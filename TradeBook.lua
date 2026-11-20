-- TradeBook: the ledger ("Handelsbuch") in Blizzard's own look (ns.NativeWindow): side tabs
-- Übersicht / Handelsbuch / Bestand / Auktionen. Opens on the overview, period "Alles".
-- Opened with the tab "Handelsbuch" under the auction house, the minimap button or /m4 buch.
-- All pages with the real figures (ns.Profit, ns.MyAuctions, ns.Ledger).
local ADDON, ns = ...

local TradeBook = {}
ns.TradeBook = TradeBook

local NAME = "M4CompanionTradeBook"
local ICON = "Interface\\Icons\\INV_Misc_Coin_02" -- a pile of gold coins
local PERIODS = { { key = "today", label = "Heute" }, { key = "week", label = "7 Tage" }, { key = "all", label = "Alles" } }

local window
local period = "all"


-- Overview, built from Blizzard's "Berufe" overview parts: on top two cards side by side
-- (profit and loss with the period choice, stock), below running auctions and recent trades.
local CARD_W, TOP_H = 331, 142

local function card(page, w, x, y, width, height, title)
  local c = CreateFrame("Frame", nil, page)
  c:SetSize(width, height)
  c:SetPoint("TOPLEFT", w.frame, "TOPLEFT", x, y)
  local bg = c:CreateTexture(nil, "BACKGROUND")
  bg:SetAllPoints()
  bg:SetAtlas("Profession-overview-Card")
  c.Title = c:CreateFontString(nil, "OVERLAY", "GameFontNormal")
  c.Title:SetPoint("TOPLEFT", 20, -16)
  c.Title:SetText(title)
  return c
end

