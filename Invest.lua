-- Invest: auction house tab "Anlage" with long-term investment candidates, i.e. items
-- that trade here far below their Classic Era price (Data_Invest.lua, tools/invest.py).
local ADDON, ns = ...

local function money(c) return c and ns.FormatMoney(c, true) or "–" end

ns.AHTable.Add({
  id = "Invest", label = "Anlage", title = "Anlage – Klassiker unter Wert",
  sort = "upside",
  columns = {
    { "name", "Item", 0, "LEFT" },
    { "min", "Billigstes hier", 110, "RIGHT", function(e)
      return (e.min and e.min > GetMoney()) and ("|cffffb547" .. money(e.min) .. "|r") or money(e.min)
    end },
    { "here", "Median 7 T", 100, "RIGHT", function(e) return money(e.here) end, true },
    { "classic", "Classic Era", 100, "RIGHT", function(e) return money(e.classic) end, true },
    { "upside", "Faktor", 70, "RIGHT", function(e) return string.format("|cff5fd38dx%.1f|r", e.upside) end },
    { "fpd", "Verk./Tag EU", 90, "RIGHT", function(e) return string.format("%.1f", e.fpd) end, true },
  },
  rows = function()
    local list, house = {}, ns.AHData and ns.AHData[113]
    for itemID, v in pairs(ns.InvestData and ns.InvestData.items or {}) do
      local row = house and house.items[itemID]
      table.insert(list, { itemID = itemID, classic = v[1], here = v[2], upside = v[3], fpd = v[4] or 0,
        min = row and row[1] })
    end
    return list
  end,
  status = function(list)
    local data, house = ns.InvestData, ns.AHData and ns.AHData[113]
    if not data then return "Keine Vergleichsdaten (Data_Invest.lua fehlt)." end
    return string.format("%d Items  ·  Preise hier ≈ %d %% von Classic Era  ·  Faktor = wie weit das Item bis zu"
      .. " diesem Niveau steigen müsste  ·  AH-Daten %s  ·  Kein Versprechen: Forever ändert manche Items.",
      #list, math.floor(data.level * 100 + 0.5), house and house.updated and house.updated:sub(1, 16):gsub("T", " ") or "–")
  end,
})
