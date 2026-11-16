-- Costs: what a reagent costs to buy and what a product sells for, from live
-- prices where possible and the last stored snapshot otherwise.
local ADDON, ns = ...

local Costs = {}
ns.Costs = Costs

-- Classic vendor prices of common reagents, used until the merchant scan has
-- recorded the real price on this server.
local VENDOR_ESTIMATE = {
  [2320] = 10, [2321] = 100, [4291] = 500, [8343] = 2000, [14341] = 5000,
  [4289] = 50, [4340] = 350, [2324] = 25, [2604] = 50, [2605] = 100,
  [6260] = 50, [6261] = 1000, [2325] = 1000,
}

local function stored(itemID)
  return ns.db.prices and ns.db.prices[itemID]
end

-- Copper per unit, and where the price comes from.
function Costs.Buy(itemID)
  local vendor = ns.db.vendorBuy and ns.db.vendorBuy[itemID]
  if vendor then return vendor, "Händler" end
  if VENDOR_ESTIMATE[itemID] then return VENDOR_ESTIMATE[itemID], "Händler" end
  local ah = ns.Prices.Auction(itemID) or (stored(itemID) or {}).ah
  if ah then return ah, "AH" end
  -- Never seen in our auction house: the region market value is the best guess.
  local market = ns.Market.Info(itemID)
  if market and market.marketValue > 0 then return market.marketValue, "AH (TSM)" end
  return nil
end

function Costs.VendorSell(itemID)
  return ns.Prices.Vendor(itemID) or (stored(itemID) or {}).vs or 0
end

-- Expected auction revenue per unit (see Market.Expected), or nil if it does not sell.
function Costs.AuctionSell(itemID)
  local ah = ns.Prices.Auction(itemID) or (stored(itemID) or {}).ah
  return (ns.Market.Expected(itemID, ah, Costs.VendorSell(itemID)))
end

-- Units in bags and bank.
function Costs.Owned(itemID)
  local count = (C_Item and C_Item.GetItemCount) or GetItemCount
  return count and count(itemID, true) or 0
end

-- Latest recipe scan of the player's professions that have planner data:
-- returns a list of { scan, data, rank, max }.
function Costs.Professions()
  local list = {}
  local prefix = ns.CharKey() .. ":"
  local char = ns.db.chars and ns.db.chars[ns.CharKey()]
  for key, scan in pairs(ns.db.recipes or {}) do
    local data = ns.DataBySkillLine and ns.DataBySkillLine[scan.professionID]
    if data and key:sub(1, #prefix) == prefix then
      local rank, max = scan.rank, scan.max
      -- The character snapshot is newer than the last time the window was opened.
      for _, prof in ipairs(char and char.professions or {}) do
        if prof.name == scan.profession then rank, max = prof.rank or rank, prof.max or max end
      end
      table.insert(list, { scan = scan, data = data, rank = rank, max = max, name = scan.profession })
    end
  end
  return list
end

function Costs.Candidates(prof, all)
  return ns.Planner.Candidates(prof.scan.recipes, prof.data,
    Costs.Buy, Costs.VendorSell, Costs.AuctionSell, all)
end
