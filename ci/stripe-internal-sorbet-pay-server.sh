#!/bin/bash
set -eux

# shellcheck disable=SC1091
. /usr/stripe/bin/docker/stripe-init-build

PAY_SERVER=./pay-server


export TIME='cmd: "%C"
wall: %e
user: %U
system: %S
maxrss: %M
'

# This is what we'll ship to our users
/usr/local/bin/junit-script-output \
    release-build \
    bazel build main:sorbet --config=stripeci --config=release-linux

# Validate the build
VERSION=$(./bazel-bin/main/sorbet --version)
EXPECTED_VERSION='Ruby Typer rev [0-9]* git [0-9a-f]{40} built on 201.* GMT with debug symbols'
if ! [[ $VERSION =~ $EXPECTED_VERSION ]]; then
    git status
    echo "Bad Version: $VERSION"
    exit 1
fi

mkdir -p /build/bin
cp bazel-bin/main/sorbet /build/bin

ASAN_SYMBOLIZER_PATH="$(bazel info output_base)/external/llvm_toolchain/bin/llvm-symbolizer"
ASAN_SYMBOLIZER_PATH="$(realpath "$ASAN_SYMBOLIZER_PATH")"
export ASAN_SYMBOLIZER_PATH
$ASAN_SYMBOLIZER_PATH -version

SORBET_CACHE_DIR=$(mktemp -d)
mkdir -p "${SORBET_CACHE_DIR}/bin"
export SORBET_CACHE_DIR
RUBY_TYPER_CACHE_DIR=$SORBET_CACHE_DIR
export RUBY_TYPER_CACHE_DIR

GIT_SHA=$(git rev-parse HEAD)

if [ ! -d $PAY_SERVER ]; then
    echo "$PAY_SERVER doesn't exist"
    exit 1
fi
cd $PAY_SERVER

if [ ! -f "../ci/stripe-internal-sorbet-pay-server-sha" ]; then
    echo "ci/stripe-internal-sorbet-pay-server-sha doesn't exist"
    exit 1
fi
PAY_SERVER_SHA="$(cat ../ci/stripe-internal-sorbet-pay-server-sha)"
# You need this if you set $PAY_SERVER_SHA to be a branch
# git fetch origin "$PAY_SERVER_SHA"
git checkout "$PAY_SERVER_SHA"
SORBET_MASQUERADE_SHA="$(cat sorbet/sorbet.sha)"
(
    cd -
    mkdir -p "${SORBET_CACHE_DIR}/${SORBET_MASQUERADE_SHA}/bin"
    ln -s "$(pwd)/bazel-bin/main/sorbet" "${SORBET_CACHE_DIR}/${SORBET_MASQUERADE_SHA}/bin"
)
eval "$(rbenv init -)"
stripe-deps-ruby --without ci_ignore

# Clobber our .bazelrc so pay-server's bazel doesn't see it.
mv ../.bazelrc ../.bazelrc-moved

# Unset JENKINS_URL so pay-server acts like it's running in dev, not
# CI, and runs its own `bazel` invocations
env -u JENKINS_URL rbenv exec bundle exec rake build:autogen:SorbetFileListStep

# restore bazelrc
mv ../.bazelrc-moved ../.bazelrc

RECORD_STATS=
if [ "$GIT_BRANCH" == "master" ] || [[ "$GIT_BRANCH" == integration-* ]]; then
    RECORD_STATS=1
    echo Will submit metrics for "$GIT_SHA"
fi

OUT=$(mktemp)
TIMEFILE=$(mktemp)

/usr/local/bin/junit-script-output \
    typecheck-uncached \
    /usr/bin/time -o "$TIMEFILE" ./scripts/bin/typecheck 2>&1 | tee "$OUT"
if [ "$(cat "$OUT")" != "No errors! Great job." ]; then
    exit 1
fi
cat "$TIMEFILE"

# Run 2 more times to exercise caching
/usr/local/bin/junit-script-output \
    typecheck-cached \
    /usr/bin/time -o "$TIMEFILE" ./scripts/bin/typecheck 2>&1 | tee "$OUT"
if [ "$(cat "$OUT")" != "No errors! Great job." ]; then
    exit 1
fi
cat "$TIMEFILE"

