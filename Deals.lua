-- Deals: rules for "far below its usual price", used by the Schnäppchen view (own
-- full scan) and the sniper (live searches). Market data comes from ns.Item.
--   house price  = unit price at which a quarter of the listed quantity is reached
--                  (a few cheap outliers don't move it; a flooded market does)
--   reference    = the lower of the house price and the average (ns.Item)
-- An offer is a deal at or below 60 % of the reference, for items that sell at least
-- MIN_PER_DAY a day in our house, when at least 20 silver profit remain after the cut.
local ADDON, ns = ...

local Deals = {}
ns.Deals = Deals

Deals.MAX_SHARE = 0.6     -- offer at most 60 % of the reference
Deals.MIN_PER_DAY = 10    -- sold per day in our house (ns.Item)
Deals.MIN_PROFIT = 2000   -- 20 silver per item line after the 5 % cut
local CUT = 0.05

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
  local avg = ns.Item(itemID).avg
  if house and (not avg or house < avg) then return house, "AH-Preis" end
  if avg then return avg, "Ø" end
  return nil
end

local function liquid(itemID)
  local perDay = ns.Item(itemID).perDay
  return perDay ~= nil and perDay >= Deals.MIN_PER_DAY
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
