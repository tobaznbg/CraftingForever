-- TradeBook: the ledger ("Handelsbuch") in Blizzard's own look (ns.NativeWindow): side tabs
-- Übersicht / Handelsbuch / Bestand / Auktionen. Opens on the overview, period "Alles".
-- Opened with the tab "Handelsbuch" under the auction house, the minimap button or /m4 buch.
-- Overview with the real figures (ns.Profit, ns.MyAuctions, ns.Ledger); the other tabs still examples.
local ADDON, ns = ...

local TradeBook = {}
ns.TradeBook = TradeBook

local NAME = "M4CompanionTradeBook"
local ICON = "Interface\\Icons\\INV_Misc_Coin_02" -- a pile of gold coins
local PERIODS = { { key = "today", label = "Heute" }, { key = "week", label = "7 Tage" }, { key = "all", label = "Alles" } }

local window
local period = "all"


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

-- Overview, built from Blizzard's "Berufe" overview parts: on top two cards side by side
-- (profit and loss with the period choice, stock), below running auctions and recent trades.
local CARD_W, TOP_H = 331, 142

local function card(page, w, x, y, width, height, title)
  local c = CreateFrame("Frame", nil, page)
  c:SetSize(width, height)
  c:SetPoint("TOPLEFT", w.frame, "TOPLEFT", x, y)
  local bg = c:CreateTexture(nil, "BACKGROUND")
  bg:SetAllPoints()
  bg:SetAtlas("Profession-overview-Card")
  c.Title = c:CreateFontString(nil, "OVERLAY", "GameFontNormal")
  c.Title:SetPoint("TOPLEFT", 20, -16)
  c.Title:SetText(title)
  return c
end

