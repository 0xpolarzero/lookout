# Lookout: design direction ("Quiet by default")

Lookout is a glanceable edge utility. It is looked at for under a second, many times a day, and it answers one question: does anything need me? This document is the single source of truth for the design, and it describes the product as built. Where it conflicts with the code or README, this wins; the README says the same in the user's words.

Spine: **Quiet by default** (radical editing, progressive disclosure, calm empty states). Grafted from **Gauge**: one shared footer, a working mark (first an arc, now a ring: 10.1), one focus-ring recipe, drawn switch, per-surface contrast tests, Settings panes. Grafted from **Quiet Native**: concentric radii, Reduce Transparency and Increase Contrast fallbacks, Differentiate Without Colour, VoiceOver containers/announcements/rotor. Quiet Native's material and light mode are deliberately deferred (section 3.1).

---

## 1. Principles

Each is testable by reading a screenshot or running a check.

1. **Glance, then act.** The bar at rest shows state, never detail: no breakdowns, names or summaries. Test: no text longer than a count appears on the resting bar.
2. **Success is silent, failure is loud.** Passing CI, read items, idle sessions and a healthy sync render with no hue, no number and no chrome. Test: with everything healthy the bar contains no colour other than neutral greys.
3. **Three hues, one meaning each.** Amber = needs you. Red = broken. Blue (accent) = unread/interactive. Green appears in exactly one place (update ready). Nothing else carries a hue: no clay, purple, project colour in the bar, or per-kind colour. Test: grep for `Theme.green|purple|claude` outside the allowed places in 2.1.
4. **State is a shape first, a colour second, never an opacity.** Every state has a distinct silhouette (filled tile, dot, ring, glyph, numeral) and a VoiceOver value. Test: the greyscale render of each bar state is distinguishable; no `.opacity(` on content to signal state.
5. **Never fade content.** A busy, read, pending or searched-over element keeps its full text token. Only a non-text status layer (the working ring) may pulse. Test: ContrastTests pass for every token pair; no dimming of live controls.
6. **Nothing the user aimed at moves.** Bar cells keep their screen position at rest, on hover, in a peek and when kept open (on the sides the first cell; on top and bottom the leading edge of the strip). Test: pixel diff of rest vs open shots (section 9).
7. **One fact, one place, one word.** A fact is stated once (glyph or number or sentence). Vocabulary is fixed (table in 4.0). Test: grep for the retired words in 4.0.
8. **Every hover affordance has a keyboard and VoiceOver path.** Test: every row action and bar cell has an `accessibilityAction`/key; no control exists only on hover.
9. **Empty and error states are content with a cause.** "All caught up" appears only when true. Test: each row of the table in 4.9 has a playground shot.
10. **Idle is 0%.** The only repeating motion is the working ring, drawn by Core Animation. Test: `scripts/idle-cpu.sh` (section 8).

---

## 2. What changes and what is cut

| Element | Decision | Why |
|---|---|---|
| Tile fade/pulse of the whole face; 0.55 pending dim; 0.44 Reduce Motion freeze | Cut. Full-opacity tile; state shown by fill, dot, ring | Letters fell to 1.5-2.8:1; working looked disabled |
| Pending tiles smaller/dimmer + dash separator + "PENDING" | Cut. Same 26 pt tile, group "New activity", standard hairline | Dim means unimportant, the wrong signal |
| Project underline and project colour on the bar | Cut. Project = group gap on the bar, named group header in panels. Colour survives only as a 6 pt dot in group headers and menus, palette of 4 | Hung outside layout, colour-only, collided with CI green |
| CI seal + three coloured dot counts | Cut. One glyph of the worst state + its count only when failing | Said one fact three times; checkmark on a running state lied |
| Asterisk cell | Cut when tiles exist; shown as `tertiary` hover anchor only with zero sessions | Decorative, 30 pt of width |
| Bots count on the bar | Cut from the bar; stays in the Bots tab and the inbox VoiceOver value | Bots are meant to be silent |
| Clay, purple, green, blue-fill status hues; amber for CI running and Bots tab | Cut | One hue, one meaning |
| Inbox kind badge on avatars; StateTag capsule; open-arrow button; mark-read check; three-icon hover capsule | Cut. Kind is a symbol + word in the meta line; one action (Done); row click opens | 6 pt glyph, duplicate information, mixed check/X semantics |
| Two-column focused inbox | Cut. Single column | Down moved sideways |
| Three always-visible expand glyphs | Cut. Section header is the control (click, ⌘1/2/3), chevron on hover/focus only | Read as fullscreen; three identical buttons |
| Fake search (Text + caret) | Replaced by a real `TextField` | Paste, IME, AZERTY dead keys, VoiceOver |
| "Up to date" row, green sync dot | Cut. Healthy = silent; faults = banners + gear badge | Chrome for the common case |
| CI chips, per-state line titles, count column, 4-chip cap, `+N` tooltip | Replaced by failing/running rows and one collapsed Passing row | Hid repos, repeated counts |
| CI/bar dimming (0.4 while searching, 0.5 on pages) | Cut. CI is removed from layout while searching; bar never dims | Live controls below 3:1 |
| Cards, tracked caps eyebrows, restating hints, 9/10/10.5/12.5 pt text | Replaced by grouped forms, sentence-case labels, 11 pt floor | Heavy, low contrast |
| 7-icon repo matrix and 9 pt legend | Replaced by summary + preset pop-up + labelled checkboxes | Memorisation UI |
| Always-visible token field, disabled Save/Add buttons, amber `+` square | Cut; revealed on demand / plain bordered button | Noise for the common case |
| Back chevron + chip tabs on pages; push between sibling panes | Replaced by a segmented title + `Done`; 0.14 s cross-fade | Three overlapping navigations |
| Project initial tiles in New session | Cut. One row with a menu of projects by name | Loudest elements in the hub |
| Keycap borders, SF Rounded keys, bounce, badge pop, `.snappy`, 0.34 s refocus spring | Cut | Web feel; calm utility |
| Hand-painted seam, per-state blurred shadows, `Eyebrow`, `CountBadge`, `DotCount`, `CIDot`, `Caret` | Deleted | Replaced by one outline, static shadow layers, new components |
| Dimmed Done/read rows (0.72 title step) | Cut. Read = regular weight at full `text` | Contrast |
| Bottom-edge reversed list order | Not done | ↑↓ keeps one meaning on every edge |
| Scrolling peeks, a faded last row | Cut. A peek is whole rows and one `+N more` that keeps the hub open on its section | A fade hides content; a scroll view inside a hover panel fights the pointer |
| Tile column in a sessions peek | Cut. The row lights its bar tile, the tile lights its row | The bar's tiles are right there |
| "1 waiting" / "1 failing" beside an open section's rows | Cut. Said in the header only when the section is folded to it | The Waiting for you group and the failing rows already say it |

Added, each earning its place: undo line and ⌘Z; "Done: all read" bulk path; Done sorted by clear time; real search with ⌘F and a visible magnifier; CI rows with failing check names and age; **Mute until it changes** for CI; pinned "Waiting for you" group and a clickable "N waiting"; `+N` overflow tile; sync-fault gear badge and in-list banners; cause-specific empty states; a cue under a list cut at a whole row (`+N more` pages to the rest, `Back to top` at the end); per-row accessibility actions, bar-cell activation, root container, announcements, rotor; Tab ring; Settings panes; repo presets; ContrastTests; idle-CPU script.

