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
  maxPrice = 0,         -- maximum unit price; 0 means no limit
  minProfit = 2000,     -- 20 silver per item line after the 5 % cut
  minDemand = 2,        -- ns.Item demand (cloud scale) for a hit
  watchMax = 150,       -- items on the watch list
  watchMinDemand = 2,   -- ns.Item demand for the watch list
  sellDays = 2,         -- price stair: what is bought must sell within this many days
  minGap = 0.15,        -- price stair: every bought level at least 15 % below the net resale price
  recipeWatch = true,   -- watch the tradeable recipes of ns.RecipeWatch as well (own category)
  recipeMax = 0.7,      -- recipe hit: offer at most this share of its usual price (most are listed near it)
}
local CUT = 0.05

function Deals.Settings()
  local s = ns.db and ns.db.settings and ns.db.settings.sniper or {}
  local out = {}
  for k, v in pairs(Deals.DEFAULTS) do
    if s[k] ~= nil then out[k] = s[k] else out[k] = v end -- keeps a stored false
  end
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

-- Reference value and a short source text, or nil. Sources: "AH-Preis" (house price of the
-- current offers), "gestern" (yesterday's daily price), "Ø 14 Tage" (ns.Item average).
function Deals.Reference(itemID, house)
  local e = ns.Item(itemID)
  local avg, label = e.avg, "Ø 14 Tage"
  -- While our own history is short, the average leans on the TSM start value, which can be
  -- far above this realm (Untoter Motor: 16g average, 4g real). Buying never trusts more
  -- than yesterday's real daily price here.
  if e.yesterday and (not avg or e.yesterday < avg) then avg, label = e.yesterday, "gestern" end
  if house and (not avg or house < avg) then return house, "AH-Preis" end
  if avg then return avg, label end
  return nil
end

local function liquid(itemID)
  local demand = ns.Item(itemID).demand
  return demand ~= nil and demand >= Deals.Settings().minDemand
end

Deals.HousePrice = housePrice
Deals.Liquid = liquid
Deals.CUT = CUT

-- Price stair (detail check of the sniper; the "next listing" rule is its first step).
-- For one searched item: every price level P of the foreign offers is a candidate selling
-- price. Buying means clearing the stair below P: all foreign units cheaper than P are bought
-- (N units, cost C) and sold again at resale = min(P - 1, cap). P is valid only when
--   1. N <= perDay * sellDays (sells within sellDays; perDay = certain sales, else demand)
--   2. a real middle field: the foreign units in [P, P * 1.25] are at least MIDFIELD and at
--      least as many as the units bought. Otherwise the cheap units ARE the market and the
--      few above them are just overpriced offers (Bauplan: Thoriumpatronen, 20 cheap, 4 above)
--   3. resale never above cap (ns.Item average, else the reference)
--   4. every bought level pays off on its own: unit <= resale * (1 - CUT) * (1 - minGap)
--   5. every bought unit stays at or below the optional maxPrice setting
-- The P with the highest profit N * resale * (1 - CUT) - C wins.
-- listings = { { unit, count, own }... }. Returns nil or
--   { level = P, sellAt = resale, sellSource = "Mittelfeld" | "Ø-Obergrenze", buyUpTo, units,
--     cost, profit, best, auctions = bought listings (cheapest first) }.
Deals.MIDFIELD, Deals.MIDFIELD_SPAN = 3, 1.25
function Deals.Staircase(listings, cap, perDay, set)
  if not cap or cap <= 0 then return nil end
  set = set or Deals.Settings()
  local foreign = {}
  for _, l in ipairs(listings) do
    if not l.own and l.unit and l.unit > 0 then table.insert(foreign, l) end
  end
  table.sort(foreign, function(a, b) return a.unit < b.unit end)
  local maxUnits = (perDay or 0) * set.sellDays
  local best
  for i, candidate in ipairs(foreign) do
    local P = candidate.unit
    if i > 1 and foreign[i - 1].unit < P then -- each price level once, something below it
      local resale = math.min(P - 1, cap)
      local ceiling = resale * (1 - CUT) * (1 - set.minGap)
      local units, cost, ok = 0, 0, true
      for j = 1, i - 1 do
        local l = foreign[j]
        if l.unit > ceiling or (set.maxPrice > 0 and l.unit > set.maxPrice) then ok = false break end
        units, cost = units + l.count, cost + l.unit * l.count
      end
      if ok and units > maxUnits then ok = false end
      if ok then
        local mid = 0
        for j = i, #foreign do
          if foreign[j].unit > P * Deals.MIDFIELD_SPAN then break end
          mid = mid + foreign[j].count
        end
        ok = mid >= Deals.MIDFIELD and mid >= units
      end
      if ok then
        local profit = units * resale * (1 - CUT) - cost
        if not best or profit > best.profit then
          local bought = {}
          for j = 1, i - 1 do table.insert(bought, foreign[j]) end
          best = { level = P, sellAt = resale, sellSource = resale < cap and "Mittelfeld" or "Ø-Obergrenze",
            buyUpTo = foreign[i - 1].unit, units = units, cost = cost, profit = profit, best = foreign[1].unit,
            auctions = bought }
        end
      end
    end
  end
  return best
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
