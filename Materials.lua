-- Materials: window right of the item detail (ItemDetail.lua) with the materials of a recipe:
-- per material what is needed for N crafts, what the character already holds (bags and bank,
-- ns.db.inventory), what is missing, where it comes from (merchant / auction house) and what the
-- missing part costs right now (ns.Item: merchant price, else cheapest offer). With the auction
-- house open, auction house goods get a buy button: one click asks the server for the price of
-- the missing units, a second click confirms (one purchase per player click, like the sniper).
-- Same look as the detail window it belongs to ("blizzard" native frame or the own one).
local ADDON, ns = ...

local Materials = {}
ns.Materials = Materials

local WIDTH, ROW = 300, 34
local GREEN, RED, MUTED = "|cff5fd38d", "|cffff6b6b", "|cff999999"

local frame, rows, recipeID, teaches, crafts = nil, {}, nil, nil, 1
local pending -- { itemID, units, quoted, total } of the purchase in progress
local note    -- status line (price asked, bought, failed)
local api = C_AuctionHouse or {}

local function money(c) return ns.FormatMoney(c, true) end

local function ahOpen()
  return ns.AHSearch and ns.AHSearch.IsOpen and ns.AHSearch.IsOpen() or false
end

-- Units of `id` in bags and bank of this character.
local function held(id)
  local key = ns.CharKey and ns.CharKey()
  local inv = key and ns.db and ns.db.inventory and ns.db.inventory[key]
  local n = 0
  for _, part in ipairs({ inv and inv.bags or {}, inv and inv.bank or {} }) do
    local e = part[id]
    if e then n = n + (e.n or 0) end
  end
  return n
end

-- Goods sold per unit (commodities) can be bought by quantity; others not from here.
local function isCommodity(id)
  if api.GetItemCommodityStatus and Enum and Enum.ItemCommodityStatus then
    local ok, status = pcall(api.GetItemCommodityStatus, id)
    if ok and status == Enum.ItemCommodityStatus.Item then return false end
    if ok and status == Enum.ItemCommodityStatus.Commodity then return true end
  end
  local getInstant = (C_Item and C_Item.GetItemInfoInstant) or GetItemInfoInstant
  local classID = getInstant and select(6, getInstant(id))
  return classID == 7 -- trade goods
end

-- The rows: { id, need, have, missing, unit, total, vendor, commodity }.
function Materials.Rows(list, n)
  local out = {}
  for i = 1, #(list or {}), 2 do
    local id, per = list[i], list[i + 1] or 1
    local item = ns.Item(id)
    local unit, vendor = ns.Item.BuyCost(item)
    local need = per * n
    local have = held(id)
    local missing = math.max(0, need - have)
    out[#out + 1] = { id = id, need = need, have = have, missing = missing, unit = unit,
      total = unit and unit * missing or nil, vendor = vendor or false, commodity = not vendor and isCommodity(id) }
  end
  return out
end

-- Buying ---------------------------------------------------------------------------------

local function buy(r)
  if not ahOpen() then return end
  if pending and pending.itemID == r.id and pending.quoted then
    api.ConfirmCommoditiesPurchase(r.id, pending.units)
    pending.confirmed = true
    note = "Kauf bestätigt …"
    return Materials.Refresh()
  end
  if pending then note = "Erst den laufenden Kauf abschließen."; return Materials.Refresh() end
  if r.missing <= 0 then return end
  if r.total and r.total > GetMoney() then note = RED .. "Nicht genug Gold.|r"; return Materials.Refresh() end
  pending = { itemID = r.id, units = r.missing }
  api.StartCommoditiesPurchase(r.id, r.missing)
  note = "Preis wird angefragt …"
  Materials.Refresh()
end

if ns.On then
  ns.On("COMMODITY_PRICE_UPDATED", function(_, unitPrice, totalPrice)
    if not pending or pending.quoted then return end
    pending.quoted, pending.total = true, totalPrice
    note = string.format("%d× für %s – nochmal klicken zum Bestätigen.", pending.units, money(totalPrice))
    Materials.Refresh()
  end)
  ns.On("COMMODITY_PRICE_UNAVAILABLE", function()
    if not pending then return end
    pending, note = nil, RED .. "Preis nicht verfügbar.|r"
    Materials.Refresh()
  end)
  ns.On("COMMODITY_PURCHASE_SUCCEEDED", function()
    if not pending then return end
    note = GREEN .. "Gekauft: " .. pending.units .. "× " .. (ns.ItemName(pending.itemID) or "") .. "|r"
    pending = nil
    Materials.Refresh()
  end)
  ns.On("COMMODITY_PURCHASE_FAILED", function()
    if not pending then return end
    pending, note = nil, RED .. "Kauf fehlgeschlagen.|r"
    Materials.Refresh()
  end)
  ns.On("AUCTION_HOUSE_CLOSED", function()
    if pending and api.CancelCommoditiesPurchase then pcall(api.CancelCommoditiesPurchase) end
    pending = nil
  end)
  -- bags change after a purchase: what is held and missing changes too
  ns.On("BAG_UPDATE_DELAYED", function() if frame and frame:IsShown() then Materials.Refresh() end end)
