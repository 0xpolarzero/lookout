#!/bin/bash
# Idle is 0%. Launches the release build on the demo data (`--demo agents`: a working session, so its ring is turning),
# lets it settle (until its CPU time has stopped moving), then reads the process's cumulative CPU time at the start and
# end of a window and asserts the average stays under the limit, at rest and kept open (`--open`), on the right edge and
# along the top (the full-width strip is where the window grows). The demo does not poll or watch Claude's files, so this
# measures the bar itself: the ring, the clock, the hover trigger.
#
# What is measured has to have a ring that is looping. The app says so on stdout (`--lifecycle`, for this script only):
# `lifecycle: sessions=S working=W rings=R showing=0|1 reduceMotion=0|1`, once after a few seconds and again whenever that
# changes. The script fails when no session works, no ring loops or Reduce Motion is on, at the start or at any moment of the
# window: a locked or covered screen and Reduce Motion each stop the bar's animation, and a number from a bar that stands
# still proves nothing. ALLOW_HIDDEN=1 turns that failure into a warning.
#
# A sample that is missing or malformed, a window that is not positive or a CPU time that goes backwards is a failure,
# never a 0%. WindowServer's share over the same window is printed apart and is not part of the verdict: it draws the
# ring. To say what the ring costs it, the bar is measured once more on `--demo busy`, which has no working session, and
# the difference is printed.
#
# What it does not measure: the network, notifications, the updater's loop, Claude's files changing under the watchers,
# typing, hovering and scrolling. Those are for Instruments by hand.
#
# This puts the bar on screen for about two minutes, so it is for the final gate, not for every change.
#
#   scripts/idle-cpu.sh                 build (release) and measure
#   LIMIT=0.2 WINDOW=60 EDGES="right top bottom left" scripts/idle-cpu.sh
#   SKIP_BUILD=1 scripts/idle-cpu.sh    use the release build as it is
set -u
cd "$(dirname "$0")/.."

limit=${LIMIT:-0.1}     # percent of one core
settle=${SETTLE:-5}     # seconds between launch and the wait for the CPU time to stop moving
quiet_for=${QUIET_FOR:-3}   # whole seconds the CPU time must not move before the window begins (ps reports hundredths)
quiet_max=${QUIET_MAX:-40}  # whole seconds that wait takes at most
window=${WINDOW:-30}    # seconds between the two samples
edges=${EDGES:-"right top"}
bin=.build/release/Lookout

number() { [[ "$1" =~ ^[0-9]+(\.[0-9]+)?$ ]]; }
for value in "$limit" "$settle" "$window"; do
    number "$value" || { echo "idle-cpu: LIMIT, SETTLE and WINDOW are numbers ('$value' is not)"; exit 2; }
done
for value in "$quiet_for" "$quiet_max"; do
    [[ "$value" =~ ^[0-9]+$ ]] || { echo "idle-cpu: QUIET_FOR and QUIET_MAX are whole numbers ('$value' is not)"; exit 2; }
done
awk -v limit="$limit" -v window="$window" 'BEGIN { exit !(limit > 0 && window > 0) }' || { echo "idle-cpu: LIMIT and WINDOW must be above 0"; exit 2; }
for edge in $edges; do
    case "$edge" in left | right | top | bottom) ;; *) echo "idle-cpu: EDGES are left, right, top or bottom ('$edge' is not)"; exit 2 ;; esac
done

if [ "${SKIP_BUILD:-0}" != "1" ]; then
    swift build -c release >/dev/null || { echo "idle-cpu: release build failed"; exit 2; }
fi
[ -x "$bin" ] || { echo "idle-cpu: $bin not found"; exit 2; }

# cpu_seconds <pid>: cumulative CPU time, from ps's [[H:]M:]S.cc. Prints nothing, and fails, when there is none to read.
cpu_seconds() {
    local text
    text=$(ps -o cputime= -p "$1" 2>/dev/null | tr -d ' ') || return 1
    [[ "$text" =~ ^[0-9]+(:[0-9]+){0,2}(\.[0-9]+)?$ ]] || return 1
    awk -v t="$text" 'BEGIN {
        n = split(t, p, ":"); s = 0
        for (i = 1; i <= n; i++) s = s * 60 + p[i]
        printf "%.2f\n", s
    }'
}

# ring_problem <first>: why the rings were not looping at some point since the <first>th report of the app (the last report
# before a window is the state it begins in), or nothing when they were. A report that never came is a problem too.
ring_problem() {
    awk -v first="$1" '
        /^lifecycle:/ {
            n++
            if (n < first) next
            rings = showing = reduce = ""
            for (i = 2; i <= NF; i++) {
                split($i, kv, "=")
                if (kv[1] == "rings") rings = kv[2]
                else if (kv[1] == "showing") showing = kv[2]
                else if (kv[1] == "reduceMotion") reduce = kv[2]
            }
            seen = 1
            if (reduce == "1") { print "Reduce Motion is on: the rings are static, so the number would mean nothing (turn it off in System Settings)"; exit }
            if (rings + 0 < 1) { print "no ring is looping (rings=" rings ", window showing=" showing "): locked or asleep screen, or a covered bar"; exit }
        }
        END { if (!seen) print "the app made no report of its rings" }
    ' "$out"
}

