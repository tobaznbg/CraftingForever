-- NativeWindow: a window in Blizzard's own look, built from the profession window's parts, for
-- any addon page that should look native (first user: the ledger, TradeBook.lua).
--
--   local w = ns.NativeWindow.New{ name = "M4Thing", title = "Titel", icon = "Interface\\Icons\\…",
--     width = 760, height = 560 }
--   w:AddTab{ key = "overview", title = "Übersicht", icon = "…", build = function(page, w) … end,
--     onShow = function(page, w) … end }   -- page: a frame filling the content area
--   w:SelectTab(key); w:Show(); w:Toggle(); w.frame
--
-- Building blocks for pages:
--   ns.NativeWindow.Split(page, { entries = { { header = "…" } | { name, icon, … } },
--       onSelect = function(entry, card) … end })  -> split = { list, card, SetEntries(entries) }
--     left Blizzard's recipe list (search box, filter, category and recipe rows), right the recipe
--     card (border and background of the profession window's form)
--   ns.NativeWindow.Panel(parent, title)  -> an inset panel with a gold title (overview pages)
--   ns.NativeWindow.Figures(parent, anchor, labels) -> { values = { fontstring… }, SetWidth(w) }
--     gold labels left, values right-aligned; a line before the last row
-- The profession templates live in a load-on-demand part of the UI: New loads it.
local ADDON, ns = ...

local NW = {}
ns.NativeWindow = NW
NW.__index = NW

local function try(objType, parent, template, name)
  local ok, f = pcall(CreateFrame, objType, name, parent, template)
  return ok and f or nil
end

local function loadProfessions()
  if rawget(_G, "ProfessionsFrame") then return end
  local load = (C_AddOns and C_AddOns.LoadAddOn) or LoadAddOn
  if load then pcall(load, "Blizzard_Professions") end
end

function NW.New(opts)
  loadProfessions()
  local self = setmetatable({ tabs = {}, order = {} }, NW)
  local f = try("Frame", UIParent, "PortraitFrameTemplate", opts.name)
    or try("Frame", UIParent, "ButtonFrameTemplate", opts.name) or CreateFrame("Frame", opts.name, UIParent)
  self.frame = f
  f:SetSize(opts.width or 760, opts.height or 560)
  f:SetToplevel(true)
  f:EnableMouse(true)
  f:SetMovable(true)
  f:SetClampedToScreen(true)
  f:Hide()
  if ButtonFrameTemplate_HideButtonBar then pcall(ButtonFrameTemplate_HideButtonBar, f) end
  if f.SetPortraitToAsset then
    pcall(f.SetPortraitToAsset, f, opts.icon)
  else
    local container = rawget(f, "PortraitContainer")
    local portrait = rawget(f, "portrait") or (type(container) == "table" and rawget(container, "portrait"))
    if type(portrait) == "table" and SetPortraitToTexture then pcall(SetPortraitToTexture, portrait, opts.icon) end
  end
  if f.SetTitle then
    pcall(f.SetTitle, f, opts.title or "")
  else
    local container = rawget(f, "TitleContainer")
    local title = rawget(f, "TitleText") or (type(container) == "table" and rawget(container, "TitleText"))
    if type(title) == "table" then title:SetText(opts.title or "") end
  end
  local inset = rawget(f, "Inset")
  if type(inset) == "table" then inset:Hide() end
  f:RegisterForDrag("LeftButton")
  f:SetScript("OnDragStart", function(fr) fr:StartMoving() end)
  f:SetScript("OnDragStop", function(fr) fr:StopMovingOrSizing() end)
  if opts.name and UISpecialFrames then tinsert(UISpecialFrames, opts.name) end
  f:SetPoint("CENTER", UIParent, "CENTER", 0, 40)
  -- the profession window's page background
  local bg = f:CreateTexture(nil, "BACKGROUND", nil, -3)
  bg:SetPoint("TOPLEFT", 3, -21)
  bg:SetPoint("BOTTOMRIGHT", -3, 3)
  bg:SetAtlas("Profession-Background-Template2")
  self.background = bg
  -- the content area the pages fill
  local area = CreateFrame("Frame", nil, f)
  area:SetPoint("TOPLEFT", 8, -60)
  area:SetPoint("BOTTOMRIGHT", -8, 8)
  self.area = area
  return self
end

-- A side tab and its page (built on first selection).
function NW:AddTab(def)
  local f = self.frame
  local i = #self.order + 1
  local t = try("CheckButton", f, "LargeSideTabButtonTemplate") or try("Button", f, "LargeSideTabButtonTemplate")
    or try("Frame", f, "LargeSideTabButtonTemplate")
  if t then
    t:ClearAllPoints()
    t:SetPoint("TOPLEFT", f, "TOPRIGHT", -2, -40 - (i - 1) * 60)
    local icon = rawget(t, "Icon")
    if type(icon) == "table" then icon:SetTexture(def.icon) end
    if t.HasScript and t:HasScript("OnClick") then
      t:SetScript("OnClick", function() self:SelectTab(def.key) end)
    else
      t:EnableMouse(true)
      t:SetScript("OnMouseUp", function() self:SelectTab(def.key) end)
    end
    t:SetScript("OnEnter", function(btn)
      GameTooltip:SetOwner(btn, "ANCHOR_RIGHT")
      GameTooltip:SetText(def.title)
      GameTooltip:Show()
    end)
    t:SetScript("OnLeave", function() GameTooltip:Hide() end)
    t:Show()
  end
  self.tabs[def.key] = { def = def, button = t }
  self.order[i] = def.key
end

function NW:SelectTab(key)
  local tab = self.tabs[key]
  if not tab then return end
  for k, other in pairs(self.tabs) do
    if other.page then other.page:SetShown(k == key) end
    local sel = other.button and rawget(other.button, "SelectedTexture")
    if type(sel) == "table" then sel:SetShown(k == key) end
    if other.button and other.button.SetChecked then pcall(other.button.SetChecked, other.button, k == key) end
  end
  if not tab.page then
    tab.page = CreateFrame("Frame", nil, self.area)
    tab.page:SetAllPoints(self.area)
    if tab.def.build then ns.Safe(tab.def.build, tab.page, self) end
  end
  tab.page:Show()
  self.current = key
  if tab.def.onShow then ns.Safe(tab.def.onShow, tab.page, self) end
end

function NW:Show()
  self.frame:Show()
  self.frame:Raise()
  if not self.current and self.order[1] then self:SelectTab(self.order[1]) end
end

function NW:Toggle()
  if self.frame:IsShown() then self.frame:Hide() else self:Show() end
end

-- Pages ------------------------------------------------------------------------------------

-- Gold labels, values right-aligned (width set with SetWidth), a line before the last row.
function NW.Figures(parent, anchor, labels, opts)
  opts = opts or {}
  local out = { values = {}, labels = {} }
  local step = opts.step or 16
  for i, text in ipairs(labels) do
    local l = parent:CreateFontString(nil, "OVERLAY", opts.labelFont or "GameFontNormalSmall")
    local extra = (i == #labels and opts.line ~= false and #labels > 1) and 8 or 0
    l:SetPoint("TOPLEFT", anchor, "BOTTOMLEFT", 0, -(opts.gap or 10) - (i - 1) * step - extra)
    l:SetText(text)
    local v = parent:CreateFontString(nil, "OVERLAY", opts.valueFont or "GameFontHighlightSmall")
    v:SetPoint("TOPLEFT", l, "TOPLEFT", 0, 0)
    v:SetJustifyH("RIGHT")
    out.labels[i], out.values[i] = l, v
    if extra > 0 then
      local line = parent:CreateTexture(nil, "ARTWORK")
      line:SetColorTexture(1, 0.82, 0, 0.25)
      line:SetHeight(1)
      line:SetPoint("BOTTOMLEFT", l, "TOPLEFT", 0, 4)
      out.line = line
    end
  end
  function out.SetWidth(w)
    for _, v in ipairs(out.values) do v:SetWidth(w) end
    if out.line then out.line:SetWidth(w) end
  end
  return out
end

-- An inset panel with a gold title, like the boxes of the profession overview.
function NW.Panel(parent, title)
  local p = try("Frame", parent, "InsetFrameTemplate") or CreateFrame("Frame", nil, parent)
  local bg = p:CreateTexture(nil, "BACKGROUND", nil, 1)
  bg:SetPoint("TOPLEFT", 3, -3)
  bg:SetPoint("BOTTOMRIGHT", -3, 3)
  bg:SetColorTexture(0, 0, 0, 0.25)
  if title then
    p.Title = p:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    p.Title:SetPoint("TOPLEFT", 14, -12)
    p.Title:SetText(title)
  end
  return p
end

-- Left Blizzard's recipe list, right the recipe card.
function NW.Split(page, opts)
  local split = { selected = nil }
  local list = try("Frame", page, "ProfessionsRecipeListTemplate") or try("Frame", page, "InsetFrameTemplate")
  list:ClearAllPoints()
  list:SetPoint("TOPLEFT", 0, -4)
  list:SetPoint("BOTTOMLEFT", 0, 0)
  list:SetWidth(opts.listWidth or 304)
  split.list = list
  local card = CreateFrame("Frame", nil, page)
  card:SetPoint("TOPLEFT", list, "TOPRIGHT", 6, 0)
  card:SetPoint("BOTTOMRIGHT", 0, 0)
  local cardBg = card:CreateTexture(nil, "BACKGROUND")
  cardBg:SetAllPoints()
  cardBg:SetAtlas(opts.cardAtlas or "Profession-background-card-leatherworking")
  local cardBorder = card:CreateTexture(nil, "BORDER")
  cardBorder:SetAllPoints()
  cardBorder:SetAtlas("common-insideframe")
  split.card = card

  local box, bar = rawget(list, "ScrollBox"), rawget(list, "ScrollBar")
  if type(box) == "table" and CreateScrollBoxListLinearView and ScrollUtil and CreateDataProvider then
    local view = CreateScrollBoxListLinearView()
    view:SetElementFactory(function(factory, data)
      if data.header then
        factory("ProfessionsRecipeListCategoryTemplate", function(button)
          local text = rawget(button, "ButtonText") or rawget(button, "Label")
          if type(text) == "table" then text:SetText(data.header) end
          local rank = rawget(button, "RankBar") -- the profession's skill bar of a category
          if type(rank) == "table" and rank.Hide then rank:Hide() end
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
          if type(selected) == "table" then selected:SetShown(split.selected == data) end
          button:SetScript("OnEnter", function(b)
            local h = rawget(b, "HighlightOverlay")
            if type(h) == "table" then h:Show() end
          end)
          button:SetScript("OnLeave", function(b)
            local h = rawget(b, "HighlightOverlay")
            if type(h) == "table" then h:Hide() end
          end)
          button:SetScript("OnClick", function()
            split.selected = data
            box:ForEachFrame(function(other)
              local o = rawget(other, "SelectedOverlay")
              if type(o) == "table" then o:SetShown(other == button) end
            end)
            if opts.onSelect then ns.Safe(opts.onSelect, data, card) end
          end)
        end)
      end
    end)
    view:SetElementExtentCalculator(function(_, data) return data.header and 25 or 20 end)
    ScrollUtil.InitScrollBoxListWithScrollBar(box, bar, view)
  end
  function split.SetEntries(entries)
    if type(box) == "table" and box.SetDataProvider and CreateDataProvider then
      box:SetDataProvider(CreateDataProvider(entries or {}))
    end
    for _, e in ipairs(entries or {}) do
      if not e.header then
        split.selected = e
        if opts.onSelect then ns.Safe(opts.onSelect, e, card) end
        break
      end
    end
  end
  if opts.entries then split.SetEntries(opts.entries) end
  return split
end
