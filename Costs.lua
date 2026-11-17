-- Costs: profession helpers for the planner. Prices come from ns.Item only.
local ADDON, ns = ...

local Costs = {}
ns.Costs = Costs

-- Copper per unit to buy a reagent, and where ("Händler" or "AH").
function Costs.Buy(itemID)
  local unit, vendor = ns.Item.BuyCost(ns.Item(itemID))
  if not unit then return nil end
  return unit, vendor and "Händler" or "AH"
end

function Costs.VendorSell(itemID)
  return ns.Item(itemID).vendorSell or 0
end

-- Copper per unit an auction brings (Item.SellNet), or nil if it only goes to a merchant.
function Costs.AuctionSell(itemID)
  local net, viaAH = ns.Item.SellNet(ns.Item(itemID))
  return viaAH and net or nil
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
