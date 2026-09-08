# Task: Scan filter consolidation (iOS) — CFG-UUID-only, gated

Source: Trello Firmware "Config Service in ad packet"
(`rareBit-Flags-Receivers/docs/cfg-uuid-in-docked-adv.md`). Decision (Sam,
2026-09-08): phones must never connect to the Relay service (`33210001-…`);
it is for smartwatches only. Android twin:
`rareBit-Android/docs/scan-filter-consolidation.md`.

---

## State

iOS already rejects Relay-service advertisers in `didDiscover`
(`passesServiceFilter = advServices.contains(cfg) || advServices.isEmpty`), so
the Android Phase 1 fix has no iOS counterpart. What remains is the
`CLAUDE.md` TEMP note: empty-adv rareBit devices are accepted because fielded
firmware advertises no service UUID while docked.

## Phase 2 — gated on the fleet

Once every fielded Flag / Receiver / Relay advertises the CFG UUID while
docked (firmware 2.0 in production **and** units updated — Sam's call):

- `scanForPeripherals(withServices: [cfgUuids.service])` — the OS does the
  filtering, which also unlocks background scanning.
- In `didDiscover`, drop the `advServices.isEmpty` escape hatch; the name
  check stays for typing (the name arrives in the scan response — active scan,
  iOS default).
- Keep the legacy-DFU bootloader match (`legacyDfuUuids.service`) as a second
  scan target or a separate scan — it is not a CFG advertiser and must still be
  found during Relay DFU recovery.
- Remove the TEMP note from `CLAUDE.md`.
- Cost: pre-2.0 units become invisible to the app and can no longer be
  updated from it. That is why this is gated.

## Tasks (Phase 2 only — do not start until the gate is cleared)

1. **Make:** the four bullets above.
2. **Test:** docked 2.0 Flag, docked 2.0 Relay, undocked RXRLY → the two
   docked units list, the RXRLY does not; Relay DFU trigger → bootloader still
   discovered and flashed.
3. **Assess:** scan list stable across three scan cycles; no device duplicated
   or renamed between adv and scan-response updates.
4. **CHANGELOG.md:** entry under History; update the BleScanner architecture
   line ("Scans for rareBit-named devices" → CFG service).
