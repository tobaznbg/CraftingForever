-- AHTable: own tabs in the auction house frame, each a sortable item table over the
-- full width of the frame, with optional filter buttons and a "Suchen" button per row.
-- The tabs work like LibAHTab (TSM, Auctionator): DisplayMode tab buttons after
-- Blizzard's tabs; selecting one clears the display mode and shows its frame, any
-- Blizzard display mode hides it again.
--
-- ns.AHTable.Add{
--   id, label, title,
--   columns = { { key, title, width (0 = name column), align, format(entry) -> text, muted }... },
--   rows = function(filter) -> list of entries (each with itemID),
--   status = function(list) -> text,
--   filters = { { key, label }... } (optional, first is the default),
--   sort = key, desc = true,
--   rowColor = function(entry) -> { r, g, b } or nil (optional marker: bar + faint tint),
--   subtitle = function(entry) -> text (optional second line under the name),
--   salesFilter = true: button "Verk./Tag ≥ n" that hides entries with entry.fpd < n
--                 (cycles through SALES_STEPS, remembered per tab),
-- }
local ADDON, ns = ...

local AHTable = {}
ns.AHTable = AHTable

local ROW, HEADER, TOOLBAR = 30, 22, 28
local FOOTER = 8
local BUTTON_W = 64
local MAX_ROWS = 40

local SALES_STEPS = { 0, 1, 2, 5, 10, 25 }
local defs = {}       -- in tab order

local function settings(t)
  ns.db.ahTable = ns.db.ahTable or {}
  ns.db.ahTable[t.id] = ns.db.ahTable[t.id] or { minSales = 1 }
  return ns.db.ahTable[t.id]
end
local created = false

-- Switches to Blizzard's buy tab and searches the item there.
local function search(itemID)
  if AuctionHouseFrame and AuctionHouseFrameDisplayMode then
    AuctionHouseFrame:SetDisplayMode(AuctionHouseFrameDisplayMode.Buy)
  end
  C_Timer.After(0.1, function() ns.Safe(ns.Deals.Search, itemID) end)
end

local function sortList(t)
  local key, desc = t.sortKey, t.sortDesc
  table.sort(t.list, function(a, b)
    local x, y = a[key], b[key]
    if key == "name" then x, y = (x or ""):lower(), (y or ""):lower() else x, y = x or 0, y or 0 end
    if x == y then return a.itemID < b.itemID end
    if desc then return x > y end
    return x < y
  end)
end

local function build(t)
  t.list = t.rows(t.filter) or {}
  if t.salesFilter then
    local min, kept = settings(t).minSales or 0, {}
    for _, e in ipairs(t.list) do
      if (e.fpd or 0) >= min then table.insert(kept, e) end
    end
    t.list = kept
  end
  for _, e in ipairs(t.list) do e.name = ns.ItemName(e.itemID) or ("#" .. e.itemID) end
  sortList(t)
end

local function refresh(t)
  local f = t.frame
  if not f or not f:IsShown() then return end
  local top = HEADER + (t.filters and TOOLBAR or 0)
  local n = math.max(1, math.min(MAX_ROWS, math.floor((f:GetHeight() - top - FOOTER) / ROW)))
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
      if r.sub then r.sub:SetText(t.subtitle(e) or "") end
      r.icon:SetTexture(((C_Item and C_Item.GetItemIconByID) or GetItemIcon)(e.itemID))
      e.name = ns.ItemName(e.itemID) or e.name
      for _, c in ipairs(t.columns) do
        r.cells[c[1]]:SetText(c[5] and c[5](e) or tostring(e[c[1]] or ""))
      end
      r:Show()
    else
      r:Hide()
    end
  end
  for _, h in ipairs(t.headers) do
    h.label:SetTextColor(unpack(h.key == t.sortKey and ns.Style.C.accent or ns.Style.C.muted))
  end
  for key, b in pairs(t.filterButtons or {}) do b:SetActive(key == t.filter) end
  if t.salesButton then
    t.salesButton.label:SetText(string.format("Verk./Tag ≥ %d", settings(t).minSales or 0))
  end
end

