-- Tracker: records everything looted or gathered, with position and value,
-- grouped into sessions. A session starts automatically with the first loot
-- and ends after a longer idle gap.
local ADDON, ns = ...

local Tracker = {}
ns.Tracker = Tracker

local SESSION_IDLE_GAP = 15 * 60 -- seconds without loot that close a session
local CAST_WINDOW = 5            -- seconds between a gathering cast and its loot window
local MAX_EVENTS_PER_SESSION = 10000

-- Rank-1 spell IDs of the gathering skills; names are resolved at runtime
-- so the client locale does not matter.
local GATHER_SPELLS = {
  skinning = { 8613, 8617, 8618, 10768 },
  mining = { 2575, 2576, 3564, 10248 },
  herbalism = { 2366, 2368, 3570, 11993 },
}

local gatherByName = {}
local lastCast = nil
local lootOpen = false
local moneyAtLootOpen = nil
local markLootEvent -- defined with the coin handling below
local lootNpc = nil -- first creature in the open loot window, gets the coins
-- Corpses already counted in this session. The client forbids addons to read the
-- combat log, so kills are counted as looted corpses (each creature GUID once).
local countedCorpses, countedFor = {}, nil

local function buildGatherNames()
  for kind, ids in pairs(GATHER_SPELLS) do
    for _, id in ipairs(ids) do
      local name = ns.SpellName(id)
      if name then gatherByName[name] = kind end
    end
  end
end

local function npcIdFromGuid(guid)
  if type(guid) ~= "string" then return nil end
  local unitType, _, _, _, _, npcID = strsplit("-", guid)
  if unitType == "Creature" or unitType == "Vehicle" then
    return tonumber(npcID)
  end
  return nil
end

-- Session handling ---------------------------------------------------------

function Tracker.Current()
  local db = ns.db
  if not db or not db.current then return nil end
  return db.sessions[db.current]
end

function Tracker.NewSession()
  local db = ns.db
  local now = time()
  local mapID = ns.PlayerPosition()
  local session = {
    char = ns.CharKey(),
    level = UnitLevel("player"),
    start = now,
    last = now,
    value = 0,
    money = 0,
    unpriced = 0,
    kinds = {},
    items = {},
    zones = {},
    events = {},
    -- per creature type: kills by the player, item value and coins looted
    npcs = {},
  }
  if mapID then session.zones[mapID] = ns.MapName(mapID) end
  table.insert(db.sessions, session)
  db.current = #db.sessions
  return session
end

local function npcStats(session, npcID)
  session.npcs = session.npcs or {}
  local stats = session.npcs[npcID]
  if not stats then
    stats = { kills = 0, value = 0, money = 0 }
    session.npcs[npcID] = stats
  end
  return stats
end

-- Tracking can be switched off with the Stop button; nothing is recorded then.
function Tracker.IsTracking()
  return ns.db and ns.db.tracking ~= false
end

function Tracker.Start()
  ns.db.tracking = true
  return Tracker.NewSession()
end

function Tracker.Stop()
  local session = Tracker.Current()
  if session and not session.stopped then session.stopped = time() end
  ns.db.tracking = false
end

-- Throws the current session away and, if tracking, starts an empty one.
function Tracker.Reset()
  local db = ns.db
  if db.current and db.sessions[db.current] then
    table.remove(db.sessions, db.current)
  end
  db.current = nil
  if Tracker.IsTracking() then Tracker.NewSession() end
end

-- Returns the running session, starting a new one if there is none or the
-- last activity is too long ago; nil while tracking is stopped.
local function activeSession()
  if not Tracker.IsTracking() then return nil end
  local session = Tracker.Current()
  if session and not session.stopped and session.char == ns.CharKey() and time() - (session.last or 0) <= SESSION_IDLE_GAP then
    return session
  end
  return Tracker.NewSession()
end

-- Duration counts until the last loot, or until now if still running.
function Tracker.Duration(session)
  if not session then return 0 end
  if session.stopped then return math.max(0, session.stopped - session.start) end
  local stop = session.last or session.start
  if time() - (session.last or 0) <= SESSION_IDLE_GAP then
    stop = time()
  end
  return math.max(0, stop - session.start)
end

function Tracker.GoldPerHour(session)
  local seconds = Tracker.Duration(session)
  if seconds < 60 then return nil end
  return (session.value + session.money) * 3600 / seconds
end

-- Recording ----------------------------------------------------------------

local function lootKind()
  if IsFishingLoot and IsFishingLoot() then return "fishing" end
  if lastCast and GetTime() - lastCast.t <= CAST_WINDOW then
    local kind = gatherByName[lastCast.name]
    if kind then return kind end
  end
  return "loot"
