# CLAUDE.md

## Project

One Xcode project, two apps sharing bundle `rareBit.Watch-Receiver`:

- **iOS companion** — `rareBit App/` (scheme/target: `Watch Receiver`). Device
  management, config, firmware updates for the rareBit device family.
- **watchOS receiver** — `Watch Receiver Watch App/` (scheme: `Watch Receiver
  Watch App`). Referee-worn: flag alert haptics + match timer.

Architecture, BLE encoding schemes, and history: `CHANGELOG.md`.
Relay OTA DFU spec: `docs/relay-dfu-flow.md`.
Keep `CHANGELOG.md` updated when shipping notable changes.

## Build & install (physical devices)

Scripts on PATH in `~/bin`:

- `ship.sh` — build `Watch Receiver`, install + launch on Sam's iPhone.
- `watch_ship.sh` — build the watch scheme, install + launch on Sam's Apple Watch.

Notes:
- `devicectl` uses CoreDevice UUIDs; `xcodebuild -destination` uses hardware
  ECIDs. Both are recorded in the scripts — don't swap them.
- **Before any device install, ask via AskUserQuestion whether the target
  device is unlocked** (the question notifies Sam). A locked device fails with
  `Device is busy` (build) or `RequestDenied … Locked` (launch). If the watch
  is locked, fall back to a simulator compile-check only.
- Compile-check without hardware: destination `generic/platform=iOS Simulator`
  (iOS) or a watchOS simulator; use `-derivedDataPath ~/.ship-dd-sim` to avoid
  clobbering the device build cache.
- Live app logs: relaunch with
  `xcrun devicectl device process launch --device <UUID> --terminate-existing
  --console <bundle-id>` in a background shell teeing to a file. The stream
  dies whenever the app is reinstalled or quit — reattach after each install.

## Firmware / BLE gotchas

- **Relay uses Nordic legacy DFU** (trigger char `…0004`, magic `0xA8`,
  bootloader service `1530`); **PRO Flag / PRO Receiver use SMP (McuManager)**.
  Keep the two flows separate — don't route relays down the SMP path.
- FW version byte is nibble-encoded (`0x1A` = v1.10); minor caps at 15.
- GitHub release checks are unauthenticated (60 req/hr/IP) and session-cached;
  `/releases/latest` ignores drafts and prereleases.
- TEMP: the iOS scan filter accepts advertisements with no service UUIDs
  because relay-v1.9 firmware doesn't advertise the config UUID while docked.
  Tighten to config-UUID-only once firmware does (then move the filter into
  `scanForPeripherals(withServices:)`).

## Trello board policy

Board: **rareBit Flags & Receivers** (lists for this repo: `iOS`, `WatchOS`).
The board is how this project's Claude sessions communicate with Sam, the
engineer guiding and reviewing day-to-day task completion.

- **Never create cards or lists.** Sam is the only one who creates them.
- Work is tracked via **checklists on Sam's cards** — max 5 items per card.
  Items must primarily follow the flow **"make the change → test it → assess
  the output"**, phrased in language that fits the card, with an optional
  **"triage the issue"** step where applicable.
- Supplemental notes may be appended to a card's description — keep them very
  brief.
- **Never apply labels.** Ensure these exist on the board: Low Priority
  (green), 1 Week Old (yellow), 2 Weeks Old (orange), High Priority (red),
  Client Directive (purple), Hold (blue).
- **On every major push and/or merge to any repo in this project**: sweep the
  board — check off completed checklist items across all cards, and archive
  cards that are complete.
- Give a high amount of effort to keeping the board clutter-free, in both
  information and checklist items.
