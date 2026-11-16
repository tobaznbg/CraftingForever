-- AuctionStats: pure logic for our own auction house scans (no game API, so the
-- tools in tools/ load it too).
--
-- A listing is { unit = copper per item, count = stack size, seller = name or "?",
-- tl = time-left bucket 1..4 }.
--
-- Time-left buckets (classic auction house, durations 2/8/24 h):
--   1 < 30 min, 2 30 min - 2 h, 3 2 h - 8 h, 4 > 8 h
-- A listing that vanished between two scans although its bucket guaranteed more
-- remaining time than has passed cannot have expired: it was bought or cancelled.
-- Those are counted as estimated sales. Listings that may have expired are only
-- counted as "ended", which gives an estimated sale rate sold / (sold + ended).
local ADDON, ns = ...

local Stats = {}
ns.AuctionStats = Stats

Stats.MIN_REMAINING = { 0, 30 * 60, 2 * 3600, 8 * 3600 }
Stats.HISTORY_DAYS = 30

-- Market value like TSM's: the cheapest 15-30 % of the listed quantity, cut off at
-- a price jump of more than 20 %, then outliers beyond 1.5 standard deviations
-- removed; quantity-weighted mean of the rest.
function Stats.MarketValue(listings)
  local sorted = {}
  local total = 0
  for _, l in ipairs(listings) do
    if l.unit and l.unit > 0 then
      table.insert(sorted, l)
      total = total + l.count
    end
  end
  if total == 0 then return nil end
  table.sort(sorted, function(a, b) return a.unit < b.unit end)

  local picked, qty = {}, 0
  for i, l in ipairs(sorted) do
    local share = qty / total
    if share >= 0.15 then
      if share >= 0.30 then break end
      if l.unit > sorted[i - 1].unit * 1.2 then break end
    end
    table.insert(picked, l)
    qty = qty + l.count
  end

  local sum, n = 0, 0
  for _, l in ipairs(picked) do sum = sum + l.unit * l.count; n = n + l.count end
  local mean = sum / n
  local var = 0
  for _, l in ipairs(picked) do var = var + l.count * (l.unit - mean) ^ 2 end
  local sd = math.sqrt(var / n)

  local kept, keptN = 0, 0
  for _, l in ipairs(picked) do
    if sd == 0 or math.abs(l.unit - mean) <= 1.5 * sd then
      kept = kept + l.unit * l.count
      keptN = keptN + l.count
    end
  end
  if keptN == 0 then return math.floor(mean + 0.5) end
  return math.floor(kept / keptN + 0.5)
end

-- Summary of one item's listings: min unit price, market value, quantity,
-- number of listings, number of distinct sellers.
function Stats.Summarize(listings)
  local min, qty, sellers, nSellers = nil, 0, {}, 0
  for _, l in ipairs(listings) do
    if l.unit and l.unit > 0 and (not min or l.unit < min) then min = l.unit end
    qty = qty + l.count
    if not sellers[l.seller] then sellers[l.seller] = true; nSellers = nSellers + 1 end
  end
  return { min = min, mv = Stats.MarketValue(listings), qty = qty, n = #listings, sellers = nSellers }
end

-- Fingerprint of a listing: "unit:count:seller:tl". Without auction IDs this is
-- the only way to recognise a listing in the next scan.
function Stats.Key(l)
  return l.unit .. ":" .. l.count .. ":" .. l.seller .. ":" .. l.tl
end

function Stats.ParseKey(key)
  local unit, count, seller, tl = key:match("^(%d+):(%d+):(.*):(%d)$")
  if not unit then return nil end
  return { unit = tonumber(unit), count = tonumber(count), seller = seller, tl = tonumber(tl) }
end

-- Identity ignores the time-left bucket, which drops while a listing waits.
local function identity(l) return l.unit .. ":" .. l.count .. ":" .. l.seller end

-- Compares one item's listings between two scans `elapsed` seconds apart.
-- Returns soldUnits, soldValue, soldListings, endedListings.
function Stats.Diff(previous, current, elapsed)
  local remaining = {}
  for _, l in ipairs(current) do
    local id = identity(l)
    remaining[id] = (remaining[id] or 0) + 1
  end
  local soldUnits, soldValue, soldN, endedN = 0, 0, 0, 0
  for _, l in ipairs(previous) do
    local id = identity(l)
    if (remaining[id] or 0) > 0 then
      remaining[id] = remaining[id] - 1
    elseif elapsed < (Stats.MIN_REMAINING[l.tl] or 0) then
      soldUnits = soldUnits + l.count
      soldValue = soldValue + l.unit * l.count
      soldN = soldN + 1
    else
      endedN = endedN + 1
    end
  end
  return soldUnits, soldValue, soldN, endedN
end

-- Day row: { min, mvSum, scans, qty, n, sellers, soldUnits, soldValue, soldN, endedN }
function Stats.AddToDay(row, summary, soldUnits, soldValue, soldN, endedN)
  row = row or { 0, 0, 0, 0, 0, 0, 0, 0, 0, 0 }
  if summary then
    if summary.min and (row[1] == 0 or summary.min < row[1]) then row[1] = summary.min end
    if summary.mv then row[2] = row[2] + summary.mv; row[3] = row[3] + 1 end
    row[4], row[5], row[6] = summary.qty, summary.n, summary.sellers
  end
  row[7] = row[7] + (soldUnits or 0)
  row[8] = row[8] + (soldValue or 0)
  row[9] = row[9] + (soldN or 0)
  row[10] = row[10] + (endedN or 0)
  return row
end

function Stats.DayKey(t)
  return math.floor(t / 86400)
end

-- Removes day aggregates older than HISTORY_DAYS.
function Stats.Prune(days, now)
  local oldest = Stats.DayKey(now) - Stats.HISTORY_DAYS
  for day in pairs(days) do
    if day < oldest then days[day] = nil end
  end
end

-- History of one item over the stored days:
--   days, mv (mean of daily market values), min (median of daily minimums),
--   soldPerDay (estimated units), salePrice (mean unit price of estimated sales),
--   saleRate (sold / (sold + ended), nil with fewer than `minEnded` finished listings),
--   qty, n, sellers (latest day)
function Stats.History(days, itemID, minEnded)
  local count, mvSum, mins = 0, 0, {}
  local soldUnits, soldValue, soldN, endedN = 0, 0, 0, 0
  local latestDay, latest
  for day, items in pairs(days or {}) do
    local row = items[itemID]
    if row then
      count = count + 1
      if row[3] > 0 then mvSum = mvSum + row[2] / row[3] end
      if row[1] > 0 then table.insert(mins, row[1]) end
      soldUnits, soldValue = soldUnits + row[7], soldValue + row[8]
      soldN, endedN = soldN + row[9], endedN + row[10]
      if not latestDay or day > latestDay then latestDay, latest = day, row end
    end
  end
  if count == 0 then return nil end
  table.sort(mins)
  local median
  if #mins > 0 then
    local mid = math.floor(#mins / 2)
    median = #mins % 2 == 1 and mins[mid + 1] or math.floor((mins[mid] + mins[mid + 1]) / 2)
  end
  local finished = soldN + endedN
  return {
    days = count,
    mv = math.floor(mvSum / count + 0.5),
    min = median,
    soldPerDay = soldUnits / count,
    salePrice = soldUnits > 0 and math.floor(soldValue / soldUnits + 0.5) or nil,
    saleRate = finished >= (minEnded or 5) and soldN / finished or nil,
    qty = latest[4], n = latest[5], sellers = latest[6],
  }
end
