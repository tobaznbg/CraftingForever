-- Trends: auction house tab with rising and falling items (ns.Item: trend = PPO of the
-- daily prices, EMA 3 days against EMA 14 days; direction from EMA 3 / 7 / 14).
local ADDON, ns = ...

local function money(c) return c and ns.FormatMoney(c, true) or "–" end
local function pct(v)
  if not v then return "–" end
  local s = string.format("%+d %%", math.floor(v * 100 + (v >= 0 and 0.5 or -0.5)))
  return (v >= 0 and "|cff5fd38d" or "|cffff6b6b") .. s .. "|r"
end

ns.AHTable.Add({
  id = "Trends", label = "Trends", title = "Trends – steigende und fallende Preise",
  -- Much sold first: in thin markets one odd listing makes a "trend" of +5000 %.
  sort = "perDay",
  views = { { "up", "Steigend" }, { "down", "Fallend" } },
  defaultFilters = { perDay = "2" },
  onOpen = function() if ns.AuctionScan then ns.AuctionScan.EnsureFresh() end end,
  columns = {
    { key = "name", title = "Item", width = 0, align = "LEFT" },
    { key = "now", title = "Preis jetzt", width = 95, filter = "money", fmt = function(e) return money(e.now) end },
    { key = "change", title = "seit gestern", width = 90, filter = "pct", fmt = function(e) return pct(e.change) end },
    { key = "trend", title = "Trend", width = 80, filter = "pct", fmt = function(e) return pct(e.trend) end },
    { key = "perDay", title = "Verk./Tag", width = 80, muted = true, filter = "num",
      fmt = function(e) return string.format("%.0f", e.perDay) end },
  },
  rows = function(view)
    local list, house = {}, ns.AHData and ns.AHData[113]
    local want = view == "up" and 1 or -1
    for itemID in pairs(house and house.items or {}) do
      local item = ns.Item(itemID)
      if item.direction == want and item.trend then
        table.insert(list, { itemID = itemID, now = item.now, change = item.change, trend = item.trend,
          perDay = item.perDay or 0 })
      end
    end
    return list
  end,
})

-- New live prices: recompute (AuctionScan loads after this file).
ns.OnReady(function()
  if ns.AuctionScan and ns.AuctionScan.OnDone then
    ns.AuctionScan.OnDone(function() ns.AHTable.Rebuild() end)
  end
end)
