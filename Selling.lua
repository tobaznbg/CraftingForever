-- Selling: panel next to the auction house that lists everything in the bags the
-- Bestand logic would sell on the auction house, looks up the current lowest
-- price live and posts one auction per click (the game requires a click for
-- every post).
-- Mode "Sniper": the sniper's whole watch list live (ns.Sniper.State) with progress,
-- last cheapest price and last check per item; hits on top with a buy button. A click on a
-- hit row opens the item's detail window (SniperDetail.lua) right of the panel.
local ADDON, ns = ...

local Selling = {}
ns.Selling = Selling

local WIDTH, ROW = 360, 26
local MAX_ROWS = 18
local CRASH_SHARE = 0.7  -- warn when the live price is below 70 % of the usual one
local DURATIONS = { { 1, "2 h" }, { 2, "8 h" }, { 3, "24 h" } }

local panel, rowsFrames, durationButtons, status
local duration = 3
local mode = "sell" -- "sell" or "sniper"
local control, sniperLines, ledgerButton
local sniperView         -- watch list view of the sniper mode (createSniperView)
local SNIPER_ROW = 20
local GREEN, MUTED = "|cff5fd38d", "|cff99999e"
-- Sniper columns right of the item name: buy up to, sell at (price stair of the hit), button.
local SNIPER_COLS = { { "Kauf bis", 62 }, { "Einstellen", 74 }, { "", 58 } }
local modeTabs
local entries = {}       -- current list
local live = {}          -- itemID -> { price, own, t } from live searches
local queue, searching = {}, nil

local api = C_AuctionHouse or {}

local function money(c) return ns.FormatMoney(c, true) end

-- Items in the bags: itemID -> { location of one stack, total count, quality, bound }.
local function bagItems()
  local c = C_Container or {}
  local numSlots, info = c.GetContainerNumSlots or GetContainerNumSlots, c.GetContainerItemInfo
  local items = {}
  for _, bag in ipairs(ns.CarriedBags()) do
    for slot = 1, (numSlots(bag) or 0) do
      local i = info and info(bag, slot)
      if i and i.itemID and not i.isLocked then
        local e = items[i.itemID]
        if not e then
          e = { itemID = i.itemID, n = 0, q = i.quality, bound = i.isBound,
                location = ItemLocation:CreateFromBagAndSlot(bag, slot) }
          items[i.itemID] = e
        end
        e.n = e.n + (i.stackCount or 1)
      end
    end
  end
  return items
end

local function isCommodity(e)
  if api.GetItemCommodityStatus and Enum and Enum.ItemCommodityStatus then
    return api.GetItemCommodityStatus(e.location) == Enum.ItemCommodityStatus.Commodity
  end
  return false
end

-- Live price search, one at a time ---------------------------------------------

local function nextSearch()
  if searching or #queue == 0 or not (panel and panel:IsShown()) then return end
  local e = table.remove(queue, 1)
  searching = e
  local key = api.MakeItemKey and api.MakeItemKey(e.itemID)
  if not key then searching = nil return end
  api.SendSearchQuery(key, {}, true)
  -- Give up on a search that never answers.
  C_Timer.After(5, function()
    if searching == e then searching = nil; nextSearch() end
  end)
end

local function finishSearch(itemID, price, own)
  live[itemID] = { price = price, own = own, t = GetTime() }
  ns.Item.Observe(itemID, price)
  if searching and searching.itemID == itemID then searching = nil end
  ns.Safe(Selling.Refresh)
  C_Timer.After(0.3, nextSearch)
end

ns.On("COMMODITY_SEARCH_RESULTS_UPDATED", function(_, itemID)
  if not searching or searching.itemID ~= itemID then return end
  local r = api.GetNumCommoditySearchResults(itemID) > 0 and api.GetCommoditySearchResultInfo(itemID, 1)
  finishSearch(itemID, r and r.unitPrice, r and r.containsOwnerItem)
end)

ns.On("ITEM_SEARCH_RESULTS_UPDATED", function(_, itemKey)
  local itemID = itemKey and itemKey.itemID
  if not searching or searching.itemID ~= itemID then return end
  local best, own
  for i = 1, api.GetNumItemSearchResults(itemKey) do
    local r = api.GetItemSearchResultInfo(itemKey, i)
    if r and r.buyoutAmount and (not best or r.buyoutAmount < best) then
      best, own = r.buyoutAmount, r.containsOwnerItem
    end
  end
  finishSearch(itemID, best, own)
end)

