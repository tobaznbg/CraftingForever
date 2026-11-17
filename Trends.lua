-- Trends: auction house tab with items whose price is clearly rising or falling.
--   EU trend   = TSM region market value (recent) against its 60-day average, relative
--                to the median of all items (so a general price shift does not count)
--   here       = market value in our house against its 7-day median, once the
--                collector has two days of data
-- Data_Trend.lua is built by tools/trend.py.
local ADDON, ns = ...

local HOUSE_MIN_HOURS = 48

local function money(c) return c and ns.FormatMoney(c, true) or "–" end
local function pct(v)
  if not v then return "–" end
  local s = string.format("%+d %%", math.floor(v * 100 + (v >= 0 and 0.5 or -0.5)))
  return (v >= 0 and "|cff5fd38d" or "|cffff6b6b") .. s .. "|r"
end

ns.AHTable.Add({
  id = "Trends", label = "Trends", title = "Trends – steigende und fallende Preise",
  sort = "strength",
  views = { { "up", "Steigend" }, { "down", "Fallend" } },
  columns = {
    { key = "name", title = "Item", width = 0, align = "LEFT" },
    { key = "mvHere", title = "Wert hier", width = 90, filter = "money", fmt = function(e) return money(e.mvHere) end },
    { key = "houseChange", title = "Trend hier", width = 75, filter = "pct", fmt = function(e) return pct(e.houseChange) end },
    { key = "euMv", title = "EU jetzt", width = 90, muted = true, filter = "money", fmt = function(e) return money(e.euMv) end },
    { key = "euHist", title = "EU 60 T", width = 90, muted = true, fmt = function(e) return money(e.euHist) end },
    { key = "change", title = "Trend EU", width = 75, filter = "pct", fmt = function(e) return pct(e.change) end },
    { key = "fpd", title = "Verk./Tag EU", width = 85, muted = true, filter = "num",
      fmt = function(e) return string.format("%.0f", e.fpd) end },
  },
  rows = function(filter)
    local list, house = {}, ns.AHData and ns.AHData[113]
    local houseOk = house and (house.hours or 0) >= HOUSE_MIN_HOURS
    for itemID, v in pairs(ns.TrendData and ns.TrendData.items or {}) do
      local change = v[3]
      if (filter == "up") == (change > 0) then
        local row = house and house.items[itemID]
        local hc = houseOk and row and row[2] and row[3] and row[3] > 0 and (row[2] / row[3] - 1) or nil
        table.insert(list, { itemID = itemID, euMv = v[1], euHist = v[2], change = change, fpd = v[4],
          strength = math.abs(change), mvHere = row and row[2], houseChange = hc })
      end
    end
    return list
  end,
})
