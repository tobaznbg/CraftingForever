-- Crafting: auction house tab. First a choice of all crafting professions (with icon),
-- then every recipe of that profession that makes an item (Data_Recipes.lua, Blizzard
-- API), priced via ns.Item: buy = merchant, else cheapest offer; sell = cheapest offer
-- - 1 copper - 5 % cut, or a merchant if higher. Learned state and skill come from the
-- character's own profession scan (open the profession window once); unlearned recipes
-- get a red marker and, where the planner data knows it, how to learn them.
-- Opening the tab starts a live scan (every 15 min at most).
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
      local reagents, cost, missing = {}, 0, false
      for i = 1, #reagentList, 2 do
        local id, n = reagentList[i], reagentList[i + 1]
        table.insert(reagents, { i = id, n = n })
        local unit = buy(id)
        if not unit then missing = true break end
        cost = cost + unit * n
      end
      if not missing then
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
            cost = cost, value = value, profit = profit, onAH = onAH, demand = ns.Item(out).demand or 0,
            produced = quantity, reagents = reagents })
        end
      end
    end
  end
  return list
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
          local cost, list = 0, rec[4] or {}
          for i = 1, #list, 2 do
            local unit = buy(list[i])
            if not unit then cost = nil break end
            cost = cost + unit * list[i + 1]
          end
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
    { "Verkauf netto", money(value) .. (e.unsure and e.nowPrice
      and ("  |cffffb547(jetzt " .. money(e.nowPrice) .. ", unsicher)|r") or "") },
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
    { key = "cost", title = "Material", width = 95, muted = true, filter = "money",
      fmt = function(e) return money(e.cost) end },
    { key = "value", title = "Verkauf", width = 95, filter = "money",
      fmt = function(e)
        local text = (e.onAH and "" or "|cff99999eH |r") .. money(e.value)
        return e.unsure and ("|cffffb547" .. text .. " ?|r") or text
      end },
    { key = "profit", title = "Gewinn", width = 95, filter = "money", fmt = function(e)
      return (e.profit >= 0 and "|cff5fd38d" or "|cffff6b6b") .. (e.profit < 0 and "-" or "")
        .. money(math.abs(e.profit)) .. "|r"
    end },
    { key = "demand", title = "Nachfrage", width = 80, muted = true, filter = "num",
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
