#!/usr/bin/env python3
#
# Usage: collapse-generated-files.py < <generated-files>
#
# What ../shared/collapse-generated-files.sh does for one generated file (run
# under `parallel`, a process per file), for each generated file read from
# stdin (as `find` lists them in generated-<platform>, ex: "./dom/foo.h"), in
# one process, run in the index root after process-tc-artifacts.sh:
#
# - The file's copies, generated-*/<file> (in the order the shell's glob had
#   them), are normalized one at a time (dos2unix, then the sed expression
#   below), each compared with the first, stopping at the first that differs
#   (so the copies after it stay as they are).
# - If they're all the same, the first is moved to objdir/<file>, and the
#   platforms' analyses of it, analysis-*/__GENERATED__/<file>, are merged into
#   analysis/__GENERATED__/<file> (empty if there are none, as the shell's
#   redirection of merge-analyses' output made it).
# - Otherwise each platform's copy, in PLATFORMS' order, is moved to
#   objdir/__<platform>__/<file>, and its analysis to
#   analysis/__GENERATED__/__<platform>__/<file>, stopping at the first
#   platform which isn't optional and has no copy.
#
# The shell script started ~25 processes per file (bash, dos2unix, sed and cmp
# per copy, mkdir, mv, merge-analyses): firefox-disco's 10-11k generated files
# (~78k copies) took 0.8 minutes at 70-88% of 32 cores on the 2026-10-27
# config8 run.  Here, on threads, dos2unix and sed only run on the copies
# they could change, so their semantics are theirs exactly: dos2unix (by
# default) only changes CR-LF pairs and byte order marks, and the sed
# expression only matches text with its build paths (case-insensitively, for
# the second, so also with the characters which fold to "s" and "k" in a UTF-8
# locale).  The identical files' analyses are merged by `merge-analyses
# --batch`, a chunk of files per process, the biggest first.  A file with a
# copy which isn't a regular file is left to the shell script.

import os
import re
import shutil
import subprocess
import sys
import time
from concurrent.futures import ThreadPoolExecutor

PLATFORMS = ['linux64', 'linux64-opt', 'macosx64', 'macosx64-aarch64',
             'macosx64-aarch64-opt', 'win64', 'win64-opt', 'android-armv7',
             'android-aarch64', 'ios']
OPTIONAL = {'linux64-opt', 'ios', 'macosx64-aarch64', 'macosx64-aarch64-opt',
            'win64-opt', 'android-armv7', 'android-aarch64'}

NORMALIZE_EXPR = 's#/builds/worker/checkouts/gecko/##g;s#z:/task_[0-9]*/build/src/##gI'

BOMS = (b'\xef\xbb\xbf', b'\xff\xfe', b'\xfe\xff', b'\x84\x31\x95\x33')
# (LATIN SMALL LETTER LONG S and KELVIN SIGN, in UTF-8.)
FOLDING = (b'\xc5\xbf', b'\xe2\x84\xaa')

# The identical files' analyses merged per merge-analyses process, at most
# (it never frees the analyses' interned strings).
MERGE_CHUNK_FILES = 100
MERGE_CHUNK_BYTES = 256 << 20

CONFIG_REPO = os.environ.get('CONFIG_REPO', os.path.dirname(os.path.dirname(os.path.abspath(__file__))))


def normalize(path, unchanged=None):
    '''Normalize a copy as `dos2unix --quiet` and `sed --in-place -Ee
    NORMALIZE_EXPR` did, returning its contents.  (A copy whose contents are
    `unchanged`, contents normalizing didn't change, needs nothing.)'''
    with open(path, 'rb') as f:
        data = f.read()
    if unchanged is not None and data == unchanged:
        return data
    if b'\r\n' in data or data.startswith(BOMS):
        subprocess.run(['dos2unix', '--quiet', path], check=False)
        with open(path, 'rb') as f:
            data = f.read()
    # (The second expression needs ":/" and then a "t", which nothing else
    # folds to, before its case-insensitive comparison.)
    if (b'/builds/worker/checkouts/gecko/' in data
            or ((b':/t' in data or b':/T' in data)
                and (b'z:/task_' in data.lower() or any(c in data for c in FOLDING)))):
        subprocess.run(['sed', '--in-place', '-Ee', NORMALIZE_EXPR, path], check=False)
        with open(path, 'rb') as f:
            data = f.read()
    return data