**Deliberate behaviour changes** (each has a README line and, where stored, a migration):
bots count off the bar; project colours off the bar (stored colour indices remap into the 4-colour palette; values are kept, not deleted); "Remove" renamed "Hide"; Done sorted by `clearedAt` (nil falls back to `createdAt`); `mutedCI` store; single-column focused inbox; horizontal kept-open geometry (2.3); waiting sessions pinned to the top group in panel and bar; gear click label "Settings"; CI cell click opens checks; peeks never scroll; at most eight sessions listed before `+N`, waiting ones never cut; a muted failure stays in the list, quieted, and out of the bar.

---

## 3. Tokens

All live in `Theme`/`Theme.*` (Theme.swift, Components.swift). A token nothing uses is deleted (there is no `Theme.raised`, `Theme.hover`, card fill, eyebrow/caption/badge font or `Radius.panel`).

### 3.1 Appearance decision

Dark-only, opaque, on purpose. Every status hue and contrast ratio is tuned for dark; light mode doubles the QA surface. All `FloatingPanel`s and their hosting views set `appearance = NSAppearance(named: .darkAqua)` so AppKit children (context menus, pop-ups, field editor, caret, selection, focus ring) match; remove nothing else. The surface stays opaque `Theme.bg`: text never sits on a wallpaper, the shape-only shadow and the bar/peek join depend on it. **Reduce Transparency is therefore a documented no-op.** A material (`NSVisualEffectView` `.popover`, `.behindWindow`, `.active`, resizable `maskImage` clip, `bg`@.72 tint, mask-out shadow, opaque fallback on Reduce Transparency/Increase Contrast) is a gated later experiment, not part of this work. Lookout follows no private text-size setting (macOS has none); rows are sized by line boxes. The accent is a fixed blue rather than `controlAccentColor` on purpose: a user accent of orange or red would collide with amber = needs you and red = broken.

### 3.2 Colour

Contrast computed against the surfaces actually used (sRGB, WCAG relative luminance; `bg` = .078/.078/.086, fills are white-alpha over `bg`).

