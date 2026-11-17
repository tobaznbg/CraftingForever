-- Crafting: auction house tab "Herstellen" - which learned recipes of the character's
-- professions make a profit when every reagent is bought (merchant if it sells it,
-- else the auction house) and the product is sold on the auction house.
--   prices     ns.Item (Item.lua): buy = merchant, else cheapest offer now;
--              sell = cheapest offer now - 1 copper - 5 % cut, or a merchant if higher.
--              Opening the tab starts a live scan (every 15 min at most).
-- Only professions whose window was opened once are known (Recipes.Scan); the scan
-- also holds the recipes not learned yet. Those are shown with a red background and
-- how to learn them (planner data: trainer, merchant, drop, quest; the pattern price
-- is not part of the profit).
local ADDON, ns = ...

local function money(c) return c and ns.FormatMoney(c, true) or "–" end

-- Copper per unit to buy a reagent (merchant, else cheapest offer, else the average
-- when it is not on offer right now), and whether it comes from a merchant.
local function buy(itemID)
  local e = ns.Item(itemID)
  local unit, vendor = ns.Item.BuyCost(e)
  return unit or e.avg, vendor
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

local function rows(filter)
  local list = {}
  local prefix = ns.CharKey() .. ":"
  for key, scan in pairs(ns.db.recipes or {}) do
    if key:sub(1, #prefix) == prefix then
      for recipeID, r in pairs(scan.recipes or {}) do
        if r.out and (r.learned or filter ~= "learned") then
          local cost, missing = 0, false
          for _, reagent in ipairs(r.r or {}) do
            local unit = reagent.i and buy(reagent.i)
            if not unit then missing = true break end
            cost = cost + unit * (reagent.n or 1)
          end
          if not missing then
            local produced = ((r.qmin or 1) + (r.qmax or r.qmin or 1)) / 2
            local unitValue, onAH = sell(r.out)
            local value = unitValue * produced
            local profit = value - cost
            local item = ns.Item(r.out)
            if filter ~= "profit" or (profit > 0 and onAH) then
              local learn, need = nil, nil
              if not r.learned then learn, need = learnInfo(scan.professionID, recipeID) end
              -- 0 learned, 1 learnable now, 2 later: what can be made now comes first.
              local group = r.learned and 0 or ((need and need > (scan.rank or 0)) and 2 or 1)
              local fpd = item.perDay or 0
              table.insert(list, { itemID = r.out, recipe = r.name, profession = scan.profession,
                score = (2 - group) * 1e12 + profit,
                learned = r.learned and true or false, learn = learn, tooHigh = need and need > (scan.rank or 0),
                cost = cost, value = value, profit = profit, onAH = onAH,
                fpd = fpd,
                produced = produced, reagents = r.r })
            end
          end
        end
      end
    end
  end
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
  local footer = string.format(
    "%d× herstellen  ·  ergibt %g Stück\n"
    .. "Material gesamt %s  ·  davon noch kaufen |cffffb547%s|r\n"
    .. "Verkauf netto %s  ·  Gewinn %s%s|r  ·  dein Gold %s\n"
    .. "|cff99999eKlick auf ein Material: im AH suchen  ·  Shift +/−: in 10er-Schritten  ·  H = Händler|r",
    count, produced, money(total), money(buyTotal), money(value),
    (value - total) >= 0 and "|cff5fd38d" or "|cffff6b6b", money(value - total), money(GetMoney()))
  return {
    title = e.name,
    subtitle = e.learned and (e.profession .. " · gelernt") or ("nicht gelernt: " .. (e.learn or "?")),
    columns = { { "Braucht", 52 }, { "Habe", 44 }, { "Kaufen", 50 }, { "Preis", 66 }, { "Kosten", 70 } },
    rows = rows,
    footer = footer,
  }
end

ns.AHTable.Add({
  id = "Crafting", label = "Herstellen", title = "Herstellen – was sich mit gekauften Materialien lohnt",
  sort = "score",          -- learned first, then learnable now, then later; each by profit
  views = { { "profit", "Mit Gewinn" }, { "learned", "Nur gelernte" }, { "all", "Alle Rezepte" } },
  defaultFilters = { fpd = "1" },
  rowColor = function(e) return not e.learned and { 0.85, 0.25, 0.25 } or nil end,
  subtitle = function(e)
    if e.learned then return e.profession .. "  ·  gelernt" end
    return (e.tooHigh and "|cffff6b6b" or "|cffffb547") .. "nicht gelernt: " .. e.learn .. "|r"
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
      fmt = function(e) return (e.onAH and "" or "|cff99999eH |r") .. money(e.value) end },
    { key = "profit", title = "Gewinn", width = 95, filter = "money", fmt = function(e)
      return (e.profit >= 0 and "|cff5fd38d" or "|cffff6b6b") .. (e.profit < 0 and "-" or "")
        .. money(math.abs(e.profit)) .. "|r"
    end },
    { key = "fpd", title = "Verk./Tag", width = 75, muted = true, filter = "num",
      fmt = function(e) return string.format("%.0f", e.fpd) end },
  },
  rows = rows,
})

-- New live prices: recompute the list and the detail panel (AuctionScan loads later).
ns.OnReady(function()
  if ns.AuctionScan and ns.AuctionScan.OnDone then
    ns.AuctionScan.OnDone(function() ns.AHTable.Rebuild() end)
  end
end)
