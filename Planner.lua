-- Planner: cheapest expected path from one skill level to another.
-- Pure logic without game API calls, so it also runs outside the game (tools/plan.lua).
--
-- Model
--   chance(skill)  orange 1, yellow/green (grey - skill) / (grey - yellow), grey 0
--   net(recipe)    reagent cost - resale value of the product (negative = profit)
--   segment        using one recipe from skill a to b costs
--                  learnCost + sum over s in [a, b) of net / chance(s)
--   path           dynamic programming over skill levels picks the cheapest
--                  chain of segments from `from` to `to`.
local ADDON, ns = ...

local Planner = {}
ns.Planner = Planner

-- Skill-up chance at the given skill; colors = { orange, yellow, green, grey }.
function Planner.Chance(colors, skill)
  local yellow, grey = colors[2], colors[4]
  if skill >= grey then return 0 end
  if skill < yellow then return 1 end
  if grey == yellow then return 0 end
  return (grey - skill) / (grey - yellow)
end

local function hasSource(source, code)
  return type(source) == "string" and source:find(code, 1, true) ~= nil
end

-- Builds the list of candidate recipes.
--   scanRecipes   recipes as stored by Recipes.Scan
--   data          color/learn table (ns.Data.Leatherworking)
--   buyCost(id)   copper per unit to obtain a reagent, or nil if unknown
--   vendorSell(id) copper per unit a merchant pays for the product (0 if none)
--   ahSell(id)    copper per unit after auction cut, or nil if no auction price
--   all           true: every recipe; "vendor": also patterns sold by a vendor
--                 (their price is unknown, so it is not counted; marked needsPattern)
function Planner.Candidates(scanRecipes, data, buyCost, vendorSell, ahSell, all)
  local list, skipped = {}, {}
  for recipeID, recipe in pairs(scanRecipes) do
    local d = data[recipeID]
    local trainer = hasSource(d and d[7], "6")
    local vendorPattern = not trainer and hasSource(d and d[7], "5")
    if d and recipe.out and (all == true or recipe.learned or trainer or (all == "vendor" and vendorPattern)) then
      local cost, missing = 0, nil
      for _, reagent in ipairs(recipe.r or {}) do
        local unit = reagent.i and buyCost(reagent.i)
        if not unit then
          missing = reagent.i
          break
        end
        cost = cost + unit * (reagent.n or 1)
      end
      if missing then
        table.insert(skipped, { id = recipeID, name = recipe.name, missing = missing })
      else
        local produced = ((recipe.qmin or 1) + (recipe.qmax or recipe.qmin or 1)) / 2
        local vendorValue = (vendorSell(recipe.out) or 0) * produced
        local auction = ahSell(recipe.out)
        local ahValue = math.max(vendorValue, (auction or 0) * produced)
        table.insert(list, {
          id = recipeID,
          name = recipe.name,
          learned = recipe.learned and true or false,
          learnAt = d[5] or d[1],
          learnCost = recipe.learned and 0 or (d[6] or 0),
          colors = { d[1], d[2], d[3], d[4] },
          cost = cost,
          vendorValue = vendorValue,
          ahValue = ahValue,
          hasAuction = auction ~= nil,
          needsPattern = not recipe.learned and not trainer,
          source = d[7],
          reagents = recipe.r,
          out = recipe.out,
        })
      end
    end
  end
  return list, skipped
end

-- Cheapest path from skill `from` to `to`.
--   ahCap  how many units of one product can be sold at the auction price;
--          everything beyond goes to a vendor (0 = vendor only).
-- Returns ordered segments:
--   { recipe, from, to, crafts, cost (net, incl. learning), spend (reagents), back (sales) }
function Planner.Path(candidates, from, to, ahCap)
  ahCap = ahCap or 0
  local best, back = {}, {}
  -- Recipes already used on the best path to each skill level. Learning cost and
  -- the limited auction sales may only count once per recipe; without this the
  -- search splits one recipe into many short segments to collect them repeatedly.
  local used = {}
  best[from] = 0
  used[from] = {}
  for s = from, to - 1 do
    if best[s] then
      for _, c in ipairs(candidates) do
        if s >= c.learnAt then
          local firstUse = not used[s][c.id]
          local cap = firstUse and ahCap or 0
          local acc, crafts, spend, income = (firstUse and c.learnCost or 0), 0, 0, 0
          for t = s + 1, to do
            local p = Planner.Chance(c.colors, t - 1)
            if p <= 0 then break end
            local step = 1 / p
            local atAuction = math.max(0, math.min(step, cap - crafts))
            local value = atAuction * c.ahValue + (step - atAuction) * c.vendorValue
            crafts = crafts + step
            spend = spend + step * c.cost
            income = income + value
            acc = acc + step * c.cost - value
            local total = best[s] + acc
            if best[t] == nil or total < best[t] then
              best[t] = total
              back[t] = { from = s, recipe = c, crafts = crafts, cost = acc, spend = spend, income = income,
                          learned = firstUse and c.learnCost or 0 }
              local set = {}
              for id in pairs(used[s]) do set[id] = true end
              set[c.id] = true
              used[t] = set
            end
          end
        end
      end
    end
  end
  -- Without a full path, stop at the highest skill that can be reached.
  if best[to] == nil then
    local reached
    for t = to - 1, from + 1, -1 do
      if best[t] then reached = t; break end
    end
    if not reached then return nil end
    to = reached
  end

  local segments, t = {}, to
  while t > from do
    local b = back[t]
    table.insert(segments, 1, {
      recipe = b.recipe, from = b.from, to = t, crafts = b.crafts,
      cost = b.cost, spend = b.spend, income = b.income, learned = b.learned,
    })
    t = b.from
  end

  -- Merge consecutive segments of the same recipe (learning is charged once).
  local merged = {}
  for _, seg in ipairs(segments) do
    local last = merged[#merged]
    if last and last.recipe == seg.recipe then
      last.to = seg.to
      last.crafts = last.crafts + seg.crafts
      last.cost = last.cost + seg.cost
      last.learned = last.learned + seg.learned
      last.spend = last.spend + seg.spend
      last.income = last.income + seg.income
    else
      table.insert(merged, seg)
    end
  end
  return merged, best[to], to
end

-- Profit of one craft, for making gold rather than levelling.
--   safe       products go to a vendor
--   potential  products sell at the current auction price (after cut)
-- A recipe is flagged when either value clears the thresholds:
--   safe      any profit at all, because a vendor always buys
--   potential at least `minProfit` copper and `minMargin` of the material cost
function Planner.Profit(candidates, minProfit, minMargin)
  local rows = {}
  for _, c in ipairs(candidates) do
    local safe = c.vendorValue - c.cost
    local potential = c.ahValue - c.cost
    local margin = c.cost > 0 and potential / c.cost or math.huge
    table.insert(rows, {
      recipe = c,
      safe = safe,
      potential = potential,
      margin = margin,
      safeDeal = safe > 0,
      potentialDeal = c.hasAuction and potential >= minProfit and margin >= minMargin,
    })
  end
  table.sort(rows, function(a, b) return a.potential > b.potential end)
  return rows
end

-- Total reagents to buy/bring for a path: { [itemID] = count }.
function Planner.Shopping(segments)
  local need = {}
  for _, seg in ipairs(segments) do
    local crafts = math.ceil(seg.crafts)
    for _, reagent in ipairs(seg.recipe.reagents or {}) do
      need[reagent.i] = (need[reagent.i] or 0) + reagent.n * crafts
    end
  end
  return need
end