| Token | Value | Use | on bg | on hover | on tile | on selected |
|---|---|---|---|---|---|---|
| `bg` | rgb .078 .078 .086 (#141416) | hub, peek, page | | | | |
| `rail` | white .025 over `bg` | side-edge bar column | | | | |
| `text` | white .93 | titles, unread and read rows, values | 15.95 | 13.5 | 12.35 | 11.6 |
| `secondary` | white .70 | summaries, ages, status words, hints, form details, gear | 9.34 | 8.25 | 7.69 | 7.30 |
| `tertiary` | white .58 | meta line, placeholders, quiet CI glyph, separators | 6.73 | 6.13 | 5.79 | 5.54 |
| `accent` | rgb .40 .58 1.0 | unread-done dot, focus ring, selection bar, switch on, update glyph | 6.35 | 5.32 | 4.84 | 4.53 |
| `accentText` | rgb .52 .68 1.0 | accent as text (links) | 8.28 | 6.94 | 6.32 | 5.91 |
| `amber` | rgb .99 .74 .27 | needs you: inbox tile, waiting tile, unread dot, "Waiting", sync warning | 10.96 | 9.18 | 8.36 | 7.83 |
| `red` | rgb 1.0 .47 .45 | failing glyph, failing check names, sign-in fault | 7.17 | 6.01 | 5.47 | 5.12 |
| `green` | rgb .32 .82 .50 | update-ready tile fill only | 9.47 | | | |
| `onTint` | black .85 | text/glyph on amber and green fills | 9.95 on amber, 8.81 on green | | | |
| `claude` | rgb .85 .47 .34 | Claude mark in the Claude settings pane only | | | | |

| Surface/line token | Value |
|---|---|
| `Fill.hover` | white .07 (pointer hover only) |
| `Fill.field` | white .06 |
| `Fill.tile` | white .10 (neutral tiles, avatars, bordered buttons) |
| `Fill.selected` | white .12 (keyboard pick, selected tab) |
| `Fill.pressed` | white .15 |
| `Fill.group` | white .045 (settings groups, banners, undo line) |
| `stroke` | white .12, 1 pt (hub outline); decorative, exempt from 3:1 |
| `divider` | white .08, 1 pt |
| `fieldBorder` | white .34, 1 pt (3.11:1 on `bg`); focus: 1.5 pt `accent` + `Fill.field`→white .08 |
| `switchOff` | track white .16 + 1 pt white .34 border |

Neutral tiles (1.3:1 against `bg`) carry a label at 12:1; the tile boundary is not information, so exempt.

**Project palette** (group-header and menu dots only; 6 pt): violet .67/.52/1.0, pink .96/.42/.75, cyan .24/.82/.93, silver .86/.86/.90. Green and lime removed.

**Increase Contrast** (`colorSchemeContrast == .increased`, resolved once into a `Theme.Resolved` environment value; never read per view): `stroke` .28 (2.5:1) and borders 1.5 pt; `divider` .20; `secondary` .86; `tertiary` .80; `red` as text on a chip rgb 1.0 .66 .64 (`Resolved.red`: `Theme.red` falls to 3.22:1 on a pressed ×1.6 fill, this holds 4.63:1); fills ×1.6; focus ring 2 pt; the working ring is `text` instead of `secondary`. **Differentiate Without Colour** (`accessibilityDifferentiateWithoutColor`): the waiting tile gets a 1.5 pt `onTint` inner stroke; the unread dot gets a 1 pt white ring. **Reduce Transparency**: no-op (3.1).

**ContrastTests** (Tests/LookoutTests): composites every foreground token, as the views use it, over every surface token it can land on (bg, rail, hover, field, tile, selected, pressed, popover; amber and green fills for `onTint`) in normal and Increase Contrast sets. Text pairs ≥ 4.5:1, glyph/ring/border pairs ≥ 3:1. The pair list lives in the test; keep it in step with the tokens.

### 3.3 Type

SF Pro (system). SF Rounded only for tile letters. Floor 11 pt; no half-point sizes; `.monospacedDigit()` for counts, ages and elapsed.

| Name | Spec | Use |
|---|---|---|
| `title` | 13 semibold | page, section and group titles; unread row titles |
| `body` | 13 regular | read row titles, form labels, menu labels |
| `control` | 12 medium | tabs, buttons, chips |
| `meta` | 11 regular | second lines, summaries, hints, tooltip detail |
| `label` | 11 semibold, sentence case, `secondary` | group and form section headings (replaces tracked caps) |
| `numeral` | 11 semibold, monospaced digits | counts, ages, elapsed, status words |
| `tile` | 11 bold, rounded | tile letters (the tile is fixed, the font does not scale) |
| `keyhint` | 11 regular, SF Pro, `secondary` | key equivalents as plain text (never SF Rounded: ⌃ must render as ⌃) |

Unread = semibold + dot + VoiceOver value ("Unread"). Read = regular at `text`. Meta line uses `tertiary`; summaries, ages, status words and hints use `secondary`; `tertiary` is never used for a hint on a form.

### 3.4 Space, size, radius

- Space: `hair` 2, `xs` 4, `sm` 6, `md` 8, `lg` 12, `xl` 16.
- Pitch: **36 pt on both axes** for every bar cell (tile 26 centred), the header, one-line rows and the footer. Bar depth 46. Divider slot 19 pt along the axis (9 + 1 + 9), hairline 18 pt long.
- Rows: two-line **44** (inbox, CI, session); session with a task line **60**; menu rows **28**; form rows min **36**.
- Content edge: leading text x = inset 6 + row padding 8 = **14 pt**, used by headers, tabs, dots, group labels, form titles (one `Metrics.contentEdge`). Dot slot 14, avatar 24, trailing age column 36.
- Radii, all `.continuous`, concentric (inner = outer − inset): **hub 16** (bar, peek, expanded: one value, no 20/22 pop); **row 10** (= 16 − 6; also banner, undo line, settings group); **field 8**; **tile and button 7** (26 × .27); **keycap/small chip 4**; capsules for tabs. Delete `Radius.panel`/`lg + 2`. Use `ConcentricRectangle` under `#available(macOS 26, *)` only if it reproduces these numbers; otherwise the formula.
- Widths (`HubGeometry`): peek inbox 400, CI 360, sessions 400, controls 240; kept-open side hub detail 420; horizontal kept-open: left column 420 (inbox + CI), right column 400, gutter 12, max total 860; a focused section is one column: inbox ≤ 560, CI 420, sessions 480; a page is 420 beside the bar and 480 under the strip. Max hub length from `visibleFrame` minus both insets and the Dock/menu bar, never a floor.
- Hit targets: ≥ 24×24 for any control via `.contentShape` without changing the visual; row action buttons 24 visual / 28 hit; tag remove and shortcut reset 24.
- Surface: `bg` fill, 1 pt `stroke` outline, drawn once as one clip + one stroke. Shadows are static shapes in a layer under everything: contact (r2, y1, black .35) always; ambient (r20, y7, black .30) fixed radius, cross-faded by opacity (0 at rest, 1 on peek/open). Radius and offset never animate.

### 3.5 Focus and selection (defined once, `Components.swift`)

- **Pointer hover**: `Fill.hover` only. Cleared on pointer exit unless the last input was keyboard. A key never acts on a row the pointer left.
- **Keyboard pick** (rows): `Fill.selected` + 2 pt × 24 pt `accent` leading bar at x = 2. The bar is 6.35:1 on `bg`.
- **`.focusRing(radius)`**: 1.5 pt `accent` stroke, offset 2 (tiles, icon buttons, tabs, chips, menu rows, fields, switches), drawn from `@FocusState`/Full Keyboard Access focus so Tab shows position. Replaces the white .85 tile ring. Inset (offset 0, radius 10) for rows.
- Text fields: system focus behaviour plus the 1.5 pt `accent` border.

### 3.6 Motion

Three speeds, no bounce anywhere. All through `.motion(_:value:)` / `Theme.Motion.resolve(reduce)` (one entry point). `reduceNow` (NSWorkspace) remains the only non-view path, behind one `Hub.animate(_:body)` helper.

| Name | Curve | Use |
|---|---|---|
| `hover` | easeOut .12 | fills, tints |
| `fade` | easeOut .14 | content in/out, list changes by revision, undo line, sibling page switch, panel first open/last close (8 pt slide) |
| `move` | spring .28, bounce 0 | expand, page slide-in from the gear, focus |
| `close` | spring .20, bounce 0 | collapse |
| `heartbeat` | easeInOut 1.2 s autoreverse, opacity 1.0 ↔ 0.4 | the working ring only |

Rules: animate only what changed spatially or in state; no motion on hover except fills; no motion on poll refresh except row cross-fades. **Reduce Motion**: nothing translates, scales or springs; changes are 0.10 s cross-fades or instant; the ring is static at opacity 1; update download ring is determinate (allowed); the edge-drag glide is skipped (frame set directly). There is no `.snappy`, badge pop, linear tween, fixed transition or push between Settings panes.

`Theme.Timing` (documented, one place): dwell 100 ms (first panel only), section switch instant, leave grace 120 ms, tooltip 400 ms then instant when another tip closed < 600 ms ago.

---

## 4. Components

Shared ones live in Components.swift; each has rest / hover / pressed / picked (focus) / disabled states unless noted. Disabled = no hover fill, label at `tertiary` (never an opacity multiplier below .6).

### 4.0 Vocabulary (grep-enforced)

Inbox tabs: **Needs you / Bots / Done**. Sessions: **Waiting / Working / Finished** (never "done"), groups **Waiting for you / <project> / Scratch / New activity**. CI: **Failing / Running / Passing / No runs** from one table on `CIState` (title, label, symbol, VoiceOver phrase). Actions: **Keep open** (never Pinned/Unpin), **Hide** (never Remove), **Keep** (a session), **Done / Restore**. Retired words in UI strings: pending, Remove (session), Pinned, Unpin, "No checks", "No CI shown" (replaced by "No CI configured"), "Make room for this".

### 4.1 `BarCell` and `StatusTile`

`BarCell`: 36 pt slot, 26 pt tile or glyph, centred; the only element type on the bar. Accessibility: button trait, label, value, hint, action **Show** (keeps the hub open and moves selection and VoiceOver focus to that section). `StatusTile`: 26 pt, radius 7, `Fill.tile`, label `tile` font in `text`, or SF Symbol 12 pt, or emoji.

| State | Tile | Mark | Non-colour cue |
|---|---|---|---|
| Waiting | solid `amber`, `onTint` label | none | whole-tile luminance jump (+ inner stroke under Differentiate) |
| Working (also finished with tasks running) | `Fill.tile`, `text` | **ring**: a full rounded outline 1.5 pt `secondary` (`text` under Increase Contrast), 2 pt outside the tile, concentric (radius 7 + 3.5), breathing on the heartbeat | ring shape + motion (static opacity 1 under Reduce Motion) |
| Finished, unread | `Fill.tile`, `text` | 7 pt `accent` dot on the tile's top-trailing corner (offset +5/−5: the ring's corner when it has one) with 1.5 pt `bg`/`rail` halo | dot shape |
| Idle / read | `Fill.tile`, `text` | none | |

Waiting never shows a ring or a dot; working + unread shows both. Picked/hovered: `.focusRing(7)`. New activity tiles are identical (no shrink, no dim). The ring is a cached tiny image on a `CALayer` driven by `Pulse`; every instance uses one shared `beginTime` (`layer.convertTime(CACurrentMediaTime(), from: nil)` modulo the period) so all rings breathe in phase and a re-render never restarts it; none runs while the window is hidden. The Pulse cache key includes contrast + differentiate state. Waiting/Working/Unread values: `"waiting for you, lcu, 4 minutes"`.

### 4.2 `SectionHeader` (36 pt)

