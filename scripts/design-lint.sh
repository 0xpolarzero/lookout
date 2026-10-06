#!/bin/bash
# The grep gate of DESIGN.md section 8: forbidden constructs, retired words in UI strings, and hues outside the
# places that own them. Fast, headless; run before a commit. A line (or the one under a comment line saying
# `design-lint: ignore`) is skipped.
set -u
cd "$(dirname "$0")/.."

src=Sources/Lookout
# The dev surfaces (playground, demo data) and the icon keyword table aren't the product's UI.
files=$(find "$src" -name '*.swift' ! -name Playground.swift ! -name Demo.swift ! -name SessionIcons.swift | sort)
failed=0

# scan <rule> <pattern> [excluded file name]: report each matching code line (comments and ignored lines left out).
# With STRINGS=1 the pattern is matched against each string literal alone (never the code between two of them).
scan() {
    local rule=$1 pattern=$2 skip=${3:-}
    local hits
    # shellcheck disable=SC2086
    hits=$(for f in $files; do
        [ "$(basename "$f")" = "$skip" ] && continue
        PAT="$pattern" awk -v file="$f" -v strings="${STRINGS:-0}" '
            BEGIN { pat = ENVIRON["PAT"] }
            function ignored(t) { return t ~ /design-lint: ignore/ }
            { text = $0 }
            text ~ /^[ \t]*\/\// { prev = text; next }
            ignored(text) || ignored(prev) { prev = text; next }
            {
                hit = 0
                if (strings == "1") {
                    rest = text
                    while (match(rest, /"([^"\\]|\\.)*"/)) {
                        if (substr(rest, RSTART, RLENGTH) ~ pat) hit = 1
                        rest = substr(rest, RSTART + RLENGTH)
                    }
                } else if (text ~ pat) hit = 1
                if (hit) print file ":" NR ":" text
                prev = text
            }' "$f"
    done)
    if [ -n "$hits" ]; then
        echo "design-lint: $rule"
        echo "$hits" | sed 's/^/  /'
        failed=1
    fi
}

# Motion and performance (section 8): nothing repeats in SwiftUI, nothing watches globally at rest.
scan "repeating SwiftUI motion (the working arc is Core Animation)" 'repeatForever|TimelineView|Timer\.publish'
scan "global event monitor other than .flagsChanged" 'addGlobalMonitorForEvents' 
scan "no bounce: three speeds, none springy" '[(, ]\.(snappy|bouncy)[,)]|bounce: *0?\.0*[1-9]'
# Type floor: text is 11pt or more (symbols size themselves with Theme.Typography.glyph).
scan "text below 11pt" '\.system\(size: *([0-9]|10)(\.[0-9]+)?[,)]'

# Vocabulary (4.0), in string literals only.
export STRINGS=1
scan "retired word in a string: pending" '[Pp]ending'
scan "retired word in a string: Pinned / Unpin" 'Pinned|Unpin'
scan "retired word in a string: No checks / No CI shown / Make room for this" 'No checks|No CI shown|Make room for this'
# (A session is hidden, not removed; Settings' own "Remove" buttons are for a key and a bot handle.)
scan "retired word in a string: Remove" '^"Remove( a session)?"$' SettingsView.swift
unset STRINGS

# Three hues, one meaning each (principle 3): green is the update-ready tile, clay the Claude pane, purple nothing.
scan "Theme.purple is retired" 'Theme\.purple'
scan "Theme.green outside the update tile" 'Theme\.green' Sessions.swift
scan "Theme.claude outside the Claude settings pane" 'Theme\.claude' SettingsView.swift

# Retired tokens and components.
scan "retired token or component" 'Theme\.raised|Theme\.hover([^A-Za-z]|$)|Radius\.panel|Fill\.faint|(^|[^A-Za-z])(Eyebrow|CountBadge|DotCount|CIDot|Caret)\('

if [ $failed -eq 0 ]; then echo "design-lint: clean"; fi
exit $failed
