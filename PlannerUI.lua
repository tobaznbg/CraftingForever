-- PlannerUI: profession window with three tabs.
--   Skillen        cheapest path to the current skill cap, with shopping list
--   Lohnt sich     recipes that earn gold per craft
--   Muster im AH   pattern offers that are cheap or pay back quickly
-- Every money column is shown twice: SICHER (vendor only) and POTENZIAL (auction).
local ADDON, ns = ...

local PlannerUI = {}
ns.PlannerUI = PlannerUI

local WIDTH, HEIGHT = 760, 480
local ROW_HEIGHT = 18
local AH_CAP = 3                 -- units per product assumed to sell at auction
local MIN_PROFIT = 10000         -- potential deal: at least 1g per craft ...
local MIN_MARGIN = 0.5           -- ... and 50 % above material cost
local BET_GAP = 10000            -- AH upside above this is marked as a bet
local PAYBACK_MAX = 5
local MAX_SKILL = 300
-- German rank names by their cap, and the character level a rank requires.
local RANK_NAMES = { [75] = "Lehrling", [150] = "Geselle", [225] = "Experte", [300] = "Fachmann" }
local RANK_LEVEL = { [225] = 20, [300] = 35 }            -- pattern pays back within this many crafts
local CHEAP_SHARE = 0.5          -- pattern at most half its usual price

local GREEN, RED, GREY, GOLD, ORANGE = "|cff5fd38d", "|cffff6b6b", "|cff8e8e93", "|cffd8c9a3", "|cffffb547"
local SOURCE = { ["6"] = "Lehrer", ["2"] = "Drop", ["5"] = "Händler", ["4"] = "Quest" }

local frame, scroll, content, title, tabs
local rows = {}
local current = "path"

-- Formatting ---------------------------------------------------------------

local function money(copper)
  return ns.FormatMoney(copper, true)
end

-- A cost: positive is money spent (white), negative is a gain (green).
local function cost(copper)
  if copper <= 0 then return GREEN .. "+" .. money(-copper) .. "|r" end
  return "-" .. money(copper)
end

-- A profit: positive green, negative red.
local function profit(copper)
  if copper > 0 then return GREEN .. "+" .. money(copper) .. "|r" end
  return RED .. money(copper) .. "|r"
end

local function sourceText(code)
  local parts = {}
  for c in tostring(code or ""):gmatch("%d") do table.insert(parts, SOURCE[c] or c) end
  return table.concat(parts, "+")
end

-- Rows ---------------------------------------------------------------------
-- A row is either a text line spanning the width or a list of cells laid out
-- by the current column definition { {width, justify}, ... }.

local columns
local lines

local function addText(text) table.insert(lines, { text = text }) end
local function addCells(...) table.insert(lines, { cells = { ... } }) end
-- A row about one item: hovering it shows the item tooltip.
local function addItemCells(itemID, ...) table.insert(lines, { cells = { ... }, item = itemID }) end

local function itemIcon(itemID)
  local getIcon = (C_Item and C_Item.GetItemIconByID) or GetItemIcon
  return itemID and getIcon and getIcon(itemID) or nil
end

-- Name with the item's icon in front.
local function withIcon(itemID, text)
  local icon = itemIcon(itemID)
  if not icon then return text end
  return "|T" .. icon .. ":14:14:0:0|t " .. text
end
local function addBlank() table.insert(lines, { text = " " }) end

local function rowFrame(index)
  local row = rows[index]
  if row then return row end
  row = CreateFrame("Frame", nil, content)
  row:SetHeight(ROW_HEIGHT)
  row.stripe = ns.Style.Solid(row, ns.Style.C.row)
  row.stripe:SetAllPoints()
  local highlight = ns.Style.Solid(row, ns.Style.C.hover, "BACKGROUND", 1)
  highlight:SetAllPoints()
  highlight:Hide()
  row:SetScript("OnEnter", function(self)
    if not self.item then return end
    highlight:Show()
    GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
    GameTooltip:SetItemByID(self.item)
    GameTooltip:Show()
  end)
  row:SetScript("OnLeave", function()
    highlight:Hide()
    GameTooltip:Hide()
  end)
  row.cells = {}
  rows[index] = row
  return row
end

local function cell(row, index)
  local fs = row.cells[index]
  if not fs then
    fs = ns.Style.Text(row, 12)
    row.cells[index] = fs
  end
  return fs
end