-- Price to post at, or nil with a reason.
local function askPrice(e)
  local l = live[e.itemID]
  if not l then return nil, "Preis wird abgefragt …" end
  local item = ns.Item(e.itemID)
  local vendor = item.vendorSell or 0
  local ask
  if l.price then
    -- Our own auction already leads: match it instead of undercutting ourselves.
    ask = l.own and l.price or math.max(1, l.price - 1)
  elseif item.avg then
    ask = item.avg
  else
    return nil, "kein Angebot – Preis selbst setzen"
  end
  if ask * (1 - ns.Item.CUT) <= vendor then return nil, "unter Händlerpreis" end
  -- Lowest sensible price: what it costs to make (own learned recipe) or the average,
  -- whichever is higher. Below it, better wait than join the undercutting.
  local floor = math.max(ns.CraftingCost and ns.CraftingCost(e.itemID) or 0, item.avg or 0)
  if floor > 0 and ask < floor then
    return ask, "unter Mindestpreis " .. money(floor) .. " – besser liegen lassen", true
  end
  local warn
  if item.avg and ask < item.avg * CRASH_SHARE then
    warn = string.format("%d %% unter Ø", math.floor((1 - ask / item.avg) * 100))
  end
  return ask, warn
end

local function post(e)
  local ask = askPrice(e)
  if not ask then return end
  if isCommodity(e) then
    api.PostCommodity(e.location, duration, e.n, ask)
  else
    api.PostItem(e.location, duration, 1, nil, ask)
  end
  live[e.itemID] = nil -- the price changed with our own auction
end

-- Sniper watch list view -----------------------------------------------------------

local function ago(t)
  local s = math.max(0, time() - t)
  if s < 60 then return string.format("vor %d s", s) end
  if s < 3600 then return string.format("vor %d min", math.floor(s / 60)) end
  return string.format("vor %d h", math.floor(s / 3600))
end

local function clock(seconds)
  seconds = math.max(0, math.floor(seconds + 0.5))
  return string.format("%d:%02d", math.floor(seconds / 60), seconds % 60)
end

-- Item tooltip, plus the hit figures when the row is a hit.
local function sniperTooltip(self)
  local e = self.entry
  if not e then return end
  GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
  GameTooltip:SetItemByID(e.itemID)
  local h = e.hit
  if h then
    GameTooltip:AddLine(" ")
    GameTooltip:AddLine(string.format("%dx kaufen bis %s  ·  einstellen zu %s", h.units, money(h.buyUpTo), money(h.sellAt)), 0.37, 0.83, 0.55)
    GameTooltip:AddLine(string.format("Gewinn ~%s%s", money(h.profit),
      h.days and string.format("  ·  verkauft in ~%s Tagen", ns.SniperDetail.Days(h.days)) or ""), 0.37, 0.83, 0.55)
    if h.cost > GetMoney() then GameTooltip:AddLine("Gold reicht nicht für alle.", 1, 0.71, 0.28) end
  end
  GameTooltip:AddLine("Klick: Details", 0.31, 0.76, 0.63)
  GameTooltip:Show()
end

