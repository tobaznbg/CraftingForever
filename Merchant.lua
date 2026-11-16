-- Merchant: records what vendors charge for items with unlimited stock
-- (threads, salt, dyes), so recipe costs use real vendor prices.
local ADDON, ns = ...

local function itemInfo(index)
  if C_MerchantFrame and C_MerchantFrame.GetItemInfo then
    local info = C_MerchantFrame.GetItemInfo(index)
    if info then
      return info.price, info.stackCount, info.numAvailable
    end
  end
  if GetMerchantItemInfo then
    local _, _, price, quantity, numAvailable = GetMerchantItemInfo(index)
    return price, quantity, numAvailable
  end
  return nil
end

local function scanMerchant()
  ns.db.vendorBuy = ns.db.vendorBuy or {}
  for index = 1, (GetMerchantNumItems() or 0) do
    local link = GetMerchantItemLink(index)
    local itemID = link and tonumber(link:match("item:(%d+)"))
    local price, stack, available = itemInfo(index)
    -- Only unlimited stock is a reliable source; limited items are one-off offers.
    if itemID and price and price > 0 and available == -1 then
      ns.db.vendorBuy[itemID] = math.floor(price / math.max(1, stack or 1) + 0.5)
    end
  end
end

ns.On("MERCHANT_SHOW", function() scanMerchant() end)
ns.On("MERCHANT_UPDATE", function() scanMerchant() end)
