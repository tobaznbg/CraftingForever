-- Ledger: every auction house trade of this character, whichever window it came from.
--   buy        purchase succeeded (hooks on C_AuctionHouse: PlaceBid, commodity purchase)
--   post       auction created (hooks on PostItem / PostCommodity)
--   sale       "sold" mail with invoice: price and the auction house cut
--   expired    "expired" mail, cancelled: "cancelled" mail
-- Mails stay in the inbox until taken, so every scan sees them again. A mail counts
-- once: same kind, item, amount and count and a receive time within MAIL_SLACK of
-- an entry already logged is the same mail.
-- db.ledger[charKey] = { events = { { t, k, i, n, u, c, cut, p, d }... } }
--   t time, k kind, i itemID (nil if only the name is known), n item name,
--   u units, c copper (buy: paid, sale: price before cut), cut, p unit price (post), d duration
local ADDON, ns = ...

local Ledger = {}
ns.Ledger = Ledger

local api = C_AuctionHouse or {}
local MAIL_SLACK = 900   -- seconds; receive time derived from daysLeft drifts a little
local MAIL_DAYS = 30     -- auction house mails are kept 30 days
local KEEP = 3000

local function book()
  ns.db.ledger = ns.db.ledger or {}
  local key = ns.CharKey()
  ns.db.ledger[key] = ns.db.ledger[key] or { events = {} }
  return ns.db.ledger[key]
end

local function nameOf(itemID)
  return itemID and ns.ItemName(itemID) or nil
end

local function add(e)
  e.t = e.t or time()
  e.n = e.n or nameOf(e.i)
  local events = book().events
  table.insert(events, e)
  while #events > KEEP do table.remove(events, 1) end
  if ns.PlannerUI and ns.PlannerUI.Refresh then ns.Safe(ns.PlannerUI.Refresh) end
end

-- Item id for a name from the mails: game cache first, then our own entries.
local function idForName(name)
  local getInfo = (C_Item and C_Item.GetItemInfo) or GetItemInfo
  local link = getInfo and select(2, getInfo(name))
  local id = link and tonumber(link:match("item:(%d+)"))
  if id then return id end
  local events = book().events
  for i = #events, 1, -1 do
    if events[i].n == name and events[i].i then return events[i].i end
  end
end

-- Purchases -------------------------------------------------------------------------

