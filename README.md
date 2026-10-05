# Lookout

An always-on GitHub sidekick for macOS: a small pill docked to the edge of the screen, with an inbox for the events you care about.

**What it's for**

- **Your repos:** get notified on everything: new issues, new PRs, every comment.
- **Repos you contribute to:** only what's meant for you: replies on your issues and PRs, @mentions, answers after you comment, and review comments in your threads.
- **CI:** see at a glance which repos are green, red or running on main, and get pinged when main breaks.
- **Review requests:** from any repo, cleared once you've reviewed.

Bots are kept quiet, and items mark themselves *addressed* when you reply and *resolved* when a review thread is resolved.

![Lookout states](docs/screenshots/overview.png)

## Install

Grab the latest zip from [Releases](https://github.com/0xpolarzero/lookout/releases), move **Lookout.app** to `/Applications`, then clear the quarantine once (the app isn't notarized yet):

    xattr -dr com.apple.quarantine /Applications/Lookout.app

After that Lookout updates itself: when a new release is out, an arrow appears on the pill. Click it to download (a ring shows progress), then click again to restart into the new version. Right-click it for the release notes or to skip that version. Settings → Updates shows your version, checks on demand and turns the background check (every 6 hours) off. An update is only installed if its checksum matches and it's signed by the same certificate as the app you're running.

## Build & run

    ./scripts/build-app.sh && open build/Lookout.app

Requires macOS 14+. Auth comes from `gh auth token` (or a token pasted in Settings, stored in the Keychain).

## Using it

- **Pill**: inbox (amber badge = unread items that need you, grey dot = only bots; a purple moon means snoozed, a red mark means a sync error), and CI counts: how many repos are passing (green), failing (red) and running (amber) on main; hover a row to see which, click to open the CI tab. Settings are in the panel. Drag it from anywhere to any screen edge; on the top or bottom it lays out horizontally. `⌃⌥L` toggles the panel (customizable in Settings → Shortcuts).
- **Repositories**: add `owner/repo` (suggestions come from repos you own or are involved in) and toggle: issues, issue comments, PRs, PR comments, review comments, CI on the default branch.
- **Which comments count**: by default only comments that are for you: on issues/PRs you opened, ones that @mention you, or ones posted after you joined the conversation (for review comments: in a review thread you posted in). Turn on **All comments** per repo to get every comment.
- **CI**: the default branch of every repo with its CI badge on, failing first, with the commit, its title and the failing checks. Click a row to open the commit's checks.
- **Inbox**: *Needs you* / *Bots* / *Done*. Hover a row to mark it read, discard it, or open it. Keys act on the hovered row (or pick one with ↑↓): Return opens, Space toggles read, ⌫ discards or restores, ⌥Space marks all read, ⌘R refreshes, Esc closes. All customizable in Settings → Shortcuts.
- **States**: unread → read (you saw it) → **addressed** (you replied after it, so this happens automatically) → **resolved** (review thread resolved, synced through GraphQL). Discarded items go to Done.
- **Bots**: GitHub Apps (`…[bot]`) plus any handles you add arrive silently in the Bots tab.
- **Claude sessions (extension, off by default)**: for people using the Claude desktop app's Code tab. Turn it on in Settings → Extensions. Your Claude Code sessions show up on the pill and in an **Agents** tab: done and unread (blue), waiting for you (amber), or still working (a pulsing dot, with what it's doing right now: *Running swift test · 2m*, *Editing PillView.swift*). Collapsed, the pill shows the two counts; the caret expands it to one tile per session: two letters (or an emoji you pick), underlined in its project's colour, projects grouped together. Optionally, each session gets an SF Symbol picked for it instead: paste a [TypeSafe](https://typesafe.ai) API key in Settings and Jev picks one from the title, project and first message (one of ~250 icons not already on screen; about $0.0001 a session; the key stays in the Keychain). Hover the tiles for a drawer of full titles, each level with its tile; click to jump to the conversation. Sessions with new activity arrive as *pending* (smaller, dimmer): keep the ones you use (drag to reorder, or search any session by name in the Agents tab) or dismiss them until their next activity. `⌃⌥S` opens the switcher from anywhere: ↑↓ or 1–9 and Return to open, or just type to find any session by name; ⌘K keeps, ⌘⌫ removes, Esc goes back. Read state follows the app (a finished turn, opening a session, the sidebar's dot) and can be changed in Lookout without touching the app. Lookout only reads the app's files (`~/Library/Application Support/Claude`, and `~/.claude/projects` for what a working agent is doing), which aren't a public API: if an app update changes them, the Agents tab says so and the GitHub side keeps working.
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
    .build/debug/Lookout --snapshot docs/screenshots                                 # render every state + overview.png
    build/Lookout.app/Contents/MacOS/Lookout --update 0.1.0   # pretend to be 0.1.0: check, download and verify the latest release
    .build/debug/Lookout --check owner/repo [--days N] [--all]   # headless live sync, prints the inbox
    .build/debug/Lookout --check owner/repo --thread 123         # what Lookout knows about one thread
    swift test

State: `~/Library/Application Support/Lookout/state.json`.
