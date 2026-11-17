-- Costs: profession helpers for the planner. Prices come from ns.Item only.
local ADDON, ns = ...

local Costs = {}
ns.Costs = Costs

-- Copper per unit to buy a reagent, and where ("Händler" or "AH").
function Costs.Buy(itemID)
  local unit, vendor = ns.Item.BuyCost(ns.Item(itemID))
  if not unit then return nil end
  return unit, vendor and "Händler" or "AH"
end

function Costs.VendorSell(itemID)
  return ns.Item(itemID).vendorSell or 0
end

-- Copper per unit an auction brings (Item.SellNet), or nil if it only goes to a merchant.
function Costs.AuctionSell(itemID)
  local net, viaAH = ns.Item.SellNet(ns.Item(itemID))
  return viaAH and net or nil
end

-- Units in bags and bank.
function Costs.Owned(itemID)
  local count = (C_Item and C_Item.GetItemCount) or GetItemCount
  return count and count(itemID, true) or 0
end

-- Skill data of a profession from ns.SkillData, or nil (placeholder or not generated yet).
local function skillData(professionID)
  local skill = ns.SkillData and ns.SkillData[professionID]
  if type(skill) == "table" and type(skill.recipes) == "table" and next(skill.recipes) then return skill end
end
Costs.SkillData = skillData

-- The character's own profession scans by profession ID.
local function ownScans()
  local own, prefix = {}, ns.CharKey() .. ":"
  for key, scan in pairs(ns.db.recipes or {}) do
    if key:sub(1, #prefix) == prefix and scan.professionID then own[scan.professionID] = scan end
  end
  return own
end

-- Rank and cap of a profession: the character snapshot is newer than the last time
-- the profession window was opened.
local function ownSkill(name, scan)
  local rank, max = scan and scan.rank, scan and scan.max
  local char = ns.db.chars and ns.db.chars[ns.CharKey()]
  for _, prof in ipairs(char and char.professions or {}) do
    if name and prof.name == name then rank, max = prof.rank or rank, prof.max or max end
  end
  return rank, max
end

local function professionName(professionID, scan)
  local recipeData = ns.RecipeData and ns.RecipeData[professionID]
  local skill = ns.SkillData and ns.SkillData[professionID]
  return (scan and scan.profession) or (recipeData and recipeData.name) or (skill and skill.name)
end

-- Latest recipe scan of the player's professions that have planner data:
-- returns a list of { scan, data, rank, max, name, pid, skill }.
function Costs.Professions()
  local list = {}
  for pid, scan in pairs(ownScans()) do
    local skill = skillData(pid)
    local data = skill and skill.recipes or (ns.DataBySkillLine and ns.DataBySkillLine[pid])
    if data then
      local rank, max = ownSkill(scan.profession, scan)
      table.insert(list, { scan = scan, data = data, rank = rank, max = max, name = scan.profession,
        pid = pid, skill = skill })
    end
  end
  return list
end

-- Planner input for any crafting profession, also one the character does not have:
-- { pid, name, scan (own, or nil), rank, max (nil when not learned), skill, data }.
-- Without data the second value says why: "nodata" (no skill data for the profession)
-- or "noscan" (only the old data, which needs the own scan for reagents and products).
function Costs.Profession(professionID)
  local scan = ownScans()[professionID]
  local name = professionName(professionID, scan)
  local rank, max = ownSkill(name, scan)
  local prof = { pid = professionID, name = name, scan = scan, rank = rank, max = max }
  local skill = skillData(professionID)
  if skill then
    prof.skill, prof.data = skill, skill.recipes
    return prof
  end
  local data = ns.DataBySkillLine and ns.DataBySkillLine[professionID]
  if not data then return nil, "nodata", prof end
  if not scan then return nil, "noscan", prof end
  prof.data = data
  return prof
end

-- All crafting professions for a choice: { pid, name, icon, rank, max, own, hasData }...,
-- own professions first (highest skill first), then by name.
function Costs.AllProfessions()
  local ids, own = {}, ownScans()
  for pid in pairs(ns.RecipeData or {}) do ids[pid] = true end
  for pid in pairs(ns.SkillData or {}) do ids[pid] = true end
  local list = {}
  for pid in pairs(ids) do
    local name = professionName(pid, own[pid])
    if name then
      local rank, max = ownSkill(name, own[pid])
      local recipeData = ns.RecipeData and ns.RecipeData[pid]
      table.insert(list, { pid = pid, name = name, icon = recipeData and recipeData.icon,
        rank = rank, max = max, own = rank ~= nil,
        hasData = skillData(pid) ~= nil or (own[pid] ~= nil and ns.DataBySkillLine ~= nil
          and ns.DataBySkillLine[pid] ~= nil) })
    end
  end
  table.sort(list, function(a, b)
    if a.own ~= b.own then return a.own end
    if a.own and a.rank ~= b.rank then return a.rank > b.rank end
    return a.name < b.name
  end)
  return list
end

-- Candidate recipes of a profession (Planner.Candidates): from ns.SkillData when there is
-- an entry, else from the own scan with the old color/learn data.
function Costs.Candidates(prof, all)
  if prof.skill then
    return ns.Planner.Candidates(ns.Planner.SkillRecipes(prof.skill, prof.scan), prof.skill.recipes,
      Costs.Buy, Costs.VendorSell, Costs.AuctionSell, all)
  end
  return ns.Planner.Candidates(prof.scan.recipes, prof.data,
    Costs.Buy, Costs.VendorSell, Costs.AuctionSell, all)
end
