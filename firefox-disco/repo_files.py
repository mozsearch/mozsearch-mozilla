def filter_ipdl(path):
    if 'ipc/ipdl/test' in path:
        return False
    return True

def filter_webidl(path):
    if 'dom/bindings/mozwebidlcodegen/test' in path:
        return False
    if 'dom/bindings/test' in path:
        return False
    if 'dom/webidl/MozApplicationEvent.webidl' in path:
        return False
    if 'tools/ts/' in path:
        return False
    return True

def modify_file_list(lines, config):
    lines.append(b'__GENERATED__/dom/bindings/CSS2Properties.webidl')
    lines.append(b'__GENERATED__/dom/bindings/CSSStyleProperties.webidl')
    return lines

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
