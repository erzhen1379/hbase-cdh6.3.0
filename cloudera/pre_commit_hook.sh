#!/bin/bash
####
# CLOUDERA-BUILD
#
# The cloudera precommit driver is triggered and calls this script
# which performs precommit checks using apache yetus.
#
# This scripts gets passed some env variables that include pointers to
# the branch with the patch applied, and the hash of the patch.
#
# One minor complication is that yetus depends having a patch file to
# apply to the current branch.

# Entering this script, there are few required env var args and
# optional args:
echo "GIT_COMMIT (hash of push under review):   $GIT_COMMIT"
echo "GERRIT_BRANCH (branch name to commit to): $GERRIT_BRANCH"
echo "YETUS_ARGS (env provided args):           $YETUS_ARGS"
WORKSPACE=${WORKSPACE:-"."}
RUN_IN_DOCKER=${RUN_IN_DOCKER:-"false"}
DEBUG=${DEBUG:-"true"}
YETUS_ARGS=${YETUS_ARGS:-'--project=hbase --plugins=all,-hadoopcheck,-asflicense --tests-filter=test4tests'}
GIT=${GIT:-$(which git)}
echo "YETUS_ARGS (used args):                   $YETUS_ARGS"

echo "git version installed by default.  This needs to be v1.7.3+ (NOTE: centos6 defaults to git 1.7.1)"
$GIT --version

# Unit tests exclude list living in ./cloudera
#
# Trim out every thing after a '#', then drop all-whitespace lines, and then reformat to
# EXCLUDED_TESTS expected comma separated list
sed 's/#.*//' cloudera/excluded.txt |  grep -v '^\w*$' | tr '\n' ',' | sed 's/^/EXCLUDED_TESTS=/' > build.properties

# Assumed from job environment
export JAVA_HOME=$JAVA_1_8_HOME
export PATH=${JAVA_HOME}/bin:${MAVEN_3_5_0_HOME}/bin:$PATH
export YETUS_VERSION_NUMBER=0.8.0

if [[ "true" = "${DEBUG}" ]]; then
  set -x
  env
  pwd
fi

echo "checking user"
whoami
echo "checking groups"
groups

COMPONENT=${WORKSPACE}
TEST_FRAMEWORK=${WORKSPACE}/test_framework

# defensive check against misbehaving tests
find "${COMPONENT}" -name target -exec chmod -R u+w {} \;

PATCHPROCESS=${WORKSPACE}/patchprocess
if [[ -d ${PATCHPROCESS} ]]; then
  echo "[WARN] patch process already existed '${PATCHPROCESS}'"
  rm -rf "${PATCHPROCESS}"
fi
mkdir -p "${PATCHPROCESS}"

# First time we call this it's from jenkins, so break it on spaces
# YETUS_ARGS=(${YETUS_ARGS} --jenkins)
## HACK avoid --jenkins which enables robot which does a 'git -xdf' that breaks the run
YETUS_ARGS=(${YETUS_ARGS} --dirty-workspace --run-tests)

### Download Yetus
if [ ! -d "${TEST_FRAMEWORK}" ]; then
  echo "[INFO] Downloading Yetus..."
  mkdir -p "${TEST_FRAMEWORK}"
  cd "${TEST_FRAMEWORK}"

  mkdir -p "${TEST_FRAMEWORK}/.gpg"
  chmod -R 700 "${TEST_FRAMEWORK}/.gpg"

  # TODO post these curl'ed files on mirrors or artifactory and grab it from there.
  curl -L --fail -o "${TEST_FRAMEWORK}/KEYS_YETUS" https://dist.apache.org/repos/dist/release/yetus/KEYS
  gpg --homedir "${TEST_FRAMEWORK}/.gpg" --import "${TEST_FRAMEWORK}/KEYS_YETUS"

  ## Release
  curl -L --fail -O "https://dist.apache.org/repos/dist/release/yetus/${YETUS_VERSION_NUMBER}/yetus-${YETUS_VERSION_NUMBER}-bin.tar.gz"
  curl -L --fail -O "https://dist.apache.org/repos/dist/release/yetus/${YETUS_VERSION_NUMBER}/yetus-${YETUS_VERSION_NUMBER}-bin.tar.gz.asc"
  gpg --homedir "${TEST_FRAMEWORK}/.gpg" --verify "yetus-${YETUS_VERSION_NUMBER}-bin.tar.gz.asc"
  tar xzpf "yetus-${YETUS_VERSION_NUMBER}-bin.tar.gz"
fi

TESTPATCHBIN=${TEST_FRAMEWORK}/yetus-${YETUS_VERSION_NUMBER}/bin/test-patch
TESTPATCHLIB=${TEST_FRAMEWORK}/yetus-${YETUS_VERSION_NUMBER}/lib/precommit

if [ ! -x "${TESTPATCHBIN}" ] && [ -n "${TEST_FRAMEWORK}" ] && [ -d "${TEST_FRAMEWORK}" ]; then
  echo "Something is amiss with the test framework; removing it. please re-run."
  rm -rf "${TEST_FRAMEWORK}"
  exit 1