/usr/local/bin/junit-script-output \
    typecheck-final \
    /usr/bin/time -o "$TIMEFILE" ./scripts/bin/typecheck 2>&1 | tee "$OUT"
if [ "$(cat "$OUT")" != "No errors! Great job." ]; then
    exit 1
fi
cat "$TIMEFILE"


# Make sure we are not order dependent
get_seeded_random() {
    seed="$1"
    openssl enc -aes-256-ctr -pass pass:"$seed" -nosalt \
        </dev/zero 2>/dev/null
}
for i in $(seq 10); do
  SAVED_FILE_LIST=$(mktemp)
  FILE_LIST=build/sorbet_file_lists/RUBY_TYPER
  cp "$FILE_LIST" "$SAVED_FILE_LIST"
  SEED=$(cat ../ci/stripe-internal-sorbet-pay-server-random)
  sort --random-source=<(get_seeded_random "$SEED$i") -R "$SAVED_FILE_LIST" > "$FILE_LIST"
  /usr/local/bin/junit-script-output \
      typecheck-random \
      /usr/bin/time -o "$TIMEFILE" ./scripts/bin/typecheck 2>&1 | tee "$OUT"
  if [ "$(cat "$OUT")" != "No errors! Great job." ]; then
     exit 1
  fi
  cat "$TIMEFILE"
  mv "$SAVED_FILE_LIST" "$FILE_LIST"
done


if [ "$RECORD_STATS" ]; then
    t_user="$(grep user "$TIMEFILE" | cut -d ' ' -f 2)"
    t_wall="$(grep wall "$TIMEFILE" | cut -d ' ' -f 2)"
    veneur-emit -hostport veneur-srv.service.consul:8200 -debug -timing "$t_wall"s -name ruby_typer.payserver.prod_run.seconds
    veneur-emit -hostport veneur-srv.service.consul:8200 -debug -timing "$t_user"s -name ruby_typer.payserver.prod_run.cpu_seconds
fi

(
    cd -

    # Ship a version with debug assertions and counters, as well.
    /usr/local/bin/junit-script-output \
        release-build \
        bazel build main:sorbet --config=stripeci --config=release-debug-linux
    cp bazel-bin/main/sorbet /build/bin/sorbet.dbg
)


# Run 2: Make sure we don't crash on all of pay-server with ASAN on
ASAN_OPTIONS=detect_leaks=0
export ASAN_OPTIONS
UBSAN_OPTIONS=print_stacktrace=1
export UBSAN_OPTIONS
LSAN_OPTIONS=verbosity=1:log_threads=1
export LSAN_OPTIONS

(
    cd -
    /usr/local/bin/junit-script-output \
        sanitized-build \
        bazel build main:sorbet --config=stripeci --config=release-sanitized-linux
    cp bazel-bin/main/sorbet /build/bin/sorbet.san
)

# Disable leak sanatizer. Does not work in docker
# https://github.com/google/sanitizers/issues/764
/usr/local/bin/junit-script-output \
    typecheck-sanitized \
    /usr/bin/time -o "$TIMEFILE" \
    ./scripts/bin/typecheck --suppress-non-critical --typed=strict \
    --statsd-host=veneur-srv.service.consul --statsd-prefix=ruby_typer.payserver --counters \
    --metrics-file=metrics.json --metrics-prefix=ruby_typer.payserver --metrics-repo=stripe-internal/sorbet --metrics-sha="$GIT_SHA" --error-white-list=1000

cat "$TIMEFILE"

if [ "$RECORD_STATS" ]; then
    t_user="$(grep user "$TIMEFILE" | cut -d ' ' -f 2)"
    t_wall="$(grep wall "$TIMEFILE" | cut -d ' ' -f 2)"
    veneur-emit -hostport veneur-srv.service.consul:8200 -debug -timing "$t_wall"s -name ruby_typer.payserver.full_run.seconds
    veneur-emit -hostport veneur-srv.service.consul:8200 -debug -timing "$t_user"s -name ruby_typer.payserver.full_run.cpu_seconds
    LOG_DIR="/log/persisted/$(date "+%Y%m%d")/$PAY_SERVER_SHA/"
    mkdir -p "$LOG_DIR"
    cp metrics.json "$LOG_DIR"
fi
