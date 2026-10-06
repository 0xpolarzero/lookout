#!/bin/bash
# Gate 5 of DESIGN.md section 9 (the rules are section 8): idle is 0%. Launches the release build on the demo data with
# its real lifecycle (`--demo agents --lifecycle`: the demo's working sessions stay on the bar, so the rings are breathing
# and their rows tick; polling, with every request failing at once; the Claude watchers and their reads on an empty
# temporary folder, whose answer is not applied: it would take the demo's sessions away), lets it settle, then reads the
# process's cumulative CPU time at the start and end of a window and asserts the average stays under the limit, at rest
# and kept open (`--open`), on the right edge and along the top (the full-width strip is where the window grew).
#
# What is measured has to have a ring: the app says on stdout how many sessions it has and how many work, and the script
# fails when none does (a verdict from a bar with no ring proves nothing, as one from a bar nobody can see does not).
#
# WindowServer's share over the same window is printed apart and is not part of the verdict: it draws the rings. To say
# what they cost it is measured once more on `--demo busy`, which has no working session, and the difference is printed.
#
# It needs the bar on screen: with the screen locked or asleep, or the bar covered, the ring's animation is removed and
# any number would be about 0%. So the script checks that the bar's window is on screen and fails when it is not;
# ALLOW_HIDDEN=1 turns that into a warning.
#
# What it does not measure: the network (every request fails at once, so nothing is parsed or drawn from an answer),
# notifications, the updater's loop, a real Claude app's files changing under the watchers, a transcript being read,
# typing, hovering and scrolling. Those are covered by the rules of section 8 and by Instruments by hand.
#
# This puts the bar on screen for about three minutes, so it is for the final gate, not for every change.
#
#   scripts/idle-cpu.sh                 build (release) and measure
#   LIMIT=0.2 WINDOW=60 EDGES="right top bottom left" scripts/idle-cpu.sh
#   SKIP_BUILD=1 scripts/idle-cpu.sh    use the release build as it is
set -u
cd "$(dirname "$0")/.."

limit=${LIMIT:-0.1}     # percent of one core
settle=${SETTLE:-5}     # seconds between launch and the first sample
window=${WINDOW:-30}    # seconds between the two samples
edges=${EDGES:-"right top"}
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

# on_screen <pid>: how many windows of the process are on screen and not transparent (0 when the screen is locked).
on_screen() {
    osascript -l JavaScript -e '
        function run(argv) {
            ObjC.import("CoreGraphics")
            const pid = Number(argv[0])
            const windows = ObjC.deepUnwrap(ObjC.castRefToObject($.CGWindowListCopyWindowInfo($.kCGWindowListOptionOnScreenOnly, 0)))
            return String(windows.filter(w => w.kCGWindowOwnerPID === pid && w.kCGWindowAlpha > 0).length)
        }' "$1" 2>/dev/null || echo 0
}

# The Claude app's folders, empty: the watchers have something to watch and nothing happens in it.
claude_root=$(mktemp -d)
mkdir -p "$claude_root/claude-code-sessions" "$claude_root/Local Storage/leveldb"

out=$(mktemp)
pid=
cleanup() {
    [ -n "$pid" ] && kill "$pid" 2>/dev/null
    rm -rf "$claude_root" "$out"
}
trap cleanup EXIT

failed=0
scenario=agents
last_ws=0

# measure <label> <edge> [launch argument]: one launch, one verdict.
measure() {
    local label=$1 edge=$2; shift 2
    : >"$out"
    LOOKOUT_CLAUDE_ROOT=$claude_root "$bin" --demo "$scenario" --lifecycle --edge "$edge" "$@" >"$out" 2>&1 &
    pid=$!
    sleep "$settle"
    if ! kill -0 "$pid" 2>/dev/null; then
        echo "idle-cpu: $label $edge: Lookout exited during the first $settle seconds"
        failed=1
        return
    fi
    if [ "$scenario" = agents ] && ! grep -q 'lifecycle: sessions=[0-9]* working=[1-9]' "$out"; then
        echo "idle-cpu: $label $edge: no working session on the bar ($(grep 'lifecycle:' "$out" || echo 'no report')): there is no ring to measure"
        failed=1
    fi
    if [ "$(on_screen "$pid")" = "0" ]; then
        echo "idle-cpu: $label $edge: the bar's window is not on screen (locked or asleep screen, or covered): the rings aren't drawing, so a number would mean nothing"
        [ "${ALLOW_HIDDEN:-0}" = "1" ] || failed=1
    fi
    local ws; ws=$(pgrep -x WindowServer | head -1)
    local app0 app1 ws0 ws1
    app0=$(cpu_seconds "$pid"); ws0=$(cpu_seconds "${ws:-0}")
    sleep "$window"
    if ! kill -0 "$pid" 2>/dev/null; then
        echo "idle-cpu: $label $edge: Lookout exited while it was measured"
        failed=1
        return
    fi
    app1=$(cpu_seconds "$pid"); ws1=$(cpu_seconds "${ws:-0}")
    last_ws=$(awk -v w0="${ws0:-0}" -v w1="${ws1:-0}" -v window="$window" 'BEGIN { printf "%.2f", (w1 - w0) / window * 100 }')
    awk -v label="$label $edge" -v window="$window" -v limit="$limit" -v a0="$app0" -v a1="$app1" -v w0="${ws0:-0}" -v w1="${ws1:-0}" 'BEGIN {
        app = (a1 - a0) / window * 100; server = (w1 - w0) / window * 100
        verdict = app < limit ? "ok" : "FAIL"
        printf "%-12s Lookout %.3f%% (limit %s%%)  WindowServer %.2f%% (all clients)  %s\n", label, app, limit, server, verdict
        exit app < limit ? 0 : 1
    }' || failed=1
    kill "$pid" 2>/dev/null
    wait "$pid" 2>/dev/null
    pid=
    # The next launch starts from a clean slate, not beside the previous one's window.
    sleep 1
}

ring_ws=
for edge in $edges; do
    measure rest "$edge"
    [ -z "$ring_ws" ] && ring_ws=$last_ws
    measure open "$edge" --open
done

# What the rings cost: the same bar at rest with no working session, WindowServer's share beside the first one's.
scenario=busy
first_edge=${edges%% *}
measure "no ring" "$first_edge"
awk -v ring="$ring_ws" -v none="$last_ws" 'BEGIN { printf "rings: WindowServer %.2f%% with working sessions, %.2f%% without (all clients; %+.2f%%)\n", ring, none, ring - none }'

exit $failed
