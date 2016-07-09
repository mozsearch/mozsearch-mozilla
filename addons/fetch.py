import json
import os
import os.path
import requests

def fetch():
    server = 'https://addons.mozilla.org'
    url = server + '/api/v3/addons/search/?sort=created&type=extension'

    xpis = {}

    while url:
        res = requests.get(url)
        res.raise_for_status()

        res_json = res.json()
        for addon in res_json['results']:
            print addon['id']
            print addon['guid']

            names = addon['name']
            for k in names:
                name = names[k]
                if k == 'en-US':
                    break
            print name

            guid = addon['guid']

            for v in addon['current_version']['files']:
                prefix1 = guid[1:3]
                prefix2 = guid[4:6]
                name_fixed = name.replace('/', '_')
                path = 'data/%s/%s/%s/%s/%d' % (prefix1, prefix2, guid, name_fixed, v['id'])

                if os.path.exists(path):
                    continue

                os.makedirs(path)

                target = path + ('/%s.xpi' % guid)

                url = v['url']

                print path
                print v['id'], v['url']

                xpis[target] = url

            print

        if res_json['next']:
            url = res_json['next']
        else:
            url = None

    with open('urls.txt', 'w') as f:
        for target, url in xpis.items():
            if '\n' in target or '\n' in url:
                continue

            print >>f, target.encode('utf-8')
            print >>f, url.encode('utf-8')

if __name__ == '__main__':
    fetch()
    
