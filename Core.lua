-- Core: namespace, saved variables, event dispatch, error capture, utilities.
local ADDON, ns = ...

ns.name = ADDON
ns.version = "0.4.0-dev"

local MAX_ERRORS = 50

-- Errors are kept in the saved variables so they can be read outside the game.
local function logError(err, stack)
  local db = CraftingForeverDB
  if type(db) == "table" then
    db.errors = db.errors or {}
    table.insert(db.errors, { t = time(), e = tostring(err), s = stack })
    while #db.errors > MAX_ERRORS do
      table.remove(db.errors, 1)
    end
  end
  print("|cffff5555CraftingForever Fehler:|r " .. tostring(err))
end

local function errorHandler(err)
  logError(err, debugstack and debugstack(2, 12, 0) or nil)
  return err
end

function ns.Safe(fn, ...)
  return xpcall(fn, errorHandler, ...)
end

-- Event dispatch: several modules may listen to the same event.
local frame = CreateFrame("Frame")
local handlers = {}

function ns.On(event, fn)
  if not handlers[event] then
    handlers[event] = {}
    frame:RegisterEvent(event)
  end
  table.insert(handlers[event], fn)
end

frame:SetScript("OnEvent", function(_, event, ...)
  local list = handlers[event]
  if not list then return end
  for _, fn in ipairs(list) do
    ns.Safe(fn, event, ...)
  end
end)

-- Callbacks run once the saved variables are available.
local readyCallbacks = {}

function ns.OnReady(fn)
  if ns.db then
    ns.Safe(fn)
  else
    table.insert(readyCallbacks, fn)
  end
end

ns.On("ADDON_LOADED", function(_, loadedName)
  if loadedName ~= ADDON then return end
  CraftingForeverDB = CraftingForeverDB or {}
  local db = CraftingForeverDB
  db.schema = 1
  db.errors = db.errors or {}
  db.chars = db.chars or {}
  db.sessions = db.sessions or {}
  db.ui = db.ui or { shown = true }
  ns.db = db
  for _, fn in ipairs(readyCallbacks) do
    ns.Safe(fn)
  end
  readyCallbacks = {}
end)

-- Utilities ----------------------------------------------------------------

function ns.CharKey()
  return (UnitName("player") or "?") .. "-" .. (GetRealmName() or "?")
end

local GOLD_ICON = "|TInterface\\MoneyFrame\\UI-GoldIcon:0:0:2:0|t"
local SILVER_ICON = "|TInterface\\MoneyFrame\\UI-SilverIcon:0:0:2:0|t"
local COPPER_ICON = "|TInterface\\MoneyFrame\\UI-CopperIcon:0:0:2:0|t"

-- Money with the game's coin icons, so gold and silver cannot be mixed up.
--   short  leave out copper once there is gold
function ns.FormatMoney(copper, short)
  copper = math.floor((copper or 0) + 0.5)
  local negative = copper < 0
  if negative then copper = -copper end
  local g = math.floor(copper / 10000)
  local s = math.floor((copper % 10000) / 100)
  local c = copper % 100
  local out
  if g > 0 then
    out = g .. GOLD_ICON .. " " .. s .. SILVER_ICON
    if not short then out = out .. " " .. c .. COPPER_ICON end
  elseif s > 0 then
    out = s .. SILVER_ICON .. " " .. c .. COPPER_ICON
  else
    out = c .. COPPER_ICON
  end
  return negative and ("-" .. out) or out
end

function ns.FormatDuration(seconds)
  seconds = math.max(0, math.floor(seconds or 0))
  local h = math.floor(seconds / 3600)
  local m = math.floor((seconds % 3600) / 60)
  local s = seconds % 60
  if h > 0 then
    return string.format("%d:%02d:%02d", h, m, s)
  end
  return string.format("%d:%02d", m, s)
end

function ns.SpellName(spellID)
  if not spellID then return nil end
  if C_Spell and C_Spell.GetSpellInfo then
    local info = C_Spell.GetSpellInfo(spellID)
    return info and info.name
  end
  if GetSpellInfo then
    return (GetSpellInfo(spellID))
  end
  return nil
end

function ns.ItemName(itemID)
  if C_Item and C_Item.GetItemNameByID then
    local name = C_Item.GetItemNameByID(itemID)
    if name then return name end
  end
  if GetItemInfo then
    local name = GetItemInfo(itemID)
    if name then return name end
  end
  local stored = ns.db and ns.db.prices and ns.db.prices[itemID]
  if stored and stored.n then return stored.n end
  -- Not in the client's item cache yet: ask the server; GET_ITEM_INFO_RECEIVED
  -- follows and windows refresh themselves.
  if C_Item and C_Item.RequestLoadItemDataByID then
    C_Item.RequestLoadItemDataByID(itemID)
  end
  return "Item " .. tostring(itemID)
end

function ns.PlayerPosition()
  if not (C_Map and C_Map.GetBestMapForUnit) then return nil end
  local mapID = C_Map.GetBestMapForUnit("player")
  if not mapID then return nil end
  local x, y
  local pos = C_Map.GetPlayerMapPosition and C_Map.GetPlayerMapPosition(mapID, "player")
  if pos then
    x, y = pos:GetXY()
    x = x and math.floor(x * 1000 + 0.5) / 10
    y = y and math.floor(y * 1000 + 0.5) / 10
  end
  return mapID, x, y
end

function ns.MapName(mapID)
  if mapID and C_Map and C_Map.GetMapInfo then
    local info = C_Map.GetMapInfo(mapID)
    return info and info.name
  end
  return nil
end

-- Bag IDs the player carries: backpack, bags and (newer clients) the reagent bag.
function ns.CarriedBags()
  local ids = {}
  for bag = 0, (NUM_BAG_SLOTS or 4) do table.insert(ids, bag) end
  local reagent = Enum and Enum.BagIndex and Enum.BagIndex.ReagentBag
  if reagent then table.insert(ids, reagent) end
  return ids
end

-- Bank container IDs: the bank itself and its bag slots.
function ns.BankBags()
  local ids = { (Enum and Enum.BagIndex and Enum.BagIndex.Bank) or BANK_CONTAINER or -1 }
  local first = (NUM_TOTAL_EQUIPPED_BAG_SLOTS or ((NUM_BAG_SLOTS or 4) + (NUM_REAGENTBAG_SLOTS or 0))) + 1
  for bag = first, first + (NUM_BANKBAGSLOTS or 6) - 1 do table.insert(ids, bag) end
  return ids
end

