-- Crafting: table (auction house tab and main window). First a choice of all crafting professions (with icon),
-- then every recipe of that profession that makes an item (Data_Recipes.lua, Blizzard
-- API), priced via ns.Item: buy = merchant, else cheapest offer; sell = cheapest offer
-- - 1 copper - 5 % cut, or a merchant if higher. Learned state and skill come from the
-- character's own profession scan (open the profession window once); unlearned recipes
-- get a red marker and, where the planner data knows it, how to learn them.
-- Also answers what a recipe item teaches (ns.RecipeTeaches / ns.RecipeTeachInfo) for the
-- tooltip and the item detail window.
-- Opening the tab starts a live scan (every 15 min at most, only with the AH open).
local ADDON, ns = ...

local function money(c) return c and ns.FormatMoney(c, true) or "–" end

-- Copper per unit to buy a reagent (merchant, else cheapest offer, else the average
-- when it is not on offer right now), and whether it comes from a merchant.
local function buy(itemID)
  return ns.Item.BuyCost(ns.Item(itemID))
end

-- Copper per unit the product brings (undercut, minus cut; or a merchant), and
-- whether via the auction house.
local function sell(itemID)
  return ns.Item.SellNet(ns.Item(itemID))
end

local SOURCES = { ["6"] = "Lehrer", ["5"] = "Händler", ["2"] = "Drop", ["4"] = "Quest" }