`label`/`title` text, optional single status phrase (only when the section is folded to its header: "1 waiting", "1 failing"; open, its own rows say it), trailing actions. The **whole header is the focus toggle** (pointer cursor, `accessibilityAction("Focus")`, ⌘1/2/3). A `chevron.down`/`chevron.up` (24 pt target, `tertiary`, tooltip "Expand Inbox") appears only on header hover or keyboard focus. A focused section shows `esc` as `keyhint` text beside the title. Trailing slots are reserved per section so tabs and right edge never jump. Title is `.isHeader`.

### 4.3 `Tabs` (inbox filters, Settings panes)

Custom drawn (a non-key panel draws `Picker(.segmented)` grey). Height 24, capsule, `control` 12. Selected = `text` on `Fill.tile`, `.isSelected`; unselected = `secondary`. Container `accessibilityElement(children: .contain)` labelled "Inbox filter". Counts are `numeral` text after the label: Needs you unread in `amber`, Bots unread in `tertiary`, Done none. Badge colour encodes urgency, never selection. On a Settings page ←/→ switch panes.

### 4.4 `Row` (inbox, CI, session)

Fixed 44 pt (session task line adds 16), whole-row `Button`, hover/pick per 3.5, context menu, `.accessibilityElement(children: .combine)`.
`[14 dot slot][24 avatar or glyph] title (line 1) … age (line 1 trailing, 36 pt column) / meta (line 2) … action (line 2 trailing)`.
**Actions sit at the trailing end of line 2**, so title, age and status never disappear. One visible action per row (24 visual / 28 hit circle, `Fill.selected`), shown on hover, keyboard pick **and** VoiceOver focus. Everything else lives in the context menu, a key and `accessibilityAction`s. Tooltip (`.help`): title + first 3 lines of snippet, also for the keyboard-picked row. Every secondary line joins its parts with ` · ` (`lcu · Should updates install…`, `Running swift test · +2 more`).

### 4.5 `IconButton`

24 pt visual, 28 hit, 14 pt glyph `secondary`, hover `Fill.hover` circle, `.focusRing`. Mandatory accessibility label. Outline symbols at rest; `.fill` only for on/active (pin, bookmark).

### 4.6 `Tip`

Kept only for icon-only bar and header controls; anything with visible text uses `.help`. Style after the system tip: popover fill #2B2B2D, radius 7, 1 pt `stroke`, padding 8/4, 12 pt label + 12 pt `secondary` key on one line ("Settings  ⌘,"), 400 ms then instant, also on keyboard focus after 1 s. Never carries primary information.

### 4.7 `MenuRow` and `KeyCap`

`MenuRow` matches NSMenu: 28 pt, 16 pt symbol column, 13 pt label, key equivalent as plain `keyhint` right-aligned, highlight `Fill.selected` + `.focusRing`, arrow-key navigation, Return activates, Esc closes. `KeyCap` survives only for the `esc` hint and footer key hints: SF Pro 11, no stroke, `Fill.tile`, radius 4.

### 4.8 `SwitchStyle`, `FieldStyle`, `SegmentedTabs`

`SwitchStyle`: drawn 32×20 capsule, on = `accent` + white 16 pt knob, off = `switchOff`; independent of key-window state; real `Toggle` for VoiceOver (value On/Off); whole label row is the hit target (≥ 36 pt); `hover` fade, instant under Reduce Motion. `FieldStyle`: 28 pt, radius 8, `Fill.field`, `fieldBorder`; focus per 3.5; secrets are `SecureField`. Buttons: bordered = `Fill.tile` + `fieldBorder`, radius 7, 28 pt, `control` font.

### 4.9 `StatusBanner`, `EmptyBlock`, `UndoLine`

`StatusBanner`: 30 pt, radius 10, `Fill.group`, icon + sentence + up to two text/bordered buttons; used for sync, rate-limit, snooze, Claude notices. `EmptyBlock`: centred two lines, min height 132; line 1 `body` medium `secondary`, line 2 `meta` `tertiary`, optional one bordered button or `accentText` link; no glyph unless it carries a cause. `UndoLine`: 32 pt strip at the bottom of a section, `Fill.group`, radius 10, "Moved to Done · Undo", visible 6 s, ⌘Z works while visible and 30 s after, `fade`, posts a VoiceOver announcement; one-shot timer cancelled on dismiss. Used by Done, Done all, Clear Done, Hide, Mute folder, Mute CI, Stop showing CI, a repository's preset and Stop watching (the last two on the Repositories page).

### 4.10 `SearchField`

SwiftUI `TextField` + `@FocusState` (no NSSearchField; the panel is already key when pinned). Magnifier, 13 pt field, `meta` result summary ("3 items · 2 sessions"), clear (24 pt), `esc` hint. Accessibility: label "Search inbox and sessions", value = summary, announcement on change (debounced 400 ms). The key monitor seeds it (6.2).

### 4.11 `HubFooter` (36 pt, one view on all four edges)

Left: "Checked 2m ago" (`meta`, `tertiary`, minute clock) as a button that checks now (⌘R, tooltip "Check now  ⌘R"); a fault replaces it with the fault text ("Can't sign in to GitHub", red, opens Settings; "2 repositories didn't sync" and "Not syncing", `secondary`; "Checking…"), drawn without the clock; GitHub's rate limit running low adds a quiet warning beside it. No key-hint strip: keys live in tooltips, context menus and the README. Right: **Keep open** (`pin`/`pin.fill`, label "Keep open"/"Stop keeping open") and **Repositories** (`books.vertical`). Settings is the gear cell, which exists once per edge: the rail's last cell on the sides, the strip's trailing cell on top and bottom, aligned with the footer row. Replaces `footer`, `footerDetail` and the strip's trailing group.

---

## 5. Layout per surface

### 5.1 Bar at rest (all four edges)

One order, one pitch: **Inbox, CI, | Sessions…, New session (+), | Update, Gear**. Separators: one hairline grammar (18 pt, `divider`, 9 pt each side); the second hairline appears only when sessions exist. Side edges: 46 pt wide column on `rail` + 1 pt inner-edge hairline, rounded corners away from the screen edge (radius 16); top/bottom: 46 pt deep strip, same cells left to right. Gear is last on every edge. Never dimmed.

