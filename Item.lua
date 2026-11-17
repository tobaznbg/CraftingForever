-- Item: the one place for an item's market data. Every module takes its numbers from
-- here; nothing else reads price sources (collector export, own scans, searches).
--
-- ns.Item(itemID) -> {
--   now        cheapest offer right now (copper per unit), nil if not on offer; from
--              the newest of: collector snapshot, own full scan, single item searches
--   offers, quantity   auctions / units listed at that time (internal, not shown)
--   min, avg, max      lowest / average / highest hourly cheapest offer of the last
--                      two weeks (collector; at the start blended with TSM start values)
--   demand     relative demand from the cloud (scale: TSM's real EU sales per day; our own
--              estimate calibrated to it). Shown as a level, not as units: Item.DemandText
--   yesterday  daily price of the previous day (cloud); change = now / yesterday - 1
--   trend      PPO of the daily prices, EMA 3 days / EMA 14 days - 1 (cloud)
--   direction  1 rising, -1 falling, 0 sideways (EMA 3 / 7 / 14 in order or not)
--   vendorSell what a merchant pays, vendorBuy what a merchant charges (nil if unknown)
-- }
-- Derived (the only formulas for these):
--   Item.SellNet(e)  selling one unit: undercut the cheapest offer by 1 copper, minus the
--                    5 % cut (no offer: the average); a merchant if he pays more
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
    e.now, e.offers, e.quantity = row[1], row[7], row[8]
  end
  local ah = ns.db and ns.db.ah
  if ah and ah.currentT and ah.currentT > bestT then
    local live = ah.current and ah.current[itemID]
    -- own scan row: { min, marketValue, quantity, offers, sellers }
    e.now = live and live[1] and live[1] > 0 and live[1] or nil
    e.quantity, e.offers = live and live[3] or 0, live and live[4] or 0
    bestT = ah.currentT
  end
  local o = observed[itemID]
  if o and o.t > bestT then e.now = o.now end
  if row then
    e.min, e.avg, e.max = row[11], row[12], row[13]
    e.demand = row[18]
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
  local base = e.now and (e.now - 1) or e.avg
  local ah = base and base > 0 and math.floor(base * (1 - CUT)) or 0
  local vendor = e.vendorSell or 0
  if ah > 0 and ah >= vendor then return ah, true end
  return vendor, false
end

function Item.BuyCost(e)
  if e.vendorBuy then return e.vendorBuy, true end
  return e.now or e.avg, false
end

function Item.Value(e)
  return (Item.SellNet(e))
end

local DIRECTION = { [1] = "steigt", [-1] = "fällt", [0] = "seitwärts" }

-- "+49 % steigt" for views; nil without data.
function Item.TrendText(e)
  if not e.trend then return nil end
  return string.format("%+d %% %s", math.floor(e.trend * 100 + (e.trend >= 0 and 0.5 or -0.5)),
    DIRECTION[e.direction or 0] or "")
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
