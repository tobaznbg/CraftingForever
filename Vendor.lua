-- Vendor: auction house tab "Händler" - offers below what a merchant pays for the item.
-- Buy them and sell them to a merchant (no auction house cut). Offers come from the own
-- full scan (opening the tab starts one, every 15 min at most), prices from ns.Item.
local ADDON, ns = ...

local function money(c) return c and ns.FormatMoney(c, true) or "–" end

ns.AHTable.Add({
  id = "Vendor", label = "Händler", title = "Händler – im AH billiger als beim Händler",
  sort = "total",
  onOpen = function() if ns.AuctionScan then ns.AuctionScan.EnsureFresh() end end,
  info = function() return ns.AuctionScan and ns.AuctionScan.LiveInfo() or nil end,
  columns = {
    { key = "name", title = "Item", width = 0, align = "LEFT" },
    { key = "cheapest", title = "ab", width = 85, filter = "money", fmt = function(e) return money(e.cheapest) end },
    { key = "vendor", title = "Händler zahlt", width = 95, muted = true, fmt = function(e) return money(e.vendor) end },
    { key = "units", title = "Stück", width = 60, filter = "num", fmt = function(e) return tostring(e.units) end },
    { key = "cost", title = "Einsatz", width = 85, muted = true, filter = "money", fmt = function(e) return money(e.cost) end },
    { key = "total", title = "Gewinn", width = 85, filter = "money",
      fmt = function(e) return "|cff5fd38d" .. money(e.total) .. "|r" end },
  },
  rows = function()
    local list = {}
    for itemID in pairs(ns.Item.ScannedItems()) do
      local item = ns.Item(itemID)
      local vendor = item.vendorSell
      if vendor and item.cheapest and item.cheapest < vendor then
        local units, cost, total = 0, 0, 0
        for _, l in ipairs(ns.Item.Listings(itemID) or {}) do
          if l.unit >= vendor then break end
          units, cost, total = units + l.count, cost + l.unit * l.count, total + (vendor - l.unit) * l.count
        end
        if total > 0 then
          table.insert(list, { itemID = itemID, cheapest = item.cheapest, vendor = vendor, units = units,
            cost = cost, total = total })
        end
      end
    end
    return list
  end,
})

-- New scan: recompute (AuctionScan loads after this file).
ns.OnReady(function()
  if ns.AuctionScan and ns.AuctionScan.OnDone then
    ns.AuctionScan.OnDone(function() ns.AHTable.Rebuild() end)
  end
end)
