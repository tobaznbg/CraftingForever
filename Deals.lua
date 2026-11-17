-- Deals: rules for "far below its usual price", used by the sniper (live searches). Market data comes from ns.Item.
--   house price  = unit price at which a quarter of the listed quantity is reached
--                  (a few cheap outliers don't move it; a flooded market does)
--   reference    = the lower of the house price and the average (ns.Item)
-- An offer is a deal at or below maxShare of the reference, for items with demand
-- >= minDemand (ns.Item), when at least minProfit remains after the cut (Deals.Settings).
local ADDON, ns = ...

local Deals = {}
ns.Deals = Deals

-- Settings of the sniper, adjustable in the main window (ns.db.settings.sniper).
Deals.DEFAULTS = {
  maxShare = 0.6,       -- offer at most 60 % of the reference
  minProfit = 2000,     -- 20 silver per item line after the 5 % cut
  minDemand = 2,        -- ns.Item demand (cloud scale) for a hit
  watchMax = 150,       -- items on the watch list
  watchMinDemand = 2,   -- ns.Item demand for the watch list
}
local CUT = 0.05

function Deals.Settings()
  local s = ns.db and ns.db.settings and ns.db.settings.sniper or {}
  local out = {}
  for k, v in pairs(Deals.DEFAULTS) do out[k] = s[k] ~= nil and s[k] or v end
  return out
end

function Deals.Set(key, value)
  ns.db.settings = ns.db.settings or {}
  ns.db.settings.sniper = ns.db.settings.sniper or {}
  ns.db.settings.sniper[key] = value
end

-- Current values (the old constants).
function Deals.MaxShare() return Deals.Settings().maxShare end
function Deals.MinProfit() return Deals.Settings().minProfit end

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
  local e = ns.Item(itemID)
  local avg = e.avg
  -- While our own history is short, the average leans on the TSM start value, which can be
  -- far above this realm (Untoter Motor: 16g average, 4g real). Buying never trusts more
  -- than yesterday's real daily price here.
  if e.yesterday and (not avg or e.yesterday < avg) then avg = e.yesterday end
  if house and (not avg or house < avg) then return house, "AH-Preis" end
  if avg then return avg, "Ø" end
  return nil
end

local function liquid(itemID)
  local demand = ns.Item(itemID).demand
  return demand ~= nil and demand >= Deals.Settings().minDemand
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