- **Inbox cell** (a click goes straight to Needs you with its newest item picked): needs-you count > 0 → solid `amber` tile with the count as 13 bold rounded numeral in `onTint` ("99+" at 11); 0 → `Fill.tile` tile with `tray` 13 pt `secondary`. Same footprint, nothing shifts when the first item arrives. Label "Inbox", value "5 need you, 2 bot items" / "Nothing needs you", hint "Shows the inbox".
- **CI cell** (glyph, no tile; one VoiceOver element "CI, 1 failing, 1 running, 2 passing"): worst un-muted state decides: Failing `xmark.octagon.fill` `red` (the cross cut out of the octagon) with the failing count under it (`numeral`, `red`, "9+" past nine), all inside the 26 pt footprint so the cell never widens; Running `circle.dashed` `secondary`, static, no count; Passing `checkmark.circle` outline `tertiary`, no count; No runs `minus.circle` `tertiary`. Absent when no repo has CI on. Click opens the worst repo's checks (failing first, then most recent); tooltip says so.
- **Session cells**: `StatusTile`s in panel order: Waiting for you, project groups (user's drag order), New activity. Project boundary = extra 8 pt gap (4 pt inside a group). Cap: 8 visible (`SessionCap`: one session over would be a `+1`, so it shows instead) + `+N` tile (`Fill.tile`, `numeral`), a button that opens the sessions with every row listed and the first hidden one picked ("3 more sessions"); **waiting tiles are never collapsed into +N for want of a slot** (they take visible ones). The lists use the same rule, so the numbers agree. The edge's room has the last word: the bar never runs longer than the screen (less 12 pt), so Update and the gear stay on it. Past that room the last non-waiting tiles go into the `+N` first, then the last waiting ones; a `+N` that holds a waiting session is a solid `amber` tile with `onTint` text (VoiceOver value "2 waiting for you"). The sessions' side panel is laid out from the same sequence: a `+N more sessions` row (36 pt, "2 waiting" in `amber`) stands beside the `+N` tile and keeps the sessions open, so every row stays level with its tile. Re-sorting is frozen while the pointer is over the hub, applied on leave with a `fade`. With the extension on and zero sessions: a `tertiary` `asterisk` 14 pt hover anchor. A trailing `plus` neutral tile (extension on) opens the New session menu.
- **Update cell**: neutral 26 pt tile, `arrow.down` `accent`; downloading adds a determinate 1.5 pt `accent` ring; ready = `green` tile, `arrow.clockwise` `onTint`. Label "Update to 0.5.0"/"Restart to update" on every edge. Never blue-filled.
- **Gear**: `gearshape` outline 14 pt `secondary`, 26 pt hit. Click opens Settings; label "Settings" ("Close Settings" and lit with `Fill.selected` while a page is open); hover opens the controls peek; VoiceOver actions "Keep open", "Repositories", "Check now", "Show controls". Sync fault badge: 9 pt `exclamationmark.circle.fill` top-trailing, `red` for sign-in, `amber` for partial/rate-limited/not syncing (shape + label "Settings, sync problem"); healthy and snoozed show nothing.
- Hover opens the peek after the dwell; Return/VoiceOver activation keeps the hub open on that cell's section.

### 5.2 Peeks

Placement, zero gap, dwell 100 ms, instant section switching, leave grace 120 ms and the hit region (including the 2 pt seam) are the choreography of 6.1. Panel = bar's `Surface` with radius 16, joined edge square; the bar and the panel are one union path with one fill and one stroke, so no seam line shows (and a page can slide out of the bar by growing that path). Width per 3.4. Section header 36. Peeks show rows exactly as kept-open does (same anatomy), **never scrolling**: whole rows up to the cap and one `+N more` row (36 pt) that keeps the hub open on that section, on every edge; a peek from a low cell moves up by what would hang past the screen instead of cutting a row. A sessions peek has no tile column (the bar's tiles are beside it): hovering or picking a row lights its bar tile with `.focusRing(7)`, hovering a tile lights its row, and the header lines up with the rows' text. Peeks never move anything on the bar.

### 5.3 Kept open

- **Side edges** (bar 46 + detail 420, footer last): first header 36 = first cell 36; tabs/title centre line = the inbox tile's centre line, so **the inbox tile does not move** (pixel diff = 0 pt): the hub grows only away from where the bar rests and takes what the screen leaves there, so a bar resting low folds CI to its header and the lists take the rest and scroll (the inbox always keeps a row beside the sessions). Other cells slide beside their sections (kept-open is an intentional mode change). Order: Inbox, CI, Sessions, footer. The rail keeps `rail` fill; row hover on the session rows spans content and rail, so tile and text read as one row even on the right edge.
- **Top/bottom**: the strip's **leading edge stays at the same screen x**; the hub grows away from it and is shifted by the minimum only when the screen clamps it (never centred, never a long glide). Strip segments equal the columns beneath them: left column Inbox then CI directly beneath (own in-column header, no pinned spacer, no dead band), right column Sessions; columns take the free height, and a sessions column taller than the left one is cut to it at a whole row (`+N more` under it) so the columns end together. Strip trailing group: gear (+ update). On the bottom edge the strip stays at the edge and the content grows upward; row order stays newest-first (↑ = up everywhere). Section focus: a focused inbox is one column (≤ 560) at the strip's edge with the meta on the title's baseline from 560 wide, a focused CI 420, sessions 480; others collapse to header lines; Esc or ⌘0 returns.
- Both: `HubFooter` (4.11). Kept-open lists scroll within whole rows: a list cut short ends with one cue, `+N more` (pages to the next rows) and `Back to top` once at the end; an unfocused Sessions list cut at eight ends with `+N more`, which gives it the room; focused, `+N below`. During search the CI block is removed from layout but its bar cell stays in the rail at its place; results are Inbox and Sessions groups with counts ("No items match" / "No sessions match" under a group that has none); "No match" only when both are empty.
- Sizes derive from `visibleFrame` (1280×720 shots on every edge must not overflow).

### 5.4 Inbox

Header (36): `Tabs`; trailing `magnifyingglass` (⌘F) and `ellipsis.circle` menu: **Mark all as read**, **Done: all read**, and on Done **Clear Done**; shown whenever the list has rows; slots reserved. Row: avatar = image or one letter of the login (`secondary` 11 semibold on `Fill.tile`, no tint); unread: 6 pt `amber` dot (Bots: `tertiary`) + semibold; line 1 title + age (`numeral`, `secondary`; in Done, the clear time); line 2 `meta` `tertiary`: 10 pt kind symbol (`text.bubble`, `arrow.triangle.pull`, `exclamationmark.circle`, `eye`) then `repo#n · Kind · @author`, then inline state ("Addressed"/"Resolved" in `secondary` with a leading symbol that is never the Restore arrow, no capsule), omitted when it equals the tab. The state is the news, so it keeps its word: on a narrow row the kind's word goes first (its symbol stays), then the author is cut, and the action's room at the end is always kept. Action: **Done** (`checkmark`, ⌫, tooltip "Done  ⌫"); on Done tab **Restore** (`arrow.uturn.backward`). The checkmark means Done only. Row click opens on GitHub and marks read. Whole-row capped lists, lazy past 150, system scroll indicators, no fade mask; a hairline appears under the header once scrolled. Row height identical in every tab.
Context menu (symbols, keys, destructive last): Open on GitHub, Mark as read/unread, Copy link, Treat @author as a bot, Done.

### 5.5 CI

