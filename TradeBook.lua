-- TradeBook: the ledger ("Handelsbuch") in Blizzard's own look (ns.NativeWindow): side tabs
-- Übersicht / Handelsbuch / Bestand / Auktionen. Opens on the overview, period "Alles".
-- Opened with the tab "Handelsbuch" under the auction house, the minimap button or /m4 buch.
-- Layout pilot: example figures, not the real ledger yet.
local ADDON, ns = ...

local TradeBook = {}
ns.TradeBook = TradeBook

local NAME = "M4CompanionTradeBook"
local ICON = "Interface\\Icons\\INV_Misc_Coin_02" -- a pile of gold coins
local PERIODS = { { key = "today", label = "Heute" }, { key = "week", label = "7 Tage" }, { key = "all", label = "Alles" } }

local window
local period = "all"

-- Example figures per period (until the real ledger is wired in).
local EXAMPLE = {
  today = { revenue = "3g 12s", cost = "1g 80s", fees = "16s", profit = "|cff5fd38d+1g 16s|r", sales = "7 Verkäufe" },
  week = { revenue = "41g 05s", cost = "22g 40s", fees = "2g 05s", profit = "|cff5fd38d+16g 60s|r", sales = "63 Verkäufe" },
  all = { revenue = "96g 70s", cost = "58g 15s", fees = "4g 84s", profit = "|cff5fd38d+33g 71s|r", sales = "171 Verkäufe" },
}

local DUMMY = {
  { header = "Lederverarbeitung" },
  { name = "Stiefel des Nachtschleichers", icon = "Interface\\Icons\\INV_Boots_08" },
  { name = "Tückische Lederstulpen", icon = "Interface\\Icons\\INV_Gauntlets_19" },
  { name = "Hose des Nachtschleichers", icon = "Interface\\Icons\\INV_Pants_07" },
  { header = "Handel" },
  { name = "Abgefangene Kiste: Blühende Kräuter", icon = "Interface\\Icons\\INV_Crate_01" },
  { name = "Muster: Robe der Leere", icon = "Interface\\Icons\\INV_Scroll_03" },
  { header = "Beute" },
  { name = "Zornprankengürtel des arkanen Zorns", icon = "Interface\\Icons\\INV_Belt_03" },
  { name = "Leichtes Leder", icon = "Interface\\Icons\\INV_Misc_LeatherScrap_03" },
}

-- The card of a list entry: icon and name like the recipe header, four figures.
local function cardDetail(entry, card)
  if not card.m4 then
    local d = {}
    d.Icon = card:CreateTexture(nil, "ARTWORK")
    d.Icon:SetSize(44, 44)
    d.Icon:SetPoint("TOPLEFT", 22, -22)
    local okMask, mask = pcall(card.CreateMaskTexture, card)
    if okMask and mask then
      mask:SetTexture("Interface\\CharacterFrame\\TempPortraitAlphaMask", "CLAMPTOBLACKADDITIVE", "CLAMPTOBLACKADDITIVE")
      mask:SetAllPoints(d.Icon)
      d.Icon:AddMaskTexture(mask)
    end
    local ring = card:CreateTexture(nil, "OVERLAY")
    ring:SetSize(60, 60)
    ring:SetPoint("CENTER", d.Icon, "CENTER", 0, 0)
    ring:SetTexture("Interface\\Minimap\\MiniMap-TrackingBorder")
    ring:SetTexCoord(0, 0.6, 0, 0.6)
    d.Name = card:CreateFontString(nil, "OVERLAY", "GameFontHighlightLarge")
    d.Name:SetPoint("LEFT", d.Icon, "RIGHT", 14, 6)
    d.Name:SetPoint("RIGHT", card, "RIGHT", -20, 0)
    d.Name:SetJustifyH("LEFT")
    local head = card:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    head:SetPoint("TOPLEFT", d.Icon, "BOTTOMLEFT", 0, -20)
    head:SetText("Kennzahlen:")
    d.Figures = ns.NativeWindow.Figures(card, head, { "Umsatz", "Einkauf", "Gebühren", "Gewinn" })
    card.m4 = d
  end
  local d = card.m4
  d.Icon:SetTexture(entry.icon)
  d.Name:SetText(entry.name)
  local v = d.Figures.values
  v[1]:SetText("12g 40s"); v[2]:SetText("7g 15s"); v[3]:SetText("62s"); v[4]:SetText("|cff5fd38d+4g 63s|r")
  d.Figures.SetWidth(math.max(100, (card:GetWidth() or 400) - 46))
