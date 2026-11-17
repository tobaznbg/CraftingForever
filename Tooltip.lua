-- Tooltip: adds what a merchant pays for the item, from the client's own item
-- data, so vendor prices can be checked anywhere (the AH tooltip may omit them).
local ADDON, ns = ...

local function sellPrice(itemID)
  local getInfo = (C_Item and C_Item.GetItemInfo) or GetItemInfo
  local price = getInfo and select(11, getInfo(itemID))
  return type(price) == "number" and price or nil
end

local function addLines(tooltip, itemID)
  if not itemID or tooltip.cfDone == itemID then return end
  tooltip.cfDone = itemID
  local C = "|cff4fc2a1CF|r "
  local m = ns.Farming and ns.Farming.Market(itemID)
  if m then
    local ask = math.max(1, (m.min or m.price) - 1)
    tooltip:AddDoubleLine(C .. "AH-Erlös (unterbieten, -5 %)", ns.FormatMoney(ask * 0.95), 1, 1, 1, 1, 1, 1)
    tooltip:AddDoubleLine(C .. "AH günstigstes / Marktwert",
      ns.FormatMoney(m.min or m.price) .. " / " .. ns.FormatMoney(m.price), 0.7, 0.7, 0.7, 0.7, 0.7, 0.7)
    local demand = m.soldPerDay and string.format("%.0f verkauft/Tag", m.soldPerDay) or "Absatz noch offen"
    tooltip:AddDoubleLine(C .. string.format("%d im AH", m.quantity or 0), demand, 0.7, 0.7, 0.7, 0.7, 0.7, 0.7)
  else
    tooltip:AddLine(C .. "nicht im AH", 0.7, 0.7, 0.7)
  end
  -- Last 14 days in our auction house: lowest / average / highest hourly cheapest offer.
  local house = ns.AHData and ns.AHData[113]
  local row = house and house.items[itemID]
  if row and row[11] then
    local days = row[14] or 0
    local label = days >= 13.5 and "14 Tage" or string.format("%s Tage", days < 1 and "<1" or tostring(math.floor(days + 0.5)))
    tooltip:AddDoubleLine(C .. label .. " min / Ø / max",
      ns.FormatMoney(row[11]) .. " / " .. ns.FormatMoney(row[12]) .. " / " .. ns.FormatMoney(row[13]),
      0.7, 0.7, 0.7, 1, 1, 1)
  end
  -- Decision as in the Bestand tab; bag entry if the item is carried (bound state).
  if ns.Inventory then
    local inv = ns.db.inventory and ns.db.inventory[ns.CharKey()]
    local entry = inv and ((inv.bags and inv.bags[itemID]) or (inv.bank and inv.bank[itemID]))
    if not entry then
      local getInfo = (C_Item and C_Item.GetItemInfo) or GetItemInfo
      entry = { n = 1, q = getInfo and select(3, getInfo(itemID)) or 1 }
    end
    local action, reason = ns.Inventory.Advise(itemID, entry)
    local colors = { AH = { 0.37, 0.83, 0.55 }, ["Händler"] = { 0.85, 0.79, 0.64 }, behalten = { 0.6, 0.6, 0.6 } }
    local c = colors[action] or colors.behalten
    tooltip:AddDoubleLine(C .. "Empfehlung", action .. " (" .. reason .. ")", 1, 1, 1, c[1], c[2], c[3])
  end
  local price = sellPrice(itemID)
  if price then
    tooltip:AddDoubleLine(C .. "Händler zahlt", price > 0 and ns.FormatMoney(price) or "nichts", 1, 1, 1, 1, 1, 1)
  end
  tooltip:Show()
end

if TooltipDataProcessor and Enum and Enum.TooltipDataType then
  TooltipDataProcessor.AddTooltipPostCall(Enum.TooltipDataType.Item, function(tooltip, data)
    if tooltip == GameTooltip or tooltip == ItemRefTooltip then
      ns.Safe(addLines, tooltip, data and data.id)
    end
  end)
else
  GameTooltip:HookScript("OnTooltipSetItem", function(tooltip)
    local _, link = tooltip:GetItem()
    ns.Safe(addLines, tooltip, link and tonumber(link:match("item:(%d+)")))
  end)
end
GameTooltip:HookScript("OnTooltipCleared", function(tooltip) tooltip.cfDone = nil end)
