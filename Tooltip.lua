-- Tooltip: the item's market data (ns.Item) and the recommendation, everywhere.
local ADDON, ns = ...

local function addLines(tooltip, itemID)
  if not itemID or tooltip.cfDone == itemID then return end
  tooltip.cfDone = itemID
  local C = "|cff4fc2a1M4|r "
  local item = ns.Item(itemID)
  if item.now then
    local change = item.change and string.format("  (%+d %% zu gestern)",
      math.floor(item.change * 100 + (item.change >= 0 and 0.5 or -0.5))) or ""
    local unsure = ns.Item.Unsure(item)
    tooltip:AddDoubleLine(C .. "AH jetzt", ns.FormatMoney(item.now) .. change .. (unsure and "  unsicher" or ""),
      1, 1, 1, 1, unsure and 0.71 or 1, unsure and 0.28 or 1)
  else
    tooltip:AddLine(C .. "nicht im AH", 0.7, 0.7, 0.7)
  end
  if item.min and item.max then
    tooltip:AddDoubleLine(C .. "Preisspanne", ns.FormatMoney(item.min) .. " – " .. ns.FormatMoney(item.max)
      .. "  (Ø " .. ns.FormatMoney(item.avg) .. ")", 0.7, 0.7, 0.7, 1, 1, 1)
  end
  local trend = ns.Item.TrendText(item)
  if trend then
    local up, down = item.direction == 1, item.direction == -1
    tooltip:AddDoubleLine(C .. "Trend", trend, 0.7, 0.7, 0.7, up and 0.37 or (down and 1 or 0.8),
      up and 0.83 or (down and 0.42 or 0.8), up and 0.55 or (down and 0.42 or 0.8))
  end
  local demand = ns.Item.DemandText(item)
  if demand then
    if item.certain and item.certain >= 1 then
      local n = math.floor(item.certain + 0.5)
      demand = demand .. "  (mind. " .. (BreakUpLargeNumbers and BreakUpLargeNumbers(n) or tostring(n)) .. " / Tag)"
    end
    tooltip:AddDoubleLine(C .. "Nachfrage", demand, 0.7, 0.7, 0.7, 1, 1, 1)
  end
  -- Gap between the auction house block and recommendation / merchant price.
  tooltip:AddLine(" ")
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
    tooltip:AddDoubleLine(C .. "Empfehlung", action, 1, 1, 1, c[1], c[2], c[3])
  end
  tooltip:AddDoubleLine(C .. "Händler zahlt", item.vendorSell and ns.FormatMoney(item.vendorSell) or "nichts",
    1, 1, 1, 1, 1, 1)
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
