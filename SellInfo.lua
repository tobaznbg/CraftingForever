-- SellInfo: two rows in Blizzard's "Auktion erstellen" (auction house tab "Verkaufen"), right
-- under "Gesamtpreis" and in its style, recomputed while the price or quantity is typed:
--   Einstand   1g 96s 26c          (cost of the units, ns.Profit.UnitCost x quantity)
--   Gewinn    -49s 80c             (total price after the 5 % cut minus that cost; green/red)
-- Without a known cost: "Einstand  unbekannt", no profit row. The post button moves below the
-- rows. Only reads Blizzard's frames, never posts or changes a price.
-- Pilot: while the sell slot holds an item, the item detail window (ItemDetail.lua) docks at
-- the auction house frame in the native Blizzard look, and the own Selling panel steps aside.
local ADDON, ns = ...

local SellInfo = {}
ns.SellInfo = SellInfo

local CUT = 0.05
local ROW_H = 24

local function money(c) return ns.FormatMoney(c) end

-- The item id in a sell frame, nil when the slot is empty: the location Blizzard put in with
-- SetItem (hooked in attach), else the frame's GetItem.
local function itemOf(frame)
  local location = frame.m4Location
  if location == nil and frame.GetItem then
    local ok, loc = pcall(frame.GetItem, frame)
    location = ok and loc or nil
  end
  if not location then return nil end
  if type(location) == "table" and location.IsValid and not location:IsValid() then return nil end
  local getID = C_Item and C_Item.GetItemID
  if not getID then return nil end
  local ok, id = pcall(getID, location)
  return ok and id or nil
end

-- The unit price entered (copper), nil when none.
local function unitPriceOf(frame)
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

-- The quantity entered, 1 when it cannot be read.
local function quantityOf(frame)
  for _, get in ipairs({
    function() return frame:GetQuantity() end,
    function() return frame.QuantityInput:GetQuantity() end,
    function() return frame.QuantityInput.InputBox:GetNumber() end,
  }) do
    local ok, n = pcall(get)
    if ok and type(n) == "number" and n > 0 then return n end
  end
  return 1
end

-- The two values for item `id`, unit price `price` (nil: none yet) and `qty` units:
-- costText, profitText (nil: no profit row). Nothing at all without an item.
function SellInfo.Values(id, price, qty)
  if not (id and ns.Profit and ns.Profit.UnitCost) then return nil end
  local cost = ns.Profit.UnitCost(id)
  if not cost then return "|cff999999unbekannt|r", nil end
  qty = qty or 1
  local total = math.floor(cost * qty + 0.5)
  if not price then return money(total), nil end
  local profit = math.floor(price * qty * (1 - CUT) - total)
  local text = profit >= 0 and ("|cff5fd38d" .. money(profit) .. "|r") or ("|cffff6b6b-" .. money(-profit) .. "|r")
  return money(total), text
end

-- One row like Blizzard's: label right-aligned in the label column, value left in the value column.
local function newRow(holder, frame, labelText, index)
  local total = frame.TotalPrice
  local label = holder:CreateFontString(nil, "OVERLAY", "GameFontNormal")
  local value = holder:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
  label:SetText(labelText)
  label:SetJustifyH("RIGHT")
  value:SetJustifyH("LEFT")
  local y = -(index - 1) * ROW_H - 10
  if total and total.Label then
    label:SetPoint("TOPRIGHT", total.Label, "BOTTOMRIGHT", 0, y)
  elseif total then
    label:SetPoint("TOPLEFT", total, "BOTTOMLEFT", 0, y)
  else
    label:SetPoint("BOTTOMLEFT", frame.PostButton or frame, "TOPLEFT", 0, -y)
  end
  local valueAnchor = total and (total.MoneyDisplayFrame or total.MoneyFrame)
  if valueAnchor then
    value:SetPoint("TOPLEFT", valueAnchor, "BOTTOMLEFT", 0, y)
  else
    value:SetPoint("LEFT", label, "RIGHT", 18, 0)
  end
  return { label = label, value = value }
end

