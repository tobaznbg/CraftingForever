-- ShoppingList: "Einkaufsliste" - items to make several times (to sell, to level a friend, …).
-- In the profession window the button "Einkaufsliste" (under the recipe's figures) puts the
-- selected recipe with the count of Blizzard's number box on the list and opens the window:
-- left the wished items ("Alles zusammen" on top), right per reagent what is needed, what the
-- household has (bags and bank of every character of the realm and faction, ns.Ledger.Household),
-- what is missing and what that costs.
--
-- Plan (List.Plan): per reagent the household's stock is used first; for the rest an
-- intermediate the character can make (a learned recipe of its scans) is made when that is
-- cheaper than buying it (up to MAX_DEPTH levels), else it is bought (ns.Item.BuyCost: merchant,
-- else the cheapest offer). The wished item's own stock is not counted (they are to be made).
--
-- Saved in ns.db.shopping = { { rid = recipe (spell) id, out = item, name, pid, n = count }, … },
-- ns.db.shoppingT = time of the last change: the state sync takes the newest list (Sync.lua).
local ADDON, ns = ...

local List = {}
ns.ShoppingList = List

local MAX_DEPTH = 3
local MAX_ROWS = 14
local RIGHT_EDGE = 24
local GREEN, RED, MUTED = "|cff5fd38d", "|cffff6b6b", "|cff999999"

local function money(c) return ns.FormatMoney(math.floor((c or 0) + 0.5), true) end
local function wishes()
  ns.db.shopping = ns.db.shopping or {}
  return ns.db.shopping
end
local function changed() ns.db.shoppingT = time() end
local function itemIcon(id)
  local get = (C_Item and C_Item.GetItemIconByID) or GetItemIcon
  return id and get and get(id) or nil
end
local function qualityName(id, name)
  local q = C_Item and C_Item.GetItemQualityByID and C_Item.GetItemQualityByID(id)
  local c = q and ITEM_QUALITY_COLORS and ITEM_QUALITY_COLORS[q]
  return c and c.hex and (c.hex .. name .. "|r") or name
end

-- Recipes of the household's profession scans --------------------------------------------------
-- The list is the account's (ns.db), so a bank character sees it too: recipes and
-- intermediates come from the scans of every household character, the playing one first.

local function ownScans()
  local me = ns.CharKey()
  local keys = ns.Ledger and ns.Ledger.Household and ns.Ledger.Household() or { me }
  local out = {}
  for _, char in ipairs(keys) do
    local prefix = char .. ":"
    for key, scan in pairs(ns.db and ns.db.recipes or {}) do
      if key:sub(1, #prefix) == prefix and type(scan.recipes) == "table" then
        if char == me then table.insert(out, 1, scan) else out[#out + 1] = scan end
      end
    end
  end
  return out
end

-- A recipe (spell id) of the scans: recipe { r = { { i, n }… }, out, qmin, qmax }, its scan.
local function scanRecipe(rid)
  for _, scan in ipairs(ownScans()) do
    local r = scan.recipes[rid]
    if r then return r, scan end
  end
  return nil
end

-- The learned recipe that makes an item (an intermediate), or nil.
local function maker(itemID)
  for _, scan in ipairs(ownScans()) do
    for rid, r in pairs(scan.recipes) do
      if r.learned and r.out == itemID and r.r and #r.r > 0 then return { rid = rid, r = r } end
    end
  end
  return nil
end

local function made(r) return ((r.qmin or 1) + (r.qmax or r.qmin or 1)) / 2 end

-- Stock of the household -----------------------------------------------------------------------

-- Bags and bank of every household character: total and { { char, n }… }. The playing one live
-- (GetItemCount with bank), the others from their stored inventory.
local function holdings(itemID)
  local me = ns.CharKey()
  local keys = ns.Ledger and ns.Ledger.Household and ns.Ledger.Household() or { me }
  local total, parts = 0, {}
  for _, key in ipairs(keys) do
    local n = 0
    local inv = ns.db.inventory and ns.db.inventory[key]
    for _, place in ipairs({ inv and inv.bags or {}, inv and inv.bank or {} }) do
      local e = place[itemID]
      if e then n = n + (e.n or 0) end
    end
    if key == me then
      local count = (C_Item and C_Item.GetItemCount) or GetItemCount
      if count then n = math.max(n, count(itemID, true) or 0) end
    end
    if n > 0 then
      total = total + n
      parts[#parts + 1] = { key:match("^([^-]+)") or key, n }
    end
  end
  return total, parts
end
List.Holdings = holdings

-- Prices ---------------------------------------------------------------------------------------

-- Cheapest way to one unit: buying or making it (learned recipe, its reagents the same way).
-- Returns the cost per unit and whether making it is cheaper; nil when neither has a price.
local function unitCost(itemID, depth, seen)
  local buy = ns.Item.BuyCost(ns.Item(itemID))
  local craft
  local m = depth < MAX_DEPTH and not seen[itemID] and maker(itemID)
  if m then
    seen[itemID] = true
    local sum = 0
    for _, g in ipairs(m.r.r) do
      local c = g.i and unitCost(g.i, depth + 1, seen)
      if not c then sum = nil break end
      sum = sum + c * (g.n or 1)
    end
    seen[itemID] = nil
    if sum then craft = sum / made(m.r) end
  end
  if craft and (not buy or craft < buy) then return craft, true end
  return buy, false
end

-- The plan ---------------------------------------------------------------------------------------

-- Plan for a list of wishes: { lines = { { itemID, need, have, crafts, made, buy, unit, vendor,
-- parts }… } in order of appearance, cost (material at market value), toBuy (copper still to
-- spend), revenue (selling the wished items after the cut), sellable }.
function List.Plan(list)
  local pool, lines, byItem = {}, {}, {}
  local function line(id)
    local l = byItem[id]
    if not l then
      l = { itemID = id, need = 0, have = 0, crafts = 0, made = 0, buy = 0 }
      byItem[id] = l
      lines[#lines + 1] = l
    end
    return l
  end
  local function want(id, n, depth)
    local l = line(id)
    l.need = l.need + n
    if pool[id] == nil then pool[id], l.parts = holdings(id) end
    local use = math.min(pool[id], n)
    pool[id] = pool[id] - use
    l.have = l.have + use
    local rest = n - use
    if rest <= 0 then return end
    local _, viaCraft = unitCost(id, depth, {})
    local m = viaCraft and depth < MAX_DEPTH and maker(id)
    if m then
      local crafts = math.ceil(rest / made(m.r))
      l.crafts = l.crafts + crafts
      l.made = l.made + crafts * made(m.r)
      for _, g in ipairs(m.r.r) do
        if g.i then want(g.i, (g.n or 1) * crafts, depth + 1) end
      end
    else
      l.buy = l.buy + rest
      l.unit, l.vendor = ns.Item.BuyCost(ns.Item(id))
    end
  end
  local plan = { lines = lines, cost = 0, toBuy = 0, revenue = 0, sellable = true, missing = 0 }
  for _, w in ipairs(list) do
    local r = scanRecipe(w.rid)
    if r and r.r then
      local crafts = math.ceil((w.n or 1) / made(r))
      for _, g in ipairs(r.r) do
        if g.i then want(g.i, (g.n or 1) * crafts, 1) end
      end
      local unit, onAH = ns.Item.SellNet(ns.Item(w.out))
      if unit and unit > 0 then plan.revenue = plan.revenue + unit * (w.n or 1) end
      if not onAH then plan.sellable = false end
    end
  end
  for _, l in ipairs(lines) do
    if l.buy > 0 then
      if l.unit then plan.toBuy = plan.toBuy + l.buy * l.unit else plan.missing = plan.missing + 1 end
    end
    -- raw material at market value (what is bought plus what is taken from stock); made
    -- intermediates count through their own reagents
    local unit = l.unit or ns.Item.BuyCost(ns.Item(l.itemID))
    if unit and l.crafts == 0 then plan.cost = plan.cost + (l.have + l.buy) * unit end
  end
  return plan
end

-- Adding from the profession window ----------------------------------------------------------

function List.Add(rid, n)
  local r, scan = scanRecipe(rid)
  if not (r and r.out) then
    print("|cff33ccffm4:|r Dieses Rezept stellt kein Item her.")
    return nil
  end
  n = math.max(1, math.floor(n or 1))
  changed()
  for _, w in ipairs(wishes()) do
    if w.rid == rid then
      w.n = w.n + n
      return w
    end
  end
  local w = { rid = rid, out = r.out, name = r.name or ns.ItemName(r.out), pid = scan.professionID, n = n }
  table.insert(wishes(), w)
  return w
end

-- Window ------------------------------------------------------------------------------------------

local window, split, selected

local function refresh()
  if not (window and split) then return end
  local list = wishes()
  local entries = {}
  if #list > 0 then
    local plan = List.Plan(list)
    entries[#entries + 1] = { key = "h:list", header = "Einkaufsliste" }
    entries[#entries + 1] = { key = "all", name = "Alles zusammen", icon = "Interface\\Icons\\INV_Misc_Bag_10",
      value = plan.toBuy > 0 and money(plan.toBuy) or (GREEN .. "alles da|r"), all = true }
    for _, w in ipairs(list) do
      entries[#entries + 1] = { key = "w:" .. w.rid, name = w.name or ns.ItemName(w.out) or "?", icon = itemIcon(w.out),
        itemID = w.out, value = "×" .. w.n, wish = w }
    end
  end
  split.SetEntries(entries)
  if split.empty then
    split.empty:SetText(#list == 0 and "Die Einkaufsliste ist leer.\nIm Berufsfenster ein Rezept wählen und\n„Einkaufsliste“ klicken." or "")
  end
end
List.Refresh = refresh

local function ahOpen() return AuctionHouseFrame and AuctionHouseFrame:IsShown() end
local function searchAH(itemID)
  if not ahOpen() then return end
  if AuctionHouseFrameDisplayMode then AuctionHouseFrame:SetDisplayMode(AuctionHouseFrameDisplayMode.Buy) end
  C_Timer.After(0.1, function() if ns.Deals and ns.Deals.Search then ns.Safe(ns.Deals.Search, itemID) end end)
end

local function smallButton(parent, text, width, onClick)
  local ok, b = pcall(CreateFrame, "Button", nil, parent, "UIPanelButtonTemplate")
  if not ok or not b then b = CreateFrame("Button", nil, parent) end
  b:SetSize(width, 20)
  b:SetText(text)
  b:SetScript("OnClick", onClick)
  return b
end

-- The card: head (item, count with -/+ and remove), the reagent table, the summary.
-- Columns from the right edge (right end of each), so they never run into the cost column.
local COST_W = 86
local COLS = { { "Brauche", COST_W + 80 }, { "Habe", COST_W + 44 }, { "Fehlt", COST_W + 12 } }
local function card(c)
  local NW = ns.NativeWindow
  local v = NW.CardHead(c)
  v.Head:SetText("Material:")
  v.Minus = smallButton(c, "−", 24, function()
    local w = selected and selected.wish
    if not w then return end
    w.n = math.max(1, w.n - (IsShiftKeyDown() and 10 or 1))
    changed()
    refresh()
  end)
  v.Plus = smallButton(c, "+", 24, function()
    local w = selected and selected.wish
    if not w then return end
    w.n = w.n + (IsShiftKeyDown() and 10 or 1)
    changed()
    refresh()
  end)
  v.Remove = smallButton(c, "Entfernen", 80, function()
    local w = selected and selected.wish
    if not w then return end
    for i, x in ipairs(wishes()) do if x == w then table.remove(wishes(), i) break end end
    changed()
    refresh()
  end)
  v.Minus:SetPoint("TOPLEFT", v.Sub, "BOTTOMLEFT", 0, -6)
  v.Plus:SetPoint("LEFT", v.Minus, "RIGHT", 2, 0)
  v.Remove:SetPoint("LEFT", v.Plus, "RIGHT", 8, 0)
  v.Head:ClearAllPoints()
  v.Head:SetPoint("TOPLEFT", v.Icon, "BOTTOMLEFT", 0, -26)
  v.colHeads = {}
  for i, col in ipairs(COLS) do
    local h = c:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    h:SetPoint("RIGHT", c, "RIGHT", -RIGHT_EDGE - col[2], 0)
    h:SetPoint("TOP", v.Head, "TOP", 0, 0)
    h:SetText(col[1])
    v.colHeads[i] = h
  end
  local costHead = c:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
  costHead:SetPoint("RIGHT", c, "RIGHT", -RIGHT_EDGE, 0)
  costHead:SetPoint("TOP", v.Head, "TOP", 0, 0)
  costHead:SetText("Kosten")
  v.costHead = costHead
  v.rows = {}
  for i = 1, MAX_ROWS do
    local row = CreateFrame("Button", nil, c)
    row:SetHeight(18)
    row:SetPoint("TOPLEFT", v.Head, "BOTTOMLEFT", -2, -4 - (i - 1) * 18)
    row:SetPoint("RIGHT", c, "RIGHT", -RIGHT_EDGE + 4, 0)
    local hl = row:CreateTexture(nil, "HIGHLIGHT")
    hl:SetAllPoints()
    hl:SetColorTexture(1, 1, 1, 0.06)
    row.Icon = row:CreateTexture(nil, "ARTWORK")
    row.Icon:SetSize(16, 16)
    row.Icon:SetPoint("LEFT", 2, 0)
    row.Name = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    row.Name:SetPoint("LEFT", row.Icon, "RIGHT", 5, 0)
    row.Name:SetPoint("RIGHT", row, "RIGHT", -(COLS[1][2] + 4 + 46), 0) -- ends before "Brauche"
    row.Name:SetJustifyH("LEFT")
    row.Name:SetWordWrap(false)
    row.cells = {}
    for j, col in ipairs(COLS) do
      local fs = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
      fs:SetPoint("RIGHT", row, "RIGHT", -(col[2] + 4), 0)
      fs:SetJustifyH("RIGHT")
      row.cells[j] = fs
    end
    row.Cost = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    row.Cost:SetPoint("RIGHT", row, "RIGHT", -4, 0)
    row.Cost:SetJustifyH("RIGHT")
    row:SetScript("OnEnter", function(self)
      local l = self.line
      if not l then return end
      GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
      GameTooltip:SetItemByID(l.itemID)
      GameTooltip:AddLine(" ")
      for _, p in ipairs(l.parts or {}) do GameTooltip:AddDoubleLine("bei " .. p[1], tostring(p[2]), 1, 1, 1, 1, 1, 1) end
      if l.crafts > 0 then GameTooltip:AddLine(string.format("%d× selbst herstellen (günstiger als kaufen)", l.crafts), 0.37, 0.83, 0.55) end
      if l.buy > 0 and ahOpen() then GameTooltip:AddLine("Klick: im AH suchen", 0.31, 0.76, 0.63) end
      GameTooltip:Show()
    end)
    row:SetScript("OnLeave", function() GameTooltip:Hide() end)
    row:SetScript("OnClick", function(self)
      local l = self.line
      if not l then return end
      if ns.NativeWindow.AltClick(l.itemID, self) then return end
      searchAH(l.itemID)
    end)
    row:Hide()
    v.rows[i] = row
  end
  v.more = c:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
  v.sum = {}
  for i, text in ipairs({ "Material gesamt", "Noch zu kaufen" }) do
    local l = c:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    l:SetText(text)
    local val = c:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    val:SetPoint("RIGHT", c, "RIGHT", -RIGHT_EDGE, 0)
    val:SetPoint("TOP", l, "TOP", 0, 0)
    val:SetJustifyH("RIGHT")
    v.sum[i] = { label = l, value = val }
  end
  return v
end

local function show(entry, c)
  if not rawget(c, "m4Shopping") then c.m4Shopping = card(c) end
  local v = c.m4Shopping
  selected = entry
  local shown = entry ~= nil and not entry.header
  for _, part in ipairs({ v.Icon, v.Ring, v.Name, v.Sub, v.Head, v.costHead, v.more }) do part:SetShown(shown) end
  for _, h in ipairs(v.colHeads) do h:SetShown(shown) end
  for _, s in ipairs(v.sum) do s.label:SetShown(shown); s.value:SetShown(shown) end
  for _, row in ipairs(v.rows) do row:Hide(); row.line = nil end
  local w = entry and entry.wish
  for _, b in ipairs({ v.Minus, v.Plus, v.Remove }) do b:SetShown(w ~= nil) end
  if not shown then return end
  local list = w and { w } or wishes()
  local plan = List.Plan(list)
  if w then
    v.Icon:SetTexture(itemIcon(w.out))
    v.itemID = w.out
    v.Name:SetText(qualityName(w.out, w.name or ns.ItemName(w.out) or "?"))
    v.Sub:SetText(string.format("%d× herstellen", w.n))
  else
    v.Icon:SetTexture("Interface\\Icons\\INV_Misc_Bag_10")
    v.itemID = nil
    v.Name:SetText("Alles zusammen")
    v.Sub:SetText(string.format("%d %s", #list, #list == 1 and "Rezept" or "Rezepte"))
  end
  v.Head:ClearAllPoints()
  v.Head:SetPoint("TOPLEFT", v.Icon, "BOTTOMLEFT", 0, w and -30 or -20)
  local last = v.Head
  for i, l in ipairs(plan.lines) do
    local row = v.rows[i]
    if not row then break end
    row.line = l
    row.Icon:SetTexture(itemIcon(l.itemID))
    row.Name:SetText((ns.ItemName(l.itemID) or ("#" .. l.itemID)) .. (l.crafts > 0 and (MUTED .. "  herst.|r") or ""))
    local missing = l.need - l.have
    row.cells[1]:SetText(tostring(l.need))
    row.cells[2]:SetText((l.have >= l.need and GREEN or "") .. l.have .. (l.have >= l.need and "|r" or ""))
    if missing <= 0 then
      row.cells[3]:SetText(GREEN .. "–|r")
    elseif l.crafts > 0 then
      row.cells[3]:SetText(GREEN .. missing .. "|r")
    else
      row.cells[3]:SetText(RED .. missing .. "|r")
    end
    if l.buy > 0 then
      row.Cost:SetText(l.unit and (money(l.buy * l.unit) .. (l.vendor and (MUTED .. " H|r") or "")) or (RED .. "kein Preis|r"))
    elseif l.crafts > 0 then
      row.Cost:SetText(MUTED .. l.crafts .. "× herstellen|r")
    else
      row.Cost:SetText(MUTED .. "–|r")
    end
    row:Show()
    last = row
  end
  v.more:ClearAllPoints()
  v.more:SetPoint("TOPLEFT", last, "BOTTOMLEFT", 2, -4)
  v.more:SetText(#plan.lines > MAX_ROWS and string.format("… und %d weitere", #plan.lines - MAX_ROWS) or "")
  local anchor = #plan.lines > MAX_ROWS and v.more or last
  local values = {
    money(plan.cost),
    plan.toBuy > 0 and (money(plan.toBuy) .. (plan.missing > 0 and (RED .. " + " .. plan.missing .. " ohne Preis|r") or ""))
      or (GREEN .. "nichts – alles da|r"),
  }
  for i, s in ipairs(v.sum) do
    s.label:ClearAllPoints()
    s.label:SetPoint("TOPLEFT", anchor, "BOTTOMLEFT", 2, -14 - (i - 1) * 14)
    s.value:SetText(values[i])
  end
end

local function create()
  local NW = ns.NativeWindow
  -- wider than the profession window: room for the reagent names next to four columns
  window = NW.New({ name = "M4CompanionShoppingList", title = "Einkaufsliste", icon = "Interface\\Icons\\INV_Misc_Note_02",
    width = 760 })
  -- its tab under the profession window follows (Crafting.lua)
  local function sync() if ns.Products and ns.Products.SyncTab then ns.Products.SyncTab() end end
  window.frame:HookScript("OnShow", sync)
  window.frame:HookScript("OnHide", sync)
  window:AddTab({ key = "list", title = "Einkaufsliste", hidden = true, build = function(page)
    split = NW.Split(page, { onSelect = show })
  end, onShow = function() refresh() end })
end

-- Shows the window; with a recipe id that wish is selected.
function List.Show(rid)
  if not window then create() end
  window:Show()
  window:SelectTab("list")
  refresh()
  if rid and split and split.Select then split.Select("w:" .. rid) end
end

function List.Toggle()
  if window and window.frame:IsShown() then window.frame:Hide() else List.Show() end
end

function List.Frame() return window and window.frame end

-- Bags change (bought, crafted, taken from the bank): the open window follows, once per burst.
local pending = false
ns.On("BAG_UPDATE_DELAYED", function()
  if pending or not (window and window.frame:IsShown()) then return end
  pending = true
  C_Timer.After(0.5, function()
    pending = false
    ns.Safe(refresh)
  end)
end)
