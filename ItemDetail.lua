-- ItemDetail: detail window for any item. With the auction house open it docks right of the
-- AH panel (the Selling panel, else the auction house frame); otherwise it is a movable
-- window of its own (position in ns.db.itemDetail), closed by × or ESC.
-- Opened from everywhere: a click on a sniper hit at the auction house (Selling.lua),
-- Alt+left click on an item (bags, bank, character, loot, chat links, Blizzard's AH lists via
-- HandleModifiedItemClick; the addon's own tables via ItemDetail.AltClick) and /m4 item.
-- Shows why the offer is a sniper hit (only while it is one), the hourly price and quantity
-- of the last 48 hours (ns.Item.History), the market figures (ns.Item), the price stair
-- (the sniper's last search, else the own full scan via ns.Item.Listings) and the crafting
-- cost (ns.CraftInfo from Tooltip.lua). No own price logic here.
-- Opened while the auction house is open, it searches the item right away (ns.AHSearch,
-- one search a second, through the sniper while it runs): "suche …", then the price stair
-- and "AH jetzt" of that search ("Preistreppe (gerade gesucht)").
local ADDON, ns = ...

local Detail = {}
ns.ItemDetail = Detail
ns.SniperDetail = Detail -- old name, kept for callers that still use it

local WIDTH = 340
local FREE_HEIGHT = 560 -- height as a window of its own (docked it follows the anchor)
local LINE = 16
local CHART_H, SLOTS = 96, 48
local GREEN, ORANGE = "|cff5fd38d", "|cffffb547"

local frame, body, scroll, itemID
local origin   -- "sniper" when opened from the sniper list at the auction house
local docked   -- anchor frame while docked at the auction house, nil as a window of its own
local lines, sections = {}, {}
local chart
local live     -- { itemID, state = "searching"|"done"|"failed", offers, t } of the search on opening
local render -- forward declared: used by Show/Toggle/Refresh, defined below
local place  -- forward declared: used by create and the auction house events

local function money(c) return ns.FormatMoney(c, true) end

local function ago(t)
  local s = math.max(0, time() - t)
  if s < 60 then return string.format("vor %d s", s) end
  if s < 3600 then return string.format("vor %d min", math.floor(s / 60)) end
  if s < 2 * 86400 then return string.format("vor %d h", math.floor(s / 3600)) end
  return string.format("vor %d Tagen", math.floor(s / 86400))
end

local WEEKDAYS = { "So", "Mo", "Di", "Mi", "Do", "Fr", "Sa" }
-- "Mo 14:00" in local time.
local function stamp(t)
  return (WEEKDAYS[tonumber(date("%w", t)) + 1] or "") .. " " .. date("%H:%M", t)
end

-- Days / units per day with one decimal, German style: "1,5".
function Detail.Days(d)
  local text = string.format("%.1f", d or 0):gsub("%.", ","):gsub(",0$", "")
  return text
end

local function count(n)
  n = math.floor((n or 0) + 0.5)
  return BreakUpLargeNumbers and BreakUpLargeNumbers(n) or tostring(n)
end

-- Layout helpers: everything is placed top-down on the scroll body with a y cursor.
local y, used, usedSections = 0, 0, 0

local function line(label, value)
  local Style = ns.Style
  used = used + 1
  local l = lines[used]
  if not l then
    l = {}
    l.label = Style.Text(body, 12)
    l.label:SetJustifyH("LEFT")
    l.label:SetTextColor(unpack(Style.C.muted))
    l.value = Style.Text(body, 12)
    l.value:SetJustifyH("RIGHT")
    lines[used] = l
  end
  l.label:ClearAllPoints()
  l.label:SetPoint("TOPLEFT", body, "TOPLEFT", 4, -y)
  l.value:ClearAllPoints()
  l.value:SetPoint("TOPRIGHT", body, "TOPRIGHT", -4, -y)
  l.label:SetText(label or "")
  l.value:SetText(value or "")
  l.label:Show()
  l.value:Show()
  y = y + LINE
  return l
end

local function section(title)
  local Style = ns.Style
  usedSections = usedSections + 1
  local s = sections[usedSections]
  if not s then
    s = {}
    s.text = Style.Text(body, 12)
    s.text:SetJustifyH("LEFT")
    s.rule = Style.Solid(body, Style.C.border, "ARTWORK")
    s.rule:SetHeight(1)
    sections[usedSections] = s
  end
  y = y + (usedSections > 1 and 8 or 2)
  s.text:ClearAllPoints()
  s.text:SetPoint("TOPLEFT", body, "TOPLEFT", 4, -y)
  s.text:SetText(Style.HEAD .. title .. "|r")
  s.rule:ClearAllPoints()
  s.rule:SetPoint("TOPLEFT", body, "TOPLEFT", 4, -(y + 15))
  s.rule:SetPoint("TOPRIGHT", body, "TOPRIGHT", -4, -(y + 15))
  s.text:Show()
  s.rule:Show()
  y = y + 19
  return s
end

-- Chart ------------------------------------------------------------------------------

local function createChart()
  local Style = ns.Style
  local c = CreateFrame("Frame", nil, body)
  c:SetHeight(CHART_H + 42)
  c.plot = CreateFrame("Frame", nil, c)
  c.plot:SetPoint("TOPLEFT", 0, 0)
  c.plot:SetPoint("TOPRIGHT", 0, 0)
  c.plot:SetHeight(CHART_H)
  local bg = Style.Solid(c.plot, { 1, 1, 1, 0.025 })
  bg:SetAllPoints()
  c.base = Style.Solid(c.plot, Style.C.border, "ARTWORK")
  c.base:SetHeight(1)
  c.base:SetPoint("BOTTOMLEFT")
  c.base:SetPoint("BOTTOMRIGHT")
  c.bars, c.lines, c.ticks = {}, {}, {}
  c.limit = Style.Solid(c.plot, { 0.37, 0.83, 0.55, 0.5 }, "ARTWORK")
  c.limit:SetHeight(1)
  c.sell = Style.Solid(c.plot, { 1, 1, 1, 0.45 }, "ARTWORK")
  c.sell:SetHeight(1)
  local function label(size, point, x, yy)
    local fs = Style.Text(c, size)
    fs:SetPoint(point, c.plot, point, x, yy)
    fs:SetTextColor(unpack(Style.C.muted))
    return fs
  end
  c.hi = label(10, "TOPLEFT", 3, -2)
  c.lo = label(10, "BOTTOMLEFT", 3, 3)
  c.qtyMax = label(10, "TOPRIGHT", -3, -2)
  c.t1 = Style.Text(c, 10)
  c.t1:SetPoint("TOPLEFT", c.plot, "BOTTOMLEFT", 0, -2)
  c.t2 = Style.Text(c, 10)
  c.t2:SetPoint("TOP", c.plot, "BOTTOM", 0, -2)
  c.t3 = Style.Text(c, 10)
  c.t3:SetPoint("TOPRIGHT", c.plot, "BOTTOMRIGHT", 0, -2)
  c.legend = Style.Text(c, 10)
  c.legend:SetPoint("TOPLEFT", c.plot, "BOTTOMLEFT", 0, -15)
  c.legend:SetPoint("RIGHT", c, "RIGHT", 0, 0)
  c.legend:SetJustifyH("LEFT")
  c.legend:SetWordWrap(true) -- two lines with buy/sell lines
  for _, fs in ipairs({ c.t1, c.t2, c.t3, c.legend }) do fs:SetTextColor(unpack(Style.C.muted)) end
  c.empty = Style.Text(c.plot, 11)
  c.empty:SetPoint("CENTER")
  c.empty:SetTextColor(unpack(Style.C.muted))
  return c
end

local function pooled(list, i, make)
  local t = list[i]
  if not t then t = make(); list[i] = t end
  t:Show()
  return t
end

local function hideFrom(list, first)
  for i = first, #list do list[i]:Hide() end
end

-- Draws the 48 h history: quantity as muted bars, cheapest offer as an accent line
-- (broken where the item was sold out or no snapshot exists), sold-out hours as orange
-- ticks on the base line, buy up to (green) and sell at (white) as thin lines.
local function drawChart(c, history, limit, sellAt)
  local Style = ns.Style
  local plot = c.plot
  local w = WIDTH - 34 -- body width minus the chart's margins
  local slotW = w / SLOTS
  local prices, qty = history and history.prices or {}, history and history.qty or {}
  local lo, hi, qmax = nil, nil, 0
  for i = 1, SLOTS do
    local p, q = prices[i], qty[i]
    if p and p > 0 then lo = math.min(lo or p, p); hi = math.max(hi or p, p) end
    if q and q > qmax then qmax = q end
  end
  if not lo then
    c.empty:SetText(history and "48 h lang nicht im Angebot" or "Kein Verlauf für dieses Item")
    c.empty:Show()
    hideFrom(c.bars, 1); hideFrom(c.lines, 1); hideFrom(c.ticks, 1)
    c.limit:Hide()
    c.sell:Hide()
    c.hi:SetText(""); c.lo:SetText(""); c.qtyMax:SetText("")
    c.t1:SetText(""); c.t2:SetText(""); c.t3:SetText("")
    c.legend:SetText("")
    return
  end
  c.empty:Hide()
  local top, bottom = hi, lo
  for _, v in ipairs({ limit or 0, sellAt or 0 }) do
    if v > 0 then top, bottom = math.max(top, v), math.min(bottom, v) end
  end
  if top == bottom then top, bottom = top * 1.05 + 1, bottom * 0.95 end
  local plotTop, plotBottom = CHART_H - 14, 12 -- room for the min/max labels
  local function py(p) return plotBottom + (p - bottom) / (top - bottom) * (plotTop - plotBottom) end
  -- quantity bars
  local nb = 0
  for i = 1, SLOTS do
    local q = qty[i]
    if q and q > 0 and qmax > 0 then
      nb = nb + 1
      local bar = pooled(c.bars, nb, function() return Style.Solid(plot, { 1, 1, 1, 0.09 }, "BORDER") end)
      bar:ClearAllPoints()
      bar:SetPoint("BOTTOMLEFT", plot, "BOTTOMLEFT", (i - 1) * slotW + 0.5, 1)
      bar:SetSize(math.max(1, slotW - 1), math.max(1, (CHART_H - 2) * q / qmax))
    end
  end
  hideFrom(c.bars, nb + 1)
  -- price line and sold-out ticks
  local nl, nt, last = 0, 0, nil
  for i = 1, SLOTS do
    local p = prices[i]
    local x = (i - 0.5) * slotW
    if p and p > 0 then
      local yy = py(p)
      -- connected to the previous hour, or a short dash after a gap so it stays visible
      local x0, y0, x1 = x - 1.5, yy, x + 1.5
      if last and last[1] == i - 1 then x0, y0, x1 = last[2], last[3], x end
      if plot.CreateLine then
        nl = nl + 1
        local l = pooled(c.lines, nl, function()
          local ln = plot:CreateLine(nil, "OVERLAY")
          ln:SetThickness(2)
          ln:SetColorTexture(unpack(Style.C.accent))
          return ln
        end)
        l:SetStartPoint("BOTTOMLEFT", plot, x0, y0)
        l:SetEndPoint("BOTTOMLEFT", plot, x1, yy)
      end
      last = { i, x, yy }
    else
      last = nil
      if p == 0 then
        nt = nt + 1
        local t = pooled(c.ticks, nt, function() return Style.Solid(plot, { 1, 0.71, 0.28, 0.9 }, "OVERLAY") end)
        t:ClearAllPoints()
        t:SetPoint("BOTTOMLEFT", plot, "BOTTOMLEFT", (i - 1) * slotW + 0.5, 1)
        t:SetSize(math.max(1, slotW - 1), 3)
      end
    end
  end
  hideFrom(c.lines, nl + 1)
  hideFrom(c.ticks, nt + 1)
  if sellAt and sellAt > 0 then
    c.sell:ClearAllPoints()
    c.sell:SetPoint("BOTTOMLEFT", plot, "BOTTOMLEFT", 0, py(sellAt))
    c.sell:SetPoint("BOTTOMRIGHT", plot, "BOTTOMRIGHT", 0, py(sellAt))
    c.sell:Show()
  else
    c.sell:Hide()
  end
  if limit and limit > 0 then
    c.limit:ClearAllPoints()
    c.limit:SetPoint("BOTTOMLEFT", plot, "BOTTOMLEFT", 0, py(limit))
    c.limit:SetPoint("BOTTOMRIGHT", plot, "BOTTOMRIGHT", 0, py(limit))
    c.limit:Show()
  else
    c.limit:Hide()
  end
  c.hi:SetText(money(hi))
  c.lo:SetText(money(lo))
  c.qtyMax:SetText(qmax > 0 and ("max " .. count(qmax) .. " Stück") or "")
  local start, step = history.start, history.step
  local lastT = start + (SLOTS - 1) * step
  c.t1:SetText(stamp(start))
  c.t2:SetText(stamp(start + (SLOTS / 2) * step))
  c.t3:SetText(time() - lastT < 2 * 3600 and "jetzt" or stamp(lastT))
  c.legend:SetText(ns.Style.ACCENT .. "Linie|r billigstes  ·  Balken Menge  ·  " .. ORANGE .. "orange|r ausverkauft"
    .. (limit and ("  ·  " .. GREEN .. "grün|r Kauf bis  ·  weiß Einstellen") or ""))
end

-- Content ------------------------------------------------------------------------------

-- The sniper's current hit for the item, nil if it is none right now.
local function currentHit(id)
  if not (ns.Sniper and ns.Sniper.State) then return nil end
  for _, e in ipairs(ns.Sniper.State().rows) do
    if e.itemID == id and e.hit then return e.hit end
  end
end

-- Offers of the own full scan grouped by unit price, cheapest first, and the scan time.
local function scanLevels(id)
  local list, t = ns.Item.Listings(id)
  if not list or #list == 0 then return nil end
  local levels = {}
  for _, l in ipairs(list) do
    local last = levels[#levels]
    if last and last.unit == l.unit then
      last.count = last.count + l.count
    else
      table.insert(levels, { unit = l.unit, count = l.count })
    end
  end
  return levels, t
end

-- Offers of the newest single search (the shared store of ns.AHSearch or the sniper's list),
-- grouped by price, cheapest first, and its time; nil without one.
local function lastSearch(id)
  local a, ta, b, tb
  if ns.AHSearch and ns.AHSearch.Last then a, ta = ns.AHSearch.Last(id) end
  if ns.Sniper and ns.Sniper.Listings then b, tb = ns.Sniper.Listings(id) end
  if a and (not b or (ta or 0) >= (tb or 0)) then return a, ta end
  return b, tb
end

render = function()
  if not frame or not frame:IsShown() or not itemID then return end
  local Style = ns.Style
  local getIcon = (C_Item and C_Item.GetItemIconByID) or GetItemIcon
  frame.icon:SetTexture(getIcon and getIcon(itemID) or nil)
  frame.name:SetText(ns.ItemName(itemID) or ("#" .. itemID))
  y, used, usedSections = 0, 0, 0
  local h = currentHit(itemID)
  local item = ns.Item(itemID)

  -- 1. Why it is a hit (only while the item is one)
  if h then
    section("Warum Treffer")
    line("Kaufen", string.format("%dx bis %s  (zus. %s)", h.units, money(h.buyUpTo), money(h.cost)))
    line("Einstellen zu", money(h.sellAt) .. "  " .. Style.MUTED .. (h.sellSource or "") .. "|r")
    line("Obergrenze (Ø)", h.cap and money(h.cap) or "–")
    line("Erwarteter Gewinn", GREEN .. "+" .. money(h.profit) .. "|r  " .. Style.MUTED .. "nach 5 % Gebühr|r")
    if h.days then
      line("Verkauft in", "~" .. Detail.Days(h.days) .. " Tagen  " .. Style.MUTED .. string.format("(%s / Tag, %s)|r",
        Detail.Days(h.perDay), h.perDaySource or ""))
    end
    line("Treffer seit", ago(h.firstSeen or time()))
  end

  -- 2. History of the last 48 hours
  section("Preis 48 Stunden")
  if not chart then chart = createChart() end
  chart:ClearAllPoints()
  chart:SetPoint("TOPLEFT", body, "TOPLEFT", 4, -y)
  chart:SetPoint("RIGHT", body, "RIGHT", -4, 0)
  drawChart(chart, ns.Item.History(itemID), h and h.buyUpTo, h and h.sellAt)
  y = y + CHART_H + 44

  -- 3. Market figures (ns.Item)
  section("Markt")
  local fresh = live and live.itemID == itemID and live
  if fresh and fresh.state == "done" then
    local cheapest = fresh.offers[1]
    line("AH jetzt", cheapest and (money(cheapest.unit) .. "  " .. Style.MUTED .. "gerade gesucht|r")
      or (Style.MUTED .. "nicht im AH (gerade gesucht)|r"))
  elseif fresh and fresh.state == "searching" then
    line("AH jetzt", (item.now and (money(item.now) .. "  ") or "") .. Style.ACCENT .. "suche …|r")
  else
    line("AH jetzt", item.now and money(item.now) or (Style.MUTED .. "nicht im AH|r"))
  end
  line("Gestern (Tagespreis)", item.yesterday and money(item.yesterday) or "–")
  if item.min and item.max then
    line("Spanne 14 Tage", money(item.min) .. " – " .. money(item.max) .. (item.avg and ("  (Ø " .. money(item.avg) .. ")") or ""))
  end
  line("Trend", ns.Item.TrendText(item) or "–")
  local demand = ns.Item.DemandText(item)
  if demand and item.certain and item.certain >= 1 then
    demand = demand .. "  ·  mind. " .. count(item.certain) .. " / Tag verkauft"
  end
  line("Nachfrage", demand or "–")
  line("Im AH", string.format("%s Angebote  ·  %s Stück", count(item.offers), count(item.quantity)))

  -- 3b. What one unit cost the player (ns.Profit.UnitCost) and the room left to undercut.
  local cost, costSource = nil, nil
  if ns.Profit and ns.Profit.UnitCost then cost, costSource = ns.Profit.UnitCost(itemID) end
  section("Dein Einstand")
  if not cost then
    line("Einstand pro Stück", Style.MUTED .. "unbekannt|r")
    line("", Style.MUTED .. "kein Kauf, keine Herstellung im Handelsbuch, kein gelerntes Rezept|r")
  end
  if cost then
    line("Einstand pro Stück", money(math.floor(cost + 0.5)) .. "  " .. Style.MUTED .. costSource .. "|r")
    line("Ohne Verlust ab", money(ns.Profit.BreakEven(cost)) .. "  " .. Style.MUTED .. "nach 5 % Gebühr|r")
    local other
    if fresh and fresh.state == "done" then
      for _, o in ipairs(fresh.offers) do
        if not o.own then other = o.unit break end
      end
    else
      other = item.cheapest
    end
    if other then
      local room = math.floor((other - 1) * 0.95 - cost)
      line("Luft beim Unterbieten", room >= 0 and ("|cff5fd38d" .. money(room) .. "|r")
        or ("|cffff6b6b-" .. money(-room) .. " (unter Einstand)|r"))
    end
  end

  -- 4. Price stair: offers of the sniper's last search, else of the own full scan; left out
  -- without either. With a hit: bought levels green, the level sold under highlighted.
  -- The search started on opening wins: "suche …" while it runs, then "gerade gesucht".
  local levels, t, from
  if fresh and fresh.state == "done" then
    levels, t = fresh.offers, fresh.t
    from = time() - t < 60 and "gerade gesucht" or ("letzte Suche " .. ago(t))
  else
    levels, t = lastSearch(itemID)
    if levels then from = "letzte Suche " .. ago(t) end
  end
  local mark = h and levels -- hit markers only on the levels of a search
  if not levels then
    levels, t = scanLevels(itemID)
    from = levels and ("Scan " .. ago(t or time()))
  end
  if fresh and fresh.state == "searching" then
    from = "suche …" .. (from and ("  ·  " .. from) or "")
  elseif fresh and fresh.state == "failed" then
    from = "Suche ohne Antwort" .. (from and ("  ·  " .. from) or "")
  end
  if from then section("Preistreppe (" .. from .. ")") end
  if fresh and fresh.state == "searching" and not levels then
    line(Style.ACCENT .. "suche …|r", "")
  elseif levels and #levels == 0 then
    line("keine Angebote", "")
  elseif levels then
    local MAX = 9
    for i = 1, math.min(MAX, #levels) do
      local l = levels[i]
      local price, amount = money(l.unit), count(l.count) .. " Stück"
      if l.own then
        price = price .. Style.MUTED .. "  eigenes|r"
      elseif mark and l.unit <= h.buyUpTo then
        price, amount = GREEN .. price .. "  kaufen|r", GREEN .. amount .. "|r"
      elseif mark and l.unit == h.level then
        price = Style.ACCENT .. price .. "  einstellen knapp darunter|r"
      end
      line(price, amount)
    end
    if #levels > MAX then line(Style.MUTED .. string.format("+%d weitere Preisstufen", #levels - MAX) .. "|r", "") end
  end

  -- 5. Crafting (same recipe choice as the tooltip)
  local craft = ns.CraftInfo and ns.CraftInfo(itemID)
  if craft then
    section("Herstellung")
    line("Herstellkosten / Stück", money(math.floor(craft.cost + 0.5)))
    line("Rezept", craft.prof .. " · " .. craft.source)
  end

  for i = used + 1, #lines do lines[i].label:Hide(); lines[i].value:Hide() end
  for i = usedSections + 1, #sections do sections[i].text:Hide(); sections[i].rule:Hide() end
  body:SetSize(WIDTH - 26, math.max(1, y + 6))
  if scroll.UpdateBar then scroll.UpdateBar() end
end

-- Window ----------------------------------------------------------------------------

local FRAME_NAME = "M4CompanionItemDetail"

local function savePosition()
  local point, _, relPoint, x, yy = frame:GetPoint()
  if not (point and ns.db) then return end
  ns.db.itemDetail = ns.db.itemDetail or {}
  ns.db.itemDetail.pos = { point, relPoint, x, yy }
end

-- The AH panel to dock at: the Selling panel, else the auction house frame; nil when closed.
local function dockAnchor()
  local sell = ns.Selling and ns.Selling.Frame and ns.Selling.Frame()
  if sell and sell:IsShown() then return sell end
  local ah = AuctionHouseFrame
  if ah and ah.IsShown and ah:IsShown() then return ah end
end

-- Docks right of `anchor` (or the current AH panel), else places the own window.
place = function(anchor)
  anchor = anchor or dockAnchor()
  docked = anchor
  frame:ClearAllPoints()
  if anchor then
    frame:SetPoint("TOPLEFT", anchor, "TOPRIGHT", 4, 0)
    frame:SetPoint("BOTTOMLEFT", anchor, "BOTTOMRIGHT", 4, 0)
  else
    frame:SetHeight(FREE_HEIGHT)
    local pos = ns.db and ns.db.itemDetail and ns.db.itemDetail.pos
    if pos then
      frame:SetPoint(pos[1], UIParent, pos[2], pos[3], pos[4])
    else
      frame:SetPoint("CENTER", UIParent, "CENTER", 260, 40)
    end
  end
end

local function create()
  local Style = ns.Style
  frame = CreateFrame("Frame", FRAME_NAME, UIParent)
  frame:SetWidth(WIDTH)
  frame:SetFrameStrata("HIGH")
  frame:EnableMouse(true)
  frame:SetMovable(true)
  frame:SetClampedToScreen(true)
  Style.Panel(frame, 30)
  -- ESC closes the window (Blizzard's CloseSpecialWindows).
  if UISpecialFrames then tinsert(UISpecialFrames, FRAME_NAME) end
  frame:SetScript("OnHide", function() origin = nil end)
  local close = Style.Close(frame, function() Detail.Hide() end)
  close:SetPoint("TOPRIGHT", -4, -4)
  frame.close = close
  -- Head: icon and name, item tooltip on hover; dragging it moves the own window.
  local head = CreateFrame("Button", nil, frame)
  head:SetPoint("TOPLEFT", 6, -4)
  head:SetPoint("RIGHT", frame, "RIGHT", -32, 0)
  head:SetHeight(24)
  frame.icon = head:CreateTexture(nil, "ARTWORK")
  frame.icon:SetSize(20, 20)
  frame.icon:SetPoint("LEFT", 2, 0)
  frame.name = Style.Text(head, 14)
  frame.name:SetPoint("LEFT", frame.icon, "RIGHT", 6, 0)
  frame.name:SetPoint("RIGHT", head, "RIGHT", 0, 0)
  frame.name:SetJustifyH("LEFT")
  head:SetScript("OnEnter", function(self)
    if not itemID then return end
    GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
    GameTooltip:SetItemByID(itemID)
    GameTooltip:Show()
  end)
  head:SetScript("OnLeave", function() GameTooltip:Hide() end)
  head:RegisterForDrag("LeftButton")
  head:SetScript("OnDragStart", function()
    if not docked then frame:StartMoving() end
  end)
  head:SetScript("OnDragStop", function()
    frame:StopMovingOrSizing()
    if not docked then ns.Safe(savePosition) end
  end)
  frame.head = head
  scroll, body = Style.Scroll(frame)
  scroll:SetPoint("TOPLEFT", 8, -36)
  scroll:SetPoint("BOTTOMRIGHT", -14, 8)
  frame:Hide()
end

-- Item id from an id, an item link or an item string; nil otherwise.
local function toID(item)
  if type(item) == "number" then return item end
  if type(item) == "string" then return tonumber(item:match("item:(%d+)")) end
end

-- Opens the detail of the item (docked at the auction house or as a window of its own).
--   opts.anchor  dock right of this frame instead of the current AH panel
--   opts.origin  "sniper" when opened from the sniper list
-- Searches the item now when the auction house is open (ns.AHSearch); the answer re-renders.
local function searchLive(id)
  local AHSearch = ns.AHSearch
  if not (AHSearch and AHSearch.IsOpen and AHSearch.IsOpen()) then live = nil; return end
  if live and live.itemID == id and live.state == "searching" then return end
  local my = { itemID = id, state = "searching" }
  live = my
  local accepted = AHSearch.Request(id, function(offers)
    if live ~= my then return end
    my.state, my.offers, my.t = offers and "done" or "failed", offers, time()
    render()
  end, true)
  if not accepted and live == my then live = nil end
end

function Detail.Show(item, opts)
  local id = toID(item)
  if not id then return end
  opts = opts or {}
  if not frame then create() end
  itemID, origin = id, opts.origin
  place(opts.anchor)
  frame:Show()
  searchLive(id)
  render()
end

-- Click on a sniper hit: opens the detail next to `parent` (the Selling panel); a second click
-- on the same item closes it.
-- origin: the panel mode it was opened from ("sniper" default, "mine"); it closes when the
-- panel switches to another mode (Detail.HideSniper).
function Detail.Toggle(id, parent, from)
  if frame and frame:IsShown() and itemID == id then return Detail.Hide() end
  Detail.Show(id, { anchor = parent, origin = from or "sniper" })
end

function Detail.Hide()
  if frame then frame:Hide() end
  itemID, origin, live = nil, nil, nil
end

-- Closes the window only if it was opened from the sniper list (leaving the sniper mode).
-- Closes a window opened from a panel mode, unless that mode is `keep` (the current one).
-- Windows opened by Alt+click (no origin) stay.
function Detail.HideSniper(keep)
  if origin and origin ~= keep then Detail.Hide() end
end

function Detail.IsShown() return frame ~= nil and frame:IsShown() end
function Detail.ItemID() return frame and frame:IsShown() and itemID or nil end

function Detail.Refresh() render() end

-- Alt+left click without other modifiers.
function Detail.IsAltClick()
  return IsAltKeyDown and IsAltKeyDown() and not (IsShiftKeyDown and IsShiftKeyDown())
    and not (IsControlKeyDown and IsControlKeyDown()) or false
end

-- For the addon's item tables: opens the detail on Alt+click and returns true; returns false
-- otherwise, so the table keeps its normal click behaviour.
function Detail.AltClick(item)
  local id = toID(item)
  if not id or not Detail.IsAltClick() then return false end
  ns.Safe(Detail.Show, id)
  return true
end

-- /m4 item <link | name | id>: the item id, or nil and a message.
function Detail.Resolve(text)
  text = (text or ""):gsub("^%s+", ""):gsub("%s+$", "")
  if text == "" then return nil, "Item fehlt: /m4 item <Item-Link, Name oder ID>" end
  local id = toID(text) or tonumber(text)
  if id then return id end
  local getInfo = (C_Item and C_Item.GetItemInfo) or GetItemInfo
  local link = getInfo and select(2, getInfo(text))
  id = toID(link)
  if id then return id end
  -- Names the addon ships (Data_ItemNames.lua): exact first, else one unique partial match.
  local want = text:lower()
  local partial = {}
  for itemId, name in pairs(ns.ItemNames or {}) do
    local lower = name:lower()
    if lower == want then return itemId end
    if lower:find(want, 1, true) then table.insert(partial, itemId) end
  end
  if #partial == 1 then return partial[1] end
  if #partial > 1 then
    table.sort(partial, function(a, b) return ns.ItemNames[a] < ns.ItemNames[b] end)
    local names = {}
    for i = 1, math.min(5, #partial) do names[i] = ns.ItemNames[partial[i]] end
    return nil, string.format("%d Items passen zu „%s“: %s%s", #partial, text, table.concat(names, ", "),
      #partial > 5 and ", …" or "")
  end
  return nil, "Item nicht gefunden: " .. text
end

function Detail.Open(text)
  local id, err = Detail.Resolve(text)
  if id then return Detail.Show(id) end
  print("|cffffd100M4:|r " .. err)
end

-- Alt+left click on any item of the game UI (bags, bank, character, loot, chat links,
-- Blizzard's auction house lists): a post hook, the original keeps running untouched.
-- Both paths below can see the same click: open once.
local lastID, lastAt = nil, 0
local function openOnce(id)
  local now = GetTime and GetTime() or 0
  if id == lastID and now - lastAt < 0.5 then return end
  lastID, lastAt = id, now
  ns.Safe(Detail.Show, id)
end

if hooksecurefunc and HandleModifiedItemClick then
  hooksecurefunc("HandleModifiedItemClick", function(link)
    if type(link) ~= "string" or not Detail.IsAltClick() then return end
    local button = GetMouseButtonClicked and GetMouseButtonClicked()
    if button and button ~= "LeftButton" then return end
    local id = toID(link)
    if id then openOnce(id) end
  end)
end

-- Blizzard's auction house lists do not go through HandleModifiedItemClick. Every item the
-- game shows a tooltip for can be opened instead: Alt+left click while the game tooltip
-- shows an item (GLOBAL_MOUSE_DOWN only observes the click, nothing is intercepted).
function Detail.TooltipItem()
  if not (GameTooltip and GameTooltip:IsShown() and GameTooltip.GetItem) then return nil end
  local _, link = GameTooltip:GetItem()
  return toID(link)
end

if CreateFrame then
  local watcher = CreateFrame("Frame")
  if pcall(watcher.RegisterEvent, watcher, "GLOBAL_MOUSE_DOWN") then
    watcher:SetScript("OnEvent", function(_, _, button)
      if button ~= "LeftButton" or not Detail.IsAltClick() then return end
      local id = Detail.TooltipItem()
      if id then openOnce(id) end
    end)
  end
end

if ns.On then
  -- The auction house opens: an open own window docks at it (after the Selling panel exists).
  ns.On("AUCTION_HOUSE_SHOW", function()
    if not C_Timer then return end
    C_Timer.After(0.3, function()
      if frame and frame:IsShown() and not docked then ns.Safe(place); ns.Safe(render) end
    end)
  end)
  -- It closes: a docked window closes with it.
  ns.On("AUCTION_HOUSE_CLOSED", function()
    if docked then Detail.Hide() end
  end)
  -- The name arrives from the server after the window opened.
  ns.On("GET_ITEM_INFO_RECEIVED", function(_, id)
    if id == itemID then render() end
  end)
end
