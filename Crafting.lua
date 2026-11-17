-- Crafting: auction house tab "Herstellen" - which learned recipes of the character's
-- professions make a profit when every reagent is bought (merchant if it sells it,
-- else the auction house) and the product is sold on the auction house.
--   reagent    merchant price, else cheapest offer (own scan, else collector data,
--              else TSM region value)
--   product    market value in this house (collector), else own scan, after the
--              5 % cut; a merchant price counts if it is higher
-- Only professions whose window was opened once are known (Recipes.Scan); the scan
-- also holds the recipes not learned yet. Those are shown with a red background and
-- how to learn them (planner data: trainer, merchant, drop, quest; the pattern price
-- is not part of the profit).
local ADDON, ns = ...

local CUT = 0.05

local function money(c) return c and ns.FormatMoney(c, true) or "–" end

local function houseRow(itemID)
  local house = ns.AHData and ns.AHData[113]
  return house and house.items[itemID]
end

-- Copper per unit to buy a reagent, and whether it comes from a merchant.
local function buy(itemID)
  local vendor = ns.db.vendorBuy and ns.db.vendorBuy[itemID]
  if vendor then return vendor, true end
  local own = ns.Prices.Auction(itemID)
  if own then return own end
  local row = houseRow(itemID)
  if row and row[1] then return row[1] end
  local unit, source = ns.Costs.Buy(itemID)
  return unit, source == "Händler"
end

-- Copper per unit the product brings after the cut (or from a merchant).
local function sell(itemID)
  local row = houseRow(itemID)
  local ah = (row and (row[2] or row[1])) or ns.Prices.Auction(itemID)
  local value = ah and math.floor(ah * (1 - CUT)) or 0
  return math.max(value, ns.Prices.Vendor(itemID) or 0), ah ~= nil
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
            local m = ns.Market.Info(r.out)
            if filter ~= "profit" or (profit > 0 and onAH) then
              local learn, need = nil, nil
              if not r.learned then learn, need = learnInfo(scan.professionID, recipeID) end
              table.insert(list, { itemID = r.out, recipe = r.name, profession = scan.profession,
                learned = r.learned and true or false, learn = learn, tooHigh = need and need > (scan.rank or 0),
                cost = cost, value = value, profit = profit, onAH = onAH,
                margin = cost > 0 and profit / cost or 0, fpd = m and m.soldPerDay or 0,
                produced = produced })
            end
          end
        end
      end
    end
  end
  return list
end

ns.AHTable.Add({
  id = "Crafting", label = "Herstellen", title = "Herstellen – was sich mit gekauften Materialien lohnt",
  sort = "profit",
  filters = { { "profit", "Mit Gewinn" }, { "learned", "Nur gelernte" }, { "all", "Alle Rezepte" } },
  rowColor = function(e) return not e.learned and { 0.75, 0.15, 0.15, 0.22 } or nil end,
  columns = {
    { "name", "Ergebnis", 0, "LEFT", function(e)
      return e.name .. (e.produced > 1 and string.format(" |cff99999ex%g|r", e.produced) or "")
    end },
    { "learn", "Lernen", 170, "LEFT", function(e)
      if e.learned then return "|cff99999egelernt|r" end
      return (e.tooHigh and "|cffff6b6b" or "|cffffb547") .. e.learn .. "|r"
    end },
    { "cost", "Material", 100, "RIGHT", function(e) return money(e.cost) end, true },
    { "value", "Verkauf netto", 110, "RIGHT", function(e)
      return money(e.value) .. (e.onAH and "" or " |cff99999e(Händler)|r")
    end },
    { "profit", "Gewinn", 100, "RIGHT", function(e)
      return (e.profit >= 0 and "|cff5fd38d" or "|cffff6b6b") .. (e.profit < 0 and "-" or "")
        .. money(math.abs(e.profit)) .. "|r"
    end },
    { "margin", "Marge", 70, "RIGHT", function(e) return string.format("%d %%", math.floor(e.margin * 100 + 0.5)) end },
    { "fpd", "Verk./Tag EU", 90, "RIGHT", function(e) return string.format("%.0f", e.fpd) end, true },
  },
  rows = rows,
  status = function(list)
    local profs = {}
    local prefix = ns.CharKey() .. ":"
    for key, scan in pairs(ns.db.recipes or {}) do
      if key:sub(1, #prefix) == prefix then table.insert(profs, scan.profession) end
    end
    if #profs == 0 then return "Noch kein Beruf bekannt: einmal das Berufsfenster öffnen, dann erscheinen die Rezepte hier." end
    return string.format("%d Rezepte  ·  Berufe: %s  ·  rot = noch nicht gelernt (Musterpreis nicht eingerechnet)  ·"
      .. " Material: Händler, sonst billigstes AH-Angebot  ·  Verkauf: Marktwert hier minus 5 %% Gebühr", #list, table.concat(profs, ", "))
  end,
})
