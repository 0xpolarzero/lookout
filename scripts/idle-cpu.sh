#!/bin/bash
# Gate 1 of DESIGN.md section 8: idle is 0%. Launches the release build on the demo data (`--demo agents`: working
# sessions, so the rings are breathing), lets it settle, then reads the process's cumulative CPU time at the start and
# end of a window and asserts the average stays under the limit, once with the bar at rest and once kept open
# (`--open`). WindowServer's share over the same window is printed apart: it draws the rings, and is not part of the
# verdict. This puts the bar on screen for about two minutes, so it is for the final gate, not for every change.
#
#   scripts/idle-cpu.sh                 build (release) and measure both
#   LIMIT=0.2 WINDOW=60 scripts/idle-cpu.sh
#   SKIP_BUILD=1 scripts/idle-cpu.sh    use the release build as it is
set -u
cd "$(dirname "$0")/.."

limit=${LIMIT:-0.1}     # percent of one core
settle=${SETTLE:-5}     # seconds between launch and the first sample
window=${WINDOW:-30}    # seconds between the two samples
bin=.build/release/Lookout

if [ "${SKIP_BUILD:-0}" != "1" ]; then
    swift build -c release >/dev/null || { echo "idle-cpu: release build failed"; exit 2; }
fi
[ -x "$bin" ] || { echo "idle-cpu: $bin not found"; exit 2; }

# cpu_seconds <pid>: cumulative CPU time, from ps's [[H:]M:]S.cc.
cpu_seconds() {
    ps -o cputime= -p "$1" 2>/dev/null | awk '{
        n = split($1, t, ":"); s = 0
        for (i = 1; i <= n; i++) s = s * 60 + t[i]
        printf "%.2f\n", s
    }'
}

pid=
cleanup() { [ -n "$pid" ] && kill "$pid" 2>/dev/null; }
trap cleanup EXIT

failed=0

# measure <label> [launch argument]: one launch, one verdict.
measure() {
    local label=$1; shift
    "$bin" --demo agents "$@" >/dev/null 2>&1 &
    pid=$!
    sleep "$settle"
    if ! kill -0 "$pid" 2>/dev/null; then
        echo "idle-cpu: $label: Lookout exited during the first $settle seconds"
        failed=1
        return
    fi
    local ws; ws=$(pgrep -x WindowServer | head -1)
    local app0 app1 ws0 ws1
    app0=$(cpu_seconds "$pid"); ws0=$(cpu_seconds "${ws:-0}")
    sleep "$window"
    if ! kill -0 "$pid" 2>/dev/null; then
        echo "idle-cpu: $label: Lookout exited while it was measured"
        failed=1
        return
    fi
    app1=$(cpu_seconds "$pid"); ws1=$(cpu_seconds "${ws:-0}")
    awk -v label="$label" -v window="$window" -v limit="$limit" -v a0="$app0" -v a1="$app1" -v w0="${ws0:-0}" -v w1="${ws1:-0}" 'BEGIN {
        app = (a1 - a0) / window * 100; server = (w1 - w0) / window * 100
        verdict = app < limit ? "ok" : "FAIL"
        printf "%-8s Lookout %.3f%% (limit %s%%)  WindowServer %.2f%% (all clients)  %s\n", label, app, limit, server, verdict
        exit app < limit ? 0 : 1
    }' || failed=1
    kill "$pid" 2>/dev/null
    wait "$pid" 2>/dev/null
    pid=
    # The next launch starts from a clean slate, not beside the previous one's window.
    sleep 1
}

measure rest
measure open --open

exit $failed
