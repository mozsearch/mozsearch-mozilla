# This file is intentionally not executable, because it should always be sourced
# into a pre-existing shell. MOZSEARCH_PATH and INDEX_ROOT should be defined prior
# to sourcing.

if [ -z $MOZSEARCH_PATH ]
then
    echo "Error: resolve-gecko-revs.sh is being sourced without MOZSEARCH_PATH defined"
    return # leave without aborting the calling script
elif [ -z $INDEX_ROOT ]
then
    echo "Error: resolve-gecko-revs.sh is being sourced without INDEX_ROOT defined"
    return # leave without aborting the calling script
fi

REVISION_TREE=$1
REVISION_ID=$2

date

REVISION="${REVISION_TREE}.${REVISION_ID}"
CURL="curl -SsfL --compressed"

pushd $INDEX_ROOT

PREEXISTING_HG_REV=
if [ -f "target.json" ]; then
    PREEXISTING_HG_REV=$(python $MOZSEARCH_PATH/scripts/read-json.py target.json moz_source_stamp)
    echo "Found pre-existing target.json with hg revision ${PREEXISTING_HG_REV}."
fi

${CURL} https://firefox-ci-tc.services.mozilla.com/api/index/v1/task/gecko.v2.$REVISION.firefox.linux64-searchfox-debug/artifacts/public/build/target.json > target.json
INDEXED_HG_REV=$(python $MOZSEARCH_PATH/scripts/read-json.py target.json moz_source_stamp)

popd