-- A table in a card: column heads, a gold rule and a scroll list of rows (Blizzard's scroll box
-- and minimal scroll bar). Returns setRows(rows), rows = { { icon = …, itemID = …, text1, … } }.
local function scrollTable(c, cols, top)
  for _, col in ipairs(cols) do
    local h = c:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    if col[3] == "LEFT" then h:SetPoint("TOPLEFT", col[2], top) else h:SetPoint("TOPRIGHT", c, "TOPLEFT", col[2], top) end
    h:SetText(col[1])
  end
  local rule = c:CreateTexture(nil, "ARTWORK")
  rule:SetColorTexture(1, 0.82, 0, 0.25)
  rule:SetHeight(1)
  rule:SetPoint("TOPLEFT", 20, top - 14)
  rule:SetPoint("TOPRIGHT", -24, top - 14)
  local empty = c:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
  empty:SetPoint("TOPLEFT", 22, top - 24)
  local okB, box = pcall(CreateFrame, "Frame", nil, c, "WowScrollBoxList")
  local okS, bar = pcall(CreateFrame, "EventFrame", nil, c, "MinimalScrollBar")
  if not (okB and okS and CreateScrollBoxListLinearView and ScrollUtil) then
    return function(rows) empty:SetText(#rows .. " Einträge") end
  end
  box:SetPoint("TOPLEFT", 16, top - 18)
  box:SetPoint("BOTTOMRIGHT", -30, 14)
  bar:SetPoint("TOPLEFT", box, "TOPRIGHT", 8, 0)
  bar:SetPoint("BOTTOMLEFT", box, "BOTTOMRIGHT", 8, 0)
  local view = CreateScrollBoxListLinearView()
  view:SetElementExtent(20)
  view:SetElementInitializer("BackdropTemplate", function(row, r)
    if not row.m4 then
      row.m4 = {}
      row.m4.icon = row:CreateTexture(nil, "ARTWORK")
      row.m4.icon:SetSize(16, 16)
      row.m4.icon:SetPoint("LEFT", 4, 0)
      for k, col in ipairs(cols) do
        local fs = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        fs:SetWordWrap(false)
        if col[3] == "LEFT" then
          fs:SetPoint("LEFT", row, "LEFT", k == 1 and 26 or (col[2] - 16), 0)
          fs:SetWidth(col[4] or 200)
          fs:SetJustifyH("LEFT")
        else
          fs:SetPoint("RIGHT", row, "LEFT", col[2] - 16, 0)
          fs:SetJustifyH("RIGHT")
        end
        row.m4[k] = fs
      end
      row:EnableMouse(true)
      row:SetScript("OnEnter", function(self)
        if not self.itemID then return end
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        GameTooltip:SetItemByID(self.itemID)
        GameTooltip:Show()
      end)
      row:SetScript("OnLeave", function() GameTooltip:Hide() end)
      row:SetScript("OnMouseUp", function(self, button)
        if button ~= "LeftButton" then return end
        if self.itemID and ns.ItemDetail and ns.ItemDetail.AltClick(self.itemID) then return end
        if self.onClick then ns.Safe(self.onClick) end
      end)
    end
    row.itemID = r.itemID
    row.onClick = r.onClick
    row.m4.icon:SetTexture(r.icon)
    for k = 1, #cols do row.m4[k]:SetText(r[k] or "") end
  end)
  ScrollUtil.InitScrollBoxListWithScrollBar(box, bar, view)
  return function(rows)
    empty:SetText(#rows == 0 and "Keine Einträge" or "")
    box:SetDataProvider(CreateDataProvider(rows))
  end
end

-- Real data ------------------------------------------------------------------------------------

local GREEN, RED, MUTED = "|cff5fd38d", "|cffff6b6b", "|cff999999"
local function money(c) return ns.FormatMoney(math.floor((c or 0) + 0.5), true) end
local function signed(c)
  c = math.floor((c or 0) + 0.5)
  return c >= 0 and (GREEN .. "+" .. money(c) .. "|r") or (RED .. "-" .. money(-c) .. "|r")
end
local function iconOf(id)
  local get = (C_Item and C_Item.GetItemIconByID) or GetItemIcon
  return id and get and get(id) or nil
end

local function since()
  if period == "today" then
    local d = date("*t")
    return time({ year = d.year, month = d.month, day = d.day, hour = 0 })
  elseif period == "week" then
    return time() - 7 * 86400
  end
  return nil
end

-- Running auctions: the last answer of this session (with the undercut check), else the copy
-- stored for the companion app (not checked).
local function auctionRows()
  local out, under = {}, 0
  local My = ns.MyAuctions
  for _, r in ipairs(My and My.Rows and My.Rows() or {}) do
    if (r.active or 0) > 0 then
      local status
      if r.status == "best" then status = GREEN .. "bester Preis|r"
      elseif r.status == "under" then status = RED .. "unterboten " .. money(r.diff) .. "|r"; under = under + 1
      elseif r.status == "alone" then status = MUTED .. "allein im AH|r"
      elseif r.status == "bid" then status = MUTED .. "nur Gebot|r"
      else status = MUTED .. "–|r" end
      local left = r.timeLeft and string.format("%d h", math.ceil(r.timeLeft / 3600)) or "–"
      out[#out + 1] = { itemID = r.itemID, icon = iconOf(r.itemID),
        (ns.ItemName(r.itemID) or "") .. ((r.quantity or 1) > 1 and (MUTED .. "  " .. r.quantity .. "×|r") or ""),
        r.unit and money(r.unit) or "–", status, MUTED .. left .. "|r" }
    end
  end
  if #out == 0 then
    local key = ns.CharKey and ns.CharKey()
    local saved = key and ns.db and ns.db.owned and ns.db.owned[key]
    for _, a in ipairs(saved and saved.list or {}) do
      if not a.s then
        out[#out + 1] = { itemID = a.i, icon = iconOf(a.i),
          (ns.ItemName(a.i) or "") .. ((a.q or 1) > 1 and (MUTED .. "  " .. a.q .. "×|r") or ""),
          a.u and money(a.u) or "–", MUTED .. "nicht geprüft|r",
          MUTED .. (a.tl and string.format("%d h", math.ceil(a.tl / 3600)) or "–") .. "|r" }
      end
    end
  end
  return out, under
end

local KINDS = { buy = "Kauf", sale = "Verkauf", vendor = "Händler", post = "Eingestellt", expired = "Abgelaufen",
  cancelled = "Abgebrochen", craft = "Hergestellt" }

-- The last 20 trades (all of them: the "Handelsbuch" tab).
local function tradeRows()
  local out = {}
  for _, e in ipairs(ns.Ledger and ns.Ledger.Recent and ns.Ledger.Recent(20) or {}) do
    local amount = ""
    if e.k == "buy" then amount = RED .. "-" .. money(e.c) .. "|r"
    elseif e.k == "sale" then amount = GREEN .. "+" .. money((e.c or 0) - (e.cut or 0)) .. "|r"
    elseif e.k == "vendor" then amount = GREEN .. "+" .. money(e.c) .. "|r"
    elseif e.k == "post" and e.p then amount = MUTED .. money(e.p * (e.u or 1)) .. "|r" end
    out[#out + 1] = { itemID = e.i, icon = iconOf(e.i),
      e.n or (e.i and ns.ItemName(e.i)) or "?",
      MUTED .. date("%d.%m. %H:%M", e.t or 0) .. "|r  " .. (KINDS[e.k] or tostring(e.k)),
      tostring(e.u or 1), amount }
  end
  return out
end

local function buildOverview(page, w)
  local NW = ns.NativeWindow

  -- 1. profit and loss (left) with the period choice
  local pnl = card(page, w, 5, -41, CARD_W, TOP_H, "Gewinn und Verlust")
  local dd
  local okD, d = pcall(CreateFrame, "DropdownButton", nil, pnl, "WowStyle1DropdownTemplate")
  if okD and d and d.SetupMenu then
    dd = d
    dd:SetWidth(96)
    dd:SetPoint("TOPRIGHT", -16, -10)
    dd:SetupMenu(function(_, root)
      for _, def in ipairs(PERIODS) do
        root:CreateRadio(def.label, function() return period == def.key end, function()
          period = def.key
          if page.Refresh then page.Refresh() end
        end)
      end
    end)
  else
    local okB, bt = pcall(CreateFrame, "Button", nil, pnl, "UIPanelButtonTemplate")
    dd = okB and bt or CreateFrame("Button", nil, pnl)
    dd:SetSize(96, 22)
    dd:SetPoint("TOPRIGHT", -16, -10)
    dd:SetScript("OnClick", function()
      for i, def in ipairs(PERIODS) do
        if def.key == period then period = PERIODS[i % #PERIODS + 1].key break end
      end
      if page.Refresh then page.Refresh() end
    end)
  end
  local pnlSlot = NW.Slot(pnl, "Interface\\Icons\\INV_Misc_Coin_02", "Gewinn", "")
  pnlSlot:SetPoint("TOPLEFT", 16, -40)
  local pnlFig = NW.Figures(pnl, pnlSlot, { "Umsatz", "Einkauf", "Gebühren" }, { line = false, gap = 8, step = 14 })
  pnlFig.labels[1]:ClearAllPoints()
  pnlFig.labels[1]:SetPoint("TOPLEFT", pnlSlot, "BOTTOMLEFT", 2, -8)
  pnlFig.SetWidth(CARD_W - 40)

  -- 2. stock (right)
  local stock = card(page, w, 5 + CARD_W + 2, -41, CARD_W, TOP_H, "Bestand")
  local stockSlot = NW.Slot(stock, "Interface\\Icons\\INV_Box_02", "Buchgewinn", "")
  stockSlot:SetPoint("TOPLEFT", 16, -40)
  local stockFig = NW.Figures(stock, stockSlot, { "Einkauf", "Erlös", "Items" }, { line = false, gap = 8, step = 14 })
  stockFig.labels[1]:ClearAllPoints()
  stockFig.labels[1]:SetPoint("TOPLEFT", stockSlot, "BOTTOMLEFT", 2, -8)
  stockFig.SetWidth(CARD_W - 40)

  -- 3. running auctions (full width)
  local AH = 200
  local auc = card(page, w, 5, -41 - TOP_H + 4, 664, AH, "Laufende Auktionen")
  local aucInfo = auc:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
  aucInfo:SetPoint("TOPRIGHT", -20, -18)
  local setAuctions = scrollTable(auc, { { "Gegenstand", 20, "LEFT", 330 }, { "Preis", 450, "RIGHT" },
    { "Status", 565, "RIGHT" }, { "Zeit", 612, "RIGHT" } }, -42)

  -- 4. recent trades (full width), scrollable
  local trTop = -41 - TOP_H + 4 - AH + 4
  local tr = card(page, w, 5, trTop, 664, 594 + trTop - 10, "Letzte Vorgänge")
  local setTrades = scrollTable(tr, { { "Item", 20, "LEFT", 270 }, { "Wann · Art", 320, "LEFT", 170 },
    { "Menge", 520, "RIGHT" }, { "Betrag", 612, "RIGHT" } }, -42)

  function page.Refresh()
    local label
    for _, def in ipairs(PERIODS) do if def.key == period then label = def.label end end
    if dd.SetText then dd:SetText(label) end
    if dd.GenerateMenu then pcall(dd.GenerateMenu, dd) end
    -- profit and loss of the period, stock now (ns.Profit, one replay)
    local report = ns.Profit and ns.Profit.Report and ns.Profit.Report(since())
    local t = report and report.totals or {}
    local sales = 0
    for _, g in ipairs(report and report.groups or {}) do sales = sales + (g.sold or 0) end
    pnlSlot.Sub:SetText(signed(t.profit) .. MUTED .. "  ·  " .. sales .. " verkauft|r")
    pnlFig.values[1]:SetText(money(t.revenue)); pnlFig.values[2]:SetText(money(t.materials)); pnlFig.values[3]:SetText(money(t.fees))
    local st = report and report.stockTotals or {}
    stockSlot.Sub:SetText(signed(st.gain))
    stockFig.values[1]:SetText(money(st.cost)); stockFig.values[2]:SetText(money(st.sell))
    stockFig.values[3]:SetText(string.format("%d Items · %d Stück", report and #(report.stock or {}) or 0, st.units or 0))
    local rows, under = auctionRows()
    setAuctions(rows)
    aucInfo:SetText(#rows .. " Auktionen" .. (under > 0 and ("  ·  " .. RED .. under .. " unterboten|r") or ""))
    setTrades(tradeRows())
  end
  page.Refresh()
end

-- Sub pages: Blizzard's recipe list left, the card right ---------------------------------------

-- The card's icon as a button: item tooltip on hover, Alt+click opens the market data window.
-- d.itemID is set by whoever shows an item on the card.
local function iconButton(parent, d)
  local b = CreateFrame("Button", nil, parent)
  b:SetAllPoints(d.Icon)
  b:SetScript("OnEnter", function(self)
    if not d.itemID then return end
    GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
    GameTooltip:SetItemByID(d.itemID)
    GameTooltip:Show()
  end)
  b:SetScript("OnLeave", function() GameTooltip:Hide() end)
  b:SetScript("OnClick", function()
    if d.itemID and ns.ItemDetail then ns.ItemDetail.AltClick(d.itemID) end
  end)
  return b
end

-- Card head (icon in a ring, name) and figure rows, built once per card for its labels.
local function cardFrame(card, labels)
  if card.m4 then return card.m4 end
  local d = {}
  d.Icon = card:CreateTexture(nil, "ARTWORK")
  d.Icon:SetSize(44, 44)
  d.Icon:SetPoint("TOPLEFT", 22, -22)
  local okMask, mask = pcall(card.CreateMaskTexture, card)
  if okMask and mask then
    mask:SetTexture("Interface\\CharacterFrame\\TempPortraitAlphaMask", "CLAMPTOBLACKADDITIVE", "CLAMPTOBLACKADDITIVE")
    mask:SetAllPoints(d.Icon)
    d.Icon:AddMaskTexture(mask)
  end
  local ring = card:CreateTexture(nil, "OVERLAY")
  ring:SetSize(60, 60)
  ring:SetPoint("CENTER", d.Icon, "CENTER", 0, 0)
  ring:SetTexture("Interface\\Minimap\\MiniMap-TrackingBorder")
  ring:SetTexCoord(0, 0.6, 0, 0.6)
  d.Ring = ring
  d.Name = card:CreateFontString(nil, "OVERLAY", "GameFontHighlightLarge")
  d.Name:SetPoint("LEFT", d.Icon, "RIGHT", 14, 6)
  d.Name:SetPoint("RIGHT", card, "RIGHT", -20, 0)
  d.Name:SetJustifyH("LEFT")
  d.Sub = card:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
  d.Sub:SetPoint("TOPLEFT", d.Name, "BOTTOMLEFT", 0, -3)
  d.Head = card:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
  d.Head:SetPoint("TOPLEFT", d.Icon, "BOTTOMLEFT", 0, -20)
  d.Head:SetText("Kennzahlen:")
  iconButton(card, d)
  d.Figures = ns.NativeWindow.Figures(card, d.Head, labels)
  d.Figures.SetWidth(math.max(100, (card:GetWidth() or 340) - 46))
  card:HookScript("OnSizeChanged", function(c) d.Figures.SetWidth(math.max(100, (c:GetWidth() or 340) - 46)) end)
  card.m4 = d
  return d
end

local function showCard(card, d, entry, values, sub)
  local parts = { d.Icon, d.Ring, d.Name, d.Sub, d.Head }
  for _, p in ipairs(parts) do p:SetShown(entry ~= nil) end
  for i, v in ipairs(d.Figures.values) do
    v:SetShown(entry ~= nil)
    d.Figures.labels[i]:SetShown(entry ~= nil)
  end
  if d.Figures.line then d.Figures.line:SetShown(entry ~= nil) end
  if not entry then return end
  d.Icon:SetTexture(entry.icon)
  d.itemID = entry.itemID
  d.Name:SetText(entry.name)
  d.Sub:SetText(sub or "")
  for i, v in ipairs(d.Figures.values) do v:SetText(values[i] or "–") end
end

local function shortGroup(name)
  if ns.Profit and name == ns.Profit.TRADE then return "Handel" end
  if ns.Profit and name == ns.Profit.FARMED then return "Beute" end
  return name
end

-- "Handelsbuch": how economic each activity is. Left the areas as plain rows (trade, loot, each
-- profession) with their profit; right the area's figures and its items (scrollable, by
-- contribution); an item opens in place (its profit and loss and trades, "‹ Zurück" to the
-- area). The search box searches all items.
local AREA_ROWS = 7

-- Figures of one area: { labels, values, top = { { name, value }… }, sub }.
local function areaFigures(g, items)
  local P = ns.Profit
  local function pct(a, b) return (b and b ~= 0) and string.format("%d %%", math.floor(a / b * 100 + 0.5)) or "–" end
  local top = {}
  local sorted = {}
  for _, r in ipairs(items or {}) do sorted[#sorted + 1] = r end
  if P.IsFarmed(g.name) then
    table.sort(sorted, function(a, b) return (a.revenue or 0) > (b.revenue or 0) end)
    for i = 1, math.min(5, #sorted) do top[i] = { sorted[i].name or ns.ItemName(sorted[i].itemId) or "?", money(sorted[i].revenue) } end
    local sub = g.name == P.FARMED and "Beute – was du gelootet und verkauft hast"
      or (g.name .. " – gesammelt und verkauft (kein Einkauf)")
    return { sub = sub, topTitle = "Brachte am meisten:",
      labels = { "Erlös", "Gebühren", "Verlorene Einstellgebühren", "Verkauft", "Gewinn" },
      values = { money(g.revenue), money(g.fees), money(g.depositsLost), (g.sold or 0) .. " Stück", signed(g.profit) }, top = top }
  end
  table.sort(sorted, function(a, b) return (a.profit or 0) > (b.profit or 0) end)
  for i = 1, math.min(5, #sorted) do top[i] = { sorted[i].name or ns.ItemName(sorted[i].itemId) or "?", signed(sorted[i].profit) } end
  if g.name == P.TRADE then
    return { sub = "Handel – im AH oder beim Händler gekauft und wieder verkauft", topTitle = "Größter Beitrag:",
      labels = { "Einkauf", "Verkauf", "Gebühren", "Marge", "Noch im Bestand", "Abgelaufen", "Gewinn" },
      values = { money(g.spent), money(g.revenue), money(g.fees), pct(g.profit or 0, g.revenue), money(g.stockValue),
        string.format("%d×  " .. RED .. "-%s|r", (g.expired or 0) + (g.cancelled or 0), money(g.depositsLost)), signed(g.profit) },
      top = top }
  end
  return { sub = "Beruf – Material gekauft, hergestellt und verkauft", topTitle = "Größter Beitrag:",
    labels = { "Materialkosten", "Erlös", "Gebühren", "Marge", "Hergestellt / verkauft", "Unverkauft (Material)", "Gewinn" },
    values = { money(g.materials), money(g.revenue), money(g.fees), pct(g.profit or 0, g.revenue),
      string.format("%d / %d Stück", g.crafted or 0, g.sold or 0),
      string.format("%d Stück · %s", g.stockUnits or 0, money(g.stockValue)), signed(g.profit) }, top = top }
end

local AREA_ICONS = { trade = "Interface\\Icons\\INV_Misc_Coin_02", farmed = "Interface\\Icons\\INV_Misc_Bag_10" }
local PROFESSION_ICONS = {
  ["Lederverarbeitung"] = "Interface\\Icons\\Trade_LeatherWorking", ["Schneiderei"] = "Interface\\Icons\\Trade_Tailoring",
  ["Schmiedekunst"] = "Interface\\Icons\\Trade_BlackSmithing", ["Alchimie"] = "Interface\\Icons\\Trade_Alchemy",
  ["Alchemie"] = "Interface\\Icons\\Trade_Alchemy", ["Ingenieurskunst"] = "Interface\\Icons\\Trade_Engineering",
  ["Verzauberkunst"] = "Interface\\Icons\\Trade_Engraving", ["Kochkunst"] = "Interface\\Icons\\INV_Misc_Food_15",
  ["Erste Hilfe"] = "Interface\\Icons\\Spell_Holy_SealOfSacrifice", ["Bergbau"] = "Interface\\Icons\\Trade_Mining",
  ["Kürschnerei"] = "Interface\\Icons\\INV_Misc_Pelt_Wolf_01", ["Kräuterkunde"] = "Interface\\Icons\\Trade_Herbalism",
}

-- Card head: icon in a ring, name, a line below (shared by the area and the item view).
local function head(layer)
  local d = {}
  d.Icon = layer:CreateTexture(nil, "ARTWORK")
  d.Icon:SetSize(44, 44)
  d.Icon:SetPoint("TOPLEFT", 22, -22)
  local okMask, mask = pcall(layer.CreateMaskTexture, layer)
  if okMask and mask then
    mask:SetTexture("Interface\\CharacterFrame\\TempPortraitAlphaMask", "CLAMPTOBLACKADDITIVE", "CLAMPTOBLACKADDITIVE")
    mask:SetAllPoints(d.Icon)
    d.Icon:AddMaskTexture(mask)
  end
  local ring = layer:CreateTexture(nil, "OVERLAY")
  ring:SetSize(60, 60)
  ring:SetPoint("CENTER", d.Icon, "CENTER", 0, 0)
  ring:SetTexture("Interface\\Minimap\\MiniMap-TrackingBorder")
  ring:SetTexCoord(0, 0.6, 0, 0.6)
  d.Name = layer:CreateFontString(nil, "OVERLAY", "GameFontHighlightLarge")
  d.Name:SetPoint("LEFT", d.Icon, "RIGHT", 14, 6)
  d.Name:SetPoint("RIGHT", layer, "RIGHT", -20, 0)
  d.Name:SetJustifyH("LEFT")
  d.Name:SetWordWrap(false)
  d.Sub = layer:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
  d.Sub:SetPoint("TOPLEFT", d.Name, "BOTTOMLEFT", 0, -3)
  d.Sub:SetPoint("RIGHT", layer, "RIGHT", -20, 0)
  d.Sub:SetJustifyH("LEFT")
  d.Head = layer:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
  d.Head:SetPoint("TOPLEFT", d.Icon, "BOTTOMLEFT", 0, -20)
  d.Head:SetText("Kennzahlen:")
  iconButton(layer, d)
  return d
end

local function buildLedger(page)
  local NW = ns.NativeWindow
  local ITEM_LABELS = { "Hergestellt / gekauft", "Verkauft", "Ø Verkaufspreis", "Umsatz", "Einkauf", "Gebühren", "Gewinn" }
  local card, area, item, allItems, currentArea
  local showItem -- forward

  local function layers(c)
    if area then return end
    card = c
    -- area view
    local al = CreateFrame("Frame", nil, c)
    al:SetAllPoints(c)
    area = head(al)
    area.layer = al
    local labels = {}
    for i = 1, AREA_ROWS do labels[i] = "" end
    area.Figures = NW.Figures(al, area.Head, labels)
    area.SetItems = scrollTable(al, { { "Item", 20, "LEFT", 190 }, { "Stück", 245, "RIGHT" }, { "Gewinn", 315, "RIGHT" } }, -232)
    -- item view
    local il = CreateFrame("Frame", nil, c)
    il:SetAllPoints(c)
    item = head(il)
    item.layer = il
    item.Figures = NW.Figures(il, item.Head, ITEM_LABELS)
    item.SetEvents = scrollTable(il, { { "Wann · Art", 20, "LEFT", 160 }, { "Menge", 225, "RIGHT" }, { "Betrag", 300, "RIGHT" } }, -250)
    local okB, back = pcall(CreateFrame, "Button", nil, il, "UIPanelButtonTemplate")
    if not okB then back = CreateFrame("Button", nil, il) end
    back:SetSize(76, 22)
    back:SetPoint("TOPRIGHT", il, "TOPRIGHT", -16, -27) -- on the name's line (icon 44 px at -22)
    back:SetText("‹ Zurück")
    -- the name and the line below end before the button
    item.Name:ClearAllPoints()
    item.Name:SetPoint("LEFT", item.Icon, "RIGHT", 14, 6)
    item.Name:SetPoint("RIGHT", back, "LEFT", -8, 0)
    back:SetScript("OnClick", function()
      if currentArea then il:Hide(); al:Show() end
    end)
    item.Back = back
    il:Hide()
    local function widths(fr)
      local w = math.max(100, (fr:GetWidth() or 340) - 46)
      area.Figures.SetWidth(w)
      item.Figures.SetWidth(w)
    end
    widths(c)
    c:HookScript("OnSizeChanged", widths)
  end

  local function eventRows(itemID)
    local rows = {}
    for _, e in ipairs(ns.Profit.ItemEvents(itemID, since()) or {}) do
      local amount = ""
      if e.k == "buy" then amount = RED .. "-" .. money(e.c) .. "|r"
      elseif e.k == "sale" then amount = GREEN .. "+" .. money((e.c or 0) - (e.cut or 0)) .. "|r"
      elseif e.k == "vendor" then amount = GREEN .. "+" .. money(e.c) .. "|r"
      elseif (e.k == "expired" or e.k == "cancelled") and e.lost then amount = RED .. "-" .. money(e.lost) .. "|r"
      elseif e.k == "post" and e.p then amount = MUTED .. money(e.p * (e.u or 1)) .. "|r" end
      rows[#rows + 1] = { MUTED .. date("%d.%m. %H:%M", e.t or 0) .. "|r  " .. (KINDS[e.k] or tostring(e.k)),
        tostring(e.u or 1), amount }
    end
    return rows
  end

  showItem = function(r, fromArea)
    item.layer:Show()
    area.layer:Hide()
    item.Back:SetShown(fromArea and true or false)
    item.Icon:SetTexture(iconOf(r.itemId))
    item.itemID = r.itemId
    item.Name:SetText(r.name or ns.ItemName(r.itemId) or ("#" .. r.itemId))
    item.Sub:SetText(shortGroup(r.prof))
    local v = { string.format("%d / %d", r.crafted or 0, r.bought or 0), tostring(r.sold or 0),
      r.avgPrice and money(r.avgPrice) or "–", money(r.revenue), money(r.materials), money(r.fees), signed(r.profit) }
    for i, fs in ipairs(item.Figures.values) do fs:SetText(v[i] or "–") end
    item.SetEvents(eventRows(r.itemId))
  end

  local function showArea(entry)
    currentArea = entry
    area.layer:Show()
    item.layer:Hide()
    local f = entry.figures
    area.Icon:SetTexture(entry.icon)
    area.itemID = nil
    area.Name:SetText(entry.name)
    area.Sub:SetText("Zusammenfassung")
    for i = 1, AREA_ROWS do
      local has = f.labels[i] ~= nil
      area.Figures.labels[i]:SetShown(has)
      area.Figures.values[i]:SetShown(has)
      area.Figures.labels[i]:SetText(f.labels[i] or "")
      area.Figures.values[i]:SetText(f.values[i] or "")
    end
    if area.Figures.line then
      area.Figures.line:ClearAllPoints()
      area.Figures.line:SetPoint("BOTTOMLEFT", area.Figures.labels[#f.labels], "TOPLEFT", 0, 4)
    end
    local rows = {}
    for _, r in ipairs(entry.items) do
      local value = entry.isLoot and money(r.revenue) or signed(r.profit)
      rows[#rows + 1] = { itemID = r.itemId, icon = iconOf(r.itemId), r.name or ns.ItemName(r.itemId) or "?",
        tostring(r.sold or 0), value, onClick = function() showItem(r, true) end }
    end
    area.SetItems(rows)
  end

  local split = NW.Split(page, {
    footer = 104,
    onSelect = function(entry, c)
      layers(c)
      if entry and entry.areaEntry then showArea(entry)
      elseif entry and entry.row then showItem(entry.row, false) end
    end,
    -- the search box searches every item of every area
    search = function(query)
      local out = { { key = "search", header = "Suchergebnisse" } }
      for _, r in ipairs(allItems or {}) do
        local name = (r.name or ns.ItemName(r.itemId) or ""):lower()
        if name:find(query, 1, true) then
          out[#out + 1] = { key = "i:" .. r.prof .. ":" .. r.itemId, name = r.name or ns.ItemName(r.itemId),
            icon = iconOf(r.itemId), value = signed(r.profit), row = r }
        end
      end
      return out
    end,
  })

  -- Balance under the areas: all areas of the period together.
  local balance
  if split.footer then
    local title = split.footer:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    title:SetPoint("TOPLEFT", 6, -8)
    title:SetText("Bilanz")
    balance = NW.Figures(split.footer, title, { "Einkauf / Material", "Erlöse", "Gebühren", "Gewinn" }, { gap = 6, step = 15 })
    balance.SetWidth(math.max(100, (split.footer:GetWidth() or 280) - 14))
    split.footer:HookScript("OnSizeChanged", function(f) balance.SetWidth(math.max(100, (f:GetWidth() or 280) - 14)) end)
  end

  function page.Refresh()
    local P = ns.Profit
    local report = P and P.Report and P.Report(since()) or { groups = {}, items = {} }
    if balance then
      local t = report.totals or {}
      balance.values[1]:SetText(money(t.materials))
      balance.values[2]:SetText(money(t.revenue))
      balance.values[3]:SetText(money(t.fees))
      balance.values[4]:SetText(signed(t.profit))
    end
    local ordered = {}
    for _, g in ipairs(report.groups) do if g.name == P.TRADE then ordered[#ordered + 1] = g end end
    for _, g in ipairs(report.groups) do if g.name == P.FARMED then ordered[#ordered + 1] = g end end
    -- gathering professions next to the loot, then the crafting professions
    for _, g in ipairs(report.groups) do if g.name ~= P.FARMED and P.IsFarmed(g.name) then ordered[#ordered + 1] = g end end
    for _, g in ipairs(report.groups) do if g.name ~= P.TRADE and not P.IsFarmed(g.name) then ordered[#ordered + 1] = g end end
    local entries = { { key = "areas", header = "Bereiche" } }
    allItems = {}
    for _, g in ipairs(ordered) do
      local items = {}
      for _, r in ipairs(report.items[g.name] or {}) do items[#items + 1] = r; allItems[#allItems + 1] = r end
      local isLoot = P.IsFarmed(g.name)
      table.sort(items, function(a, b)
        if isLoot then return (a.revenue or 0) > (b.revenue or 0) end
        return (a.profit or 0) > (b.profit or 0)
      end)
      local icon = g.name == P.TRADE and AREA_ICONS.trade or (isLoot and AREA_ICONS.farmed)
        or PROFESSION_ICONS[g.name] or "Interface\\Icons\\INV_Misc_QuestionMark"
      entries[#entries + 1] = { key = g.name, areaEntry = true, name = shortGroup(g.name), icon = icon,
        value = signed(g.profit), figures = areaFigures(g, items), items = items, isLoot = isLoot }
    end
    split.SetEntries(entries)
  end
end

-- "Bestand": what the character holds by source, with cost and what selling would bring.
local function buildStock(page)
  local NW = ns.NativeWindow
  local LABELS = { "Stück", "Einkauf / Stk.", "Einkauf", "Erlös / Stk.", "Erlös", "Buchgewinn" }
  local split = NW.Split(page, { onSelect = function(entry, card)
    local d = cardFrame(card, LABELS)
    local s = entry and entry.row
    showCard(card, d, entry, s and {
      tostring(s.units), money(s.unitCost), money(s.cost), s.sellUnit and money(s.sellUnit) or "–",
      s.sell and money(s.sell) or "–",
      s.gain and (signed(s.gain) .. (s.gainPct and string.format("  (%+d %%)", math.floor(s.gainPct * 100 + 0.5)) or "")) or "–",
    }, s and s.source)
  end })
  function page.Refresh()
    local report = ns.Profit and ns.Profit.Report and ns.Profit.Report(nil) or { stock = {} }
    local groups, order = {}, {}
    for _, s in ipairs(report.stock or {}) do
      local key = s.source or "?"
      if not groups[key] then groups[key] = {}; order[#order + 1] = key end
      table.insert(groups[key], s)
    end
    local entries = {}
    for _, key in ipairs(order) do
      entries[#entries + 1] = { key = key, header = key:sub(1, 1):upper() .. key:sub(2) }
      for _, s in ipairs(groups[key]) do
        entries[#entries + 1] = { key = key .. ":" .. s.itemId, itemID = s.itemId, icon = iconOf(s.itemId),
          name = s.name or ns.ItemName(s.itemId) or ("#" .. s.itemId), row = s }
      end
    end
    split.SetEntries(entries)
  end
end

-- "Auktionen": the running auctions by status (undercut first), price, cheapest other offer,
-- cost and profit.
local function buildAuctions(page)
  local NW = ns.NativeWindow
  local LABELS = { "Stück", "Mein Preis", "Billigst fremd", "Restzeit", "Einkauf / Stk.", "Gewinn" }
  local split = NW.Split(page, { onSelect = function(entry, card)
    local d = cardFrame(card, LABELS)
    local r = entry and entry.row
    local profit
    if r and r.unit then
      local cost, source = ns.Profit.UnitCost(r.itemID)
      if cost then profit = signed(math.floor((r.unit * 0.95 - cost) * (r.quantity or 1))) .. (source == "Beute" and (MUTED .. "  Beute|r") or "") end
    end
    local cost = r and ns.Profit.UnitCost(r.itemID)
    showCard(card, d, entry, r and {
      tostring(r.quantity or 1), r.unit and money(r.unit) or "–", r.foreign and money(r.foreign) or "–",
      r.timeLeft and string.format("%d h", math.ceil(r.timeLeft / 3600)) or "–",
      cost and money(cost) or "–", profit or "–",
    }, entry and entry.status)
  end })
  function page.Refresh()
    local My = ns.MyAuctions
    local buckets = { under = {}, best = {}, other = {} }
    for _, r in ipairs(My and My.Rows and My.Rows() or {}) do
      if (r.active or 0) > 0 then
        local status = r.status == "best" and "bester Preis" or (r.status == "under" and ("unterboten um " .. money(r.diff)))
          or (r.status == "alone" and "allein im AH") or "nicht geprüft"
        local b = r.status == "under" and "under" or (r.status == "best" and "best" or "other")
        table.insert(buckets[b], { key = "a:" .. r.itemID, itemID = r.itemID, icon = iconOf(r.itemID),
          name = ns.ItemName(r.itemID) or ("#" .. r.itemID), row = r, status = status })
      end
    end
    if #buckets.under + #buckets.best + #buckets.other == 0 then
      local key = ns.CharKey and ns.CharKey()
      local saved = key and ns.db and ns.db.owned and ns.db.owned[key]
      for _, a in ipairs(saved and saved.list or {}) do
        if not a.s then
          table.insert(buckets.other, { key = "s:" .. tostring(a.id), itemID = a.i, icon = iconOf(a.i),
            name = ns.ItemName(a.i) or ("#" .. tostring(a.i)), status = "nicht geprüft (Auktionshaus öffnen)",
            row = { itemID = a.i, unit = a.u, quantity = a.q, timeLeft = a.tl } })
        end
      end
    end
    local entries = {}
    for _, def in ipairs({ { "under", "Unterboten" }, { "best", "Bester Preis" }, { "other", "Sonstige" } }) do
      if #buckets[def[1]] > 0 then
        entries[#entries + 1] = { key = def[1], header = def[2] .. "  " .. MUTED .. "(" .. #buckets[def[1]] .. ")|r" }
        for _, e in ipairs(buckets[def[1]]) do entries[#entries + 1] = e end
      end
    end
    split.SetEntries(entries)
  end
end

local function refreshPage(page) if page.Refresh then page.Refresh() end end

local function create()
  window = ns.NativeWindow.New({ name = NAME, title = "Handelsbuch", icon = ICON })
  window:AddTab({ key = "overview", title = "Übersicht", icon = "Interface\\Icons\\INV_Misc_Coin_02", overview = true,
    build = buildOverview, onShow = function(page) if page.Refresh then page.Refresh() end end })
  window:AddTab({ key = "ledger", title = "Handelsbuch", icon = "Interface\\Icons\\INV_Misc_Note_01",
    build = buildLedger, onShow = refreshPage })
  window:AddTab({ key = "stock", title = "Bestand", icon = "Interface\\Icons\\INV_Box_02",
    build = buildStock, onShow = refreshPage })
  window:AddTab({ key = "auctions", title = "Auktionen", icon = "Interface\\Icons\\INV_Hammer_15",
    build = buildAuctions, onShow = refreshPage })
end

function TradeBook.Show()
  if not window then create() end
  window:Show()
  window:SelectTab("overview")
end

function TradeBook.Toggle()
  if window and window.frame:IsShown() then window.frame:Hide() else TradeBook.Show() end
end

function TradeBook.Frame() return window and window.frame end

-- The tab "Handelsbuch" under the auction house, after Blizzard's tabs. It opens the window and
-- leaves the auction house view as it is (it is not one of the AH's display modes).
local tab
local function addTab()
  local ah = AuctionHouseFrame
  if not ah or tab then return end
  local tabs = rawget(ah, "Tabs")
  local last = type(tabs) == "table" and tabs[#tabs]
  local ok, t = pcall(CreateFrame, "Button", "M4CompanionTradeBookTab", ah, "AuctionHouseFrameDisplayModeTabTemplate")
  if not ok then ok, t = pcall(CreateFrame, "Button", "M4CompanionTradeBookTab", ah, "UIPanelButtonTemplate") end
  if not ok then return end
  tab = t
  t:SetText("Handelsbuch")
  if PanelTemplates_TabResize then pcall(PanelTemplates_TabResize, t, 20, nil, 70) end
  if last then
    t:SetPoint("TOPLEFT", last, "TOPRIGHT", 3, 0)
  else
    t:SetPoint("TOPLEFT", ah, "BOTTOMLEFT", 300, 2)
  end
  if PanelTemplates_DeselectTab then pcall(PanelTemplates_DeselectTab, t) end
  t:SetScript("OnClick", function() ns.Safe(TradeBook.Toggle) end)
end

if ns.On then
  ns.On("AUCTION_HOUSE_SHOW", function()
    if C_Timer then C_Timer.After(0.2, function() ns.Safe(addTab) end) else ns.Safe(addTab) end
  end)
end

-- Probe (one step, removed later): what the profession window is made of in this client, so
-- the ledger window can use the very same templates, atlases and side tabs.
local function regionsOf(f, depth)
  local out = {}
  if type(f) ~= "table" or not f.GetRegions then return out end
  for _, r in ipairs({ f:GetRegions() }) do
    if r.GetObjectType and r:GetObjectType() == "Texture" then
      local atlas = r.GetAtlas and r:GetAtlas()
      local tex = r.GetTexture and r:GetTexture()
      local layer, sub = r:GetDrawLayer()
      local p, rel, rp, x, y = r:GetPoint(1)
      out[#out + 1] = string.format("%s|%s|%s/%s|%s %s %s %.0f %.0f|%.0fx%.0f|shown=%s", tostring(r:GetName() or "-"),
        tostring(atlas or tex), tostring(layer), tostring(sub), tostring(p),
        rel == f and "parent" or tostring(rel and rel.GetName and rel:GetName() or (rel and "other") or "nil"),
        tostring(rp), x or 0, y or 0, r:GetWidth() or 0, r:GetHeight() or 0, tostring(r:IsShown()))
    end
  end
  return out
end

local function keysOf(t)
  local k = {}
  for key, v in pairs(t) do
    if type(v) == "table" and v.GetObjectType then k[#k + 1] = tostring(key) .. ":" .. v:GetObjectType() end
  end
  table.sort(k)
  return table.concat(k, ",")
end

function TradeBook.Probe()
  if not ns.db then return end
  if not rawget(_G, "ProfessionsFrame") then
    local load = (C_AddOns and C_AddOns.LoadAddOn) or LoadAddOn
    if load then pcall(load, "Blizzard_Professions") end
  end
  local out = { t = time() }
  local pf = rawget(_G, "ProfessionsFrame")
  out.pf = type(pf)
  if type(pf) == "table" then
    out.pfKeys = keysOf(pf)
    out.pfRegions = table.concat(regionsOf(pf), " ;; ")
    local page = rawget(pf, "CraftingPage")
    if type(page) == "table" then
      out.pageKeys = keysOf(page)
      out.pageRegions = table.concat(regionsOf(page), " ;; ")
      local list = rawget(page, "RecipeList")
      if type(list) == "table" then
        out.listKeys = keysOf(list)
        out.listRegions = table.concat(regionsOf(list), " ;; ")
        local sb = rawget(list, "SearchBox")
        if type(sb) == "table" then
          local p, rel, rp, x, y = sb:GetPoint(1)
          out.searchPoint = string.format("%s %s %.0f %.0f %.0fx%.0f", tostring(p), tostring(rp), x or 0, y or 0, sb:GetWidth(), sb:GetHeight())
        end
        local fb = rawget(list, "FilterButton") or rawget(list, "FilterDropdown")
        if type(fb) == "table" then
          local p, rel, rp, x, y = fb:GetPoint(1)
          out.filterPoint = string.format("%s %s %.0f %.0f %.0fx%.0f %s", tostring(p), tostring(rp), x or 0, y or 0, fb:GetWidth(), fb:GetHeight(), fb:GetObjectType())
        end
        local box = rawget(list, "ScrollBox")
        if type(box) == "table" and box.ForEachFrame then
          local rows = {}
          box:ForEachFrame(function(row)
            if #rows < 3 then
              rows[#rows + 1] = keysOf(row) .. " => " .. table.concat(regionsOf(row), " ;; ")
            end
          end)
          out.rows = table.concat(rows, " || ")
        end
      end
      local form = rawget(page, "SchematicForm")
      if type(form) == "table" then
        out.formKeys = keysOf(form)
        out.formRegions = table.concat(regionsOf(form), " ;; ")
        local bg = rawget(form, "Background")
        if type(bg) == "table" then out.formBackground = tostring(bg.GetAtlas and bg:GetAtlas() or bg:GetTexture()) end
      end
    end
    -- side tabs: children of the window at its right edge
    local tabs = {}
    for _, child in ipairs({ pf:GetChildren() }) do
      local l, r = child:GetLeft(), pf:GetRight()
      if l and r and l > r - 10 then
        tabs[#tabs + 1] = tostring(child:GetName() or "-") .. ":" .. child:GetObjectType() .. " " .. keysOf(child)
          .. " => " .. table.concat(regionsOf(child), " ;; ")
      end
    end
    out.sideTabs = table.concat(tabs, " || ")
  end
  local info = C_XMLUtil and C_XMLUtil.GetTemplateInfo
  local names = {}
  for _, n in ipairs({ "ProfessionsRecipeListCategoryTemplate", "ProfessionsRecipeListRecipeTemplate",
      "ProfessionsRecipeListTemplate", "ProfessionsFrameTabTemplate", "SpellBookSkillLineTabTemplate",
      "ProfessionsSideTabTemplate", "LargeSideTabButtonTemplate", "SideTabTemplate", "SearchBoxTemplate",
      "WowStyle1FilterDropdownTemplate", "UIMenuButtonStretchTemplate", "ProfessionsSchematicFormTemplate" }) do
    local ok, ti = pcall(function() return info and info(n) end)
    names[#names + 1] = n .. "=" .. tostring(ok and ti ~= nil)
  end
  out.templates = table.concat(names, ",")
  ns.db.tradeBookProbe = out
end

if ns.On then
  ns.On("TRADE_SKILL_SHOW", function()
    if C_Timer then C_Timer.After(0.5, function() ns.Safe(TradeBook.Probe) end) end
  end)
end

-- Probe 2: the profession overview page ("Berufe", ProfessionsFrame.BookPage), two levels deep.
local function describe(f, depth, out, prefix)
  if type(f) ~= "table" or not f.GetObjectType then return end
  local w, h = f:GetWidth() or 0, f:GetHeight() or 0
  local p, rel, rp, x, y = f:GetPoint(1)
  out[#out + 1] = string.format("%s%s %s %.0fx%.0f @%s %s %.0f %.0f", prefix, f:GetObjectType(), tostring(f:GetName() or "-"),
    w, h, tostring(p), tostring(rp), x or 0, y or 0)
  if f.GetRegions then
    for _, r in ipairs({ f:GetRegions() }) do
      local t = r:GetObjectType()
      if t == "Texture" then
        local layer, sub = r:GetDrawLayer()
        local rp1, _, rrp, rx, ry = r:GetPoint(1)
        out[#out + 1] = string.format("%s  tex %s %s/%s %.0fx%.0f @%s %s %.0f %.0f", prefix,
          tostring((r.GetAtlas and r:GetAtlas()) or r:GetTexture()), tostring(layer), tostring(sub),
          r:GetWidth() or 0, r:GetHeight() or 0, tostring(rp1), tostring(rrp), rx or 0, ry or 0)
      elseif t == "FontString" then
        local fo = r:GetFontObject()
        out[#out + 1] = string.format("%s  text %q font=%s", prefix, tostring(r:GetText()), tostring(fo and fo:GetName()))
      end
    end
  end
  if depth > 0 and f.GetChildren then
    for _, c in ipairs({ f:GetChildren() }) do describe(c, depth - 1, out, prefix .. "    ") end
  end
end

-- The shown window whose title is "Berufe" (whatever its name in this client).
local function findBook()
  local book = rawget(_G, "ProfessionsBookFrame")
  if type(book) == "table" and book:IsShown() then return book end
  if not EnumerateFrames then return nil end
  local f = EnumerateFrames()
  while f do
    if f:IsShown() and f.GetParent and f:GetParent() == UIParent then
      local container = rawget(f, "TitleContainer")
      local title = rawget(f, "TitleText") or (type(container) == "table" and rawget(container, "TitleText"))
      if type(title) == "table" and title.GetText and title:GetText() == "Berufe" then return f end
    end
    f = EnumerateFrames(f)
  end
end

function TradeBook.ProbeBook()
  local book = findBook()
  if type(book) ~= "table" or not ns.db then return false end
  local out = {}
  describe(book, 4, out, "")
  ns.db.tradeBookProbe2 = { t = time(), name = tostring(book:GetName()), lines = out }
  return true
end

-- look for it every 2 s until found once (probe only)
if C_Timer and C_Timer.NewTicker then
  local ticker
  ticker = C_Timer.NewTicker(2, function()
    local ok, found = pcall(TradeBook.ProbeBook)
    if ok and found and ticker then ticker:Cancel() end
  end)
end

-- The professions book ("Berufe", K) loads on demand: hook its OnShow once it exists.
local bookHooked = false
local function hookBook()
  local book = rawget(_G, "ProfessionsBookFrame")
  if bookHooked or type(book) ~= "table" then return end
  bookHooked = true
  book:HookScript("OnShow", function()
    if C_Timer then C_Timer.After(0.5, function() ns.Safe(TradeBook.ProbeBook) end) end
  end)
  if book:IsShown() then ns.Safe(TradeBook.ProbeBook) end
end
if ns.On then
  ns.On("ADDON_LOADED", function(_, name) if name == "Blizzard_ProfessionsBook" then ns.Safe(hookBook) end end)
  ns.On("PLAYER_LOGIN", function() ns.Safe(hookBook) end)
end
