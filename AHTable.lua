-- AHTable: reusable item table, used as own tabs in the auction house frame and embedded
-- in other windows. Sortable columns, per-column filters, optional view buttons, two-line
-- rows and a "Suchen" button per row (only while the auction house is open).
--
-- A definition (ns.AHTable.Add) can be shown any number of times: every host (an AH tab,
-- ns.AHTable.Embed) gets its own instance with its own list, scroll position, sorting,
-- view and filter display; definition and saved filters are shared.
--
-- ns.AHTable.Embed(id, parent, opts) -> frame
--   Fills `parent` with a new instance of the table `id`. opts (all optional):
--     detailAnchor = frame whose right edge the detail panel docks to (default AuctionHouseFrame),
--     onTitle = function(text) (the table's title, e.g. after a chooser choice).
--   frame:Refresh() recomputes the list. Works without the auction house (never opened):
--   no search buttons, no live scan on open (onOpen only runs while the AH is open).
--
-- ns.AHTable.Add{
--   id, label, title,
--   columns = { {
--     key, title, width (0 = the name column, takes the rest), align ("LEFT"/"RIGHT"),
--     fmt = function(entry) -> text (default: tostring(entry[key])),
--     muted = true (grey text),
--     filter = "money" | "pct" | "num" (column can be filtered; money in gold, pct in %),
--     optional = true (dropped, right-most first, when the name column would get narrower
--                      than MIN_NAME in a narrow host, e.g. the auction house),
--   }... },
--   rows = function(view, choice) -> list of entries (each with itemID and the column keys),
--   chooser = function() -> { { key, label, icon, info, lines = { text... }, series = { n... } }... }
--             (optional first screen of big tiles, e.g. professions: icon, label, info line,
--             up to two more lines and a bar chart of `series`; the list shows after a
--             choice, "‹ Zurück" returns),
--   views = { { key, label, width }... } (optional buttons, the first is the default),
--   defaultFilters = { [key] = ">= 1" ... } (until the user sets own filters),
--   sort = key, desc = true,
--   rowColor = function(entry) -> { r, g, b } or nil (marker bar + faint tint),
--   subtitle = function(entry) -> text (second line under the name),
--   onOpen = function(t) (runs inside the tab click, i.e. with a hardware event; embedded
--            tables run it on show, only while the auction house is open),
--   info = function() -> short text left of the entry count (e.g. price basis),
--   detail = function(entry, count) -> { title, subtitle, columns = { { title, width }... },
--            rows = { { itemID, cells = { text... } }... },
--            summary = { { label, value }... } (single-line rows at the bottom), hint = text }
--            (click on a row opens it in a panel right of the host's detailAnchor; with
--            detailCount = true the panel has a -/+ count that is passed in; for AH tabs
--            the panel stays open while searching/buying in Blizzard's tabs, until its X
--            or the auction house closes; for embedded tables until the table hides),
-- }
--
-- Filters: one input per filterable column in a row under the header, shown with the
-- "Filter" button. "5" or ">=5" keeps entries with value >= 5, "<5" or "<=5" keeps
-- values <= 5; empty = no filter. Saved per table in ns.db.ahTable[id].filters.
--
-- The tabs work like LibAHTab (TSM, Auctionator): DisplayMode tab buttons after
-- Blizzard's tabs; selecting one clears the display mode and shows its frame, any
-- Blizzard display mode hides it again.
local ADDON, ns = ...

local AHTable = {}
ns.AHTable = AHTable

local ROW, HEADER, TOOLBAR, FILTER_ROW, FOOTER = 30, 22, 28, 24, 8
local CHART_BARS, CHART_H = 14, 22   -- chooser tiles: 14 days
local BUTTON_W = 64
local MAX_ROWS = 40
local MIN_NAME = 200  -- narrowest name column before optional columns are dropped
local SCALE = { money = 10000, pct = 0.01, num = 1 }

local defs = {}       -- definitions, in tab order
local byId = {}       -- id -> definition
local instances = {}  -- every shown table (AH tabs and embedded ones)
local ahTabs = {}     -- the instances that are AH tabs, in tab order
local created = false -- AH tabs built
local ahShown = false -- auction house currently open
local detail = { t = nil, entry = nil, count = 1 }   -- detail panel state (see below)
local showDetail      -- defined with the detail panel below, used by row clicks
local layoutColumns   -- defined with the frame, used when the AH opens/closes

-- True while the auction house is open (AUCTION_HOUSE_SHOW .. AUCTION_HOUSE_CLOSED).
local function ahOpen() return ahShown end

-- Title of the host: the AH frame for AH tabs, opts.onTitle for embedded tables.
local function setTitle(t, text)
  if t.isAHTab then
    local f = AuctionHouseFrame
    if f and f.SetTitle then f:SetTitle(text) end
  elseif t.onTitle then
    ns.Safe(t.onTitle, text)
  end
end

local function settings(t)
  if not ns.db then
    -- SavedVariables not loaded yet: defaults, not saved.
    local s = { filters = {} }
    for key, text in pairs(t.defaultFilters or {}) do s.filters[key] = text end
    return s
  end
  ns.db.ahTable = ns.db.ahTable or {}
  local s = ns.db.ahTable[t.id]
  if not s or not s.filters then
    s = { filters = {} }
    for key, text in pairs(t.defaultFilters or {}) do s.filters[key] = text end
    ns.db.ahTable[t.id] = s
  end
  return s
end

-- "5", ">=5", "> 5" -> ">=", 5;  "<5", "<=5" -> "<=", 5;  "" -> nil
local function parseFilter(text)
  if not text then return nil end
  local op, num = text:match("^%s*([<>]?)=?%s*(-?[%d%.,]+)%s*$")
  if not num then return nil end
  num = tonumber((num:gsub(",", ".")))
  if not num then return nil end
  return op == "<" and "<=" or ">=", num
end

local function passes(t, e)
  local filters = settings(t).filters
  for _, c in ipairs(t.columns) do
    if c.filter then
      local op, num = parseFilter(filters[c.key])
      if op then
        local v = e[c.key]
        if v == nil then return false end
        local limit = num * SCALE[c.filter]
        if op == ">=" and v < limit then return false end
        if op == "<=" and v > limit then return false end
      end
    end
  end
  return true
end

local function activeFilters(t)
  local n, filters = 0, settings(t).filters
  for _, c in ipairs(t.columns) do
    if c.filter and parseFilter(filters[c.key]) then n = n + 1 end
  end
  return n
end

-- Switches to Blizzard's buy tab and searches the item there (only with the AH open).
local function search(itemID)
  if not ahOpen() then return end
  if AuctionHouseFrame and AuctionHouseFrameDisplayMode then
    AuctionHouseFrame:SetDisplayMode(AuctionHouseFrameDisplayMode.Buy)
  end
  C_Timer.After(0.1, function() ns.Safe(ns.Deals.Search, itemID) end)
end

local function sortList(t)
  local key, desc = t.sortKey, t.sortDesc
  table.sort(t.list, function(a, b)
    local x, y = a[key], b[key]
    if type(x) == "string" or type(y) == "string" then
      x, y = tostring(x or ""):lower(), tostring(y or ""):lower()
    else
      x, y = x or 0, y or 0
    end
    if x == y then return a.itemID < b.itemID end
    if desc then return x > y end
    return x < y
  end)
end

local function build(t)
  local kept = {}
  local source = (t.chooser and not t.choice) and {} or (t.rows(t.view, t.choice) or {})
  for _, e in ipairs(source) do
    e.name = ns.ItemName(e.itemID) or ("#" .. e.itemID)
    if passes(t, e) then table.insert(kept, e) end
  end
  t.list = kept
  sortList(t)
end

local function topOffset(t)
  return 1 + TOOLBAR + (t.showFilters and FILTER_ROW or 0)
end

local function layoutRows(t)
  local y0 = topOffset(t) + HEADER
  for i, r in ipairs(t.rowFrames) do
    r:ClearAllPoints()
    r:SetPoint("TOPLEFT", 1, -y0 - (i - 1) * ROW)
    r:SetPoint("TOPRIGHT", -1, -y0 - (i - 1) * ROW)
  end
  t.head:ClearAllPoints()
  t.head:SetPoint("TOPLEFT", 1, -(1 + TOOLBAR))
  t.head:SetPoint("TOPRIGHT", -1, -(1 + TOOLBAR))
  t.filterRow:SetShown(t.showFilters and true or false)
end

-- Chooser screen or list, depending on whether a choice is made.
local function showMode(t)
  if not t.chooser then return false end
  local choosing = t.choice == nil
  t.choosePanel:SetShown(choosing)
  t.head:SetShown(not choosing)
  t.filterRow:SetShown(not choosing and t.showFilters and true or false)
  t.filterButton:SetShown(not choosing)
  t.countText:SetShown(not choosing)
  if t.backButton then t.backButton:SetShown(not choosing) end
  for _, b in pairs(t.viewButtons or {}) do b:SetShown(not choosing) end
  if choosing then
    for _, r in ipairs(t.rowFrames) do r:Hide() end
    local items = t.chooser() or {}
    for i, b in ipairs(t.chooseButtons) do
      local c = items[i]
      b.choice = c
      if c then
        b.icon:SetTexture(c.icon)
        b.label:SetText(c.label)
        b.info:SetText(c.info or "")
        for j, fs in ipairs(b.lines) do fs:SetText(c.lines and c.lines[j] or "") end
        -- Bar chart: one bar per value, scaled to the largest, newest right.
        local series, maxV = c.series or {}, 0
        for _, v in ipairs(series) do maxV = math.max(maxV, v or 0) end
        for j, bar in ipairs(b.bars) do
          local v = series[#series - #b.bars + j]
          if v and maxV > 0 then
            bar:SetHeight(math.max(2, CHART_H * v / maxV))
            bar:Show()
          else
            bar:Hide()
          end
        end
        b.chartBase:SetShown(#series > 0)
        b:Show()
      else
        b:Hide()
      end
    end
  end
  return choosing
end

local function refresh(t)
  local f = t.frame
  if not f or not f:IsShown() then return end
  if t.searchShown ~= ahOpen() then layoutColumns(t) end
  if showMode(t) then return end
  local n = math.max(1, math.min(MAX_ROWS, math.floor((f:GetHeight() - topOffset(t) - HEADER - FOOTER) / ROW)))
  t.offset = math.max(0, math.min(t.offset, #t.list - n))
  for i, r in ipairs(t.rowFrames) do
    local e = i <= n and t.list[t.offset + i] or nil
    r.entry = e
    if e then
      local mark = t.rowColor and t.rowColor(e)
      r.tint:SetShown(mark ~= nil)
      r.bar:SetShown(mark ~= nil)
      if mark then
        r.tint:SetColorTexture(mark[1], mark[2], mark[3], 0.08)
        r.bar:SetColorTexture(mark[1], mark[2], mark[3], 1)
      end
      r.icon:SetTexture(((C_Item and C_Item.GetItemIconByID) or GetItemIcon)(e.itemID))
      e.name = ns.ItemName(e.itemID) or e.name
      for _, c in ipairs(t.columns) do
        r.cells[c.key]:SetText(c.fmt and c.fmt(e) or tostring(e[c.key] or ""))
      end
      if r.sub then r.sub:SetText(t.subtitle(e) or "") end
      r:Show()
    else
      r:Hide()
    end
  end
  for _, h in ipairs(t.headers) do
    h.label:SetTextColor(unpack(h.key == t.sortKey and ns.Style.C.accent or ns.Style.C.muted))
  end
  for key, b in pairs(t.viewButtons or {}) do b:SetActive(key == t.view) end
  local active = activeFilters(t)
  t.filterButton.label:SetText(active > 0 and string.format("Filter (%d)", active) or "Filter")
  local info = t.info and t.info() or (ns.Status and ns.Status.Text()) or nil
  t.countText:SetText((info and (info .. "   ·   ") or "") .. string.format("%d Einträge", #t.list))
end

-- Places the cells of header, filter row and rows: fixed columns right-aligned before the
-- search button (only while the AH is open), the name column takes the rest. Optional
-- columns are dropped (right-most first) while the name column would be too narrow.
function layoutColumns(t)
  local showSearch = ahOpen()
  t.searchShown = showSearch
  local right = showSearch and (BUTTON_W + 16) or 8
  local width = t.frame and t.frame:GetWidth() or 0
  local visible, fixed = {}, right
  for i = 2, #t.columns do
    visible[i] = true
    fixed = fixed + t.columns[i].width
  end
  if width > 0 then
    for i = #t.columns, 2, -1 do
      if width - 34 - fixed >= MIN_NAME then break end
      if t.columns[i].optional then
        visible[i] = false
        fixed = fixed - t.columns[i].width
      end
    end
  end
  for _, set in ipairs(t.cellSets or {}) do
    local x = 0
    for i = 2, #t.columns do
      local cell = set.cells[i]
      if visible[i] then x = x + t.columns[i].width end
      if cell then
        cell:SetShown(visible[i])
        if visible[i] then
          cell:ClearAllPoints()
          cell:SetPoint("RIGHT", set.row, "RIGHT", -(fixed - x), 0)
          cell:SetWidth(t.columns[i].width - 8)
        end
      end
    end
    local name = set.cells[1]
    if name then
      local y = set.twoLines and 7 or 0
      name:ClearAllPoints()
      name:SetPoint("LEFT", set.row, "LEFT", 34, y)
      name:SetPoint("RIGHT", set.row, "RIGHT", -fixed, y)
    end
  end
  for _, r in ipairs(t.rowFrames or {}) do
    if r.searchButton then r.searchButton:SetShown(showSearch) end
  end
end

-- parent: the AH frame (tab, fixed insets) or any frame (embedded, filled completely).
local function createFrame(t, parent, embedded)
  local Style = ns.Style
  local f = CreateFrame("Frame", nil, parent)
  t.frame = f
  if embedded then
    f:SetAllPoints(parent)
    f:SetFrameLevel(parent:GetFrameLevel() + 1)
  else
    f:SetPoint("TOPLEFT", parent, "TOPLEFT", 8, -60)
    f:SetPoint("BOTTOMRIGHT", parent, "BOTTOMRIGHT", -8, 28)
    f:SetFrameLevel(parent:GetFrameLevel() + 20)
  end
  Style.Solid(f, Style.C.bg):SetAllPoints()
  Style.Border(f)

  -- Toolbar: back button (with a chooser) and view buttons left, count and filter right.
  local x0 = 8
  if t.chooser then
    t.backButton = Style.Button(f, "‹ Zurück", 80, 20, function()
      t.choice, t.offset = nil, 0
      setTitle(t, t.title)
      refresh(t)
    end)
    t.backButton:SetPoint("TOPLEFT", 8, -5)
    x0 = 96
  end
  if t.views then
    t.viewButtons = {}
    local x = x0
    for _, v in ipairs(t.views) do
      local b = Style.Tab(f, v[2], v[3] or 90, function()
        t.view, t.offset = v[1], 0
        build(t)
        refresh(t)
      end)
      b:SetPoint("TOPLEFT", x, -2)
      t.viewButtons[v[1]] = b
      x = x + (v[3] or 90) + 4
    end
  end
  t.filterButton = Style.Button(f, "Filter", 80, 20, function()
    t.showFilters = not t.showFilters
    layoutRows(t)
    refresh(t)
  end)
  t.filterButton:SetPoint("TOPRIGHT", -8, -5)
  t.countText = Style.Text(f, 11)
  t.countText:SetPoint("RIGHT", t.filterButton, "LEFT", -10, 0)
  t.countText:SetTextColor(unpack(Style.C.muted))

  -- Column layout: cells are collected per row and placed by layoutColumns.
  t.cellSets = {}
  local function place(row, makeCell, twoLines)
    local set = { row = row, cells = {}, twoLines = twoLines }
    for i, c in ipairs(t.columns) do set.cells[i] = makeCell(c) end
    table.insert(t.cellSets, set)
  end

  local head = CreateFrame("Frame", nil, f)
  t.head = head
  head:SetHeight(HEADER)
  Style.Solid(head, Style.C.header):SetAllPoints()
  t.headers = {}
  place(head, function(c)
    local b = CreateFrame("Button", nil, head)
    b:SetHeight(HEADER)
    b.label = Style.Text(b, 12)
    b.label:SetAllPoints()
    b.label:SetJustifyH(c.align or "RIGHT")
    b.label:SetText(c.title)
    b.key = c.key
    b:SetScript("OnClick", function(self)
      if t.sortKey == self.key then t.sortDesc = not t.sortDesc
      else t.sortKey, t.sortDesc = self.key, self.key ~= "name" end
      sortList(t)
      refresh(t)
    end)
    table.insert(t.headers, b)
    return b
  end)

  -- Filter row: an input under every filterable column.
  local fr = CreateFrame("Frame", nil, f)
  t.filterRow = fr
  fr:SetPoint("TOPLEFT", head, "BOTTOMLEFT", 0, 0)
  fr:SetPoint("TOPRIGHT", head, "BOTTOMRIGHT", 0, 0)
  fr:SetHeight(FILTER_ROW)
  Style.Solid(fr, { 1, 1, 1, 0.04 }):SetAllPoints()
  local hint = Style.Text(fr, 11)
  hint:SetPoint("LEFT", 34, 0)
  hint:SetTextColor(unpack(Style.C.muted))
  hint:SetText("5 = mindestens 5,  <5 = höchstens 5  (Preise in Gold, Prozent in %)")
  t.inputs = {}
  place(fr, function(c)
    if not c.filter then return nil end
    local box = CreateFrame("EditBox", nil, fr)
    box:SetHeight(18)
    box:SetAutoFocus(false)
    box:SetFontObject(Style.Font(12))
    box:SetJustifyH("RIGHT")
    box:SetTextInsets(4, 4, 0, 0)
    Style.Solid(box, Style.C.button):SetAllPoints()
    Style.Border(box)
    box:SetText(settings(t).filters[c.key] or "")
    local function apply(self)
      local text = self:GetText()
      settings(t).filters[c.key] = (text ~= "" and text) or nil
      if text ~= "" and not parseFilter(text) then self:SetTextColor(1, 0.42, 0.42) else self:SetTextColor(1, 1, 1) end
      t.offset = 0
      build(t)
      refresh(t)
    end
    box:SetScript("OnEnterPressed", function(self) apply(self); self:ClearFocus() end)
    box:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)
    box:SetScript("OnEditFocusLost", apply)
    t.inputs[c.key] = box
    return box
  end)
  fr:Hide()

  t.rowFrames = {}
  for i = 1, MAX_ROWS do
    local r = CreateFrame("Frame", nil, f)
    r:SetHeight(ROW)
    local stripe = Style.Solid(r, Style.C.row)
    stripe:SetAllPoints()
    stripe:SetShown(i % 2 == 0)
    r.tint = Style.Solid(r, { 0, 0, 0, 0 }, "BACKGROUND", 1)
    r.tint:SetAllPoints()
    r.tint:Hide()
    r.bar = Style.Solid(r, { 0, 0, 0, 0 }, "ARTWORK")
    r.bar:SetPoint("TOPLEFT")
    r.bar:SetPoint("BOTTOMLEFT")
    r.bar:SetWidth(3)
    r.bar:Hide()
    local hover = Style.Solid(r, Style.C.hover, "ARTWORK")
    hover:SetAllPoints()
    hover:Hide()
    r.icon = r:CreateTexture(nil, "ARTWORK")
    r.icon:SetSize(22, 22)
    r.icon:SetPoint("LEFT", 8, 0)
    r.cells = {}
    place(r, function(c)
      local fs = Style.Text(r, 12)
      fs:SetJustifyH(c.align or "RIGHT")
      if c.muted then fs:SetTextColor(unpack(Style.C.muted)) end
      r.cells[c.key] = fs
      return fs
    end, t.subtitle ~= nil)
    if t.subtitle then
      r.sub = Style.Text(r, 11)
      r.sub:SetPoint("LEFT", r, "LEFT", 34, -7)
      r.sub:SetPoint("RIGHT", r.cells.name, "RIGHT", 0, 0)
      r.sub:SetJustifyH("LEFT")
      r.sub:SetTextColor(unpack(Style.C.muted))
    end
    local b = Style.Button(r, "Suchen", BUTTON_W, 18, function()
      if r.entry then search(r.entry.itemID) end
    end, Style.C.accent)
    b:SetPoint("RIGHT", -8, 0)
    r.searchButton = b
    r:EnableMouse(true)
    r:SetScript("OnEnter", function(self)
      hover:Show()
      if not self.entry then return end
      GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
      GameTooltip:SetItemByID(self.entry.itemID)
      GameTooltip:Show()
    end)
    r:SetScript("OnLeave", function() hover:Hide(); GameTooltip:Hide() end)
    if t.detail then
      r:SetScript("OnMouseUp", function(self, button)
        if button == "LeftButton" and self.entry then ns.Safe(showDetail, t, self.entry) end
      end)
    end
    t.rowFrames[i] = r
  end
  layoutRows(t)

  f:EnableMouseWheel(true)
  f:SetScript("OnMouseWheel", function(_, delta)
    t.offset = t.offset - delta * 3
    refresh(t)
  end)
  -- Chooser screen: a grid of big buttons with icon, label and info line.
  if t.chooser then
    local panel = CreateFrame("Frame", nil, f)
    t.choosePanel = panel
    panel:SetPoint("TOPLEFT", 1, -(1 + TOOLBAR))
    panel:SetPoint("BOTTOMRIGHT", -1, 1)
    t.chooseButtons = {}
    local W, H, COLS = 230, 128, 3
    for i = 1, 12 do
      local b = CreateFrame("Button", nil, panel)
      b:SetSize(W, H)
      b:SetPoint("TOPLEFT", 16 + ((i - 1) % COLS) * (W + 12), -12 - math.floor((i - 1) / COLS) * (H + 12))
      Style.Solid(b, Style.C.button):SetAllPoints()
      Style.Border(b)
      local hover = Style.Solid(b, Style.C.hover, "ARTWORK")
      hover:SetAllPoints()
      hover:Hide()
      b.icon = b:CreateTexture(nil, "OVERLAY")
      b.icon:SetSize(40, 40)
      b.icon:SetPoint("TOPLEFT", 10, -10)
      b.label = Style.Text(b, 14)
      b.label:SetPoint("TOPLEFT", b.icon, "TOPRIGHT", 10, -3)
      b.label:SetPoint("RIGHT", -8, 0)
      b.label:SetJustifyH("LEFT")
      b.info = Style.Text(b, 11)
      b.info:SetPoint("BOTTOMLEFT", b.icon, "BOTTOMRIGHT", 10, 3)
      b.info:SetPoint("RIGHT", -8, 0)
      b.info:SetJustifyH("LEFT")
      b.info:SetTextColor(unpack(Style.C.muted))
      b.lines = {}
      for j = 1, 2 do
        local fs = Style.Text(b, 11)
        fs:SetPoint("TOPLEFT", b.icon, "BOTTOMLEFT", 0, -6 - (j - 1) * 14)
        fs:SetPoint("RIGHT", -8, 0)
        fs:SetJustifyH("LEFT")
        b.lines[j] = fs
      end
      -- Bar chart along the bottom edge.
      b.chartBase = Style.Solid(b, Style.C.border, "ARTWORK")
      b.chartBase:SetHeight(1)
      b.chartBase:SetPoint("BOTTOMLEFT", 10, 8)
      b.chartBase:SetPoint("BOTTOMRIGHT", -10, 8)
      b.bars = {}
      local barW = math.floor((W - 20) / CHART_BARS) - 2
      for j = 1, CHART_BARS do
        local bar = Style.Solid(b, Style.C.accent, "ARTWORK")
        bar:SetWidth(barW)
        bar:SetPoint("BOTTOMLEFT", 10 + (j - 1) * (barW + 2), 9)
        bar:Hide()
        b.bars[j] = bar
      end
      b:SetScript("OnEnter", function() hover:Show() end)
      b:SetScript("OnLeave", function() hover:Hide() end)
      b:SetScript("OnClick", function(self)
        if not self.choice then return end
        t.choice, t.offset = self.choice.key, 0
        setTitle(t, t.title .. " – " .. self.choice.label)
        build(t)
        refresh(t)
      end)
      b:Hide()
      t.chooseButtons[i] = b
    end
    panel:Hide()
  end

  layoutColumns(t)
  f:SetScript("OnShow", function()
    layoutColumns(t)
    build(t)
    refresh(t)
    -- Embedded: the live scan only makes sense (and only works) with the AH open.
    if embedded and t.onOpen and ahOpen() then ns.Safe(t.onOpen, t) end
  end)
  f:SetScript("OnSizeChanged", function() layoutColumns(t); refresh(t) end)
  if embedded then
    -- The detail panel belongs to the visible table.
    f:SetScript("OnHide", function() if detail.t == t then AHTable.HideDetail() end end)
  end
  f:Hide()
end

-- Detail panel -------------------------------------------------------------------------

local DETAIL_W, DETAIL_ROWS, DETAIL_ROW = 460, 10, 26
local SUMMARY_ROWS, SUMMARY_ROW = 8, 18

local function renderDetail()
  local d, t = detail, detail.t
  if not d.frame or not d.frame:IsShown() or not t then return end
  local info = t.detail(d.entry, d.count) or {}
  d.title:SetText(info.title or "")
  d.sub:SetText(info.subtitle or "")
  d.countBox:SetShown(t.detailCount and true or false)
  d.countLabel:SetText(t.detailCount and tostring(d.count) or "")
  local cols = info.columns or {}
  -- Columns right-aligned from the right edge, the name takes the rest.
  local function placeCells(cells, row)
    local x = 8
    for i = #cols, 1, -1 do
      local fs = cells[i]
      fs:ClearAllPoints()
      fs:SetPoint("RIGHT", row, "RIGHT", -x, 0)
      fs:SetWidth(cols[i][2] - 6)
      fs:Show()
      x = x + cols[i][2]
    end
    for i = #cols + 1, #cells do cells[i]:Hide() end
    return x
  end
  local used = placeCells(d.headCells, d.head)
  for i, c in ipairs(cols) do d.headCells[i]:SetText(c[1]) end
  for i, r in ipairs(d.rows) do
    local row = (info.rows or {})[i]
    r.itemID = row and row.itemID
    if row then
      r.icon:SetTexture(row.itemID and ((C_Item and C_Item.GetItemIconByID) or GetItemIcon)(row.itemID) or nil)
      r.name:SetText(row.name or (row.itemID and ns.ItemName(row.itemID)) or "")
      r.name:SetPoint("RIGHT", r, "RIGHT", -used, 0)
      placeCells(r.cells, r)
      for j = 1, #cols do r.cells[j]:SetText(row.cells[j] or "") end
      r:Show()
    else
      r:Hide()
    end
  end
  for i, line in ipairs(d.summary) do
    local s = (info.summary or {})[i]
    line.label:SetText(s and s[1] or "")
    line.value:SetText(s and s[2] or "")
  end
  d.hint:SetText(info.hint or "")
end

local function createDetail(parent)
  local Style = ns.Style
  local f = CreateFrame("Frame", "M4CompanionAHDetail", parent)
  detail.frame = f
  f:SetWidth(DETAIL_W)
  f:SetFrameStrata("HIGH")
  Style.Panel(f, 30)
  local close = Style.Close(f, function() f:Hide() end)
  close:SetPoint("TOPRIGHT", -6, -6)
  detail.title = Style.Text(f, 14)
  detail.title:SetPoint("TOPLEFT", 12, -9)
  detail.title:SetPoint("RIGHT", -40, 0)
  detail.title:SetJustifyH("LEFT")
  detail.sub = Style.Text(f, 11)
  detail.sub:SetPoint("TOPLEFT", 12, -38)
  detail.sub:SetPoint("RIGHT", -110, 0)
  detail.sub:SetJustifyH("LEFT")
  detail.sub:SetTextColor(unpack(Style.C.muted))

  -- Count: - n +
  local box = CreateFrame("Frame", nil, f)
  detail.countBox = box
  box:SetSize(96, 22)
  box:SetPoint("TOPRIGHT", -10, -34)
  local function step(delta)
    local n = detail.count
    local inc = IsShiftKeyDown() and 10 or 1
    detail.count = math.max(1, math.min(999, n + delta * inc))
    renderDetail()
  end
  local minus = Style.Button(box, "-", 26, 22, function() step(-1) end)
  minus:SetPoint("LEFT")
  local plus = Style.Button(box, "+", 26, 22, function() step(1) end)
  plus:SetPoint("RIGHT")
  detail.countLabel = Style.Text(box, 13)
  detail.countLabel:SetPoint("CENTER")

  local head = CreateFrame("Frame", nil, f)
  detail.head = head
  head:SetPoint("TOPLEFT", 1, -62)
  head:SetPoint("TOPRIGHT", -1, -62)
  head:SetHeight(20)
  Style.Solid(head, Style.C.header):SetAllPoints()
  local hname = Style.Text(head, 12)
  hname:SetPoint("LEFT", 12, 0)
  hname:SetText("Material")
  hname:SetTextColor(unpack(Style.C.muted))
  detail.headCells = {}
  for i = 1, 6 do
    local fs = Style.Text(head, 12)
    fs:SetJustifyH("RIGHT")
    fs:SetTextColor(unpack(Style.C.muted))
    detail.headCells[i] = fs
  end

  detail.rows = {}
  for i = 1, DETAIL_ROWS do
    local r = CreateFrame("Button", nil, f)
    r:SetHeight(DETAIL_ROW)
    r:SetPoint("TOPLEFT", 1, -82 - (i - 1) * DETAIL_ROW)
    r:SetPoint("TOPRIGHT", -1, -82 - (i - 1) * DETAIL_ROW)
    local stripe = Style.Solid(r, Style.C.row)
    stripe:SetAllPoints()
    stripe:SetShown(i % 2 == 0)
    local hover = Style.Solid(r, Style.C.hover, "ARTWORK")
    hover:SetAllPoints()
    hover:Hide()
    r.icon = r:CreateTexture(nil, "ARTWORK")
    r.icon:SetSize(20, 20)
    r.icon:SetPoint("LEFT", 8, 0)
    r.name = Style.Text(r, 12)
    r.name:SetPoint("LEFT", r.icon, "RIGHT", 6, 0)
    r.name:SetJustifyH("LEFT")
    r.cells = {}
    for j = 1, 6 do
      local fs = Style.Text(r, 12)
      fs:SetJustifyH("RIGHT")
      r.cells[j] = fs
    end
    -- Click: search the reagent in Blizzard's buy tab.
    r:SetScript("OnClick", function(self) if self.itemID then search(self.itemID) end end)
    r:SetScript("OnEnter", function(self)
      hover:Show()
      if not self.itemID then return end
      GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
      GameTooltip:SetItemByID(self.itemID)
      if ahOpen() then GameTooltip:AddLine("Klick: im AH suchen", 0.31, 0.76, 0.63) end
      GameTooltip:Show()
    end)
    r:SetScript("OnLeave", function() hover:Hide(); GameTooltip:Hide() end)
    detail.rows[i] = r
  end

  -- Summary: single-line rows, label left, value right (money with coin icons must not wrap).
  detail.hint = Style.Text(f, 11)
  detail.hint:SetPoint("BOTTOMLEFT", 12, 10)
  detail.hint:SetPoint("BOTTOMRIGHT", -12, 10)
  detail.hint:SetJustifyH("LEFT")
  detail.hint:SetTextColor(unpack(Style.C.muted))
  local sep = Style.Solid(f, Style.C.border, "ARTWORK")
  sep:SetHeight(1)
  sep:SetPoint("BOTTOMLEFT", 8, 30 + SUMMARY_ROWS * SUMMARY_ROW)
  sep:SetPoint("BOTTOMRIGHT", -8, 30 + SUMMARY_ROWS * SUMMARY_ROW)
  detail.summary = {}
  for i = 1, SUMMARY_ROWS do
    local y = 28 + (SUMMARY_ROWS - i) * SUMMARY_ROW
    local label = Style.Text(f, 12)
    label:SetPoint("BOTTOMLEFT", 12, y)
    label:SetJustifyH("LEFT")
    label:SetTextColor(unpack(Style.C.muted))
    local value = Style.Text(f, 12)
    value:SetPoint("BOTTOMRIGHT", -12, y)
    value:SetJustifyH("RIGHT")
    detail.summary[i] = { label = label, value = value }
  end
  f:Hide()
end

-- Docks the panel to the host's anchor (AH tabs: the auction house frame); it is
-- parented there so it scales and hides with it.
function showDetail(t, entry)
  local anchor = t.detailAnchor or AuctionHouseFrame or UIParent
  if not detail.frame then createDetail(anchor) end
  local f = detail.frame
  if detail.anchor ~= anchor then
    detail.anchor = anchor
    f:SetParent(anchor)
    f:SetFrameStrata("HIGH")
    f:ClearAllPoints()
    if anchor == UIParent then
      f:SetPoint("TOPRIGHT", anchor, "TOPRIGHT", -20, -120)
      f:SetHeight(560)
    else
      f:SetPoint("TOPLEFT", anchor, "TOPRIGHT", 4, 0)
      f:SetPoint("BOTTOMLEFT", anchor, "BOTTOMRIGHT", 4, 0)
    end
  end
  if detail.entry ~= entry then detail.count = 1 end
  detail.t, detail.entry = t, entry
  f:Show()
  renderDetail()
end

function AHTable.HideDetail()
  if detail.frame then detail.frame:Hide() end
end

local function selectTab(t)
  AuctionHouseFrame:SetDisplayMode({})
  AuctionHouseFrame.displayMode = nil
  for _, b in ipairs(AuctionHouseFrame.Tabs) do PanelTemplates_DeselectTab(b) end
  for _, o in ipairs(ahTabs) do
    if o ~= t then o.frame:Hide(); PanelTemplates_DeselectTab(o.tab) end
  end
  PanelTemplates_SelectTab(t.tab)
  if t.chooser then t.choice = nil end   -- a tab with a chooser always starts there
  setTitle(t, t.title)
  t.frame:Show()
  if t.onOpen then ns.Safe(t.onOpen, t) end
end

-- New instance of a definition: own list, scroll, sorting, view and choice; everything
-- else (columns, rows, saved filters via the id) comes from the definition.
local function newInstance(def, opts)
  local t = setmetatable({
    def = def,
    offset = 0, list = {},
    sortKey = def.sort or "name", sortDesc = def.desc ~= false,
    view = def.views and def.views[1][1] or nil,
  }, { __index = def })
  for key, value in pairs(opts or {}) do t[key] = value end
  table.insert(instances, t)
  return t
end

-- Recomputes the lists of the visible tables (e.g. after new prices).
function AHTable.Rebuild()
  for _, t in ipairs(instances) do
    if t.frame and t.frame:IsShown() then build(t); refresh(t) end
  end
  renderDetail()
end

local function createAll(parent)
  -- After Blizzard's tabs, or after the last LibAHTab tab when TSM/Auctionator are loaded.
  local anchor = parent.Tabs[#parent.Tabs]
  local lib = LibStub and LibStub("LibAHTab-1-0", true)
  if lib and lib.internalState and #lib.internalState.Tabs > 0 then
    anchor = lib.internalState.Tabs[#lib.internalState.Tabs]
  end
  -- Forever uses the retail auction house frame: retail tab spacing.
  local offsetX = 3
  for _, def in ipairs(defs) do
    local t = newInstance(def, { isAHTab = true, detailAnchor = parent })
    createFrame(t, parent, false)
    local tab = CreateFrame("Button", "M4CompanionAHTab" .. t.id, parent, "AuctionHouseFrameDisplayModeTabTemplate")
    t.tab = tab
    tab:SetText(t.label)
    PanelTemplates_TabResize(tab, 20, nil, 70)
    tab:SetPoint("TOPLEFT", anchor, "TOPRIGHT", offsetX, 0)
    PanelTemplates_DeselectTab(tab)
    tab:SetScript("OnClick", function() ns.Safe(selectTab, t) end)
    table.insert(ahTabs, t)
    anchor = tab
  end
  hooksecurefunc(parent, "SetDisplayMode", function(_, displayMode)
    if type(displayMode) == "table" and #displayMode > 0 then
      for _, t in ipairs(ahTabs) do t.frame:Hide(); PanelTemplates_DeselectTab(t.tab) end
    end
  end)
end

function AHTable.Add(def)
  -- Defaults on the definition too (offline tests build a definition directly).
  def.offset, def.list = 0, {}
  def.sortKey, def.sortDesc = def.sort or "name", def.desc ~= false
  def.view = def.views and def.views[1][1] or nil
  table.insert(defs, def)
  byId[def.id] = def
end

-- Embeds a new instance of the table `id` into `parent` (see the top of the file).
function AHTable.Embed(id, parent, opts)
  local def = byId[id]
  if not def then error("AHTable.Embed: unknown table " .. tostring(id)) end
  opts = opts or {}
  local t = newInstance(def, { isAHTab = false, detailAnchor = opts.detailAnchor, onTitle = opts.onTitle })
  createFrame(t, parent, true)
  local f = t.frame
  f.instance = t
  function f:Refresh()
    if not self:IsShown() then return end
    build(t)
    refresh(t)
  end
  f:Show()
  return f
end

function AHTable.Refresh()
  for _, t in ipairs(instances) do refresh(t) end
end

-- For offline tests.
AHTable._parseFilter = parseFilter
AHTable._build = build
AHTable._instances = instances

ns.On("AUCTION_HOUSE_SHOW", function()
  ahShown = true
  C_Timer.After(0.3, function()
    -- Embedded tables get their search buttons.
    ns.Safe(AHTable.Refresh)
    local parent = AuctionHouseFrame
    if created or not parent or not parent.Tabs or not parent.SetDisplayMode then return end
    created = true
    ns.Safe(createAll, parent)
  end)
end)

-- Names arrive from the server bit by bit: redraw once a burst of them is in.
local namesPending = false
ns.On("GET_ITEM_INFO_RECEIVED", function()
  if namesPending or #instances == 0 then return end
  namesPending = true
  C_Timer.After(0.3, function()
    namesPending = false
    for _, t in ipairs(instances) do
      if t.frame and t.frame:IsShown() and t.sortKey == "name" then sortList(t) end
    end
    ns.Safe(AHTable.Refresh)
  end)
end)

-- Bags change while buying: the "have" column follows.
ns.On("BAG_UPDATE_DELAYED", function() ns.Safe(renderDetail) end)

ns.On("AUCTION_HOUSE_CLOSED", function()
  ahShown = false
  if detail.t and detail.t.isAHTab then AHTable.HideDetail() end
  for _, t in ipairs(ahTabs) do
    if t.frame then t.frame:Hide(); PanelTemplates_DeselectTab(t.tab) end
  end
  -- Embedded tables lose their search buttons.
  ns.Safe(AHTable.Refresh)
end)