def move_file(src, dst):
    os.makedirs(os.path.dirname(dst), exist_ok=True)
    os.rename(src, dst)


def collapse(generated, generated_dirs, analysis_dirs, to_merge):
    '''Collapse one generated file's copies; returns its log lines.'''
    copies = [f'{d}/{generated}' for d in generated_dirs if os.path.lexists(f'{d}/{generated}')]
    if any(not os.path.isfile(c) or os.path.islink(c) for c in copies) or not copies:
        script = os.path.join(CONFIG_REPO, 'shared', 'collapse-generated-files.sh')
        out = subprocess.run([script, generated], check=True, stdout=subprocess.PIPE, text=True)
        return out.stdout.splitlines()

    with open(copies[0], 'rb') as f:
        raw = f.read()
    first = normalize(copies[0])
    unchanged = first if first == raw else None
    all_same = True
    for copy in copies[1:]:
        if normalize(copy, unchanged) != first:
            all_same = False
            break

    if all_same:
        move_file(copies[0], f'objdir/{generated}')
        analyses = [f'{d}/__GENERATED__/{generated}' for d in analysis_dirs
                    if os.path.isfile(f'{d}/__GENERATED__/{generated}')]
        merged = f'analysis/__GENERATED__/{generated}'
        if analyses:
            to_merge.append((sum(os.path.getsize(a) for a in analyses), merged))
        else:
            os.makedirs(os.path.dirname(merged), exist_ok=True)
            open(merged, 'wb').close()
        return [f'Generated file {generated} was identical across platforms where it was created']

    log = []
    for platform in PLATFORMS:
        copy = f'generated-{platform}/{generated}'
        if not os.path.isfile(copy):
            if platform in OPTIONAL:
                continue
            break
        log.append(f'Taking generated file {generated} from {platform}')
        move_file(copy, f'objdir/__{platform}__/{generated}')
        analysis = f'analysis-{platform}/__GENERATED__/{generated}'
        if os.path.isfile(analysis):
            move_file(analysis, f'analysis/__GENERATED__/__{platform}__/{generated}')
    return log


def merge_analyses(to_merge):
    '''Merge the identical files' analyses, a chunk of them per
    `merge-analyses --batch analysis`, as many at once as there are CPUs.'''
    chunks = []
    chunk, chunk_bytes = [], 0
    for size, merged in sorted(to_merge, reverse=True):
        if chunk and (len(chunk) >= MERGE_CHUNK_FILES or chunk_bytes + size > MERGE_CHUNK_BYTES):
            chunks.append(chunk)
            chunk, chunk_bytes = [], 0
        chunk.append(merged[len('analysis/'):])
        chunk_bytes += size
    if chunk:
        chunks.append(chunk)

    def run(paths):
        env = dict(os.environ, RUST_LOG=os.environ.get('RUST_LOG', 'info'))
        subprocess.run(['merge-analyses', '--batch', 'analysis'], input=''.join(p + '\n' for p in paths),
                       text=True, check=True, env=env)

    with ThreadPoolExecutor(max_workers=len(os.sched_getaffinity(0))) as pool:
        for _ in pool.map(run, chunks):
            pass


def main():
    generated_files = sorted(set(line.rstrip('\n') for line in sys.stdin if line.strip()))
    # (In the order the indexers' shell's `generated-*/<file>` globs had
    # them: its collation, C.UTF-8's, compares the whole paths, so
    # generated-linux64-opt/... comes before generated-linux64/....)
    def dirs(prefix):
        return sorted((d for d in os.listdir('.') if d.startswith(prefix) and os.path.isdir(d)),
                      key=lambda d: d + '/')
    generated_dirs = dirs('generated-')
    analysis_dirs = dirs('analysis-')
    to_merge = []
    start = time.monotonic()
    # (The files are independent, and mostly read and compared: threads.)
    with ThreadPoolExecutor(max_workers=min(16, len(os.sched_getaffinity(0)))) as pool:
        logs = pool.map(lambda generated: collapse(generated, generated_dirs, analysis_dirs, to_merge),
                        generated_files)
        for log in logs:
            for line in log:
                print(line)
    print(f'Collapsed {len(generated_files)} generated files in {time.monotonic() - start:.1f} s')
    start = time.monotonic()
    merge_analyses(to_merge)
    print(f'Merged the analyses of {len(to_merge)} identical generated files in {time.monotonic() - start:.1f} s')


if __name__ == '__main__':
    main()
