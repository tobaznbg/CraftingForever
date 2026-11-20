-- Minimap: round button at the minimap edge (like other addons), draggable around it.
-- Left click: m4-companion window; right click: trading ledger. The tooltip shows how
-- current the data is. Position saved in ns.db.minimap.angle.
local ADDON, ns = ...

local RADIUS_PAD = 5
local button

local function place()
  local angle = math.rad(ns.db.minimap.angle or 210)
  local r = (Minimap:GetWidth() / 2) + RADIUS_PAD
  button:ClearAllPoints()
  button:SetPoint("CENTER", Minimap, "CENTER", math.cos(angle) * r, math.sin(angle) * r)
end

local function create()
  ns.db.minimap = ns.db.minimap or {}
  if ns.db.minimap.hide then return end
  button = CreateFrame("Button", "M4CompanionMinimapButton", Minimap)
  button:SetSize(31, 31)
  button:SetFrameStrata("MEDIUM")
  button:SetFrameLevel(8)
  button:RegisterForClicks("LeftButtonUp", "RightButtonUp")
  button:RegisterForDrag("LeftButton")
  button:SetHighlightTexture("Interface\\Minimap\\UI-Minimap-ZoomButton-Highlight")

  local bg = button:CreateTexture(nil, "BACKGROUND")
  bg:SetSize(20, 20)
  bg:SetPoint("CENTER")
  bg:SetColorTexture(0.08, 0.08, 0.09, 1)
  local icon = button:CreateTexture(nil, "ARTWORK")
  icon:SetSize(22, 22)
  icon:SetPoint("CENTER")
  icon:SetTexture("Interface\\AddOns\\m4-companion\\media\\emblem")
  local border = button:CreateTexture(nil, "OVERLAY")
  border:SetSize(53, 53)
  border:SetPoint("TOPLEFT")
  border:SetTexture("Interface\\Minimap\\MiniMap-TrackingBorder")

  button:SetScript("OnClick", function(_, mouse)
    -- for now (pilot): left click the ledger window in Blizzard's look, right click the main window
    if mouse == "RightButton" then
      if ns.MainUI then ns.Safe(ns.MainUI.Toggle) else ns.Safe(ns.PlannerUI.Toggle) end
    elseif IsShiftKeyDown() and ns.ShoppingList then
      ns.Safe(ns.ShoppingList.Toggle) -- also for a character without the profession (bank)
    elseif ns.TradeBook then
      ns.Safe(ns.TradeBook.Toggle)
    elseif ns.MainUI then
      ns.Safe(ns.MainUI.Toggle)
    end
  end)
  button:SetScript("OnDragStart", function(self)
    self:SetScript("OnUpdate", function()
      local mx, my = Minimap:GetCenter()
      local scale = Minimap:GetEffectiveScale()
      local cx, cy = GetCursorPosition()
      ns.db.minimap.angle = math.deg(math.atan2(cy / scale - my, cx / scale - mx))
      place()
    end)
  end)
  button:SetScript("OnDragStop", function(self) self:SetScript("OnUpdate", nil) end)
  button:SetScript("OnEnter", function(self)
    GameTooltip:SetOwner(self, "ANCHOR_LEFT")
    GameTooltip:AddLine("m4-companion")
    GameTooltip:AddLine(ns.Status.Text(), 0.8, 0.8, 0.8)
    GameTooltip:AddLine("Linksklick: Handelsbuch  ·  Rechtsklick: Fenster", 0.6, 0.6, 0.6)
    GameTooltip:AddLine("Shift+Linksklick: Einkaufsliste", 0.6, 0.6, 0.6)
    GameTooltip:Show()
  end)
  button:SetScript("OnLeave", function() GameTooltip:Hide() end)
  place()
end

ns.OnReady(function() ns.Safe(create) end)