fi

cd "${WORKSPACE}"

if [[ "true" = "${DEBUG}" ]]; then
  echo "[DEBUG] debug mode is on, dumping the test patch env"
  # DEBUG print the test framework
  ls -l "${TESTPATCHBIN}"
  ls -la "${TESTPATCHLIB}/test-patch.d/"
  # DEBUG print the local customization
  if [ -d "${COMPONENT}/tools/jenkins/test-patch.d" ]; then
    ls -la "${COMPONENT}/tools/jenkins/test-patch.d/"
  fi
  YETUS_ARGS=(--debug ${YETUS_ARGS[@]})
fi

# Right now running on Docker is broken because it can't find our custom build of git
if [[ "true" = "${RUN_IN_DOCKER}" ]]; then
  YETUS_ARGS=(--docker --findbugs-home=/opt/findbugs ${YETUS_ARGS[@]})
  if [ -d "${COMPONENT}/dev-support/docker/Dockerfile" ]; then
    YETUS_ARGS=(--dockerfile="${COMPONENT}/dev-support/docker/Dockerfile" ${YETUS_ARGS[@]})
    YETUS_ARGS=("--dockermemlimit=20g" "${YETUS_ARGS[@]}")
  fi
else
  YETUS_ARGS=(--findbugs-home=/opt/toolchain/findbugs-1.3.9 ${YETUS_ARGS[@]})
fi

# If we start including any custom plugins, grab them.
if [ -d "${COMPONENT}/dev-support/test-patch.d" ]; then
  YETUS_ARGS=("--user-plugins=${COMPONENT}/dev-support/test-patch.d" ${YETUS_ARGS[@]})
fi

# If we have our personality defined, use it.
if [ -r "${COMPONENT}/cloudera/cdh-personality.sh" ]; then
  YETUS_ARGS=("--personality=${COMPONENT}/cloudera/cdh-personality.sh" ${YETUS_ARGS[@]})
fi

YETUS_ARGS=("--proclimit=10000" "${YETUS_ARGS[@]}")

# work around YETUS-61, manually create a patch file and move the repo to the correct branch.
if [ -z "${GIT_COMMIT}" ] || [ -z "${GERRIT_BRANCH}" ]; then
  echo "[FATAL] env variables about the git commits under test not found, aborting." >&2
  exit 1
fi
PATCHFILE=$(mktemp --quiet --tmpdir="${PATCHPROCESS}" "hbase.precommit.test.XXXXXX-${GERRIT_BRANCH}.patch")
cd "${COMPONENT}"
"${GIT}" remote -v
"${GIT}" log --oneline -50 --graph
# '--first-parent' for straight line commit histories it lists the
#   previous commits and for commit histories with merges it returns
#   just the cdh-specific commits and merges
"${GIT}" log --first-parent --oneline -5
# 'head -2 | tail -1' gets the commit on the cdh side before the current one.
# 'cut -d ' ' -f 1' gets the first field which is the hash of the previous cdh commit.
CDH_PARENT=`"${GIT}" log --first-parent --oneline | head -2 | tail -1 |  cut -d ' ' -f 1`

# Create the patch via diff.  This "works" with regular commits and merge commits
"${GIT}" diff --full-index "${CDH_PARENT}".."${GIT_COMMIT}" >"${PATCHFILE}"

# Check out the commit under review
"${GIT}" checkout "${GERRIT_BRANCH}"

# Set code back to the parent
"${GIT}" reset --hard "${CDH_PARENT}"
"${GIT}" branch --set-upstream-to="origin/${GERRIT_BRANCH}" "${GERRIT_BRANCH}"
cd "${WORKSPACE}"

# activate mvn-gbn wrapper
export PATH="$(dirname "$(which mvn-gbn-wrapper)")":"$PATH"
mv "$(which mvn-gbn-wrapper)" "$(dirname "$(which mvn-gbn-wrapper)")/mvn"

# invoke test-patch and send results to a known HTML file.
if ! /bin/bash "${TESTPATCHBIN}" \
        "${YETUS_ARGS[@]}" \
        --patch-dir="${PATCHPROCESS}" \
        --basedir="${COMPONENT}" \
        --mvn-custom-repos \
        --git-cmd="${GIT}" \
        --branch="${GERRIT_BRANCH}" \
        --html-report-file="${PATCHPROCESS}/report_output.html" \
        --whitespace-eol-ignore-list=".*stylesheet.css" \
        "${PATCHFILE}" ; then
  echo "[ERROR] test patch failed, grabbing test logs into artifact 'test_logs.zip'"
  echo "[DEBUG] If we failed but didn't run any junit tests, zip will fail. We can safely ignore that."
  find "${COMPONENT}" -path '*/target/surefire-reports/*'
  # find "${COMPONENT}" -path '*/target/surefire-reports/*' | zip "${PATCHPROCESS}/test_logs.zip" -@ || true
  exit 1
fi
