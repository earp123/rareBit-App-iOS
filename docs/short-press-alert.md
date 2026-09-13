# Short Press Alert — Alert 3 on watchOS, copy + delay unit on iOS (13 Sep 2026)

Scope: `rareBit-App-iOS` — watch: `Watch Receiver Watch App/BLEScanner.swift`,
`DeviceDetailView.swift`; phone: `rareBit App/DeviceDetailView.swift`.
Contract owner: `rareBit-Flags-Receivers/docs/short-press-alert.md`
(`common/include/uuids.h`, `RELAY_NOTIFY_*`).

## State today

**Watch** — `didUpdateValueFor` reads `alertBits = byte & 0x03`: `0x01` → flag 1
preset, `0x02` → flag 2 preset, anything else → "Unknown alert source" + a single
`.click`. A relay on `feature/short-press-alert` sending Alert 3 (`0x03`) clicks
once and is otherwise ignored.

**Phone** — the Short Press Alert toggle already shows for every device type with
a config service (Flag, Receiver, RXRLY, Relay), so the receiver-side gate needs no
new control. Two copy problems: the delay label multiplies the raw field by 20 but
the firmware step is 30 ms (`CFG_SHTPRS_DELAY_STEP_MS`), and the info panel says
these features arrive "in firmware 2v0" under a "SETTINGS NOT IN USE" header.

## Contract

Notify byte bits 1–0 are a type field: 0 link event, 1 Alert 1 (slot 1 long
press), 2 Alert 2 (slot 2 long press), **3 Alert 3** — a short press from either
flag, sent only when the relay's own short-press setting is on. Alert 3 does not say
which flag pressed. Link bits 7/6 unchanged.

Receiver / Relay bit 0 now gates Alert 3 on that device; Flag bit 0 still gates
whether the flag sends a short press at all. Both must be on for Alert 3 to reach
the referee — which is what the phone's info text already says.

## Change — watch

1. `BLEScanner.swift`: add `@Published private(set) var shortPressHaptic: HapticPreset
   = .tripleFailure`; `cycleHaptic(for:)` gains `case 3`.
2. `didUpdateValueFor`: `case 0x03: preset = self.shortPressHaptic` with a log line
   `⚡️ Short press alert → …`. The `default` branch stays for anything else.
3. `DeviceDetailView.swift` (watch): third tile beside the two flag icons —
   `flagIcon`-style button labelled `S` (or a bolt glyph), always enabled once
   `isActive`, cycling and previewing `shortPressHaptic`. Ring colour from the preset,
   like the flag tiles.
4. Keep `hapticCooldown` as-is; Alert 3 shares it.

## Change — phone

5. `rareBit App/DeviceDetailView.swift`: delay label `* 20` → `* 30`. One-line fix;
   Android has the same bug and its twin doc carries it.
6. Info panel copy: rewrite the "Short Press Alert" block to the three-type wording
   (Receiver/Relay: "relays short presses as their own alert type; off = short
   presses arrive as the normal Flag 1/2 alert") and note both Flag and
   Receiver/Relay must be on. Drop "will be introduced in firmware 2v0" and the
   "SETTINGS NOT IN USE" header once 2.0 is the shipping stream — gate on
   `firmwareVersionByteById >= 0x20` if you want it exact, otherwise plain copy.

## Test (Sam)

1. Watch on a relay running `feature/short-press-alert`, relay bit 0 on: short
   press either flag → `shortPressHaptic` plays; log shows `0xC3`. Long presses
   unchanged (`0xC1` / `0xC2`).
2. Tap the `S` tile → preset cycles and previews; next short press uses it.
3. Relay bit 0 off → short press plays the slot preset (byte is `0xC1` / `0xC2`).
4. Phone: connect a Flag, slider at 10 → label reads 300, not 200.
5. Phone: info panel copy matches the three-type contract on Receiver and Relay.

## Assess

- `isPlayingHaptic` cooldown is 4 s — a short press inside that window after a
  slot alert is dropped on the watch even though the relay sent it. Pre-existing;
  note it, don't fix it here.
- CHANGELOG on merge: notify byte table gains type 3; delay unit correction.
