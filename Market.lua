-- Market: realistic auction value from TradeSkillMaster's region data.
-- Pure logic (no game API), so the tools in tools/ use it too.
--
-- The cheapest offer in the auction house says what a seller asks, not what a
-- buyer pays. TSM records actual sales across the region, so the expected
-- revenue of posting one unit is
--   saleRate * price * (1 - cut) + (1 - saleRate) * vendor
-- price = average sale price, or the current offer if that is lower (you have
-- to undercut it). Units that do not sell are counted as sold to a vendor.
local ADDON, ns = ...

local Market = {}
ns.Market = Market

local CUT = 0.05

function Market.Info(itemID)
  local data = ns.MarketData
  local row = data and data.items[itemID]
  if not row then return nil end
  return { marketValue = row[1], avgSale = row[2], saleRate = row[3], soldPerDay = row[4] }
end

function Market.Updated()
  return ns.MarketData and ns.MarketData.updated
end

-- History of the item in our own scans (AuctionStats.History), or nil.
-- Only used once the item was seen on at least two scan days.
function Market.Own(itemID)
  local ah = ns.db and ns.db.ah
  if not (ah and ah.days and ns.AuctionStats) then return nil end
  local history = ns.AuctionStats.History(ah.days, itemID)
  if not history or history.days < 2 then return nil end
  return history
end

-- Expected copper per unit when posted at auction, or nil when it does not sell.
--   currentAH  cheapest current offer (copper) or nil
--   vendor     what a merchant pays (copper) or 0
-- Our own auction house data comes first (price of estimated sales, else market
-- value; estimated sale rate), TSM's region data fills what is missing.
-- Second return value: true when the estimate rests on recorded or estimated sales.
function Market.Expected(itemID, currentAH, vendor)
  vendor = vendor or 0
  local own = Market.Own(itemID)
  local info = Market.Info(itemID)

  local price = own and (own.salePrice or own.mv) or nil
  if not price and info and info.avgSale > 0 then price = info.avgSale end
  local rate = own and own.saleRate
  if rate == nil and info then rate = info.saleRate end

  if rate == nil then
    -- No sales record at all: only an asking price is known, which is unverified.
    local ask = price or currentAH
    return ask and math.floor(ask * (1 - CUT)) or nil, false
  end
  if rate <= 0 or not price or price <= 0 then return nil, true end
  if currentAH and currentAH < price then price = currentAH end
  local value = rate * price * (1 - CUT) + (1 - rate) * vendor
  return math.floor(value), true
end

local function demandText(rate, perDay)
  return string.format("%d %%, %s/Tag", math.floor(rate * 100 + 0.5),
    perDay >= 10 and string.format("%d", math.floor(perDay)) or string.format("%.1f", perDay))
end

local function demandColor(rate, perDay)
  if rate >= 0.5 and perDay >= 5 then return "|cff40ff40" end
  if rate >= 0.2 and perDay >= 1 then return "|cffffd100" end
  return "|cffff9900"
end

-- Short demand label and color code for the UI. "AH" = our own scans,
-- "EU" = TSM region data.
function Market.Demand(itemID)
  local own = Market.Own(itemID)
  if own and own.saleRate then
    if own.saleRate <= 0 then return "AH: nie verkauft", "|cffff6060" end
    return "AH: " .. demandText(own.saleRate, own.soldPerDay), demandColor(own.saleRate, own.soldPerDay)
  end
  local info = Market.Info(itemID)
  if not info then return "keine Verkaufsdaten", "|cff9d9d9d" end
  if info.saleRate <= 0 or info.soldPerDay <= 0 then return "EU: nie verkauft", "|cffff6060" end
  return "EU: " .. demandText(info.saleRate, info.soldPerDay), demandColor(info.saleRate, info.soldPerDay)
end