out=$(mktemp)
pid=
# stop_app: ends the app a measure launched, and waits for it, so none outlives its measure or reaches the next one's window.
stop_app() {
    [ -n "$pid" ] || return 0
    kill "$pid" 2>/dev/null
    wait "$pid" 2>/dev/null
    pid=
}
cleanup() {
    stop_app
    rm -f "$out"
}
trap cleanup EXIT

failed=0
scenario=agents
last_ws=0

# measure <label> <edge> [launch argument]: one launch, one verdict. However it ends, the app is stopped.
measure() {
    sample "$@"
    stop_app
    # The next launch starts from a clean slate, not beside the previous one's window.
    sleep 1
}

sample() {
    local label=$1 edge=$2; shift 2
    : >"$out"
    "$bin" --demo "$scenario" --lifecycle --edge "$edge" "$@" >"$out" 2>&1 &
    pid=$!
    sleep "$settle"
    if ! kill -0 "$pid" 2>/dev/null; then
        echo "idle-cpu: $label $edge: Lookout exited during the first $settle seconds"
        failed=1
        return
    fi
    # Launching costs a second of CPU or more, longer on a busy machine and longer still when the bar opens at once (--open:
    # the whole hub is built and its avatars asked for): the window starts once the CPU time has not moved for a few seconds,
    # so it never holds a start-up that was still going. At most `quiet_max` seconds are waited.
    local still=0 last now_cpu waited=0
    last=$(cpu_seconds "$pid") || last=
    while [ "$still" -lt "$quiet_for" ] && [ "$waited" -lt "$quiet_max" ]; do
        sleep 1
        waited=$((waited + 1))
        now_cpu=$(cpu_seconds "$pid") || now_cpu=
        if [ -n "$now_cpu" ] && [ "$now_cpu" = "$last" ]; then still=$((still + 1)); else still=0; fi
        last=$now_cpu
    done
    if [ "$still" -lt "$quiet_for" ]; then
        echo "idle-cpu: $label $edge: the CPU time was still moving $quiet_max s after the start-up (the window begins anyway)"
    fi
    if [ "$scenario" = agents ] && ! grep -q 'lifecycle: sessions=[0-9]* working=[1-9]' "$out"; then
        echo "idle-cpu: $label $edge: no working session on the bar ($(grep 'lifecycle:' "$out" | tail -1 || echo 'no report')): there is no ring to measure"
        failed=1
    fi
    # The reports so far; the window starts from the last of them.
    local reports problem
    reports=$(grep -c '^lifecycle:' "$out")
    if [ "$scenario" = agents ] && problem=$(ring_problem "$reports") && [ -n "$problem" ]; then
        echo "idle-cpu: $label $edge: $problem"
        if [ "${ALLOW_HIDDEN:-0}" != "1" ]; then
            failed=1
            return
        fi
    fi
    local ws; ws=$(pgrep -x WindowServer | head -1)
    local app0 app1 ws0 ws1
    app0=$(cpu_seconds "$pid") || { echo "idle-cpu: $label $edge: no CPU sample of Lookout at the start"; failed=1; return; }
    ws0=$(cpu_seconds "${ws:-0}") || ws0=
    sleep "$window"
    if ! kill -0 "$pid" 2>/dev/null; then
        echo "idle-cpu: $label $edge: Lookout exited while it was measured"
        failed=1
        return
    fi
    app1=$(cpu_seconds "$pid") || { echo "idle-cpu: $label $edge: no CPU sample of Lookout at the end"; failed=1; return; }
    ws1=$(cpu_seconds "${ws:-0}") || ws1=
    # Nothing may have stopped the rings while the window ran: a stretch with none looping costs nothing and passes for free.
    if [ "$scenario" = agents ] && problem=$(ring_problem "$reports") && [ -n "$problem" ]; then
        echo "idle-cpu: $label $edge: $problem (during the measurement)"
        [ "${ALLOW_HIDDEN:-0}" = "1" ] || failed=1
    fi
    if [ -n "$ws0" ] && [ -n "$ws1" ]; then
        last_ws=$(awk -v w0="$ws0" -v w1="$ws1" -v window="$window" 'BEGIN { printf "%.2f", (w1 - w0) / window * 100 }')
    else
        last_ws="n/a"
    fi
    awk -v label="$label $edge" -v window="$window" -v limit="$limit" -v a0="$app0" -v a1="$app1" -v ws="$last_ws" 'BEGIN {
        if (!(window > 0) || a1 < a0) {
            printf "%-12s FAIL: a window of %s s and CPU time going from %s to %s are no measurement\n", label, window, a0, a1
            exit 1
        }
        app = (a1 - a0) / window * 100
        verdict = app < limit ? "ok" : "FAIL"
        printf "%-12s Lookout %.3f%% (limit %s%%)  WindowServer %s%% (all clients)  %s\n", label, app, limit, ws, verdict
        exit app < limit ? 0 : 1
    }' || failed=1
}

ring_ws=
for edge in $edges; do
    measure rest "$edge"
    [ -z "$ring_ws" ] && ring_ws=$last_ws
    measure open "$edge" --open
done

# What the ring costs: the same bar at rest with no working session, WindowServer's share beside the first one's.
scenario=busy
measure "no ring" "${edges%% *}"
awk -v ring="$ring_ws" -v none="$last_ws" 'BEGIN {
    if (ring == "n/a" || none == "n/a") { print "ring: WindowServer not sampled"; exit }
    printf "ring: WindowServer %.2f%% with a working session, %.2f%% without (all clients; %+.2f%%)\n", ring, none, ring - none
}'

exit $failed
