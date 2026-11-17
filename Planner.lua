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

-- Recipes that need a profession specialization (Data_Skill.lua marks them with `spec`;
-- this list covers the older leatherworking data); left out of plans unless learned.
Planner.SPECIALIZATION = {
  [10650] = true, [10619] = true, [10630] = true, [10632] = true, [10621] = true,
}
-- Trainer recipes learned at 200 or later are taught by the Artisan (Fachmann) trainer.
Planner.ARTISAN_FROM = 200
Planner.MAX_SKILL = 300

-- Classic ranks: the cap each one lifts the skill to and the character level it needs.
-- Reaching a cap, the next rank has to be learned at the trainer before skill goes on.
Planner.RANKS = {
  { cap = 75, name = "Lehrling", level = 5 },
  { cap = 150, name = "Geselle", level = 10 },
  { cap = 225, name = "Experte", level = 20 },
  { cap = 300, name = "Fachmann", level = 35 },
}

-- The rank that has to be learned at `cap` (to go beyond it), or nil at the end.
function Planner.NextRank(cap)
  for _, rank in ipairs(Planner.RANKS) do
    if rank.cap > cap then return rank end
  end
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
    -- Start recipes (orange from skill 0/1, given when the profession is learned) carry no
    -- source in the data; their "learned at" (d[5]) is the first rank's cap, not a skill.
    local startRecipe = d ~= nil and (d[7] == nil or d[7] == "") and (d[1] or 99) <= 1
    local trainer = hasSource(d and d[7], "6") or startRecipe
    -- Transmutations have a cooldown (Forever: 1 hour, Arcanite ~2 days): they cannot be
    -- crafted dozens of times in a row, so they are no way to raise the skill.
    local cooldown = recipe.name and recipe.name:find("^Transmutieren") ~= nil
    local vendorPattern = not trainer and hasSource(d and d[7], "5")
    local special = (Planner.SPECIALIZATION[recipeID] or (d and d.spec)) and not recipe.learned
      and all ~= true
    if d and (recipe.out or recipe.noOutput) and not special and not cooldown
        and (all == true or recipe.learned or trainer or (all == "vendor" and vendorPattern)) then
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
        local vendorValue = recipe.out and (vendorSell(recipe.out) or 0) * produced or 0
        local auction = recipe.out and ahSell(recipe.out) or nil
        local ahValue = math.max(vendorValue, (auction or 0) * produced)
        table.insert(list, {
          id = recipeID,
          name = recipe.name,
          learned = recipe.learned and true or false,
          -- A learned recipe can be used at any skill (its learn level is irrelevant).
          learnAt = recipe.learned and 0 or (startRecipe and 0) or (d[5] or d[1]),
          artisan = not recipe.learned and trainer and (d[5] or d[1] or 0) >= Planner.ARTISAN_FROM or nil,
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

-- Recipes of a SkillData entry (ns.SkillData[professionID]) in the shape of a recipe
-- scan, so Planner.Candidates takes them with the entry's recipes as color/learn data:
--   Planner.Candidates(Planner.SkillRecipes(skill, scan), skill.recipes, ...)
-- Reagents, product and names come from SkillData; whether a recipe is learned from the
-- character's own scan (scan.recipes keyed by the same spell IDs), if there is one.
-- Recipes without a product (enchantments) are kept: they only cost material.
function Planner.SkillRecipes(skill, scan)
  local own = scan and scan.recipes or {}
  local list = {}
  for spellID, d in pairs(skill and skill.recipes or {}) do
    local reagents = {}
    local r = d.r or {}
    for i = 1, #r - 1, 2 do
      table.insert(reagents, { i = r[i], n = r[i + 1] })
    end
    local mine = own[spellID]
    list[spellID] = {
      name = d.name or (mine and mine.name) or ("Rezept " .. spellID),
      learned = mine and mine.learned or false,
      out = d.out,
      noOutput = d.out == nil and #reagents > 0 or nil,
      qmin = d.qty or 1,
      qmax = d.qty or 1,
      r = reagents,
    }
  end
  return list
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

-- Path segments with the trainer visits in between, for display:
--   { rank = { at, name, cap, level } }  learn the next rank at skill `at`
--   { seg = segment }                    a segment of Planner.Path
-- `max` is the character's current skill cap (nil: not known, e.g. the profession is not
-- learned yet; then every cap from `from` on needs a visit).
function Planner.Steps(segments, from, max)
  local steps = {}
  local caps = {}
  for _, rank in ipairs(Planner.RANKS) do
    if rank.cap < Planner.MAX_SKILL and rank.cap >= from and (not max or rank.cap >= max) then
      table.insert(caps, rank.cap)
    end
  end
  local nextCap = 1
  local function notice(at)
    local rank = Planner.NextRank(at)
    table.insert(steps, { rank = { at = at, name = rank.name, cap = rank.cap, level = rank.level } })
  end
  for _, seg in ipairs(segments or {}) do
    -- A segment that goes beyond a cap (or starts right at it) needs the next rank first.
    while caps[nextCap] and seg.to > caps[nextCap] do
      notice(caps[nextCap])
      nextCap = nextCap + 1
    end
    table.insert(steps, { seg = seg })
  end
  return steps
end
