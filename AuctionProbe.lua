-- AuctionProbe: records which auction house API this client offers, so the
-- listing recorder can be built on the right one. Runs on every AH visit.
local ADDON, ns = ...

local function has(fn) return type(fn) == "function" end

ns.On("AUCTION_HOUSE_SHOW", function()
  local modern = C_AuctionHouse or {}
  ns.db.ahApi = {
    t = time(),
    replicateItems = has(modern.ReplicateItems),
    getReplicateItemInfo = has(modern.GetReplicateItemInfo),
    getReplicateItemTimeLeft = has(modern.GetReplicateItemTimeLeft),
    getItemSearchResultInfo = has(modern.GetItemSearchResultInfo),
    queryAuctionItems = has(QueryAuctionItems),
    getAuctionItemInfo = has(GetAuctionItemInfo),
    getAuctionItemTimeLeft = has(GetAuctionItemTimeLeft),
    canSendAuctionQuery = has(CanSendAuctionQuery),
  }
end)
