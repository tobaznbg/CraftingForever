-- Deals: rules for "far below its usual price", used by the sniper (live searches). Market data comes from ns.Item.
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

-- Puts the item into the auction house search, so it can be bought as usual.
function Deals.Search(itemID)
  local bar = AuctionHouseFrame and AuctionHouseFrame.SearchBar
  local name = ns.ItemName(itemID)
  if bar and bar.SearchBox then
    bar.SearchBox:SetText(name)
    if bar.StartSearch then bar:StartSearch() end
  end
end
