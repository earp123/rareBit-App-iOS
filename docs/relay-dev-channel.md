# Task: Relay on the development channel (iOS) — fetch and flash `RELAY_v2.0-dev.<n>`

Source: `rareBit-Relay/docs/dev-release-channel.md` + its CHANGELOG "Development
release channel (2026-09-14)". First build is live:
`RELAY_v2.0-dev.1` in the private `earp123/rareBit-Relay` repo. Decision (Sam,
2026-09-13): the Relay reaches the dev channel through the same hidden dev
DFU card the Flag/Receiver already use. Trello: iOS card TBD (not "Dev Mode
DFU" — that checklist is full).
Scope: `rareBit App/` only. `RelayDfuService.swift`, `FWservice.swift`,
`DeviceDetailView` (Relay firmware card + dev card), `BleScanner` armed state.
Watch app untouched. Stable Relay path (`relay-v` from the public repo) must
not change. Everything dev stays inside `#if DEBUG`.

---

## What already exists

- `latestDevRelease(for:)` — private-repo fetch with `Secrets.githubPAT`,
  filters `target_commitish == "development" && prerelease && hasPrefix(devTagPrefix)`,
  picks the highest `-dev.<n>`, decodes `manifest.json` via
  `downloadAsset(_, channel: .development)` (asset API URL + octet-stream +
  PAT). Never writes `cached`. `.relay` returns `devTagPrefix == nil` → throws
  `devNotSupported`. That is the only thing standing between the Relay and
  the channel on the fetch side.
- `downloadVerifiedPackage(_:)` already downloads and SHA-verifies the
  legacy-DFU zip for a `FirmwareUpdateRelease` on either channel.
- `LegacyDfuFlasher` + the Relay firmware card: trigger `0xA8` → scan for
  `00001530-…` → flash the zip → reconnect → confirm FWV.
- `FirmwareManifest` decodes the Relay dev manifest as-is: `dfu_package`,
  `dfu_package_sha256`, `uf2`, `channel`, `build`, `commit`, `run_url` are all
  present; `full_version` is absent (optional, fine) so `devDescription`
  falls back to `version` → `v2.0 (build 1)`.

## Contract for the Relay (differs from Flags-Receivers in three places)

| | Flag / RX / RXRLY | Relay |
|---|---|---|
| Repo | `earp123/rareBit-Flags-Receivers` | `earp123/rareBit-Relay` |
| `target_commitish` | `development` | `main` |
| Tag prefix | `PRO_FLAG_` / `PRO_RX_` / `RXRLY_` | `RELAY_` |
| Version in tag | `M.N.P` | `M.N` |
| Flash artifact | `ota_image` .bin over SMP | `dfu_package` zip over legacy DFU |

Tag example `RELAY_v2.0-dev.1`; assets `rareBit-Relay-v2.0-dev.1-dfu.zip`,
`rareBit-Relay-v2.0-dev.1.uf2`, `manifest.json`. Version byte is pinned per
stream (`0x20` today) — **no version gate**, the developer chose the build.
The PAT must have Contents: read on `rareBit-Relay` — same
`Secrets.githubPAT`, Sam extends the token's repository list; no new symbol.

## Behavior

1. **Per-product dev source.** Replace `devTagPrefix: String?` with a dev
   source on `FirmwareProduct` — repo releases URL, branch, tag prefix —
   `.relay → (rareBit-Relay, "main", "RELAY_")`, the other three unchanged.
   `latestDevRelease` uses the product's URL and filters
   `target_commitish == product.devBranch`. Single `#if DEBUG` block as now.
   `noDevReleaseForProduct`'s text names the branch instead of hard-coding
   `'development'`.
2. **`FirmwareVersion.init(_:)`** strips `RELAY_v` alongside the other three
   prefixes (it is only used for display on this path, but a stray `RELAY_`
   would parse as 0.0).
3. **Relay detail view, dev card.** The 3 s hold on the title card must
   unlock the same dev card on a Relay as on SMP products: *Fetch dev build*
   → `Dev v2.0 (build 1) armed` / `No dev release on 'main' yet` / `Dev fetch
   failed: <e>`. Arms `pendingDevRelease` exactly as today. If the Relay
   firmware card is a separate view from the SMP DFU card, put the dev state
   there rather than routing a Relay through the SMP card.
4. **Install path.** With a dev release armed on a Relay, the card's primary
   button reads `Install build 1` and runs the existing legacy-DFU sequence
   with **that** release: `downloadVerifiedPackage` (channel `.development`,
   SHA mandatory) → `0xA8` trigger (docked only; ATT `0x03` → `notDocked` as
   now) → `1530` scan → `LegacyDfuFlasher.flash` → reconnect → FWV read.
   `updateAvailable` is not consulted. Armed release clears on disconnect,
   leaving the view, and after the flash (the reboot disconnects).
5. **Stable path untouched.** `latestRelease(for: .relay)` still reads the
   public repo by `relay-v` prefix, still `cached`, still version-gated. The
   dev fetch never touches `cachedReleaseList` or `cached`.
6. **Release build.** No Relay dev URL, no `RELAY_` prefix string, no PAT
   reference outside `#if DEBUG`. Same check as the 2026-09-08 verification.

Log lines: `[FW] dev RELAY_v2.0-dev.1 → 0x20 build 1`, `[FW] dev armed`,
`[FW] dev cleared`, plus the existing `[RelayDFU]` lines.

## Tasks

1. **Make:** 1–6 above.
2. **Test (Relay, the real flash):** dock an OTAFIX Relay on `relay-v2.0`
   (public) → connect → hold 3 s → Fetch shows `v2.0 (build 1)` → Install →
   trigger, bootloader found, zip flashed, reboot, reconnect, FWV `0x20`.
   `[RelayDFU]` log clean. This run also closes the Relay card's "flash
   dev.1" bench step — no separate nRF Connect run needed.
3. **Test (stable unchanged):** without the hold, the same Relay's firmware
   card still resolves `relay-v2.0` from the public repo and reports up to
   date. A Flag still fetches `PRO_FLAG_…` from Flags-Receivers on the hold.
4. **Test (negatives):** PAT lacking `rareBit-Relay` (or a wrong token) →
   `Dev fetch failed` with the HTTP status, stable path still works after.
   Release configuration: no dev card, no `rareBit-Relay` string, no PAT
   symbol.
5. **Assess + CHANGELOG.md:** History entry; update the Architecture
   `FirmwareService / DFU` line (dev channel now covers all four products,
   two private repos) and the BLE DFU section's product list.