end

-- Overview: period choice on top, the period's profit and loss, stock, and three boxes.
local function buildOverview(page)
  local NW = ns.NativeWindow
  -- period buttons (top right), the chosen one held down
  local buttons = {}
  local prev
  for i = #PERIODS, 1, -1 do
    local def = PERIODS[i]
    local okB, b = pcall(CreateFrame, "Button", nil, page, "UIPanelButtonTemplate")
    if not okB then b = CreateFrame("Button", nil, page) end
    b:SetSize(76, 22)
    b:SetText(def.label)
    if prev then b:SetPoint("RIGHT", prev, "LEFT", -4, 0) else b:SetPoint("TOPRIGHT", page, "TOPRIGHT", -6, 0) end
    b:SetScript("OnClick", function()
      period = def.key
      if page.Refresh then page.Refresh() end
    end)
    buttons[def.key] = b
    prev = b
  end
  local label = page:CreateFontString(nil, "OVERLAY", "GameFontNormal")
  label:SetPoint("RIGHT", prev, "LEFT", -10, 0)
  label:SetText("Zeitraum:")

  -- top: profit and loss (left), stock (right)
  local pnl = NW.Panel(page, "Gewinn und Verlust")
  pnl:SetPoint("TOPLEFT", 0, -30)
  pnl:SetPoint("RIGHT", page, "CENTER", -3, 0)
  pnl:SetHeight(190)
  pnl.Big = pnl:CreateFontString(nil, "OVERLAY", "GameFontHighlightHuge")
  pnl.Big:SetPoint("TOPLEFT", pnl.Title, "BOTTOMLEFT", 0, -12)
  pnl.Sub = pnl:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
  pnl.Sub:SetPoint("TOPLEFT", pnl.Big, "BOTTOMLEFT", 0, -4)
  pnl.Figures = NW.Figures(pnl, pnl.Sub, { "Umsatz", "Einkauf", "Gebühren", "Gewinn" })

  local stock = NW.Panel(page, "Bestand")
  stock:SetPoint("TOPLEFT", page, "TOP", 3, -30)
  stock:SetPoint("RIGHT", page, "RIGHT", 0, 0)
  stock:SetHeight(190)
  stock.Big = stock:CreateFontString(nil, "OVERLAY", "GameFontHighlightHuge")
  stock.Big:SetPoint("TOPLEFT", stock.Title, "BOTTOMLEFT", 0, -12)
  stock.Big:SetText("|cff5fd38d+6g 74s|r")
  stock.Sub = stock:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
  stock.Sub:SetPoint("TOPLEFT", stock.Big, "BOTTOMLEFT", 0, -4)
  stock.Sub:SetText("Buchgewinn, wenn alles verkauft wird")
  stock.Figures = NW.Figures(stock, stock.Sub, { "Items", "Einkauf", "Erlös netto", "Buchgewinn" })
  local sv = stock.Figures.values
  sv[1]:SetText("7 Items · 11 Stück"); sv[2]:SetText("4g 02s"); sv[3]:SetText("10g 76s"); sv[4]:SetText("|cff5fd38d+6g 74s|r")

  -- bottom: three boxes
  local boxes = {
    { title = "Beste Items", lines = { "Stiefel des Nachtschleichers  |cff5fd38d+9g 12s|r", "Muster: Robe der Leere  |cff5fd38d+4g 80s|r", "Leichtes Leder  |cff5fd38d+2g 05s|r" } },
    { title = "Schlechteste Items", lines = { "Abgefangene Kiste  |cffff6b6b-6s 99c|r", "Hose des Nachtschleichers  |cffff6b6b-1g 10s|r", "Tückische Lederstulpen  |cffff6b6b-42s|r" } },
    { title = "Auktionen", lines = { "12 laufend", "|cffff6b6b3 unterboten|r", "5 abgelaufen (Gebühr 22s)" } },
  }
  local bw = 1 / 3
  for i, def in ipairs(boxes) do
    local box = NW.Panel(page, def.title)
    box:SetPoint("TOPLEFT", pnl, "BOTTOMLEFT", 0, -6)
    box:SetPoint("BOTTOM", page, "BOTTOM", 0, 0)
    box.m4Index = i
    box.m4Lines = {}
    for k, text in ipairs(def.lines) do
      local fs = box:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
      fs:SetPoint("TOPLEFT", box.Title, "BOTTOMLEFT", 0, -10 - (k - 1) * 16)
      fs:SetText(text)
    end
    page["Box" .. i] = box
  end
  -- three equal columns (widths need the page's size)
  local function layoutBoxes()
    local w = page:GetWidth() or 0
    if w <= 0 then return end
    local each = (w - 12) * bw
    for i = 1, 3 do
      local box = page["Box" .. i]
      box:ClearAllPoints()
      box:SetPoint("TOPLEFT", pnl, "BOTTOMLEFT", (i - 1) * (each + 6), -6)
      box:SetPoint("BOTTOM", page, "BOTTOM", 0, 0)
      box:SetWidth(each)
    end
    local half = (w - 6) / 2 - 28
    pnl.Figures.SetWidth(half)
    stock.Figures.SetWidth(half)
  end
  page:SetScript("OnSizeChanged", layoutBoxes)

  function page.Refresh()
    for key, b in pairs(buttons) do
      if b.SetEnabled then b:SetEnabled(key ~= period) end -- the chosen one held down (disabled look)
    end
    local e = EXAMPLE[period]
    pnl.Big:SetText(e.profit)
    pnl.Sub:SetText("Gewinn · " .. e.sales)
    local v = pnl.Figures.values
    v[1]:SetText(e.revenue); v[2]:SetText(e.cost); v[3]:SetText(e.fees); v[4]:SetText(e.profit)
    layoutBoxes()
  end
  page.Refresh()
end

local function create()
  window = ns.NativeWindow.New({ name = NAME, title = "Handelsbuch", icon = ICON, width = 760, height = 560 })
  window:AddTab({ key = "overview", title = "Übersicht", icon = "Interface\\Icons\\INV_Misc_Coin_02",
    build = buildOverview, onShow = function(page) if page.Refresh then page.Refresh() end end })
  window:AddTab({ key = "ledger", title = "Handelsbuch", icon = "Interface\\Icons\\INV_Misc_Note_01",
    build = function(page) ns.NativeWindow.Split(page, { entries = DUMMY, onSelect = cardDetail }) end })
  window:AddTab({ key = "stock", title = "Bestand", icon = "Interface\\Icons\\INV_Box_02",
    build = function(page) ns.NativeWindow.Split(page, { entries = DUMMY, onSelect = cardDetail }) end })
  window:AddTab({ key = "auctions", title = "Auktionen", icon = "Interface\\Icons\\INV_Hammer_15",
    build = function(page) ns.NativeWindow.Split(page, { entries = DUMMY, onSelect = cardDetail }) end })
end

function TradeBook.Show()
  if not window then create() end
  window:Show()
  window:SelectTab("overview")
end

function TradeBook.Toggle()
  if window and window.frame:IsShown() then window.frame:Hide() else TradeBook.Show() end
end

function TradeBook.Frame() return window and window.frame end

-- The tab "Handelsbuch" under the auction house, after Blizzard's tabs. It opens the window and
-- leaves the auction house view as it is (it is not one of the AH's display modes).
local tab
local function addTab()
  local ah = AuctionHouseFrame
  if not ah or tab then return end
  local tabs = rawget(ah, "Tabs")
  local last = type(tabs) == "table" and tabs[#tabs]
  local ok, t = pcall(CreateFrame, "Button", "M4CompanionTradeBookTab", ah, "AuctionHouseFrameDisplayModeTabTemplate")
  if not ok then ok, t = pcall(CreateFrame, "Button", "M4CompanionTradeBookTab", ah, "UIPanelButtonTemplate") end
  if not ok then return end
  tab = t
  t:SetText("Handelsbuch")
  if PanelTemplates_TabResize then pcall(PanelTemplates_TabResize, t, 20, nil, 70) end
  if last then
    t:SetPoint("TOPLEFT", last, "TOPRIGHT", 3, 0)
  else
    t:SetPoint("TOPLEFT", ah, "BOTTOMLEFT", 300, 2)
  end
  if PanelTemplates_DeselectTab then pcall(PanelTemplates_DeselectTab, t) end
  t:SetScript("OnClick", function() ns.Safe(TradeBook.Toggle) end)
end

if ns.On then
  ns.On("AUCTION_HOUSE_SHOW", function()
    if C_Timer then C_Timer.After(0.2, function() ns.Safe(addTab) end) else ns.Safe(addTab) end
  end)
end

-- Probe (one step, removed later): what the profession window is made of in this client, so
-- the ledger window can use the very same templates, atlases and side tabs.
local function regionsOf(f, depth)
  local out = {}
  if type(f) ~= "table" or not f.GetRegions then return out end
  for _, r in ipairs({ f:GetRegions() }) do
    if r.GetObjectType and r:GetObjectType() == "Texture" then
      local atlas = r.GetAtlas and r:GetAtlas()
      local tex = r.GetTexture and r:GetTexture()
      local layer, sub = r:GetDrawLayer()
      local p, rel, rp, x, y = r:GetPoint(1)
      out[#out + 1] = string.format("%s|%s|%s/%s|%s %s %s %.0f %.0f|%.0fx%.0f|shown=%s", tostring(r:GetName() or "-"),
        tostring(atlas or tex), tostring(layer), tostring(sub), tostring(p),
        rel == f and "parent" or tostring(rel and rel.GetName and rel:GetName() or (rel and "other") or "nil"),
        tostring(rp), x or 0, y or 0, r:GetWidth() or 0, r:GetHeight() or 0, tostring(r:IsShown()))
    end
  end
  return out
end

local function keysOf(t)
  local k = {}
  for key, v in pairs(t) do
    if type(v) == "table" and v.GetObjectType then k[#k + 1] = tostring(key) .. ":" .. v:GetObjectType() end
  end
  table.sort(k)
  return table.concat(k, ",")
end

function TradeBook.Probe()
  if not ns.db then return end
  if not rawget(_G, "ProfessionsFrame") then
    local load = (C_AddOns and C_AddOns.LoadAddOn) or LoadAddOn
    if load then pcall(load, "Blizzard_Professions") end
  end
  local out = { t = time() }
  local pf = rawget(_G, "ProfessionsFrame")
  out.pf = type(pf)
  if type(pf) == "table" then
    out.pfKeys = keysOf(pf)
    out.pfRegions = table.concat(regionsOf(pf), " ;; ")
    local page = rawget(pf, "CraftingPage")
    if type(page) == "table" then
      out.pageKeys = keysOf(page)
      out.pageRegions = table.concat(regionsOf(page), " ;; ")
      local list = rawget(page, "RecipeList")
      if type(list) == "table" then
        out.listKeys = keysOf(list)
        out.listRegions = table.concat(regionsOf(list), " ;; ")
        local sb = rawget(list, "SearchBox")
        if type(sb) == "table" then
          local p, rel, rp, x, y = sb:GetPoint(1)
          out.searchPoint = string.format("%s %s %.0f %.0f %.0fx%.0f", tostring(p), tostring(rp), x or 0, y or 0, sb:GetWidth(), sb:GetHeight())
        end
        local fb = rawget(list, "FilterButton") or rawget(list, "FilterDropdown")
        if type(fb) == "table" then
          local p, rel, rp, x, y = fb:GetPoint(1)
          out.filterPoint = string.format("%s %s %.0f %.0f %.0fx%.0f %s", tostring(p), tostring(rp), x or 0, y or 0, fb:GetWidth(), fb:GetHeight(), fb:GetObjectType())
        end
        local box = rawget(list, "ScrollBox")
        if type(box) == "table" and box.ForEachFrame then
          local rows = {}
          box:ForEachFrame(function(row)
            if #rows < 3 then
              rows[#rows + 1] = keysOf(row) .. " => " .. table.concat(regionsOf(row), " ;; ")
            end
          end)
          out.rows = table.concat(rows, " || ")
        end
      end
      local form = rawget(page, "SchematicForm")
      if type(form) == "table" then
        out.formKeys = keysOf(form)
        out.formRegions = table.concat(regionsOf(form), " ;; ")
        local bg = rawget(form, "Background")
        if type(bg) == "table" then out.formBackground = tostring(bg.GetAtlas and bg:GetAtlas() or bg:GetTexture()) end
      end
    end
    -- side tabs: children of the window at its right edge
    local tabs = {}
    for _, child in ipairs({ pf:GetChildren() }) do
      local l, r = child:GetLeft(), pf:GetRight()
      if l and r and l > r - 10 then
        tabs[#tabs + 1] = tostring(child:GetName() or "-") .. ":" .. child:GetObjectType() .. " " .. keysOf(child)
          .. " => " .. table.concat(regionsOf(child), " ;; ")
      end
    end
    out.sideTabs = table.concat(tabs, " || ")
  end
  local info = C_XMLUtil and C_XMLUtil.GetTemplateInfo
  local names = {}
  for _, n in ipairs({ "ProfessionsRecipeListCategoryTemplate", "ProfessionsRecipeListRecipeTemplate",
      "ProfessionsRecipeListTemplate", "ProfessionsFrameTabTemplate", "SpellBookSkillLineTabTemplate",
      "ProfessionsSideTabTemplate", "LargeSideTabButtonTemplate", "SideTabTemplate", "SearchBoxTemplate",
      "WowStyle1FilterDropdownTemplate", "UIMenuButtonStretchTemplate", "ProfessionsSchematicFormTemplate" }) do
    local ok, ti = pcall(function() return info and info(n) end)
    names[#names + 1] = n .. "=" .. tostring(ok and ti ~= nil)
  end
  out.templates = table.concat(names, ",")
  ns.db.tradeBookProbe = out
end

if ns.On then
  ns.On("TRADE_SKILL_SHOW", function()
    if C_Timer then C_Timer.After(0.5, function() ns.Safe(TradeBook.Probe) end) end
  end)
end

-- Probe 2: the profession overview page ("Berufe", ProfessionsFrame.BookPage), two levels deep.
local function describe(f, depth, out, prefix)
  if type(f) ~= "table" or not f.GetObjectType then return end
  local w, h = f:GetWidth() or 0, f:GetHeight() or 0
  local p, rel, rp, x, y = f:GetPoint(1)
  out[#out + 1] = string.format("%s%s %s %.0fx%.0f @%s %s %.0f %.0f", prefix, f:GetObjectType(), tostring(f:GetName() or "-"),
    w, h, tostring(p), tostring(rp), x or 0, y or 0)
  if f.GetRegions then
    for _, r in ipairs({ f:GetRegions() }) do
      local t = r:GetObjectType()
      if t == "Texture" then
        local layer, sub = r:GetDrawLayer()
        local rp1, _, rrp, rx, ry = r:GetPoint(1)
        out[#out + 1] = string.format("%s  tex %s %s/%s %.0fx%.0f @%s %s %.0f %.0f", prefix,
          tostring((r.GetAtlas and r:GetAtlas()) or r:GetTexture()), tostring(layer), tostring(sub),
          r:GetWidth() or 0, r:GetHeight() or 0, tostring(rp1), tostring(rrp), rx or 0, ry or 0)
      elseif t == "FontString" then
        local fo = r:GetFontObject()
        out[#out + 1] = string.format("%s  text %q font=%s", prefix, tostring(r:GetText()), tostring(fo and fo:GetName()))
      end
    end
  end
  if depth > 0 and f.GetChildren then
    for _, c in ipairs({ f:GetChildren() }) do describe(c, depth - 1, out, prefix .. "    ") end
  end
end

-- The shown window whose title is "Berufe" (whatever its name in this client).
local function findBook()
  local book = rawget(_G, "ProfessionsBookFrame")
  if type(book) == "table" and book:IsShown() then return book end
  if not EnumerateFrames then return nil end
  local f = EnumerateFrames()
  while f do
    if f:IsShown() and f.GetParent and f:GetParent() == UIParent then
      local container = rawget(f, "TitleContainer")
      local title = rawget(f, "TitleText") or (type(container) == "table" and rawget(container, "TitleText"))
      if type(title) == "table" and title.GetText and title:GetText() == "Berufe" then return f end
    end
    f = EnumerateFrames(f)
  end
end

function TradeBook.ProbeBook()
  local book = findBook()
  if type(book) ~= "table" or not ns.db then return false end
  local out = {}
  describe(book, 4, out, "")
  ns.db.tradeBookProbe2 = { t = time(), name = tostring(book:GetName()), lines = out }
  return true
end

-- look for it every 2 s until found once (probe only)
if C_Timer and C_Timer.NewTicker then
  local ticker
  ticker = C_Timer.NewTicker(2, function()
    local ok, found = pcall(TradeBook.ProbeBook)
    if ok and found and ticker then ticker:Cancel() end
  end)
end

-- The professions book ("Berufe", K) loads on demand: hook its OnShow once it exists.
local bookHooked = false
local function hookBook()
  local book = rawget(_G, "ProfessionsBookFrame")
  if bookHooked or type(book) ~= "table" then return end
  bookHooked = true
  book:HookScript("OnShow", function()
    if C_Timer then C_Timer.After(0.5, function() ns.Safe(TradeBook.ProbeBook) end) end
  end)
  if book:IsShown() then ns.Safe(TradeBook.ProbeBook) end
end
if ns.On then
  ns.On("ADDON_LOADED", function(_, name) if name == "Blizzard_ProfessionsBook" then ns.Safe(hookBook) end end)
  ns.On("PLAYER_LOGIN", function() ns.Safe(hookBook) end)
end
