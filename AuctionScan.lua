-- AuctionScan: our own full scan of the auction house, no other addon needed.
-- Supports the classic auction API (QueryAuctionItems getAll) and the modern one
-- (C_AuctionHouse.ReplicateItems); which one the client has is detected at runtime.
--
-- Stored in CraftingForeverDB.ah:
--   last     { t, items = { [itemID] = { fingerprint, ... } } }  previous scan, for the diff
--   current  { [itemID] = { min, mv, qty, n, sellers } }         latest scan summary
--   days     { [dayKey] = { [itemID] = day row } }               see AuctionStats.AddToDay
--   lastScanT, scans, api
local ADDON, ns = ...

local Scan = {}
ns.AuctionScan = Scan

local THROTTLE = 15 * 60       -- the server allows a full scan every 15 minutes
local BATCH = 200              -- listings read per frame
local ITEM_BATCH = 300         -- items processed per frame when saving
local MAX_DIFF_AGE = 24 * 3600 -- older previous scans say nothing about sales
local PREFIX = "|cffffd100CraftingForever:|r "

local state -- running scan: { api, started, listings = { [itemID] = { ... } }, count }
local button

local function db()
  local ah = ns.db.ah
  if not ah then
    ah = { days = {}, current = {}, scans = 0 }
    ns.db.ah = ah
  end
  return ah
end

local function hasModern()
  return C_AuctionHouse and type(C_AuctionHouse.ReplicateItems) == "function"
end

local function hasLegacy()
  return type(QueryAuctionItems) == "function" and type(GetAuctionItemInfo) == "function"
end

local function detectApi()
  if AuctionHouseFrame and hasModern() then return "modern" end
  if AuctionFrame and hasLegacy() then return "legacy" end
  if hasModern() then return "modern" end
  if hasLegacy() then return "legacy" end
  return nil
end

-- Seconds since the last finished scan, or nil.
function Scan.Age()
  local t = ns.db and ns.db.ah and ns.db.ah.currentT
  return t and (time() - t) or nil
end

function Scan.Running()
  return state ~= nil
end

-- Called after every finished scan.
local doneListeners = {}
function Scan.OnDone(fn) table.insert(doneListeners, fn) end

function Scan.HasData()
  return ns.db and ns.db.ah and ns.db.ah.lastScanT ~= nil
end

-- Seconds until the next full scan is allowed (0 = now).
function Scan.Wait()
  local last = ns.db.ah and ns.db.ah.lastScanT
  if not last then return 0 end
  return math.max(0, THROTTLE - (time() - last))
end

local function canScan(api)
  if api == "legacy" and CanSendAuctionQuery then
    local _, canAll = CanSendAuctionQuery()
    return canAll and true or false
  end
  return Scan.Wait() == 0
end

local function addListing(itemID, count, buyout, seller, timeLeft)
  if not itemID or itemID == 0 or not buyout or buyout <= 0 then return end
  count = math.max(1, count or 1)
  local list = state.listings[itemID]
  if not list then
    list = {}
    state.listings[itemID] = list
  end
  table.insert(list, {
    unit = math.floor(buyout / count + 0.5),
    count = count,
    -- Seller names may still be loading; such listings are kept anyway.
    seller = (seller and seller ~= "") and seller or "?",
    tl = timeLeft or 4,
  })
  state.count = state.count + 1
end

-- Reading -------------------------------------------------------------------

-- GetAuctionItemInfo / GetReplicateItemInfo share the return layout:
-- 3 count, 10 buyout, 14 owner, 17 itemID, 18 hasAllInfo
local function readLegacy(index)
  local _, _, count, _, _, _, _, _, _, buyout, _, _, _, owner, _, _, itemID = GetAuctionItemInfo("list", index)
  local timeLeft = GetAuctionItemTimeLeft and GetAuctionItemTimeLeft("list", index)
  addListing(itemID, count, buyout, owner, timeLeft)
end

local function readModern(index)
  local _, _, count, _, _, _, _, _, _, buyout, _, _, _, owner, _, _, itemID = C_AuctionHouse.GetReplicateItemInfo(index)
  local timeLeft = C_AuctionHouse.GetReplicateItemTimeLeft and C_AuctionHouse.GetReplicateItemTimeLeft(index)
  -- The modern enum is 0..3; store it as the classic 1..4.
  addListing(itemID, count, buyout, owner, timeLeft and (timeLeft + 1))
