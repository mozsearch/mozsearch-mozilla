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

def filter_idl(path):
    # ESR31 doesn't even have an XPIDL parser we'll recognize but let's bypass
    # trying to use a modern one.
    return False