end

local function recordItem(session, kind, itemID, count, sourceGuid, mapID, x, y)
  local value, ah, vendor = ns.Prices.Value(itemID)
  -- Prefer what the item realistically sells for (recorded sales), not the asking price.
  if ns.Market then
    local expected, known = ns.Market.Expected(itemID, ah, vendor)
    if known then
      value = math.max(vendor or 0, expected or 0)
      ah = ah or 0
    end
  end
  local entry = session.items[itemID]
  if not entry then
    entry = { n = 0, v = 0 }
    session.items[itemID] = entry
  end
  entry.n = entry.n + count
  entry.v = entry.v + value * count
  local npcID = npcIdFromGuid(sourceGuid)
  if npcID then
    local stats = npcStats(session, npcID)
    stats.value = stats.value + value * count
    lootNpc = lootNpc or npcID
  end
  session.value = session.value + value * count
  if not ah and not vendor then
    session.unpriced = session.unpriced + count
  end
  if #session.events < MAX_EVENTS_PER_SESSION then
    table.insert(session.events, {
      t = time(),
      k = kind,
      i = itemID,
      n = count,
      ah = ah,
      vp = vendor,
      npc = npcIdFromGuid(sourceGuid),
      m = mapID,
      x = x,
      y = y,
      sp = lastCast and lastCast.name or nil,
    })
  end
end

local ITEM_SLOT = (Enum and Enum.LootSlotType and Enum.LootSlotType.Item) or 1

local function onLootOpened()
  if lootOpen then return end
  lootOpen = true
  moneyAtLootOpen = GetMoney()
  markLootEvent()
  -- Coin-only corpses have no item slot; take the creature from the first slot.
  lootNpc = GetNumLootItems() > 0 and GetLootSourceInfo and npcIdFromGuid(GetLootSourceInfo(1)) or nil

  local session = activeSession()
  if not session then return end
  local kind = lootKind()
  if kind == "loot" and GetLootSourceInfo then
    if countedFor ~= session then countedCorpses, countedFor = {}, session end
    for slot = 1, GetNumLootItems() do
      local guid = GetLootSourceInfo(slot)
      local npcID = npcIdFromGuid(guid)
      if npcID and not countedCorpses[guid] then
        countedCorpses[guid] = true
        local stats = npcStats(session, npcID)
        stats.kills = stats.kills + 1
      end
    end
  end
  local mapID, x, y = ns.PlayerPosition()
  if mapID and not session.zones[mapID] then
    session.zones[mapID] = ns.MapName(mapID)
  end

  local recorded = false
  for slot = 1, GetNumLootItems() do
    if GetLootSlotType(slot) == ITEM_SLOT then
      local link = GetLootSlotLink(slot)
      local itemID = link and tonumber(link:match("item:(%d+)"))
      if itemID then
        local _, _, quantity = GetLootSlotInfo(slot)
        local sourceGuid = GetLootSourceInfo and GetLootSourceInfo(slot)
        recordItem(session, kind, itemID, quantity or 1, sourceGuid, mapID, x, y)
        recorded = true
      end
    end
  end

  if recorded then
    session.kinds[kind] = (session.kinds[kind] or 0) + 1
  end
  session.last = time()
  -- A gathering cast belongs to exactly one loot window.
  lastCast = nil
end

local LOOT_MONEY_WINDOW = 2 -- seconds around a loot event in which coins count as loot
local lastLootEvent = -100
local pendingMoney, pendingAt = 0, -100 -- coins that arrived just before the loot event
local lastMoney = nil
local otherSource = false -- merchant, mail, trade, quest reward window open

local function addLootMoney(session, delta)
  session.money = session.money + delta
  if lootNpc then
    local stats = npcStats(session, lootNpc)
    stats.money = stats.money + delta
  end
end

local function lootSession()
  if not Tracker.IsTracking() then return nil end
  local session = Tracker.Current()
  if session and not session.stopped then return session end
  return nil
end

function markLootEvent()
  lastLootEvent = GetTime()
  if pendingMoney > 0 and GetTime() - pendingAt <= LOOT_MONEY_WINDOW then
    local session = lootSession()
    if session then addLootMoney(session, pendingMoney) end
  end
  pendingMoney = 0
end

