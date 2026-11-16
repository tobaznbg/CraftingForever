-- Sniper: while the auction house is open and the sniper runs, it searches the
-- items of a watch list one after another (like TSM's sniper with groups, which
-- also issues single item searches), compares the offers with the reference value
-- (Deals.Reference) and lists the hits.
-- No bulk request: SearchForItemKeys with 400 keys got the character disconnected
-- (16 Nov 2026). Searches are paced to at most one per SEARCH_SPACING seconds.
-- Watch list = items of our own auction house (collector data) that sell at least
-- WATCH_MIN_PER_DAY a day and sell well in the EU data (Deals.Liquid), where a 40 % discount is worth Deals.MIN_PROFIT and that
-- we can afford; the WATCH_MAX best by expected profit. Without the collector data
-- or the API it falls back to browsing the whole auction house (slow). A hit is an offer at or below Deals.MAX_SHARE of the reference, for an
-- item that sells well, with at least Deals.MIN_PROFIT after the cut.
-- Buying is always a click of the player: items one auction per click,
-- commodities "Kaufen" (the game quotes the final price) and then "Bestätigen".
-- If the game blocks automatic searches, every search round needs a click too.
-- Every hit and purchase is logged in db.sniper, so the yield can be measured.
local ADDON, ns = ...

local Sniper = {}
ns.Sniper = Sniper

local api = C_AuctionHouse or {}
local PAUSE = 3            -- seconds between two browse rounds
local SEARCH_TIMEOUT = 6   -- give up on a detail search after this
local BROWSE_TIMEOUT = 25
local MAX_PAGES = 80
local PRICE_TOLERANCE = 1.02 -- commodity quote may be 2 % above the listed cost
local LOG_MAX = 2000
local WATCH_MAX = 150
local WATCH_MIN_PER_DAY = 10
local SEARCH_SPACING = 1.0   -- seconds between two searches (TSM allows itself 100 a minute)
local FULL_PAUSE = 30        -- pause between two whole-AH browses (as TSM)

local running, manual = false, false
local phase = "idle"        -- idle, browse, detail, wait
local token = 0             -- invalidates timers of an earlier round
local pages, browseStarted = 0, nil
local candidates = {}
local detailing = nil
local hits = {}             -- key -> hit
local checked = {}          -- key -> min price at which the detail found no deal
local pending = nil         -- commodity quote waiting for "Bestätigen"
local buying = nil          -- item auction bought, waiting for the result
local note = nil            -- last message for the status line
local round = { items = 0, candidates = 0, seconds = 0 }
local timeouts = 0          -- detail searches without an answer (this run)
local watch = nil           -- { keys = {itemKey...}, set = {itemID = true} } or nil (whole AH)

local function changed()
  if ns.Selling and ns.Selling.Refresh then ns.Safe(ns.Selling.Refresh) end
end

local function store()
  ns.db.sniper = ns.db.sniper or { log = {} }
  return ns.db.sniper
end

local function session()
  local s = store()
  if not s.session or s.session.closed then
    s.session = { start = time(), rounds = 0, hits = 0, hitProfit = 0, bought = 0, spent = 0,
      expected = 0, gone = 0, goneSeconds = 0 }
  end
  return s.session
end

local function log(kind, hit, extra)
  local s = store()
  local e = { t = time(), k = kind, i = hit.itemID, u = hit.units, p = math.floor(hit.profit), c = hit.cost }
  if extra then for k, v in pairs(extra) do e[k] = v end end
  table.insert(s.log, e)
  while #s.log > LOG_MAX do table.remove(s.log, 1) end
end

-- Item level is left out: search results may carry the real level while the
-- browse result says 0, and in this game an item id has one level anyway.
local function keyOf(itemKey)
  return table.concat({ itemKey.itemID, itemKey.itemSuffix or 0, itemKey.battlePetSpeciesID or 0 }, ":")
end

-- Market value of this item in our own auction house (collector, at most ~1 h old).
local function houseValue(itemID)
  local house = ns.AHData and ns.AHData[113]
  local row = house and house.items[itemID]
  return row and row[2]
