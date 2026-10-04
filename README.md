# Lookout

An always-on GitHub sidekick for macOS: a small pill docked to the edge of the screen, with an inbox for the events you care about.

## Build & run

    ./scripts/build-app.sh && open build/Lookout.app

Requires macOS 14+. Auth comes from `gh auth token` (or a token pasted in Settings, stored in the Keychain).

## Using it

- **Pill**: inbox (amber badge = unread items that need you, grey dot = only bots), one CI dot per repo, settings. Drag the top handle to move it; it snaps to the nearest edge. `⌃⌥Space` toggles the panel.
- **Repositories**: add `owner/repo` (suggestions come from repos you own or are involved in) and toggle: issues, issue comments, PRs, PR comments, review comments, CI on the default branch.
- **Inbox**: *Needs you* / *Bots* / *Done*. Hover a row to mark it read, discard it, or open it. Keys: ↑↓ to move, Return to open, Space to toggle read, ⌫ to discard or restore, Esc to close.
- **States**: unread → read (you saw it) → **addressed** (you replied after it, so this happens automatically) → **resolved** (review thread resolved, synced through GraphQL). Discarded items go to Done.
- **Bots**: GitHub Apps (`…[bot]`) plus any handles you add arrive silently in the Bots tab.
- **Extras**: review requests from any repo (closed automatically once you review), CI red/green transition notifications, snooze, launch at login.

## Dev flags

    .build/debug/Lookout --demo --open            # fake data, nothing saved
    .build/debug/Lookout --demo --snapshot /tmp/x # render every screen to PNG
    .build/debug/Lookout --check owner/repo       # headless live sync, prints the inbox

State: `~/Library/Application Support/Lookout/state.json`.