-- A table in a card: column heads, a gold rule and a scroll list of rows (Blizzard's scroll box
-- and minimal scroll bar). Returns setRows(rows), rows = { { icon = …, itemID = …, text1, … } }.
local function scrollTable(c, cols, top)
  for _, col in ipairs(cols) do
    local h = c:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    if col[3] == "LEFT" then h:SetPoint("TOPLEFT", col[2], top) else h:SetPoint("TOPRIGHT", c, "TOPLEFT", col[2], top) end
    h:SetText(col[1])
  end
  local rule = c:CreateTexture(nil, "ARTWORK")
  rule:SetColorTexture(1, 0.82, 0, 0.25)
  rule:SetHeight(1)
  rule:SetPoint("TOPLEFT", 20, top - 14)
  rule:SetPoint("TOPRIGHT", -24, top - 14)
  local empty = c:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
  empty:SetPoint("TOPLEFT", 22, top - 24)
  local okB, box = pcall(CreateFrame, "Frame", nil, c, "WowScrollBoxList")
  local okS, bar = pcall(CreateFrame, "EventFrame", nil, c, "MinimalScrollBar")
  if not (okB and okS and CreateScrollBoxListLinearView and ScrollUtil) then
    return function(rows) empty:SetText(#rows .. " Einträge") end
  end
  box:SetPoint("TOPLEFT", 16, top - 18)
  box:SetPoint("BOTTOMRIGHT", -30, 14)
  bar:SetPoint("TOPLEFT", box, "TOPRIGHT", 8, 0)
  bar:SetPoint("BOTTOMLEFT", box, "BOTTOMRIGHT", 8, 0)
  local view = CreateScrollBoxListLinearView()
  view:SetElementExtent(20)
  view:SetElementInitializer("BackdropTemplate", function(row, r)
    if not row.m4 then
      row.m4 = {}
      row.m4.icon = row:CreateTexture(nil, "ARTWORK")
      row.m4.icon:SetSize(16, 16)
      row.m4.icon:SetPoint("LEFT", 4, 0)
      for k, col in ipairs(cols) do
        local fs = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        fs:SetWordWrap(false)
        if col[3] == "LEFT" then
          fs:SetPoint("LEFT", row, "LEFT", k == 1 and 26 or (col[2] - 16), 0)
          fs:SetWidth(col[4] or 200)
          fs:SetJustifyH("LEFT")
        else
          fs:SetPoint("RIGHT", row, "LEFT", col[2] - 16, 0)
          fs:SetJustifyH("RIGHT")
        end
        row.m4[k] = fs
      end
      row:EnableMouse(true)
      row:SetScript("OnEnter", function(self)
        if not self.itemID then return end
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        GameTooltip:SetItemByID(self.itemID)
        GameTooltip:Show()
      end)
      row:SetScript("OnLeave", function() GameTooltip:Hide() end)
      row:SetScript("OnMouseUp", function(self, button)
        if button == "LeftButton" and self.itemID and ns.ItemDetail then ns.ItemDetail.AltClick(self.itemID) end
      end)
    end
    row.itemID = r.itemID
    row.m4.icon:SetTexture(r.icon)
    for k = 1, #cols do row.m4[k]:SetText(r[k] or "") end
  end)
  ScrollUtil.InitScrollBoxListWithScrollBar(box, bar, view)
  return function(rows)
    empty:SetText(#rows == 0 and "Keine Einträge" or "")
    box:SetDataProvider(CreateDataProvider(rows))
  end
end

-- Real data ------------------------------------------------------------------------------------

local GREEN, RED, MUTED = "|cff5fd38d", "|cffff6b6b", "|cff999999"
local function money(c) return ns.FormatMoney(math.floor((c or 0) + 0.5), true) end
local function signed(c)
  c = math.floor((c or 0) + 0.5)
  return c >= 0 and (GREEN .. "+" .. money(c) .. "|r") or (RED .. "-" .. money(-c) .. "|r")
end
local function iconOf(id)
  local get = (C_Item and C_Item.GetItemIconByID) or GetItemIcon
  return id and get and get(id) or nil
end

local function since()
  if period == "today" then
    local d = date("*t")
    return time({ year = d.year, month = d.month, day = d.day, hour = 0 })
  elseif period == "week" then
    return time() - 7 * 86400
  end
  return nil
end

-- Running auctions: the last answer of this session (with the undercut check), else the copy
-- stored for the companion app (not checked).
local function auctionRows()
  local out, under = {}, 0
  local My = ns.MyAuctions
  for _, r in ipairs(My and My.Rows and My.Rows() or {}) do
    if (r.active or 0) > 0 then
      local status
      if r.status == "best" then status = GREEN .. "bester Preis|r"
      elseif r.status == "under" then status = RED .. "unterboten " .. money(r.diff) .. "|r"; under = under + 1
      elseif r.status == "alone" then status = MUTED .. "allein im AH|r"
      elseif r.status == "bid" then status = MUTED .. "nur Gebot|r"
      else status = MUTED .. "–|r" end
      local left = r.timeLeft and string.format("%d h", math.ceil(r.timeLeft / 3600)) or "–"
      out[#out + 1] = { itemID = r.itemID, icon = iconOf(r.itemID),
        (ns.ItemName(r.itemID) or "") .. ((r.quantity or 1) > 1 and (MUTED .. "  " .. r.quantity .. "×|r") or ""),
        r.unit and money(r.unit) or "–", status, MUTED .. left .. "|r" }
    end
  end
  if #out == 0 then
    local key = ns.CharKey and ns.CharKey()
    local saved = key and ns.db and ns.db.owned and ns.db.owned[key]
    for _, a in ipairs(saved and saved.list or {}) do
      if not a.s then
        out[#out + 1] = { itemID = a.i, icon = iconOf(a.i),
          (ns.ItemName(a.i) or "") .. ((a.q or 1) > 1 and (MUTED .. "  " .. a.q .. "×|r") or ""),
          a.u and money(a.u) or "–", MUTED .. "nicht geprüft|r",
          MUTED .. (a.tl and string.format("%d h", math.ceil(a.tl / 3600)) or "–") .. "|r" }
      end
    end
  end
  return out, under
end

local KINDS = { buy = "Kauf", sale = "Verkauf", vendor = "Händler", post = "Eingestellt", expired = "Abgelaufen",
  cancelled = "Abgebrochen", craft = "Hergestellt" }

-- The last 20 trades (all of them: the "Handelsbuch" tab).
local function tradeRows()
  local out = {}
  for _, e in ipairs(ns.Ledger and ns.Ledger.Recent and ns.Ledger.Recent(20) or {}) do
    local amount = ""
    if e.k == "buy" then amount = RED .. "-" .. money(e.c) .. "|r"
    elseif e.k == "sale" then amount = GREEN .. "+" .. money((e.c or 0) - (e.cut or 0)) .. "|r"
    elseif e.k == "vendor" then amount = GREEN .. "+" .. money(e.c) .. "|r"
    elseif e.k == "post" and e.p then amount = MUTED .. money(e.p * (e.u or 1)) .. "|r" end
    out[#out + 1] = { itemID = e.i, icon = iconOf(e.i),
      e.n or (e.i and ns.ItemName(e.i)) or "?",
      MUTED .. date("%d.%m. %H:%M", e.t or 0) .. "|r  " .. (KINDS[e.k] or tostring(e.k)),
      tostring(e.u or 1), amount }
  end
  return out
end

local function buildOverview(page, w)
  local NW = ns.NativeWindow

  -- 1. profit and loss (left) with the period choice
  local pnl = card(page, w, 5, -41, CARD_W, TOP_H, "Gewinn und Verlust")
  local dd
  local okD, d = pcall(CreateFrame, "DropdownButton", nil, pnl, "WowStyle1DropdownTemplate")
  if okD and d and d.SetupMenu then
    dd = d
    dd:SetWidth(96)
    dd:SetPoint("TOPRIGHT", -16, -10)
    dd:SetupMenu(function(_, root)
      for _, def in ipairs(PERIODS) do
        root:CreateRadio(def.label, function() return period == def.key end, function()
          period = def.key
          if page.Refresh then page.Refresh() end
        end)
      end
    end)
  else
    local okB, bt = pcall(CreateFrame, "Button", nil, pnl, "UIPanelButtonTemplate")
    dd = okB and bt or CreateFrame("Button", nil, pnl)
    dd:SetSize(96, 22)
    dd:SetPoint("TOPRIGHT", -16, -10)
    dd:SetScript("OnClick", function()
      for i, def in ipairs(PERIODS) do
        if def.key == period then period = PERIODS[i % #PERIODS + 1].key break end
      end
      if page.Refresh then page.Refresh() end
    end)
  end
  local pnlSlot = NW.Slot(pnl, "Interface\\Icons\\INV_Misc_Coin_02", "Gewinn", "")
  pnlSlot:SetPoint("TOPLEFT", 16, -40)
  local pnlFig = NW.Figures(pnl, pnlSlot, { "Umsatz", "Einkauf", "Gebühren" }, { line = false, gap = 8, step = 14 })
  pnlFig.labels[1]:ClearAllPoints()
  pnlFig.labels[1]:SetPoint("TOPLEFT", pnlSlot, "BOTTOMLEFT", 2, -8)
  pnlFig.SetWidth(CARD_W - 40)

  -- 2. stock (right)
  local stock = card(page, w, 5 + CARD_W + 2, -41, CARD_W, TOP_H, "Bestand")
  local stockSlot = NW.Slot(stock, "Interface\\Icons\\INV_Box_02", "Buchgewinn", "")
  stockSlot:SetPoint("TOPLEFT", 16, -40)
  local stockFig = NW.Figures(stock, stockSlot, { "Einkauf", "Erlös", "Items" }, { line = false, gap = 8, step = 14 })
  stockFig.labels[1]:ClearAllPoints()
  stockFig.labels[1]:SetPoint("TOPLEFT", stockSlot, "BOTTOMLEFT", 2, -8)
  stockFig.SetWidth(CARD_W - 40)

  -- 3. running auctions (full width)
  local AH = 200
  local auc = card(page, w, 5, -41 - TOP_H + 4, 664, AH, "Laufende Auktionen")
  local aucInfo = auc:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
  aucInfo:SetPoint("TOPRIGHT", -20, -18)
  local setAuctions = scrollTable(auc, { { "Gegenstand", 20, "LEFT", 330 }, { "Preis", 450, "RIGHT" },
    { "Status", 565, "RIGHT" }, { "Zeit", 612, "RIGHT" } }, -42)

  -- 4. recent trades (full width), scrollable
  local trTop = -41 - TOP_H + 4 - AH + 4
  local tr = card(page, w, 5, trTop, 664, 594 + trTop - 10, "Letzte Vorgänge")
  local setTrades = scrollTable(tr, { { "Item", 20, "LEFT", 270 }, { "Wann · Art", 320, "LEFT", 170 },
    { "Menge", 520, "RIGHT" }, { "Betrag", 612, "RIGHT" } }, -42)

  function page.Refresh()
    local label
    for _, def in ipairs(PERIODS) do if def.key == period then label = def.label end end
    if dd.SetText then dd:SetText(label) end
    if dd.GenerateMenu then pcall(dd.GenerateMenu, dd) end
    -- profit and loss of the period, stock now (ns.Profit, one replay)
    local report = ns.Profit and ns.Profit.Report and ns.Profit.Report(since())
    local t = report and report.totals or {}
    local sales = 0
    for _, g in ipairs(report and report.groups or {}) do sales = sales + (g.sold or 0) end
    pnlSlot.Sub:SetText(signed(t.profit) .. MUTED .. "  ·  " .. sales .. " verkauft|r")
    pnlFig.values[1]:SetText(money(t.revenue)); pnlFig.values[2]:SetText(money(t.materials)); pnlFig.values[3]:SetText(money(t.fees))
    local st = report and report.stockTotals or {}
    stockSlot.Sub:SetText(signed(st.gain))
    stockFig.values[1]:SetText(money(st.cost)); stockFig.values[2]:SetText(money(st.sell))
    stockFig.values[3]:SetText(string.format("%d Items · %d Stück", report and #(report.stock or {}) or 0, st.units or 0))
    local rows, under = auctionRows()
    setAuctions(rows)
    aucInfo:SetText(#rows .. " Auktionen" .. (under > 0 and ("  ·  " .. RED .. under .. " unterboten|r") or ""))
    setTrades(tradeRows())
  end
  page.Refresh()
end

local function create()
  window = ns.NativeWindow.New({ name = NAME, title = "Handelsbuch", icon = ICON })
  window:AddTab({ key = "overview", title = "Übersicht", icon = "Interface\\Icons\\INV_Misc_Coin_02", overview = true,
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
