#!/bin/bash
# Runs the test suite as CI does (release.yml and test.yml), writing the output to test.log.
# The summary line is required: a test process that ends partway through can still exit 0, and a run that stopped
# early must never count as a pass.
set -euo pipefail
cd "$(dirname "$0")/.."
swift test 2>&1 | tee test.log
grep -Eq "Test run with [0-9]+ tests? .*passed" test.log || { echo "::error::The test run ended without its summary"; exit 1; }
