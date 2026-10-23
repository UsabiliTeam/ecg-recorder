#!/bin/sh
# Test runner.
#   tools/test.sh                     all logic tests on the Mac (swift test, no simulator) - use this while working
#   tools/test.sh ReliabilityTests    one class (or Class/testName) on the Mac
#   tools/test.sh --sim [Class]       same tests inside the iOS Simulator (slower; run before finishing a change)
# The Mac package (Package.swift) compiles the same source files as the app, minus UI/Bluetooth code.
cd "$(dirname "$0")/.." || exit 1
if [ "$1" = "--sim" ]; then
  shift
  DEST='platform=iOS Simulator,name=iPhone 17'
  ONLY=""
  [ -n "$1" ] && ONLY="-only-testing:ECGRecorderTests/$1"
  xcodebuild build-for-testing -project ECGRecorder.xcodeproj -scheme ECGRecorder -destination "$DEST" \
    CODE_SIGNING_ALLOWED=NO -quiet 2>&1 | grep -E "error:|BUILD FAILED"
  xcodebuild test-without-building -project ECGRecorder.xcodeproj -scheme ECGRecorder -destination "$DEST" \
    $ONLY CODE_SIGNING_ALLOWED=NO 2>&1 | grep -E "error:|Test Case.*failed|Executed [0-9]+ tests?, with .* in .* \(.*\) seconds$|TEST (SUCCEEDED|FAILED)" | tail -8
else
  FILTER=""
  [ -n "$1" ] && FILTER="--filter $1"
  swift test $FILTER 2>&1 | sed 's/\x1b\[[0-9;]*m//g' | grep -E "error:|Test Case.*failed|Executed [0-9]+ tests?, with .* in .* \(.*\) seconds$|Build complete|Compiling|fatal" | tail -8
fi
