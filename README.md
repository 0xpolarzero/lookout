# Lookout

An always-on GitHub sidekick for macOS: a slim bar against the edge of the screen that opens, on hover, into an inbox for the events you care about, your CI and your Claude sessions.

**What it's for**

- **Your repos:** get notified on everything: new issues, new PRs, every comment.
- **Repos you contribute to:** only what's meant for you: replies on your issues and PRs, @mentions, answers after you comment, and review comments in your threads.
- **CI:** see at a glance which repos are green, red or running on main, and get pinged when main breaks.
- **Review requests:** from any repo, cleared once you've reviewed.

Bots are kept quiet, and items mark themselves *addressed* when you reply and *resolved* when a review thread is resolved.

<img src="docs/screenshots/hub-hover.png" width="420" alt="Hovering the sessions: their panel beside the bar"> <img src="docs/screenshots/hub-open.png" width="420" alt="Kept open: inbox, CI and sessions">

## Install

Grab the latest zip from [Releases](https://github.com/0xpolarzero/lookout/releases), move **Lookout.app** to `/Applications`, then clear the quarantine once (the app isn't notarized yet):

    xattr -dr com.apple.quarantine /Applications/Lookout.app

After that Lookout updates itself: it checks in the background (shortly after launch, every hour and on wake), downloads and verifies a new release, then shows a small restart icon on the bar; hover it for what it is, click to restart into the new version. Right-click it for the release notes or to skip that version. Settings → Updates shows your version, checks on demand and turns the background check off. An update is only installed if its checksum matches and it's signed by the same certificate as the app you're running.

## Build & run

    ./scripts/build-app.sh && open build/Lookout.app

Requires macOS 14+. Auth comes from `gh auth token` (or a token pasted in Settings, stored in the Keychain).

## Using it

- **The bar**: flush against a screen edge (drag it to any edge of any screen; along the top or bottom it lays out horizontally). From one end to the other: the inbox (an amber tile and its count when something needs you), CI (a seal in the colour of the worst state, then how many repos are failing, running and passing on main), your Claude sessions as tiles, and a gear. Hover any of them for its panel, attached to the bar and lined up with it: the inbox list, the repos in each CI state, a row beside each session's tile, or the controls (sync status, Keep open, Repositories, Settings). Nothing in the bar moves while you hover.
- **Kept open**: `⌃⌥L` (customizable in Settings → Shortcuts; a lone modifier tap like right ⌘ works too) keeps the whole view open with the keyboard: every section at once, each session with its last summary and what it left running, and a button on each section's header to give it all the room (the others shrink to their counts; Esc brings them back). Press the shortcut twice quickly to make Lookout see-through and click-through without closing it, so you can work with what's behind. Settings and Repositories slide in from the gear, with one way back (Esc). Right-click the bar for Keep Open, Settings, Repositories, Check for Updates and Quit.
- **Repositories**: add `owner/repo` (suggestions come from repos you own or are involved in) and toggle: issues, issue comments, PRs, PR comments, review comments, CI on the default branch.
- **Which comments count**: by default only comments that are for you: on issues/PRs you opened, ones that @mention you, or ones posted after you joined the conversation (for review comments: in a review thread you posted in). Turn on **All comments** per repo to get every comment.
- **CI**: every repo with its CI badge on, by state on its default branch (failing, running, passing); hover a repo for its commit and failing checks, click it to open its checks.
- **Inbox**: *Needs you* / *Bots* / *Done*. Hover a row to mark it read, discard it, or open it; click it to open it. Kept open, keys act on the hovered row (or pick one with ↑↓): Return opens, Space toggles read, ⌫ discards or restores, ⌥Space marks all read, ⌘R refreshes, Esc closes; typing searches the inbox and your sessions. Every button's tooltip shows its key; all customizable in Settings → Shortcuts.
- **States**: unread → read (you saw it) → **addressed** (you replied after it, so this happens automatically) → **resolved** (review thread resolved, synced through GraphQL). Discarded items go to Done.
- **Bots**: GitHub Apps (`…[bot]`) plus any handles you add arrive silently in the Bots tab.
- **Claude sessions (extension, off by default)**: for people using the Claude desktop app's Code tab. Turn it on in Settings → Extensions. Your Claude Code sessions show up as tiles on the bar: done and unread (blue), waiting for you (amber), or still working (its tile fades and pulses, quieter than the sessions waiting on you, with what it's doing right now: *Running swift test · 2m*, *Editing PillView.swift*). A session whose turn is over but that left subagents or shell commands running in the background pulses the same way: its row says *done 4m · 3 running*, and kept open each one is named under the session's summary. One tile per session: two letters (or an emoji you pick), underlined in its project's colour, projects grouped together. Optionally, each session gets an SF Symbol picked for it instead: paste a [TypeSafe](https://typesafe.ai) API key in Settings and Jev picks one from the title, project and first message (first the kind of icon, then one of ~680 SF Symbols in it that isn't already on screen; about $0.0002 a session; the key stays in the Keychain). Hover the tiles for their rows, each level with its tile; click to jump to the conversation. Sessions with new activity arrive as *pending* (smaller, dimmer): keep the ones you use or dismiss them until their next activity. `⌃⌥S` opens Lookout on your sessions from anywhere: ↑↓ and Return to open, or just type to find any session by name; ⌘K keeps, ⌘⌫ removes, Esc goes back. Read state follows the app (a finished turn, opening a session, the sidebar's dot) and can be changed in Lookout without touching the app. Lookout only reads the app's files (`~/Library/Application Support/Claude`, `~/.claude/projects` for what a working agent is doing, and Claude Code's task list in `/private/tmp/claude-<uid>` for what's left running in the background; a shell command counts as running for as long as its process has its output open), which aren't a public API: if an app update changes them, Lookout says so and the GitHub side keeps working.
- **Extras**: review requests from any repo (closed automatically once you review), CI red/green transition notifications, snooze, launch at login.

## Releasing

Push a version tag; the `Release` workflow tests, builds a universal app and publishes `Lookout-<version>.zip` to GitHub Releases:

    git tag v0.2.0 && git push origin v0.2.0

Releases are signed with one self-signed certificate, so macOS keeps Lookout's Accessibility access across updates and the updater can check a release is ours. Set it up once:

1. In Keychain Access: Certificate Assistant → Create a Certificate, name **Lookout Dev**, identity type *Self-Signed Root*, certificate type *Code Signing*.
2. Export it with its private key as a `.p12` (with a password), then add two repository secrets: `SIGNING_CERT_P12` (`base64 -i cert.p12 | pbcopy`) and `SIGNING_CERT_PASSWORD`.
3. Keep the `.p12` safe: a release signed with another certificate isn't installed by existing apps, and everyone has to update by hand once.

`build-app.sh` signs local builds with the same certificate when it's in your keychain (ad hoc otherwise, which macOS treats as a new app on every build).

## Dev flags

    .build/debug/Lookout --demo [busy|botsOnly|allClear|snoozed|error|empty|agents] --open   # mock data, nothing saved
    .build/debug/Lookout --claude [--watch]                      # what the Claude extension reads; --watch prints live changes
    .build/debug/Lookout --playground                            # the bar on a fake desktop, demo data, every edge
    .build/debug/Lookout --playground-shots <dir>                # render the bar's states (rest, hover, open, pages) as PNGs
    .build/debug/Lookout --classic                               # the old pill and panel
    .build/debug/Lookout --snapshot docs/screenshots                                 # render the old pill and panel's states
    build/Lookout.app/Contents/MacOS/Lookout --update 0.1.0   # pretend to be 0.1.0: check, download and verify the latest release
    .build/debug/Lookout --check owner/repo [--days N] [--all]   # headless live sync, prints the inbox
    .build/debug/Lookout --check owner/repo --thread 123         # what Lookout knows about one thread
    swift test

State: `~/Library/Application Support/Lookout/state.json`.
