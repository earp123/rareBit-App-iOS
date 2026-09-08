# Task: Surface battery read failures and sense faults (iOS)

Source: rareBit-Flags-Receivers CHANGELOG 4 Sep 2026 — "Battery diagnostic
characteristic" + "Battery sense-fault indication". Decision (Sam,
2026-09-08): propagate to **both** apps. Android twin:
`rareBit-Android/docs/battery-diagnostic.md` — keep the rules identical.
Trello: iOS "Improve Battery Level Feature". Scope: `rareBit App/` only
(`BleScanner`, `SmpUuids`, `DeviceDetailView`). Watch app untouched.

---

## Why

The CFG byte's battery bits (7–6) have no "unknown" value. A unit whose ADC
read fails, or whose sense divider is the wrong part (a 680R-for-68k1 batch
was confirmed on the bench), reports **LOW forever** and the app shows a red
glow that is not true. Firmware 2.0 (dev stream) now exposes what it actually
measured, so the app can stop calling a faulted unit a flat one.

## Characteristic

`23220005-38d5-4b7b-bad0-7dee1eee1b6d` — CFG service, **read-only, no notify**,
9 bytes little-endian, appended last (CFG / FWV / DFU-trigger handles unchanged):

| Bytes | Meaning |
|-------|---------|
| 0–1 | raw ADC counts (int16) |
| 2–3 | millivolts at the divider tap (int16); **`-1` (0xFFFF) = read failed** |
| 4–5 | errno from the last attempt (int16); 0 = OK |
| 6 | graded level 0 LOW / 1 MID / 2 HIGH / 3 FULL (same value as CFG bits 7–6) |
| 7 | bit0 USB docked · bit1 charger STAT high · **bit2 sense fault** |
| 8 | sample counter, wraps |

Present on Flag / Receiver ≥ 2.0 only. **Absent** on fielded 1.9 / 1.8 / 10.0
and on the Relay (its ADC is still a stub) — absence is the normal case for a
while and must change nothing.

Firmware caveat worth knowing, not acting on: STAT high also reads high when
nothing drives the pin; sense fault is only unambiguous undocked. We only see
the device docked (config mode), so the app shows what firmware reports and
does no extra inference.

## Behavior

1. **Constant.** `cfgUuids.batt_diag_characteristic` in `SmpUuids.swift`.
2. **Discover + read.** Add it to the `discoverCharacteristics([...])` list for
   the CFG service and `readValue` on discovery, after the CFG read. Re-read on
   every CFG notification (battery bits changed) — CoreBluetooth queues GATT
   ops, so no in-flight guard is needed.
3. **Parse → `BatteryDiag`** stored in `battDiagById[UUID]` (absent =
   characteristic not present): `raw`, `mv`, `errno`, `level`, `docked`,
   `statHigh`, `senseFault`, `count`. One log line per read:
   `[BLE] BATT(<id>) mv=.. err=.. lvl=.. flags=0x.. n=..`.
4. **Do not touch `DeviceConfig` or `BatteryLevel`-from-byte.** The CFG write
   base and the re-apply cache keep deriving from the CFG byte exactly as
   today. Instead add two cases to `BatteryLevel` — `.unavailable
   ("BATTERY_UNAVAILABLE")`, `.senseFault ("BATTERY_SENSE_FAULT")` — and a new
   `effectiveBatteryLevel(for:)` on `BleScanner`, precedence:
   - `diag.senseFault` → `.senseFault`
   - else `diag.mv == -1 || diag.errno != 0` → `.unavailable`
   - else → `batteryLevel(for:)` (CFG bits, unchanged)
   - no diag → `batteryLevel(for:)` (legacy units, Relay)
5. **UI.** `DeviceDetailView`: the Battery label and `batteryGlowColor` read
   `effectiveBatteryLevel(for:)`. Both new cases glow `.yellow` (the existing
   unknown colour — no new colour); labels render as **SENSE FAULT** /
   **UNAVAILABLE**. When diag is present, add one "Battery diagnostic" line to
   the existing info / expandable area: `1043 mV · errno 0 · docked · STAT
   high · #37`. Nothing else moves.
6. **Writes untouched.** Battery bits 6–7 handling and the config re-apply are
   unchanged; the diag is display-only.

## Tasks

1. **Make:** 1–6 above; no new screens.
2. **Test (healthy 2.0 unit):** docked Flag on a 2.0 dev build → diagnostic
   line shows ~1000–1070 mV, errno 0, docked; label and glow match the CFG bits
   exactly as before.
3. **Test (fault paths, temporary bench firmware):** (a) `adc_read()` forced
   to return `-EIO` → **UNAVAILABLE** / yellow; (b) `SENSE_FAULT_MAX_MV`
   raised to 2000 → **SENSE FAULT** / yellow. Revert both hacks. (Firmware's
   red-4x blink is undocked-only, so the LED will not confirm (b) on the dock.)
4. **Test (absence):** fielded 1.9 Flag and a docked Relay → no diagnostic
   line, label / glow unchanged, no discovery errors.
5. **Assess + CHANGELOG.md:** `[BLE] BATT` log for the four runs; confirm no
   CFG write was issued as a side effect. Entry under History; add the
   characteristic to the "iOS ↔ device: CFG service" encoding table.
