#!/usr/bin/env python3
# The translation units a try push affects, and the files to write analysis
# for (see analyze.sh): the TUs including the files it changes (by the base's
# reverse include map; see deps.py and resolve_deps.py), and the changed files
# and those TUs' own sources.  And of those files, the ones that not every TU
# including them is compiled for (ex: a source compiled in two directories),
# whose base records build-try-delta keeps.
#
# Usage: select_tus.py DEPS.json COMPILE_COMMANDS.json DIR
# (reads DIR/changed.lst; writes DIR/tus.lst, DIR/emit.lst, DIR/incomplete.lst)
import json
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from tu_source import tu_source

OBJ = "/builds/worker/workspace/obj-build"
SRC = "/builds/worker/checkouts/gecko"
deps_path, cc_path, d = sys.argv[1:4]
data = json.load(open(deps_path))
# (TUs are "DIRECTORY|SOURCE": some sources are compiled in two directories.)
tus = [f"{a}|{b}" for a, b in data["tus"]]
changed = open(f"{d}/changed.lst").read().split()
affected = {tus[t] for f in changed for t in data["deps"].get(f, [])}


def rel(p):
    if p.startswith(OBJ + "/"):
        return "__GENERATED__/" + p[len(OBJ) + 1:]
    if p.startswith(SRC + "/"):
        return p[len(SRC) + 1:]


by_tu = {}
for e in json.load(open(cc_path)):
    by_tu.setdefault(f"{e['directory']}|{tu_source(e)}", set()).add(e["file"])
emit = set(changed)
for tu in affected:
    emit.update(filter(None, (rel(f) for f in by_tu.get(tu, {tu.split("|")[1]}))))
incomplete = sorted(
    f for f in emit if any(tus[t] not in affected for t in data["deps"].get(f, []))
)
open(f"{d}/tus.lst", "w").write("".join(t + "\n" for t in sorted(affected)))
open(f"{d}/emit.lst", "w").write("".join(f + "\n" for f in sorted(emit)))
open(f"{d}/incomplete.lst", "w").write("".join(f + "\n" for f in incomplete))
print(f"{len(affected)} TUs; {len(emit)} files to write, {len(incomplete)} incompletely")
