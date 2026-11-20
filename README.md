# Hepigit

A small, native Git client for macOS. SwiftUI, no Electron, no account.
It drives the `git` you already have, so SSH keys, `~/.ssh/config`, the Keychain,
hooks and LFS behave exactly as in the terminal.

## Install

```sh
./scripts/bundle.sh --install     # builds a release .app and copies it to /Applications
./scripts/dmg.sh                  # builds dist/Hepigit-<version>.dmg to share
```

Needs macOS 15+ and Xcode (or the Command Line Tools). The first build takes about 30 s.

**For colleagues:** zip `dist/Hepigit.app` and send it. The app is signed ad hoc (no Apple
Developer ID), so the first launch needs right-click > Open, or:
`xattr -dr com.apple.quarantine /Applications/Hepigit.app`.

## Updates

Each install checks GitHub Releases of `hepifish/hepigit` once a day (and on Hepigit > Check for Updates…).
When a newer version exists it offers "Install and restart": it downloads the DMG, swaps the app in
place and relaunches. Tabs and settings live in `~/Library/Preferences/app.hepigit.plist` and survive.

Publish a fix:

```sh
./scripts/release.sh 1.0.1 "Fix: discard now treats file names literally"
```

That bumps `VERSION`, builds the DMG, commits, tags `v1.0.1`, pushes and creates the GitHub release.
The repo must be public for the check to work without a token.

## What it does

| Area | |
|---|---|
| Repos | Tabs for every open repo (drag to reorder, ⌘1–9, ⇧⌘[ ]), open several at once, drop folders on the window, clone |
| Graph | Lanes, merges, branch / remote / tag pills (local + remote twins merged into one pill), WIP row, infinite scroll, commit search (⌘F) |
| Branches | Check out (double-click), create, rename, delete local or remote, fast-forward, push and track, drag a branch onto yours to merge or rebase |
| Commits | Details, files, diffs, cherry-pick, revert, reset soft/mixed/hard, tag, check out detached, undo last commit |
| Working tree | Stage / unstage / discard per file or per hunk, stage all, amend, ⌘↩ to commit |
| Remote | Fetch, pull (merge, ff-only, rebase), push, force push with lease, auto upstream on first push |
| Stashes | Stash with untracked files, view files and diffs, apply, pop, delete |
| Conflicts | Banner for merge / rebase / cherry-pick / revert in progress, with Continue and Abort |

## Shortcuts

⌘O open · ⇧⌘O clone · ⌘W close tab · ⌘R refresh · ⌘F search commits · ⌘0 show changes
⇧⌘F fetch · ⇧⌘L pull · ⇧⌘P push · ⇧⌘B branch · ⇧⌘S stash · ⌥⇧⌘S pop · ⌥⌘T terminal · ↑ ↓ move through commits

## Why it stays light

- Only the visible tab is watched (one FSEvents stream). The five most recent tabs keep their
  history in memory; older ones are freed and reload in ~100 ms.
- Reads never take Git's index lock (`GIT_OPTIONAL_LOCKS=0`), so the watcher cannot loop on itself.
- History is re-read only when refs actually move; a file save only re-runs `git status`.
- The graph is drawn per row in a lazy list, so 2,000 or 80,000 commits cost the same on screen.
- Commit file lists and diffs are cached by hash; they never change.
- A quiet `git fetch` runs every 10 minutes, only for the visible repo, only while the app is in front.

Measured on git.git (86k commits, 1,000 tags): about 60–80 MB in Activity Monitor, 0% CPU at idle.

## Layout

```
Sources/Hepigit/
  Git/       GitRunner (process + env), Parsers, GraphLayout, RepoWatcher, Models
  State/     AppState (tabs, toasts, dialogs), RepoModel (one repo: data + every action)
  Views/     RootView (window, tabs, welcome, toasts, dialogs), RepoView (toolbar), Sidebar,
             GraphView, Inspector (changes / commit / stash), DiffView
  Support/   Theme and shared controls
scripts/     bundle.sh (build .app), make-icon.swift
```
