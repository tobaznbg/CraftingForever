-- Item: the one place for an item's market data. Every view uses these values and
-- derives from them; nothing else reads price sources directly.
--
-- ns.Item(itemID) -> {
--   now        cheapest offer right now (copper per unit), nil if not on offer;
--              from the newer of the own live scan and the collector's last snapshot
--   min, avg, max  lowest / average / highest hourly cheapest offer of the last two
--              weeks (collector; at the start blended with the TSM start value)
--   perDay     units sold per day in our auction house (collector estimate: vanished
--              before expiry; a cancelled cheapest offer counts as a sale, so rather high)
--   vendorSell what a merchant pays, vendorBuy what a merchant charges (if known)
-- }
-- Derived helpers: Item.SellNet (what selling brings), Item.BuyCost (what buying costs).
local ADDON, ns = ...

local CUT = 0.05

local Item = {}

local function collector(itemID)
  local house = ns.AHData and ns.AHData[113]
  return house and house.items[itemID], house
end

-- UTC "2026-11-17T09:18:56Z" -> epoch seconds.
local updatedEpoch = {}
local function epoch(iso)
  if not iso then return nil end
  if updatedEpoch[iso] == nil then
    local y, mo, d, h, mi, s = iso:match("^(%d+)-(%d+)-(%d+)T(%d+):(%d+):(%d+)Z$")
    local t = false
    if y then
      -- time() takes local time; correct by the offset between local and UTC now.
      local fields = { year = tonumber(y), month = tonumber(mo), day = tonumber(d),
        hour = tonumber(h), min = tonumber(mi), sec = tonumber(s), isdst = false }
      local now = time()
      local offset = now - time(date("!*t", now))
      t = time(fields) + offset
    end
    updatedEpoch[iso] = t
  end
  return updatedEpoch[iso] or nil
end

local function vendorSell(itemID)
  local getInfo = (C_Item and C_Item.GetItemInfo) or GetItemInfo
  local price = getInfo and select(11, getInfo(itemID))
  return type(price) == "number" and price > 0 and price or nil
end

local function get(itemID)
  local row, house = collector(itemID)
  local e = { itemID = itemID }
  -- now: the newer source wins.
  local ah = ns.db and ns.db.ah
  local liveT = ah and ah.currentT
  local houseT = house and epoch(house.updated)
  if liveT and (not houseT or liveT > houseT) then
    local live = ah.current and ah.current[itemID]
    e.now = live and live[1] and live[1] > 0 and live[1] or nil
  elseif row then
    e.now = row[1]
  end
  if row then
    e.min, e.avg, e.max = row[11], row[12], row[13]
    e.perDay = row[5]
  end
  e.vendorSell = vendorSell(itemID)
  e.vendorBuy = ns.db and ns.db.vendorBuy and ns.db.vendorBuy[itemID] or nil
  return e
end

-- What selling one unit brings: undercut the cheapest offer by 1 copper, minus the
-- cut; a merchant price counts when it is higher. Second value: true if via the AH.
function Item.SellNet(e)
  local ah = e.now and math.floor((e.now - 1) * (1 - CUT)) or 0
  local vendor = e.vendorSell or 0
  if ah >= vendor and ah > 0 then return ah, true end
  return vendor, false
end

-- What buying one unit costs: the merchant if he sells it, else the cheapest offer.
-- Second value: true if from a merchant.
function Item.BuyCost(e)
  if e.vendorBuy then return e.vendorBuy, true end
  return e.now, false
end

Item.Get = get
ns.Item = setmetatable(Item, { __call = function(_, itemID) return get(itemID) end })
