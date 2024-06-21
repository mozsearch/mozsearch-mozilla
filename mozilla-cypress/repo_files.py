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
