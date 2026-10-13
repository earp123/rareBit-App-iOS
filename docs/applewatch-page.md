# Apple Watch page for rarebitofficial.com (13 Oct 2026)

Page: `docs/web/applewatch-page.html` — the Garmin page template
(`rareBit-Garmin/docs/web/garmin-page.html`) with the download table
replaced by the App Store link (`apps.apple.com/us/app/rarebit/id6758751793`).
Icons are the traced slide-deck sprite; `?embed=1` hides header/footer for
the Wix iframe. Served from GitHub Pages on this repo once enabled:
`https://earp123.github.io/rareBit-App-iOS/web/applewatch-page.html`.

## Two things to land (Mac, one line each)

1. **Screenshots** — the ASC set already captured on the Mac mini. The page
   references six of them by name under `docs/web/screenshots/`:
   ```
   cp ~/Desktop/rareBit-ASC-screenshots/final/watch-46mm/{01-home-searching,02-playback-haptic,04-timer-running,05-timer-paused,06-edit-mode,08-timer-stoppage-running}.png docs/web/screenshots/
   git add docs/web/screenshots && git commit -m "Apple Watch page: screenshots" && git push
   ```
   (416×496 PNGs; the page frames them in the watch's rounded-rect shape.)
2. **GitHub Pages** — not reachable from the project console:
   ```
   gh api --method POST repos/earp123/rareBit-App-iOS/pages -f "source[branch]=main" -f "source[path]=/docs"
   ```

## Wix (Sam, Editor)

Same recipe as Garmin: blank page "Apple Watch" under Smart Watch (replacing
the current /applewatch content), page background `#000000`, Embed a Site →
`https://earp123.github.io/rareBit-App-iOS/web/applewatch-page.html?embed=1`,
stretch full width, height ≈ 3300 px desktop / ≈ 4600 px mobile, trim to fit.

## Copy facts used (from CHANGELOG + App Store listing)

Watch connects to the Relay itself (CoreBluetooth on watchOS); tap = start /
pause, crown edits duration; Stoppage setting: tap opens / closes a segment,
triple tap every 20 s while open; expiry alarm buzzes until a screen tap;
Alert 3 = one shared tap, Relay firmware permitting. Requirements shown:
iOS 26 / watchOS 26 (current App Store listing).
