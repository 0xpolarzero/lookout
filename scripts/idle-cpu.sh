#!/bin/bash
# Gate 5 of DESIGN.md section 9 (the rules are section 8): idle is 0%. Launches the release build on the demo data with
# its real lifecycle (`--demo agents --lifecycle`: the demo's working sessions stay on the bar, so the rings are breathing
# and their rows tick; polling, with every request failing at once; the Claude watchers and their reads on an empty
# temporary folder, whose answer is not applied: it would take the demo's sessions away), lets it settle (until its CPU time has stopped moving), then reads the
# process's cumulative CPU time at the start and end of a window and asserts the average stays under the limit, at rest
# and kept open (`--open`), on the right edge and along the top (the full-width strip is where the window grew).
#
# What is measured has to have a ring that is looping. The app says on stdout how many sessions it has, how many work, how
# many rings have their animation attached, whether one of its windows is showing and whether Reduce Motion is on
# (`lifecycle: sessions=S working=W rings=R showing=0|1 reduceMotion=0|1`, once after a few seconds and again whenever
# that changes). The script fails when no ring loops, or Reduce Motion is on, at the start or at any moment of the window:
# a verdict from a bar with no moving ring, or one nobody can see, proves nothing (a locked or asleep screen, or a covered
# bar, removes the animation, and the window list, which lists covered windows too, cannot say so). ALLOW_HIDDEN=1 turns
# that failure into a warning. A sample that is missing or malformed, a window that is not positive or a CPU time that goes
# backwards is a failure, never a 0%.
#
# WindowServer's share over the same window is printed apart and is not part of the verdict: it draws the rings. To say
# what they cost it is measured once more on `--demo busy`, which has no working session, and the difference is printed.
#
# Polling is measured once more with GitHub's answers served from memory (`--canned`: a quiet account's, sized as GitHub sizes
# them, each with an ETag, and a 304 for every request that has it; the first poll is the full answers, the rest the 304s the
# shipped app gets at rest). It polls every 5 seconds so that a window holds several, and what it costs over the plain run at
# rest (the rings, the clock) is scaled to the default minute and added to that: what a poll's requests, cache and
# bookkeeping cost at rest, which the other runs (every request failing) do not reach. The rest of the process does not poll
# faster, so it is not scaled with it.
#
# What it does not measure: the network itself (TLS, the radio), what a changed answer costs to parse and draw,
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
# The canned polling's run polls faster than the default: what it costs over `baseline` (the plain run's figure, in percent)
# is multiplied by `scale` before it is judged, and `baseline` is not.
scale=1
baseline=0
last_app=0

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
            kill "$pid" 2>/dev/null; wait "$pid" 2>/dev/null; pid=
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
    # Nothing may have hidden the rings while the window ran: a stretch with none looping costs nothing and passes for free.
    if [ "$scenario" = agents ] && problem=$(ring_problem "$reports") && [ -n "$problem" ]; then
        echo "idle-cpu: $label $edge: $problem (during the measurement)"
        [ "${ALLOW_HIDDEN:-0}" = "1" ] || failed=1
    fi
    if [ -n "$ws0" ] && [ -n "$ws1" ]; then
        last_ws=$(awk -v w0="$ws0" -v w1="$ws1" -v window="$window" 'BEGIN { printf "%.2f", (w1 - w0) / window * 100 }')
    else
        last_ws="n/a"
    fi
    last_app=$(awk -v window="$window" -v a0="$app0" -v a1="$app1" 'BEGIN { printf "%.4f", (a1 - a0) / window * 100 }')
    awk -v label="$label $edge" -v window="$window" -v limit="$limit" -v a0="$app0" -v a1="$app1" -v ws="$last_ws" -v scale="$scale" -v base="$baseline" 'BEGIN {
        if (!(window > 0) || a1 < a0) {
            printf "%-12s FAIL: a window of %s s and CPU time going from %s to %s are no measurement\n", label, window, a0, a1
            exit 1
        }
        app = (a1 - a0) / window * 100
        if (scale != 1) app = base + (app > base ? (app - base) * scale : 0)
        verdict = app < limit ? "ok" : "FAIL"
        note = scale == 1 ? "" : sprintf(" (%.3f%% at rest, the cost of polling scaled by %.3f to the default)", base, scale)
        printf "%-12s Lookout %.3f%% (limit %s%%)%s  WindowServer %s%% (all clients)  %s\n", label, app, limit, note, ws, verdict
        exit app < limit ? 0 : 1
    }' || failed=1
    kill "$pid" 2>/dev/null
    wait "$pid" 2>/dev/null
    pid=
    # The next launch starts from a clean slate, not beside the previous one's window.
    sleep 1
}

ring_ws=
rest_app=
for edge in $edges; do
    measure rest "$edge"
    [ -z "$ring_ws" ] && ring_ws=$last_ws
    [ -z "$rest_app" ] && rest_app=$last_app
    measure open "$edge" --open
done

# Polling with answers (304s) at rest: the app polls every 5 s here (`Store.cannedPollInterval`), the default is 60.
scale=$(awk 'BEGIN { printf "%.4f", 5 / 60 }')
baseline=$rest_app
measure "polling" "${edges%% *}" --canned
scale=1
baseline=0

# What the rings cost: the same bar at rest with no working session, WindowServer's share beside the first one's.
scenario=busy
first_edge=${edges%% *}
measure "no ring" "$first_edge"
awk -v ring="$ring_ws" -v none="$last_ws" 'BEGIN {
    if (ring == "n/a" || none == "n/a") { print "rings: WindowServer not sampled"; exit }
    printf "rings: WindowServer %.2f%% with working sessions, %.2f%% without (all clients; %+.2f%%)\n", ring, none, ring - none
}'

exit $failed
