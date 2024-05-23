import os
from lib import run

def modify_file_list(files, config=None, **kwargs):
    # Also grab the file list from the mozilla/ subrepo
    subrepo_path = os.path.join(config['files_path'], 'mozilla')
    sub_files = run(['git',  'ls-files'], cwd=subrepo_path).splitlines()
    sub_files = [ b'mozilla/' + f for f in sub_files if f ]
    return files + sub_files

def filter_ipdl(path):
    if 'ipc/ipdl/test' in path:
        return False
    return True

def filter_js(path):
    if 'js/src/tests' in path or 'jit-test' in path:
        return False
    return True

def filter_html(path):
    if 'testing/web-platform/' in path:
        return False
    return True

def filter_css(path):
    if 'testing/web-platform/' in path:
        return False
    return True
