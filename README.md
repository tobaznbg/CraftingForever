# CraftingForever

World of Warcraft addon for **WoW Forever** (Interface 16001): profession planner, auction house prices, farming tracker, selling panel and sniper. No dependencies.

## Install

The folder in `Interface\AddOns` must be named `CraftingForever`.

With git:

```
cd "C:\Program Files (x86)\World of Warcraft\_forever_\Interface\AddOns"
git clone https://github.com/tobaznbg/CraftingForever.git
```

Update later with `git pull` in that folder, then `/reload` in game.

Without git: download the ZIP (Code → Download ZIP), extract it into `Interface\AddOns` and rename the folder `CraftingForever-main` to `CraftingForever`.

## Use

- `/cf` small tracker window (gold/h, XP/h, loot), `/cf berufe` large window
- Auction house: panel on the right with **Verkaufen**, **Schnäppchen** and **Sniper**
- Tooltips show auction house value and a recommendation

`Data_AH113.lua` and `Data_Market.lua` are price snapshots and only as fresh as the last commit.
