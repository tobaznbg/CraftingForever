-- MainUI: the main m4-companion window (flat, dark, dense tables).
-- Header with emblem, data status and close; navigation on the left; pages on the
-- right, each created on first use:
--   overview     gold, profit, own professions, best recipes, market, open auctions, trades
--   professions  crafting table (AHTable embed) + button to the skill planner
--   market       sub tabs Trends / Anlage / Händler (AHTable embeds)
--   ledger       profit and loss per profession + recent trades
--   analysis     market analysis from the collector (ns.MarketAnalysis)
--   settings     switches in ns.db.settings
-- Position, scale and last page in ns.db.mainui. Parts built elsewhere (ns.Profit,
-- ns.MarketAnalysis, ns.AHTable.Embed) are optional: every page shows without them.
local ADDON, ns = ...

local MainUI = {}
ns.MainUI = MainUI

local Style = ns.Style

local WIDTH, HEIGHT = 1100, 680
local HEADER, SIDEBAR = 40, 170
local PAD, GAP = 14, 10
local PAGE_W = WIDTH - SIDEBAR - 2
local PAGE_H = HEIGHT - HEADER - 2
local INNER_W = PAGE_W - 2 * PAD
local TOOLBAR = 30
local ROW = 20
local TILE_H = 62
local CHART_DAYS = 30
local EMBLEM = "Interface\\AddOns\\m4-companion\\media\\emblem"
local FRAME_NAME = "M4CompanionMainFrame"

local GREEN, RED = "|cff5fd38d", "|cffff6b6b"
local CARD_BG = { 1, 1, 1, 0.025 }
local NO_ANALYSIS = "Analyse kommt mit den nächsten Daten"

local NAV = {
  { key = "overview", label = "Übersicht" },
  { key = "professions", label = "Berufe" },
  { key = "market", label = "Markt" },
  { key = "trends", label = "Trends", sub = true },
  { key = "invest", label = "Anlage", sub = true },
  { key = "vendor", label = "Händler", sub = true },
  { key = "ledger", label = "Handelsbuch" },
  { key = "analysis", label = "Analyse" },
  { key = "settings", label = "Einstellungen" },
}
local MARKET_SUBS = {
  { key = "trends", label = "Trends", table = "Trends" },
  { key = "invest", label = "Anlage", table = "Invest" },
  { key = "vendor", label = "Händler", table = "Vendor" },
}
local ALIASES = { handel = "ledger", berufe = "professions", markt = "market", analyse = "analysis" }

local KINDS = { buy = "Kauf", post = "Eingestellt", sale = "Verkauf", expired = "Abgelaufen", cancelled = "Abgebrochen", craft = "Hergestellt" }
-- Auction durations of the post hooks (1/2/3) in seconds.
local DURATIONS = { [1] = 12 * 3600, [2] = 24 * 3600, [3] = 48 * 3600 }

local TOOLTIP_LINES = {
  { "price", "Preis" }, { "range", "Preisspanne" }, { "trend", "Trend" },
  { "demand", "Nachfrage" }, { "crafting", "Crafting" }, { "advice", "Empfehlung" }, { "vendor", "Händlerpreis" },
}

local frame, statusText
local nav = {}
local pages = {}
local current
local marketSub = "trends"

-- Saved state --------------------------------------------------------------------

local function state()
  ns.db.mainui = ns.db.mainui or {}
  return ns.db.mainui
end

local function settings()
  ns.db.settings = ns.db.settings or {}
  local s = ns.db.settings
  s.tooltip = s.tooltip or {}
  if s.autoScan == nil then s.autoScan = true end   -- AuctionScan scans on AH open unless switched off
  for _, line in ipairs(TOOLTIP_LINES) do
    if s.tooltip[line[1]] == nil then s.tooltip[line[1]] = true end
  end
  return s
end

-- Formatting ---------------------------------------------------------------------

local function money(copper)
  return ns.FormatMoney(copper or 0, true)
end

local function signedMoney(copper)
  if type(copper) ~= "number" then return "–" end
  if copper > 0 then return GREEN .. "+" .. money(copper) .. "|r" end
  if copper < 0 then return RED .. money(copper) .. "|r" end
  return money(0)
end

local function pct(value, colored)
  if type(value) ~= "number" then return "–" end
  local text = string.format("%+.1f %%", value)
  if not colored or value == 0 then return text end
  return (value > 0 and GREEN or RED) .. text .. "|r"
end

local function startOfToday()
  local t = date("*t")
  t.hour, t.min, t.sec = 0, 0, 0
  return time(t)
end

-- Optional function of a module built elsewhere: its result, or nil if missing or failing.
local function optional(module, name, ...)
  local fn = type(module) == "table" and module[name]
  if type(fn) ~= "function" then return nil end
  local ok, result = ns.Safe(fn, ...)
  if ok then return result end
  return nil
end

local function analysis()
  local a = ns.MarketAnalysis
  if type(a) ~= "table" or type(a.summary) ~= "table" then return nil end
  return a
end

local function recipeName(professionID, recipeID)
  local data = ns.RecipeData and ns.RecipeData[professionID]
  local recipe = data and data.recipes and data.recipes[recipeID]
  return recipe and recipe[1], data and data.name
end

-- Widgets ------------------------------------------------------------------------

local function muted(fs)
  fs:SetTextColor(unpack(Style.C.muted))
  return fs
end

local function pageTitle(page, text)
  local t = Style.Text(page, 15)
  t:SetPoint("TOPLEFT", PAD, -PAD - 6)
  t:SetText(text)
  return t
end

-- Card: faint panel with a border and an optional title.
local function card(parent, w, h, title)
  local f = CreateFrame("Frame", nil, parent)
  f:SetSize(w, h)
  local bg = Style.Solid(f, CARD_BG)
  bg:SetAllPoints()
  Style.Border(f)
  if title then
    f.title = Style.Text(f, 12)
    f.title:SetPoint("TOPLEFT", 10, -8)
    f.title:SetText(Style.HEAD .. title .. "|r")
  end
  return f
end

