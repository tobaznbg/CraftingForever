-- Prices: item values from our own auction house scans and the item's vendor sell price.
local ADDON, ns = ...

local Prices = {}
ns.Prices = Prices

-- Auction house cut taken from the seller on a successful sale.
Prices.AH_CUT = 0.05

-- True once our own auction house scan has run at least once.
function Prices.HasScan()
  return ns.AuctionScan and ns.AuctionScan.HasData() or false
end

-- Cheapest buyout per unit in our latest full scan, in copper, or nil.
-- Falls back to the price snapshot taken when the profession window was open.
function Prices.Auction(itemID)
  local ah = ns.db and ns.db.ah
  local row = ah and ah.current and ah.current[itemID]
  if row and row[1] and row[1] > 0 then return row[1] end
  if ah and ah.lastScanT then
    -- A full scan exists and the item was not in it: no current offer.
    return nil
  end
  local stored = ns.db and ns.db.prices and ns.db.prices[itemID]
  return stored and stored.ah or nil
end

-- Market value (cheapest 15-30 % of listings) in our latest scan, or nil.
function Prices.MarketValue(itemID)
  local ah = ns.db and ns.db.ah
  local row = ah and ah.current and ah.current[itemID]
  return row and row[2] or nil
end

-- What a merchant pays for one unit, in copper, or nil if unknown/unsellable.
function Prices.Vendor(itemID)
  local getInfo = (C_Item and C_Item.GetItemInfo) or GetItemInfo
  if not getInfo then return nil end
  local sellPrice = select(11, getInfo(itemID))
  if type(sellPrice) == "number" and sellPrice > 0 then
    return sellPrice
  end
  return nil
end

-- Value of one unit if sold: auction price after cut, but never below vendor price.
-- Returns value, auctionPrice, vendorPrice.
function Prices.Value(itemID)
  local ah = Prices.Auction(itemID)
  local vendor = Prices.Vendor(itemID)
  local value = vendor or 0
  if ah then
    value = math.max(value, math.floor(ah * (1 - Prices.AH_CUT)))
  end
  return value, ah, vendor
end
