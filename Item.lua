-- Item: the one place for an item's market data. Every module takes its numbers from
-- here; nothing else reads price sources (collector export, own scans, searches).
--
-- ns.Item(itemID) -> {
--   now        market value right now (copper per unit), nil if not on offer: mean of the
--              cheapest 15-30 % of the units listed, outliers dropped, so one lone cheap or
--              lowball offer does not move it; from the newest of collector snapshot and own
--              full scan. This is "AH jetzt" in every view.
--   cheapest   the single cheapest offer right now (also from single item searches); only
--              for views about single offers (sniper, merchant flips)
--   offers, quantity   auctions / units listed at that time (internal, not shown)
--   min, avg, max      lowest / average / highest hourly cheapest offer of the last
--                      two weeks (collector; at the start blended with TSM start values)
--   demand     relative demand from the cloud (scale: TSM's real EU sales per day; our own
--              estimate calibrated to it). Shown as a level, not as units: Item.DemandText
--   certain    units certainly bought per day (partial purchases of commodities, a lower
--              bound; nil for items that are not commodities)
--   yesterday  daily price of the previous day (cloud); change = now / yesterday - 1
--   trend      PPO of the daily prices, EMA 3 days / EMA 14 days - 1 (cloud)
--   direction  1 rising, -1 falling, 0 sideways (EMA 3 / 7 / 14 in order or not)
--   vendorSell what a merchant pays, vendorBuy what a merchant charges (nil if unknown)
-- }
-- Derived (the only formulas for these):
--   Item.SellNet(e)  selling one unit: the lower of (cheapest offer - 1 copper) and the
--                    average, minus the 5 % cut; a merchant if he pays more (same rule as
--                    the cloud's ahprofessions)
--   Item.BuyCost(e)  buying one unit: merchant, else cheapest offer, else the average
--   Item.Value(e)    what one unit is worth to the player (= SellNet)
-- Producers report live observations with Item.Observe (single item searches).
-- Pure Lua apart from guarded game calls, so tools/ can load it too.
local ADDON, ns = ...

local CUT = 0.05
local HOUSE = 113

-- Classic merchant prices of common reagents, until a merchant visit records the real one.
local VENDOR_ESTIMATE = {
  [2320] = 10, [2321] = 100, [4291] = 500, [8343] = 2000, [14341] = 5000,
  [4289] = 50, [4340] = 350, [2324] = 25, [2604] = 50, [2605] = 100,
  [6260] = 50, [6261] = 1000, [2325] = 1000,
}

local Item = {}
local observed = {}   -- itemID -> { now, t } from single item searches (this session)

local function collector(itemID)
  local house = ns.AHData and ns.AHData[HOUSE]
  return house and house.items[itemID], house
end

-- UTC "2026-11-17T09:18:56Z" -> epoch seconds (cached).
local epochCache = {}
local function epoch(iso)
  if not iso or not time then return nil end
  if epochCache[iso] == nil then
    local y, mo, d, h, mi, s = iso:match("^(%d+)-(%d+)-(%d+)T(%d+):(%d+):(%d+)Z$")
    local t = false
    if y then
      -- time() reads the table as local time; shift by the local UTC offset.
      local now = time()
      local offset = now - time(date("!*t", now))
      t = time({ year = tonumber(y), month = tonumber(mo), day = tonumber(d), hour = tonumber(h),
        min = tonumber(mi), sec = tonumber(s), isdst = false }) + offset
    end
    epochCache[iso] = t
  end
  return epochCache[iso] or nil
end

local function clientVendorSell(itemID)
  local getInfo = (C_Item and C_Item.GetItemInfo) or GetItemInfo
  local price = getInfo and select(11, getInfo(itemID))
  if type(price) == "number" then return price end
  local known = ns.db and ns.db.vendorSell and ns.db.vendorSell[itemID]
  return known
end

function Item.Get(itemID)
  local row, house = collector(itemID)
  local e = { itemID = itemID }
  -- now: the newest source wins.
  local bestT = -1
  if row then
    bestT = epoch(house.updated) or 0
    e.cheapest, e.now, e.offers, e.quantity = row[1], row[2] or row[1], row[7], row[8]
  end
  local ah = ns.db and ns.db.ah
  if ah and ah.currentT and ah.currentT > bestT then
    local live = ah.current and ah.current[itemID]
    -- own scan row: { min, marketValue, quantity, offers, sellers }
    e.cheapest = live and live[1] and live[1] > 0 and live[1] or nil
    e.now = live and live[2] and live[2] > 0 and live[2] or e.cheapest
    e.quantity, e.offers = live and live[3] or 0, live and live[4] or 0
    bestT = ah.currentT
  end
  local o = observed[itemID]
  if o and o.t > bestT then
    e.cheapest = o.now
    -- The cheap offers are gone: the market is at least where the cheapest one is now.
    if o.now and e.now and o.now > e.now then e.now = o.now end
    if not o.now then e.now = nil end
  end
  if row then
    e.min, e.avg, e.max = row[11], row[12], row[13]
    e.demand, e.certain = row[18], row[19]
    e.yesterday, e.trend, e.direction = row[15], row[16], row[17]
  end
  -- Same formula as the cloud (ahmetrics change24), with the newest price we have.
  if e.now and e.yesterday and e.yesterday > 0 then e.change = e.now / e.yesterday - 1 end
  local vs = clientVendorSell(itemID)
  e.vendorSell = vs and vs > 0 and vs or nil
  e.vendorBuy = (ns.db and ns.db.vendorBuy and ns.db.vendorBuy[itemID]) or VENDOR_ESTIMATE[itemID]
  return e
end

-- All offers of the item in the own full scan, cheapest first: { { unit, count }... }, and
-- the scan time; nil without a scan. (The only place that reads the scan's listings.)
function Item.Listings(itemID)
  local last = ns.db and ns.db.ah and ns.db.ah.last
  local keys = last and last.items and last.items[itemID]
  if not keys then return nil, last and last.t end
  local list = {}
  for _, key in ipairs(keys) do
    local unit, count = key:match("^(%d+):(%d+):")
    if unit then table.insert(list, { unit = tonumber(unit), count = tonumber(count) }) end
  end
  table.sort(list, function(x, y) return x.unit < y.unit end)
  return list, last.t
end

-- Hourly history of the last 48 hours from the collector (Data_History.lua, every listed
-- item, compact format; the older table format is read too): { start = epoch of the first slot, step = 3600,
--   prices = { cheapest offer per hour, 0 = not listed, false = no snapshot }, qty = {...} }
-- or nil. The live copy from the data addon (m4-companion_Data, kept current by the
-- companion app, global M4CompanionData) wins over the one shipped with this addon.
-- Looked up per call: the data addon loads after this one.
local function historyTable()
  local live = rawget(_G, "M4CompanionData")
  if type(live) == "table" and type(live.History) == "table" then return live.History end
  return ns.History
end

-- One compact list "350,,,-,0,725": empty = same as before, "-" = no snapshot (false).
local function decodeSlots(text, n)
  local out, prev, i = {}, false, 0
  for tok in (text .. ","):gmatch("([^,]*),") do
    i = i + 1
    if tok == "-" then prev = false
    elseif tok ~= "" then prev = tonumber(tok) or false end
    out[i] = prev
  end
  for k = i + 1, n or i do out[k] = false end
  return out
end

local decoded = setmetatable({}, { __mode = "k" }) -- history table -> itemID -> result

local function historyFrom(history, itemID)
  if not history then return nil end
  if type(history.items) == "table" then
    -- Compact format (all listed items): ns.History = { start, step, n, items = { [id] = "p;q" } }
    local cache = decoded[history]
    if not cache then cache = {}; decoded[history] = cache end
    if cache[itemID] ~= nil then return cache[itemID] or nil end
    local text = history.items[itemID]
    local result = false
    if type(text) == "string" then
      local p, q = text:match("^([^;]*);(.*)$")
      if p then
        result = { start = history.start, step = history.step or 3600,
          prices = decodeSlots(p, history.n), qty = decodeSlots(q, history.n) }
      end
    end
    cache[itemID] = result
    return result or nil
  end
  local h = history[itemID]
  if type(h) ~= "table" then return nil end
  return { start = h[1], step = h.step or 3600, prices = h.prices or {}, qty = h.qty or {} }
end

-- The app's live copy first; an item it does not know (older or smaller file) from the copy
-- shipped with the addon.
function Item.History(itemID)
  local live = historyTable()
  return historyFrom(live, itemID) or (live ~= ns.History and historyFrom(ns.History, itemID)) or nil
end

-- Items in the own full scan (itemID -> true).
function Item.ScannedItems()
  local last = ns.db and ns.db.ah and ns.db.ah.last
  return last and last.items or {}
end

-- A single item search saw this cheapest offer (nil = none on offer) right now.
function Item.Observe(itemID, cheapest, t)
  observed[itemID] = { now = cheapest, t = t or (time and time()) or 0 }
end

function Item.SellNet(e)
  -- Sustained price: undercut the cheapest offer, but never above the 14-day average
  -- (one seller listing far above the usual price does not make it sellable there).
  local base = e.now and (e.now - 1) or e.avg
  if base and e.avg then base = math.min(base, e.avg) end
  local ah = base and base > 0 and math.floor(base * (1 - CUT)) or 0
  local vendor = e.vendorSell or 0
  if ah > 0 and ah >= vendor then return ah, true end
  return vendor, false
end

function Item.BuyCost(e)
  if e.vendorBuy then return e.vendorBuy, true end
  return e.now or e.avg, false
end

-- The current price is far from the average (more than 50 % above or below): a single
-- offer that may not be the market. Views mark such prices as "unsicher".
function Item.Unsure(e)
  return e.now ~= nil and e.avg ~= nil and e.avg > 0 and (e.now > e.avg * 1.5 or e.now < e.avg * 0.5)
end

function Item.Value(e)
  return (Item.SellNet(e))
end

-- "+49 % steigt" for views; nil without data. The word follows the number (3-day vs 14-day
-- average): from +3 % "steigt", from -3 % "fällt", in between "seitwärts" - so a -1 % item is
-- not called falling.
function Item.TrendText(e)
  if not e.trend then return nil end
  local word = e.trend >= 0.03 and "steigt" or (e.trend <= -0.03 and "fällt" or "seitwärts")
  return string.format("%+d %% %s", math.floor(e.trend * 100 + (e.trend >= 0 and 0.5 or -0.5)), word)
end

-- Demand levels (the cloud's demand scale).
Item.DEMAND_LEVELS = { { 20, "sehr hoch" }, { 5, "hoch" }, { 1, "mittel" }, { 0.05, "niedrig" } }

-- "hoch" etc. for views; nil without data.
function Item.DemandText(e)
  if e.demand == nil then return nil end
  for _, level in ipairs(Item.DEMAND_LEVELS) do
    if e.demand >= level[1] then return level[2] end
  end
  return "kaum"
end

Item.CUT = CUT
ns.Item = setmetatable(Item, { __call = function(_, itemID) return Item.Get(itemID) end })
