#!/bin/zsh
# Runs mMac's UI tests N times in a row (default 3) and checks that they leave mMac's real
# defaults, the com.domalhambra.mmac domain, exactly as they were: the same keys and values.
#
#   mac/scripts/ui-tests.sh [N] [extra xcodebuild arguments, such as -only-testing:…]
#
# Each run goes under `caffeinate -d`, so the display neither sleeps nor locks, and is stopped
# after 15 minutes. The script stops at the first failed run. It exits 0 only when every run
# passed and the defaults are unchanged. It only reads the real domain, with `defaults export`.
# Logs and the two exports go to .cache/ui-tests/ at the repository root.
set -u

readonly DOMAIN=com.domalhambra.mmac
readonly WATCHDOG=900
repository=${0:A:h:h:h}
runs=${1:-3}
[[ $# -gt 0 ]] && shift
if [[ ! $runs == <1-> ]]; then
  print -u2 "Usage: $0 [N] [extra xcodebuild arguments]. N is a whole number of runs, 1 or more."
  exit 2
fi

export MUSE_BIN="$(command -v muse)"
if [[ -z $MUSE_BIN ]]; then
  print -u2 "muse is not on PATH. The echo test needs the installed Muse Code CLI."
  exit 2
fi
# xcodebuild passes TEST_RUNNER_ variables to the test runner without the prefix.
export TEST_RUNNER_MUSE_BIN=$MUSE_BIN

out=$repository/.cache/ui-tests
mkdir -p $out
cd $repository

# A domain that does not exist yet exports as nothing, so a run that creates it shows as a change.
export_defaults() { defaults export $DOMAIN - 2>/dev/null || true; }

export_defaults > $out/defaults-before.plist

failed=0
for (( run = 1; run <= runs; run++ )); do
  log=$out/run-$run.log
  print "== Run $run of $runs ($log)"
  caffeinate -d xcodebuild test -project mac/mMac.xcodeproj -scheme mMac -derivedDataPath .cache/mmac \
    -destination 'platform=macOS' "$@" > $log 2>&1 &
  pid=$!
  start=$SECONDS
  while kill -0 $pid 2>/dev/null; do
    if (( SECONDS - start > WATCHDOG )); then
      print "Run $run passed $WATCHDOG seconds. Stopping it." | tee -a $log
      pkill -P $pid
      kill $pid 2>/dev/null
      break
    fi
    sleep 5
  done
  wait $pid
  code=$?
  grep -E "Test Case .*(passed|failed)|Executed [0-9]+ tests?," $log | grep -v "Executed 0 tests" | sort -u
  if (( code != 0 )) || ! grep -q '\*\* TEST SUCCEEDED \*\*' $log; then
    print "Run $run failed (xcodebuild exit $code). Stopping."
    failed=1
    break
  fi
  print "Run $run passed."
done

export_defaults > $out/defaults-after.plist
print "== $DOMAIN, before and after"
if diff $out/defaults-before.plist $out/defaults-after.plist; then
  print "Unchanged: the same keys and values."
else
  print "Changed: the lines above differ."
  failed=1
fi

exit $failed
