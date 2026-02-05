#!/usr/bin/env python3

import sys
import json
import os
import re

# Build help-input.html and tree-list.js from config json files.
# The following properties are used for each tree:
#
#   'tree_list_label': string
#     The label used in the tree-list.js.
#   'help_label': string
#     The label used in the repositories table in help-input.html.
#   'label': string
#     Set `tree_list_label` and `help_label` at once.
#   'group': string
#     The group that the tree corresponds to.
#     One of the string in the `columns` list below.
#   'group_order': int
#     Trees inside a group are ordered by this value, in ascending order.
#     Trees with the same group_order are ordered by the lower-cased
#     tree_list_label.
#   'git_blame_path': string
#     Part of the main config.  Used for checking if blame is available.
#   'ccov_root': string
#     Part of the main config.  Used for checking if coverage is available.
#   'help_indexed_langs': string[]
#     List of languages indexed in the repository.
#     subset of the `langs` list below.

columns = [
    ['Firefox'],
    ['Firefox other', 'Thunderbird'],
    ['Searchfox', 'MinGW', 'Other'],
]

langs = ['js', 'idl', 'cpp', 'rs', 'java', 'py']


def load_configs(config_repo_dir, langs):
    configs = [
        'config1.json',
        'config2.json',
        'config3.json',
        'config4.json',
        'config5.json',
        'config6.json',
        'config7.json',
    ]

    groups = {}
    for name in configs:
        with open(os.path.join(config_repo_dir, name), 'r') as f:
            config = json.load(f)

        for tree, data in config['trees'].items():
            if 'group' not in data:
                continue

            tree_list_label = tree
            help_label = tree
            if 'label' in data:
                tree_list_label = data['label']
                help_label = data['label']
            if 'tree_list_label' in data:
                tree_list_label = data['tree_list_label']
            if 'help_label' in data:
                help_label = data['help_label']

            info = {
                'tree': tree,
                'tree_list_label': tree_list_label,
                'help_label': help_label,
                'group_order': data.get('group_order', 0),
                'search': True,
                'blame': 'git_blame_path' in data,
                'ccov': 'ccov_root' in data,
            }

            indexed_langs = data.get('help_indexed_langs', [])

            for lang in langs:
                info[lang] = lang in indexed_langs

            group_name = data['group']
            if group_name not in groups:
                groups[group_name] = []
            groups[group_name].append(info)

    for infos in groups.values():
        infos.sort(key=lambda info: (info.get('group_order', 0),
                                     info['tree_list_label'].lower()))

    return groups


def to_cell(b):
    if b:
        return '<td style="text-align: center">✓</td>'
    return '<td></td>'


def print_table(out, groups, group_names):
    print('''
    <table style="width:100%" border="1">
      <thead>
        <tr>
          <th rowspan="2">Repository</th>
          <th rowspan="2">Text search</th>
          <th rowspan="2">Blame</th>
          <th rowspan="2">Coverage</th>
          <th colspan="6">Language semantic analysis</th>
        </tr>
        <tr>
          <th>JS</th>
          <th>IDL</th>
          <th>C++</th>
          <th>Rust</th>
          <th>Java</th>
          <th>Python</th>
        </tr>
      </thead>
      <tbody>
''', file=out)

    for name in group_names:
        group = groups[name]
        print(f'<tr>', file=out)
        print(f'<td colspan="10" style="text-align: start;">{name}</td>', file=out)
        print(f'</tr>', file=out)
        first = True
        for info in group:
            tree = info['tree']
            label = info['help_label']

            if 'blame' not in info:
                print(f'{tree} is not found in config')
                sys.exit(1)

            search = to_cell(True)
            blame = to_cell(info['blame'])
            ccov = to_cell(info['ccov'])

            js = to_cell(info['js'])
            idl = to_cell(info['idl'])
            cpp = to_cell(info['cpp'])
            rs = to_cell(info['rs'])
            java = to_cell(info['java'])
            py = to_cell(info['py'])

            print(f'<tr>', file=out)
            print(f'<td style="text-align: start; padding-inline-start: 3em;"><a href="/{tree}/source/">{label}</a></td>', file=out)
            print(f'{search}{blame}{ccov}{js}{idl}{cpp}{rs}{java}{py}', file=out)
            print(f'</tr>', file=out)

    print('''
      </tbody>
    </table>
''', file=out)


def build_help(config_repo_dir, out_file, groups, group_names):
    with open(os.path.join(config_repo_dir, 'help_template.html'), 'r') as f:
        content = f.read()

    marker = '{TABLE}'
    start = content.find(marker)
    if start == -1:
        print(f'{marker} marker not found')
        sys.exit(1)
    end = start + len(marker)

    with open(out_file, 'w') as out:
        print(content[:start], file=out)
        print_table(out, groups, group_names)
        print(content[end:], file=out)


def print_tree_list(out, groups, columns):
    print('var TREE_LIST = [', file=out)
    for column in columns:
        print('  [', file=out)
        for group in column:
            print('    {', file=out)
            print('      name: "' + group + '",', file=out)
            print('      items: [', file=out)
            for info in groups[group]:
                print('        {', file=out)
                if info['tree_list_label'] != info['tree']:
                    print('          label: "' + info['tree_list_label'] + '",', file=out)
                print('          value: "' + info['tree'] + '",', file=out)
                print('        },', file=out)
            print('      ],', file=out)
            print('    },', file=out)
        print('  ],', file=out)
    print('];', file=out)


def build_tree_list(out_file, groups, columns):
    with open(out_file, 'w') as out:
        print_tree_list(out, groups, columns)


def flatten_columns(columns):
    names = []
    for column in columns:
        for name in column:
            names.append(name)
    return names


if len(sys.argv) != 4:
    print("Usage: build-help-and-tree-list.py <target> <config_repo_dir> <out_file>")
    print("  target: \"help\" or \"tree-list\"")
    print("  config_repo_dir: The directory that contains config*.json")
    print("  out_file: The path of the output file")
    sys.exit(1)

target = sys.argv[1]
config_repo_dir = sys.argv[2]
out_file = sys.argv[3]

groups = load_configs(config_repo_dir, langs)

if target == 'help':
    build_help(config_repo_dir, out_file, groups, flatten_columns(columns))
elif target == 'tree-list':
    build_tree_list(out_file, groups, columns)
