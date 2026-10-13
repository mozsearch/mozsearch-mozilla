#!/usr/bin/env python3
# Fold deps.py's paths through the objdir's symlinks (dist/include's headers
# link to the srcdir, absolutely, or elsewhere in the objdir, relatively), so
# that the reverse include map is keyed by the files patches change and the
# files the build generates.
#
# Usage: resolve_deps.py HOST_OBJDIR DEPS.json OUT.json
import json
import os
import sys

OBJ = "/builds/worker/workspace/obj-build"
SRC = "/builds/worker/checkouts/gecko"
host_obj, deps_path, out_path = sys.argv[1:4]


def resolve(key):
    if not key.startswith("__GENERATED__/"):
        return key
    p = os.path.join(host_obj, key[len("__GENERATED__/"):])
    for _ in range(10):
        if not os.path.islink(p):
            break
        target = os.readlink(p)
        if target.startswith(SRC + "/"):
            return target[len(SRC) + 1:]
        if target.startswith(OBJ + "/"):
            p = os.path.join(host_obj, target[len(OBJ) + 1:])
        else:
            p = os.path.normpath(os.path.join(os.path.dirname(p), target))
    rel = os.path.relpath(p, host_obj)
    return key if rel.startswith("..") else "__GENERATED__/" + rel


data = json.load(open(deps_path))
deps = {}
for key, tus in data["deps"].items():
    deps.setdefault(resolve(key), set()).update(tus)
data["deps"] = {k: sorted(v) for k, v in deps.items()}
json.dump(data, open(out_path, "w"))
left = sum(1 for k in deps if k.startswith("__GENERATED__/dist/include/"))
print(f"{len(deps)} files; {left} still under dist/include")
