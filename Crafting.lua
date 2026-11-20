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
  for _, rec in pairs(data.recipes) do
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