-- "Lehrer ab 165 (24s)", "Händler/Drop ab 140" etc., and the skill needed.
local function learnInfo(professionID, recipeID)
  local data = ns.DataBySkillLine and ns.DataBySkillLine[professionID]
  local d = data and data[recipeID]
  if not d then return "unbekannt", nil end
  local parts = {}
  for code in tostring(d[7] or ""):gmatch("[^+]+") do table.insert(parts, SOURCES[code] or code) end
  local text = (#parts > 0 and table.concat(parts, "/") or "Quelle ?") .. " ab " .. (d[5] or d[1] or "?")
  if d[6] and d[6] > 0 then text = text .. " (" .. money(d[6]) .. ")" end
  return text, d[5] or d[1]
end

-- The character's own profession scans: professionID -> { scan, byItem = { [craftedItemID] =
-- { recipeID (spell), recipe } } } (learned state and skill come from the game).
local function ownScans()
  local own, prefix = {}, ns.CharKey() .. ":"
  for key, scan in pairs(ns.db.recipes or {}) do
    if key:sub(1, #prefix) == prefix and scan.professionID then
      local byItem = {}
      for recipeID, r in pairs(scan.recipes or {}) do
        -- Several recipes can make the same item: a learned one wins.
        if r.out and (not byItem[r.out] or r.learned) then byItem[r.out] = { id = recipeID, r = r } end
      end
      own[scan.professionID] = { scan = scan, byItem = byItem }
    end
  end
  return own
end

-- All recipes of one profession (Data_Recipes.lua) that make an item, priced via ns.Item.
local function rows(filter, professionID)
  local list = {}
  local data = ns.RecipeData and ns.RecipeData[professionID]
  if not data then return list end
  local mine = ownScans()[professionID]
  for rid, rec in pairs(data.recipes) do
    local out, quantity, reagentList = rec[2], rec[3] or 1, rec[4] or {}
    local known = mine and out and mine.byItem[out]
    local learned = known and known.r.learned and true or false
    if out and (learned or filter ~= "learned") then
      local cost = ns.Item.MaterialCost(reagentList)
      if cost then
        local reagents = {}
        for i = 1, #reagentList, 2 do table.insert(reagents, { i = reagentList[i], n = reagentList[i + 1] }) end
        local unitValue, onAH = sell(out)
        local value = unitValue * quantity
        local profit = value - cost
        if filter ~= "profit" or (profit > 0 and onAH) then
          local learn, need = nil, nil
          if not learned then
            if known then learn, need = learnInfo(professionID, known.id) else learn = "Quelle ?" end
          end
          local rank = mine and mine.scan.rank or 0
          local tooHigh = not learned and (not mine or (need and need > rank)) or false
          -- 0 learned, 1 learnable now, 2 later: what can be made now comes first.
          local group = learned and 0 or (tooHigh and 2 or 1)
          table.insert(list, { itemID = out, recipe = rec[1], profession = data.name,
            cat = known and known.r.cat, spell = known and known.id or rid, pid = professionID,
            score = (2 - group) * 1e12 + profit, learned = learned, learn = learn, tooHigh = tooHigh,
            unsure = ns.Item.Unsure(ns.Item(out)), nowPrice = ns.Item(out).now,
            cost = cost, unitCost = cost / quantity, value = value, profit = profit, onAH = onAH, demand = ns.Item(out).demand or 0,
            produced = quantity, reagents = reagents })
        end
      end
    end
  end
  return list
end

-- Name of the character's profession that makes the item with a learned recipe, or nil.
-- (The P&L books sales of such items to that profession when no craft was logged.)
function ns.CraftedBy(itemID)
  for pid, mine in pairs(ownScans()) do
    local known = mine.byItem[itemID]
    if known and known.r.learned then
      local data = ns.RecipeData and ns.RecipeData[pid]
      return data and data.name or mine.scan.name
    end
  end
end

-- Material cost per unit of an item the character can make with a learned recipe (the
-- cheapest such recipe), or nil. Used as the lowest sensible selling price.
function ns.CraftingCost(itemID)
  local best
  for pid, mine in pairs(ownScans()) do
    local known = mine.byItem[itemID]
    if known and known.r.learned then
      local data = ns.RecipeData and ns.RecipeData[pid]
      for _, rec in pairs(data and data.recipes or {}) do
        if rec[2] == itemID then
          local cost = ns.Item.MaterialCost(rec[4])
          if cost then
            cost = cost / (rec[3] or 1)
            if not best or cost < best then best = cost end
          end
        end
      end
    end
  end
  return best
end

-- Recipe items ----------------------------------------------------------------------
-- What a recipe item ("Muster: Dämmerrüstung") teaches: the watch list (Data_RecipeWatch.lua)
-- first, else the item name without its prefix, looked up in the skill data (Data_Skill.lua,
-- spell ids, skill to learn) and the recipe data (Data_Recipes.lua). The name index is built
-- on the first call, every item's answer is kept.

-- Prefix -> professions it can stand for (narrows down recipes of the same name).
local RECIPE_PREFIXES = {
  { "Rezept", { Alchimie = true, Kochkunst = true } },
  { "Muster", { Lederverarbeitung = true, Schneiderei = true } },
  { "Pläne", { Schmiedekunst = true } },
  { "Bauplan", { Ingenieurskunst = true } },
  { "Schema", { Ingenieurskunst = true } },
  { "Schematic", { Ingenieurskunst = true } },
  { "Formel", { Verzauberkunst = true } },
  { "Handbuch", { ["Erste Hilfe"] = true } },
}

-- Short profession names for compact lines ("Leder 300").
local SHORT = { Lederverarbeitung = "Leder", Schmiedekunst = "Schmied", Verzauberkunst = "Verzauber",
  Ingenieurskunst = "Ingenieur", Kochkunst = "Kochen" }
function ns.ProfessionShort(name) return SHORT[name] or name or "?" end

-- Lower case without spaces and dashes: "Waffe – Kreuzfahrer" = "Waffe - Kreuzfahrer",
-- "Fallschirm-Umhang" = "Fallschirmumhang".
local function norm(name)
  local s = tostring(name or ""):lower():gsub("\226\128\147", ""):gsub("\226\128\148", "")
  s = s:gsub("[%s%-]+", "")
  return s
end

-- The recipe name in a recipe item's name and the professions its prefix stands for;
-- nil if it has none of the prefixes.
local function stripPrefix(name)
  if type(name) ~= "string" then return nil end
  for _, prefix in ipairs(RECIPE_PREFIXES) do
    local rest = name:match("^" .. prefix[1] .. ": (.+)$")
    if rest then return rest, prefix[2] end
  end
end

-- Other spellings of the same recipe: "Eisen in Gold transmutieren" is the spell
-- "Transmutieren: Eisen in Gold", "Stiefel verzaubern - Geschwindigkeit" is "Stiefel - Geschwindigkeit".
local function spellings(rest)
  local list = { rest }
  local what = rest:match("^(.+) transmutieren$")
  if what then table.insert(list, "Transmutieren: " .. what) end
  local slot, effect = rest:match("^(.+) verzaubern %- (.+)$")
  if slot then table.insert(list, slot .. " - " .. effect) end
  return list
end

-- One recipe out of several of the same name: the prefix's professions, then the ones the
-- skill data knows (learnable from an item; the recipe data also lists variants made by
-- other means), then the same era (Forever's own recipe items have ids above 200000 and
-- make items above 200000). nil if it stays ambiguous.
local NEW_IDS = 200000
local function choose(list, professions, itemID)
  local function keep(test)
    local out = {}
    for _, c in ipairs(list) do if test(c) then table.insert(out, c) end end
    if #out > 0 then list = out end
  end
  if professions then keep(function(c) return professions[c.profession] end) end
  if #list > 1 then keep(function(c) return c.spell ~= nil end) end
  if #list > 1 then keep(function(c) return c.product and (c.product > NEW_IDS) == (itemID > NEW_IDS) end) end
  return #list == 1 and list[1] or nil
end

local byName, byProduct   -- normalized recipe name / product item -> { candidates }
local function addCandidate(c)
  local key = norm(c.name)
  local list = byName[key]
  if not list then list = {}; byName[key] = list end
  for _, other in ipairs(list) do
    -- The same recipe from the other data file (or another rank making the same item): fill gaps.
    if other.pid == c.pid and other.product == c.product then
      for k, v in pairs(c) do if other[k] == nil then other[k] = v end end
      return
    end
  end
  table.insert(list, c)
  if c.product then
    byProduct[c.product] = byProduct[c.product] or {}
    table.insert(byProduct[c.product], c)
  end
end

local function buildIndex()
  byName, byProduct = {}, {}
  -- Skill data first: it knows the spell and the skill needed to learn it.
  for pid, prof in pairs(ns.SkillData or {}) do
    for spell, d in pairs(prof.recipes or {}) do
      if d.name then
        addCandidate({ pid = pid, profession = prof.name, spell = spell, name = d.name, product = d.out,
          qty = d.qty or 1, reagents = d.r, skill = d[5] })
      end
    end
  end
  for pid, data in pairs(ns.RecipeData or {}) do
    for recipeID, rec in pairs(data.recipes or {}) do
      if rec[1] then
        addCandidate({ pid = pid, profession = data.name, recipeID = recipeID, name = rec[1], product = rec[2],
          qty = rec[3] or 1, reagents = rec[4] })
      end
    end
  end
end

local function professionID(name)
  for pid, prof in pairs(ns.SkillData or {}) do if prof.name == name then return pid end end
  for pid, data in pairs(ns.RecipeData or {}) do if data.name == name then return pid end end
end

local teaches = {}   -- itemID -> result or false (not a recipe item / not found)

-- ns.RecipeTeaches(itemID) -> { profession, pid, skill, product (nil for enchantments), qty,
--   reagents = { itemID, count, ... }, spell, name, from = "watch"|"name" } or nil.
function ns.RecipeTeaches(itemID)
  if not itemID then return nil end
  local known = teaches[itemID]
  if known ~= nil then return known or nil end
  local watch = ns.RecipeWatch and ns.RecipeWatch[itemID]
  local name = ns.ItemNames and ns.ItemNames[itemID]
  if not name and ns.ItemName then
    name = ns.ItemName(itemID)
    -- Not loaded yet ("Item 123"): ask again next time instead of remembering "no recipe".
    if not watch and (not name or name:match("^Item %d+$")) then return nil end
  end
  local rest, professions = stripPrefix(name)
  if not watch and not rest then teaches[itemID] = false return nil end
  if not byName then buildIndex() end
  local named = {}
  for _, spelling in ipairs(rest and spellings(rest) or {}) do
    for _, c in ipairs(byName[norm(spelling)] or {}) do table.insert(named, c) end
  end
  local pick
  if watch then
    -- The watch list names the product (or, for enchantments, the profession): it decides.
    local list = watch.product and byProduct[watch.product] or named
    for _, c in ipairs(list) do
      if c.profession == watch.profession and (not pick or (c.skill or 0) < (pick.skill or 0)) then pick = c end
    end
    pick = pick or { profession = watch.profession, pid = professionID(watch.profession),
      product = watch.product, qty = 1 }
  else
    pick = choose(named, professions, itemID)
  end
  local result = false
  if pick then
    result = { profession = pick.profession, pid = pick.pid, skill = pick.skill or (watch and watch.skill),
      product = pick.product, qty = pick.qty or 1, reagents = pick.reagents, spell = pick.spell,
      name = pick.name or rest, from = watch and "watch" or "name" }
  end
  teaches[itemID] = result
  return result or nil
end

-- The character's state for a taught recipe: { rank, learned } from the own scan of that
-- profession, nil without one (profession missing or its window never opened).
local function ownState(t)
  local prefix = ns.CharKey() .. ":"
  for key, scan in pairs(ns.db and ns.db.recipes or {}) do
    if key:sub(1, #prefix) == prefix and scan.professionID == t.pid then
      local learned = false
      for id, r in pairs(scan.recipes or {}) do
        if r.learned and ((t.product and r.out == t.product)
          or (not t.product and (id == t.spell or norm(r.name) == norm(t.name)))) then
          learned = true
          break
        end
      end
      return { rank = scan.rank or 0, learned = learned }
    end
  end
end

-- Everything the tooltip and the detail window show for a recipe item, or nil:
-- { teaches, own, cost (material per unit made, nil if a price is missing), missing (item
--   without price), value / onAH (product sells net per unit), profit, product (ns.Item),
--   recipeNow (the recipe item itself in the AH) }
function ns.RecipeTeachInfo(itemID)
  local t = ns.RecipeTeaches(itemID)
  if not t then return nil end
  local info = { teaches = t, own = ownState(t), recipeNow = ns.Item(itemID).now }
  if t.reagents then
    local cost, missing = ns.Item.MaterialCost(t.reagents)
    info.cost, info.missing = cost and cost / (t.qty or 1), missing
  end
  if t.product then
    info.product = ns.Item(t.product)
    info.value, info.onAH = ns.Item.SellNet(info.product)
    if info.cost then info.profit = info.value - info.cost end
  end
  return info
end

-- "schon gelernt", "du: Leder 150" (green when the skill is reached) or "du: kein Leder-Scan".
function ns.RecipeOwnText(info)
  local t, own = info.teaches, info.own
  local prof = ns.ProfessionShort(t.profession)
  if not own then return "|cffff6b6bdu: kein " .. prof .. "-Scan|r" end
  if own.learned then return "|cff5fd38dschon gelernt|r" end
  local reached = not t.skill or own.rank >= t.skill
  return (reached and "|cff5fd38d" or "|cffffb547") .. "du: " .. prof .. " " .. own.rank .. "|r"
end

-- Crafting professions for the chooser, ranked by the cloud's rating (Data_Professions.lua):
-- how many recipes bring gold sustainably (profit with demand) and the best one; the chart
-- is that rating over the last days. The character's skill is shown for own professions.
local function professions()
  local own, list = ownScans(), {}
  local stats = ns.ProfessionStats and ns.ProfessionStats.professions or {}
  for id, data in pairs(ns.RecipeData or {}) do
    local mine, s = own[id], stats[id]
    local lines, series = {}, {}
    if s then
      lines[1] = string.format("%d Rezepte lohnen", s[1] or 0)
      local best = s[2] and data.recipes[s[2]]
      if best then lines[2] = best[1] .. "  |cff5fd38d" .. money(s[3]) .. "|r" end
      for _, point in ipairs(s.series or {}) do table.insert(series, point[3] or 0) end
    end
    table.insert(list, { key = id, label = data.name, icon = data.icon,
      info = mine and string.format("dein Skill %d", mine.scan.rank or 0) or "",
      lines = lines, series = series, score = s and s[5] or 0 })
  end
  table.sort(list, function(a, b)
    if a.score ~= b.score then return a.score > b.score end
    return a.label < b.label
  end)
  return list
end

-- Reagents for `count` crafts: need, have (bags + bank), to buy, unit price, cost.
local function detail(e, count)
  local rows, total, buyTotal = {}, 0, 0
  for _, reagent in ipairs(e.reagents or {}) do
    local need = (reagent.n or 1) * count
    local have = ns.Costs.Owned(reagent.i)
    local toBuy = math.max(0, need - have)
    local unit, vendor = buy(reagent.i)
    unit = unit or 0
    total = total + need * unit
    buyTotal = buyTotal + toBuy * unit
    table.insert(rows, { itemID = reagent.i, cells = {
      tostring(need),
      (have >= need and "|cff5fd38d" or "|cffffb547") .. have .. "|r",
      toBuy > 0 and tostring(toBuy) or "|cff5fd38d–|r",
      money(unit) .. (vendor and " |cff99999eH|r" or ""),
      toBuy > 0 and money(toBuy * unit) or "–",
    } })
  end
  local produced = e.produced * count
  local value = e.value * count
  local profit = value - total
  local summary = {
    { string.format("%d× herstellen", count), string.format("ergibt %g Stück", produced) },
    { "Material gesamt", money(total) },
    { "davon noch kaufen", "|cffffb547" .. money(buyTotal) .. "|r" },
    { "Einkauf pro Stück", money(produced > 0 and total / produced or nil) },
    { "Preis jetzt", e.nowPrice and (e.unsure and ("|cffffb547" .. money(e.nowPrice) .. " (unsicher)|r")
      or money(e.nowPrice)) or "nicht im Angebot" },
    { "Verkauf netto", money(value) },
    { "Gewinn", (profit >= 0 and "|cff5fd38d" or "|cffff6b6b-") .. money(math.abs(profit)) .. "|r" },
    { "dein Gold", money(GetMoney()) },
  }
  return {
    title = e.name,
    subtitle = e.profession .. " · " .. (e.learned and "gelernt" or ("nicht gelernt: " .. (e.learn or "?"))),
    columns = { { "Braucht", 56 }, { "Habe", 46 }, { "Kaufen", 54 }, { "Preis", 84 }, { "Kosten", 90 } },
    rows = rows,
    summary = summary,
    hint = "Klick auf Material: im AH suchen  ·  Shift +/−: 10er-Schritte  ·  H = Händler",
  }
end

ns.AHTable.Add({
  ahTab = false, -- only in the main window (the AH tabs are retired, 20 Nov 2026)
  id = "Crafting", label = "Crafting", title = "Crafting",
  chooser = professions,
  sort = "score",          -- learned first, then learnable now, then later; each by profit
  views = { { "profit", "Mit Gewinn" }, { "learned", "Nur gelernte" }, { "all", "Alle Rezepte" } },
  defaultFilters = { demand = "1" },
  rowColor = function(e) return not e.learned and { 0.85, 0.25, 0.25 } or nil end,
  subtitle = function(e)
    if e.learned then return "gelernt" end
    return (e.tooHigh and "|cffff6b6b" or "|cffffb547") .. "nicht gelernt: " .. (e.learn or "?") .. "|r"
  end,
  detail = detail,
  detailCount = true,
  onOpen = function() if ns.AuctionScan then ns.AuctionScan.EnsureFresh() end end,
  info = function() return ns.AuctionScan and ns.AuctionScan.LiveInfo() or nil end,
  columns = {
    { key = "name", title = "Ergebnis", width = 0, align = "LEFT", fmt = function(e)
      return e.name .. (e.produced > 1 and string.format(" |cff99999ex%g|r", e.produced) or "")
    end },
    { key = "cost", title = "Material", width = 90, muted = true, filter = "money",
      fmt = function(e) return money(e.cost) end },
    -- Per unit, next to each other: what one costs to make and what it is offered at.
    { key = "unitCost", title = "Einkauf", width = 85, muted = true, filter = "money", optional = true,
      fmt = function(e) return money(e.unitCost) end },
    { key = "nowPrice", title = "Preis jetzt", width = 90, filter = "money", optional = true,
      fmt = function(e)
        return e.unsure and ("|cffffb547" .. money(e.nowPrice) .. "|r") or money(e.nowPrice)
      end },
    { key = "value", title = "Verkauf", width = 90, filter = "money",
      fmt = function(e)
        local text = (e.onAH and "" or "|cff99999eH |r") .. money(e.value)
        return e.unsure and ("|cffffb547" .. text .. " ?|r") or text
      end },
    { key = "profit", title = "Gewinn", width = 90, filter = "money", fmt = function(e)
      return (e.profit >= 0 and "|cff5fd38d" or "|cffff6b6b") .. (e.profit < 0 and "-" or "")
        .. money(math.abs(e.profit)) .. "|r"
    end },
    { key = "demand", title = "Nachfrage", width = 75, muted = true, filter = "num",
      fmt = function(e) return ns.Item.DemandText(e) or "–" end },
  },
  rows = rows,
})

-- New live prices: recompute the list and the detail panel (AuctionScan loads later).
ns.OnReady(function()
  if ns.AuctionScan and ns.AuctionScan.OnDone then
    ns.AuctionScan.OnDone(function() ns.AHTable.Rebuild() end)
  end
end)

-- Blizzard's profession window (minimal additions, nothing of Blizzard's changed) ------------
-- Recipe list: gold coins left of each recipe name that pays (making it and selling the
-- product via the auction house brings more than the material costs): 1 to 3 by the profit
-- (ns.CoinCount). Selected recipe:
-- the price next to each reagent and a three line summary under the reagents. Figures from the
-- own profession scan (ns.db.recipes) and ns.Item (BuyCost, SellNet) - no own price logic.

local RIGHT_EDGE = 24 -- prices and summary values end this far from the form's right edge

-- Economics of one recipe (spell id) of the character's scans; nil without a product or price.
function ns.RecipeEconomics(recipeID)
  local prefix = ns.CharKey() .. ":"
  local r
  for key, scan in pairs(ns.db and ns.db.recipes or {}) do
    if key:sub(1, #prefix) == prefix and scan.recipes and scan.recipes[recipeID] then r = scan.recipes[recipeID] end
  end
  if not (r and r.out) then return nil end
  local cost, reagents = 0, {}
  for _, g in ipairs(r.r or {}) do
    if g.i then
      local unit, vendor = ns.Item.BuyCost(ns.Item(g.i))
      reagents[g.i] = { unit = unit, vendor = vendor, n = g.n or 1 }
      if not unit then return { reagents = reagents, out = r.out } end
      cost = cost + unit * (g.n or 1)
    end
  end
  local qty = ((r.qmin or 1) + (r.qmax or r.qmin or 1)) / 2
  local unitValue, onAH = ns.Item.SellNet(ns.Item(r.out))
  local value = unitValue * qty
  return { cost = cost, value = value, profit = value - cost, onAH = onAH, reagents = reagents, out = r.out }
end

-- "Attraktiv": the cloud's rule for a recipe that brings gold sustainably (collector,
-- ahprofessions.py): at least 5 silver profit per craft via the auction house and demand of at
-- least "mittel"; ranked by profit x demand (capped at 20) - a ranking aid, not gold per day.
local MIN_PROFIT, MIN_DEMAND, DEMAND_CAP = 500, 1, 20

-- Gold coins of a recipe that pays (profession window and "Alle Produkte"): one below 2 gold
-- profit per craft, two up to 10 gold, three above; none without profit.
function ns.CoinCount(profit)
  if not profit or profit <= 0 then return 0 end
  if profit < 20000 then return 1 end
  if profit < 100000 then return 2 end
  return 3
end
function ns.CraftAttractive(e)
  if not e.onAH then return false, "verkauft sich nur an Händler" end
  if (e.profit or 0) < MIN_PROFIT then
    return false, (e.profit or 0) > 0 and "Gewinn unter 5 Silber" or "kein Gewinn"
  end
  if (e.demand or 0) < MIN_DEMAND then return false, "Nachfrage zu gering" end
  return true, nil, e.profit * math.min(e.demand, DEMAND_CAP)
end

-- "Alle Produkte": every recipe of the open profession (Data_Recipes.lua: all recipes the game
-- knows, drops and rare ones included), in the profession window's look. Left the recipes
-- (filter: attractive / with profit / learned / all), right the card with reagents and figures.
-- Same figures as the coin in the profession window and the old professions page (rows()).
local Products = {}
ns.Products = Products
local FILTERS = {
  { key = "attractive", label = "Attraktiv (Gewinn + Nachfrage)" },
  { key = "profit", label = "Mit Gewinn" },
  { key = "learned", label = "Nur gelernte" },
  { key = "all", label = "Alle Rezepte" },
}
-- Level of the product (the level needed to use it): everything, "for me" (the character's level
-- and the 9 below), or a range. Unknown levels (item not loaded yet) count once they arrive.
local LEVELS = {
  { key = "all", label = "Alle Stufen" },
  { key = "me", label = "Für mich" },
  { key = "1-19", label = "Stufe 1–19" },
  { key = "20-29", label = "Stufe 20–29" },
  { key = "30-39", label = "Stufe 30–39" },
  { key = "40-49", label = "Stufe 40–49" },
  { key = "50-60", label = "Stufe 50–60" },
}
local MAX_REAGENTS = 8
local productsWindow, productsSplit, productsPID

local function signedMoney(c)
  c = math.floor((c or 0) + 0.5)
  return c >= 0 and ("|cff5fd38d+" .. money(c) .. "|r") or ("|cffff6b6b-" .. money(-c) .. "|r")
end

local function itemIcon(id)
  local get = (C_Item and C_Item.GetItemIconByID) or GetItemIcon
  return id and get and get(id) or nil
end

local function filterKey()
  local ui = ns.db and ns.db.ui
  return ui and ui.productsFilter or "attractive"
end

local function levelKey()
  local ui = ns.db and ns.db.ui
  return ui and ui.productsLevel or "all"
end

-- The level needed to use an item (0 = none), nil while the client has not loaded it (asked for).
local pendingLevels = false
local function useLevel(itemID)
  local get = (C_Item and C_Item.GetItemInfo) or GetItemInfo
  if not get then return 0 end
  local name, _, _, _, minLevel = get(itemID) -- not "get and get(…)": that keeps only the name
  if name then return minLevel or 0 end
  if C_Item and C_Item.RequestLoadItemDataByID then pcall(C_Item.RequestLoadItemDataByID, itemID) end
  pendingLevels = true
  return nil
end

local function levelRange(key)
  if key == "me" then
    local lv = UnitLevel and UnitLevel("player") or 60
    return math.max(1, lv - 9), lv
  end
  local lo, hi = tostring(key):match("^(%d+)%-(%d+)$")
  return tonumber(lo), tonumber(hi)
end

local function levelOK(e, lo, hi)
  if not lo then return true end
  local lv = useLevel(e.itemID)
  return lv ~= nil and lv > 0 and lv >= lo and lv <= hi
end

-- Category name and order of the game (asked while the profession is open, kept for later).
local function category(cat)
  if not cat then return nil end
  ns.db.recipeCats = ns.db.recipeCats or {}
  local known = ns.db.recipeCats[cat]
  local api = C_TradeSkillUI and C_TradeSkillUI.GetCategoryInfo
  if api then
    local ok, info = pcall(api, cat)
    if ok and type(info) == "table" and info.name then
      known = { n = info.name, o = info.uiOrder or 0 }
      ns.db.recipeCats[cat] = known
    end
  end
  return known
end

local function productEntries(pid)
  local key = filterKey()
  local list = rows(key == "learned" and "learned" or "all", pid)
  local out = {}
  local function entry(e)
    return { key = tostring(e.spell or e.itemID), name = e.recipe, icon = itemIcon(e.itemID), itemID = e.itemID,
      coins = e.onAH and ns.CoinCount(e.profit) or 0, locked = not e.learned, e = e }
  end
  -- the filter only leaves recipes out; the game's categories stay as in "Alle Rezepte"
  local kept = {}
  local lo, hi = levelRange(levelKey())
  for _, e in ipairs(list) do
    e.attractive, e.why, e.rank = ns.CraftAttractive(e)
    if (key ~= "attractive" or e.attractive) and (key ~= "profit" or (e.profit > 0 and e.onAH))
      and levelOK(e, lo, hi) then
      kept[#kept + 1] = e
    end
  end
  list = kept
  local groups, order = {}, {}
  for _, e in ipairs(list) do
    local c = category(e.cat)
    local name = c and c.n or "Weitere"
    local g = groups[name]
    if not g then
      g = { name = name, o = c and c.o or 1e9, items = {} }
      groups[name] = g
      order[#order + 1] = g
    end
    g.items[#g.items + 1] = e
  end
  table.sort(order, function(a, b)
    if a.o ~= b.o then return a.o < b.o end
    return a.name < b.name
  end)
  for _, g in ipairs(order) do
    out[#out + 1] = { key = "h:" .. g.name, header = g.name }
    table.sort(g.items, function(a, b)
      if a.learned ~= b.learned then return a.learned end
      return (a.recipe or "") < (b.recipe or "")
    end)
    for _, e in ipairs(g.items) do out[#out + 1] = entry(e) end
  end
  return out
end

-- How a recipe is learned, from the Forever recipe sources (Data_RecipeSources.lua): one line
-- per way - trainer, vendors of the own faction (NPC, zone), reputation, Merchant's Favor, drop
-- (who drops it, else a random world drop), quest - and a tradeable recipe item with its price
-- at the auction house right now. nil when the sources do not know the recipe.
local KIND = { vendor = "Händler", limited = "Händler (begrenzter Vorrat)", rep = "Ruf-Händler", favor = "Händlergunst",
  cond = "Händler (mit Bedingung)", unknown = "Händler (NPC unbekannt)" }
local function sourceLines(pid, spell)
  local srcs = ns.RecipeSources and ns.RecipeSources[pid]
  local entry = srcs and srcs.recipes and srcs.recipes[spell]
  if not entry then return nil end
  local mine = (UnitFactionGroup and UnitFactionGroup("player")) == "Alliance" and "A" or "H"
  local lines = {}
  if entry.auto then lines[#lines + 1] = "Beim Erlernen des Berufs" end
  if entry.t then lines[#lines + 1] = "Lehrer" .. (entry.rank and (" (" .. entry.rank .. ")") or "") end
  for _, s in ipairs(entry) do
    local npc = s[2] and s[2] > 0 and srcs.npcs and srcs.npcs[s[2]] or nil
    if not npc or npc[5] == "B" or npc[5] == mine or npc[5] == nil then
      local text = KIND[s[1]] or s[1]
      if npc then text = text .. ": " .. npc[1] .. " (" .. (npc[2] or "?") .. ")" end
      if s.rf then text = text .. ", Ruf " .. s.rf .. " " .. (s.rs or "") end
      if s.favor then text = text .. ", " .. s.favor .. " Gunst" end
      if (s[3] or 0) > 0 then text = text .. ", " .. money(s[3]) end
      if s.c == 1 then text = text .. " |cff999999(Classic-Daten)|r" end
      lines[#lines + 1] = text
    end
  end
  if entry.d then
    if entry.dr then
      lines[#lines + 1] = "Drop: " .. table.concat(entry.dr, ", ")
        .. (entry.drMore and string.format(" |cff999999und %d weitere|r", entry.drMore) or "")
    else
      lines[#lines + 1] = "Drop: zufällig (Weltdrop)"
    end
  end
  if entry.q then lines[#lines + 1] = "Quest: " .. entry.q end
  if entry.item then
    local p = ns.Item(entry.item).now
    lines[#lines + 1] = p and ("Rezept im AH: " .. money(p)) or "|cff999999Rezept handelbar, gerade nicht im AH|r"
  elseif entry.bop then
    lines[#lines + 1] = "|cff999999Rezept nicht handelbar (seelengebunden)|r"
  end
  return #lines > 0 and lines or nil
end

-- A reagent slot like the profession window's: Blizzard's slot template if the client has it,
-- else an item button (icon in the slot frame); "0/20 Name" right of it, the price at the edge.
local function reagentSlot(c)
  local r = {}
  local ok, slot = pcall(CreateFrame, "Button", nil, c, "ItemButtonTemplate")
  if not ok or not slot then slot = CreateFrame("Button", nil, c) end
  slot:SetSize(37, 37)
  r.Slot = slot
  r.Icon = rawget(slot, "icon") or rawget(slot, "Icon")
  if type(r.Icon) ~= "table" then
    r.Icon = slot:CreateTexture(nil, "ARTWORK")
    r.Icon:SetAllPoints()
  end
  local count = rawget(slot, "Count")
  if type(count) == "table" and count.Hide then count:Hide() end
  r.Name = c:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
  r.Name:SetPoint("LEFT", slot, "RIGHT", 8, 0)
  r.Name:SetWidth(150)
  r.Name:SetJustifyH("LEFT")
  r.Name:SetMaxLines(2)
  r.Price = c:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
  r.Price:SetPoint("RIGHT", c, "RIGHT", -RIGHT_EDGE, 0)
  r.Price:SetPoint("TOP", slot, "TOP", 0, -12)
  r.Price:SetJustifyH("RIGHT")
  slot:SetScript("OnEnter", function(self)
    if not r.itemID then return end
    GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
    GameTooltip:SetItemByID(r.itemID)
    GameTooltip:Show()
  end)
  slot:SetScript("OnLeave", function() GameTooltip:Hide() end)
  slot:SetScript("OnClick", function(self) if r.itemID then ns.NativeWindow.AltClick(r.itemID, self) end end)
  return r
end

-- The card in the profession window's look: icon and name, how it is learned where Blizzard
-- shows the description, "Reagenzien:" with slots and prices, then the summary rows the
-- profession window gets from this addon (Herstellkosten, Erlös, Nachfrage, line, Gewinn).
local SUMMARY = { "Herstellkosten", "Erlös", "Nachfrage", "Gewinn" }
local function productCard(c)
  local v = ns.NativeWindow.CardHead(c)
  -- "Erlernen:" with one line per way to learn it (unlearned recipes), where Blizzard shows the
  -- description
  v.LearnHead = c:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
  v.LearnHead:SetPoint("TOPLEFT", v.Icon, "BOTTOMLEFT", 0, -16)
  v.LearnHead:SetText("Erlernen:")
  v.Source = c:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
  v.Source:SetPoint("TOPLEFT", v.LearnHead, "BOTTOMLEFT", 0, -5)
  v.Source:SetPoint("RIGHT", c, "RIGHT", -RIGHT_EDGE, 0)
  v.Source:SetJustifyH("LEFT")
  v.Source:SetSpacing(3)
  v.Source:SetMaxLines(8)
  v.Head:SetText("Reagenzien:")
  v.reagents = {}
  for i = 1, MAX_REAGENTS do v.reagents[i] = reagentSlot(c) end
  v.rows = {}
  for i, text in ipairs(SUMMARY) do
    local l = c:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    l:SetText(text)
    local val = c:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    val:SetJustifyH("RIGHT")
    val:SetPoint("RIGHT", c, "RIGHT", -RIGHT_EDGE, 0)
    val:SetPoint("TOP", l, "TOP", 0, 0)
    v.rows[i] = { label = l, value = val }
  end
  v.Line = c:CreateTexture(nil, "ARTWORK")
  v.Line:SetColorTexture(1, 0.82, 0, 0.25)
  v.Line:SetHeight(1)
  return v
end

local function showProduct(entry, c)
  if not rawget(c, "m4Product") then c.m4Product = productCard(c) end
  local v = c.m4Product
  local e = entry and entry.e
  local shown = e ~= nil
  for _, part in ipairs({ v.Icon, v.Ring, v.Name, v.Sub, v.Head, v.LearnHead, v.Source, v.Line }) do part:SetShown(shown) end
  for _, row in ipairs(v.rows) do row.label:SetShown(shown); row.value:SetShown(shown) end
  for _, r in ipairs(v.reagents) do r.Slot:Hide(); r.Name:Hide(); r.Price:Hide(); r.itemID = nil end
  if productsSplit and productsSplit.empty then
    productsSplit.empty:SetText(shown and "" or "Keine Rezepte für diesen Filter.")
  end
  if not shown then return end
  v.Icon:SetTexture(itemIcon(e.itemID))
  v.itemID = e.itemID
  v.Name:SetText(e.recipe .. (e.produced > 1 and string.format("  |cff999999x%g|r", e.produced) or ""))
  v.Sub:SetText(e.learned and "gelernt"
    or ((e.tooHigh and "|cffff6b6b" or "|cffffb547") .. "nicht gelernt" .. (e.learn and (": " .. e.learn:gsub("^Quelle %? ", "")) or "") .. "|r"))
  local src = not e.learned and sourceLines(e.pid, e.spell) or nil
  v.Source:SetText(src and table.concat(src, "\n") or "")
  v.Source:SetShown(src ~= nil)
  v.LearnHead:SetShown(src ~= nil)
  v.Head:ClearAllPoints()
  v.Head:SetPoint("TOPLEFT", src and v.Source or v.Icon, "BOTTOMLEFT", 0, src and -16 or -20)
  local last = v.Head
  for i, g in ipairs(e.reagents or {}) do
    local r = v.reagents[i]
    if not r then break end
    local unit, vendor = buy(g.i)
    local have = ns.Costs and ns.Costs.Owned and ns.Costs.Owned(g.i) or 0
    r.itemID = g.i
    r.Icon:SetTexture(itemIcon(g.i))
    r.Slot:ClearAllPoints()
    r.Slot:SetPoint("TOPLEFT", last, "BOTTOMLEFT", 0, i == 1 and -8 or -6)
    r.Name:SetText(string.format("%s%d/%d|r %s", have >= g.n and "|cffffffff" or "|cff999999", have, g.n,
      ns.ItemName(g.i) or ("#" .. g.i)))
    r.Price:SetText(unit and (money(unit * g.n) .. "|cff999999  " .. (vendor and "H" or "AH") .. "|r") or "|cffff6b6bkein Preis|r")
    r.Slot:Show(); r.Name:Show(); r.Price:Show()
    last = r.Slot
  end
  local values = {
    money(e.cost),
    money(e.value) .. (e.onAH and "" or "|cff999999  H|r"),
    ns.Item.DemandText(e) or "–",
    signedMoney(e.profit),
  }
  for i, row in ipairs(v.rows) do
    row.label:ClearAllPoints()
    local gap = i == #v.rows and 7 or 0 -- room for the line before "Gewinn"
    row.label:SetPoint("TOPLEFT", last, "BOTTOMLEFT", 0, -14 - (i - 1) * 14 - gap)
    row.value:SetText(values[i])
  end
  local gewinn = v.rows[#v.rows].label
  v.Line:ClearAllPoints()
  v.Line:SetPoint("BOTTOMLEFT", gewinn, "TOPLEFT", 0, 3)
  v.Line:SetPoint("RIGHT", c, "RIGHT", -RIGHT_EDGE + 2, 0)
end

local function refreshProducts()
  if not (productsWindow and productsSplit and productsPID) then return end
  local data = ns.RecipeData and ns.RecipeData[productsPID]
  local title = "Alle Produkte" .. (data and (" – " .. data.name) or "")
  local f = productsWindow.frame
  if f.SetTitle then pcall(f.SetTitle, f, title) end
  if data and data.icon and f.SetPortraitToAsset then pcall(f.SetPortraitToAsset, f, data.icon) end
  LEVELS[2].label = string.format("Für mich (Stufe %d–%d)", levelRange("me"))
  pendingLevels = false
  productsSplit.SetEntries(data and productEntries(productsPID) or {})
  if not data and productsSplit.empty then productsSplit.empty:SetText("Dieser Beruf stellt keine Produkte her.") end
end

local function createProducts()
  local NW = ns.NativeWindow
  productsWindow = NW.New({ name = "M4CompanionProducts", title = "Alle Produkte", icon = "Interface\\Icons\\INV_Misc_Coin_02" })
  productsWindow.frame:HookScript("OnShow", function() Products.SyncTab() end)
  productsWindow.frame:HookScript("OnHide", function() Products.SyncTab() end)
  productsWindow:AddTab({ key = "products", title = "Alle Produkte", hidden = true, build = function(page)
    productsSplit = NW.Split(page, {
      onSelect = showProduct,
      filter = { groups = {
        { title = "Rezepte", options = FILTERS, get = filterKey, set = function(key)
          ns.db.ui = ns.db.ui or {}
          ns.db.ui.productsFilter = key
          refreshProducts()
        end },
        { title = "Stufe", options = LEVELS, get = levelKey, set = function(key)
          ns.db.ui = ns.db.ui or {}
          ns.db.ui.productsLevel = key
          refreshProducts()
        end },
      } },
    })
  end, onShow = function() refreshProducts() end })
end

-- The open profession's id (Data_Recipes keys: the skill line, e.g. 165 Lederverarbeitung).
local function openProfessionID()
  local api = C_TradeSkillUI
  if api and api.GetBaseProfessionInfo then
    local ok, info = pcall(api.GetBaseProfessionInfo)
    if ok and type(info) == "table" and info.professionID then return info.professionID end
  end
  if api and api.GetTradeSkillLine then
    local ok, id = pcall(api.GetTradeSkillLine)
    if ok then return id end
  end
  return nil
end

Products.Entries = productEntries -- for tests
Products.SourceLines = sourceLines

function Products.Show(pid)
  if not productsWindow then createProducts() end
  productsPID = pid or openProfessionID() or productsPID
  productsWindow:Show()
  productsWindow:SelectTab("products")
end

-- The tab under the profession window looks selected while the window is open.
function Products.SyncTab()
  local tab = Products.tab
  if not tab then return end
  local open = productsWindow and productsWindow.frame:IsShown()
  local fn = open and PanelTemplates_SelectTab or PanelTemplates_DeselectTab
  if fn then pcall(fn, tab) end
end

-- The tab: closes the window, unless it shows another profession (then it switches).
function Products.Toggle(pid)
  pid = pid or openProfessionID()
  if productsWindow and productsWindow.frame:IsShown() and (not pid or pid == productsPID) then
    productsWindow.frame:Hide()
  else
    Products.Show(pid)
  end
end

-- Item data arrives (the levels asked for by the level filter): the open list follows, once
-- per burst.
local levelRefresh = false
ns.On("GET_ITEM_INFO_RECEIVED", function()
  if not (pendingLevels and productsWindow and productsWindow.frame:IsShown()) or levelRefresh then return end
  levelRefresh = true
  C_Timer.After(0.5, function()
    levelRefresh = false
    ns.Safe(refreshProducts)
  end)
end)

-- New live prices: the open list follows.
ns.OnReady(function()
  if ns.AuctionScan and ns.AuctionScan.OnDone then
    ns.AuctionScan.OnDone(function()
      if productsWindow and productsWindow.frame:IsShown() then ns.Safe(refreshProducts) end
    end)
  end
end)

local function profTrace(key, value)
  if ns.db then ns.db.professionsTrace = ns.db.professionsTrace or {}; ns.db.professionsTrace[key] = value end
end

local function recipeIDOf(row)
  local ok, node = pcall(function() return row:GetElementData() end)
  if not ok or type(node) ~= "table" then return nil end
  local data = node.GetData and node:GetData() or node
  local info = type(data) == "table" and data.recipeInfo
  return type(info) == "table" and info.recipeID or nil
end

local function updateList(list)
  local box = rawget(list, "ScrollBox")
  if type(box) ~= "table" or not box.ForEachFrame then return end
  local n = 0
  box:ForEachFrame(function(row)
    local id = recipeIDOf(row)
    local label = rawget(row, "Label")
    if not (id and type(label) == "table") then
      if row.m4Coins then row.m4Coins.Set(0) end -- a category row: no coins, name in place
      return
    end
    n = n + 1
    local e = ns.RecipeEconomics(id)
    if not row.m4Coins then row.m4Coins = ns.NativeWindow.Coins(row, label) end
    local coins = e and e.profit and e.onAH and ns.CoinCount(e.profit) or 0 -- only where it pays
    -- left of the skill-up arrow when it shows, else where it sits
    local ups = rawget(row, "SkillUps")
    row.m4Coins.Set(coins, type(ups) == "table" and ups.IsShown and ups:IsShown() and ups or nil)
  end)
  profTrace("listRows", n)
end

-- The reagent slots of the schematic form (frames that carry a reagent schematic).
local function reagentSlots(form)
  local out = {}
  local slots = rawget(form, "reagentSlots")
  if type(slots) == "table" then
    for _, list in pairs(slots) do
      if type(list) == "table" then
        for _, slot in ipairs(list) do out[#out + 1] = slot end
      end
    end
  end
  return out
end

local function slotItem(slot)
  local s = rawget(slot, "reagentSlotSchematic")
  local reagent = type(s) == "table" and s.reagents and s.reagents[1]
  return reagent and reagent.itemID, s and s.quantityRequired
end

local function updateForm(form)
  local info = rawget(form, "currentRecipeInfo")
  if (type(info) ~= "table") and form.GetRecipeInfo then
    local ok, v = pcall(form.GetRecipeInfo, form)
    info = ok and v or nil
  end
  local id = type(info) == "table" and info.recipeID or nil
  local e = id and ns.RecipeEconomics(id)
  local fmt = function(c) return ns.FormatMoney(c, true) end
  local slots = reagentSlots(form)
  profTrace("slots", #slots)
  local lowest
  for _, slot in ipairs(slots) do
    local itemID, need = slotItem(slot)
    if not slot.m4Price then
      -- on the slot (hides with it when Blizzard puts the slot back in its pool), placed by
      -- the form's right edge
      slot.m4Price = slot:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
      slot.m4Price:SetJustifyH("RIGHT")
      local nameFS = rawget(slot, "Name") or (type(rawget(slot, "Button")) == "table" and rawget(slot.Button, "Name"))
      if type(nameFS) == "table" and nameFS.GetFontObject and nameFS:GetFontObject() then
        slot.m4Price:SetFontObject(nameFS:GetFontObject())
      end
    end
    -- right column of the form, on the height of the slot
    do
      local _, fy = form:GetCenter()
      local _, sy = slot:GetCenter()
      slot.m4Price:ClearAllPoints()
      if fy and sy then slot.m4Price:SetPoint("RIGHT", form, "RIGHT", -RIGHT_EDGE, sy - fy) end
    end
    local r = e and e.reagents and itemID and e.reagents[itemID]
    if itemID and r and r.unit then
      slot.m4Price:SetText(fmt(r.unit * (need or r.n)) .. "|cff999999  " .. (r.vendor and "H" or "AH") .. "|r")
    elseif itemID then
      slot.m4Price:SetText("|cffff6b6bkein Preis|r")
    else
      slot.m4Price:SetText("")
    end
    if slot:IsShown() then
      local b = slot:GetBottom()
      if b and (not lowest or b < lowest:GetBottom()) then lowest = slot end
    end
  end
  -- Summary: three rows like Blizzard's (gold label left, value right in the price column).
  if not form.m4Rows then
    form.m4Rows = {}
    for i, text in ipairs({ "Herstellkosten", "Erlös", "Gewinn" }) do
      local l = form:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
      l:SetText(text)
      local v = form:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
      v:SetJustifyH("RIGHT")
      form.m4Rows[i] = { label = l, value = v }
    end
  end
  local values
  if e and e.cost and e.value then
    local p = e.profit
    values = { fmt(e.cost), fmt(e.value) .. (e.onAH and "" or "|cff999999  H|r"),
      p >= 0 and ("|cff5fd38d+" .. fmt(p) .. "|r") or ("|cffff6b6b-" .. fmt(-p) .. "|r") }
  end
  -- a thin line between revenue and profit
  if not form.m4Line then
    form.m4Line = form:CreateTexture(nil, "ARTWORK")
    form.m4Line:SetColorTexture(1, 0.82, 0, 0.25)
    form.m4Line:SetHeight(1)
  end
  for i, row in ipairs(form.m4Rows) do
    row.label:ClearAllPoints()
    row.value:ClearAllPoints()
    local gap = i >= 3 and 7 or 0 -- room for the line before "Gewinn"
    if lowest then
      row.label:SetPoint("TOPLEFT", lowest, "BOTTOMLEFT", 0, -12 - (i - 1) * 14 - gap)
    else
      row.label:SetPoint("BOTTOMLEFT", form, "BOTTOMLEFT", 20, 60 - (i - 1) * 14 - gap)
    end
    if i == 3 then
      form.m4Line:ClearAllPoints()
      form.m4Line:SetPoint("BOTTOMLEFT", row.label, "TOPLEFT", 0, 3)
      local lx, fr = row.label:GetLeft(), form:GetRight()
      form.m4Line:SetWidth(lx and fr and math.max(1, fr - RIGHT_EDGE - lx) or 200)
      form.m4Line:SetShown(values ~= nil)
    end
    local _, fy = form:GetCenter()
    local _, ly = row.label:GetCenter()
    if fy and ly then row.value:SetPoint("RIGHT", form, "RIGHT", -RIGHT_EDGE, ly - fy) end
    row.label:SetShown(values ~= nil)
    row.value:SetText(values and values[i] or "")
  end
end

local function attachProfessions()
  local pf = rawget(_G, "ProfessionsFrame")
  local page = type(pf) == "table" and rawget(pf, "CraftingPage")
  if type(page) ~= "table" or page.m4Info then
    profTrace("frame", type(pf) == "table" and (type(page) == "table" and "page" or "no page") or "no ProfessionsFrame")
    return
  end
  local list, form = rawget(page, "RecipeList"), rawget(page, "SchematicForm")
  profTrace("frame", "list=" .. type(list) .. " form=" .. type(form))
  local layer = CreateFrame("Frame", nil, page)
  page.m4Info = layer
  -- "Alle Produkte": a tab under the profession window (Blizzard's tab template), like the
  -- trade book's tab under the auction house was; shown selected while the window is open
  local okT, tab = pcall(CreateFrame, "Button", "M4CompanionProductsTab", pf, "PanelTabButtonTemplate")
  if okT and tab then
    tab:SetText("Alle Produkte")
    if PanelTemplates_TabResize then pcall(PanelTemplates_TabResize, tab, 0) end
    tab:SetPoint("TOPLEFT", pf, "BOTTOMLEFT", 12, 2)
    Products.tab = tab
    Products.SyncTab()
    tab:SetScript("OnClick", function() ns.Safe(Products.Toggle) end)
  end
  local elapsed = 0
  layer:SetScript("OnUpdate", function(_, dt)
    elapsed = elapsed + (dt or 0)
    if elapsed < 0.4 then return end
    elapsed = 0
    if type(list) == "table" then ns.Safe(updateList, list) end
    if type(form) == "table" and form:IsShown() then ns.Safe(updateForm, form) end
  end)
end

if ns.On then
  ns.On("TRADE_SKILL_SHOW", function()
    ns.Safe(attachProfessions)
    if C_Timer then C_Timer.After(0.3, function() ns.Safe(attachProfessions) end) end
  end)
end