Header: "CI" + disclosure chevron; one phrase ("1 failing" `red`, "1 running" `secondary`) only while CI is folded to its header; stale data (the oldest successful check is older than three polls) adds one `tertiary` line "Last checked 12:03". Failing then running repos are 44 pt rows, uncapped, failing first then newest change: leading 14 pt state glyph (same silhouettes as the bar: `xmark.octagon.fill` `red`; `circle.dashed` `secondary`), title repo name (`owner/` only on a name collision), age since change (`numeral`), line 2 failing check names in `red` at `meta` (truncating) or the commit headline in `tertiary`. Passing collapses to one 36 pt row "Passing · 11" (`checkmark.circle` `tertiary`, ←/→ or click expands in place to repo names as links; focused CI expands it); all green = just that row ("All passing · 11 repositories"). A muted repo is quieted, not fixed: it lists first in the opened Passing group with its real state's glyph and word in `tertiary` ("failing, muted"), and the row's title counts it apart ("Passing · 11, 1 muted"; "Muted · 1" when only muted repos are quiet). No CI at all is one calm line, "No CI configured · Choose repositories". No zero states, no count column, no coloured line titles. Row click opens checks; CI rows are keyboard targets (Return opens, ⌘C copies the URL). Context menu: Open checks, Open commit, Open repository, Copy commit SHA, Check now, **Mute until it changes** (`mutedCI[fullName] = sha`, persisted; left out of the worst state, the bar's glyph and count, and the failing rows until its commit or its state changes, a rerun of the same commit included, so it never turns the bar into a passing check; an undo line; **Unmute** while muted), Stop showing CI (undo line). Ages and headlines come from external check runs and statuses too; a failing workflow is named by the jobs that failed in it, and by its own name only when none is found. VoiceOver value: "swift-format, failing, Linux build and Windows test, 45 minutes ago". Ages ride the minute clock.

### 5.6 Sessions

Header: "Sessions" + "1 waiting" in `amber` only while Sessions is folded to its header (a button that scrolls to and picks the first waiting row); no done/working counts. Groups: **Waiting for you** (`amber` `label`; every waiting session, each showing its project name in the row; hidden when empty); one group per project (6 pt palette dot, name `label`, count; "Scratch" for folderless; header is the right-click target for colour, mute, label; drag reorder within a group, plus Move up/down, ⌥↑/⌥↓); **New activity** (trailing **Keep all** text button, which keeps only what New activity lists and leaves waiting sessions alone; the list is cut from its end by `SessionCap`, with a keyboard-reachable `+N more` row).
Row (44; 60 with tasks; same anatomy in peeks and on all edges, a peek without the tile): tile in the rail (leading on left/top/bottom edges, trailing on the right edge); line 1 title (semibold if unread/waiting) + status `numeral`: "Waiting" `amber` semibold, "Working 2m", "Finished 4m" (`secondary`), status column ≤ 38% with title priority; line 2 the one thing that matters now, `meta` `secondary`: the blocking question (or the plan's title) for waiting, else the turn summary (shown in peeks too), after the project's name where the row names its project (`lcu · Should updates install…`); line 3 only with tasks: first running task in full + "· +2 more" (`secondary`), full list in `.help`. Action: **Keep** (`bookmark`) in New activity, **Hide** (`eye.slash`, ⌘⌫, "Comes back on new activity") elsewhere; the pin is reserved for Keep open. Context menu: Open in Claude, Mark as read/unread, Keep, Hide, Move up/down, Colour (menu items with swatch images), Mute "name" (undo line), Change label (segmented: Letters / Emoji / Icon). VoiceOver value "state, project, age", hint = summary or question; actions Open, Mark read/unread, Keep, Hide, Move up, Move down.
**New session row** (36, a keyboard target; not while searching, and with no sessions a peek is just its header and this row): neutral `plus` tile in the rail, "New session", trailing `chevron.down` menu: "Scratch (no folder)" then projects by full name with palette dot, most recent first. Click = scratch session; → opens the menu. No project chips. The bar's `+` opens the same menu.

### 5.7 Controls peek and menus

Controls peek (240): `MenuRow`s: Keep open (check when on; "Stop keeping open"; shows the configured key), Repositories…, Settings… (⌘,); hairline; quiet row "Checked 2m ago" + "Sync now ⌘R" (fault text instead when broken). Reachable from the gear by hover or by VoiceOver actions ("Show controls") and from the footer. Opened for the keyboard it takes the keys (↑↓ walk its rows round, Return or Space does one) and stays up wherever the pointer is until Esc or a row closes it. Bar context menu (symbols, system key equivalents, destructive last): Keep Open/Stop Keeping Open, Settings… ⌘,, Repositories…, Check for Updates…, Quit Lookout ⌘Q. (Lookout is an accessory app with no menu bar, so there is no app menu.)

### 5.8 Settings and Repositories

Page header (36): Settings = `Tabs` **General | Notifications | Shortcuts | Claude** (←/→ switch; selected pane title is a heading), Repositories = title "Repositories"; trailing plain **Done** (Esc). No chevron. Page slides in once from the gear (`move`); pane/page switches cross-fade (`fade`). The panel becomes key while a page is open. Scroll indicators automatic; hairline under header once scrolled; no bottom mask. The bar is never dimmed. Pages are as tall as the hub opens whichever pane shows, so switching panes never resizes the panel; the scroll view takes the difference.
Form idiom: sentence-case `label` titles (20 above, 6 below), one inset `Fill.group` radius-10 group per section, rows ≥ 36 pt hairline-separated inset 14, label `body` left, control right, optional detail `meta` `secondary` only where it prevents a mistake. Option choices are bordered pop-up buttons with plain words.

- **General**: group GitHub: account row (avatar 22, `@login`, "Token from gh CLI", trailing "Use a token…" revealing an inline `SecureField`: autofocus, Return saves, Esc cancels; signed out: red icon + "Not signed in" and what to do, as plain text), Repositories row "Watching 6 ›", Check every (Every 30 seconds … Every 5 minutes, caption under 1 minute about rate limits); group Lookout: Launch at login (a refusal puts the switch back: "Couldn't turn on Launch at login" + "Try again"), Keep the bar centred; group Updates: version title, status line, one trailing bordered button, a drawn determinate bar while downloading, and on a release build "Check for updates automatically"; **Quit Lookout** alone, last, plain button.
- **Notifications**: Desktop notifications; Review requests; Snooze (pop-up; active shows "Until 14:30" in `secondary` + **Resume**, no purple); group Bots: "Treat GitHub Apps as bots", removable tags (24 pt remove) + one add field (Return adds; button only while text is present).
- **Shortcuts**: groups "Anywhere" (Keep open, Open on sessions; one note that a lone modifier or a mouse button works too, one Accessibility notice `StatusBanner` "Needs Accessibility access" with **Open Privacy Settings** via the `x-apple.systempreferences` deep link, shown only when a bound key needs it) and "In Lookout" (open, read, Done, mark all read, check now and, with the extension, keep, hide, move); recorder rows with 24 pt visible Reset (which says which action already holds the default key and then keeps the one that works), Delete clears while recording, "Already used by …"; **Restore defaults**. Footer paragraph cut.
- **Claude**: the extension switch is the group title, its mark and title in full colour even when the Claude app is missing (only the switch is drawn unavailable, and the reason is the row's detail line); when on, indented: Muted folders (pop-up), Icons picked for you (one sentence "Sends session titles and first messages to typesafe.ai"; `SecureField` key beneath when on). Jev/TypeSafe wording appears only here.
- **Repositories**: add row = field "owner/repo or GitHub URL" (`plus` glyph) + bordered **Add** (disabled when empty); suggestions are an overlay (never pushes the list), ≤ 5, watched repos filtered, ↑↓ highlight, Return adds the highlight or the typed repo, Esc closes, empty → "No match. Press Return to add owner/repo"; errors red icon + sentence. Repo row (one accessibility container; 36, 44 with a failure line): `owner/` `tertiary` + name semibold, middle truncation; trailing pop-up **Everything / Only what's for me / Custom** and a **CI** toggle. Custom discloses labelled native checkboxes: Issues opened, Issue comments, Pull requests opened, Pull request comments, Review comments, "Every comment, not only the ones for me" (with the README sentence). Presets map onto the existing flags (*Everything*: new issues and PRs and every comment; *Only what's for me*: comments only, and only the ones for you); every existing option stays reachable (Store tests prove the round trip), and a repo that follows new issues and PRs but only the comments for you, which is how a new one starts, is Custom. Custom's summary line ("New PRs and PR comments for you") is the disclosure for its checkboxes, which are drawn (outline holding 3:1, accent fill when on, in a non-key panel too). A name too long for the line beside its controls takes a line of its own, the full name in the tooltip. Every change (a preset, Stop watching) has an undo line and ⌘Z for 30 s; undoing a preset puts back only what it changed. Failure: red second line, a sentence about the repository ("No access to e2b-dev/runtime", "Couldn't find ziglang/zig, or no access to it"; GitHub's own wording only in the tooltip and VoiceOver's value) + Retry in a reserved slot (no column shift). Context menu: Open on GitHub, Open Actions, Open latest commit checks, Move up, Move down, Stop watching (undo line). Drag, ⌥↑/⌥↓, menu and VoiceOver actions (Toggle issues / PRs / CI, Move up, Move down, Stop watching). Empty: field focused + two example suggestions.

### 5.9 Empty, loading, error, snoozed, update states

One at a time, in priority order. Lists never show spinners or skeletons.

| Cause | Where | Copy | Action |
|---|---|---|---|
| Can't sign in | Inbox body replaces list | `red` icon "Can't sign in to GitHub" / "Lookout uses gh or your saved token." | Open Settings |
| No repos watched | Inbox body | "Nothing watched yet" / "Add a repository to start." | Add a repository (opens Repositories, field focused) |
| Some repos failed | Banner above list; list stays | `amber` icon "2 repositories didn't sync" | Retry |
| Rate limited | Banner | "GitHub is rate limiting. Checking again at 14:12." | none |
| Snoozed | Banner | "Snoozed until 14:30" | Resume |
| Needs you empty (true) | Inbox body | "All caught up" / "Checked 2m ago" (minute clock) | "2 in Bots" link when bots unread |
| Needs you empty, but a source failed, is stale or rate limited | Inbox body | "Nothing new" (never "All caught up") | |
| Bots empty / Done empty | Inbox body | "Bots are quiet" / "Cleared items land here" | |
| No match | Search results, only when both groups empty | "No match" | |
| No CI | CI | "No CI configured" / "Choose repositories" | link to Repositories |
| All passing | CI | one Passing row | |
| Extension on, no sessions | Sessions | "No Claude sessions" + New session row | |
| Claude files missing/unreadable | Banner under Sessions header | existing wording | Details |
| Update available/downloading/ready | Update cell (5.1) + General pane row | per 5.1 and 5.8 | |
| Loading first sync | Inbox body | "Checking GitHub…" (`secondary`, static) | |

The hollow `checkmark.circle` (22 pt, `tertiary`) is used only for "All caught up". The green filled check is deleted. Tooltips on the bar: icon-only name + key; sync detail ("next check in 3m") is also in the controls peek, never tooltip-only.

---

## 6. Interactions and keyboard

### 6.1 Hover choreography (must survive)

1. First panel opens after a 100 ms dwell. 2. Switching sections is instant. 3. Leaving has a 120 ms grace so bar-to-panel travel never closes it. 4. Hover state no body reads stays out of observed state. 5. The hit region includes the bar/panel seam. 6. Nothing in the bar moves on hover. 7. Every panel also opens from activation (Return/VoiceOver on its bar cell).

### 6.2 Key map

| Key | Action | Notes |
|---|---|---|
| ⌃⌥L (default), or a lone-modifier tap | Keep open | customizable |
| ⌃⌥S (default) | Open on sessions | customizable |
| ↑ ↓ | Pick previous/next **visible** target | order: inbox rows, CI rows, session rows, New session row; only rows on screen (a focused section hides the others', and a pick on one is let go); rehomed when a section collapses |
| Return | Open the pick (GitHub, checks, Claude, start session) | |
| Space | Toggle read/unread | types a space while the search field has focus |
| ⌫ | Done / Restore | edits text while the search field has focus |
| ⌥Space | Mark all as read | |
| ⌘K / ⌘⌫ | Keep / Hide a session | |
| ⌘Z | Undo last Done/Hide/Mute/Stop watching | while undo line visible, and 30 s after |
| ⌘F | Search | typing any printable character also starts it |
| ⌘R | Check now | |
| ⌘, | Settings | |
| ⌘1 / ⌘2 / ⌘3 | Focus Inbox / CI / Sessions | click on the header does the same |
| ⌘0 | Back to all sections | |
| ← → | Expand/collapse Passing on its row; switch Settings panes on a page; → on New session opens its menu | |
| ⌥↑ ⌥↓ | Move session or repo | also in menu and VoiceOver actions |
| Tab / Shift-Tab | Chrome ring: tabs → header actions → footer actions → (settings: pane tabs → controls) | list selection is unaffected; ring uses `.focusRing`; focused control gets Space/Return |
| Esc | Steps back, first match wins: close open menu/popover/suggestions → clear query → leave page → leave section focus → un-keep hub and return focus to the previous app | |

All existing in-hub bindings stay customizable. Key monitor rules: it yields when a text field or a focused button has focus; row commands apply only when a list has the keyboard selection; typing seeds the search field (first character inserted, field focused) so paste, IME, selection and AZERTY dead keys work; the monitor lives only while the hub is key.

### 6.3 Focus model

Two layers: **row selection** (↑↓, the keyboard pick) and the **chrome ring** (Tab). Pointer hover is separate and never moves VoiceOver focus. Opening from the keyboard (shortcut or `Show`) moves VoiceOver focus into the hub; Esc moves it back out and restores the previous app. The root announces on open ("Lookout, 5 need you, 1 CI failing, 1 session waiting") and on `Back to bar`.

---

## 7. Accessibility checklist

- **Structure**: root container "Lookout" (`window.title = "Lookout"`, hosting view an accessibility group, root hint = key summary "Up and down to pick, Return to open, Delete to finish, Escape to go back"); labelled containers Inbox, CI, Sessions, Controls; each section title `.isHeader`; filter tabs in an "Inbox filter" container with `.isSelected`; settings pane title is a heading. The bar and the hub share the same container structure. Tab groups use `.isTabBar`.
- **Bar**: one stop per cell; CI is one element; every cell has button trait + `Show`; session tile value "state, project, age", hint the question/summary; `+N` tile "3 more sessions".
- **Rows**: combined element; inbox label "Review comment from andrewrk on zig #21877: std.io: add vectored reads to File, 3 minutes ago", value "Unread"/"Done", hint "Opens on GitHub. More actions available."; actions Mark as read/unread, Done/Back to inbox, Open on GitHub, Copy link; CI and session actions per 5.5/5.6. Row visual actions appear on VoiceOver focus too. Switches expose On/Off; drawn controls keep real traits.
- **Announcements** (`AccessibilityNotification.Announcement`): hub open, Done ("Moved to Done, 4 left. Undo available"), undo, CI flip while open, search result count (debounced), banner appearance.
- **Rotor**: "Unread" over inbox rows.
- **Menu route**: the global shortcuts and the bar's context menu; every bar cell is a VoiceOver button with a `Show` action.
- **Contrast**: ContrastTests gate (3.2); nothing dimmed by opacity; CI collapses (not dims) while searching.
- **Colour independence**: waiting = filled tile + word; failing = octagon-x + names; running = dashed ring; working = ring; unread = dot + weight + value; Differentiate adds strokes.
- **Targets** ≥ 24 pt everywhere, row actions 28; **type** floor 11 pt.
- **Reduce Motion**: 3.6. **Increase Contrast**: 3.2. **Reduce Transparency**: no-op. **Differentiate Without Colour**: 3.2.
- **Focus**: one `.focusRing` on every control; fields system + accent border; no ring covered by a mask.
- **Full Keyboard Access**: every custom button is `.focusable()`; Tab order per 6.2.
- Manual pass required: VoiceOver walk of bar, rows, search, settings; Full Keyboard Access walk; AZERTY dead keys (´ + e), IME composition and paste in search; Esc restoring focus.

---

## 8. Performance rules (idle stays 0%)

**Forbidden**: any SwiftUI-driven repeating animation (`repeatForever`, `TimelineView`, `Timer.publish`, per-view timers); looping motion outside Core Animation; a second ticking clock; new global event monitors (the only one allowed is `flagsChanged` for the lone-modifier shortcut; no key or mouse monitors at rest; the hover trigger at rest is a tracking area); animating shadow radius/offset; `drawingGroup`/blur/mask around lists or live content; spinners, shimmer, skeletons; a re-render of the whole hub on poll (rows cross-fade by revision; the sync state changes colour/glyph without spinning).

**Required**: the only looping element is the working ring (shared `beginTime`, one cached image per appearance, removed when the window is occluded). Time labels go through `Ticking`/`Clock`; add `Clock.minute` (30 s) for ages and "Checked 2m ago"; seconds tick only for a visible working session under a minute; the 1 s clock timer is not running when no seconds-ticking view is on screen. Undo lines use one-shot timers cancelled on dismissal. Whole-row lazy lists, hover state out of the body, 0.5 s coalesced saves, FSEvents watchers, 60 s poll (30 s open, ×2 in Low Power) hold.

Instruments (SwiftUI + Core Animation, no frame over 8 ms while opening) is guidance for manual profiling, not a gate.

**Gates** (section 9 runs them):
1. `scripts/idle-cpu.sh`: launches the release build with `--demo agents` (it puts the bar on screen for about two minutes, so it is the final gate, not a per-change one), waits 5 s to settle, samples the process's cumulative CPU time at t0 and t0+30 s (`ps -o cputime=`, converted to seconds), asserts Δ/30 s < 0.1% once at rest and once kept open (`--open`), prints WindowServer's share separately.
2. Geometry: unit tests over the layout (`HubGeometry`) and a pixel check of rest vs open shots.
3. `ContrastTests`, `swift test`.
4. Grep gate in `scripts/design-lint.sh`: forbidden symbols (`repeatForever`, `TimelineView`, `Timer.publish`, `addGlobalMonitorForEvents` other than `.flagsChanged`, `.snappy`, `bounce: 0.0[1-9]`, `.system(size: [0-9.]*` below 11, retired words in 4.0).

---

## 9. Verification

Every change passes the same gates, in this order. All are headless except the last.

1. `swift build` with no warnings.
2. `swift test`: the unit tests (stores, undo, presets, geometry, ordering, keys, scroll cues), `ContrastTests` (3.2), the per-edge geometry checks (rest vs open: the inbox tile and the strip's leading edge move 0 pt), the in-phase check of the working rings (`PulseTests`) and a test that fails on a repeated shot name.
3. `scripts/design-lint.sh`: the grep gate of section 8 (forbidden constructs, retired words in 4.0, hues outside the places that own them). A line is exempt with a `design-lint: ignore` comment on it or above it, with its reason.
4. Look at the shots. `.build/debug/Lookout --playground-shots <dir> [filter…]` renders the real views on the demo data, offscreen, as PNGs named `<edge>-<state>` (edge: right, top, left, bottom); with filters, only the shots whose name contains one (`right-open`, `peek-agents`). The catalog is documented on `PlaygroundShots` in Playground.swift and covers every state of 5.9, every bar state, every edge, undo, search, tooltips, picked rows, Increase Contrast, Reduce Motion, Differentiate Without Colour, and 1280×720 on every edge (nothing may overflow). Read the images: a change is not done until its shots have been looked at on a side edge and on the top. `--playground` shows the same bar on a fake desktop for trying it by hand; `--demo [scenario] --open` runs the app on mock data without saving anything.
5. `scripts/idle-cpu.sh` (the final gate only: it puts the bar on screen for about two minutes): under 0.1% CPU at rest and kept open.

Manual passes that no script replaces (section 7): a VoiceOver walk of the bar, rows, search and Settings; a Full Keyboard Access walk; AZERTY dead keys (´ + e), IME composition and paste in search; Esc restoring focus to the previous app.

---

## 10. Decisions after the first integration

Numbered because the code cites them. Sections 3 to 8 already say each one; this is where they are in one place.

1. **Working mark is a ring, not an arc.** A 270° arc hugging the tile read as a bracket. Working (and finished with tasks running) = a full rounded-rect outline 1.5 pt, `secondary` (Increase Contrast: `text`), drawn 2 pt outside the tile (concentric radius 7 + 3.5), breathing on the shared heartbeat (opacity 1 ↔ 0.4, 1.2 s, one shared `beginTime`); static at opacity 1 under Reduce Motion. Waiting never has the ring. The unread dot sits on the ring's corner.
2. **Peeks don't repeat the bar.** In a sessions peek the rows carry no tile column: the bar's tiles are right there. Hovering or picking a row lights its bar tile with `.focusRing(7)`; hovering a tile lights its row. Kept-open (where the rail tiles move beside their rows) is unchanged.
3. **Peeks never scroll.** Every peek shows whole rows up to its cap and ends with one `+N more` row that keeps the hub open focused on that section. Kept-open lists scroll.
4. **One overflow phrase and one cap rule.** `+N more` everywhere (no "Show all N"). The bar's `+N` tile and the lists use the same rule (waiting sessions are never collapsed; the remaining visible slots are shared in panel order), so the numbers agree.
5. **Header phrases only when they add information.** "1 waiting" (Sessions) and "1 failing" (CI) appear in a section header only when that section is collapsed to its header (another section focused, or search). Expanded, the Waiting for you group and the failing rows already say it. Inbox tab counts stay (the list may be cut).
6. **Search keeps the bar intact.** The CI block leaves the kept-open layout during search but its bar cell stays in the rail at its place.
7. **Meta separators.** Every secondary line joins its parts with ` · ` (e.g. waiting rows: `lcu · Should updates install…`).