-- Key figure: label, big value, small line under it.
local function tile(parent, w, label)
  local f = card(parent, w, TILE_H)
  f.label = Style.Text(f, 11)
  f.label:SetPoint("TOPLEFT", 10, -8)
  muted(f.label):SetText(label)
  f.value = Style.Text(f, 18)
  f.value:SetPoint("TOPLEFT", 10, -23)
  f.value:SetWidth(w - 20)
  f.value:SetJustifyH("LEFT")
  f.sub = muted(Style.Text(f, 11))
  f.sub:SetPoint("TOPLEFT", 10, -45)
  f.sub:SetWidth(w - 20)
  f.sub:SetJustifyH("LEFT")
  function f:Set(value, sub)
    self.value:SetText(value or "–")
    self.sub:SetText(sub or "")
  end
  return f
end

-- Table: header row and striped rows.
--   columns  { { title, width (0 = takes the rest), align }... }
--   opts     { scroll = true }
-- g:SetRows(list, emptyText): list of { cell texts..., color = {r,g,b} (first cell),
-- onClick = fn }.
local function grid(parent, w, h, columns, opts)
  opts = opts or {}
  local g = CreateFrame("Frame", nil, parent)
  g:SetSize(w, h)
  local inner = w - (opts.scroll and 10 or 0)
  local fixed = 0
  for _, c in ipairs(columns) do fixed = fixed + (c[2] or 0) end
  local xs, ws, x = {}, {}, 0
  for i, c in ipairs(columns) do
    local cw = (c[2] and c[2] > 0) and c[2] or math.max(40, inner - fixed)
    xs[i], ws[i] = x, cw
    x = x + cw
  end

  local head = Style.Solid(g, Style.C.header, "BACKGROUND", 1)
  head:SetPoint("TOPLEFT")
  head:SetPoint("TOPRIGHT")
  head:SetHeight(ROW)
  for i, c in ipairs(columns) do
    local t = muted(Style.Text(g, 11))
    t:SetPoint("TOPLEFT", xs[i] + 6, -5)
    t:SetWidth(ws[i] - 12)
    t:SetJustifyH(c[3] or "LEFT")
    t:SetText(c[1])
  end

  local body
  if opts.scroll then
    local scroll
    scroll, body = Style.Scroll(g)
    scroll:SetPoint("TOPLEFT", 0, -ROW)
    scroll:SetPoint("BOTTOMRIGHT", -10, 0)
    body:SetSize(inner, 1)
    g.scroll = scroll
  else
    body = CreateFrame("Frame", nil, g)
    body:SetPoint("TOPLEFT", 0, -ROW)
    body:SetSize(inner, math.max(1, h - ROW))
  end
  local empty = muted(Style.Text(g, 12))
  empty:SetPoint("TOPLEFT", 6, -(ROW + 6))

  local rows = {}
  local function rowAt(i)
    if rows[i] then return rows[i] end
    local r = CreateFrame("Button", nil, body)
    r:SetSize(inner, ROW)
    r:SetPoint("TOPLEFT", 0, -(i - 1) * ROW)
    r.stripe = Style.Solid(r, Style.C.row)
    r.stripe:SetAllPoints()
    r.stripe:SetShown(i % 2 == 0)
    r.hover = Style.Solid(r, Style.C.hover, "ARTWORK")
    r.hover:SetAllPoints()
    r.hover:Hide()
    r.cells = {}
    for c = 1, #columns do
      local t = Style.Text(r, 12)
      t:SetPoint("LEFT", xs[c] + 6, 0)
      t:SetWidth(ws[c] - 12)
      t:SetJustifyH(columns[c][3] or "LEFT")
      r.cells[c] = t
    end
    r:SetScript("OnEnter", function(self) if self.onClick then self.hover:Show() end end)
    r:SetScript("OnLeave", function(self) self.hover:Hide() end)
    r:SetScript("OnClick", function(self) if self.onClick then ns.Safe(self.onClick) end end)
    rows[i] = r
    return r
  end

  function g:SetRows(list, emptyText)
    for i, data in ipairs(list) do
      local r = rowAt(i)
      for c, cell in ipairs(r.cells) do
        cell:SetText(tostring(data[c] or ""))
        cell:SetTextColor(unpack(Style.C.text))
      end
      if data.color then r.cells[1]:SetTextColor(unpack(data.color)) end
      r.onClick = data.onClick
      r:Show()
    end
    for i = #list + 1, #rows do rows[i]:Hide() end
    empty:SetText(#list == 0 and (emptyText or "") or "")
    body:SetHeight(math.max(1, #list * ROW))
    if g.scroll then
      g.scroll:SetVerticalScroll(0)
      g.scroll.UpdateBar()
    end
  end
  return g
end

-- Label/value lines (e.g. market in short).
local function pairsList(parent, n, w)
  local list = { lines = {} }
  for i = 1, n do
    local label = muted(Style.Text(parent, 12))
    label:SetPoint("TOPLEFT", 10, -30 - (i - 1) * ROW)
    local value = Style.Text(parent, 12)
    value:SetPoint("TOPRIGHT", -10, -30 - (i - 1) * ROW)
    value:SetWidth(w - 150)
    value:SetJustifyH("RIGHT")
    list.lines[i] = { label = label, value = value }
  end
  function list:Set(items)
    for i, line in ipairs(self.lines) do
      local item = items[i]
      line.label:SetText(item and item[1] or "")
      line.value:SetText(item and item[2] or "")
    end
  end
  return list
end

-- Chart drawn with textures: kind "bars" or "line". c:SetData(values, opts) with
-- opts = { fmt = fn(value) -> text, first = label, last = label,
--          certain = { part of each bar that is certain (number) or false } }.
local function chart(parent, w, h, kind)
  local c = CreateFrame("Frame", nil, parent)
  c:SetSize(w, h)
  local LABEL = 14
  local plotH = h - 2 * LABEL
  local base = Style.Solid(c, Style.C.border, "BORDER")
  base:SetPoint("BOTTOMLEFT", 0, LABEL)
  base:SetPoint("BOTTOMRIGHT", 0, LABEL)
  base:SetHeight(1)
  c.maxLabel = muted(Style.Text(c, 10))
  c.maxLabel:SetPoint("TOPLEFT", 0, 0)
  c.lastLabel = Style.Text(c, 10)
  c.lastLabel:SetPoint("TOPRIGHT", 0, 0)
  c.firstDay = muted(Style.Text(c, 10))
  c.firstDay:SetPoint("BOTTOMLEFT", 0, 0)
  c.lastDay = muted(Style.Text(c, 10))
  c.lastDay:SetPoint("BOTTOMRIGHT", 0, 0)
  local pool = { back = {}, front = {}, lines = {}, dots = {} }

  local function texture(list, i, color, layer)
    if not list[i] then list[i] = Style.Solid(c, color, layer or "ARTWORK") end
    list[i]:Show()
    return list[i]
  end
  local function hideFrom(list, n)
    for i = n, #list do list[i]:Hide() end
  end

  function c:SetData(values, opts)
    opts = opts or {}
    local fmt = opts.fmt or tostring
    local n = #values
    local lo, hi = math.huge, -math.huge
    for _, v in ipairs(values) do lo, hi = math.min(lo, v), math.max(hi, v) end
    self.firstDay:SetText(opts.first or "")
    self.lastDay:SetText(opts.last or "")
    self.maxLabel:SetText(n > 0 and fmt(hi) or "")
    self.lastLabel:SetText(n > 0 and fmt(values[n]) or "")
    local accent = Style.C.accent
    if kind == "bars" then
      local gap = n > 40 and 1 or 2
      local bw = n > 0 and math.max(1, (w - gap * (n - 1)) / n) or 0
      local top = math.max(hi, 0)
      for i, v in ipairs(values) do
        local height = top > 0 and math.max(v > 0 and 1 or 0, v / top * plotH) or 0
        local x = (i - 1) * (bw + gap)
        local back = texture(pool.back, i, { accent[1], accent[2], accent[3], 0.35 })
        back:ClearAllPoints()
        back:SetPoint("BOTTOMLEFT", c, "BOTTOMLEFT", x, LABEL + 1)
        back:SetSize(bw, math.max(0.01, height))
        back:SetShown(height > 0)
        local certain = opts.certain and opts.certain[i]
        local share = 1
        if certain == false then share = 0
        elseif type(certain) == "number" and v > 0 then share = math.max(0, math.min(1, certain / v)) end
        local front = texture(pool.front, i, accent, "OVERLAY")
        front:ClearAllPoints()
        front:SetPoint("BOTTOMLEFT", c, "BOTTOMLEFT", x, LABEL + 1)
        front:SetSize(bw, math.max(0.01, height * share))
        front:SetShown(height * share > 0)
      end
      hideFrom(pool.back, n + 1)
      hideFrom(pool.front, n + 1)
    else
      if hi == lo then hi, lo = hi + 1, lo - 1 end
      local step = n > 1 and w / (n - 1) or 0
      local points = {}
      for i, v in ipairs(values) do
        points[i] = { (i - 1) * step, LABEL + 1 + (v - lo) / (hi - lo) * (plotH - 2) }
      end
      local lines = 0
      if c.CreateLine then
        for i = 2, n do
          lines = i - 1
          local line = pool.lines[lines]
          if not line then
            line = c:CreateLine(nil, "ARTWORK")
            line:SetThickness(2)
            line:SetColorTexture(unpack(accent))
            pool.lines[lines] = line
          end
          line:SetStartPoint("BOTTOMLEFT", c, points[i - 1][1], points[i - 1][2])
          line:SetEndPoint("BOTTOMLEFT", c, points[i][1], points[i][2])
          line:Show()
        end
      end
      hideFrom(pool.lines, lines + 1)
      for i, p in ipairs(points) do
        local dot = texture(pool.dots, i, accent, "OVERLAY")
        dot:ClearAllPoints()
        dot:SetSize(3, 3)
        dot:SetPoint("CENTER", c, "BOTTOMLEFT", p[1], p[2])
      end
      hideFrom(pool.dots, n + 1)
    end
  end
  return c
end

-- Flat toggle: square box (accent when on) and a label.
local function toggle(parent, label, get, set)
  local b = CreateFrame("Button", nil, parent)
  b:SetSize(360, 24)
  local box = CreateFrame("Frame", nil, b)
  box:SetSize(14, 14)
  box:SetPoint("LEFT", 0, 0)
  local boxBg = Style.Solid(box, Style.C.button)
  boxBg:SetAllPoints()
  Style.Border(box)
  local fill = Style.Solid(box, Style.C.accent, "ARTWORK")
  fill:SetPoint("TOPLEFT", 3, -3)
  fill:SetPoint("BOTTOMRIGHT", -3, 3)
  b.label = Style.Text(b, 12)
  b.label:SetPoint("LEFT", box, "RIGHT", 10, 0)
  b.label:SetText(label)
  function b:Update() fill:SetShown(get() and true or false) end
  b:SetScript("OnClick", function(self)
    set(not get())
    self:Update()
  end)
  b:SetScript("OnEnter", function() boxBg:SetColorTexture(unpack(Style.C.buttonHi)) end)
  b:SetScript("OnLeave", function() boxBg:SetColorTexture(unpack(Style.C.button)) end)
  b:Update()
  return b
end

local function setButtonActive(b, active)
  b.active = active
  b.bg:SetColorTexture(unpack(active and Style.C.buttonHi or Style.C.button))
  b.label:SetTextColor(unpack(active and Style.C.accent or Style.C.text))
end

-- Ledger data --------------------------------------------------------------------

local function ledgerEvents(n)
  return optional(ns.Ledger, "Recent", n) or {}
end

local function eventRow(e)
  local amount = "–"
  if e.k == "buy" then
    amount = RED .. "-" .. money(e.c) .. "|r"
  elseif e.k == "sale" then
    amount = GREEN .. "+" .. money((e.c or 0) - (e.cut or 0)) .. "|r"
  elseif e.k == "post" and e.p then
    amount = Style.MUTED .. money(e.p * (e.u or 1)) .. "|r"
  end
  local name = e.n or (e.i and ns.ItemName(e.i)) or "?"
  return { date("%d.%m. %H:%M", e.t or 0), KINDS[e.k] or tostring(e.k), name, tostring(e.u or 1), amount }
end

-- Auctions that are probably still running (rough): posts within their duration whose
-- units were not yet matched by a sale, expiry or cancel mail of the same item.
local function openAuctions()
  local all = optional(ns.Ledger, "Events")
  local events = {}
  if type(all) == "table" then
    for i = #all, 1, -1 do events[#events + 1] = all[i] end   -- newest first, like Recent
  else
    events = ledgerEvents(3000)
  end
  local now, since = time(), time() - DURATIONS[3] - 3600
  local queues, order = {}, {}
  for i = #events, 1, -1 do   -- oldest first
    local e = events[i]
    if (e.t or 0) >= since then
      local key = e.i or e.n
      if key then
        local q = queues[key]
        if not q then
          q = {}
          queues[key] = q
          table.insert(order, key)
        end
        if e.k == "post" then
          table.insert(q, { e = e, u = e.u or 1, ends = (e.t or now) + (DURATIONS[e.d] or DURATIONS[3]) })
        elseif e.k == "sale" or e.k == "expired" or e.k == "cancelled" then
          local units = e.u or 1
          while units > 0 and #q > 0 do
            local take = math.min(units, q[1].u)
            q[1].u, units = q[1].u - take, units - take
            if q[1].u <= 0 then table.remove(q, 1) end
          end
        end
      end
    end
  end
  local list, units, value = {}, 0, 0
  for _, key in ipairs(order) do
    for _, p in ipairs(queues[key]) do
      if p.u > 0 and p.ends > now then
        local worth = (p.e.p or 0) * p.u
        units, value = units + p.u, value + worth
        table.insert(list, { e = p.e, u = p.u, ends = p.ends, worth = worth })
      end
    end
  end
  table.sort(list, function(a, b) return a.ends < b.ends end)
  return list, units, value
end

-- Pages --------------------------------------------------------------------------

local PAGES = {}

-- Overview.
PAGES.overview = function(p)
  pageTitle(p, "Übersicht")
  local y = -(PAD + TOOLBAR + 6)
  local tw = (INNER_W - 3 * GAP) / 4
  local gold = tile(p, tw, "Gold")
  gold:SetPoint("TOPLEFT", PAD, y)
  local today = tile(p, tw, "Gewinn heute")
  today:SetPoint("TOPLEFT", gold, "TOPRIGHT", GAP, 0)
  local week = tile(p, tw, "Gewinn 7 Tage")
  week:SetPoint("TOPLEFT", today, "TOPRIGHT", GAP, 0)
  local stock = tile(p, tw, "Bestand (Wert)")
  stock:SetPoint("TOPLEFT", week, "TOPRIGHT", GAP, 0)

  y = y - TILE_H - GAP
  local colW = (INNER_W - GAP) / 2
  local avail = PAGE_H + y - PAD

  local profH, recipeH = 166, 112
  local profCard = card(p, colW, profH, "Deine Berufe")
  profCard:SetPoint("TOPLEFT", PAD, y)
  local profLines = {}
  for i = 1, 5 do
    local top = -30 - (i - 1) * 26
    local name = Style.Text(profCard, 12)
    name:SetPoint("TOPLEFT", 10, top)
    local rank = Style.Text(profCard, 12)
    rank:SetPoint("TOPRIGHT", -10, top)
    local track = Style.Solid(profCard, { 1, 1, 1, 0.06 }, "ARTWORK")
    track:SetPoint("TOPLEFT", 10, top - 15)
    track:SetSize(colW - 20, 3)
    local bar = Style.Solid(profCard, Style.C.accent, "OVERLAY")
    bar:SetPoint("TOPLEFT", track, "TOPLEFT")
    bar:SetHeight(3)
    profLines[i] = { name = name, rank = rank, track = track, bar = bar }
  end
  local profEmpty = muted(Style.Text(profCard, 12))
  profEmpty:SetPoint("TOPLEFT", 10, -30)

  local recipeCard = card(p, colW, recipeH, "Lohnt sich gerade")
  recipeCard:SetPoint("TOPLEFT", profCard, "BOTTOMLEFT", 0, -GAP)
  local recipes = grid(recipeCard, colW - 2, recipeH - 30, {
    { "Rezept", 0 }, { "Beruf", 110 }, { "Gewinn", 100, "RIGHT" } })
  recipes:SetPoint("TOPLEFT", 1, -29)

  local marketCard = card(p, colW, avail - profH - recipeH - 2 * GAP, "Markt")
  marketCard:SetPoint("TOPLEFT", recipeCard, "BOTTOMLEFT", 0, -GAP)
  local market = pairsList(marketCard, 4, colW)
  local marketEmpty = muted(Style.Text(marketCard, 12))
  marketEmpty:SetPoint("TOPLEFT", 10, -30)

  local openH = 200
  local openCard = card(p, colW, openH, "Offene Auktionen")
  openCard:SetPoint("TOPLEFT", PAD + colW + GAP, y)
  local openInfo = muted(Style.Text(openCard, 11))
  openInfo:SetPoint("TOPRIGHT", -10, -9)
  local open = grid(openCard, colW - 2, openH - 30, {
    { "Item", 0 }, { "Menge", 50, "RIGHT" }, { "Wert", 100, "RIGHT" }, { "Endet", 60, "RIGHT" } })
  open:SetPoint("TOPLEFT", 1, -29)

  local recentCard = card(p, colW, avail - openH - GAP, "Letzte Vorgänge")
  recentCard:SetPoint("TOPLEFT", openCard, "BOTTOMLEFT", 0, -GAP)
  local recent = grid(recentCard, colW - 2, avail - openH - GAP - 30, {
    { "Zeit", 82 }, { "Art", 76 }, { "Item", 0 }, { "Menge", 44, "RIGHT" }, { "Betrag", 92, "RIGHT" } })
  recent:SetPoint("TOPLEFT", 1, -29)

  function p:Refresh()
    gold:Set(money(GetMoney()))
    local dayTotals = optional(ns.Profit, "Totals", startOfToday())
    local weekTotals = optional(ns.Profit, "Totals", time() - 7 * 86400)
    local allTotals = optional(ns.Profit, "Totals", 0)
    today:Set(dayTotals and signedMoney(dayTotals.profit),
      dayTotals and ("Erlöse " .. money(dayTotals.revenue)) or "")
    week:Set(weekTotals and signedMoney(weekTotals.profit),
      weekTotals and ("Erlöse " .. money(weekTotals.revenue)) or "")
    stock:Set(allTotals and allTotals.stockValue and money(allTotals.stockValue) or "–")

    local char = ns.db.chars and ns.db.chars[ns.CharKey()]
    local profs = char and char.professions or {}
    for i, line in ipairs(profLines) do
      local prof = profs[i]
      line.name:SetText(prof and prof.name or "")
      line.rank:SetText(prof and string.format("%d / %d", prof.rank or 0, prof.max or 0) or "")
      line.track:SetShown(prof ~= nil)
      local share = prof and (prof.max or 0) > 0 and math.min(1, (prof.rank or 0) / prof.max) or 0
      line.bar:SetWidth(math.max(0.01, (colW - 20) * share))
      line.bar:SetShown(share > 0)
    end
    profEmpty:SetText(#profs == 0 and "Noch keine Berufe erfasst" or "")

    local best = {}
    local stats = ns.ProfessionStats and ns.ProfessionStats.professions or {}
    for pid, s in pairs(stats) do
      local name, profName = recipeName(pid, s[2])
      if name and (s[3] or 0) > 0 then
        table.insert(best, { name, profName or "", money(s[3]), profit = s[3],
          onClick = function() MainUI.Show("professions") end })
      end
    end
    table.sort(best, function(a, b) return a.profit > b.profit end)
    for i = #best, 4, -1 do best[i] = nil end
    recipes:SetRows(best, "Noch keine Berufsdaten")

    local a = analysis()
    if a then
      local s = a.summary
      market:Set({
        { "Umsatz 7 Tage", (s.turnover7d and money(s.turnover7d) or "–") .. "  " .. pct(s.turnoverChangePct, true) },
        { "Angebote", pct(s.offersChangePct) },
        { "Inflation", pct(s.inflationPct) },
        { "Top-Beruf", s.topProfession and s.topProfession.name or "–" },
      })
      marketEmpty:SetText("")
    else
      market:Set({})
      marketEmpty:SetText(NO_ANALYSIS)
    end

    local list, units, value = openAuctions()
    local rows = {}
    for i = 1, math.min(#list, 7) do
      local o = list[i]
      table.insert(rows, { o.e.n or (o.e.i and ns.ItemName(o.e.i)) or "?", tostring(o.u),
        o.worth > 0 and money(o.worth) or "–", date("%H:%M", o.ends) })
    end
    open:SetRows(rows, "Keine offenen Auktionen")
    openInfo:SetText(#list > 0 and string.format("%d Stück · %s", units, money(value)) or "")

    rows = {}
    for _, e in ipairs(ledgerEvents(8)) do table.insert(rows, eventRow(e)) end
    recent:SetRows(rows, "Noch keine Vorgänge")
  end
end

-- Embedded auction table in `holder`, created on first success.
local function embed(holder, id)
  if not holder.table then
    local t = optional(ns.AHTable, "Embed", id, holder, { detailAnchor = frame })
    if t then
      holder.table = t
      if t.GetNumPoints and t:GetNumPoints() == 0 then t:SetAllPoints(holder) end
      holder.missing:SetText("")
    else
      holder.missing:SetText("Tabelle nicht verfügbar")
    end
  end
  if holder.table then
    holder.table:Show()
    if holder.table.Refresh then ns.Safe(holder.table.Refresh, holder.table) end
  end
end

local function holderFrame(p)
  local h = CreateFrame("Frame", nil, p)
  h:SetPoint("TOPLEFT", PAD, -(PAD + TOOLBAR + 6))
  h:SetPoint("BOTTOMRIGHT", -PAD, PAD)
  h.missing = muted(Style.Text(h, 12))
  h.missing:SetPoint("TOPLEFT", 6, -6)
  return h
end

-- Professions.
PAGES.professions = function(p)
  pageTitle(p, "Berufe")
  local planner = Style.Button(p, "Skill-Planer", 100, 22, function()
    if ns.PlannerUI and ns.PlannerUI.Toggle then ns.Safe(ns.PlannerUI.Toggle) end
  end)
  planner:SetPoint("TOPRIGHT", -PAD, -PAD - 2)
  local holder = holderFrame(p)
  function p:Refresh() embed(holder, "Crafting") end
end

-- Market with sub tabs.
PAGES.market = function(p)
  local title = pageTitle(p, "Markt")
  local tabs, holders = {}, {}
  local anchor, offset = title, 24
  for _, sub in ipairs(MARKET_SUBS) do
    local tab = Style.Tab(p, sub.label, 84, function() MainUI.Show(sub.key) end)
    tab:SetPoint("LEFT", anchor, "RIGHT", offset, 0)
    anchor, offset = tab, 2
    tabs[sub.key] = tab
    holders[sub.key] = holderFrame(p)
  end
  function p:Refresh()
    for _, sub in ipairs(MARKET_SUBS) do
      local active = sub.key == marketSub
      tabs[sub.key]:SetActive(active)
      holders[sub.key]:SetShown(active)
      if active then embed(holders[sub.key], sub.table) end
    end
  end
end

-- Ledger: profit and loss per profession, recent trades.
local PERIODS = {
  { key = "today", label = "Heute", since = function() return startOfToday() end },
  { key = "week", label = "7 Tage", since = function() return time() - 7 * 86400 end },
  { key = "all", label = "Alles", since = function() return 0 end },
}

PAGES.ledger = function(p)
  pageTitle(p, "Handelsbuch")
  local buttons = {}
  local right = -PAD
  for i = #PERIODS, 1, -1 do
    local period = PERIODS[i]
    local b = Style.Button(p, period.label, 70, 22, function()
      state().period = period.key
      p:Refresh()
    end)
    b:SetScript("OnLeave", function(self)
      self.bg:SetColorTexture(unpack(self.active and Style.C.buttonHi or Style.C.button))
    end)
    b:SetPoint("TOPRIGHT", right, -PAD - 2)
    right = right - 74
    buttons[period.key] = b
  end

  local y = -(PAD + TOOLBAR + 6)
  local plH = 236
  local pl = grid(p, INNER_W, plH, {
    { "Beruf", 0 }, { "Erlöse (brutto)", 120, "RIGHT" }, { "Material", 120, "RIGHT" },
    { "Gebühren", 110, "RIGHT" }, { "Ergebnis", 120, "RIGHT" }, { "Bestand", 170, "RIGHT" } }, { scroll = true })
  pl:SetPoint("TOPLEFT", PAD, y)

  local label = Style.Text(p, 12)
  label:SetPoint("TOPLEFT", PAD, y - plH - 14)
  label:SetText(Style.HEAD .. "Letzte Vorgänge|r")
  local listTop = y - plH - 34
  local recent = grid(p, INNER_W, PAGE_H + listTop - PAD, {
    { "Datum", 110 }, { "Art", 100 }, { "Item", 0 }, { "Menge", 70, "RIGHT" }, { "Betrag", 140, "RIGHT" } },
    { scroll = true })
  recent:SetPoint("TOPLEFT", PAD, listTop)

  function p:Refresh()
    local key = state().period or "week"
    local since = 0
    for _, period in ipairs(PERIODS) do
      setButtonActive(buttons[period.key], period.key == key)
      if period.key == key then since = period.since() end
    end
    local list = optional(ns.Profit, "Professions", since)
    local rows = {}
    if type(list) == "table" then
      local sum = { revenue = 0, materials = 0, fees = 0, profit = 0, stockValue = 0, stockUnits = 0 }
      local sorted = {}
      for _, r in ipairs(list) do table.insert(sorted, r) end
      table.sort(sorted, function(a, b) return (a.profit or 0) > (b.profit or 0) end)
      for _, r in ipairs(sorted) do
        local fees = r.fees or 0   -- contains the AH cut and lost deposits
        for k in pairs(sum) do
          if k ~= "fees" then sum[k] = sum[k] + (r[k] or 0) end
        end
        sum.fees = sum.fees + fees
        table.insert(rows, { r.name or "?", money(r.revenue), money(r.materials), money(fees),
          signedMoney(r.profit or 0),
          (r.stockUnits or 0) > 0 and string.format("%s (%d)", money(r.stockValue), r.stockUnits) or "–" })
      end
      if #rows > 1 then
        table.insert(rows, { "Summe", money(sum.revenue), money(sum.materials), money(sum.fees),
          signedMoney(sum.profit), sum.stockUnits > 0 and money(sum.stockValue) or "–", color = Style.C.accent })
      end
      pl:SetRows(rows, "Keine Vorgänge im Zeitraum")
    else
      pl:SetRows(rows, "Gewinnrechnung noch nicht verfügbar")
    end

    rows = {}
    for _, e in ipairs(ledgerEvents(40)) do table.insert(rows, eventRow(e)) end
    recent:SetRows(rows, "Noch keine Vorgänge")
  end
end

-- Analysis of the market from the collector.
PAGES.analysis = function(p)
  pageTitle(p, "Analyse")
  local stamp = muted(Style.Text(p, 11))
  stamp:SetPoint("TOPRIGHT", -PAD, -PAD - 8)
  local none = muted(Style.Text(p, 13))
  none:SetPoint("CENTER", 0, 20)
  none:SetText(NO_ANALYSIS)

  local body = CreateFrame("Frame", nil, p)
  body:SetAllPoints()
  local y = -(PAD + TOOLBAR + 6)
  local tw = (INNER_W - 3 * GAP) / 4
  local turnover = tile(body, tw, "Umsatz 7 Tage")
  turnover:SetPoint("TOPLEFT", PAD, y)
  local offers = tile(body, tw, "Angebote")
  offers:SetPoint("TOPLEFT", turnover, "TOPRIGHT", GAP, 0)
  local inflation = tile(body, tw, "Inflation")
  inflation:SetPoint("TOPLEFT", offers, "TOPRIGHT", GAP, 0)
  local top = tile(body, tw, "Top-Beruf")
  top:SetPoint("TOPLEFT", inflation, "TOPRIGHT", GAP, 0)

  y = y - TILE_H - GAP
  local chartH = 168
  local cw = (INNER_W - 2 * GAP) / 3
  local charts = {}
  local defs = {
    { "Umsatz pro Tag", "bars", "turnover" },
    { "Preisindex", "line", "priceIndex" },
    { "Angebote pro Tag", "bars", "offers" },
  }
  for i, def in ipairs(defs) do
    local c = card(body, cw, chartH, def[1])
    c:SetPoint("TOPLEFT", PAD + (i - 1) * (cw + GAP), y)
    local drawing = chart(c, cw - 20, chartH - 40, def[2])
    drawing:SetPoint("TOPLEFT", 10, -30)
    charts[i] = { chart = drawing, field = def[3] }
  end

  y = y - chartH - GAP
  local listH = PAGE_H + y - PAD
  local colW = (INNER_W - GAP) / 2
  local recipeCard = card(body, colW, listH, "Top-Rezepte")
  recipeCard:SetPoint("TOPLEFT", PAD, y)
  local recipes = grid(recipeCard, colW - 2, listH - 30, {
    { "Rezept", 0 }, { "Beruf", 110 }, { "Gewinn", 96, "RIGHT" }, { "Nachfrage", 72, "RIGHT" } })
  recipes:SetPoint("TOPLEFT", 1, -29)

  local moverCard = card(body, colW, listH, "Gewinner und Verlierer")
  moverCard:SetPoint("TOPLEFT", PAD + colW + GAP, y)
  local half = (colW - 2 - GAP) / 2
  local up = grid(moverCard, half, listH - 30, { { "Steigt", 0 }, { "", 64, "RIGHT" } })
  up:SetPoint("TOPLEFT", 1, -29)
  local down = grid(moverCard, half, listH - 30, { { "Fällt", 0 }, { "", 64, "RIGHT" } })
  down:SetPoint("TOPLEFT", 1 + half + GAP, -29)

  local function moverRows(list)
    local rows = {}
    for i = 1, math.min(#(list or {}), 8) do
      local m = list[i]
      table.insert(rows, { m.itemId and ns.ItemName(m.itemId) or "?", pct(m.change and m.change * 100, true) })
    end
    return rows
  end

  function p:Refresh()
    local a = analysis()
    body:SetShown(a ~= nil)
    none:SetShown(a == nil)
    stamp:SetText(a and a.updated and ("Stand " .. tostring(a.updated)) or "")
    if not a then return end
    local s = a.summary
    turnover:Set(s.turnover7d and money(s.turnover7d) or "–", pct(s.turnoverChangePct, true) .. " zur Vorwoche")
    offers:Set(pct(s.offersChangePct), "")
    inflation:Set(pct(s.inflationPct), "")
    local tp = s.topProfession
    top:Set(tp and tp.name or "–", "")

    local days = {}
    for _, d in ipairs(a.days or {}) do table.insert(days, d) end
    table.sort(days, function(x, z) return tostring(x.day) < tostring(z.day) end)
    while #days > CHART_DAYS do table.remove(days, 1) end
    local first = days[1] and tostring(days[1].day or ""):sub(6) or ""
    local last = days[#days] and tostring(days[#days].day or ""):sub(6) or ""
    for _, c in ipairs(charts) do
      local values, certain = {}, {}
      for i, d in ipairs(days) do
        values[i] = tonumber(d[c.field]) or 0
        if c.field == "turnover" then
          if d.turnoverCertain == nil then certain[i] = true else certain[i] = d.turnoverCertain end
        end
      end
      local fmt = tostring
      if c.field == "turnover" then fmt = money
      elseif c.field == "priceIndex" then fmt = function(v) return string.format("%.1f", v) end
      elseif c.field == "offers" then fmt = function(v) return tostring(math.floor(v + 0.5)) end end
      c.chart:SetData(values, { fmt = fmt, first = first, last = last,
        certain = c.field == "turnover" and certain or nil })
    end

    local rows = {}
    for i = 1, math.min(#(s.topRecipes or {}), 5) do
      local r = s.topRecipes[i]
      local _, profName = recipeName(r.professionId, r.id)
      table.insert(rows, { r.name or recipeName(r.professionId, r.id) or "?", profName or "",
        r.profit and money(r.profit) or "–", r.demand and string.format("%.1f", r.demand) or "–" })
    end
    recipes:SetRows(rows, "Keine Rezepte")
    local movers = s.movers or {}
    up:SetRows(moverRows(movers.up), "–")
    down:SetRows(moverRows(movers.down), "–")
  end
end

-- Settings (saved in ns.db.settings, the minimap switch in ns.db.minimap.hide).
PAGES.settings = function(p)
  pageTitle(p, "Einstellungen")
  local toggles = {}
  local y = -(PAD + TOOLBAR + 10)
  local function section(text)
    local t = Style.Text(p, 12)
    t:SetPoint("TOPLEFT", PAD, y)
    t:SetText(Style.HEAD .. text .. "|r")
    y = y - 24
  end
  local function add(label, get, set)
    local t = toggle(p, label, get, set)
    t:SetPoint("TOPLEFT", PAD + 4, y)
    table.insert(toggles, t)
    y = y - 26
    return t
  end

  section("Allgemein")
  local reload = Style.Button(p, "Neu laden", 90, 20, function() ReloadUI() end)
  reload:Hide()
  local minimap = add("Minimap-Symbol anzeigen", function()
    return not (ns.db.minimap and ns.db.minimap.hide)
  end, function(on)
    ns.db.minimap = ns.db.minimap or {}
    ns.db.minimap.hide = not on
    reload:Show()
  end)
  reload:SetPoint("LEFT", minimap.label, "RIGHT", 14, 0)
  add("Auto-Vollscan beim Öffnen des Auktionshauses",
    function() return settings().autoScan end,
    function(on) settings().autoScan = on end)

  y = y - 10
  section("Tooltip")
  for _, line in ipairs(TOOLTIP_LINES) do
    add(line[2], function() return settings().tooltip[line[1]] end,
      function(on) settings().tooltip[line[1]] = on end)
  end

  y = y - 10
  section("Fenster")
  local scaleLabel = Style.Text(p, 12)
  local function changeScale(delta)
    local s = state()
    s.scale = math.max(0.6, math.min(1.4, (s.scale or 1) + delta))
    MainUI.ApplyScale()
    p:Refresh()
  end
  local minus = Style.Button(p, "–", 24, 20, function() changeScale(-0.05) end)
  minus:SetPoint("TOPLEFT", PAD + 4, y)
  scaleLabel:SetPoint("LEFT", minus, "RIGHT", 10, 0)
  scaleLabel:SetWidth(110)
  local plus = Style.Button(p, "+", 24, 20, function() changeScale(0.05) end)
  plus:SetPoint("LEFT", scaleLabel, "RIGHT", 10, 0)

  function p:Refresh()
    for _, t in ipairs(toggles) do t:Update() end
    scaleLabel:SetText(string.format("Größe %d %%", math.floor((state().scale or 1) * 100 + 0.5)))
  end
end

-- Window ---------------------------------------------------------------------------

local function updateStatus()
  if statusText and ns.Status and ns.Status.Text then
    local ok, text = ns.Safe(ns.Status.Text)
    statusText:SetText(ok and text or "")
  end
end

local function updateNav()
  for _, b in ipairs(nav) do
    local entry = b.entry
    local active
    if entry.sub then
      active = current == "market" and marketSub == entry.key
    else
      active = current == entry.key
    end
    b.active = active
    b.bar:SetShown(active)
    b.bg:SetShown(active)
    local open = entry.key == "market" and current == "market"
    b.label:SetTextColor(unpack((active or open) and Style.C.text or Style.C.muted))
  end
end

local function selectPage(key)
  current = key
  for k, page in pairs(pages) do page:SetShown(k == key) end
  local page = pages[key]
  if not page then
    page = CreateFrame("Frame", nil, frame.content)
    page:SetAllPoints()
    pages[key] = page
    PAGES[key](page)
  end
  page:Show()
  updateNav()
  if page.Refresh then ns.Safe(page.Refresh, page) end
end

-- Scale: the saved one, made smaller when the window would not fit on the screen.
function MainUI.ApplyScale()
  if not frame then return end
  local s = state().scale or 1
  local w, h = UIParent:GetWidth() or 0, UIParent:GetHeight() or 0
  if w > 0 then s = math.min(s, w / (WIDTH + 20)) end
  if h > 0 then s = math.min(s, h / (HEIGHT + 20)) end
  frame:SetScale(math.max(0.5, s))
end

local function createFrame()
  frame = CreateFrame("Frame", FRAME_NAME, UIParent)
  frame:SetSize(WIDTH, HEIGHT)
  frame:SetFrameStrata("HIGH")
  frame:SetToplevel(true)
  frame:SetClampedToScreen(true)
  frame:SetMovable(true)
  frame:EnableMouse(true)
  frame:RegisterForDrag("LeftButton")
  frame:SetScript("OnDragStart", frame.StartMoving)
  frame:SetScript("OnDragStop", function(self)
    self:StopMovingOrSizing()
    local point, _, relPoint, x, y = self:GetPoint()
    state().pos = { point, relPoint, x, y }
  end)
  frame:Hide()
  Style.Panel(frame, HEADER)
  tinsert(UISpecialFrames, FRAME_NAME)
  MainUI.ApplyScale()
  local pos = state().pos
  if pos then
    frame:SetPoint(pos[1], UIParent, pos[2], pos[3], pos[4])
  else
    frame:SetPoint("CENTER")
  end

  -- Header.
  local emblem = frame:CreateTexture(nil, "ARTWORK")
  emblem:SetSize(28, 28)
  emblem:SetPoint("TOPLEFT", 10, -6)
  emblem:SetTexture(EMBLEM)
  local brand = Style.Text(frame, 16)
  brand:SetPoint("LEFT", emblem, "RIGHT", 8, 0)
  brand:SetText(Style.ACCENT .. "m4|r-companion")
  local close = Style.Close(frame)
  close:SetPoint("TOPRIGHT", -8, -8)
  statusText = muted(Style.Text(frame, 12))
  statusText:SetPoint("RIGHT", close, "LEFT", -12, 0)
  statusText:SetJustifyH("RIGHT")

  -- Sidebar.
  local side = Style.Solid(frame, { 0, 0, 0, 0.2 }, "BACKGROUND", 1)
  side:SetPoint("TOPLEFT", 1, -(HEADER + 1))
  side:SetPoint("BOTTOMLEFT", 1, 1)
  side:SetWidth(SIDEBAR)
  local edge = Style.Solid(frame, Style.C.border, "BORDER")
  edge:SetPoint("TOPLEFT", side, "TOPRIGHT")
  edge:SetPoint("BOTTOMLEFT", side, "BOTTOMRIGHT")
  edge:SetWidth(1)
  local y = -(HEADER + 10)
  for _, entry in ipairs(NAV) do
    local h = entry.sub and 24 or 30
    local b = CreateFrame("Button", nil, frame)
    b:SetSize(SIDEBAR, h)
    b:SetPoint("TOPLEFT", 1, y)
    b.entry = entry
    b.bg = Style.Solid(b, Style.C.hover, "ARTWORK")
    b.bg:SetAllPoints()
    b.bar = Style.Solid(b, Style.C.accent, "OVERLAY")
    b.bar:SetPoint("TOPLEFT")
    b.bar:SetPoint("BOTTOMLEFT")
    b.bar:SetWidth(3)
    b.label = Style.Text(b, entry.sub and 12 or 13)
    b.label:SetPoint("LEFT", entry.sub and 30 or 16, 0)
    b.label:SetText(entry.label)
    b:SetScript("OnEnter", function(self) self.label:SetTextColor(unpack(Style.C.text)) end)
    b:SetScript("OnLeave", function() updateNav() end)
    b:SetScript("OnClick", function() MainUI.Show(entry.key) end)
    table.insert(nav, b)
    y = y - h
  end

  -- Page area.
  local content = CreateFrame("Frame", nil, frame)
  content:SetPoint("TOPLEFT", SIDEBAR + 2, -(HEADER + 1))
  content:SetPoint("BOTTOMRIGHT", -1, 1)
  frame.content = content

  -- Data status once a minute while open.
  local elapsed = 0
  frame:SetScript("OnUpdate", function(_, dt)
    elapsed = elapsed + dt
    if elapsed < 60 then return end
    elapsed = 0
    updateStatus()
  end)
  frame:SetScript("OnShow", function() elapsed = 0; updateStatus() end)
end

-- Opens the window on a page: overview, professions, market, trends, invest, vendor,
-- ledger, analysis, settings (default: the last one shown).
function MainUI.Show(page)
  if not ns.db then return end
  if not frame then createFrame() end
  page = ALIASES[page] or page or state().page or "overview"
  if not current and state().marketSub then marketSub = state().marketSub end   -- first open
  for _, sub in ipairs(MARKET_SUBS) do
    if sub.key == page then
      marketSub, page = page, "market"
    end
  end
  if not PAGES[page] then page = "overview" end
  state().page, state().marketSub = page, marketSub
  frame:Show()
  updateStatus()
  selectPage(page)
end

function MainUI.Toggle()
  if frame and frame:IsShown() then
    frame:Hide()
  else
    MainUI.Show()
  end
end

-- Redraws the visible page.
function MainUI.Refresh()
  if not (frame and frame:IsShown() and current and pages[current]) then return end
  local page = pages[current]
  if page.Refresh then ns.Safe(page.Refresh, page) end
end

-- Own pages follow new item names, money and mails (embedded tables refresh themselves).
local pending = false
local function refreshSoon()
  if pending or not (frame and frame:IsShown()) then return end
  if current ~= "overview" and current ~= "ledger" and current ~= "analysis" then return end
  pending = true
  C_Timer.After(0.5, function()
    pending = false
    MainUI.Refresh()
  end)
end
ns.On("GET_ITEM_INFO_RECEIVED", refreshSoon)
ns.On("PLAYER_MONEY", refreshSoon)
ns.On("MAIL_INBOX_UPDATE", refreshSoon)
ns.On("AUCTION_HOUSE_CLOSED", refreshSoon)
ns.On("DISPLAY_SIZE_CHANGED", function() MainUI.ApplyScale() end)
ns.On("UI_SCALE_CHANGED", function() MainUI.ApplyScale() end)
