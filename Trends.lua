-- Trends: auction house tab with items whose price moves away from its average.
--   trend = cheapest offer now against the average of the last two weeks (ns.Item)
local ADDON, ns = ...

local MIN_MOVE = 0.10   -- at least 10 % away from the average

local Trends = {}
ns.Trends = Trends

-- Price now, average and the change between them, or nil without data.
function Trends.Info(itemID)
  local item = ns.Item(itemID)
  if not item.now or not item.avg or item.avg <= 0 then return nil end
  return item.now, item.avg, item.now / item.avg - 1, item
end

local function money(c) return c and ns.FormatMoney(c, true) or "–" end
local function pct(v)
  if not v then return "–" end
  local s = string.format("%+d %%", math.floor(v * 100 + (v >= 0 and 0.5 or -0.5)))
  return (v >= 0 and "|cff5fd38d" or "|cffff6b6b") .. s .. "|r"
end

ns.AHTable.Add({
  id = "Trends", label = "Trends", title = "Trends – Preise in deinem Auktionshaus",
  -- Much sold first: in thin markets one odd listing makes a "trend" of +5000 %.
  sort = "perDay",
  views = { { "up", "Steigend" }, { "down", "Fallend" } },
  defaultFilters = { perDay = "2" },
  onOpen = function() if ns.AuctionScan then ns.AuctionScan.EnsureFresh() end end,
  columns = {
    { key = "name", title = "Item", width = 0, align = "LEFT" },
    { key = "now", title = "Preis jetzt", width = 95, filter = "money", fmt = function(e) return money(e.now) end },
    { key = "avg", title = "Ø", width = 95, muted = true, filter = "money", fmt = function(e) return money(e.avg) end },
    { key = "change", title = "Jetzt vs. Ø", width = 90, filter = "pct", fmt = function(e) return pct(e.change) end },
    { key = "perDay", title = "Verk./Tag", width = 80, muted = true, filter = "num",
      fmt = function(e) return string.format("%.0f", e.perDay) end },
  },
  rows = function(view)
    local list, house = {}, ns.AHData and ns.AHData[113]
    for itemID in pairs(house and house.items or {}) do
      local now, avg, change, item = Trends.Info(itemID)
      if now and ((view == "up" and change >= MIN_MOVE) or (view == "down" and change <= -MIN_MOVE)) then
        table.insert(list, { itemID = itemID, now = now, avg = avg, change = change, perDay = item.perDay or 0,
          strength = math.abs(change) })
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
