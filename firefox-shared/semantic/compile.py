#!/usr/bin/env python3
# Compile translation units with the indexer, from the objdir's
# compile_commands.json, as the searchfox task does, but writing the analysis
# into OUTDIR (instead of the objdir's mozsearch_index), and as quickly as
# that allows (see analyze.sh): only parsing (the indexer is an AST consumer),
# and without the moz-check plugin.  (The plugin prepare.sh builds only
# writes the files MOZSEARCH_ONLY_FILES lists, if it's set.)  Run inside
# inbuild.sh.
#
# Usage: compile.py OUTDIR JOBS TUS   (TUS: a file of "DIRECTORY|SOURCE" lines;
# see tu_source.py)
import json
import os
import subprocess
import sys
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
    entry = entries.get(tu)
    if entry is None:
        return tu, -1, "no compile command"
    p = subprocess.run(command(entry), cwd=entry["directory"], capture_output=True, text=True)
    return tu, p.returncode, p.stderr


os.makedirs(outdir, exist_ok=True)
failed = 0
with ThreadPoolExecutor(jobs) as pool:
    for tu, code, stderr in pool.map(run, tus):
        if code:
            failed += 1
            print(f"FAILED ({code}): {tu}\n{stderr[-4000:]}", flush=True)
print(f"{len(tus)} translation units, {failed} failed", flush=True)