local function createFrame(t, parent)
  local Style = ns.Style
  local f = CreateFrame("Frame", nil, parent)
  t.frame = f
  f:SetPoint("TOPLEFT", parent, "TOPLEFT", 8, -60)
  f:SetPoint("BOTTOMRIGHT", parent, "BOTTOMRIGHT", -8, 28)
  f:SetFrameLevel(parent:GetFrameLevel() + 20)
  Style.Solid(f, Style.C.bg):SetAllPoints()
  Style.Border(f)

  local top = 1
  if t.filters then
    t.filterButtons = {}
    local x = 8
    for _, fd in ipairs(t.filters) do
      local b = Style.Tab(f, fd[2], fd[3] or 90, function()
        t.filter, t.offset = fd[1], 0
        build(t)
        refresh(t)
      end)
      b:SetPoint("TOPLEFT", x, -2)
      t.filterButtons[fd[1]] = b
      x = x + (fd[3] or 90) + 4
    end
    top = top + TOOLBAR
  end
  if t.salesFilter then
    t.salesButton = Style.Button(f, "", 110, 20, function()
      local s, nextValue = settings(t), SALES_STEPS[1]
      for i, v in ipairs(SALES_STEPS) do
        if v == (s.minSales or 0) then nextValue = SALES_STEPS[i % #SALES_STEPS + 1] end
      end
      s.minSales, t.offset = nextValue, 0
      build(t)
      refresh(t)
    end)
    t.salesButton:SetPoint("TOPRIGHT", -8, -5)
  end

  -- Column layout: the name column takes what the fixed columns leave.
  local fixed = BUTTON_W + 16
  for i = 2, #t.columns do fixed = fixed + t.columns[i][3] end
  local function place(row, makeCell)
    local x = 8
    for i, c in ipairs(t.columns) do
      local cell = makeCell(c)
      if i == 1 then
        local y = (t.subtitle and row ~= t.head) and 7 or 0
        cell:SetPoint("LEFT", row, "LEFT", 34, y)
        cell:SetPoint("RIGHT", row, "RIGHT", -fixed, y)
      else
        x = x + c[3]
        cell:SetPoint("RIGHT", row, "RIGHT", -(fixed - x + 8), 0)
        cell:SetWidth(c[3] - 8)
      end
    end
  end

  local head = CreateFrame("Frame", nil, f)
  t.head = head
  head:SetPoint("TOPLEFT", 1, -top)
  head:SetPoint("TOPRIGHT", -1, -top)
  head:SetHeight(HEADER)
  Style.Solid(head, Style.C.header):SetAllPoints()
  t.headers = {}
  place(head, function(c)
    local b = CreateFrame("Button", nil, head)
    b:SetHeight(HEADER)
    b.label = Style.Text(b, 12)
    b.label:SetAllPoints()
    b.label:SetJustifyH(c[4])
    b.label:SetText(c[2])
    b.key = c[1]
    b:SetScript("OnClick", function(self)
      if t.sortKey == self.key then t.sortDesc = not t.sortDesc
      else t.sortKey, t.sortDesc = self.key, self.key ~= "name" end
      sortList(t)
      refresh(t)
    end)
    table.insert(t.headers, b)
    return b
  end)

  t.rowFrames = {}
  for i = 1, MAX_ROWS do
    local r = CreateFrame("Frame", nil, f)
    local y = -top - HEADER - (i - 1) * ROW
    r:SetPoint("TOPLEFT", 1, y)
    r:SetPoint("TOPRIGHT", -1, y)
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
      fs:SetJustifyH(c[4])
      if c[6] then fs:SetTextColor(unpack(Style.C.muted)) end
      r.cells[c[1]] = fs
      return fs
    end)
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
    r:EnableMouse(true)
    r:SetScript("OnEnter", function(self)
      hover:Show()
      if not self.entry then return end
      GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
      GameTooltip:SetItemByID(self.entry.itemID)
      GameTooltip:Show()
    end)
    r:SetScript("OnLeave", function() hover:Hide(); GameTooltip:Hide() end)
    t.rowFrames[i] = r
  end

  f:EnableMouseWheel(true)
  f:SetScript("OnMouseWheel", function(_, delta)
    t.offset = t.offset - delta * 3
    refresh(t)
  end)

  f:SetScript("OnShow", function() build(t); refresh(t) end)
  f:SetScript("OnSizeChanged", function() refresh(t) end)
  f:Hide()
end

local function selectTab(t)
  AuctionHouseFrame:SetDisplayMode({})
  AuctionHouseFrame.displayMode = nil
  for _, b in ipairs(AuctionHouseFrame.Tabs) do PanelTemplates_DeselectTab(b) end
  for _, o in ipairs(defs) do
    if o ~= t then o.frame:Hide(); PanelTemplates_DeselectTab(o.tab) end
  end
  PanelTemplates_SelectTab(t.tab)
  if AuctionHouseFrame.SetTitle then AuctionHouseFrame:SetTitle(t.title) end
  t.frame:Show()
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
  for _, t in ipairs(defs) do
    createFrame(t, parent)
    local tab = CreateFrame("Button", "CraftingForeverAHTab" .. t.id, parent, "AuctionHouseFrameDisplayModeTabTemplate")
    t.tab = tab
    tab:SetText(t.label)
    PanelTemplates_TabResize(tab, 20, nil, 70)
    tab:SetPoint("TOPLEFT", anchor, "TOPRIGHT", offsetX, 0)
    tab:SetHitRectInsets((math.abs(offsetX) - 3) / 2, (math.abs(offsetX) - 3) / 2, 0, 0)
    PanelTemplates_DeselectTab(tab)
    tab:SetScript("OnClick", function() ns.Safe(selectTab, t) end)
    anchor = tab
  end
  hooksecurefunc(parent, "SetDisplayMode", function(_, displayMode)
    if type(displayMode) == "table" and #displayMode > 0 then
      for _, t in ipairs(defs) do t.frame:Hide(); PanelTemplates_DeselectTab(t.tab) end
    end
  end)
end

function AHTable.Add(def)
  def.offset, def.list = 0, {}
  def.sortKey, def.sortDesc = def.sort or "name", def.desc ~= false
  def.filter = def.filters and def.filters[1][1] or nil
  table.insert(defs, def)
end

function AHTable.Refresh()
  for _, t in ipairs(defs) do refresh(t) end
end

ns.On("AUCTION_HOUSE_SHOW", function()
  C_Timer.After(0.3, function()
    local parent = AuctionHouseFrame
    if created or not parent or not parent.Tabs or not parent.SetDisplayMode then return end
    created = true
    ns.Safe(createAll, parent)
  end)
end)

-- Names arrive from the server bit by bit: redraw once a burst of them is in.
local namesPending = false
ns.On("GET_ITEM_INFO_RECEIVED", function()
  if namesPending or not created then return end
  namesPending = true
  C_Timer.After(0.3, function()
    namesPending = false
    for _, t in ipairs(defs) do
      if t.frame and t.frame:IsShown() and t.sortKey == "name" then sortList(t) end
    end
    ns.Safe(AHTable.Refresh)
  end)
end)

ns.On("AUCTION_HOUSE_CLOSED", function()
  for _, t in ipairs(defs) do
    if t.frame then t.frame:Hide(); PanelTemplates_DeselectTab(t.tab) end
  end
end)
