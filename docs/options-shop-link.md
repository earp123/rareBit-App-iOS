# Task: Options menu — replace reseller links with the rareBit shop (iOS)

Source: Sam, 2026-09-11 — `rarebitofficial.com/shop` (Wix Stores) is live and
rareBit sells direct now. Both mobile apps drop the third-party reseller links
and the "Buy PRO Sets" sub-menu that only existed to hold them. Android mirrors
this doc (`rareBit-Android/docs/options-shop-link.md`) — keep the label and URL
identical. Trello: "New Options Links" (iOS list). Branch `feature/options-links`.

Scope: `rareBit App/ScanListView.swift`, the `optionsButton` `Menu` only.
No other view, no watch app.

---

## Change

Current menu (`private var optionsButton`, ~line 189):

```
User Manual
Buy PRO Sets ▸
    RefsNeedLoveToo   → refsneedlovetoo.com/…
    The Top Ref       → thetopref.com/…
rareBitOfficial.com
Apple Watch
Support
```

Target — flat, one level:

```
User Manual
Shop                  → https://www.rarebitofficial.com/shop
rareBitOfficial.com
Apple Watch
Support
```

1. Delete the nested `Menu { … } label: { Label("Buy PRO Sets", systemImage: "cart") }`
   block, including both reseller `Link`s inside it.
2. In its place, in the same position (second item), add one flat link:
   ```swift
   Link(destination: URL(string: "https://www.rarebitofficial.com/shop")!) {
       Label("Shop", systemImage: "cart")
   }
   ```
3. Nothing else in the menu changes (User Manual, rareBitOfficial.com, Apple
   Watch, Support keep their URLs and icons).

## Tasks

1. **Make:** the edit above. After it, `grep -ri "refsneedlovetoo\|thetopref"`
   across the repo returns nothing.
2. **Test:** build and run on a phone (`ship.sh`). Tap **Options** → menu is one
   level, five items, Shop is second. Tap Shop → Safari opens
   `rarebitofficial.com/shop` and the store page loads. Tap each remaining item
   once to confirm it still opens its destination.
3. **Assess:** no layout shift on the scan list; menu order matches the target
   above; no leftover reseller strings anywhere in the project.
4. **CHANGELOG.md:** one History entry (`2026-09-xx — Options menu: direct shop
   link replaces reseller sub-menu (iOS)`) plus a one-line touch to the
   `ScanListView` bullet under App Architecture if it mentions the menu.
