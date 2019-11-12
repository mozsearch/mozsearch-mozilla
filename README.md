# Mozsearch config for Mozilla

This repository contains the config scripts used by the Mozilla instance of
the mozsearch source indexing tool. The instance is hosted at
https://searchfox.org/.

## Configs

There are two config files, `config.json` and `mozilla-releases.json`. One
indexer/web-server pair operates on the `config.json` file, and another
pair operates on the `mozilla-releases.json` file. This provides a number
of benefits compared to putting everything in a single file:
- The indexer instances can run in parallel, so they don't take as long
  in wall-clock time to finish the daily indexing run.
- An error that occurs during processing of the `config.json` repositories
  will abort that indexer and prevent the updated index from being published,
  but it will not affect the processing of the `mozilla-releases.json`
  repositories. So some degree of independence is provided in terms of
  failure.
- Hosting a set of repositories incurs load on a web server instance, and
  splitting the repositories across two web server instances allows them
  to be more responsive to user requests.

The `release` load balancer in the searchfox.org AWS stack knows (by a
one-time manual setup) how to direct requests for a particular repository
to the web server hosting that repository, so that everything appears
seamlessly under the searchfox.org domain.

## Structure

Each repository has a folder containing four main scripts: `setup`, `upload`,
`find-repo-files`, and `build`. These four entry-point scripts are invoked from the
[mozsearch](https://github.com/mozsearch/mozsearch) codebase as part of the
indexing process.

First, the `setup` script is run for all the repositories. In general, this
script downloads the git repository tarballs and updates them. It also downloads
any other remote data that needs to be fetched for processing the repository.
For the mozilla-central based repositories in particular, it downloads artifacts
from the most recent searchfox taskcluster cron job for that repository.

After the `setup` script is run, the `upload` script is run for all the
repositories, if this is a release-channel run (as opposed to a dev-channel run).
This uploads the updated git and blame repositories back to AWS.

After that, the mozsearch codebase runs the indexing steps for each repository,
which invoke the `find-repo-files` script to list the different kinds of source
files in the repository, as well as the `build` script which does the
build steps for the repository. Currently the only repository that actually
gets build (in terms of code compilation) is the `nss` repository.

For the mozilla-central based repositories, the "build" step consists of
unpacking and merging the analysis data from taskcluster. Other repositories
generally don't do builds at all and therefore don't get C++ or Rust analysis.

As the `setup` and `build` steps for the mozilla-central based repositories
are effectively the same, this code has been refactored into a set of scripts
that lives in the `shared/` folder in this repository.

## How searchfox.org stays up-to-date

1. Taskcluster triggers nightly builds with searchfox build artifacts.
   - https://searchfox.org/mozilla-central/source/.cron.yml contains a list of
     jobs which contain a "when" filter and some kind of hook mechanism.  All
     times are UTC and everything needs to be a multiple of 15 minutes.
   - Firefox's nightlies are defined as part of the "nightly-desktop" build
     of the "mozilla-central" project is scheduled to start at 10:00 UTC and
     22:00 UTC.
   - There are also builds like "periodic-update" for older releases that run
     Mondays and Thursdays at 10:00 UTC.
   - There's also a "searchfox-index" job that's also scheduled to start at
     10:00 UTC, which I guess puts it on the same underlying task for any jobs
     started at that time for the projects of interest for searchfox.  The entry
     defines a "searchfox_index" "target-tasks-method" which maps to the
     `@_target_task('searchfox_index')` decorated method in
     https://searchfox.org/mozilla-central/source/taskcluster/taskgraph/target_tasks.py
     which in turn maps onto the specific set of taskcluster build targets that
     searchfox needs.
2. AWS Lambda cron jobs trigger searchfox indexing jobs for `config.json` at
   13:30 UTC (which is 9:30am Eastern Time) and `mozilla-releases.json` at
   14:00 UTC (which is 10am Eastern Time).  These times are a function of when
   the windows searchfox job completes, with `mozilla-releases.json` being
   additionally delayed so that it can consume the byproducts of the
   `config.json` indexer run that are uploaded back to S3 by the
   `mozilla-central/upload` script.  If shifting the `config.json` indexer's
   start time, make sure that the upload reliably completes before any other
   indexing jobs are kicked off.
   - Additional jobs could be added for the 22:00 UTC nightly build if we
     wanted.
3. The indexer jobs run, for the specific example of mozilla-central:
   - The indexer invokes https://github.com/mozsearch/mozsearch-mozilla/blob/master/mozilla-central/setup
   - That script invokes https://github.com/mozsearch/mozsearch-mozilla/blob/master/shared/resolve-gecko-revs.sh which fetches
     `https://firefox-ci-tc.services.mozilla.com/api/index/v1/task/gecko.v2.$REVISION.firefox.linux64-searchfox-debug/artifacts/public/build/target.json`
     where $REVISION is "mozilla-central.latest".  We extract the specific revision from that.
   - Then https://github.com/mozsearch/mozsearch-mozilla/blob/master/shared/fetch-tc-artifacts.sh
     is invoked and it tries to fetch the result of the taskcluster searchfox jobs
     for all of our supported platforms (linux64 macosx64 win64 android-armv7)
     using that revision.  This is frequently where we error out if the windows job
     hasn't completed yet.

## Troubleshooting Indexer Failures

Here are some of the last lines you may see due to an indexer failure.

In general, the simplest course of action for an indexer failure is to terminate
the indexer and delete its volume, then manually re-trigger the indexer.  Or
just wait for tomorrow's indexing job.

### Reference is not a tree

```
+ git checkout -B release c0908ad54a95f949a1dc9f8edd3339f01423dd97
fatal: reference is not a tree: c0908ad54a95f949a1dc9f8edd3339f01423dd97
```

vcs-sync may have failed.  The fact that we got this far means the git-hg map
had an entry for the given revision but the revision somehow didn't make it to
the gecko-dev repo.  :dhouse is an appropriate contact for finding out what
happened with vcs-sync.

### Requested URL returned error: 404 Not Found

```
curl: (22) The requested URL returned error: 404 Not Found
parallel: This job failed:
curl -SsfL --compressed https://firefox-ci-tc.services.mozilla.com/api/index/v1/task/gecko.v2.mozilla-beta.revision.c76e2781238741c8c9822725da3dffc2d96c282c.firefox.win64-searchfox-debug/artifacts/public/build/target.mozsearch-index.zip > win64.mozsearch-index.zip
```

An indexing job hadn't completed by the time we got to fetching its results.
Check treeherder for the given tree.  You can filter on "searchfox".  Frequently
what happens is an infrastructure error happened (resulting in a blue build),
and the rescheduled job is still running at the current moment.  If
re-triggering, wait for the job to complete.
