# Task: Relay OTA DFU Flow (iOS)

Source of truth: `rareBit-Relay/CHANGELOG.md` → "OTA DFU" section. Firmware side is complete and bench-validated (relay-v1.9 live). This doc specifies the iOS integration.

## Overview

The Relay uses the Adafruit UF2 bootloader's **Nordic legacy DFU** (OTAFIX variant). The app: checks GitHub Releases for updates → triggers DFU via GATT (USB-docked config mode only) → flashes with Nordic's iOS DFU library.

## 1. Update check

- `GET https://api.github.com/repos/earp123/rareBit-firmware-releases/releases/latest` — public, no auth. Rate limit 60 req/hr/IP: **check once per app session, not on a timer.**
- Download the release's `manifest.json` asset:

```json
{
  "product": "relay",
  "tag": "v1.9",
  "release_tag": "relay-v1.9",
  "fw_version_byte": "0x19",
  "dfu_package": "rareBit-Relay-v1.9-dfu.zip",
  "uf2": "rareBit-Relay-v1.9.uf2",
  "dfu_package_sha256": "…",
  "commit": "…",
  "built_at": "…"
}
```

- Version byte: high nibble = major, low nibble = minor (`0x19` = v1.9). Offer update when release byte > device's FW characteristic.
- Download `dfu_package` and **verify SHA-256 against `dfu_package_sha256` before flashing.**
- Future-proofing: when receiver firmware shares this repo, `/latest` becomes unreliable — filter releases by tag prefix `relay-` (or manifest `product`). Fine to note as TODO for now.

## 2. GATT interface

Config service is advertised **only while USB-docked** (device name "rareBit Relay"):

| Characteristic | UUID | Access | Payload |
|---|---|---|---|
| Config service | `23220001-38d5-4b7b-bad0-7dee1eee1b6d` | — | — |
| Config | `23220002-38d5-4b7b-bad0-7dee1eee1b6d` | R/W/notify | 1 byte: bit0 short-press en, bit5 charging, bits7:6 battery |
| FW version | `23220003-38d5-4b7b-bad0-7dee1eee1b6d` | read | 1 byte `0xMN` = vM.N |
| DFU trigger | `23220004-38d5-4b7b-bad0-7dee1eee1b6d` | write | write `0xA8` to enter DFU |

DFU trigger semantics: write single byte `0xA8` → write response returns → device reboots into bootloader **~500 ms later**. The disconnect *is* the success signal.

ATT errors:
- `0x03` Write Not Permitted → device not USB-docked; prompt user to dock it.
- `0x13` Value Not Allowed → wrong magic byte.
- `0x0D` Invalid Attribute Value Length → payload not exactly 1 byte.

## 3. Flashing (Nordic legacy DFU)

- After reboot, bootloader advertises Nordic legacy DFU service `00001530-1212-EFDE-1523-785FEABCD123`. **Scan/filter by that service UUID, not by name** (OTAFIX advertises a board-specific name that differs from the app name and address).
- Use Nordic's [iOS DFU Library](https://github.com/NordicSemiconductor/IOS-DFU-Library); feed the downloaded zip unchanged — it auto-detects legacy protocol. Default settings (PRN on) are correct.
- On completion the bootloader auto-reboots into new firmware. Device is still docked so it re-enters config mode → reconnect and confirm FW characteristic equals manifest `fw_version_byte`.

## 4. Failure / recovery

Interrupted DFU → bootloader marks app invalid and sits in **OTA DFU mode on every boot** (advertising `1530`). Detect this state during scans and offer a retry flash — that retry is the recovery path. No USB or user surgery required.

## 5. Device prerequisite

Flow requires the **OTAFIX bootloader** (flashed at provisioning). Factory XIAO bootloaders (0.6.1) hang at end of OTA uploads — do not test against un-provisioned devices.
