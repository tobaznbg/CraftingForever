-- Invest: auction house tab "Anlage" with long-term investment candidates, i.e. items
-- that trade here far below their Classic Era price (Data_Invest.lua, tools/invest.py).
local ADDON, ns = ...

local function money(c) return c and ns.FormatMoney(c, true) or "–" end

ns.AHTable.Add({
  id = "Invest", label = "Anlage", title = "Anlage – Klassiker unter Wert",
  sort = "upside",
  columns = {
    { key = "name", title = "Item", width = 0, align = "LEFT" },
    { key = "now", title = "Preis jetzt", width = 95, filter = "money", fmt = function(e)
      return (e.now and e.now > GetMoney()) and ("|cffffb547" .. money(e.now) .. "|r") or money(e.now)
    end },
    { key = "ref", title = "Median gestern", width = 95, muted = true, filter = "money",
      fmt = function(e) return money(e.ref) end },
    { key = "classic", title = "Classic Era", width = 90, muted = true, filter = "money",
      fmt = function(e) return money(e.classic) end },
    { key = "upside", title = "Faktor", width = 60, filter = "num",
      fmt = function(e) return string.format("|cff5fd38dx%.1f|r", e.upside) end },
    { key = "demand", title = "Nachfrage", width = 80, muted = true, filter = "num",
      fmt = function(e) return ns.Item.DemandText(e) or "–" end },
  },
  rows = function()
    local list, data = {}, ns.InvestData
    for itemID, v in pairs(data and data.items or {}) do
      local item = ns.Item(itemID)
      local ref = item.ref or v[2]
      -- Factor to the general Forever price level (relative to Classic Era).
      local upside = ref and ref > 0 and data.level * v[1] / ref or v[3]
      table.insert(list, { itemID = itemID, classic = v[1], ref = ref, now = item.now, upside = upside,
        demand = item.demand or 0 })
    end
    return list
  end,
})