end

local finish

local function readBatches(first, last, read)
  local index = first
  local function step()
    if not state then return end
    local stop = math.min(last, index + BATCH - 1)
    for i = index, stop do read(i) end
    index = stop + 1
    if index <= last then
      C_Timer.After(0, function() ns.Safe(step) end)
    else
      finish()
    end
  end
  step()
end

-- Saving ----------------------------------------------------------------------

local function toKeys(listings)
  local keys = {}
  for i, l in ipairs(listings) do keys[i] = ns.AuctionStats.Key(l) end
  return keys
end

local function fromKeys(keys)
  local list = {}
  for _, key in ipairs(keys or {}) do
    local l = ns.AuctionStats.ParseKey(key)
    if l then table.insert(list, l) end
  end
  return list
end

finish = function()
  local scanState = state
  local ah = db()
  local now = time()
  local previous = ah.last
  local elapsed = previous and (now - previous.t) or nil
  local diff = elapsed and elapsed <= MAX_DIFF_AGE
  local dayKey = ns.AuctionStats.DayKey(now)
  ah.days[dayKey] = ah.days[dayKey] or {}
  local day = ah.days[dayKey]

  -- Every item that is listed now or was listed in the previous scan.
  local itemIDs, seen = {}, {}
  for itemID in pairs(scanState.listings) do
    table.insert(itemIDs, itemID); seen[itemID] = true
  end
  if diff then
    for itemID in pairs(previous.items) do
      if not seen[itemID] then table.insert(itemIDs, itemID) end
    end
  end

  local current, lastItems = {}, {}
  local soldTotal = 0
  local index = 1
  local function step()
    local stop = math.min(#itemIDs, index + ITEM_BATCH - 1)
    for i = index, stop do
      local itemID = itemIDs[i]
      local listings = scanState.listings[itemID] or {}
      local summary
      if #listings > 0 then
        summary = ns.AuctionStats.Summarize(listings)
        current[itemID] = { summary.min, summary.mv, summary.qty, summary.n, summary.sellers }
        lastItems[itemID] = toKeys(listings)
      end
      local soldUnits, soldValue, soldN, endedN
      if diff and previous.items[itemID] then
        soldUnits, soldValue, soldN, endedN =
          ns.AuctionStats.Diff(fromKeys(previous.items[itemID]), listings, elapsed)
        soldTotal = soldTotal + soldN
      end
      day[itemID] = ns.AuctionStats.AddToDay(day[itemID], summary, soldUnits, soldValue, soldN, endedN)
    end
    index = stop + 1
    if index <= #itemIDs then
      C_Timer.After(0, function() ns.Safe(step) end)
      return
    end
    ah.last = { t = now, items = lastItems }
    ah.current = current
    ah.currentT = now
    ah.scans = (ah.scans or 0) + 1
    ah.api = scanState.api
    ns.AuctionStats.Prune(ah.days, now)
    print(string.format("%sScan fertig: %d Angebote, %d Items, %d Sekunden.%s", PREFIX,
      scanState.count, #itemIDs, now - scanState.started,
      diff and string.format(" Seit dem letzten Scan vermutlich %d Angebote verkauft.", soldTotal) or ""))
    if ns.PlannerUI and ns.PlannerUI.Refresh then ns.Safe(ns.PlannerUI.Refresh) end
    for _, fn in ipairs(doneListeners) do ns.Safe(fn) end
  end
  state = nil
  step()
end

-- Starting ------------------------------------------------------------------------

local eventFrame = CreateFrame("Frame")
local silenced = {}

-- Blizzard's browse frame would redraw on every list update of a getAll query;
-- it is silenced while we read and restored afterwards.
local function silenceOthers(event)
  silenced = {}
  if not GetFramesRegisteredForEvent then return end
  for _, f in ipairs({ GetFramesRegisteredForEvent(event) }) do
    if f ~= eventFrame then
      f:UnregisterEvent(event)
      table.insert(silenced, { f, event })
    end
  end
end

local function restoreOthers()
  for _, entry in ipairs(silenced) do entry[1]:RegisterEvent(entry[2]) end
  silenced = {}
end

eventFrame:SetScript("OnEvent", function(self, event)
  self:UnregisterEvent(event)
  restoreOthers()
  if not state then return end
  ns.Safe(function()
    if event == "AUCTION_ITEM_LIST_UPDATE" then
      -- With getAll every listing is on the one "page".
      local count = GetNumAuctionItems("list")
      readBatches(1, count or 0, readLegacy)
    elseif event == "REPLICATE_ITEM_LIST_UPDATE" then
      readBatches(0, C_AuctionHouse.GetNumReplicateItems() - 1, readModern)
    end
  end)
end)

function Scan.Start()
  if state then
    print(PREFIX .. "Scan läuft bereits.")
    return
  end
  local api = detectApi()
  if not api then
    print(PREFIX .. "Dieser Client bietet keine bekannte Auktionshaus-Schnittstelle.")
    return
  end
  if not canScan(api) then
    local wait = Scan.Wait()
    if wait > 0 then
      print(string.format("%sVollscan erst wieder in %d:%02d Minuten möglich.", PREFIX,
        math.floor(wait / 60), wait % 60))
    else
      print(PREFIX .. "Der Server erlaubt gerade keinen Vollscan, bitte etwas später erneut.")
    end
    return
  end

  state = { api = api, started = time(), listings = {}, count = 0 }
  db().lastScanT = time()
  if ns.Selling then C_Timer.After(1, function() ns.Safe(ns.Selling.Refresh) end) end
  print(PREFIX .. "Vollscan gestartet – das Spiel kann kurz hängen.")
  if api == "legacy" then
    silenceOthers("AUCTION_ITEM_LIST_UPDATE")
    eventFrame:RegisterEvent("AUCTION_ITEM_LIST_UPDATE")
    QueryAuctionItems("", nil, nil, 0, nil, nil, true, false, nil)
  else
    eventFrame:RegisterEvent("REPLICATE_ITEM_LIST_UPDATE")
    C_AuctionHouse.ReplicateItems()
  end
end

local function abort()
  if state then
    state = nil
    eventFrame:UnregisterAllEvents()
    restoreOthers()
    print(PREFIX .. "Scan abgebrochen (Auktionshaus geschlossen).")
  end
end

-- Button on the auction house window ----------------------------------------------

local function createButton()
  local parent = AuctionHouseFrame or AuctionFrame
  if not parent or button then return end
  button = ns.Style.Button(parent, "CF Scan", 110, 24, nil, ns.Style.C.accent)
  -- Below the window's bottom edge, where no Blizzard or Auctionator element sits.
  button:SetPoint("TOPRIGHT", parent, "BOTTOMRIGHT", -10, -2)
  button:SetFrameStrata("HIGH")
  button:SetFrameLevel(parent:GetFrameLevel() + 50)
  ns.db.ui = ns.db.ui or {}
  ns.db.ui.scanButton = { t = time(), parent = parent:GetName() }
  button:SetScript("OnClick", function() ns.Safe(Scan.Start) end)
  button:HookScript("OnEnter", function(self)
    GameTooltip:SetOwner(self, "ANCHOR_BOTTOM")
    GameTooltip:AddLine("CraftingForever: Vollscan")
    local wait = Scan.Wait()
    if wait > 0 then
      GameTooltip:AddLine(string.format("Wieder möglich in %d:%02d", math.floor(wait / 60), wait % 60), 1, 1, 1)
    else
      GameTooltip:AddLine("Liest alle Angebote, alle 15 Minuten möglich.", 1, 1, 1)
    end
    GameTooltip:Show()
  end)
  button:HookScript("OnLeave", function() GameTooltip:Hide() end)
end

ns.On("AUCTION_HOUSE_SHOW", function()
  -- The auction UI is load-on-demand; its frame exists only from now on.
  C_Timer.After(0, function()
    ns.Safe(createButton)
    if button then button:Show() end
    print("|cffffd100CraftingForever:|r Vollscan mit dem Knopf \"CF Scan\" unter dem AH-Fenster oder mit /cf scan.")
  end)
end)
ns.On("AUCTION_HOUSE_CLOSED", abort)
