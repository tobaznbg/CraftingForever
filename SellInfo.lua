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

-- The item id in a sell frame, nil when the slot is empty: the location Blizzard put in with
-- SetItem (hooked in attach), else the frame's GetItem where the client has it.
local function itemOf(frame)
  if not frame then return nil end
  local location = frame.m4Location
  if location == nil and frame.GetItem then
    local ok, loc = pcall(frame.GetItem, frame)
    location = ok and loc or nil
  end
  if not location then return nil end
  if type(location) == "table" and location.IsValid and not location:IsValid() then return nil end
  local getID = C_Item and C_Item.GetItemID
  if not getID then return nil end
  local ok2, id = pcall(getID, location)
  return ok2 and id or nil
end

-- The unit price entered in a sell frame (copper), nil when none.
local function unitPriceOf(frame)
  if not frame then return nil end
  if frame.GetUnitPrice then
    local ok, price = pcall(frame.GetUnitPrice, frame)
    if ok and type(price) == "number" and price > 0 then return price end
  end
  local input = frame.PriceInput
  if input and input.GetAmount then
    local ok, price = pcall(input.GetAmount, input)
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
  -- Own layer above Blizzard's inset frames (a text on the sell frame itself lies under them).
  local holder = CreateFrame("Frame", nil, frame)
  holder:SetAllPoints(frame)
  holder:SetFrameStrata(frame:GetFrameStrata())
  holder:SetFrameLevel(frame:GetFrameLevel() + 50)
  local fs = holder:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
  fs:SetJustifyH("LEFT")
  fs:SetWidth(300)
  if frame.PostButton then
    fs:SetPoint("TOPLEFT", frame.PostButton, "BOTTOMLEFT", -40, -10)
  else
    fs:SetPoint("BOTTOMLEFT", frame, "BOTTOMLEFT", 20, 40)
  end
  frame.m4SellInfo = fs
  if frame.SetItem then
    hooksecurefunc(frame, "SetItem", function(self, itemLocation) self.m4Location = itemLocation end)
  end
  -- What this client offers (read once from the saved variables when something is missing).
  if ns.db then
    ns.db.sellInfoProbe = ns.db.sellInfoProbe or {}
    ns.db.sellInfoProbe[tostring(frame:GetName() or (frame == (AuctionHouseFrame and AuctionHouseFrame.ItemSellFrame) and "item" or "commodity"))] = {
      SetItem = frame.SetItem ~= nil, GetItem = frame.GetItem ~= nil, GetUnitPrice = frame.GetUnitPrice ~= nil,
      PriceInput = frame.PriceInput ~= nil, PostButton = frame.PostButton ~= nil, t = time() }
  end
  -- Price and item change while the frame is open: a light check five times a second.
  local elapsed, lastKey = 0, nil
  local function tick(self)
    local id, price = itemOf(self), unitPriceOf(self)
    local key = tostring(id) .. ":" .. tostring(price)
    if key == lastKey then return end
    lastKey = key
    local ok, text = pcall(SellInfo.Text, id, price)
    fs:SetText(ok and text or "")
    if ns.db then ns.db.sellInfoLast = { id = id, price = price, ok = ok, text = ok and text or tostring(text), t = time() } end
  end
  -- The timer runs on the own layer (a child: shown exactly while the sell frame is shown).
  holder:SetScript("OnUpdate", function(_, dt)
    elapsed = elapsed + (dt or 0)
    if elapsed < 0.2 then return end
    elapsed = 0
    ns.Safe(tick, frame)
  end)
  frame:HookScript("OnHide", function() lastKey = nil; fs:SetText("") end)
end

-- Which frames of the auction house are shown (keys and names), recorded every 2 s while it is
-- open: Forever's sell screen is not Blizzard's ItemSellFrame (its OnUpdate never ran).
local function probeShown()
  local ah = AuctionHouseFrame
  if not (ah and ah:IsShown() and ns.db) then return end
  local shown = {}
  for key, v in pairs(ah) do
    if type(v) == "table" and type(v.IsShown) == "function" and type(v.GetObjectType) == "function" then
      local ok, vis = pcall(v.IsShown, v)
      if ok and vis then
        local name = v.GetName and v:GetName() or nil
        shown[#shown + 1] = tostring(key) .. (name and ("=" .. name) or "")
      end
    end
  end
  table.sort(shown)
  local list = ns.db.sellInfoShown or {}
  ns.db.sellInfoShown = list
  local line = table.concat(shown, ", ")
  if list[#list] ~= line then
    list[#list + 1] = line
    while #list > 20 do table.remove(list, 1) end
  end
end

local function attachAll()
  local ah = AuctionHouseFrame
  if not ah then return end
  attach(ah.ItemSellFrame)
  attach(ah.CommoditiesSellFrame)
end

if ns.On then
  ns.On("AUCTION_HOUSE_CLOSED", function()
    if SellInfo.ticker then SellInfo.ticker:Cancel(); SellInfo.ticker = nil end
  end)
  ns.On("AUCTION_HOUSE_SHOW", function()
    attachAll()
    -- The auction house UI loads on demand: its frames may only exist a moment later.
    if C_Timer then C_Timer.After(0.2, function() ns.Safe(attachAll) end) end
    if C_Timer and C_Timer.NewTicker and not SellInfo.ticker then
      SellInfo.ticker = C_Timer.NewTicker(2, function() ns.Safe(probeShown) end)
    end
  end)
end
