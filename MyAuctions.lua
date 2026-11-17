-- MyAuctions: the own running auctions (C_AuctionHouse owned auctions) grouped per item, each
-- compared with the cheapest offer of somebody else (ns.AHSearch, own offers left out).
-- Shown by the Selling panel in the mode "Meine". A check (opening the mode, button
-- "Prüfen") asks the server for the own auctions and then searches every item once through
-- ns.AHSearch (one search a second, handed to the sniper while it runs).
-- Nothing is cancelled or posted automatically: MyAuctions.Cancel cancels exactly one
-- auction and is only called from a click on the row's button.
local ADDON, ns = ...

local My = {}
ns.MyAuctions = My

local api = C_AuctionHouse or {}

local owned = {}          -- list of { auctionID, itemID, itemKey, buyout, bid, quantity, timeLeftSeconds, status }
local ownedT = nil        -- time() of the last owned auctions answer
local wantCheck = false   -- search all items once the owned auctions arrived
local run = nil           -- { ids = { itemID = "waiting"|"done" }, total, done }
local failed = {}         -- itemID -> time() of a search without an answer
local onResult -- forward declared: the one callback for every search of this module

local function changed()
  if ns.Selling and ns.Selling.Refresh then ns.Safe(ns.Selling.Refresh) end
end

local function ready()
  return not api.IsThrottledMessageSystemReady or api.IsThrottledMessageSystemReady()
end

local function statusIs(value, name)
  local e = Enum and Enum.AuctionStatus
  local want = e and e[name]
  if want == nil and name == "Sold" then want = 1 end -- Retail: Active 0, Sold 1
  return want ~= nil and value == want
end

-- Owned auctions ----------------------------------------------------------------------

local function readOwned()
  owned = {}
  for i = 1, (api.GetNumOwnedAuctions and api.GetNumOwnedAuctions() or 0) do
    local a = api.GetOwnedAuctionInfo(i)
    if a and a.itemKey and a.itemKey.itemID then
      table.insert(owned, { auctionID = a.auctionID, itemID = a.itemKey.itemID, itemKey = a.itemKey,
        buyout = a.buyoutAmount, bid = a.bidAmount, quantity = a.quantity or 1,
        timeLeftSeconds = a.timeLeftSeconds, status = a.status,
        sold = statusIs(a.status, "Sold"), expired = statusIs(a.status, "Expired") })
    end
  end
  ownedT = time()
end

-- Items with at least one active auction that has a buyout (worth comparing).
local function activeItems()
  local ids, seen = {}, {}
  for _, a in ipairs(owned) do
    if not a.sold and not a.expired and a.buyout and a.buyout > 0 and not seen[a.itemID] then
      seen[a.itemID] = true
      table.insert(ids, a.itemID)
    end
  end
  return ids
end

