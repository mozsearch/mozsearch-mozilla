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
