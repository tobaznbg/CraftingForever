-- TradeBook: the ledger ("Handelsbuch") as a window in Blizzard's own look, built like the
-- profession window: portrait and title, a list column on the left (search box, entries) and a
-- details area on the right. Opened with the tab "Handelsbuch" under the auction house (next to
-- Blizzard's tabs) or /m4 buch. First step: the bare frame, no content yet.
local ADDON, ns = ...

local TradeBook = {}
ns.TradeBook = TradeBook

local NAME = "M4CompanionTradeBook"
local WIDTH, HEIGHT = 760, 560
local LIST_WIDTH = 270
local ICON = "Interface\\Icons\\INV_Misc_Book_11"

local frame

local function create()
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
  -- portrait and title the way Blizzard's windows set them
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
  -- the template's own inset is not used: two insets of our own (list, details)
  local inset = rawget(f, "Inset")
  if type(inset) == "table" then inset:Hide() end
  -- drag by the title bar
  f:RegisterForDrag("LeftButton")
  f:SetScript("OnDragStart", function(self) self:StartMoving() end)
  f:SetScript("OnDragStop", function(self) self:StopMovingOrSizing() end)
  -- ESC closes it
  if UISpecialFrames then tinsert(UISpecialFrames, NAME) end

  -- Left: the list column (search box on top, entries below)
  local list = CreateFrame("Frame", nil, f, "InsetFrameTemplate")
  list:SetPoint("TOPLEFT", 8, -64)
  list:SetPoint("BOTTOMLEFT", 8, 28)
  list:SetWidth(LIST_WIDTH)
  f.List = list
  local okS, search = pcall(CreateFrame, "EditBox", NAME .. "Search", f, "SearchBoxTemplate")
  if okS and search then
    search:SetSize(LIST_WIDTH - 12, 20)
    search:SetPoint("BOTTOMLEFT", list, "TOPLEFT", 8, 6)
    f.Search = search
  end

  -- Right: the details area
  local details = CreateFrame("Frame", nil, f, "InsetFrameTemplate")
  details:SetPoint("TOPLEFT", list, "TOPRIGHT", 6, 0)
  details:SetPoint("BOTTOMRIGHT", -8, 28)
  f.Details = details
  -- a quiet background like the profession window's recipe area
  local bg = details:CreateTexture(nil, "BACKGROUND", nil, 1)
  bg:SetPoint("TOPLEFT", 3, -3)
  bg:SetPoint("BOTTOMRIGHT", -3, 3)
  bg:SetColorTexture(0, 0, 0, 0.35)
  f.DetailsBackground = bg

  -- position: centered on first show (moved windows stay where they were dragged)
  f:SetPoint("CENTER", UIParent, "CENTER", 0, 40)
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