local function startSearches()
  wantCheck = false
  local ids = activeItems()
  run = { ids = {}, total = #ids, done = 0 }
  for _, itemID in ipairs(ids) do run.ids[itemID] = "waiting" end
  for _, itemID in ipairs(ids) do
    if not (ns.AHSearch and ns.AHSearch.Request(itemID, onResult)) then
      run.ids[itemID] = "done"
      run.done = run.done + 1
    end
  end
  changed()
end

onResult = function(offers, itemID)
  failed[itemID] = not offers and time() or nil
  if run and run.ids[itemID] == "waiting" then
    run.ids[itemID] = "done"
    run.done = run.done + 1
  end
  changed()
end

local queryPending = false
local function query()
  if not api.QueryOwnedAuctions then return false end
  if not ready() then
    if not queryPending and C_Timer then
      queryPending = true
      C_Timer.After(0.5, function() queryPending = false; ns.Safe(query) end)
    end
    return true
  end
  local order = Enum and Enum.AuctionHouseSortOrder and Enum.AuctionHouseSortOrder.Name or 0
  api.QueryOwnedAuctions({ { sortOrder = order, reverseSort = false } })
  return true
end

-- Asks the server for the own auctions (list only, no item searches).
function My.Query()
  if ns.AHSearch and not ns.AHSearch.IsOpen() then return false end
  return query()
end

-- Player action (mode opened, "Prüfen"): own auctions, then every item searched once.
function My.Check()
  if ns.AHSearch and not ns.AHSearch.IsOpen() then return false end
  if not api.QueryOwnedAuctions then
    -- no owned auctions query in this client: check what is known
    wantCheck = false
    return false
  end
  wantCheck = true
  local my = { ids = {}, total = 0, done = 0, querying = true }
  run = my
  query()
  -- no answer: stop waiting (the list keeps what is known)
  if C_Timer then
    C_Timer.After(8, function()
      if run == my and my.querying then
        my.querying, wantCheck = nil, false
        changed()
      end
    end)
  end
  changed()
  return true
end

-- Progress of the check: done, total, running (true while searches are open).
function My.Progress()
  if not run then return 0, 0, false end
  return run.done, run.total, run.querying or run.done < run.total
end

function My.Supported() return api.QueryOwnedAuctions ~= nil and api.GetOwnedAuctionInfo ~= nil end

-- Rows ----------------------------------------------------------------------------------

-- Unit price of an own auction. Commodities: buyoutAmount is taken as the price per unit;
-- if the search shows an own level at buyout / quantity instead, that one is used.
local function unitOf(a, offers)
  local unit = a.buyout
  if unit and a.quantity and a.quantity > 1 and offers then
    local perUnit = math.floor(unit / a.quantity + 0.5)
    local atBuyout, atPerUnit = false, false
    for _, l in ipairs(offers) do
      if l.unit == unit then atBuyout = true end
      if l.unit == perUnit then atPerUnit = true end
    end
    if atPerUnit and not atBuyout then unit = perUnit end
  end
  return unit
end

-- Cheapest offer of somebody else: own units (ownCount, else the own auctions at that
-- price, else the whole level when the search marks it as own) are taken out per level.
function My.CheapestForeign(offers, mine)
  for _, l in ipairs(offers or {}) do
    local own = l.ownCount or (mine and mine[l.unit]) or (l.own and l.count) or 0
    if (l.count or 0) - math.min(own, l.count or 0) > 0 then return l.unit end
  end
  return nil
end

-- Status of one item from its own auctions and the offers of a search (nil = not searched).
--   status "best" | "under" | "alone" | "sold" | "expired" | "bid" | "unknown" | "failed"
function My.Evaluate(auctions, offers)
  local r = { auctions = auctions, quantity = 0, active = 0, soldCount = 0, expiredCount = 0 }
  local mine = {}
  for _, a in ipairs(auctions) do
    if a.sold then r.soldCount = r.soldCount + (a.quantity or 1)
    elseif a.expired then r.expiredCount = r.expiredCount + (a.quantity or 1)
    else
      r.active = r.active + 1
      r.quantity = r.quantity + (a.quantity or 1)
      local unit = unitOf(a, offers)
      if unit and unit > 0 then
        mine[unit] = (mine[unit] or 0) + (a.quantity or 1)
        if not r.unit or unit < r.unit then r.unit = unit end
        if not r.top or unit > r.top.unit then r.top = { unit = unit, auction = a } end
      end
      if a.timeLeftSeconds and (not r.timeLeft or a.timeLeftSeconds < r.timeLeft) then r.timeLeft = a.timeLeftSeconds end
    end
  end
  if r.active == 0 then
    r.status = r.soldCount > 0 and "sold" or "expired"
    return r
  end
  if not r.unit then r.status = "bid"; return r end
  if not offers then r.status = "unknown"; return r end
  r.foreign = My.CheapestForeign(offers, mine)
  if not r.foreign then
    r.status = "alone"
  elseif r.unit <= r.foreign then
    r.status = "best"
  else
    r.status = "under"
    r.diff = r.unit - r.foreign
    r.pct = r.diff / r.unit * 100
  end
  return r
end

local ORDER = { under = 1, failed = 2, unknown = 3, best = 4, alone = 5, bid = 6, sold = 7, expired = 8 }

-- One row per item, undercut first (biggest gap on top), then not checked, best, alone, sold:
--   { itemID, itemKey, status, unit, foreign, diff, pct, quantity, active, soldCount,
--     timeLeft, checked (time() of the search or nil), searching (bool), top = { unit, auction } }
function My.Rows()
  local groups, order = {}, {}
  for _, a in ipairs(owned) do
    -- Sold auctions only wait for the mail: not shown.
    if not a.sold then
      local g = groups[a.itemID]
      if not g then
        g = { itemID = a.itemID, itemKey = a.itemKey, list = {} }
        groups[a.itemID] = g
        table.insert(order, g)
      end
      table.insert(g.list, a)
    end
  end
  local rows = {}
  for _, g in ipairs(order) do
    local offers, t
    if ns.AHSearch then offers, t = ns.AHSearch.Last(g.itemID) end
    local r = My.Evaluate(g.list, offers)
    r.itemID, r.itemKey, r.checked = g.itemID, g.itemKey, offers and t or nil
    r.searching = ns.AHSearch and ns.AHSearch.State(g.itemID) ~= nil or false
    if r.status == "unknown" and failed[g.itemID] then r.status = "failed" end
    table.insert(rows, r)
  end
  table.sort(rows, function(a, b)
    local oa, ob = ORDER[a.status] or 9, ORDER[b.status] or 9
    if oa ~= ob then return oa < ob end
    if a.status == "under" and a.pct ~= b.pct then return a.pct > b.pct end
    return (ns.ItemName(a.itemID) or "") < (ns.ItemName(b.itemID) or "")
  end)
  return rows
end

function My.Count() return #owned end
function My.Updated() return ownedT end

-- Cancel ----------------------------------------------------------------------------------

-- The auction a click on the row's button would cancel: the most expensive active one
-- (the one undercut first); nil when none can be cancelled.
function My.CancelTarget(row)
  local a = row and row.top and row.top.auction
  if not (a and a.auctionID and api.CancelAuction) or a.cancelling then return nil end
  if api.CanCancelAuction and not api.CanCancelAuction(a.auctionID) then return nil end
  return a
end

-- Cancels exactly one auction (one click = one call). The deposit is lost.
function My.Cancel(row)
  local a = My.CancelTarget(row)
  if not a then return false end
  a.cancelling = true -- until the server sends the new list, no second call for it
  api.CancelAuction(a.auctionID)
  return true
end

-- Events ----------------------------------------------------------------------------------

if ns.On then
  ns.On("OWNED_AUCTIONS_UPDATED", function()
    readOwned()
    if run then run.querying = nil end
    if wantCheck then startSearches() else changed() end
  end)
  ns.On("AUCTION_CANCELED", function()
    if My.Query() then changed() end
  end)
  ns.On("AUCTION_HOUSE_CLOSED", function()
    run, wantCheck, failed = nil, false, {}
  end)
end