ns.On("PLAYER_MONEY", function()
  local now = GetMoney()
  local delta = lastMoney and now - lastMoney or 0
  lastMoney = now
  if delta <= 0 or otherSource then return end
  if lootOpen or GetTime() - lastLootEvent <= LOOT_MONEY_WINDOW then
    local session = lootSession()
    if session then addLootMoney(session, delta) end
  else
    -- Auto-loot can pay before the loot event fires; hold it briefly.
    pendingMoney, pendingAt = pendingMoney + delta, GetTime()
  end
end)
ns.On("PLAYER_ENTERING_WORLD", function() lastMoney = GetMoney() end)
for _, event in ipairs({ "MERCHANT_SHOW", "MAIL_SHOW", "TRADE_SHOW", "QUEST_COMPLETE", "AUCTION_HOUSE_SHOW", "TAXIMAP_OPENED" }) do
  ns.On(event, function() otherSource = true end)
end
for _, event in ipairs({ "MERCHANT_CLOSED", "MAIL_CLOSED", "TRADE_CLOSED", "QUEST_FINISHED", "AUCTION_HOUSE_CLOSED", "TAXIMAP_CLOSED" }) do
  ns.On(event, function() otherSource = false end)
end
ns.On("LOOT_READY", markLootEvent)

local function onLootClosed()
  if not lootOpen then return end
  lootOpen = false
  moneyAtLootOpen = nil
  markLootEvent()
  C_Timer.After(1.5, function() lootNpc = nil end)
end

-- Character snapshot, so levels and skills are visible outside the game
-- and in the window.
local function snapshotCharacter()
  local db = ns.db
  local className, classFile = UnitClass("player")
  local info = {
    updated = time(),
    name = UnitName("player"),
    level = UnitLevel("player"),
    class = classFile,
    className = className,
    faction = UnitFactionGroup("player"),
    money = GetMoney(),
    professions = {},
  }
  if GetProfessions and GetProfessionInfo then
    local indices = { GetProfessions() }
    for _, index in pairs(indices) do
      if index then
        local name, _, rank, maxRank, _, _, skillLine = GetProfessionInfo(index)
        if name then
          table.insert(info.professions, { name = name, rank = rank, max = maxRank, line = skillLine })
        end
      end
    end
  end
  if #info.professions == 0 and GetNumSkillLines and GetSkillLineInfo then
    for i = 1, GetNumSkillLines() do
      local name, isHeader, _, rank, _, _, maxRank = GetSkillLineInfo(i)
      if name and not isHeader then
        table.insert(info.professions, { name = name, rank = rank, max = maxRank })
      end
    end
  end
  db.chars[ns.CharKey()] = info
end

Tracker.SnapshotCharacter = snapshotCharacter

function Tracker.Character()
  return ns.db and ns.db.chars[ns.CharKey()]
end

-- Events -------------------------------------------------------------------

ns.On("UNIT_SPELLCAST_SUCCEEDED", function(_, unit, _, spellID)
  if unit ~= "player" then return end
  lastCast = { id = spellID, name = ns.SpellName(spellID), t = GetTime() }
end)

-- Experience: gained XP per session, including across level-ups.
local lastXP, lastXPMax = nil, nil

local function readXP()
  lastXP, lastXPMax = UnitXP("player"), UnitXPMax("player")
end

ns.On("PLAYER_XP_UPDATE", function(_, unit)
  if unit and unit ~= "player" then return end
  local xp, max = UnitXP("player"), UnitXPMax("player")
  if lastXP then
    local gained = xp >= lastXP and xp - lastXP or (lastXPMax - lastXP) + xp
    local session = gained > 0 and activeSession()
    if session then
      session.xpStart = session.xpStart or session.start
      session.xp = (session.xp or 0) + gained
      session.last = time()
    end
  end
  lastXP, lastXPMax = xp, max
end)
ns.On("PLAYER_ENTERING_WORLD", function()
  readXP()
  -- Sessions from before XP tracking existed measure XP from now on.
  local session = Tracker.Current()
  if session and not session.stopped and not session.xpStart then session.xpStart = time() end
end)

-- XP per hour of a session, or nil.
function Tracker.XPPerHour(session)
  local seconds = Tracker.Duration(session) - ((session.xpStart or session.start) - session.start)
  if seconds < 60 or not session.xp or session.xp <= 0 then return nil end
  return session.xp * 3600 / seconds
end

ns.On("LOOT_OPENED", function() onLootOpened() end)
ns.On("LOOT_READY", function() onLootOpened() end)
ns.On("LOOT_CLOSED", function() onLootClosed() end)

ns.On("PLAYER_ENTERING_WORLD", function()
  buildGatherNames()
  snapshotCharacter()
end)
ns.On("SKILL_LINES_CHANGED", function() snapshotCharacter() end)
ns.On("CHAT_MSG_SKILL", function() snapshotCharacter() end)
ns.On("PLAYER_LEVEL_UP", function() snapshotCharacter() end)
ns.On("PLAYER_LOGOUT", function() snapshotCharacter() end)
