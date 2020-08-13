def filter_js(path):
    if 'js/src/tests' in path or 'jit-test' in path:
        return False
    return True