-- The detail window of the item in the sell slot (nil: none), native look, docked at the AH.
local DETAIL_ORIGIN = "ahsell"
local opened -- item the window was opened for: closed with × it stays closed for that item
local function syncDetail(id)
  local Detail = ns.ItemDetail
  if not Detail then return end
  local mine = Detail.Origin and Detail.Origin() == DETAIL_ORIGIN
  if id then
    if mine and Detail.ItemID() == id then return end
    if id == opened and not Detail.IsShown() then return end -- closed by the player
    opened = id
    Detail.Show(id, { anchor = AuctionHouseFrame, origin = DETAIL_ORIGIN, skin = "blizzard" })
  else
    opened = nil
    if mine then Detail.Hide() end
  end
end

-- The own Selling panel (Verkaufen/Sniper/Auktionen) steps aside while the sell frame shows.
local function sellingPanel(show)
  local panel = ns.Selling and ns.Selling.Frame and ns.Selling.Frame()
  if not panel then return end
  if show then
    if not ns.Selling.ENABLED then return end
    if AuctionHouseFrame and AuctionHouseFrame:IsShown() and not panel:IsShown() then
      panel:Show()
      if ns.Selling.Refresh then ns.Safe(ns.Selling.Refresh) end
    end
  elseif panel:IsShown() then
    panel:Hide()
  end
end

