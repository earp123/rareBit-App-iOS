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

Board: **rareBit Flags & Receivers** (workspace: rareBit).

- Lists are platform/domain-scoped — put cards where the work happens:
  `iOS`, `Android`, `Garmin`, `WatchOS`, `Relay`, `Firmware`,
  `Flag & Receiver Hardware`.
- Card descriptions stay **terse**: one or two sentences plus a pointer into
  the repo (`docs/*.md`, `CHANGELOG.md`) for detail. Don't write long specs
  into cards.
- Cross-link related cards with markdown links in an italic `*Note:*` line.
- Use board labels where they apply (e.g. `Test`).
- Shipped work is recorded in `CHANGELOG.md`, not as cards; don't create
  pre-completed cards.
- Don't archive or delete cards Sam created without asking.
