# m4-companion

World of Warcraft addon for **WoW Forever** (Interface 16001) by made four: auction house prices and trends, crafting profits for every profession, investment list, selling panel, sniper and trading ledger. No dependencies.

## Install

**Recommended: the companion app (Windows).**
[Download m4-companion.exe](https://github.com/tobaznbg/m4-companion/releases/latest/download/m4-companion.exe), start it and log in with Discord. It installs the addon into `Interface\AddOns\m4-companion`, keeps the addon and its price data current and updates itself. After an update type `/reload` in game. Windows may warn about an unsigned app: *More info → Run anyway*.

Manually (without the app): download the ZIP (Code → Download ZIP), extract it into `Interface\AddOns` and rename the folder `m4-companion-main` to `m4-companion`. Data files then stay as old as the download.

**Coming from CraftingForever:** close WoW, rename the folder `CraftingForever` to `m4-companion` (or clone anew and delete the old one), and in `WTF\Account\<account>\SavedVariables` rename `CraftingForever.lua` to `m4-companion.lua` and change its first line `CraftingForeverDB = {` to `M4CompanionDB = {` – otherwise the ledger and settings start empty.

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