local function sniperRow(body, i)
  local Style = ns.Style
  local r = CreateFrame("Frame", nil, body)
  r:SetHeight(SNIPER_ROW)
  r:SetPoint("TOPLEFT", 0, -(i - 1) * SNIPER_ROW)
  r:SetPoint("RIGHT", body, "RIGHT")
  r.stripe = Style.Solid(r, Style.C.row)
  r.stripe:SetAllPoints()
  r.icon = r:CreateTexture(nil, "ARTWORK")
  r.icon:SetSize(SNIPER_ROW - 4, SNIPER_ROW - 4)
  r.icon:SetPoint("LEFT", 2, 0)
  r.cells = {}
  local x = 0
  for c = #SNIPER_COLS, 1, -1 do
    local fs = Style.Text(r, 11)
    fs:SetPoint("RIGHT", r, "RIGHT", -x - 4, 0)
    fs:SetWidth(SNIPER_COLS[c][2] - 6)
    fs:SetJustifyH("RIGHT")
    r.cells[c] = fs
    x = x + SNIPER_COLS[c][2]
  end
  r.name = Style.Text(r, 12)
  r.name:SetPoint("LEFT", r.icon, "RIGHT", 5, 0)
  r.name:SetPoint("RIGHT", r, "RIGHT", -x - 4, 0)
  r.name:SetJustifyH("LEFT")
  -- Buy button over the "checked" column; same purchase path as before (one click each).
  r.button = Style.Button(r, "Kaufen", SNIPER_COLS[#SNIPER_COLS][2] - 2, SNIPER_ROW - 2, function(self)
    if self.entry then ns.Safe(ns.Sniper.Buy, self.entry) end
  end, Style.C.accent)
  r.button:SetPoint("RIGHT", -1, 0)
  r:EnableMouse(true)
  r:SetScript("OnEnter", sniperTooltip)
  r:SetScript("OnLeave", function() GameTooltip:Hide() end)
  -- Click on the row (not the buy button): detail window right of the panel, again closes it.
  r:SetScript("OnMouseUp", function(self, button)
    if button ~= "RightButton" and self.entry then
      ns.Safe(ns.SniperDetail.Toggle, self.entry.itemID, panel)
      ns.Safe(Selling.Refresh)
    end
  end)
  return r
end

local function createSniperView()
  local Style = ns.Style
  local v = CreateFrame("Frame", nil, panel)
  v:SetPoint("TOPLEFT", 8, -34)
  v:SetPoint("BOTTOMRIGHT", -8, 66) -- status block below
  v.progress = Style.Text(v, 12)
  v.progress:SetPoint("TOPLEFT", 2, -2)
  v.progress:SetPoint("RIGHT", v, "RIGHT", -2, 0)
  v.progress:SetJustifyH("LEFT")
  local head = CreateFrame("Frame", nil, v)
  head:SetHeight(14)
  head:SetPoint("TOPLEFT", 0, -20)
  head:SetPoint("RIGHT", v, "RIGHT", -10, 0)
  local x = 0
  for c = #SNIPER_COLS, 1, -1 do
    local fs = Style.Text(head, 10)
    fs:SetPoint("RIGHT", head, "RIGHT", -x - 4, 0)
    fs:SetWidth(SNIPER_COLS[c][2] - 6)
    fs:SetJustifyH("RIGHT")
    fs:SetTextColor(unpack(Style.C.muted))
    fs:SetText(SNIPER_COLS[c][1])
    x = x + SNIPER_COLS[c][2]
  end
  local itemHead = Style.Text(head, 10)
  itemHead:SetPoint("LEFT", 2, 0)
  itemHead:SetTextColor(unpack(Style.C.muted))
  itemHead:SetText("Item")
  v.scroll, v.body = Style.Scroll(v)
  v.scroll:SetPoint("TOPLEFT", 0, -36)
  v.scroll:SetPoint("BOTTOMRIGHT", -10, 0)
  v.rows = {}
  -- Shown while there is no hit: the list only holds what is worth buying.
  v.empty = Style.Text(v, 11)
  v.empty:SetPoint("TOPLEFT", 8, -44)
  v.empty:SetPoint("RIGHT", -8, 0)
  v.empty:SetJustifyH("LEFT")
  v.empty:SetTextColor(unpack(Style.C.muted))
  return v
end

-- Texts of the three columns: buy up to, sell at (hits) or cheapest now (last search), checked.
local function sniperCells(e)
  local price, checked
  if e.price == false and not e.hit then price = MUTED .. "nicht im Angebot|r"
  elseif e.hit then price = GREEN .. money(e.hit.sellAt) .. "|r"
  elseif e.price then price = money(e.price)
  else price = MUTED .. "–|r" end
  if e.current then checked = ns.Style.ACCENT .. "gerade …|r"
  elseif e.checked then checked = MUTED .. ago(e.checked) .. "|r"
  else checked = MUTED .. "–|r" end
  return e.limit and money(e.limit) or (MUTED .. "–|r"), price, checked
end

local function sniperProgress(st, lines)
  if st.total == 0 then return lines[1] or "" end
  if not st.running then
    return string.format("%s  ·  Stand Runde %d: %d Items", lines[1] or "", st.round, st.total)
  end
  if st.phase == "detail" then
    return string.format("Runde %d  ·  %d/%d  ·  %s bis zum Ende", st.round, st.index, st.total, clock(st.eta))
  end
  return string.format("Runde %d fertig  ·  %d/%d  ·  %s", st.round, st.index, st.total, lines[1] or "")
end

-- Panel --------------------------------------------------------------------------

local function createPanel(parent)
  local Style = ns.Style
  panel = CreateFrame("Frame", "M4CompanionSelling", parent)
  panel:SetWidth(WIDTH)
  panel:SetPoint("TOPLEFT", parent, "TOPRIGHT", 4, 0)
  panel:SetPoint("BOTTOMLEFT", parent, "BOTTOMRIGHT", 4, 0)
  Style.Panel(panel, 30)
  modeTabs = {}
  local mx = 6
  for _, def in ipairs({ { "sell", "Verkaufen", 70 }, { "sniper", "Sniper", 70 } }) do
    local tab = Style.Tab(panel, def[2], def[3], function()
      mode = def[1]
      ns.Safe(Selling.Refresh)
    end)
    tab:SetPoint("TOPLEFT", mx, -2)
    modeTabs[def[1]] = tab
    mx = mx + def[3] + 2
  end

  ledgerButton = Style.Button(panel, "Handelsbuch", 84, 20, function()
    ns.Safe(ns.PlannerUI.Show, "ledger")
  end)
  ledgerButton:SetPoint("TOPRIGHT", -8, -5)

  durationButtons = {}
  local x = -8
  for i = #DURATIONS, 1, -1 do
    local d = DURATIONS[i]
    local b = Style.Tab(panel, d[2], 40, function()
      duration = d[1]
      ns.Safe(Selling.Refresh)
    end)
    b:SetPoint("TOPRIGHT", x, -2)
    durationButtons[d[1]] = b
    x = x - 42
  end

  rowsFrames = {}
  for i = 1, MAX_ROWS do
    local r = CreateFrame("Frame", nil, panel)
    r:SetSize(WIDTH - 16, ROW)
    r:SetPoint("TOPLEFT", 8, -36 - (i - 1) * ROW)
    r.stripe = Style.Solid(r, Style.C.row)
    r.stripe:SetAllPoints()
    r.stripe:SetShown(i % 2 == 0)
    r.icon = r:CreateTexture(nil, "ARTWORK")
    r.icon:SetSize(20, 20)
    r.icon:SetPoint("LEFT", 2, 0)
    r.name = Style.Text(r, 12)
    r.name:SetPoint("LEFT", r.icon, "RIGHT", 6, 5)
    r.name:SetWidth(170)
    r.name:SetJustifyH("LEFT")
    r.info = Style.Text(r, 11)
    r.info:SetPoint("LEFT", r.icon, "RIGHT", 6, -6)
    r.info:SetWidth(190)
    r.info:SetJustifyH("LEFT")
    r.info:SetTextColor(unpack(Style.C.muted))
    r.price = Style.Text(r, 12)
    r.price:SetPoint("RIGHT", -82, 0)
    r.price:SetJustifyH("RIGHT")
    r.button = Style.Button(r, "Einstellen", 74, 20, function(self)
      if self.entry then ns.Safe(post, self.entry) end
    end, Style.C.accent)
    r.button:SetPoint("RIGHT", 0, 0)
    r:EnableMouse(true)
    r:SetScript("OnEnter", function(self)
      if not self.entry then return end
      GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
      GameTooltip:SetItemByID(self.entry.itemID)
      GameTooltip:Show()
    end)
    r:SetScript("OnLeave", function() GameTooltip:Hide() end)
    rowsFrames[i] = r
  end
  control = Style.Button(panel, "Start", 70, 22, function()
    ns.Safe(ns.Sniper.Click)
  end, Style.C.accent)
  control:SetPoint("BOTTOMRIGHT", -8, 8)
  -- Sniper status block: four lines above the bottom edge, separated by a rule.
  sniperLines = {}
  local colors = { Style.C.text, Style.C.muted, Style.C.muted, { 1, 0.71, 0.28, 1 } }
  for i = 4, 1, -1 do
    local fs = Style.Text(panel, i == 1 and 13 or 12)
    fs:SetPoint("BOTTOMLEFT", 10, 10 + (4 - i) * 17)
    fs:SetWidth(WIDTH - 96)
    fs:SetJustifyH("LEFT")
    fs:SetTextColor(unpack(colors[i]))
    sniperLines[i] = fs
  end
  -- Line 1 (state) moved into the progress line above the watch list.
  sniperLines.rule = Style.Solid(panel, Style.C.border)
  sniperLines.rule:SetHeight(1)
  sniperLines.rule:SetPoint("BOTTOMLEFT", 8, 63)
  sniperLines.rule:SetPoint("BOTTOMRIGHT", -8, 63)
  sniperView = createSniperView()
  -- "geprüft vor 40 s" and the time left run on: refresh the sniper view once a second.
  local elapsed = 0
  panel:SetScript("OnUpdate", function(_, dt)
    elapsed = elapsed + (dt or 0)
    if elapsed < 1 then return end
    elapsed = 0
    if mode == "sniper" then ns.Safe(Selling.Refresh) end
  end)
  status = Style.Text(panel, 11)
  status:SetPoint("BOTTOMLEFT", 10, 10)
  status:SetWidth(WIDTH - 20)
  status:SetJustifyH("LEFT")
  status:SetTextColor(unpack(Style.C.muted))
end

local function refreshSniper()
  local Sniper, Style = ns.Sniper, ns.Style
  local st = Sniper.State()
  local pending = Sniper.Pending()
  local lines = Sniper.StatusLines()
  local v = sniperView
  local detailID = ns.SniperDetail.ItemID()
  local getIcon = (C_Item and C_Item.GetItemIconByID) or GetItemIcon
  -- Only hits (offers worth buying); the watched items are on the main window's Sniper page.
  local shown, current = {}, nil
  for _, e in ipairs(st.rows) do
    if e.hit then table.insert(shown, e) end
    if e.current then current = e end
  end
  if #shown == 0 then
    local text = "Noch kein Treffer."
    if current then text = text .. "\nPrüfe gerade: " .. (ns.ItemName(current.itemID) or ("#" .. current.itemID)) end
    v.empty:SetText(text .. "\n\nBeobachtete Items: Hauptfenster (/m4) → Sniper")
    v.empty:Show()
  else
    v.empty:Hide()
  end
  v.body:SetSize(WIDTH - 26, math.max(1, #shown * SNIPER_ROW))
  for i, e in ipairs(shown) do
    local r = v.rows[i]
    if not r then r = sniperRow(v.body, i); v.rows[i] = r end
    local h = e.hit
    r.entry = e
    r.button.entry = h
    r.icon:SetTexture(getIcon and getIcon(e.itemID) or nil)
    local name = ns.ItemName(e.itemID) or ("#" .. e.itemID)
    r.name:SetText(h and (GREEN .. name .. "  +" .. money(h.profit) .. "|r") or name)
    local limit, price, checked = sniperCells(e)
    r.cells[1]:SetText(limit)
    r.cells[2]:SetText(price)
    r.cells[3]:SetText(h and "" or checked)
    if h then
      r.stripe:SetColorTexture(0.37, 0.83, 0.55, 0.14)
      local confirm = pending and pending.hit == h and pending.quoted
      r.button.label:SetText(confirm and "Bestätigen" or (h.commodity and "Kaufen" or "Kaufen 1"))
      r.button:Show()
    else
      r.stripe:SetColorTexture(unpack(e.current and Style.C.hover or Style.C.row))
      r.button:Hide()
    end
    -- The item open in the detail window is marked like a hovered row.
    local selected = e.itemID == detailID
    if selected then r.stripe:SetColorTexture(0.31, 0.76, 0.63, 0.3) end
    r.stripe:SetShown((selected or h or e.current or i % 2 == 0) and true or false)
    r:Show()
  end
  for i = #shown + 1, #v.rows do
    v.rows[i].entry, v.rows[i].button.entry = nil, nil
    v.rows[i]:Hide()
  end
  if v.scroll.UpdateBar then v.scroll.UpdateBar() end
  v.progress:SetText(sniperProgress(st, lines))
  control.label:SetText(Sniper.NeedsClick() and "Suchen" or (Sniper.IsRunning() and "Stop" or "Start"))
  for i = 2, 4 do sniperLines[i]:SetText(lines[i] or "") end
  status:SetText("")
  ns.SniperDetail.Refresh()
end

function Selling.Refresh()
  if not panel or not panel:IsShown() then return end
  for key, tab in pairs(modeTabs) do tab:SetActive(key == mode) end
  for _, b in pairs(durationButtons) do b:SetShown(mode == "sell") end
  control:SetShown(mode == "sniper")
  ledgerButton:SetShown(mode ~= "sell")
  sniperLines[1]:Hide()
  for i = 2, 4 do sniperLines[i]:SetShown(mode == "sniper") end
  sniperLines.rule:SetShown(mode == "sniper")
  sniperView:SetShown(mode == "sniper")
  status:SetShown(mode ~= "sniper")
  if mode ~= "sniper" then ns.SniperDetail.Hide() end
  if mode == "sniper" then
    for _, r in ipairs(rowsFrames) do r.entry, r.button.entry = nil, nil; r:Hide() end
    return refreshSniper()
  end
  for d, b in pairs(durationButtons) do b:SetActive(d == duration) end
  -- Everything the Bestand logic sends to the auction house.
  entries = {}
  for _, e in pairs(bagItems()) do
    local action = ns.Inventory.Advise(e.itemID, e)
    if action == "AH" then
      local item = ns.Item(e.itemID)
      e.value = item.now or item.avg or 0
      table.insert(entries, e)
    end
  end
  table.sort(entries, function(a, b) return a.value * a.n > b.value * b.n end)
  local total = 0
  for i, r in ipairs(rowsFrames) do
    local e = entries[i]
    r.entry = e
    r.button.entry = e
    if e then
      local commodity = isCommodity(e)
      local qty = commodity and e.n or 1
      r.icon:SetTexture(((C_Item and C_Item.GetItemIconByID) or GetItemIcon)(e.itemID))
      r.name:SetText(ns.ItemName(e.itemID))
      local ask, note, belowFloor = askPrice(e)
      if ask then
        local deposit = commodity and api.CalculateCommodityDeposit and api.CalculateCommodityDeposit(e.itemID, duration, qty)
          or (api.CalculateItemDeposit and api.CalculateItemDeposit(e.location, duration, qty))
        r.price:SetText(money(ask))
        r.button.label:SetText(belowFloor and "Trotzdem" or "Einstellen")
        r.info:SetText(string.format("%dx  ·  Gebühr %s%s", qty, money(deposit or 0),
          note and ("  ·  |cffffb547" .. note .. "|r") or ""))
        r.button:Show()
        total = total + ask * qty * 0.95
      else
        r.price:SetText("")
        r.info:SetText(string.format("%dx  ·  %s", qty, note or ""))
        r.button:Hide()
      end
      if not live[e.itemID] and searching ~= e then
        local queued = false
        for _, q in ipairs(queue) do if q.itemID == e.itemID then queued = true end end
        if not queued then table.insert(queue, e) end
      end
      r:Show()
    else
      r:Hide()
    end
  end
  status:SetText(#entries == 0 and "Nichts in den Taschen, das ins AH gehört."
    or string.format("%d Items fürs AH  ·  Erlös nach Gebühr ca. %s  ·  ein Klick = eine Auktion",
      #entries, money(total)))
  nextSearch()
end

ns.On("AUCTION_HOUSE_SHOW", function()
  C_Timer.After(0.2, function()
    local parent = AuctionHouseFrame
    if not parent or not api.PostCommodity then return end
    if not panel then ns.Safe(createPanel, parent) end
    if panel then panel:Show(); ns.Safe(Selling.Refresh) end
  end)
end)
ns.On("AUCTION_HOUSE_CLOSED", function()
  queue, searching = {}, nil
  ns.SniperDetail.Hide()
  if panel then panel:Hide() end
end)
ns.On("BAG_UPDATE_DELAYED", function() ns.Safe(Selling.Refresh) end)
ns.On("AUCTION_HOUSE_AUCTION_CREATED", function() ns.Safe(Selling.Refresh) end)
