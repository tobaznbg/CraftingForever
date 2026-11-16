-- Deals: outliers in the last own full scan, i.e. offers far below the price at
-- which this auction house normally trades the item.
--   house price  = unit price at which a quarter of the listed quantity is reached
--                  (a few cheap outliers don't move it; a flooded market does)
--   reference    = lowest of house price, EU sale price, EU market value and,
--                  with a day of collector data, the 7-day median here
-- An offer is a deal at or below 60 % of the reference, for items that sell
-- well (EU data), when at least 20 silver profit remain after the cut.
local ADDON, ns = ...

local Deals = {}
ns.Deals = Deals

Deals.MAX_SHARE = 0.6     -- offer at most 60 % of the reference
Deals.MIN_RATE = 0.5      -- at least half of the listings sell (EU)
Deals.MIN_PER_DAY = 10    -- sold per day (EU)
Deals.MIN_PROFIT = 2000   -- 20 silver per item line after the 5 % cut
local CUT = 0.05
local MIN_COLLECTOR_HOURS = 24

-- Unit price at which `share` of the listed quantity is reached.
-- listings = { { unit = copper, count = n }, ... } (sorted in place).
local function housePrice(listings, share)
  table.sort(listings, function(a, b) return a.unit < b.unit end)
  local total = 0
  for _, l in ipairs(listings) do total = total + l.count end
  local acc = 0
  for _, l in ipairs(listings) do
    acc = acc + l.count
    if acc >= total * share then return l.unit end
  end
end

-- Reference value and a short source text, or nil.
function Deals.Reference(itemID, house)
  local ref, source
  if house then ref, source = house, "AH-Preis" end
  local function take(value, text)
    if value and value > 0 and (not ref or value < ref) then ref, source = value, text end
  end
  local m = ns.MarketData and ns.MarketData.items[itemID]
  if m then
    take(m[2], "EU-Verkauf")
    take(m[1], "EU-Marktwert")
  end
  local house = ns.AHData and ns.AHData[113]
  local row = house and house.items[itemID]
  if row and (house.hours or 0) >= MIN_COLLECTOR_HOURS then take(row[3], "Median 7 T") end
  return ref, source
end

local function liquid(itemID)
  local m = ns.MarketData and ns.MarketData.items[itemID]
  return m and m[3] >= Deals.MIN_RATE and m[4] >= Deals.MIN_PER_DAY
end

Deals.HousePrice = housePrice
Deals.Liquid = liquid
Deals.CUT = CUT

-- List of { itemID, units, cost, profit, best, ref, source }, best first,
-- plus the scan time.
function Deals.Find()
  local ah = ns.db.ah
  local scan = ah and ah.last
  if not scan or not scan.items then return {}, nil end
  local deals = {}
  for itemID, keys in pairs(scan.items) do
    if liquid(itemID) then
      local listings = {}
      for _, key in ipairs(keys) do
        local l = ns.AuctionStats.ParseKey(key)
        if l then table.insert(listings, l) end
      end
      local ref, source = Deals.Reference(itemID, housePrice(listings, 0.25))
      if ref then
        local limit = ref * Deals.MAX_SHARE
        local units, cost, profit, best = 0, 0, 0, nil
        for _, l in ipairs(listings) do
          if l.unit <= limit then
            units = units + l.count
            cost = cost + l.unit * l.count
            profit = profit + (ref * (1 - CUT) - l.unit) * l.count
            best = best and math.min(best, l.unit) or l.unit
          end
        end
        if units > 0 and profit >= Deals.MIN_PROFIT then
          table.insert(deals, { itemID = itemID, units = units, cost = cost, profit = profit,
            best = best, ref = ref, source = source })
        end
      end
    end
  end
  table.sort(deals, function(a, b) return a.profit > b.profit end)
  return deals, scan.t
end

-- Puts the item into the auction house search, so it can be bought as usual.
function Deals.Search(itemID)
  local bar = AuctionHouseFrame and AuctionHouseFrame.SearchBar
  local name = ns.ItemName(itemID)
  if bar and bar.SearchBox then
    bar.SearchBox:SetText(name)
    if bar.StartSearch then bar:StartSearch() end
  end
end
