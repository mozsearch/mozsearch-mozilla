import sys
import requests
import tempfile
import zipfile
import re
import shutil
import os.path
import jsbeautifier

target = sys.argv[1]
url = sys.argv[2]

def ignore_file(info):
    path = info.filename

    if info.file_size > 256 * 1024:
        return True

    if path.endswith('.png') or path.endswith('.jpeg') or path.endswith('.ttf') or path.endswith('.otf') or path.endswith('.gif'):
        return True

    if path.endswith('.mf') or path.endswith('.sf') or path.endswith('.rsa'):
        return True

    if path.startswith('resources/addon-sdk/'):
        return True

    if 'jquery' in path:
        return True

    if 'bootstrap' in path and 'css' in path:
        return True

    return False

def process(z, target):
    for info in z.infolist():
        if info.filename.endswith('/'):
            # It's a directory.
            continue

        if ignore_file(info):
            continue

        if info.filename.endswith('.jar'):
            try:
                d = tempfile.mkdtemp()
                z.extract(info, d)
                z2 = zipfile.ZipFile(os.path.join(d, info.filename), 'r')
                process(z2, os.path.join(target, os.path.dirname(info.filename)))
            finally:
                shutil.rmtree(d)
            continue

        data = z.open(info).read()

        if info.filename.endswith('.js') or info.filename.endswith('.jsm'):
            for line in data.splitlines():
                if len(line) > 200:
                    data = jsbeautifier.beautify(data)
                    break
                
        path = os.path.join(target, info.filename)
        pdir = os.path.dirname(path)
        if not os.path.exists(pdir):
            os.makedirs(pdir)
                
        with open(path, 'w') as f:
            print >>f, data

        print 'Wrote', path

res = requests.get(url)
if res.status_code == 404:
    print >>sys.stderr, '{}: got a 404'.format(addon['id'])
    sys.exit(0)
else:
    res.raise_for_status()

with tempfile.TemporaryFile() as tmp:
    for chunk in res.iter_content(10000):
        tmp.write(chunk)

    with zipfile.ZipFile(tmp, 'r') as z:
        process(z, target)

