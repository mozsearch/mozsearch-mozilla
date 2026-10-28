#!/usr/bin/env python3
# Compile translation units with the indexer, from the objdir's
# compile_commands.json, as the searchfox task does, but writing the analysis
# into OUTDIR (instead of the objdir's mozsearch_index), and as quickly as
# that allows (see analyze.sh): only parsing (the indexer is an AST consumer),
# and without the moz-check plugin.  (The plugin prepare.sh builds only
# writes the files MOZSEARCH_ONLY_FILES lists, if it's set.)  Run inside
# inbuild.sh.  At the end, it says how long they took: in all, how much of the
# jobs' time they used, how long the end had fewer than JOBS of them running,
# and the slowest (with their CPU time and peak memory, from wait4).
#
# Usage: compile.py OUTDIR JOBS TUS   (TUS: a file of "DIRECTORY|SOURCE" lines;
# see tu_source.py)
import json
import os
import subprocess
import sys
import time
from concurrent.futures import ThreadPoolExecutor

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from tu_source import tu_source

OBJDIR = "/builds/worker/workspace/obj-build"
INDEX = OBJDIR + "/mozsearch_index"

outdir, jobs, tus_path = sys.argv[1], int(sys.argv[2]), sys.argv[3]
tus = open(tus_path).read().split()

with open(OBJDIR + "/compile_commands.json") as f:
    entries = {}
    for e in json.load(f):
        entries.setdefault(f"{e['directory']}|{tu_source(e)}", e)


def command(entry):
    argv = [outdir if a == INDEX else a for a in entry["arguments"]]
    # (make compiles the sources in the objdir directory by their relative
    # paths, which __FILE__ expands to, while the compile database has
    # absolute ones.)
    prefix = entry["directory"] + "/"
    argv = [
        a[len(prefix):] if a.startswith(prefix) and a.endswith((".cpp", ".cc", ".c")) else a
        for a in argv
    ]
    for flag in ("-o", "-MF"):
        while flag in argv:
            i = argv.index(flag)
            del argv[i : i + 2]
    argv = [a for a in argv if a not in ("-c", "-MD", "-MP")]
    argv.insert(1, "-fsyntax-only")
    if "moz-check" in argv:
        i = argv.index("moz-check")
        del argv[i - 3 : i + 1]
    return argv


def run(tu):
    """Compile `tu`, returning (tu, exit code, stderr, start, end, CPU
    seconds, peak resident bytes)."""
    start = time.monotonic()
    entry = entries.get(tu)
    if entry is None:
        return tu, -1, "no compile command", start, start, 0.0, 0
    p = subprocess.Popen(
        command(entry),
        cwd=entry["directory"],
        stdout=subprocess.DEVNULL,
        stderr=subprocess.PIPE,
        text=True,
    )
    stderr = p.stderr.read()
    p.stderr.close()
    # (wait4 rather than wait, for the compiler's usage.)
    _, status, usage = os.wait4(p.pid, 0)
    p.returncode = os.waitstatus_to_exitcode(status)
    cpu = usage.ru_utime + usage.ru_stime
    return tu, p.returncode, stderr, start, time.monotonic(), cpu, usage.ru_maxrss * 1024


os.makedirs(outdir, exist_ok=True)
failed = 0
results = []
started = time.monotonic()
with ThreadPoolExecutor(jobs) as pool:
    for tu, code, stderr, start, end, cpu, rss in pool.map(run, tus):
        if code:
            failed += 1
            print(f"FAILED ({code}): {tu}\n{stderr[-4000:]}", flush=True)
        results.append((end - start, cpu, rss, tu, start))
wall = time.monotonic() - started
cpu = sum(result[1] for result in results)
# (They start in order, so after the last one starts, fewer than JOBS run.)
tail = wall - (max(result[4] for result in results) - started) if results else 0
print(
    f"{len(tus)} translation units, {failed} failed, in {wall:.0f} s with {jobs} jobs: "
    f"{cpu:.0f} CPU seconds, {100 * cpu / max(wall * jobs, 1e-9):.0f}% of the jobs' time, "
    f"the last {tail:.0f} s with fewer than {jobs} running",
    flush=True,
)
if results:
    rss, tu = max((result[2], result[3]) for result in results)
    print(f"Peak memory: {rss / 1e9:.2f} GB ({tu})")
    print("Slowest:")
    for seconds, tu_cpu, tu_rss, tu, _ in sorted(results, reverse=True)[:10]:
        print(f"  {seconds:.0f} s ({tu_cpu:.0f} CPU s, {tu_rss / 1e9:.2f} GB): {tu}")
