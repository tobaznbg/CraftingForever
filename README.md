# m4-companion

World of Warcraft addon for **WoW Forever** (Interface 16001) by made four: auction house prices and trends, crafting profits for every profession, investment list, selling panel, sniper and trading ledger. No dependencies.

## Install

The folder in `Interface\AddOns` must be named `m4-companion`.

With git:

```
cd "C:\Program Files (x86)\World of Warcraft\_forever_\Interface\AddOns"
git clone https://github.com/tobaznbg/m4-companion.git
```

Update later with `git pull` in that folder, then `/reload` in game.

Without git: download the ZIP (Code → Download ZIP), extract it into `Interface\AddOns` and rename the folder `m4-companion-main` to `m4-companion`.

**Coming from CraftingForever:** close WoW, rename the folder `CraftingForever` to `m4-companion` (or clone anew and delete the old one), and in `WTF\Account\<account>\SavedVariables` rename `CraftingForever.lua` to `m4-companion.lua` and change its first line `CraftingForeverDB = {` to `M4CompanionDB = {` – otherwise the ledger and settings start empty.

## Use

- `/cf` or `/m4` small tracker window, `/cf berufe` large window, `/cf handel` trading ledger
- Auction house: own tabs **Anlage**, **Trends**, **Crafting**, **Händler**; panel on the right with **Verkaufen** and **Sniper**
- Tooltips: price now, range, trend, demand, recommendation

The data files (`Data_*.lua`) are snapshots and only as fresh as the last commit; the companion app (in preparation) keeps them current.
