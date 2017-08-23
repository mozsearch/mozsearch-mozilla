import thclient
import requests
import re
import sys

fallback = None

client = thclient.TreeherderClient()
resultsets = client.get_resultsets('comm-central', count=50)
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

        # We allow 'testfailed' since comm-central builds run some
        # checks that might not be relevant for static analysis.
        result = job['result'] in ['success', 'testfailed']

        url = ('https://treeherder.mozilla.org:443/api/jobdetail/?job_guid='
               + job['job_guid'] + '&repository=comm-central')
        res = client.session.get(url)
        j = res.json()
        for detail in j['results']:
            v = detail['url']
            if v:
                m = re.search(r'https://hg.mozilla.org/mozilla-central/rev/([0-9a-zA-Z]*)', v)
            else:
                m = None
            if m:
                mcrev = m.group(1)
                #print rev, mcrev, result

                if result:
                    print rev
                    print mcrev
                    sys.exit(0)
                elif not fallback:
                    fallback = [rev, mcrev]

print fallback[0]
print fallback[1]