local function attach(frame)
  if not frame or frame.m4SellInfo then return end
  -- Own layer above Blizzard's inset frames (a text on the sell frame itself lies under them).
  local holder = CreateFrame("Frame", nil, frame)
  holder:SetAllPoints(frame)
  holder:SetFrameStrata(frame:GetFrameStrata())
  holder:SetFrameLevel(frame:GetFrameLevel() + 50)
  local rows = { newRow(holder, frame, "Einstand", 1), newRow(holder, frame, "Gewinn", 2) }
  frame.m4SellInfo = holder
  -- Layout check: what "Gesamtpreis" consists of in this client (saved variables).
  if ns.db and frame.TotalPrice then
    local keys = {}
    for k, v in pairs(frame.TotalPrice) do
      if type(v) == "table" and v.GetObjectType then keys[#keys + 1] = tostring(k) .. ":" .. v:GetObjectType() end
    end
    table.sort(keys)
    ns.db.sellInfoLayout = table.concat(keys, ", ")
  end
  if frame.SetItem then
    hooksecurefunc(frame, "SetItem", function(self, itemLocation) self.m4Location = itemLocation end)
  end
  -- The post button sits below the last shown row. Blizzard places it again when the frame
  -- shows (and on its own layout changes), so every check moves it again when needed.
  local button = frame.PostButton
  local function placeButton()
    if not (button and button.GetPoint and button:GetNumPoints() > 0) then return end
    local last = rows[2].label:IsShown() and rows[2].label or rows[1].label
    if not last:IsShown() then return end
    local top, bottom = button:GetTop(), last:GetBottom()
    if not (top and bottom) then return end
    local overlap = top - (bottom - 8)
    if overlap > 0.5 then
      local p, rel, rp, x, y = button:GetPoint(1)
      button:ClearAllPoints()
      button:SetPoint(p, rel, rp, x, (y or 0) - overlap)
    end
  end
  local function show(costText, profitText)
    rows[1].label:SetShown(costText ~= nil)
    rows[1].value:SetText(costText or "")
    rows[2].label:SetShown(profitText ~= nil)
    rows[2].value:SetText(profitText or "")
  end
  show(nil, nil)
  -- Price, quantity and item change while the frame is open: a light check five times a second.
  local elapsed, lastKey = 0, nil
  local function tick()
    local id, price, qty = itemOf(frame), unitPriceOf(frame), quantityOf(frame)
    local key = tostring(id) .. ":" .. tostring(price) .. ":" .. tostring(qty)
    if key ~= lastKey then
      lastKey = key
      show(SellInfo.Values(id, price, qty))
    end
    placeButton()
    sellingPanel(false)
    syncDetail(id)
  end
  holder:SetScript("OnUpdate", function(_, dt)
    elapsed = elapsed + (dt or 0)
    if elapsed < 0.2 then return end
    elapsed = 0
    ns.Safe(tick)
  end)
  holder:SetScript("OnHide", function()
    lastKey = nil
    ns.Safe(syncDetail, nil)
    ns.Safe(sellingPanel, true)
  end)
end

-- Blizzard's tab "Auktionen": in each own auction's row, in the (empty) bid price column,
-- what one unit cost and what the auction brings after the cut:
--   Einstand 2g 88s
--   Gewinn +2g 81s        (green / red; nothing without a known cost or with a bid shown)
local function auctionsList(af)
  return rawget(af, "AllAuctionsList") or rawget(af, "ItemList")
end

local function forEachRow(list, fn)
  local box = rawget(list, "ScrollBox")
  if type(box) == "table" and box.ForEachFrame then
    box:ForEachFrame(fn)
    return
  end
  local sf = rawget(list, "ScrollFrame")
  for _, row in ipairs(type(sf) == "table" and rawget(sf, "buttons") or {}) do fn(row) end
end

local function rowData(row)
  local d = rawget(row, "rowData")
  if d == nil and row.GetRowData then
    local ok, v = pcall(row.GetRowData, row)
    d = ok and v or nil
  end
  if d == nil and row.GetElementData then
    local ok, v = pcall(row.GetElementData, row)
    d = ok and v or nil
  end
  return type(d) == "table" and d or nil
end

local function rowText(row)
  if row.m4Info then return row.m4Info end
  local layer = CreateFrame("Frame", nil, row)
  layer:SetAllPoints(row)
  layer:SetFrameLevel((row:GetFrameLevel() or 1) + 5)
  local fs = layer:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
  fs:SetJustifyH("RIGHT")
  local cells = rawget(row, "cells")
  local cell = type(cells) == "table" and cells[2]
  if type(cell) == "table" and cell.GetObjectType then
    fs:SetPoint("RIGHT", cell, "RIGHT", -4, 0)
  else
    -- no cells table: the bid column starts right of the item name (about 62 % of the row)
    fs:SetPoint("RIGHT", row, "LEFT", (row:GetWidth() or 560) * 0.66, 0)
  end
  row.m4Info = fs
  return fs
end

function SellInfo.AuctionText(id, unit, qty)
  if not (id and unit and unit > 0 and ns.Profit and ns.Profit.UnitCost) then return nil end
  local cost = ns.Profit.UnitCost(id)
  if not cost then return nil end
  qty = qty or 1
  local profit = math.floor((unit * (1 - CUT) - cost) * qty)
  local short = function(c) return ns.FormatMoney(c, true) end
  return "|cff999999Einstand " .. short(math.floor(cost + 0.5)) .. "|r\n"
    .. (profit >= 0 and ("|cff5fd38dGewinn +" .. short(profit)) or ("|cffff6b6bGewinn -" .. short(-profit))) .. "|r"
end

local probed = false
local function updateAuctionRows(af)
  local list = auctionsList(af)
  if not list then return end
  forEachRow(list, function(row)
    local d = rowData(row)
    local key = d and d.itemKey
    local id = type(key) == "table" and key.itemID or nil
    local text
    if id and not ((d.bidAmount or 0) > 0) then
      text = SellInfo.AuctionText(id, d.buyoutAmount, d.quantity)
    end
    local fs = row.m4Info
    if text or fs then rowText(row):SetText(text or "") end
    if not probed and ns.db and d then
      probed = true
      local keys = {}
      for k, v in pairs(row) do if type(v) == "table" then keys[#keys + 1] = tostring(k) end end
      table.sort(keys)
      ns.db.auctionsProbe = { row = table.concat(keys, ","), data = (d.buyoutAmount and "buyout " or "") .. (d.quantity and "qty" or ""),
        t = time() }
    end
  end)
end

-- One-time probe of Blizzard's table building blocks in this client (saved variables), for the
-- own columns in the "Auktionen" tab.
local function probeTable(af)
  if not ns.db or (ns.db.tableProbe and ns.db.tableProbe.v == 1) then return end
  local out = { v = 1, t = time() }
  local tb = rawget(_G, "AuctionHouseTableBuilder")
  out.builder = type(tb)
  if type(tb) == "table" then
    local fns = {}
    for k, v in pairs(tb) do if type(v) == "function" then fns[#fns + 1] = k end end
    table.sort(fns)
    out.builderFns = table.concat(fns, ",")
  end
  local keys = {}
  for k, v in pairs(af) do
    if type(v) == "table" and v.GetObjectType then keys[#keys + 1] = tostring(k) end
  end
  table.sort(keys)
  out.auctionsFrame = table.concat(keys, ",")
  local list = auctionsList(af)
  if list then
    out.listSetLayout = list.SetTableBuilderLayout ~= nil
    out.listRefresh = list.RefreshScrollFrame ~= nil
    local lk = {}
    for k, v in pairs(list) do lk[#lk + 1] = tostring(k) .. ":" .. type(v) end
    table.sort(lk)
    out.listKeys = table.concat(lk, ",")
    local builder = rawget(list, "tableBuilder")
    if type(builder) == "table" then
      local bk = {}
      for k, v in pairs(builder) do bk[#bk + 1] = tostring(k) .. ":" .. type(v) end
      local mt = getmetatable(builder)
      local idx = mt and mt.__index
      if type(idx) == "table" then for k in pairs(idx) do bk[#bk + 1] = "mt." .. tostring(k) end end
      table.sort(bk)
      out.tableBuilder = table.concat(bk, ",")
    end
  end
  local info = C_XMLUtil and C_XMLUtil.GetTemplateInfo
  local templates = {}
  for _, name in ipairs({ "AuctionHouseTableCellTemplate", "AuctionHouseTableCellTextTemplate",
      "AuctionHouseTableCellAuctionsItemTemplate", "AuctionHouseTableCellAuctionsBidTemplate",
      "AuctionHouseTableCellAuctionsBuyoutTemplate", "AuctionHouseTableCellTimeLeftTemplate",
      "AuctionHouseTableCellAuctionsTimeLeftTemplate", "AuctionHouseTableHeaderStringTemplate",
      "AuctionHousePriceDisplayTableCellTemplate", "AuctionHouseTableCellMoneyTemplate" }) do
    local ok, ti = pcall(function() return info and info(name) end)
    templates[#templates + 1] = name .. "=" .. tostring(ok and ti ~= nil)
  end
  out.templates = table.concat(templates, ",")
  for _, name in ipairs({ "AuctionHouseTableCellMixin", "AuctionHouseTablePriceCellMixin",
      "AuctionHouseTableCellAuctionsBidMixin", "AuctionHouseTableCellAuctionsBuyoutMixin",
      "AuctionHouseTableCellTextMixin" }) do
    out["mixin_" .. name] = type(rawget(_G, name))
  end
  ns.db.tableProbe = out
end

local function attachAuctions()
  local af = AuctionHouseFrame and rawget(AuctionHouseFrame, "AuctionsFrame")
  if type(af) == "table" then ns.Safe(probeTable, af) end
  if type(af) ~= "table" or af.m4Rows then return end
  local layer = CreateFrame("Frame", nil, af)
  af.m4Rows = layer
  local elapsed = 0
  layer:SetScript("OnUpdate", function(_, dt)
    elapsed = elapsed + (dt or 0)
    if elapsed < 0.3 then return end
    elapsed = 0
    ns.Safe(updateAuctionRows, af)
  end)
end

local function attachAll()
  local ah = AuctionHouseFrame
  if not ah then return end
  attach(ah.ItemSellFrame)
  attach(ah.CommoditiesSellFrame)
  attachAuctions()
end

if ns.On then
  ns.On("AUCTION_HOUSE_SHOW", function()
    attachAll()
    -- The auction house UI loads on demand: its frames may only exist a moment later.
    if C_Timer then C_Timer.After(0.2, function() ns.Safe(attachAll) end) end
  end)
end