end

-- Window ---------------------------------------------------------------------------------

local function newRow(i)
  local r = CreateFrame("Button", nil, frame.body)
  r:SetHeight(ROW)
  r:SetPoint("TOPLEFT", frame.body, "TOPLEFT", 0, -(i - 1) * ROW)
  r:SetPoint("RIGHT", frame.body, "RIGHT", 0, 0)
  r.icon = r:CreateTexture(nil, "ARTWORK")
  r.icon:SetSize(24, 24)
  r.icon:SetPoint("LEFT", 2, 0)
  r.name = r:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
  r.name:SetPoint("TOPLEFT", r.icon, "TOPRIGHT", 6, 1)
  r.name:SetPoint("RIGHT", r, "RIGHT", -84, 0)
  r.name:SetJustifyH("LEFT")
  r.name:SetWordWrap(false)
  r.info = r:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
  r.info:SetPoint("TOPLEFT", r.name, "BOTTOMLEFT", 0, -2)
  r.info:SetPoint("RIGHT", r, "RIGHT", -84, 0)
  r.info:SetJustifyH("LEFT")
  r.info:SetWordWrap(false)
  local okB, b = pcall(CreateFrame, "Button", nil, r, "UIPanelButtonTemplate")
  if not okB then b = CreateFrame("Button", nil, r) end
  b:SetSize(78, 22)
  b:SetPoint("RIGHT", -2, 0)
  r.buy = b
  r:SetScript("OnEnter", function(self)
    if not self.row then return end
    GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
    GameTooltip:SetItemByID(self.row.id)
    GameTooltip:Show()
  end)
  r:SetScript("OnLeave", function() GameTooltip:Hide() end)
  r:SetScript("OnMouseUp", function(self, button)
    if button == "LeftButton" and self.row and ns.ItemDetail then ns.ItemDetail.AltClick(self.row.id) end
  end)
  return r
end

local function create()
  local okF, f = pcall(CreateFrame, "Frame", "M4CompanionMaterials", UIParent, "ButtonFrameTemplate")
  if not okF then f = CreateFrame("Frame", "M4CompanionMaterials", UIParent) end
  frame = f
  f:SetWidth(WIDTH)
  f:SetFrameStrata("HIGH")
  f:EnableMouse(true)
  if ButtonFrameTemplate_HidePortrait then pcall(ButtonFrameTemplate_HidePortrait, f) end
  if ButtonFrameTemplate_HideButtonBar then pcall(ButtonFrameTemplate_HideButtonBar, f) end
  local container = rawget(f, "TitleContainer")
  local title = rawget(f, "TitleText") or (type(container) == "table" and rawget(container, "TitleText"))
  if type(title) == "table" then title:SetText("Material") end
  local close = rawget(f, "CloseButton")
  if type(close) == "table" then close:SetScript("OnClick", function() Materials.Hide(true) end) end
  local inset = rawget(f, "Inset")
  if type(inset) == "table" then
    inset:ClearAllPoints()
    inset:SetPoint("TOPLEFT", 4, -64)
    inset:SetPoint("BOTTOMRIGHT", -6, 6)
  end
  -- head: recipe name and the number of crafts (- n +)
  f.head = f:CreateFontString(nil, "OVERLAY", "GameFontNormal")
  f.head:SetPoint("TOPLEFT", 14, -32)
  f.head:SetPoint("RIGHT", f, "RIGHT", -96, 0)
  f.head:SetJustifyH("LEFT")
  f.head:SetWordWrap(false)
  local function stepper(label, delta)
    local okB, b = pcall(CreateFrame, "Button", nil, f, "UIPanelButtonTemplate")
    if not okB then b = CreateFrame("Button", nil, f) end
    b:SetSize(22, 20)
    b:SetText(label)
    b:SetScript("OnClick", function()
      crafts = math.max(1, math.min(200, crafts + delta * (IsShiftKeyDown and IsShiftKeyDown() and 10 or 1)))
      Materials.Refresh()
    end)
    return b
  end
  f.plus = stepper("+", 1)
  f.plus:SetPoint("TOPRIGHT", -14, -30)
  f.count = f:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
  f.count:SetPoint("RIGHT", f.plus, "LEFT", -6, 0)
  f.count:SetWidth(34)
  f.minus = stepper("–", -1)
  f.minus:SetPoint("RIGHT", f.count, "LEFT", -6, 0)
  f.body = CreateFrame("Frame", nil, f)
  f.body:SetPoint("TOPLEFT", 12, -70)
  f.body:SetPoint("RIGHT", f, "RIGHT", -12, 0)
  f.body:SetHeight(1)
  f.total = f:CreateFontString(nil, "OVERLAY", "GameFontNormal")
  f.total:SetJustifyH("LEFT")
  f.note = f:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
  f.note:SetJustifyH("LEFT")
  f.note:SetWordWrap(true)
  f:Hide()