local auctionItem = {}   -- auctionID -> itemID, from any item search (ours or Blizzard's)
local bids = {}          -- auctionID -> { itemID, amount }
local commodity = nil    -- { itemID, units, total, confirmed }

ns.On("ITEM_SEARCH_RESULTS_UPDATED", function(_, itemKey)
  if not (itemKey and api.GetNumItemSearchResults) then return end
  for i = 1, (api.GetNumItemSearchResults(itemKey) or 0) do
    local r = api.GetItemSearchResultInfo(itemKey, i)
    if r and r.auctionID then auctionItem[r.auctionID] = itemKey.itemID end
  end
end)

local function hook(name, fn)
  if type(api[name]) == "function" then hooksecurefunc(api, name, function(...) ns.Safe(fn, ...) end) end
end

hook("PlaceBid", function(auctionID, amount)
  bids[auctionID] = { itemID = auctionItem[auctionID], amount = amount }
end)

hook("StartCommoditiesPurchase", function(itemID, units)
  commodity = { itemID = itemID, units = units }
end)

hook("ConfirmCommoditiesPurchase", function(itemID, units)
  if commodity and commodity.itemID == itemID then
    commodity.units, commodity.confirmed = units, true
  end
end)

ns.On("COMMODITY_PRICE_UPDATED", function(_, unitPrice, total)
  if commodity then commodity.total = total end
end)

ns.On("COMMODITY_PURCHASE_SUCCEEDED", function()
  local c = commodity
  commodity = nil
  if not c or not c.total then return end
  add({ k = "buy", i = c.itemID, u = c.units, c = c.total })
end)

ns.On("COMMODITY_PURCHASE_FAILED", function() commodity = nil end)

ns.On("AUCTION_HOUSE_PURCHASE_COMPLETED", function(_, auctionID)
  local b = bids[auctionID]
  bids[auctionID] = nil
  if not b then return end
  add({ k = "buy", i = b.itemID, u = 1, c = b.amount })
end)

-- Posts -----------------------------------------------------------------------------

local posting = {}  -- posts sent, confirmed by AUCTION_HOUSE_AUCTION_CREATED in order

local function itemAt(location)
  local ok, id = pcall(C_Item.GetItemID, location)
  return ok and id or nil
end

hook("PostItem", function(location, duration, quantity, bid, buyout)
  table.insert(posting, { k = "post", i = itemAt(location), u = quantity or 1, p = buyout, d = duration })
end)

hook("PostCommodity", function(location, duration, quantity, unitPrice)
  table.insert(posting, { k = "post", i = itemAt(location), u = quantity, p = unitPrice, d = duration })
end)

ns.On("AUCTION_HOUSE_AUCTION_CREATED", function()
  local e = table.remove(posting, 1)
  if e then add(e) end
end)

ns.On("AUCTION_HOUSE_CLOSED", function() posting, bids, commodity = {}, {}, nil end)

-- Mails -----------------------------------------------------------------------------

-- "Auktion abgelaufen: %s" -> pattern with the item name captured.
local function subjectPattern(fmt)
  if not fmt then return nil end
  return "^" .. fmt:gsub("([%%%(%)%.%+%-%*%?%[%]%^%$])", "%%%1"):gsub("%%%%s", "(.+)") .. "$"
end

local EXPIRED = subjectPattern(AUCTION_EXPIRED_MAIL_SUBJECT)
local CANCELLED = subjectPattern(AUCTION_REMOVED_MAIL_SUBJECT)

-- Whether a mail with this signature and receive time is already in the ledger.
local function known(sig, t, used)
  local events = book().events
  for idx = #events, 1, -1 do
    local e = events[idx]
    if e.m == sig and not used[idx] and math.abs(e.t - t) <= MAIL_SLACK then
      used[idx] = true
      return true
    end
  end
  return false
end

local function scanInbox()
  if not GetInboxNumItems then return end
  local used = {}
  for i = 1, GetInboxNumItems() do
    local _, _, _, subject, _, _, daysLeft = GetInboxHeaderInfo(i)
    local received = time() - math.floor(((MAIL_DAYS - (daysLeft or MAIL_DAYS)) * 86400))
    local invoiceType, itemName, _, bid, _, _, cut, _, _, _, count = nil, nil
    if GetInboxInvoiceInfo then
      invoiceType, itemName, _, bid, _, _, cut, _, _, _, count = GetInboxInvoiceInfo(i)
    end
    local e
    if invoiceType == "seller" and itemName and bid then
      e = { k = "sale", n = itemName, u = count or 1, c = bid, cut = cut or 0 }
    elseif subject then
      local name = EXPIRED and subject:match(EXPIRED)
      local kind = name and "expired"
      if not name and CANCELLED then
        name = subject:match(CANCELLED)
        kind = name and "cancelled"
      end
      if name then
        local _, itemID, _, n = GetInboxItem(i, 1)
        e = { k = kind, n = name, i = itemID, u = n or 1 }
      end
    end
    if e then
      e.i = e.i or idForName(e.n)
      e.m = table.concat({ e.k, e.n, e.c or 0, e.u }, "|")
      if not known(e.m, received, used) then
        e.t = received
        add(e)
        used[#book().events] = true
      end
    end
  end
end

ns.On("MAIL_INBOX_UPDATE", function() ns.Safe(scanInbox) end)

-- Report ----------------------------------------------------------------------------

-- Per item: bought/sold/posted units and money, plus totals.
function Ledger.Summary()
  local items, total = {}, { bought = 0, spent = 0, sold = 0, net = 0, ownNet = 0, profit = 0, held = 0 }
  for _, e in ipairs(book().events) do
    local key = e.i or e.n or "?"
    local it = items[key]
    if not it then
      it = { itemID = e.i, name = e.n, bought = 0, spent = 0, posted = 0, sold = 0, net = 0,
        expired = 0, cancelled = 0, last = 0 }
      items[key] = it
    end
    it.itemID = it.itemID or e.i
    it.last = math.max(it.last, e.t or 0)
    if e.k == "buy" then
      it.bought, it.spent = it.bought + (e.u or 0), it.spent + (e.c or 0)
    elseif e.k == "post" then
      it.posted = it.posted + (e.u or 0)
    elseif e.k == "sale" then
      it.sold, it.net = it.sold + (e.u or 0), it.net + (e.c or 0) - (e.cut or 0)
    elseif e.k == "expired" then
      it.expired = it.expired + (e.u or 0)
    elseif e.k == "cancelled" then
      it.cancelled = it.cancelled + (e.u or 0)
    end
  end
  local list = {}
  for _, it in pairs(items) do
    -- Profit only on traded units (bought and sold again), at the average purchase price.
    local avgCost = it.bought > 0 and it.spent / it.bought or 0
    local traded = math.min(it.sold, it.bought)
    local netPer = it.sold > 0 and it.net / it.sold or 0
    it.profit = traded * (netPer - avgCost)
    it.open = math.max(0, it.bought - it.sold)
    it.openCost = it.open * avgCost
    total.bought, total.spent = total.bought + it.bought, total.spent + it.spent
    total.sold, total.net = total.sold + it.sold, total.net + it.net
    total.ownNet = total.ownNet + (it.sold - traded) * netPer
    total.profit = total.profit + it.profit
    total.held = total.held + it.openCost
    table.insert(list, it)
  end
  table.sort(list, function(a, b) return a.last > b.last end)
  return list, total
end

function Ledger.Recent(n)
  local events, out = book().events, {}
  for i = #events, math.max(1, #events - n + 1), -1 do table.insert(out, events[i]) end
  return out
end

-- One-time import of purchases the sniper logged before the ledger existed (16 Nov 2026).
-- Those were item purchases of one auction each (the sniper then miscounted the units).
ns.OnReady(function()
  local b = book()
  if b.imported then return end
  b.imported = true
  local log = ns.db.sniper and ns.db.sniper.log or {}
  for _, e in ipairs(log) do
    if e.k == "buy" and e.c then
      table.insert(b.events, { t = e.t, k = "buy", i = e.i, n = nameOf(e.i), u = 1, c = e.c })
    end
  end
  table.sort(b.events, function(x, y) return x.t < y.t end)
end)
