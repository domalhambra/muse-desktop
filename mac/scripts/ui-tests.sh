#!/bin/zsh
# Runs mMac's UI tests N times in a row (default 3) and checks that they leave mMac's real
# defaults, the com.domalhambra.mmac domain, exactly as they were: the same keys and values.
#
#   mac/scripts/ui-tests.sh [N] [extra xcodebuild arguments, such as -only-testing:…]
#
# Each run goes under `caffeinate -d`, so the display neither sleeps nor locks, and is stopped
# after 15 minutes. The script stops at the first failed run. It exits 0 only when every run
# passed and the defaults are unchanged. It only reads the real domain, with `defaults export`.
# Logs and the two exports go to .cache/ui-tests/ at the repository root: run-N.log is xcodebuild's
# output for run N. The folder run-N/ holds that run's activity: each test's fake-backend requests
# (<testName>-requests.jsonl, which the fake backend copies there),
# mMac's own log lines at debug level (app.log, from `log stream`) and the result bundle
# (result.xcresult). A new run replaces the folder's bundle and log.
#
# A timeout or Ctrl-C stops the run and everything it started: launchd starts mMac, its backend
# and mMacUITests-Runner, so they outlive xcodebuild unless they are stopped by name. That stops
# any mMac running from this checkout's .cache/mmac build, a test's or not.
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

# What a run starts, by command line: the built app and test runner, and the fake backend.
readonly started_by_runs=(
  "$repository/.cache/mmac/Build/Products/"
  "mMacUITests-Runner"
  "$repository/mac/Fixtures/fake-backend.mjs"
)
pid=""
# The `log stream` that records mMac's log lines for the current run.
log_pid=""

# Stops the current run's `log stream`, if one runs. Safe to call twice.
stop_log_stream() {
  if [[ -n $log_pid ]]; then
    kill -TERM $log_pid 2>/dev/null
    wait $log_pid 2>/dev/null
    log_pid=""
  fi
}
# Stops the current run: xcodebuild and its children, then what launchd started for it. TERM
# first, then KILL for whatever is left after 5 seconds.
stop_run() {
  local pattern
  if [[ -n $pid ]]; then
    pkill -TERM -P $pid 2>/dev/null
    kill -TERM $pid 2>/dev/null
  fi
  for pattern in $started_by_runs; do pkill -TERM -f $pattern 2>/dev/null; done
  sleep 5
  if [[ -n $pid ]]; then
    pkill -KILL -P $pid 2>/dev/null
    kill -KILL $pid 2>/dev/null
  fi
  for pattern in $started_by_runs; do pkill -KILL -f $pattern 2>/dev/null; done
}

trap 'print "Interrupted. Stopping the run."; stop_run; stop_log_stream; exit 130' INT TERM
trap 'stop_log_stream' EXIT

# Writes the domain's export, or the line "(domain absent)" when mMac has no defaults yet, so a
# run that creates them shows as a change. Fails when the export itself fails: that must never
# read as "Unchanged".
export_defaults() {
  local domains
  domains=$(defaults domains) || return 1
  if ! print -r -- $domains | tr -d ' ' | tr ',' '\n' | grep -qxF $DOMAIN; then
    print "(domain absent)"
    return 0
  fi
  defaults export $DOMAIN -
}

# Kills of AutomationModeUI by jetsam in the last 10 minutes. A UI test run fails when macOS
# ends the process that lets XCTest drive the screen. Read only.
print_jetsam_kills() {
  local kills
  kills=$(/usr/bin/log show --last 10m --style compact --predicate \
    'process != "log" AND eventMessage CONTAINS[c] "AutomationModeUI" AND (eventMessage CONTAINS[c] "jetsam" OR eventMessage CONTAINS[c] "memorystatus")' \
    2>/dev/null | grep -v '^Timestamp')
  if [[ -n $kills ]]; then
    print "AutomationModeUI jetsam kills in the last 10 minutes:"
    print -r -- $kills
  else
    print "No AutomationModeUI jetsam kills in the last 10 minutes."
  fi
}

if ! export_defaults > $out/defaults-before.plist; then
  print -u2 "mMac's defaults could not be read before the runs. Nothing ran."
  exit 1
fi

failed=0
# Moves the tests' request logs from the temporary folder into this run's folder.
collect_requests() {
  [[ -n ${requests:-} && -d $requests ]] || return 0
  mv $requests/*-requests.jsonl $activity/ 2>/dev/null
  rm -rf $requests
  requests=""
}

for (( run = 1; run <= runs; run++ )); do
  log=$out/run-$run.log
  activity=$out/run-$run
  print "== Run $run of $runs ($log, $activity/)"
  mkdir -p $activity
  # xcodebuild refuses to write over an existing result bundle.
  rm -rf $activity/result.xcresult
  rm -f $activity/*-requests.jsonl
  /usr/bin/log stream --style compact --level debug --predicate 'subsystem == "com.domalhambra.mmac"' \
    > $activity/app.log 2>&1 &
  log_pid=$!
  # The test runner is sandboxed, so the fake backend writes a copy of each test's request log to
  # a fixed folder in /private/tmp, and this script moves them in.
  requests=/private/tmp/mmac-ui-requests
  rm -rf $requests && mkdir -p $requests
    caffeinate -d xcodebuild test -project mac/mMac.xcodeproj -scheme mMac -derivedDataPath .cache/mmac \
    -destination 'platform=macOS' -resultBundlePath $activity/result.xcresult "$@" > $log 2>&1 &
  pid=$!
  start=$SECONDS
  while kill -0 $pid 2>/dev/null; do
    if (( SECONDS - start > WATCHDOG )); then
      print "Run $run passed $WATCHDOG seconds. Stopping it." | tee -a $log
      stop_run
      stop_log_stream
      collect_requests
      break
    fi
    sleep 5
  done
  wait $pid
  code=$?
  pid=""
  stop_log_stream
  collect_requests
  grep -E "Test Case .*(passed|failed)|Executed [0-9]+ tests?," $log | grep -v "Executed 0 tests" | sort -u
  if (( code != 0 )) || ! grep -q '\*\* TEST SUCCEEDED \*\*' $log; then
    print "Run $run failed (xcodebuild exit $code). Stopping."
    print_jetsam_kills
    failed=1
    break
  fi
  print "Run $run passed."
done

print "== $DOMAIN, before and after"
if ! export_defaults > $out/defaults-after.plist; then
  print "mMac's defaults could not be read after the runs, so they could not be compared."
  failed=1
elif diff $out/defaults-before.plist $out/defaults-after.plist; then
  print "Unchanged: the same keys and values."
else
  print "Changed: the lines above differ."
  failed=1
fi

exit $failed
