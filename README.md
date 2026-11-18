# m4-companion

## ⬇️ [Download: m4-companion.exe (Windows)](https://github.com/tobaznbg/m4-companion/releases/latest/download/m4-companion.exe)

**Das ist alles, was du brauchst.** Die App installiert das Addon selbst, hält es und die Preisdaten aktuell und aktualisiert sich selbst.

1. `m4-companion.exe` herunterladen und starten.
2. Mit Discord anmelden (du musst auf dem made-four-Discord sein).
3. WoW starten – fertig. Nach Updates im Spiel `/reload`.

Windows warnt evtl. vor einer unbekannten App: *Weitere Informationen → Trotzdem ausführen*.

> ⚠️ **Bitte nicht** den Code (grüner Knopf „Code → Download ZIP“) herunterladen. Ohne die App fehlen die aktuellen Preise, der Verlauf, der Abgleich zwischen PCs und die Discord-Meldungen – und das Addon wird nicht aktualisiert.

---

*English: download and run **m4-companion.exe** above, log in with Discord, start WoW. The app installs and updates the addon – do not download the source code.*

World of Warcraft addon for **WoW Forever** by made four: auction house prices and trends, crafting profits for every profession, sniper, trading ledger (P&L), item details with a 7-day price history.

## Use

- `/m4` (or `/cf`, or the minimap button) main window; right-click the minimap button for the trading ledger
- Auction house: own tabs **Anlage**, **Trends**, **Crafting**, **Händler**; panel on the right with **Verkaufen** and **Sniper**
- Tooltips: price now, range, trend, demand, recommendation

The data files (`Data_*.lua`) are snapshots; the companion app keeps them current.

## Development and releases

Two branches:

- **`dev`** – all development happens here. Push as often as you like; nothing is published.
- **`main`** – what the players get. A push to `main` starts a release that waits for the owner's approval (e-mail / GitHub app, "Review deployments"); after the click the addon reaches all companion apps within minutes.

Workflow:

1. On your dev PC, clone the repo straight into the AddOns folder and work on `dev`:
   ```
   cd "C:\Program Files (x86)\World of Warcraft\_forever_\Interface\AddOns"
   git clone -b dev https://github.com/tobaznbg/m4-companion.git m4-companion
   ```
   The companion app never touches an addon folder that contains `.git`, so your working copy stays as it is. Test with `/reload` (a new file in the `.toc` needs a game restart).
2. Commit and push to `dev`. Pull before you start (`git pull --rebase`) – more than one person works here.
3. Bump `## Version:` in `m4-companion.toc` for every release.
4. "Go": merge `dev` into `main` (pull request `dev` → `main` on GitHub, or `git checkout main && git merge --ff-only dev && git push`). Then the owner approves the waiting release.

Changes to README or `.github` alone do not start a release. Never push work in progress to `main`.