end

function Materials.Refresh()
  if not (frame and frame:IsShown() and teaches) then return end
  local list = Materials.Rows(teaches.reagents, crafts)
  frame.head:SetText(teaches.name or ns.ItemName(teaches.product or 0) or "")
  frame.count:SetText(crafts .. "×")
  local getIcon = (C_Item and C_Item.GetItemIconByID) or GetItemIcon
  local open, sum, unknown = ahOpen(), 0, false
  for i, r in ipairs(list) do
    local row = rows[i] or newRow(i)
    rows[i] = row
    row.row = r
    row.icon:SetTexture(getIcon and getIcon(r.id) or nil)
    row.name:SetText(string.format("%d× %s", r.need, ns.ItemName(r.id) or ("#" .. r.id)))
    local src = r.vendor and "Händler" or "AH"
    local info
    if r.missing == 0 then
      info = GREEN .. "vorhanden|r" .. MUTED .. string.format("  (hast %d)", r.have) .. "|r"
    elseif r.unit then
      info = string.format("fehlt %d  ·  %s %s", r.missing, src, money(r.total))
        .. (r.have > 0 and (MUTED .. string.format("  (hast %d)", r.have) .. "|r") or "")
      sum = sum + r.total
    else
      info = string.format("fehlt %d  ·  ", r.missing) .. RED .. "kein Preis|r"
      unknown = true
    end
    row.info:SetText(info)
    local canBuy = open and r.commodity and r.missing > 0 and r.unit ~= nil
    row.buy:SetShown(canBuy)
    if canBuy then
      local mine = pending and pending.itemID == r.id
      row.buy:SetText(mine and (pending.quoted and "Bestätigen" or "…") or "Kaufen")
      row.buy:SetEnabled(not pending or mine)
      row.buy:SetScript("OnClick", function() ns.Safe(buy, r) end)
    end
    row:Show()
  end
  for i = #list + 1, #rows do rows[i]:Hide(); rows[i].row = nil end
  local h = #list * ROW
  frame.total:ClearAllPoints()
  frame.total:SetPoint("TOPLEFT", frame.body, "TOPLEFT", 2, -h - 10)
  frame.total:SetText("Fehlt noch: " .. (sum > 0 and money(sum) or "–") .. (unknown and (MUTED .. "  (ohne Preis)|r") or ""))
  frame.note:ClearAllPoints()
  frame.note:SetPoint("TOPLEFT", frame.total, "BOTTOMLEFT", 0, -6)
  frame.note:SetPoint("RIGHT", frame, "RIGHT", -14, 0)
  frame.note:SetText(note or (open and "" or (MUTED .. "Kaufen geht am Auktionshaus.|r")))
end

-- Shows the materials of `teaches` (Crafting.lua RecipeTeaches entry) right of `anchor`.
function Materials.Show(recipe, t, anchor, skinName)
  if not t or not t.reagents then return Materials.Hide() end
  if not frame then create() end
  if Materials.dismissed == recipe then return end -- closed with × for this recipe
  if recipeID ~= recipe then crafts, note = 1, nil end
  recipeID, teaches = recipe, t
  frame:ClearAllPoints()
  frame:SetPoint("TOPLEFT", anchor, "TOPRIGHT", -2, 0)
  frame:SetPoint("BOTTOMLEFT", anchor, "BOTTOMRIGHT", -2, 0)
  frame:Show()
  Materials.Refresh()
end

function Materials.Hide(byPlayer)
  if byPlayer then Materials.dismissed = recipeID end
  if frame then frame:Hide() end
  if not byPlayer then Materials.dismissed = nil end
end
