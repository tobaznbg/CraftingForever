-- Invest: auction house tab "Anlage" with long-term investment candidates, i.e. items
-- that trade here far below their Classic Era price (Data_Invest.lua, tools/invest.py).
local ADDON, ns = ...

local function money(c) return c and ns.FormatMoney(c, true) or "–" end

ns.AHTable.Add({
  id = "Invest", label = "Anlage", title = "Anlage – Klassiker unter Wert",
  sort = "upside",
  columns = {
    { key = "name", title = "Item", width = 0, align = "LEFT" },
    { key = "min", title = "Billigstes hier", width = 105, filter = "money", fmt = function(e)
      return (e.min and e.min > GetMoney()) and ("|cffffb547" .. money(e.min) .. "|r") or money(e.min)
    end },
    { key = "here", title = "Median 7 T", width = 90, muted = true, filter = "money",
      fmt = function(e) return money(e.here) end },
    { key = "classic", title = "Classic Era", width = 90, muted = true, filter = "money",
      fmt = function(e) return money(e.classic) end },
    { key = "upside", title = "Faktor", width = 60, filter = "num",
      fmt = function(e) return string.format("|cff5fd38dx%.1f|r", e.upside) end },
    { key = "fpd", title = "Verk./Tag EU", width = 85, muted = true, filter = "num",
      fmt = function(e) return string.format("%.1f", e.fpd) end },
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
})
