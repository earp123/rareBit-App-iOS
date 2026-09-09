# Task: Development firmware channel (iOS) — fetch and flash the latest dev build

Source: rareBit-Flags-Receivers CHANGELOG "Development release channel (2 Sep
2026)" + `.github/workflows/release-dev.yml`. Decision (Sam, 2026-09-08): give
the iOS app the same developer plumbing Android has — a hidden gesture reveals
a dev card that fetches the newest `development`-branch pre-release from the
private firmware repo and arms it on the DFU card. Trello: iOS "Dev Mode DFU".
Scope: `rareBit App/` only. Watch app untouched. Stable path must not change.

---

## The mechanism is already there

`DeviceDetailView.swift` — the title card has
`.onLongPressGesture(minimumDuration: 3.0) { forceShowDfu = true }`. That is
the iOS twin of Android's 10 s hold (`DeviceDetailFragment`, `DEV_HOLD_MS`).
Keep the 3 s and the no-visual-cue behavior; extend what it reveals.

Android reference (`FirmwareRepository.fetchDevReleaseInfo`,
`DeviceDetailFragment` dev card): two buttons — *Show DFU card* and *Fetch dev*
— a status line, and on success the DFU button relabels to
"Install dev v…" with the release armed as `pendingRelease`. Mirror that.

## Firmware contract (private repo `earp123/rareBit-Flags-Receivers`)

- `GET /repos/earp123/rareBit-Flags-Receivers/releases` — **needs a PAT**
  (Contents: read on that repo). `Authorization: Bearer <PAT>`.
- Dev release: `target_commitish == "development"`, `prerelease == true`, tag
  `<PREFIX>_v<M.N.P>-dev.<build>` with prefix `PRO_FLAG_` / `PRO_RX_` / `RXRLY_`
  (this repo's old naming, not the public `<slug>-v` scheme). Newest first;
  the newest 5 per product are kept, older ones are deleted.
- Assets: `<base>.bin` (SMP OTA image), `<base>.bin.sha256`,
  `<base>-dfu_application.zip`, `<base>-merged.hex`, `manifest.json`.
- `manifest.json` = the public `release.yml` keys **plus** `channel`
  ("development"), `branch`, `build` (int), `full_version` ("2.0.0"),
  `commit`, `run_url`, `built_at`. `product` is the slug (`flag` / `rx` /
  `rxrly`) — same as `FirmwareProduct.rawValue`, so the existing manifest
  product check holds.
- **Private-repo asset downloads must use the asset's API `url` with
  `Accept: application/octet-stream`** (+ the PAT). `browser_download_url`
  returns 404 on a private repo. `Asset.url` is already in the model.
- The version byte is pinned per stream (flag/rx 0x20, RXRLY 0xA1) — dev
  builds are told apart by `build`, not by version. **Do not version-compare**
  a dev release against the device; the developer chose it.

## Behavior

1. **PAT.** Reuse the token already in the gitignored `Secrets.swift` (it was
   used by the pre-2026-09-04 private-repo fetch). If the file or symbol is
   gone, define `enum Secrets { static let githubPAT: String }` there, add a
   `Secrets.example.swift`, and stop — ping Sam for the token. Wrap every dev
   reference in `#if DEBUG` so the PAT never ships in a Release / TestFlight
   binary; Sam's `ship.sh` installs Debug, so his path is covered.
2. **Models.** `GitHubRelease` gains optional `target_commitish: String?` and
   `prerelease: Bool?`. `FirmwareManifest` gains optional `channel`, `build`
   (Int), `full_version`, `commit`, `run_url` — all optional so public
   manifests keep decoding unchanged.
3. **`FirmwareReleaseService.latestDevRelease(for product:)`.** Separate
   request to the private releases URL with the PAT. Filter
   `target_commitish == "development" && prerelease == true && tag_name.hasPrefix(devPrefix)`
   where `devPrefix` maps `.flag → "PRO_FLAG_"`, `.rx → "PRO_RX_"`,
   `.rxrly → "RXRLY_"` (`.relay` → not supported, throw). Pick the highest
   `dev.<build>` suffix (the list is newest-first; parsing the suffix is the
   guard against ordering assumptions). Decode `manifest.json` through the
   existing path and product check. **Never write into `cached[product]`** —
   dev builds churn and the stable path must not see them. Return a
   `FirmwareUpdateRelease` tagged as dev (a `channel` enum on the struct, or a
   sibling type — keep whatever is smallest).
4. **Auth-aware download.** `downloadAsset` takes the release's channel: public
   → `browser_download_url` as today; dev → API `url` + octet-stream + PAT. SHA
   verification (`downloadVerifiedOtaImage`) is unchanged and still mandatory.
5. **UI (`DeviceDetailView`).** With `forceShowDfu` true and `#if DEBUG`, show a
   dev card above/inside the DFU card: status text + *Fetch dev build*. States:
   `Fetching from 'development'…` → `Dev v2.0.0 build 57 armed — install from
   the DFU card` / `No dev release on 'development' yet` / `Dev fetch failed:
   <error>`. Arms `pendingDevRelease` on `BleScanner`.
6. **Install path.** When a dev release is armed, the DFU card's primary button
   reads `Install dev v2.0.0 (build 57)` and installs **that** release:
   `downloadVerifiedOtaImage` → `startDfuFromURL`, skipping
   `checkFirmwareUpdate`'s newer-than-device gate. Existing DFU progress /
   reboot / version-confirm flow unchanged. Clear the armed release on
   disconnect, on leaving the view, and after a successful flash.
7. **Product mapping.** Use `smpFirmwareProduct(for:deviceType:)` as today, so a
   receiver on RXRLY firmware fetches `RXRLY_`, not `PRO_RX_`. Cross-grade
   (rx ↔ rxrly) via the dev channel is out of scope.
8. **Stable path untouched.** The public repo never carries dev builds
   (`release.yml` publishes from `production` only), so iOS needs no
   prerelease guard there — Android needed one only because it still reads
   stable from the private repo.

## Tasks

1. **Make:** 1–8 above. Log lines: `[FW] dev <tag> → <fwbyte> build <n>` on
   fetch, `[FW] dev armed` / `[FW] dev cleared`.
2. **Test (Flag):** connect a 2.0-stream Flag → hold the title card 3 s → dev
   card → Fetch shows the newest `PRO_FLAG_v2.0.0-dev.<n>` → Install → SMP DFU
   completes, device reboots, FWV reads `0x20`, `dfuStateText` confirms.
3. **Test (Receiver / RXRLY):** plain rx fetches `PRO_RX_`; a receiver on RXRLY
   firmware fetches `RXRLY_`. One of the two flashed end-to-end.
4. **Test (negatives):** bad PAT → clear `Dev fetch failed`, stable
   *Install Update* still works afterwards (no cache poisoning). Release
   configuration build → long press still shows the DFU card, no dev card, no
   PAT symbol referenced.
5. **Assess + CHANGELOG.md:** `[FW]` log for the runs; History entry; update
   the Architecture line for `FirmwareService / DFU` and the CLAUDE.md gotcha
   that says the PAT is unused.
