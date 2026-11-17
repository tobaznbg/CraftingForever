-- Profit: profit and loss per profession from the trading ledger (Ledger.lua).
--
-- The ledger is replayed oldest first with a moving average cost per item (not FIFO):
-- auction house goods are interchangeable, stacks merge in the bags and the ledger does not
-- see every unit (farmed material, crafts before the ledger existed), so single lots cannot
-- be followed anyway; an average is robust against such gaps and needs no lot bookkeeping.
--
-- Two pools per item:
--   bought   units bought at the auction house, at their average purchase price
--   crafted  units the player made, at their average cost (external + internal material)
-- A craft takes each reagent from the crafted pool first (own intermediate, e.g. a bolt of
-- cloth: its cost moves into the product, it is no new material), then from the bought pool
-- (material at purchase price), the rest is farmed / not bought and costs 0 (Tobias' rule).
-- A sale takes units from the crafted pool first (they count for the profession), then
-- from the bought pool (group TRADE: bought and sold again, their purchase price is the cost),
-- the rest was made with a learned recipe before crafts were logged (its profession, material
-- 0 like farmed) or farmed / looted (group FARMED, cost 0). Revenue and cut pro rata.
-- Sales logged before item ids were recorded carry only the name; it is looked up.
-- Expired and cancelled auctions of an item lose the deposit of its posts (average
-- deposit per unit of the item's posts; posts before deposits were logged count 0).
--
-- Figures (copper):
--   revenue       sale price before the cut (gross)
--   fees          auction house cut + lost deposits (cut and depositsLost also separate)
--   materials     bought reagents used by crafts (farmed = 0); for TRADE the purchase price
--   profit        revenue - materials - fees
--   stock         units not sold or used yet x their average cost (now, not "since"):
--                 crafted units in their profession, bought units in TRADE
-- Per item also (in the period): bought / spent (units and copper bought at the auction
-- house, TRADE rows), soldCost (cost of the sold units taken from the pools: crafted at
-- their average cost, bought at the purchase price, farmed 0), expired / cancelled (how
-- many auctions came back: number of mails, not units).
-- Per sold unit (nil without sales): avgPrice (revenue / sold, gross), soldUnitCost
-- (soldCost / sold), unitProfit ((revenue - cut - soldCost) / sold; lost deposits are not
-- in it, they are per auction, not per unit sold).
-- Note: materials are booked when crafting, soldCost when selling. For a crafted item the
-- period's profit therefore counts the material of all units made, soldCost only that of
-- the units sold (the rest is stock).
-- "since" (epoch, nil = all) filters the figures by event time; the pools always replay the
-- whole ledger, so costs stay right.
--
-- ns.Profit.Professions(since) -> { { name, revenue, materials, fees, cut, depositsLost,
--   profit, stockUnits, stockValue, crafted, sold, bought, spent, soldCost, expired,
--   cancelled }... } sorted by profit
-- ns.Profit.Items(professionName, since) -> { { itemId, name, crafted, sold, revenue,
--   materials, fees, cut, depositsLost, profit, stockUnits, stockValue, unitCost, bought,
--   spent, soldCost, expired, cancelled, avgPrice, soldUnitCost, unitProfit }... } sorted by
--   profit
-- ns.Profit.Totals(since) -> { revenue, materials, fees, cut, depositsLost, profit,
--   stockUnits, stockValue }
-- ns.Profit.Report(since) -> { groups = Professions, items = { [group] = Items },
--   totals = Totals, stock, stockTotals = Stock() } from one replay (the ledger page)
-- ns.Profit.Stock() -> list, totals: per item units left (crafted + bought pool), cost
--   (Einstand), market value now (ns.Item(id).now x units, nil without a price) and the
--   difference; totals { units, cost, market, pricedCost, diff, unpriced } (market and diff
--   over the items with a price only, unpriced = items without one)
-- ns.Profit.ItemEvents(itemID, since) -> the item's events, newest first, as
--   { t, k, u, c, cut, p, dep, lost } (lost: deposit lost by an expired/cancelled auction)
local ADDON, ns = ...

local Profit = ns.Profit or {}
ns.Profit = Profit

local UNKNOWN = "Unbekannt"
local TRADE = "Handel (gekauft, verkauft)"
local FARMED = "Gesammelt (Farm, Beute)"
Profit.TRADE, Profit.FARMED = TRADE, FARMED

-- itemID of a ledger event: its id, else looked up by name (older events).
local byName
local function idOf(e)
  if e.i then return e.i end
  if not e.n then return nil end
  if not byName then
    byName = {}
    for id, name in pairs(ns.ItemNames or {}) do byName[name] = id end
  end
  return byName[e.n]
end

local function pool(pools, itemID)
  local p = pools[itemID]
  if not p then
    p = { q = 0, v = 0 }
    pools[itemID] = p
  end
  return p
end

-- Takes up to n units from a pool at its average cost: units taken, their value.
local function take(p, n)
  if not p or p.q <= 0 or n <= 0 then return 0, 0 end
  local k = math.min(n, p.q)
  local v = p.v * k / p.q
  p.q, p.v = p.q - k, p.v - v
  if p.q <= 0 then p.q, p.v = 0, 0 end
  return k, v
end

local function newFigures()
  return { revenue = 0, materials = 0, fees = 0, cut = 0, depositsLost = 0, crafted = 0, sold = 0,
    bought = 0, spent = 0, soldCost = 0, expired = 0, cancelled = 0 }
end

-- Replays the ledger: per item figures in the period and the pools at the end.
-- lost: event -> deposit lost (expired / cancelled with a known deposit).
local function replay(since)
  local events = ns.Ledger and ns.Ledger.Events and ns.Ledger.Events() or {}
  local bought, crafted = {}, {}
  local profOf = {}     -- itemID -> profession name (last craft)
  local depo = {}       -- itemID -> { u, dep } of posts with a known deposit
  local items = {}      -- itemID -> figures (crafted items, grouped by profession later)
  local other = {}      -- TRADE / FARMED -> itemID -> figures
  local everBought = {} -- itemID -> true
  local lost = {}
  local function figures(itemID, group)
    local t = items
    if group then
      other[group] = other[group] or {}
      t = other[group]
    end
    local f = t[itemID]
    if not f then
      f = newFigures()
      t[itemID] = f
    end
    return f
  end

  for _, e in ipairs(events) do
    local inPeriod = not since or (e.t or 0) >= since
    local id, u = idOf(e), e.u or 0
    if id and e.k == "buy" then
      everBought[id] = true
      local p = pool(bought, id)
      p.q, p.v = p.q + u, p.v + (e.c or 0)
      if inPeriod then
        local f = figures(id, TRADE)
        f.bought, f.spent = f.bought + u, f.spent + (e.c or 0)
      end
    elseif id and e.k == "craft" and u > 0 then
      local external, internal = 0, 0
      for _, g in ipairs(e.r or {}) do
        if g.i and g.n then
          local k, v = take(crafted[g.i], g.n)
          internal = internal + v
          local _, bv = take(bought[g.i], g.n - k)
          external = external + bv
        end
      end
      local p = pool(crafted, id)
      p.q, p.v = p.q + u, p.v + external + internal
      profOf[id] = e.prof or profOf[id] or UNKNOWN
      if inPeriod then
        local f = figures(id)
        f.crafted, f.materials = f.crafted + u, f.materials + external
      end
    elseif id and e.k == "post" then
      if e.dep and u > 0 then
        local d = depo[id] or { u = 0, dep = 0 }
        d.u, d.dep = d.u + u, d.dep + e.dep
        depo[id] = d
      end
    elseif id and e.k == "sale" and u > 0 then
      local k, cv = take(crafted[id], u)
      local kb, bv = take(bought[id], u - k)
      local function book(n, group, cost, value)
        if n <= 0 or not inPeriod then return end
        local f = figures(id, group)
        local share = n / u
        local cut = (e.cut or 0) * share
        f.sold = f.sold + n
        f.revenue = f.revenue + (e.c or 0) * share
        f.cut, f.fees = f.cut + cut, f.fees + cut
        f.materials = f.materials + (cost or 0)
        f.soldCost = f.soldCost + (value or 0)
      end
      book(k, nil, 0, cv)
      book(kb, TRADE, bv, bv)
      -- Not crafted per the log and not bought: made with a learned recipe before crafts were
      -- logged (material counts 0 like farmed), else farmed or looted.
      local maker = ns.CraftedBy and ns.CraftedBy(id)
      if maker and not profOf[id] then profOf[id] = maker end
      book(u - k - kb, not maker and FARMED or nil, 0, 0)
    elseif id and (e.k == "expired" or e.k == "cancelled") then
      local d = depo[id]
      local amount = d and d.u > 0 and d.dep / d.u * u or 0
      if amount > 0 then lost[e] = amount end
      if inPeriod then
        -- Same area as its sales: an item of a learned recipe belongs to that profession.
        local maker = not profOf[id] and ns.CraftedBy and ns.CraftedBy(id)
        if maker then profOf[id] = maker end
        local group = not profOf[id] and (everBought[id] and TRADE or FARMED) or nil
        local f = figures(id, group)
        f[e.k] = f[e.k] + 1
        f.depositsLost, f.fees = f.depositsLost + amount, f.fees + amount
      end
    end
  end
  return items, crafted, profOf, other, bought, lost
end

local function round(x) return math.floor(x + 0.5) end

local function row(id, group, f, p)
  return {
    itemId = id, prof = group, name = ns.ItemName and ns.ItemName(id) or nil,
    crafted = f.crafted, sold = f.sold, bought = f.bought, spent = round(f.spent),
    revenue = round(f.revenue), materials = round(f.materials), fees = round(f.fees),
    cut = round(f.cut), depositsLost = round(f.depositsLost),
    profit = round(f.revenue) - round(f.materials) - round(f.fees),
    soldCost = round(f.soldCost), expired = f.expired, cancelled = f.cancelled,
    stockUnits = p.q, stockValue = round(p.v),
    unitCost = p.q > 0 and round(p.v / p.q) or nil,
    avgPrice = f.sold > 0 and round(f.revenue / f.sold) or nil,
    soldUnitCost = f.sold > 0 and round(f.soldCost / f.sold) or nil,
    unitProfit = f.sold > 0 and round((f.revenue - f.cut - f.soldCost) / f.sold) or nil,
  }
end

local NONE = { q = 0, v = 0 }

-- Per item rows: crafted items under their profession (stock = crafted pool), TRADE rows
-- for bought items that were sold, came back or are still there (stock = bought pool, also
-- when nothing happened in the period), FARMED rows without stock.
local function itemRows(since, replayed)
  local items, crafted, profOf, other, bought = unpack(replayed or { replay(since) })
  local rows = {}
  local trade = other[TRADE] or {}
  for id, p in pairs(bought) do
    if p.q > 0 and not trade[id] then trade[id] = newFigures() end
  end
  other[TRADE] = next(trade) and trade or nil
  for group, list in pairs(other) do
    for id, f in pairs(list) do
      local p = group == TRADE and bought[id] or NONE
      -- Bought material that went into crafts (none left, nothing sold) is no trade.
      if group ~= TRADE or p.q > 0 or f.sold > 0 or f.expired > 0 or f.cancelled > 0 then
        table.insert(rows, row(id, group, f, p))
      end
    end
  end
  for id, prof in pairs(profOf) do
    local f = items[id] or newFigures()
    local p = crafted[id] or NONE
    if f.crafted > 0 or f.sold > 0 or f.fees > 0 or f.expired > 0 or f.cancelled > 0 or p.q > 0 then
      table.insert(rows, row(id, prof, f, p))
    end
  end
  return rows
end

local function byProfit(a, b)
  if a.profit ~= b.profit then return a.profit > b.profit end
  return (a.name or tostring(a.itemId)) < (b.name or tostring(b.itemId))
end

local SUM_KEYS = { "revenue", "materials", "fees", "cut", "depositsLost", "profit", "stockUnits",
  "stockValue", "crafted", "sold", "bought", "spent", "soldCost", "expired", "cancelled" }

local function professions(rows)
  local by, list = {}, {}
  for _, r in ipairs(rows) do
    local s = by[r.prof]
    if not s then
      s = { name = r.prof }
      for _, key in ipairs(SUM_KEYS) do s[key] = 0 end
      by[r.prof] = s
      table.insert(list, s)
    end
    for _, key in ipairs(SUM_KEYS) do s[key] = s[key] + r[key] end
  end
  table.sort(list, byProfit)
  return list
end

local function totals(groups)
  local t = { revenue = 0, materials = 0, fees = 0, cut = 0, depositsLost = 0, profit = 0,
    stockUnits = 0, stockValue = 0 }
  for _, s in ipairs(groups) do
    for key in pairs(t) do t[key] = t[key] + s[key] end
  end
  return t
end

function Profit.Professions(since)
  return professions(itemRows(since))
end

function Profit.Items(professionName, since)
  local list = {}
  for _, r in ipairs(itemRows(since)) do
    if r.prof == professionName then table.insert(list, r) end
  end
  table.sort(list, byProfit)
  return list
end

function Profit.Totals(since)
  return totals(Profit.Professions(since))
end

-- Stock now from the pools: crafted and bought units of an item together.
local function stock(crafted, bought)
  local by, list = {}, {}
  local function add(id, p, source)
    if not p or p.q <= 0 then return end
    local s = by[id]
    if not s then
      s = { itemId = id, name = ns.ItemName and ns.ItemName(id) or nil, units = 0, cost = 0 }
      by[id] = s
      table.insert(list, s)
    end
    s.units, s.cost = s.units + p.q, s.cost + p.v
    s.source = s.source and (s.source .. ", " .. source) or source
  end
  for id, p in pairs(crafted) do add(id, p, "hergestellt") end
  for id, p in pairs(bought) do add(id, p, "gekauft") end
  local t = { units = 0, cost = 0, market = 0, pricedCost = 0, diff = 0, unpriced = 0 }
  for _, s in ipairs(list) do
    s.cost = round(s.cost)
    s.unitCost = round(s.cost / s.units)
    local item = ns.Item and ns.Item(s.itemId)
    s.marketUnit = item and item.now or nil
    if s.marketUnit then
      s.market = round(s.marketUnit * s.units)
      s.diff = s.market - s.cost
      t.market, t.pricedCost = t.market + s.market, t.pricedCost + s.cost
    else
      t.unpriced = t.unpriced + 1
    end
    t.units, t.cost = t.units + s.units, t.cost + s.cost
  end
  t.diff = t.market - t.pricedCost
  table.sort(list, function(a, b)
    local va, vb = a.market or a.cost, b.market or b.cost
    if va ~= vb then return va > vb end
    return (a.name or tostring(a.itemId)) < (b.name or tostring(b.itemId))
  end)
  return list, t
end

function Profit.Stock()
  local _, crafted, _, _, bought = replay(nil)
  return stock(crafted, bought)
end

-- Everything the ledger page shows, from one replay.
function Profit.Report(since)
  local replayed = { replay(since) }
  local rows = itemRows(since, replayed)
  local groups = professions(rows)
  local items = {}
  for _, r in ipairs(rows) do
    items[r.prof] = items[r.prof] or {}
    table.insert(items[r.prof], r)
  end
  for _, list in pairs(items) do table.sort(list, byProfit) end
  local list, t = stock(replayed[2], replayed[5])
  return { groups = groups, items = items, totals = totals(groups), stock = list, stockTotals = t }
end

function Profit.ItemEvents(itemID, since)
  local _, _, _, _, _, lost = replay(nil)
  local events = ns.Ledger and ns.Ledger.Events and ns.Ledger.Events() or {}
  local out = {}
  for i = #events, 1, -1 do
    local e = events[i]
    if (not since or (e.t or 0) >= since) and idOf(e) == itemID then
      table.insert(out, { t = e.t, k = e.k, u = e.u, c = e.c, cut = e.cut, p = e.p, dep = e.dep,
        lost = lost[e] and round(lost[e]) or nil })
    end
  end
  return out
end

-- What one unit of the item cost the player, for pricing decisions (not for the P&L):
--   crafted pool (logged crafts, material at purchase price, farmed 0)  -> "hergestellt"
--   bought pool (bought at the auction house)                          -> "gekauft"
--   else, if the character can make it: the material at today's prices -> "Material heute"
--     (farmed material counts at its market value here: selling it would bring that much)
-- Returns copper per unit and the source text, or nil.
function Profit.UnitCost(itemID)
  local _, crafted, _, _, bought = replay(nil)
  local p = crafted[itemID]
  if p and p.q > 0 and p.v > 0 then return p.v / p.q, "hergestellt" end
  p = bought[itemID]
  if p and p.q > 0 then return p.v / p.q, "gekauft" end
  local c = ns.CraftingCost and ns.CraftingCost(itemID)
  if c then return c, "Material heute" end
end

-- The lowest unit price that still covers the cost after the auction house cut.
function Profit.BreakEven(cost)
  return cost and math.ceil(cost / (1 - 0.05)) or nil
end
