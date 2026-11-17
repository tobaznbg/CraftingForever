-- Trends: auction house tab with items whose price in our auction house moves away
-- from its 30-day average.
--   now        cheapest offer in the live scan (opening the tab starts one, every
--              15 min at most); without a live scan the collector's last market value
--   trend      now against the reference
--   reference  collector: our own 30-day median, blended with a one-time TSM start
--              value while our history is short (ownShare = weight of our own data,
--              observed days / 14; at 100 % TSM plays no part any more)
local ADDON, ns = ...

local MIN_MOVE = 0.10   -- at least 10 % away from the reference

local function money(c) return c and ns.FormatMoney(c, true) or "–" end
local function pct(v)
  if not v then return "–" end
  local s = string.format("%+d %%", math.floor(v * 100 + (v >= 0 and 0.5 or -0.5)))
  return (v >= 0 and "|cff5fd38d" or "|cffff6b6b") .. s .. "|r"
end

ns.AHTable.Add({
  id = "Trends", label = "Trends", title = "Trends – Preise in deinem Auktionshaus",
  -- Much traded first: in thin markets one odd listing makes a "trend" of +5000 %.
  sort = "offers",
  views = { { "up", "Steigend" }, { "down", "Fallend" } },
  defaultFilters = { offers = "10" },
  onOpen = function() if ns.AuctionScan then ns.AuctionScan.EnsureFresh() end end,
  info = function() return ns.AuctionScan and ns.AuctionScan.LiveInfo() or nil end,
  columns = {
    { key = "name", title = "Item", width = 0, align = "LEFT" },
    { key = "mv", title = "Preis jetzt", width = 95, filter = "money", fmt = function(e) return money(e.mv) end },
    { key = "ref", title = "Ø 30 Tage", width = 95, muted = true, filter = "money", fmt = function(e) return money(e.ref) end },
    { key = "change", title = "Jetzt vs. Ø", width = 90, filter = "pct", fmt = function(e) return pct(e.change) end },
    { key = "offers", title = "Angebote", width = 75, muted = true, filter = "num",
      fmt = function(e) return tostring(e.offers) end },
  },
  rows = function(view)
    local list, house = {}, ns.AHData and ns.AHData[113]
    for itemID, row in pairs(house and house.items or {}) do
      local ref = row[9]
      local mv, fresh = nil, false
      if ns.AuctionScan then mv, fresh = ns.AuctionScan.LiveMin(itemID) end
      if not fresh then mv = row[2] end
      if mv and ref and ref > 0 then
        local change = mv / ref - 1
        if (view == "up" and change >= MIN_MOVE) or (view == "down" and change <= -MIN_MOVE) then
          table.insert(list, { itemID = itemID, mv = mv, ref = ref, change = change, own = row[10] or 0,
            offers = row[7] or 0, strength = math.abs(change) })
        end
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
