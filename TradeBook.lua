-- TradeBook: the ledger ("Handelsbuch") as a window in Blizzard's own look, built like the
-- profession window: portrait and title, a list column on the left (search box, entries) and a
-- details area on the right. Opened with the tab "Handelsbuch" under the auction house (next to
-- Blizzard's tabs) or /m4 buch. First step: the bare frame, no content yet.
local ADDON, ns = ...

local TradeBook = {}
ns.TradeBook = TradeBook

local NAME = "M4CompanionTradeBook"
local WIDTH, HEIGHT = 760, 560
local LIST_WIDTH = 270 -- the scroll part; Blizzard's list template adds the frame around it
local ICON = "Interface\\Icons\\INV_Misc_Coin_02" -- a pile of gold coins

local frame

-- Example entries until the real ledger is wired in (layout pilot).
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

local TABS = {
  { key = "overview", title = "Übersicht", icon = "Interface\\Icons\\INV_Misc_Coin_02" },
  { key = "ledger", title = "Handelsbuch", icon = "Interface\\Icons\\INV_Misc_Note_01" },
  { key = "stock", title = "Bestand", icon = "Interface\\Icons\\INV_Box_02" },
  { key = "auctions", title = "Auktionen", icon = "Interface\\Icons\\INV_Hammer_15" },
}

local function try(objType, parent, template)
  local ok, f = pcall(CreateFrame, objType, nil, parent, template)
  return ok and f or nil
end

-- Detail area: the selected entry like the profession window's recipe card.
local function showDetail(entry)
  local d = frame.Detail
  if not (d and entry) then return end
  d.Icon:SetTexture(entry.icon)
  d.Name:SetText(entry.name)
  d.Values[1]:SetText("12g 40s")
  d.Values[2]:SetText("7g 15s")
  d.Values[3]:SetText("62s")
  d.Values[4]:SetText("|cff5fd38d+4g 63s|r")
  local w = math.max(100, (frame.Card:GetWidth() or 400) - 46)
  for _, v in ipairs(d.Values) do v:SetWidth(w) end
  if d.Line then d.Line:SetWidth(w) end
end

local function buildList(listFrame)
  local box, bar = rawget(listFrame, "ScrollBox"), rawget(listFrame, "ScrollBar")
  if not (type(box) == "table" and CreateScrollBoxListLinearView and ScrollUtil and CreateDataProvider) then return false end
  local view = CreateScrollBoxListLinearView()
  view:SetElementFactory(function(factory, data)
    if data.header then
      factory("ProfessionsRecipeListCategoryTemplate", function(button)
        local text = rawget(button, "ButtonText") or rawget(button, "Label")
        if type(text) == "table" then text:SetText(data.header) end
        local collapse = rawget(button, "CollapseButton")
        if type(collapse) == "table" and collapse.UpdateCollapsedState then pcall(collapse.UpdateCollapsedState, collapse, false) end
        button:SetScript("OnEnter", nil)
        button:SetScript("OnLeave", nil)
        button:SetScript("OnClick", nil)
      end)
    else
      factory("ProfessionsRecipeListRecipeTemplate", function(button)
        local label = rawget(button, "Label")
        if type(label) == "table" then label:SetText(data.name) end
        for _, key in ipairs({ "SkillUps", "LockedIcon", "Count" }) do
          local part = rawget(button, key)
          if type(part) == "table" and part.Hide then part:Hide() end
        end
        local selected = rawget(button, "SelectedOverlay")
        if type(selected) == "table" then selected:SetShown(frame.selected == data) end
        button:SetScript("OnEnter", function(self)
          local h = rawget(self, "HighlightOverlay")
          if type(h) == "table" then h:Show() end
        end)
        button:SetScript("OnLeave", function(self)
          local h = rawget(self, "HighlightOverlay")
          if type(h) == "table" then h:Hide() end
        end)
        button:SetScript("OnClick", function()
          frame.selected = data
          showDetail(data)
          box:ForEachFrame(function(other)
            local o = rawget(other, "SelectedOverlay")
            if type(o) == "table" then o:SetShown(other == button) end
          end)
        end)
      end)
    end
  end)
  view:SetElementExtentCalculator(function(_, data) return data.header and 25 or 20 end)
  ScrollUtil.InitScrollBoxListWithScrollBar(box, bar, view)
  box:SetDataProvider(CreateDataProvider(DUMMY))
  return true
end

local function create()
  -- Blizzard's profession templates live in a load-on-demand part of the UI
  if not rawget(_G, "ProfessionsFrame") then
    local load = (C_AddOns and C_AddOns.LoadAddOn) or LoadAddOn
    if load then pcall(load, "Blizzard_Professions") end
  end
  local ok, f = pcall(CreateFrame, "Frame", NAME, UIParent, "PortraitFrameTemplate")
  if not ok then ok, f = pcall(CreateFrame, "Frame", NAME, UIParent, "ButtonFrameTemplate") end
  if not ok then f = CreateFrame("Frame", NAME, UIParent) end
  frame = f
  f:SetSize(WIDTH, HEIGHT)
  f:SetToplevel(true)
  f:EnableMouse(true)
  f:SetMovable(true)
  f:SetClampedToScreen(true)
  f:Hide()
  if ButtonFrameTemplate_HideButtonBar then pcall(ButtonFrameTemplate_HideButtonBar, f) end
  if f.SetPortraitToAsset then
    pcall(f.SetPortraitToAsset, f, ICON)
  else
    local container = rawget(f, "PortraitContainer")
    local portrait = rawget(f, "portrait") or (type(container) == "table" and rawget(container, "portrait"))
    if type(portrait) == "table" and SetPortraitToTexture then pcall(SetPortraitToTexture, portrait, ICON) end
  end
  if f.SetTitle then
    pcall(f.SetTitle, f, "Handelsbuch")
  else
    local container = rawget(f, "TitleContainer")
    local title = rawget(f, "TitleText") or (type(container) == "table" and rawget(container, "TitleText"))
    if type(title) == "table" then title:SetText("Handelsbuch") end
  end
  local inset = rawget(f, "Inset")
  if type(inset) == "table" then inset:Hide() end
  f:RegisterForDrag("LeftButton")
  f:SetScript("OnDragStart", function(self) self:StartMoving() end)
  f:SetScript("OnDragStop", function(self) self:StopMovingOrSizing() end)
  if UISpecialFrames then tinsert(UISpecialFrames, NAME) end
  f:SetPoint("CENTER", UIParent, "CENTER", 0, 40)

  -- The profession window's page background (atlas from the probe of this client).
  local page = f:CreateTexture(nil, "BACKGROUND", nil, -3)
  page:SetPoint("TOPLEFT", 3, -21)
  page:SetPoint("BOTTOMRIGHT", -3, 3)
  page:SetAtlas("Profession-Background-Template2")

  -- Left: Blizzard's recipe list (background, frame, search box, filter, scroll box).
  local list = try("Frame", f, "ProfessionsRecipeListTemplate")
  if not list then
    list = CreateFrame("Frame", nil, f, "InsetFrameTemplate")
  end
  list:ClearAllPoints()
  list:SetPoint("TOPLEFT", 8, -64)
  list:SetPoint("BOTTOMLEFT", 8, 8)
  list:SetWidth(LIST_WIDTH + 34)
  f.List = list
  if not ns.Safe(buildList, list) then end

  -- Right: the recipe card (border and background like the profession window's form).
  local card = CreateFrame("Frame", nil, f)
  card:SetPoint("TOPLEFT", list, "TOPRIGHT", 6, 0)
  card:SetPoint("BOTTOMRIGHT", -8, 8)
  local cardBg = card:CreateTexture(nil, "BACKGROUND")
  cardBg:SetAllPoints()
  cardBg:SetAtlas("Profession-background-card-leatherworking")
  local cardBorder = card:CreateTexture(nil, "BORDER")
  cardBorder:SetAllPoints()
  cardBorder:SetAtlas("common-insideframe")
  f.Card = card

  -- Detail content (example): icon and name like the recipe header, four figures.
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
  d.Values = {}
  for i, label in ipairs({ "Umsatz", "Einkauf", "Gebühren", "Gewinn" }) do
    local l = card:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    l:SetPoint("TOPLEFT", head, "BOTTOMLEFT", 0, -10 - (i - 1) * 16 - (i == 4 and 8 or 0))
    l:SetText(label)
    local v = card:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    v:SetPoint("TOPLEFT", l, "TOPLEFT", 0, 0) -- width set to the card's in showDetail
    v:SetJustifyH("RIGHT")
    d.Values[i] = v
    if i == 4 then
      local line = card:CreateTexture(nil, "ARTWORK")
      line:SetColorTexture(1, 0.82, 0, 0.25)
      line:SetHeight(1)
      line:SetPoint("BOTTOMLEFT", l, "TOPLEFT", 0, 4)
      d.Line = line
    end
  end
  f.Detail = d
  showDetail(DUMMY[2])

  -- Side tabs on the right edge, like the profession window's (LargeSideTabButtonTemplate).
  f.Tabs = {}
  for i, def in ipairs(TABS) do
    local t = try("CheckButton", f, "LargeSideTabButtonTemplate") or try("Button", f, "LargeSideTabButtonTemplate")
      or try("Frame", f, "LargeSideTabButtonTemplate")
    if t then
      t:ClearAllPoints()
      t:SetPoint("TOPLEFT", f, "TOPRIGHT", -2, -40 - (i - 1) * 60)
      local icon = rawget(t, "Icon")
      if type(icon) == "table" then icon:SetTexture(def.icon) end
      local sel = rawget(t, "SelectedTexture")
      if type(sel) == "table" then sel:SetShown(i == 1) end
      if t.SetScript and t.HasScript and t:HasScript("OnClick") then
        t:SetScript("OnClick", function()
          for j, other in ipairs(f.Tabs) do
            local o = rawget(other, "SelectedTexture")
            if type(o) == "table" then o:SetShown(j == i) end
          end
        end)
      end
      t:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        GameTooltip:SetText(def.title)
        GameTooltip:Show()
      end)
      t:SetScript("OnLeave", function() GameTooltip:Hide() end)
      t:Show()
      f.Tabs[#f.Tabs + 1] = t
    end
  end
end

function TradeBook.Show()
  if not frame then create() end
  frame:Show()
  frame:Raise()
end

function TradeBook.Toggle()
  if frame and frame:IsShown() then frame:Hide() else TradeBook.Show() end
end

function TradeBook.Frame() return frame end

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
