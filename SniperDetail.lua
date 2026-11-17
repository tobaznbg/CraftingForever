-- SniperDetail: detail window for one item of the sniper list at the auction house,
-- docked right of the Selling panel (click on a hit row opens it, again or × closes it).
-- Shows why the offer is a hit (ns.Sniper hit + ns.Deals reference), the hourly price and
-- quantity of the last 48 hours (ns.Item.History), the item's market figures (ns.Item),
-- the offers of the sniper's last search (ns.Sniper.Listings) and the crafting cost
-- (ns.CraftInfo from Tooltip.lua). No own price logic here.
local ADDON, ns = ...

local Detail = {}
ns.SniperDetail = Detail

local WIDTH = 340
local LINE = 16
local CHART_H, SLOTS = 96, 48
local GREEN, ORANGE = "|cff5fd38d", "|cffffb547"

local frame, body, scroll, itemID
local lines, sections = {}, {}
local chart
local render -- forward declared: used by Toggle/Refresh, defined below

local function money(c) return ns.FormatMoney(c, true) end

local function ago(t)
  local s = math.max(0, time() - t)
  if s < 60 then return string.format("vor %d s", s) end
  if s < 3600 then return string.format("vor %d min", math.floor(s / 60)) end
  return string.format("vor %d h", math.floor(s / 3600))
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

local function findRow(id)
  local st = ns.Sniper.State()
  for _, e in ipairs(st.rows) do
    if e.itemID == id then return e end
  end
end

render = function()
  if not frame or not frame:IsShown() or not itemID then return end
  local Style = ns.Style
  local getIcon = (C_Item and C_Item.GetItemIconByID) or GetItemIcon
  frame.icon:SetTexture(getIcon and getIcon(itemID) or nil)
  frame.name:SetText(ns.ItemName(itemID) or ("#" .. itemID))
  y, used, usedSections = 0, 0, 0
  local row = findRow(itemID)
  local h = row and row.hit
  local item = ns.Item(itemID)

  -- 1. Why it is a hit
  section("Warum Treffer")
  if h then
    line("Kaufen", string.format("%dx bis %s  (zus. %s)", h.units, money(h.buyUpTo), money(h.cost)))
    line("Einstellen zu", money(h.sellAt) .. "  " .. Style.MUTED .. (h.sellSource or "") .. "|r")
    line("Obergrenze (Ø)", h.cap and money(h.cap) or "–")
    line("Erwarteter Gewinn", GREEN .. "+" .. money(h.profit) .. "|r  " .. Style.MUTED .. "nach 5 % Gebühr|r")
    if h.days then
      line("Verkauft in", "~" .. Detail.Days(h.days) .. " Tagen  " .. Style.MUTED .. string.format("(%s / Tag, %s)|r",
        Detail.Days(h.perDay), h.perDaySource or ""))
    end
    line("Treffer seit", ago(h.firstSeen or time()))
  else
    line("Kein Treffer (mehr)", row and row.price and money(row.price) or "")
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
  line("AH jetzt", item.now and money(item.now) or (Style.MUTED .. "nicht im AH|r"))
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

  -- 4. Price stair: offers of the sniper's last search; bought levels green, the level
  -- the units are sold under highlighted.
  local levels, t
  if ns.Sniper.Listings then levels, t = ns.Sniper.Listings(itemID) end
  section(levels and ("Preistreppe (letzte Suche " .. ago(t) .. ")") or "Preistreppe")
  if not levels or #levels == 0 then
    line(levels and "keine Angebote" or "noch nicht gesucht", "")
  else
    local MAX = 9
    for i = 1, math.min(MAX, #levels) do
      local l = levels[i]
      local price, amount = money(l.unit), count(l.count) .. " Stück"
      if l.own then
        price = price .. Style.MUTED .. "  eigenes|r"
      elseif h and l.unit <= h.buyUpTo then
        price, amount = GREEN .. price .. "  kaufen|r", GREEN .. amount .. "|r"
      elseif h and l.unit == h.level then
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

local function create(parent)
  local Style = ns.Style
  frame = CreateFrame("Frame", "M4CompanionSniperDetail", parent)
  frame:SetWidth(WIDTH)
  frame:SetPoint("TOPLEFT", parent, "TOPRIGHT", 4, 0)
  frame:SetPoint("BOTTOMLEFT", parent, "BOTTOMRIGHT", 4, 0)
  frame:SetFrameStrata("HIGH")
  frame:EnableMouse(true)
  Style.Panel(frame, 30)
  local close = Style.Close(frame, function() Detail.Hide() end)
  close:SetPoint("TOPRIGHT", -4, -4)
  frame.close = close
  -- Head: icon and name, item tooltip on hover.
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
  frame.head = head
  scroll, body = Style.Scroll(frame)
  scroll:SetPoint("TOPLEFT", 8, -36)
  scroll:SetPoint("BOTTOMRIGHT", -14, 8)
  frame:Hide()
end

-- Opens the detail of the item next to `parent` (the Selling panel); a second click on
-- the same item closes it.
function Detail.Toggle(id, parent)
  if not frame then create(parent) end
  if frame:IsShown() and itemID == id then return Detail.Hide() end
  itemID = id
  frame:Show()
  render()
end

function Detail.Hide()
  if frame then frame:Hide() end
  itemID = nil
end

function Detail.IsShown() return frame ~= nil and frame:IsShown() end
function Detail.ItemID() return frame and frame:IsShown() and itemID or nil end

function Detail.Refresh() render() end
