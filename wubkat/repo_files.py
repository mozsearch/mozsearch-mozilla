def filter_ipdl(path):
    # webkit does not have IPDL!
    return False

def filter_idl(path):
    # webkit does not have XPIDL!
    return False

def filter_js(path):
    # webkit does not have XUL, and its `.inc` files appear to at least
    # sometimes be metal shaders!
    return path.endswith(".js")
