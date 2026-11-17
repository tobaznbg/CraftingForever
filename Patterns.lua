-- Patterns: finds the recipe items ("Muster: ...") of a profession and links
-- each to the recipe it teaches, so auction offers can be valued.
--
-- The client has no direct item -> recipe link, so the pattern name without its
-- prefix is matched against the recipe name. Item IDs are found once by walking
-- the client item table (instant, no server query) and cached in the saved variables.
local ADDON, ns = ...

local Patterns = {}
ns.Patterns = Patterns

local RECIPE_CLASS = 9
local SUBCLASS_BY_SKILL_LINE = { [165] = 1 } -- leatherworking
local MAX_ITEM_ID = 60000
local CHUNK = 3000
local CACHE_VERSION = 1

local function itemClass(itemID)
  local getInstant = (C_Item and C_Item.GetItemInfoInstant) or GetItemInfoInstant
  if not getInstant then return nil end
  local _, _, _, _, _, classID, subclassID = getInstant(itemID)
  return classID, subclassID
end

local function cache()
  local c = ns.db.patterns
  if not c or c.v ~= CACHE_VERSION then
    c = { v = CACHE_VERSION, items = {}, done = false }
    ns.db.patterns = c
  end
  return c
end

-- Walks item IDs in chunks across frames to avoid a hitch.
local function findItems(onDone)
  local c = cache()
  local wanted = {}
  for _, sub in pairs(SUBCLASS_BY_SKILL_LINE) do wanted[sub] = true end
  local id = 1
  local function step()
    local last = math.min(MAX_ITEM_ID, id + CHUNK - 1)
    for itemID = id, last do
      local classID, subclassID = itemClass(itemID)
      if classID == RECIPE_CLASS and wanted[subclassID] then
        c.items[itemID] = c.items[itemID] or { sub = subclassID }
      end
    end
    id = last + 1
    if id <= MAX_ITEM_ID then
      C_Timer.After(0, function() ns.Safe(step) end)
    else
      c.done = true
      onDone()
    end
  end
  step()
end

-- "Muster: Rotwelpenhandschuhe" -> "Rotwelpenhandschuhe"
local function taughtName(itemName)
  return itemName and (itemName:match("^[^:]+:%s*(.+)$") or itemName)
end

-- Item names arrive asynchronously; fills `n` as they load.
local function loadNames()
  for itemID, entry in pairs(cache().items) do
    if not entry.n then
      local name = ns.ItemName(itemID)
      if name and not name:find("^Item %d") then
        entry.n = name
      elseif Item and Item.CreateFromItemID then
        Item:CreateFromItemID(itemID):ContinueOnItemLoad(function()
          entry.n = ns.ItemName(itemID)
        end)
      end
    end
  end
end

function Patterns.Ensure()
  local c = cache()
  if c.done then
    loadNames()
  elseif not Patterns.running then
    Patterns.running = true
    findItems(function()
      Patterns.running = false
      loadNames()
    end)
  end
end

-- Patterns for one profession scan: list of { itemID, name, recipeID }.
function Patterns.ForScan(scan)
  local sub = SUBCLASS_BY_SKILL_LINE[scan.professionID]
  local byName = {}
  for recipeID, recipe in pairs(scan.recipes) do
    if recipe.name then byName[recipe.name] = recipeID end
  end
  local list = {}
  for itemID, entry in pairs(cache().items) do
    local recipeID = entry.sub == sub and entry.n and byName[taughtName(entry.n)]
    if recipeID then
      table.insert(list, { itemID = itemID, name = entry.n, recipeID = recipeID })
    end
  end
  return list
end

-- Usual price: the average cheapest offer of the last two weeks (ns.Item), or nil.
function Patterns.UsualPrice(itemID)
  return ns.Item(itemID).avg
end

ns.OnReady(function()
  C_Timer.After(5, function() ns.Safe(Patterns.Ensure) end)
end)
