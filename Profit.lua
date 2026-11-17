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
-- A sale takes units from the crafted pool first; only those count for the profession
-- (revenue and cut pro rata), the rest are trades (bought pool), reported by the ledger.
-- Expired and cancelled auctions of a crafted item lose the deposit of its posts (average
-- deposit per unit of the item's posts; posts before deposits were logged count 0).
--
-- Figures (copper):
--   revenue       sale price before the cut (gross)
--   fees          auction house cut + lost deposits (cut and depositsLost also separate)
--   materials     bought reagents used by crafts in the period (farmed = 0)
--   profit        revenue - materials - fees
--   stock         crafted units not sold or used yet x their average cost (now, not "since")
-- "since" (epoch, nil = all) filters the figures by event time; the pools always replay the
-- whole ledger, so costs stay right.
--
-- ns.Profit.Professions(since) -> { { name, revenue, materials, fees, cut, depositsLost,
--   profit, stockUnits, stockValue, crafted, sold }... } sorted by profit
-- ns.Profit.Items(professionName, since) -> { { itemId, name, crafted, sold, revenue,
--   materials, fees, profit, stockUnits, unitCost }... } sorted by profit
-- ns.Profit.Totals(since) -> { revenue, materials, fees, profit, stockValue }
local ADDON, ns = ...

local Profit = ns.Profit or {}
ns.Profit = Profit

local UNKNOWN = "Unbekannt"

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
  return { revenue = 0, materials = 0, fees = 0, cut = 0, depositsLost = 0, crafted = 0, sold = 0 }
end

-- Replays the ledger: per item figures in the period and the pools at the end.
local function replay(since)
  local events = ns.Ledger and ns.Ledger.Events and ns.Ledger.Events() or {}
  local bought, crafted = {}, {}
  local profOf = {}     -- itemID -> profession name (last craft)
  local depo = {}       -- itemID -> { u, dep } of posts with a known deposit
  local items = {}      -- itemID -> figures
  local function figures(itemID)
    local f = items[itemID]
    if not f then
      f = newFigures()
      items[itemID] = f
    end
    return f
  end

  for _, e in ipairs(events) do
    local inPeriod = not since or (e.t or 0) >= since
    local id, u = e.i, e.u or 0
    if id and e.k == "buy" then
      local p = pool(bought, id)
      p.q, p.v = p.q + u, p.v + (e.c or 0)
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
      local k = take(crafted[id], u)
      take(bought[id], u - k)
      if k > 0 and inPeriod then
        local f = figures(id)
        local share = k / u
        local cut = (e.cut or 0) * share
        f.sold = f.sold + k
        f.revenue = f.revenue + (e.c or 0) * share
        f.cut, f.fees = f.cut + cut, f.fees + cut
      end
    elseif id and (e.k == "expired" or e.k == "cancelled") and profOf[id] and inPeriod then
      local d = depo[id]
      if d and d.u > 0 then
        local lost = d.dep / d.u * u
        local f = figures(id)
        f.depositsLost, f.fees = f.depositsLost + lost, f.fees + lost
      end
    end
  end
  return items, crafted, profOf
end

local function round(x) return math.floor(x + 0.5) end

-- Per item rows of all crafted items: { itemId, prof, figures..., stock }.
local function itemRows(since)
  local items, crafted, profOf = replay(since)
  local rows = {}
  for id, prof in pairs(profOf) do
    local f = items[id] or newFigures()
    local p = crafted[id] or { q = 0, v = 0 }
    if f.crafted > 0 or f.sold > 0 or f.fees > 0 or p.q > 0 then
      table.insert(rows, {
        itemId = id, prof = prof, name = ns.ItemName and ns.ItemName(id) or nil,
        crafted = f.crafted, sold = f.sold,
        revenue = round(f.revenue), materials = round(f.materials), fees = round(f.fees),
        cut = round(f.cut), depositsLost = round(f.depositsLost),
        profit = round(f.revenue) - round(f.materials) - round(f.fees),
        stockUnits = p.q, stockValue = round(p.v),
        unitCost = p.q > 0 and round(p.v / p.q) or nil,
      })
    end
  end
  return rows
end

local function byProfit(a, b)
  if a.profit ~= b.profit then return a.profit > b.profit end
  return (a.name or tostring(a.itemId)) < (b.name or tostring(b.itemId))
end

function Profit.Professions(since)
  local by, list = {}, {}
  for _, r in ipairs(itemRows(since)) do
    local s = by[r.prof]
    if not s then
      s = { name = r.prof, revenue = 0, materials = 0, fees = 0, cut = 0, depositsLost = 0,
        profit = 0, stockUnits = 0, stockValue = 0, crafted = 0, sold = 0 }
      by[r.prof] = s
      table.insert(list, s)
    end
    for _, key in ipairs({ "revenue", "materials", "fees", "cut", "depositsLost", "profit",
      "stockUnits", "stockValue", "crafted", "sold" }) do
      s[key] = s[key] + r[key]
    end
  end
  table.sort(list, byProfit)
  return list
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
  local t = { revenue = 0, materials = 0, fees = 0, profit = 0, stockValue = 0 }
  for _, s in ipairs(Profit.Professions(since)) do
    for key in pairs(t) do t[key] = t[key] + s[key] end
  end
  return t
end