local function render()
  local width = scroll:GetWidth()
  content:SetWidth(width)
  for index, line in ipairs(lines) do
    local row = rowFrame(index)
    row:ClearAllPoints()
    row:SetPoint("TOPLEFT", 0, -(index - 1) * ROW_HEIGHT)
    row:SetWidth(width)
    row.item = line.item
    row:EnableMouse(line.item ~= nil)
    -- Stripes only on table rows, so headings and notes stay calm.
    row.stripe:SetShown(line.cells ~= nil and index % 2 == 0)
    row:Show()
    for _, fs in pairs(row.cells) do fs:Hide() end
    if line.text then
      local fs = cell(row, 1)
      fs:ClearAllPoints()
      fs:SetPoint("LEFT", 4, 0)
      fs:SetWidth(width - 8)
      fs:SetJustifyH("LEFT")
      fs:SetText(line.text)
      fs:Show()
    else
      local x = 4
      for i, def in ipairs(columns) do
        local fs = cell(row, i)
        fs:ClearAllPoints()
        fs:SetPoint("LEFT", x, 0)
        fs:SetWidth(def[1])
        fs:SetJustifyH(def[2] or "LEFT")
        fs:SetText(line.cells[i] or "")
        fs:Show()
        x = x + def[1] + 6
      end
    end
  end
  for index = #lines + 1, #rows do rows[index]:Hide() end
  content:SetHeight(math.max(1, #lines * ROW_HEIGHT))
  if scroll.UpdateBar then scroll.UpdateBar() end
end

-- Tabs ---------------------------------------------------------------------

local function professionOrNil()
  local list = ns.Costs.Professions()
  local prof = list[1]
  if not prof then
    addText("Noch keine Berufsdaten.")
    addText("Öffne einmal dein Berufsfenster (z. B. Lederverarbeitung), dann hier |cffffffffAktualisieren|r.")
  end
  return prof
end

-- Sales value of a path segment: `cap` units at auction, the rest to a vendor.
local function segmentValue(seg, cap)
  local c = seg.recipe
  local atAuction = math.min(cap, seg.crafts)
  return atAuction * c.ahValue + (seg.crafts - atAuction) * c.vendorValue
end

local function showPath()
  local prof = professionOrNil()
  if not prof then return end
  -- Plan to the end of the profession, not just the current rank cap; the
  -- caps where the next rank has to be learned are marked along the way.
  local from, cap, to = prof.rank, prof.max, MAX_SKILL
  title:SetText(string.format("%s  %d → %d", prof.name, from, to))
  if from >= to then
    addText(GREEN .. "Maximum erreicht.|r")
    return
  end
  local function capNotice(at)
    local rank = RANK_NAMES[at + 75] or "nächste Stufe"
    local note = RANK_LEVEL[at + 75] and string.format(", braucht Charakterstufe %d", RANK_LEVEL[at + 75]) or ""
    addText(string.format("%s  Bei %d: beim Lehrer \"%s\" lernen (bis %d%s).|r", ORANGE, at, rank, at + 75, note))
  end
  if from >= cap then capNotice(cap) end

  -- Trainer recipes plus patterns sold by vendors, as the usual levelling guides do.
  local segments, _, reached = ns.Planner.Path(ns.Costs.Candidates(prof, "vendor"), from, to, 0)
  if not segments then
    addText("Kein Weg gefunden – für manche Zutaten fehlen Preise. Im AH einmal scannen.")
    return
  end

  columns = { { 55 }, { 225 }, { 35, "RIGHT" }, { 80, "RIGHT" }, { 90, "RIGHT" }, { 90, "RIGHT" } }
  addText(GREY .. "Günstigster sicherer Weg mit Lehrer-Rezepten und Händler-Mustern. Kosten = Material + Lehrer − Verkauf an Händler.|r")
  addCells(GOLD .. "Skill|r", GOLD .. "Rezept|r", GOLD .. "Stück|r", GOLD .. "Ausgabe|r",
    GOLD .. "SICHER|r", GOLD .. "POTENZIAL|r")

  local gold = GetMoney()
  local spent, reachable = 0, from
  local sumSpend, sumSafe, sumPotential = 0, 0, 0
  local nextCap = cap
  for _, seg in ipairs(segments) do
    local c = seg.recipe
    if nextCap > from and seg.to > nextCap and nextCap < to then
      capNotice(nextCap)
      nextCap = nextCap + 75
    end
    local outlay = seg.spend + seg.learned
    local safe = outlay - segmentValue(seg, 0)
    local potential = outlay - segmentValue(seg, AH_CAP)
    local name = c.name
    if seg.learned > 0 then name = name .. GREY .. "  (lernen " .. money(seg.learned) .. ")|r" end
    if c.needsPattern then name = name .. ORANGE .. "  (Muster vom Händler, Preis fehlt)|r" end
    if c.artisan then name = name .. ORANGE .. "  (Fachmann-Lehrer, Horde: Hahrana Ironhide, Feralas)|r" end
    addItemCells(c.out, string.format("%d-%d", seg.from, seg.to), withIcon(c.out, name), tostring(math.ceil(seg.crafts)),
      money(outlay), cost(safe), cost(potential))
    if safe - potential >= BET_GAP then
      local demand, color = ns.Market.Demand(c.out)
      addText(ORANGE .. "      Wette: im AH mehr wert – erst 1 Stück testen. Nachfrage EU: |r" .. color .. demand .. "|r")
    end
    -- How far the current gold reaches, paying everything up front.
    if spent + outlay <= gold and reachable == seg.from then
      spent = spent + outlay
      reachable = seg.to
    end
    sumSpend = sumSpend + outlay
    sumSafe, sumPotential = sumSafe + safe, sumPotential + potential
  end
  addCells("", GOLD .. "Gesamt|r", "", money(sumSpend), cost(sumSafe), cost(sumPotential))
  if reached < to then
    addBlank()
    addText(string.format("%sAb Skill %d gibt es keine Lehrer- oder Händler-Rezepte mehr, die noch Punkte geben.|r", ORANGE, reached))
    addText("Weiter geht es nur mit Mustern (Drop, Händler, Ruf). Die günstigsten, die bei " .. reached .. " noch Punkte geben:")
    local options = {}
    for _, c in ipairs(ns.Costs.Candidates(prof, true)) do
      local chance = ns.Planner.Chance(c.colors, reached)
      if not c.learned and c.learnAt <= reached and chance > 0 then
        table.insert(options, { c = c, perPoint = (c.cost - c.vendorValue) / chance })
      end
    end
    table.sort(options, function(a, b) return a.perPoint < b.perPoint end)
    for i = 1, math.min(5, #options) do
      local c = options[i].c
      addItemCells(c.out, "", withIcon(c.out, c.name), "", sourceText(c.source), cost(options[i].perPoint), GREY .. "pro Punkt|r")
    end
  end
  addBlank()
  if reachable >= to then
    addText(string.format("Dein Gold (%s) reicht für den ganzen Weg.", money(gold)))
  else
    addText(string.format("%sDein Gold (%s) reicht bis Skill %d.|r Dann verkaufen und weiter.",
      ORANGE, money(gold), reachable))
  end

  addBlank()
  columns = { { 200 }, { 60, "RIGHT" }, { 50, "RIGHT" }, { 60, "RIGHT" }, { 70, "RIGHT" }, { 80, "RIGHT" }, { 60 } }
  addText(GOLD .. "Einkaufsliste|r")
  addCells(GOLD .. "Material|r", GOLD .. "brauchst|r", GOLD .. "hast|r", GOLD .. "kaufen|r",
    GOLD .. "je|r", GOLD .. "Summe|r", GOLD .. "wo|r")
  local need = ns.Planner.Shopping(segments)
  local list = {}
  for itemID, count in pairs(need) do
    local unit, where = ns.Costs.Buy(itemID)
    local owned = ns.Costs.Owned(itemID)
    local buy = math.max(0, count - owned)
    table.insert(list, { id = itemID, count = count, owned = owned, buy = buy, unit = unit or 0, where = where or "?" })
  end
  table.sort(list, function(a, b) return a.buy * a.unit > b.buy * b.unit end)
  local total = 0
  for _, item in ipairs(list) do
    total = total + item.buy * item.unit
    addItemCells(item.id, withIcon(item.id, ns.ItemName(item.id)), tostring(item.count), tostring(item.owned),
      item.buy > 0 and tostring(item.buy) or GREEN .. "0|r", money(item.unit), money(item.buy * item.unit), item.where)
  end
  addCells(GOLD .. "Noch zu kaufen|r", "", "", "", "", money(total), "")
end

local function showProfit()
  local prof = professionOrNil()
  if not prof then return end
  title:SetText(prof.name .. "  –  was sich lohnt")
  local result = ns.Planner.Profit(ns.Costs.Candidates(prof, true), MIN_PROFIT, MIN_MARGIN)

  columns = { { 190 }, { 30, "RIGHT" }, { 95 }, { 70, "RIGHT" }, { 85, "RIGHT" }, { 85, "RIGHT" }, { 120 } }
  addText(GREY .. "Gewinn pro Herstellung. SICHER = Händler. POTENZIAL = erwarteter AH-Erlös (siehe unten).|r")
  addCells(GOLD .. "Rezept|r", GOLD .. "ab|r", GOLD .. "Muster|r", GOLD .. "Material|r",
    GOLD .. "SICHER|r", GOLD .. "POTENZIAL|r", GOLD .. "Nachfrage EU|r")
  local shown = 0
  for _, row in ipairs(result) do
    if row.safeDeal or row.potentialDeal then
      local c = row.recipe
      local status
      if c.learned then
        status = GREEN .. "gelernt|r"
      else
        status = sourceText(c.source)
        if c.learnAt > prof.rank then status = GREY .. status .. "|r" end
      end
      local name = c.name
      if c.learnAt > prof.rank then name = GREY .. name .. "|r" end
      addItemCells(c.out, withIcon(c.out, name), tostring(c.learnAt), status, money(c.cost), profit(row.safe),
        c.hasAuction and profit(row.potential) or GREY .. "kein AH|r", (function()
          local demand, color = ns.Market.Demand(c.out)
          return color .. demand .. "|r"
        end)())
      shown = shown + 1
    end
  end
  if shown == 0 then addText("Gerade lohnt sich nichts – nach dem nächsten AH-Scan neu ansehen.") end
  addBlank()
  addText(GREY .. "Grau = Skill noch zu niedrig.|r")
  addText(GREY .. "POTENZIAL = Verkaufsquote x echter Verkaufspreis (TSM, ganz EU) minus 5 %; was liegen bleibt, geht an den Händler.|r")
  addText(GREY .. "Nachfrage = wie oft ein Angebot verkauft wird, und Verkäufe pro Tag in ganz EU. Stand: " ..
    (ns.Market.Updated() or "?"):sub(1, 10) .. "|r")
end

local function showPatterns()
  local prof = professionOrNil()
  if not prof then return end
  title:SetText(prof.name .. "  –  Muster im AH")
  ns.Patterns.Ensure()
  if ns.Patterns.running then
    addText("Suche Muster in der Item-Datenbank … gleich nochmal |cffffffffAktualisieren|r.")
    return
  end

  local profitByRecipe = {}
  for _, row in ipairs(ns.Planner.Profit(ns.Costs.Candidates(prof, true), MIN_PROFIT, MIN_MARGIN)) do
    profitByRecipe[row.recipe.id] = row
  end

  local offers, unpriced = {}, 0
  for _, pattern in ipairs(ns.Patterns.ForScan(prof.scan)) do
    local recipe = prof.scan.recipes[pattern.recipeID]
    if recipe and not recipe.learned then
      local price = ns.Prices.Auction(pattern.itemID)
      if price then
        local usual = ns.Patterns.UsualPrice(pattern.itemID, 3)
        local vendor = ns.Costs.VendorSell(pattern.itemID)
        local row = profitByRecipe[pattern.recipeID]
        local safePayback = row and row.safe > 0 and math.ceil(price / row.safe) or nil
        local potentialPayback = row and row.recipe.hasAuction and row.potential > 0
          and math.ceil(price / row.potential) or nil
        local reasons = {}
        if vendor > price then table.insert(reasons, GREEN .. "unter Händlerpreis|r") end
        if usual and price <= usual * CHEAP_SHARE then
          table.insert(reasons, GREEN .. string.format("%d %% unter üblich|r", 100 - math.floor(price / usual * 100)))
        end
        if safePayback and safePayback <= PAYBACK_MAX then table.insert(reasons, GREEN .. "sicher schnell bezahlt|r") end
        if potentialPayback and potentialPayback <= PAYBACK_MAX then table.insert(reasons, "AH schnell bezahlt") end
        table.insert(offers, {
          itemID = pattern.itemID, name = pattern.name, price = price, usual = usual, learnAt = row and row.recipe.learnAt,
          safePayback = safePayback, potentialPayback = potentialPayback, reasons = reasons,
          deal = #reasons > 0,
        })
      else
        unpriced = unpriced + 1
      end
    end
  end
  table.sort(offers, function(a, b)
    if a.deal ~= b.deal then return a.deal end
    return (a.potentialPayback or math.huge) < (b.potentialPayback or math.huge)
  end)

  columns = { { 175 }, { 30, "RIGHT" }, { 65, "RIGHT" }, { 65, "RIGHT" }, { 50, "RIGHT" }, { 60, "RIGHT" }, { 140 } }
  addText(GREY .. "Bezahlt nach = so viele Herstellungen, bis das Muster wieder drin ist.|r")
  addCells(GOLD .. "Muster|r", GOLD .. "ab|r", GOLD .. "AH|r", GOLD .. "üblich|r",
    GOLD .. "SICHER|r", GOLD .. "POTENZIAL|r", GOLD .. "Schnäppchen weil|r")
  for _, offer in ipairs(offers) do
    local name = offer.deal and (GREEN .. offer.name .. "|r") or offer.name
    addItemCells(offer.itemID, withIcon(offer.itemID, name), offer.learnAt and tostring(offer.learnAt) or "",
      money(offer.price), offer.usual and money(offer.usual) or GREY .. "–|r",
      offer.safePayback and (offer.safePayback .. "x") or GREY .. "nie|r",
      offer.potentialPayback and (offer.potentialPayback .. "x") or GREY .. "nie|r",
      table.concat(offer.reasons, ", "))
  end
  if #offers == 0 then addText("Keine Muster mit AH-Preis bekannt.") end
  addBlank()
  addText(string.format("%s%d weitere Muster ohne AH-Preis. Preise kommen aus dem eigenen AH-Scan:|r",
    GREY, unpriced))
  addText(GREY .. "am Auktionshaus \"CF Scan\" klicken (alle 15 Minuten möglich).|r")
end

local SIGNAL_COLORS = { green = GREEN, yellow = GOLD, orange = ORANGE, grey = GREY }

local function showFarming()
  title:SetText("Farmen  –  was bringt dein AH")
  local updated, hours, ownT, minHours = ns.Farming.DataInfo()
  if not updated and not ownT then
    addText("Noch keine AH-Daten. Am Auktionshaus \"CF Scan\" klicken oder /cf scan.")
    return
  end
  addText(GREY .. string.format("Preise: %s. Absatz: %s.|r",
    ownT and ("eigener Scan " .. date("%d.%m. %H:%M", ownT)) or ("Sammler " .. (updated or "?")),
    hours >= minHours and string.format("Sammler, %d Stunden", hours)
      or string.format("noch zu wenig Daten (%d von %d Stunden)", hours, minHours)))
  columns = { { 190 }, { 75, "RIGHT" }, { 75, "RIGHT" }, { 55, "RIGHT" }, { 60, "RIGHT" }, { 95 }, { 130 } }
  for _, group in ipairs(ns.Farming.Evaluate()) do
    addBlank()
    addText(GOLD .. group.label .. "|r")
    addCells(GOLD .. "Item|r", GOLD .. "Erlös/Stück|r", GOLD .. "Marktwert|r", GOLD .. "im AH|r",
      GOLD .. "Absatz/Tag|r", GOLD .. "Signal|r", GOLD .. "Zugang|r")
    for _, row in ipairs(group.rows) do
      local m = row.market
      local name = ns.ItemName(row.itemID)
      if not row.reachable then name = GREY .. name .. "|r" end
      local color = SIGNAL_COLORS[row.color] or GREY
      addItemCells(row.itemID, withIcon(row.itemID, name),
        m and money(row.value) or GREY .. "–|r",
        m and money(m.price) or "",
        m and tostring(m.quantity) or "",
        m and m.soldPerDay and string.format("%.0f", m.soldPerDay) or GREY .. "?|r",
        color .. row.signal .. "|r",
        (row.reachable and GREEN or GREY) .. row.access .. "|r")
    end
  end
  addBlank()
  addText(GREY .. "Erlös = günstigstes Angebot - 1 Kupfer, minus 5 % Gebühr (du unterbietest und stehst vorne).|r")
  addText(GREY .. "Signal: lohnt = Erlös >= 2s und >= 10 Käufe/Tag in deinem AH. Unterbiet-Druck und Trend folgen mit mehr Daten.|r")
  addText(GREY .. "Was pro Stunde rauskommt, misst die Farm-Sitzung (/cf neu).|r")
end

local SPOTS_REACHABLE = 40 -- rows shown that you can farm now
local SPOTS_LATER = 10     -- rows shown that need a higher level

local function showSpots()
  title:SetText("Farmen  –  Spots nach Wert pro Kill")
  local updated, hours, ownT = ns.Farming.DataInfo()
  addText(GREY .. string.format("Preise: %s. Dropchancen: wowhead Forever. Münzen fehlen im Wert pro Kill, die misst die Sitzung.|r",
    ownT and ("eigener Scan " .. date("%d.%m. %H:%M", ownT)) or ("Sammler " .. (updated or "?"))))
  columns = { { 165 }, { 115 }, { 45, "RIGHT" }, { 65, "RIGHT" }, { 180 }, { 50, "RIGHT" }, { 70, "RIGHT" } }
  addCells(GOLD .. "Tier / NPC|r", GOLD .. "Gebiet|r", GOLD .. "Stufe|r", GOLD .. "Wert/Kill|r",
    GOLD .. "davon|r", GOLD .. "Kills/h|r", GOLD .. "Gold/h|r")
  local shownNow, shownLater, headerLater = 0, 0, false
  for _, row in ipairs(ns.Farming.Spots()) do
    local show = (row.reachable and shownNow < SPOTS_REACHABLE) or (not row.reachable and shownLater < SPOTS_LATER)
    if show then
      if not row.reachable and not headerLater then
        addBlank()
        addText(GOLD .. "Später (Stufe zu hoch)|r")
        headerLater = true
      end
      local name = row.reachable and row.name or (GREY .. row.name .. "|r")
      local breakdown = ns.Farming.Breakdown(row, 2)
      if row.note then breakdown = breakdown .. GREY .. " (" .. row.note .. ")|r" end
      local m = row.measured
      addCells(name, row.zone, string.format("%d-%d", row.lo, row.hi), money(row.value), breakdown,
        m and string.format("%.0f", m.killsPerHour) or GREY .. "–|r",
        m and money(m.goldPerHour) or GREY .. "–|r")
      if row.reachable then shownNow = shownNow + 1 else shownLater = shownLater + 1 end
    end
  end
  addBlank()
  addText(GREY .. "Wert/Kill = Dropchance x Menge x Erlös (günstigstes Angebot - 1 Kupfer - 5 %), plus Häuten wenn dein Skill reicht.|r")
  addText(GREY .. "Kills/h und Gold/h: gemessen in deinen Farm-Sitzungen (/cf neu vor dem Test), inklusive Münzen.|r")
end

local ACTION_COLORS = { AH = GREEN, ["Händler"] = GOLD, behalten = GREY }

local function showInventory()
  title:SetText("Bestand  –  was verkaufen, was behalten")
  local rows, inv = ns.Inventory.Rows()
  if not inv.bagsT then
    addText("Noch keine Daten – einmal die Taschen öffnen oder /reload.")
    return
  end
  addText(GREY .. string.format("Taschen: %s. Bank: %s. Erlös AH = günstigstes Angebot - 1 Kupfer - 5 %%.|r",
    date("%d.%m. %H:%M", inv.bagsT), inv.bankT and date("%d.%m. %H:%M", inv.bankT) or "noch nie geöffnet"))
  columns = { { 230 }, { 45, "RIGHT" }, { 60 }, { 85, "RIGHT" }, { 85, "RIGHT" }, { 70 }, { 140 } }
  addCells(GOLD .. "Item|r", GOLD .. "Anzahl|r", GOLD .. "Ort|r", GOLD .. "Erlös|r", GOLD .. "Händler|r",
    GOLD .. "Tun|r", GOLD .. "Warum|r")
  local sumAH, sumVendor, hidden = 0, 0, 0
  for _, row in ipairs(rows) do
    -- Quest items and worthless things only clutter the list.
    if row.reason == "Quest" or row.reason == "kein Wert" then
      hidden = hidden + 1
    else
    local color = ACTION_COLORS[row.action] or GREY
    addItemCells(row.itemID, withIcon(row.itemID, ns.ItemName(row.itemID)), tostring(row.count), row.place,
      row.value > 0 and money(row.value) or GREY .. "–|r",
      row.vendorTotal > 0 and money(row.vendorTotal) or GREY .. "–|r",
      color .. row.action .. "|r", GREY .. row.reason .. "|r")
    if row.action == "AH" then sumAH = sumAH + row.value end
    if row.action == "Händler" then sumVendor = sumVendor + row.value end
    end
  end
  addBlank()
  addText(string.format("Ins AH: %s%s|r   Zum Händler: %s%s|r   Zusammen: %s%s|r",
    GREEN, money(sumAH), GOLD, money(sumVendor), GREEN, money(sumAH + sumVendor)))
  if hidden > 0 then
    addText(GREY .. string.format("%d Questgegenstände und wertlose Items ausgeblendet.|r", hidden))
  end
  addText(GREY .. "AH, wenn es pro Stück mindestens 20 % und für den ganzen Stapel mindestens 10s mehr als der Händler bringt.|r")
end

local KIND_TEXT = { buy = "gekauft", post = "eingestellt", sale = "verkauft", expired = "abgelaufen",
  cancelled = "abgebrochen" }

local function showLedger()
  title:SetText("Handel  –  gekauft, eingestellt, verkauft")
  local list, total = ns.Ledger.Summary()
  if #list == 0 then
    addText("Noch nichts erfasst. Käufe und Einstellungen werden ab jetzt mitgeschrieben,")
    addText("Verkäufe, abgelaufene und abgebrochene Auktionen beim Öffnen des Briefkastens.")
    return
  end
  addText(string.format("Gekauft %s%s|r   ·   Verkauft netto %s%s|r   ·   Gewinn aus Handel %s   ·   Noch auf Lager (Einkauf) %s",
    GOLD, money(total.spent), GREEN, money(total.net), profit(total.profit), money(total.held)))
  if total.ownNet > 0 then
    addText(GREY .. "Davon Verkauf eigener Ware (nicht gekauft): " .. money(total.ownNet) .. "|r")
  end
  addText(GREY .. "Verkäufe kommen aus den AH-Mails: Briefkasten öffnen, dann stehen sie hier. Gewinn = Verkauf netto minus Ø Einkaufspreis, nur für gekaufte Stücke.|r")
  addBlank()
  columns = { { 210 }, { 105, "RIGHT" }, { 50, "RIGHT" }, { 105, "RIGHT" }, { 60, "RIGHT" }, { 50, "RIGHT" }, { 90, "RIGHT" } }
  addCells(GOLD .. "Item|r", GOLD .. "Gekauft|r", GOLD .. "Einges.|r", GOLD .. "Verkauft netto|r",
    GOLD .. "Abgel./abg.|r", GOLD .. "Lager|r", GOLD .. "Gewinn|r")
  for _, it in ipairs(list) do
    local name = it.itemID and withIcon(it.itemID, ns.ItemName(it.itemID)) or (it.name or "?")
    addItemCells(it.itemID, name,
      it.bought > 0 and string.format("%dx %s", it.bought, money(it.spent)) or GREY .. "–|r",
      it.posted > 0 and tostring(it.posted) or GREY .. "–|r",
      it.sold > 0 and string.format("%dx %s", it.sold, money(it.net)) or GREY .. "–|r",
      (it.expired + it.cancelled) > 0 and tostring(it.expired + it.cancelled) or GREY .. "–|r",
      it.open > 0 and tostring(it.open) or GREY .. "–|r",
      it.bought > 0 and it.sold > 0 and profit(it.profit) or GREY .. "–|r")
  end
  addBlank()
  addText(GOLD .. "Letzte Vorgänge|r")
  columns = { { 90 }, { 80 }, { 230 }, { 50, "RIGHT" }, { 120, "RIGHT" } }
  for _, e in ipairs(ns.Ledger.Recent(25)) do
    local amount = e.k == "buy" and money(e.c or 0)
      or e.k == "sale" and (money((e.c or 0) - (e.cut or 0)) .. GREY .. " netto|r")
      or e.k == "post" and e.p and (money(e.p) .. GREY .. (e.u and e.u > 1 and " /Stk|r" or "|r"))
      or ""
    local name = e.i and withIcon(e.i, ns.ItemName(e.i)) or (e.n or "?")
    addItemCells(e.i, GREY .. date("%d.%m. %H:%M", e.t) .. "|r", KIND_TEXT[e.k] or e.k, name,
      tostring(e.u or 1), amount)
  end
end

local VIEWS = {
  { key = "path", label = "Skillen", fn = showPath },
  { key = "profit", label = "Lohnt sich", fn = showProfit },
  { key = "patterns", label = "Muster im AH", fn = showPatterns },
  { key = "spots", label = "Farmen", fn = showSpots },
  { key = "farming", label = "Farm-Items", fn = showFarming },
  { key = "inventory", label = "Bestand", fn = showInventory },
  { key = "ledger", label = "Handel", fn = showLedger },
}

function PlannerUI.Refresh()
  if not frame or not frame:IsShown() then return end
  lines, columns = {}, {}
  for _, view in ipairs(VIEWS) do
    if tabs[view.key] then
      tabs[view.key]:SetActive(view.key == current)
    end
    if view.key == current then view.fn() end
  end
  render()
end

-- Frame --------------------------------------------------------------------

local HEADER = 34 -- title strip
local TABBAR = 30

local function createFrame()
  local Style = ns.Style
  frame = CreateFrame("Frame", "CraftingForeverPlanner", UIParent)
  frame:SetSize(WIDTH, HEIGHT)
  frame:SetFrameStrata("HIGH")
  frame:SetClampedToScreen(true)
  frame:SetMovable(true)
  frame:EnableMouse(true)
  frame:RegisterForDrag("LeftButton")
  frame:SetScript("OnDragStart", frame.StartMoving)
  frame:SetScript("OnDragStop", function(self)
    self:StopMovingOrSizing()
    local point, _, relPoint, x, y = self:GetPoint()
    ns.db.ui.plannerPos = { point, relPoint, x, y }
  end)
  Style.Panel(frame, HEADER)
  local pos = ns.db.ui.plannerPos
  if pos then
    frame:SetPoint(pos[1], UIParent, pos[2], pos[3], pos[4])
  else
    frame:SetPoint("CENTER")
  end
  table.insert(UISpecialFrames, "CraftingForeverPlanner") -- Escape closes it

  local brand = Style.Text(frame, 14)
  brand:SetPoint("TOPLEFT", 14, -10)
  brand:SetText(Style.ACCENT .. "Crafting|r" .. "Forever")
  title = Style.Text(frame, 13)
  title:SetPoint("LEFT", brand, "RIGHT", 14, 0)
  title:SetTextColor(unpack(Style.C.muted))

  local close = Style.Close(frame)
  close:SetPoint("TOPRIGHT", -6, -5)

  tabs = {}
  local x = 8
  for _, view in ipairs(VIEWS) do
    local tab = Style.Tab(frame, view.label, 88, function()
      current = view.key
      ns.Safe(PlannerUI.Refresh)
    end)
    tab:SetPoint("TOPLEFT", x, -(HEADER + 2))
    tabs[view.key] = tab
    x = x + 90
  end
  local refresh = Style.Button(frame, "Aktualisieren", 92, 22, function() ns.Safe(PlannerUI.Refresh) end)
  refresh:SetPoint("TOPRIGHT", -12, -(HEADER + 4))

  local line = Style.Solid(frame, Style.C.border, "BORDER")
  line:SetPoint("TOPLEFT", 1, -(HEADER + TABBAR + 2))
  line:SetPoint("TOPRIGHT", -1, -(HEADER + TABBAR + 2))
  line:SetHeight(1)

  scroll, content = Style.Scroll(frame)
  scroll:SetPoint("TOPLEFT", 10, -(HEADER + TABBAR + 10))
  scroll:SetPoint("BOTTOMRIGHT", -18, 10)
  content:SetSize(WIDTH - 40, 1)
end

-- Opens the window on one tab.
function PlannerUI.Show(key)
  if not frame then createFrame() end
  current = key
  frame:Show()
  ns.Safe(PlannerUI.Refresh)
end

function PlannerUI.Toggle()
  if not frame then createFrame() end
  frame:SetShown(not frame:IsShown())
  if frame:IsShown() then ns.Safe(PlannerUI.Refresh) end
end

-- Fresh prices after an auction house visit or a new profession scan.
local function refreshSoon() C_Timer.After(1, function() ns.Safe(PlannerUI.Refresh) end) end
ns.On("AUCTION_HOUSE_CLOSED", refreshSoon)
ns.On("TRADE_SKILL_LIST_UPDATE", refreshSoon)
ns.On("BAG_UPDATE_DELAYED", refreshSoon)

-- Item names arrive one by one after a cache miss; redraw once they settled.
local namesPending = false
ns.On("GET_ITEM_INFO_RECEIVED", function()
  if namesPending or not (frame and frame:IsShown()) then return end
  namesPending = true
  C_Timer.After(0.5, function()
    namesPending = false
    ns.Safe(PlannerUI.Refresh)
  end)
end)
