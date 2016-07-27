import thclient
import requests
import re
import sys

client = thclient.TreeherderClient()
resultsets = client.get_resultsets('comm-central')
for resultset in resultsets:
    rev = resultset['revision']

    jobs = client.get_jobs('comm-central',
                           result_set_id=resultset['id'],
                           platform='linux64',
                           job_type_name='Build',
                           platform_option='debug')
    for job in jobs:
        if job['platform_option'] != 'debug':
            continue

        result = job['result'] == 'success' # otherwise will be 'busted'

        url = ('https://treeherder.mozilla.org:443/api/jobdetail/?job_guid='
               + job['job_guid'] + '&repository=comm-central')
        res = client.session.get(url)
        j = res.json()
        for detail in j['results']:
            v = detail['value']
            m = re.search(r'moz:([0-9a-zA-Z]*)', v)
            if m:
                mcrev = m.group(1)
                #print rev, mcrev, result

                if result:
                    print rev
                    print mcrev
                    sys.exit(0)

sys.exit(1)