end

-- Same item variant as the reference prices (random suffixes and pets differ in value).
local function plainKey(itemKey)
  return (itemKey.itemSuffix or 0) == 0 and (itemKey.battlePetSpeciesID or 0) == 0
end

local function ready()
  return not api.IsThrottledMessageSystemReady or api.IsThrottledMessageSystemReady()
end

-- Watch list from the collector data of our own auction house.
local function buildWatchlist()
  local house = ns.AHData and ns.AHData[113]
  if not house or not api.SendSearchQuery or not api.MakeItemKey then return nil end
  local money, list = GetMoney(), {}
  local discount = 1 - ns.Deals.MAX_SHARE - ns.Deals.CUT
  for itemID, row in pairs(house.items) do
    local mv, perDay, offers, qty = row[2], row[5], row[7], row[8]
    -- The collector's sale estimate is unreliable for rare items (cancel and repost looks
    -- like a sale), so EU sales must confirm the demand as well.
    if mv and perDay and perDay >= WATCH_MIN_PER_DAY and mv * ns.Deals.MAX_SHARE <= money
        and ns.Deals.Liquid(itemID) then
      local stack = math.max(1, math.min(20, (qty or 1) / math.max(1, offers or 1)))
      if discount * mv * stack >= ns.Deals.MIN_PROFIT then
        table.insert(list, { itemID = itemID, score = mv * math.min(perDay, 100) })
      end
    end
  end
  table.sort(list, function(a, b) return a.score > b.score end)
  local w = { keys = {}, set = {} }
  for i = 1, math.min(WATCH_MAX, #list) do
    local itemKey = api.MakeItemKey(list[i].itemID)
    table.insert(w.keys, { itemKey = itemKey, itemID = list[i].itemID, key = keyOf(itemKey) })
    w.set[list[i].itemID] = true
  end
  return #w.keys > 0 and w or nil
end

local lastSearch = 0
-- Diagnostics: answered searches, summed answer time, throttle waits, late answers.
local diag = { answered = 0, seconds = 0, waits = 0, late = 0, sent = 0 }
local sentAt = {}
local function searchAllowed()
  return GetTime() - lastSearch >= SEARCH_SPACING
end

local function browseFilters()
  local filters = {}
  if Enum and Enum.AuctionHouseFilter then
    for name, value in pairs(Enum.AuctionHouseFilter) do
      if type(name) == "string" and name:find("Quality$") then table.insert(filters, value) end
    end
  end
  return filters
end

local function priceSort()
  local order = Enum and Enum.AuctionHouseSortOrder and Enum.AuctionHouseSortOrder.Price or 0
  return { { sortOrder = order, reverseSort = false } }
end

local nextStep

local function later(seconds, fn)
  local my = token
  C_Timer.After(seconds, function()
    if running and my == token then ns.Safe(fn) end
  end)
end

-- Browse ---------------------------------------------------------------------------

local function sendBrowse()
  if not ready() then return later(0.5, sendBrowse) end
  pages, browseStarted = 0, GetTime()
  candidates = {}
  if watch then
    -- one round = every watched item searched once
    for _, w in ipairs(watch.keys) do table.insert(candidates, w) end
    phase = "detail"
    session().rounds = session().rounds + 1
    round.items = #candidates
    changed()
    return nextStep()
  end
  phase = "browse"
  api.SendBrowseQuery({ searchString = "", sorts = priceSort(), filters = browseFilters(),
    itemClassFilters = {} })
  local my = token
  later(BROWSE_TIMEOUT, function()
    if phase == "browse" and my == token then Sniper.BrowseDone() end
  end)
end

local function quickCheck(r)
  if r.containsOwnerItem or not r.minPrice or r.minPrice <= 0 then return false end
  if not plainKey(r.itemKey) then return false end
  local itemID = r.itemKey.itemID
  if watch then
    if not watch.set[itemID] then return false end -- sells in our house: checked by the list
  elseif not ns.Deals.Liquid(itemID) then
    return false
  end
  local ref = ns.Deals.Reference(itemID, houseValue(itemID))
  return ref and r.minPrice <= ref * ns.Deals.MAX_SHARE
end

function Sniper.BrowseDone()
  if phase ~= "browse" then return end
  local results = api.GetBrowseResults and api.GetBrowseResults() or {}
  local seen = {}
  for _, r in ipairs(results) do
    local key = keyOf(r.itemKey)
    seen[key] = r.minPrice
    if quickCheck(r) and checked[key] ~= r.minPrice then
      table.insert(candidates, { itemKey = r.itemKey, itemID = r.itemKey.itemID, key = key, minPrice = r.minPrice })
    end
  end
  -- Hits whose cheapest offer is gone were bought by someone else (or cancelled).
  local s = session()
  for key, hit in pairs(hits) do
    if hit ~= (pending and pending.hit) and (not seen[key] or seen[key] > hit.best) then
      s.gone, s.goneSeconds = s.gone + 1, s.goneSeconds + (time() - hit.firstSeen)
      log("gone", hit, { a = time() - hit.firstSeen })
      hits[key] = nil
    end
  end
  round.items, round.candidates = #results, #candidates
  round.seconds = GetTime() - (browseStarted or GetTime())
  s.rounds = s.rounds + 1
  phase = "detail"
  changed()
  nextStep()
end

-- Detail ---------------------------------------------------------------------------

local function evaluate(c, listings, commodity)
  local plain = {}
  for _, l in ipairs(listings) do table.insert(plain, { unit = l.unit, count = l.count }) end
  local house = #plain > 0 and ns.Deals.HousePrice(plain, 0.25) or nil
  local ref, source = ns.Deals.Reference(c.itemID, house)
  if not ref then return nil end
  local limit = ref * ns.Deals.MAX_SHARE
  local hit = { key = c.key, itemKey = c.itemKey, itemID = c.itemID, commodity = commodity, ref = ref,
    source = source, limit = limit, units = 0, cost = 0, profit = 0, auctions = {} }
  table.sort(listings, function(a, b) return a.unit < b.unit end)
  for _, l in ipairs(listings) do
    if l.unit <= limit and not l.own then
      hit.units = hit.units + l.count
      hit.cost = hit.cost + l.unit * l.count
      hit.profit = hit.profit + (ref * (1 - ns.Deals.CUT) - l.unit) * l.count
      hit.best = hit.best or l.unit
      table.insert(hit.auctions, l)
    end
  end
  if hit.units == 0 or hit.profit < ns.Deals.MIN_PROFIT then return nil end
  return hit
end

local function answered(itemID)
  local t = sentAt[itemID]
  if not t then return end
  sentAt[itemID] = nil
  if detailing and detailing.itemID == itemID then
    diag.answered, diag.seconds = diag.answered + 1, diag.seconds + (GetTime() - t)
  else
    diag.late = diag.late + 1
  end
  ns.db.sniper.diag = diag
end

local function finishDetail(c, listings, commodity)
  if detailing ~= c then return end
  detailing = nil
  local hit = evaluate(c, listings, commodity)
  local old = hits[c.key]
  if hit then
    hit.firstSeen = old and old.firstSeen or time()
    hit.seen = time()
    hits[c.key] = hit
    if not old then
      local s = session()
      s.hits, s.hitProfit = s.hits + 1, s.hitProfit + hit.profit
      log("hit", hit, { b = hit.best, r = math.floor(hit.ref) })
      if PlaySound then pcall(PlaySound, SOUNDKIT and SOUNDKIT.AUCTION_WINDOW_OPEN or 5274) end
    end
  else
    if old then
      local s = session()
      s.gone, s.goneSeconds = s.gone + 1, s.goneSeconds + (time() - old.firstSeen)
      log("gone", old, { a = time() - old.firstSeen })
    end
    hits[c.key] = nil
    if c.minPrice then checked[c.key] = c.minPrice end
  end
  changed()
  later(0.1, nextStep)
end

local function sendDetail(c)
  if not ready() then diag.waits = diag.waits + 1 end
  if not ready() or not searchAllowed() then return later(0.25, function() sendDetail(c) end) end
  lastSearch = GetTime()
  diag.sent = diag.sent + 1
  sentAt[c.itemID] = GetTime()
  detailing = c
  api.SendSearchQuery(c.itemKey, priceSort(), true)
  later(SEARCH_TIMEOUT, function()
    if detailing == c then
      detailing, timeouts = nil, timeouts + 1
      if c.minPrice then checked[c.key] = c.minPrice end
      nextStep()
    end
  end)
end

local frame = CreateFrame("Frame")
local function listen(event)
  pcall(frame.RegisterEvent, frame, event)
end

local handlers = {}

handlers.AUCTION_HOUSE_BROWSE_RESULTS_UPDATED = function()
  if phase ~= "browse" then return end
  if api.HasFullBrowseResults and not api.HasFullBrowseResults() and pages < MAX_PAGES then
    pages = pages + 1
    if ready() then api.RequestMoreBrowseResults() else later(0.5, function() api.RequestMoreBrowseResults() end) end
    return
  end
  Sniper.BrowseDone()
end
handlers.AUCTION_HOUSE_BROWSE_RESULTS_ADDED = handlers.AUCTION_HOUSE_BROWSE_RESULTS_UPDATED

handlers.COMMODITY_SEARCH_RESULTS_UPDATED = function(itemID)
  answered(itemID)
  local c = detailing
  if not c or c.itemID ~= itemID then return end
  local listings = {}
  for i = 1, (api.GetNumCommoditySearchResults(itemID) or 0) do
    local r = api.GetCommoditySearchResultInfo(itemID, i)
    if r and r.unitPrice then
      table.insert(listings, { unit = r.unitPrice, count = r.quantity, auctionID = r.auctionID,
        own = r.containsOwnerItem })
    end
  end
  finishDetail(c, listings, true)
end

handlers.ITEM_SEARCH_RESULTS_UPDATED = function(itemKey)
  if itemKey then answered(itemKey.itemID) end
  local c = detailing
  if not c or not itemKey or keyOf(itemKey) ~= c.key then return end
  local listings = {}
  for i = 1, (api.GetNumItemSearchResults(itemKey) or 0) do
    local r = api.GetItemSearchResultInfo(itemKey, i)
    if r and r.buyoutAmount and r.buyoutAmount > 0 then
      local n = r.quantity or 1
      table.insert(listings, { unit = r.buyoutAmount / n, count = n, buyout = r.buyoutAmount,
        auctionID = r.auctionID, own = r.containsOwnerItem })
    end
  end
  finishDetail(c, listings, false)
end

-- Loop -----------------------------------------------------------------------------

nextStep = function()
  if not running or pending or buying then return end
  if phase == "detail" then
    local c = table.remove(candidates, 1)
    if c then return sendDetail(c) end
    phase = "wait"
    round.seconds = GetTime() - (browseStarted or GetTime())
    changed()
    if manual then return end -- the next round needs a click
    return later(watch and PAUSE or FULL_PAUSE, sendBrowse)
  end
end

local function stopAll(text)
  running, phase, detailing, candidates = false, "idle", nil, {}
  token = token + 1
  if pending and api.CancelCommoditiesPurchase then pcall(api.CancelCommoditiesPurchase) end
  pending, buying = nil, nil
  if text then note = text end
  local s = ns.db and ns.db.sniper and ns.db.sniper.session
  if s and not s.closed then s.closed, s.stop = true, time() end
  changed()
end

-- Buying ---------------------------------------------------------------------------

local function affordable(hit)
  local money, units, cost = GetMoney(), 0, 0
  for _, a in ipairs(hit.auctions) do
    local n = math.min(a.count, math.floor((money - cost) / a.unit))
    if n <= 0 then break end
    units, cost = units + n, cost + n * a.unit
    if n < a.count then break end
  end
  return units, cost
end

function Sniper.Buy(hit)
  if not hit then return end
  if pending and pending.hit == hit then
    -- second click: confirm the quoted commodity purchase
    api.ConfirmCommoditiesPurchase(hit.itemID, pending.units)
    pending.confirmed = true
    note = "Kauf bestätigt …"
    return changed()
  end
  if pending or buying then note = "Erst den laufenden Kauf abschließen."; return changed() end
  if hit.commodity then
    local units, cost = affordable(hit)
    if units == 0 then note = "Nicht genug Gold."; return changed() end
    pending = { hit = hit, units = units, cost = cost }
    api.StartCommoditiesPurchase(hit.itemID, units)
    note = "Preis wird beim Server angefragt …"
  else
    local a = hit.auctions[1]
    if not a then return end
    if a.buyout > GetMoney() then note = "Nicht genug Gold."; return changed() end
    buying = { hit = hit, auction = a }
    api.PlaceBid(a.auctionID, a.buyout)
    note = "Kaufe …"
    local my = buying
    C_Timer.After(8, function() if buying == my then buying = nil; nextStep() end end)
  end
  changed()
end

local function bought(hit, units, cost)
  local s = session()
  local profit = (hit.ref * (1 - ns.Deals.CUT)) * units - cost
  s.bought, s.spent, s.expected = s.bought + units, s.spent + cost, s.expected + profit
  log("buy", hit, { u = units, c = cost, p = math.floor(profit) })
end

handlers.COMMODITY_PRICE_UPDATED = function(unitPrice, totalPrice)
  if not pending or pending.quoted then return end
  pending.quoted, pending.total = true, totalPrice
  if totalPrice > pending.cost * PRICE_TOLERANCE then
    pcall(api.CancelCommoditiesPurchase)
    note = "Schon weg: Preis jetzt " .. ns.FormatMoney(unitPrice, true) .. " pro Stück."
    hits[pending.hit.key] = nil
    pending = nil
    later(0.5, nextStep)
  else
    note = string.format("%dx für %s – nochmal klicken zum Bestätigen.", pending.units, ns.FormatMoney(totalPrice, true))
  end
  changed()
end

handlers.COMMODITY_PRICE_UNAVAILABLE = function()
  if not pending then return end
  note = "Preis nicht verfügbar – schon weg."
  hits[pending.hit.key] = nil
  pending = nil
  changed()
  later(0.5, nextStep)
end

handlers.COMMODITY_PURCHASE_SUCCEEDED = function()
  if not pending then return end
  bought(pending.hit, pending.units, pending.total or pending.cost)
  note = "Gekauft: " .. pending.units .. "x " .. ns.ItemName(pending.hit.itemID)
  hits[pending.hit.key] = nil
  pending = nil
  changed()
  later(0.5, nextStep)
end

handlers.COMMODITY_PURCHASE_FAILED = function()
  if not pending then return end
  note = "Kauf fehlgeschlagen."
  pending = nil
  changed()
  later(0.5, nextStep)
end

handlers.AUCTION_HOUSE_PURCHASE_COMPLETED = function(auctionID)
  if not buying or buying.auction.auctionID ~= auctionID then return end
  local hit, a = buying.hit, buying.auction
  bought(hit, a.count, a.buyout)
  note = "Gekauft: " .. ns.ItemName(hit.itemID) .. " für " .. ns.FormatMoney(a.buyout, true)
  table.remove(hit.auctions, 1)
  hit.units, hit.cost = hit.units - a.count, hit.cost - a.buyout
  hit.profit = hit.profit - ((hit.ref * (1 - ns.Deals.CUT)) * a.count - a.buyout)
  if #hit.auctions == 0 then hits[hit.key] = nil else hit.best = hit.auctions[1].unit end
  buying = nil
  changed()
  later(0.5, nextStep)
end

handlers.AUCTION_HOUSE_SHOW_ERROR = function()
  if buying then
    note = "Kauf ging nicht – schon weg."
    hits[buying.hit.key] = nil
    buying = nil
    changed()
    later(0.5, nextStep)
  end
end

handlers.ADDON_ACTION_BLOCKED = function(addon, fn)
  if addon ~= ADDON or not running then return end
  if not manual then
    manual = true
    note = "Das Spiel verlangt pro Suchrunde einen Klick (" .. tostring(fn) .. ")."
    changed()
  end
end
handlers.ADDON_ACTION_FORBIDDEN = handlers.ADDON_ACTION_BLOCKED

handlers.AUCTION_HOUSE_CLOSED = function()
  if running then stopAll() end
end

for event in pairs(handlers) do listen(event) end
frame:SetScript("OnEvent", function(_, event, ...)
  local fn = handlers[event]
  if fn then ns.Safe(fn, ...) end
end)

-- Control --------------------------------------------------------------------------

function Sniper.IsRunning() return running end
function Sniper.NeedsClick() return running and manual and phase == "wait" end
function Sniper.Pending() return pending end

-- The one button: Start, Stop, or (when the game wants a click per round) Suchen.
function Sniper.Click()
  if not running then
    if not (api.SendBrowseQuery and api.GetBrowseResults) then
      note = "Dieser Client hat keine Browse-Suche."
      return changed()
    end
    running, note, hits, checked, timeouts = true, nil, {}, {}, 0
    diag, sentAt = { answered = 0, seconds = 0, waits = 0, late = 0, sent = 0 }, {}
    watch = buildWatchlist()
    token = token + 1
    session()
    sendBrowse()
  elseif Sniper.NeedsClick() then
    token = token + 1
    sendBrowse()
  else
    stopAll("Gestoppt.")
  end
  changed()
end

function Sniper.Hits()
  local list = {}
  for _, hit in pairs(hits) do table.insert(list, hit) end
  table.sort(list, function(a, b) return a.profit > b.profit end)
  return list
end

-- Status block for the panel: up to four short lines.
--   1 state (white), 2 progress of this session, 3 server answers, 4 last message (orange)
function Sniper.StatusLines()
  local s = ns.db and ns.db.sniper and ns.db.sniper.session
  local lines = {}
  if not running then
    lines[1] = "Gestoppt"
  elseif phase == "browse" then
    lines[1] = "Durchsucht das ganze AH …" .. (pages > 0 and (" Seite " .. pages) or "")
  elseif phase == "detail" and watch then
    local left = #candidates + (detailing and 1 or 0)
    lines[1] = string.format("Scannt: %d von %d Items", #watch.keys - left, #watch.keys)
  elseif phase == "detail" then
    lines[1] = string.format("Prüft %d Kandidaten …", #candidates + (detailing and 1 or 0))
  else
    lines[1] = string.format("Pause – Runde fertig (%d Items in %.0f s)", round.items, round.seconds)
  end
  if s then
    local minutes = math.max(1, math.floor(((s.stop or time()) - s.start) / 60))
    local text = string.format("%d Runden  ·  %d Treffer  ·  %d min", s.rounds, s.hits, minutes)
    if s.bought > 0 then
      text = text .. "  ·  gekauft " .. ns.FormatMoney(s.spent, true) .. ", erwartet +" .. ns.FormatMoney(s.expected, true)
    end
    lines[2] = text
  end
  if running and diag.sent > 0 then
    lines[3] = string.format("Server antwortet in Ø %.1f s%s", diag.answered > 0 and diag.seconds / diag.answered or 0,
      timeouts > 0 and string.format("  ·  %d ohne Antwort", timeouts) or "")
  end
  if note then lines[4] = note end
  if not running and not s then
    lines[2] = "Start: sucht laufend Angebote weit unter Wert."
    lines[3] = "Jeder Kauf ist ein Klick von dir."
  end
  return lines
end

function Sniper.Status()
  local lines, out = Sniper.StatusLines(), {}
  for i = 1, 4 do if lines[i] then table.insert(out, lines[i]) end end
  return table.concat(out, "  ·  ")
end
