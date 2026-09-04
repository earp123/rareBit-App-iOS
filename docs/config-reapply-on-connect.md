# Task: Connect-time config re-apply (iOS) — safety net for volatile-config units

Source: rareBit-Android CHANGELOG 2026-09-04 "Config persistence findings":
fielded Flags/Receivers keep a factory bootloader that write-locks the firmware
settings region, so the CFG byte is volatile and reverts on power cycle.
Decision (Sam, 2026-09-04): firmware moves its settings pages inside slot 0
(`rareBit-Flags-Receivers` `docs/config-persistence-in-slot.md`); **both mobile
apps** add this re-apply as the safety net for units power-cycled before that
firmware reaches them. Android implements the same behavior from
`rareBit-Android/docs/config-reapply-on-connect.md` — keep the rules identical.
Scope: iOS app only (`rareBit App/`, `BleScanner` CFG path). Watch app untouched.

---

## Behavior (identical to Android)

1. **Cache on write.** After every user-initiated CFG write that succeeds
   (`didWriteValueFor` with no error), store `byte & 0x3F` (bits 0–5 only) per
   device, keyed by the peripheral `identifier`. `UserDefaults` is fine.
2. **Re-apply on connect.** After the initial CFG read completes and before
   relying on notifications:
   - if a cached value exists **and** `cached != 0x00`
   - **and** the device reports bits 0–5 == `0x00` (looks factory-reset)
   → write `(deviceByte & 0xC0) | cached` through the existing write path
   (which already preserves unrelated bits from the last device-reported byte).
   Otherwise do nothing.
3. Never cache from a device read — only from successful user writes.
4. UI populates from the re-applied value via the existing notify/optimistic
   path; no dialog. One log line per connect: `reapply <id> 0x.. -> 0x..` or
   `reapply skip (persisted / no cache)`.

Rationale for "only when device reads factory default" (vs. "write when
different"): a config set from another phone is not silently overwritten.
Accepted edge: deliberately zeroed config on phone B is restored by phone A's
cache on A's next connect. Low risk, single-referee ownership.

## Tasks

1. **Make:** cache-on-write + re-apply-on-connect in `BleScanner`'s CFG handling.
2. **Test (volatile unit):** Flag on factory 1.9 bootloader running a 2.0 build
   (Android dev DFU path can flash it — iOS has no dev channel yet). Set short
   press on + delay → power-cycle the Flag → reconnect → detail view shows the
   setting and a Flag short press alerts a Receiver. Kill the app between steps.
3. **Test (persisting unit):** SWD-flashed dev board → `reapply skip (persisted)`,
   no write issued.
4. **Assess:** console logs for both runs; no write on fresh install (empty
   cache); battery bits 6–7 untouched.
5. **CHANGELOG.md:** History entry + Features line; note it is the safety net and
   firmware-side persistence is the primary fix.

## Not in this task (noted so it is not lost)

- Prerelease guard on the firmware fetch: iOS reads only the public
  `rareBit-firmware-releases` repo, which carries no dev prereleases, so the
  guard is moot until iOS gets a development DFU channel (Trello "Dev Mode DFU",
  iOS list). Add it in that task, mirroring Android `findRelease`.
