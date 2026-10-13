#!/usr/bin/env python3
# Scan every translation unit in the objdir's compile_commands.json for the
# files it includes (clang -M, without the plugins), for a reverse include map:
# which TUs a patch's changed files affect.  Run inside inbuild.sh.
#
# Usage: deps.py OUT.json [-j N]
# OUT.json: {"tus": [[directory, source], ...], "deps": {path: [tu index...]}}
# with paths relative to the srcdir, or __GENERATED__/... for the objdir's.
import json
import os
import subprocess
import sys
import time
from concurrent.futures import ThreadPoolExecutor

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from tu_source import tu_source

OBJDIR = "/builds/worker/workspace/obj-build"
SRCDIR = "/builds/worker/checkouts/gecko"

out = sys.argv[1]
jobs = int(sys.argv[3]) if len(sys.argv) > 3 else os.cpu_count()

with open(OBJDIR + "/compile_commands.json") as f:
    tus = {}
    for e in json.load(f):
        tus.setdefault((e["directory"], tu_source(e)), e["arguments"])


def scan_command(argv):
    argv = list(argv)
    if "-load" in argv:
        i = argv.index("-load")
        j = len(argv) - 1 - argv[::-1].index("-plugin-arg-mozsearch-index")
        del argv[i - 1 : j + 3]
    for flag in ("-o", "-MF"):
        while flag in argv:
            i = argv.index(flag)
            del argv[i : i + 2]
    argv = [a for a in argv if a not in ("-c", "-MD", "-MP")]
    return argv[:1] + ["-M"] + argv[1:]


def relative(path):
    path = os.path.normpath(path)
    if path.startswith(OBJDIR + "/"):
        return "__GENERATED__/" + path[len(OBJDIR) + 1 :]
    if path.startswith(SRCDIR + "/"):
        return path[len(SRCDIR) + 1 :]
    return None


def scan(key):
    directory, _ = key
    start = time.time()
    p = subprocess.run(scan_command(tus[key]), cwd=directory, capture_output=True, text=True)
    files = set()
    if p.returncode == 0:
        text = p.stdout.replace("\\\n", " ")
        for word in text.split(":", 1)[1].split():
            rel = relative(os.path.join(directory, word))
            if rel:
                files.add(rel)
    return key, p.returncode, time.time() - start, files, p.stderr[-2000:]


keys = list(tus)
start = time.time()
deps = {}
failed = 0
times = []
with ThreadPoolExecutor(jobs) as pool:
    for n, (key, code, took, files, stderr) in enumerate(pool.map(scan, keys)):
        times.append(took)
        if code:
            failed += 1
            sys.stderr.write(f"failed: {key[1]}\n{stderr}\n")
            continue
        for path in files:
            deps.setdefault(path, []).append(n)
times.sort()
print(
    f"{len(keys)} TUs in {time.time() - start:.0f}s with {jobs} jobs; {failed} failed; "
    f"per TU median {times[len(times) // 2]:.2f}s, max {times[-1]:.2f}s; {len(deps)} files"
)
with open(out, "w") as f:
    json.dump({"tus": keys, "deps": deps}, f)
