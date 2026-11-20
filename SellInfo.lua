-- SellInfo: under Blizzard's "Auktion erstellen" (auction house tab "Verkaufen") what the item
-- in the sell slot cost the player and what the entered price leaves after the 5 % cut:
--   M4 Einstand 98s 13c (hergestellt) · ohne Verlust ab 1g 03s
--      bei 77s 09c: -24s 89c je Stück
-- Cost from ns.Profit.UnitCost (ledger), nothing of its own. Only reads Blizzard's frames,
-- never posts or changes anything there.
local ADDON, ns = ...

local SellInfo = {}
ns.SellInfo = SellInfo

local CUT = 0.05

local function money(c) return ns.FormatMoney(c, true) end

-- The item id in a sell frame, nil when the slot is empty.
local function itemOf(frame)
  if not (frame and frame.GetItem) then return nil end
  local ok, location = pcall(frame.GetItem, frame)
  if not ok or not location then return nil end
  if type(location) == "table" and location.IsValid and not location:IsValid() then return nil end
  local getID = C_Item and C_Item.GetItemID
  if not getID then return nil end
  local ok2, id = pcall(getID, location)
  return ok2 and id or nil
end

-- The unit price entered in a sell frame (copper), nil when none.
local function unitPriceOf(frame)
  if frame and frame.GetUnitPrice then
    local ok, price = pcall(frame.GetUnitPrice, frame)
    if ok and type(price) == "number" and price > 0 then return price end
  end
  return nil
end

-- The text for item `id` at unit price `price` (nil: no price entered yet); nil without a cost.
function SellInfo.Text(id, price)
  if not (id and ns.Profit and ns.Profit.UnitCost) then return nil end
  local cost, source = ns.Profit.UnitCost(id)
  local Style = ns.Style
  local muted, green, red = Style and Style.MUTED or "|cff999999", "|cff5fd38d", "|cffff6b6b"
  local head = "|cff4fc2a1M4|r "
  if not cost then
    return head .. muted .. "Einstand unbekannt – kein Kauf oder Herstellung erfasst|r"
  end
  local text = head .. "Einstand " .. money(math.floor(cost + 0.5)) .. muted .. " (" .. source .. ")"
    .. "  ·  ohne Verlust ab " .. money(ns.Profit.BreakEven(cost)) .. "|r"
  if price then
    local per = math.floor(price * (1 - CUT) - cost)
    text = text .. "\n" .. muted .. "bei " .. money(price) .. ": |r"
      .. (per >= 0 and (green .. "+" .. money(per)) or (red .. "-" .. money(-per))) .. "|r"
      .. muted .. " je Stück nach Gebühr|r"
  end
  return text
end

local function attach(frame)
  if not frame or frame.m4SellInfo then return end
  local fs = frame:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
  fs:SetJustifyH("LEFT")
  fs:SetWidth(300)
  if frame.PostButton then
    fs:SetPoint("TOPLEFT", frame.PostButton, "BOTTOMLEFT", -40, -10)
  else
    fs:SetPoint("BOTTOMLEFT", frame, "BOTTOMLEFT", 20, 40)
  end
  frame.m4SellInfo = fs
  -- Price and item change while the frame is open: a light check five times a second.
  local elapsed, lastKey = 0, nil
  frame:HookScript("OnUpdate", function(self, dt)
    elapsed = elapsed + (dt or 0)
    if elapsed < 0.2 then return end
    elapsed = 0
    local id, price = itemOf(self), unitPriceOf(self)
    local key = tostring(id) .. ":" .. tostring(price)
    if key == lastKey then return end
    lastKey = key
    local ok, text = pcall(SellInfo.Text, id, price)
    fs:SetText(ok and text or "")
  end)
  frame:HookScript("OnHide", function() lastKey = nil; fs:SetText("") end)
end

if ns.On then
  ns.On("AUCTION_HOUSE_SHOW", function()
    local ah = AuctionHouseFrame
    if not ah then return end
    attach(ah.ItemSellFrame)
    attach(ah.CommoditiesSellFrame)
  end)
end
