-- Sync: the state of the player's other PCs. The companion app uploads this addon's own data
-- (ledger, profession scans, own auctions, settings) after every logout or /reload; the server
-- merges the uploads of all PCs and the app writes the result into the data addon
-- (m4-companion_Data, Data_Sync.lua -> M4CompanionData.Sync). It is merged here on load:
--   ledger    union; a trade counts once (Sync.EventKey, sameTrade), copies complete each other
--   recipes   per "Name-Realm:Profession" the scan with the newer t
--   owned     per character the answer with the newer t
--   chars     per character the snapshot with the newer updated; the gold (money) by its own
--             moneyT, the last name (fullName) from the other copy when the newer has none
--   inventory per character bags and bank each by its own time (bagsT, bankT)
--   settings  ns.db.settings and ns.db.minimap, taken when the synced settingsT is newer than
--             the local one (or there is none locally yet)
-- Nothing local is lost, merging the same state again changes nothing. The same rules run on
-- the server (m4-companion, internal/server/sync.go), so all PCs converge.
-- ns.db.settingsT is set on logout and /reload when settings or minimap changed this session.
local ADDON, ns = ...

local Sync = {}
ns.CloudSync = Sync

local MAIL_SLACK = 900       -- a mail's receive time drifts (Ledger.lua)
local BUY_SLACK = 2 * 3600   -- a hook purchase gets its mail's signature up to this later
local DEFAULT_KEEP = 3000    -- Ledger.lua's limit, if it does not publish one

local function num(v) return type(v) == "number" and v or 0 end
local function str(v) return type(v) == "string" and v or "" end

-- Numbers as text; integers without exponent.
local function fmt(v)
  v = num(v)
  if v == math.floor(v) and math.abs(v) < 1e15 then return string.format("%d", v) end
  return tostring(v)
end

local function copy(v)
  if type(v) ~= "table" then return v end
  local t = {}
  for k, x in pairs(v) do t[k] = copy(x) end
  return t
end

-- Identity of an event across copies: only fields that never change after it was logged.
-- A craft grows (u, x, r) while the player keeps crafting; a purchase gets its mail
-- signature (m) later.
function Sync.EventKey(e)
  local k = str(e.k)
  local parts = { k, fmt(e.t), fmt(e.i), str(e.n) }
  if k == "craft" then
    parts[5], parts[6] = fmt(e.rid), str(e.src)
  else
    parts[5], parts[6], parts[7], parts[8], parts[9] = fmt(e.u), fmt(e.c), fmt(e.p), fmt(e.cut), fmt(e.d)
  end
  return table.concat(parts, "|")
end

-- The same mail seen on two PCs (receive time drifts), or a purchase logged by the hooks on
-- one PC and from its mail on the other.
local function sameTrade(a, b)
  local k = str(a.k)
  if k ~= str(b.k) or k == "craft" or k == "post" then return false end
  local dt = math.abs(num(a.t) - num(b.t))
  local ma, mb = str(a.m), str(b.m)
  if ma ~= "" and ma == mb then
    return dt <= (k == "buy" and BUY_SLACK or MAIL_SLACK)
  end
  if k == "buy" and (ma == "") ~= (mb == "") then
    local sameItem = (num(a.i) ~= 0 and num(a.i) == num(b.i)) or (str(a.n) ~= "" and str(a.n) == str(b.n))
    return sameItem and num(a.c) == num(b.c) and math.max(num(a.u), 1) == math.max(num(b.u), 1)
      and dt <= BUY_SLACK
  end
  return false
end

-- Completes the kept copy with what the other one learned later.
local function enrich(keep, other)
  local changed = false
  if str(keep.m) == "" and str(other.m) ~= "" then
    keep.m = other.m
    changed = true
  end
  if keep.i == nil and other.i ~= nil then
    keep.i = other.i
    changed = true
  end
  if keep.k == "craft" and math.max(num(other.x), 1) > math.max(num(keep.x), 1) then
    keep.u, keep.x, keep.r = other.u, other.x, copy(other.r)
    changed = true
  end
  return changed
end

-- Adds the incoming events missing in list (in place), sorted by time, at most keep newest.
-- Returns the number of added events and whether the list changed.
function Sync.MergeEvents(list, incoming, keep)
  local n0 = #list
  local used, byKey = {}, {}
  for idx = 1, n0 do
    local key = Sync.EventKey(list[idx])
    local q = byKey[key]
    if not q then
      q = {}
      byKey[key] = q
    end
    q[#q + 1] = idx
  end
  local changed, rest = false, {}
  for _, e in ipairs(incoming) do
    if type(e) == "table" then
      local q = byKey[Sync.EventKey(e)]
      local idx = q and table.remove(q, 1)
      if idx then
        used[idx] = true
        if enrich(list[idx], e) then changed = true end
      else
        rest[#rest + 1] = e
      end
    end
  end
  local added, retimed = {}, false
  for _, e in ipairs(rest) do
    local found = false
    for idx = n0, 1, -1 do
      if not used[idx] and sameTrade(list[idx], e) then
        used[idx] = true
        if enrich(list[idx], e) then changed = true end
        -- both copies take the earlier time, so the PCs end up with identical events
        if num(e.t) < num(list[idx].t) then
          list[idx].t = e.t
          changed, retimed = true, true
        end
        found = true
        break
      end
    end
    if not found then added[#added + 1] = copy(e) end
  end
  if #added > 0 or retimed then
    local all = {}
    for idx = 1, n0 do all[idx] = { e = list[idx], t = num(list[idx].t), o = idx } end
    for j, e in ipairs(added) do all[n0 + j] = { e = e, t = num(e.t), o = n0 + j } end
    table.sort(all, function(a, b)
      if a.t ~= b.t then return a.t < b.t end
      return a.o < b.o
    end)
    for idx, w in ipairs(all) do list[idx] = w.e end
    changed = true
  end
  if keep and #list > keep then
    local drop, n = #list - keep, #list
    for idx = 1, n do list[idx] = list[idx + drop] end
    changed = true
  end
  return #added, changed
end

-- Overwrites dst with src in place (tables other modules hold stay valid).
local function assign(dst, src)
  for k in pairs(dst) do
    if src[k] == nil then dst[k] = nil end
  end
  for k, v in pairs(src) do
    if type(v) == "table" and type(dst[k]) == "table" then
      assign(dst[k], v)
    else
      dst[k] = copy(v)
    end
  end
end

-- A character snapshot from the sync against the local one (same rule as the server's
-- mergeChar): the newer updated wins, the gold from whichever copy saw it later, the last name
-- kept. Returns the new table, nil when nothing changes.
function Sync.MergeChar(old, new)
  if type(old) ~= "table" then return copy(new) end
  local winner, other = old, new
  if num(new.updated) > num(old.updated) then winner, other = new, old end
  local out = copy(winner)
  if num(other.moneyT) > num(out.moneyT) then out.money, out.moneyT = other.money, other.moneyT end
  if (out.fullName == nil or out.fullName == "") and type(other.fullName) == "string" and other.fullName ~= "" then
    out.fullName = other.fullName
  end
  if num(out.updated) == num(old.updated) and out.money == old.money and out.moneyT == old.moneyT
    and out.fullName == old.fullName then
    return nil
  end
  return out
end

-- Merges a synced state into db. Returns what changed.
function Sync.Apply(db, s)
  local stats = { added = 0, recipes = 0, owned = 0, chars = 0, inventory = 0, settings = false }
  if type(db) ~= "table" or type(s) ~= "table" then return stats end
  local keep = ns.Ledger and ns.Ledger.KEEP or DEFAULT_KEEP
  if type(s.ledger) == "table" then
    db.ledger = db.ledger or {}
    for key, events in pairs(s.ledger) do
      if type(key) == "string" and type(events) == "table" then
        local b = db.ledger[key]
        if type(b) ~= "table" then
          -- imported: the one-time sniper log import (Ledger.lua) belongs to the PC that had it
          b = { events = {}, imported = true }
          db.ledger[key] = b
        end
        b.events = b.events or {}
        local n = Sync.MergeEvents(b.events, events, keep)
        stats.added = stats.added + n
      end
    end
  end
  local function newer(have, key, v)
    local old = have[key]
    return type(v) == "table" and (type(old) ~= "table" or num(v.t) > num(old.t))
  end
  if type(s.recipes) == "table" then
    db.recipes = db.recipes or {}
    for key, scan in pairs(s.recipes) do
      if type(key) == "string" and newer(db.recipes, key, scan) then
        db.recipes[key] = copy(scan)
        stats.recipes = stats.recipes + 1
      end
    end
  end
  if type(s.owned) == "table" then
    db.owned = db.owned or {}
    for key, o in pairs(s.owned) do
      if type(key) == "string" and newer(db.owned, key, o) then
        db.owned[key] = copy(o)
        stats.owned = stats.owned + 1
      end
    end
  end
  if type(s.chars) == "table" then
    db.chars = db.chars or {}
    for key, c in pairs(s.chars) do
      if type(key) == "string" and type(c) == "table" then
        local merged = Sync.MergeChar(db.chars[key], c)
        if merged then
          db.chars[key] = merged
          stats.chars = stats.chars + 1
        end
      end
    end
  end
  if type(s.inventory) == "table" then
    db.inventory = db.inventory or {}
    for key, inv in pairs(s.inventory) do
      if type(key) == "string" and type(inv) == "table" then
        local have = db.inventory[key]
        if type(have) ~= "table" then have = {}; db.inventory[key] = have end
        local took = false
        for _, part in ipairs({ "bags", "bank" }) do
          local t = part .. "T"
          if type(inv[part]) == "table" and num(inv[t]) > num(have[t]) then
            have[part], have[t] = copy(inv[part]), num(inv[t])
            took = true
          end
        end
        if took then stats.inventory = stats.inventory + 1 end
      end
    end
  end
  if type(s.settings) == "table" and (db.settingsT == nil or num(s.settingsT) > num(db.settingsT)) then
    if type(db.settings) ~= "table" then db.settings = {} end
    assign(db.settings, s.settings)
    if type(s.minimap) == "table" then
      if type(db.minimap) ~= "table" then db.minimap = {} end
      assign(db.minimap, s.minimap)
    end
    db.settingsT = num(s.settingsT)
    stats.settings = true
  end
  return stats
end

-- Settings fingerprint: the same text for the same settings (keys sorted).
local function serialize(v, out)
  local t = type(v)
  if t == "table" then
    local keys = {}
    for k in pairs(v) do keys[#keys + 1] = k end
    table.sort(keys, function(a, b)
      local ta, tb = type(a), type(b)
      if ta ~= tb then return ta < tb end
      if ta == "number" or ta == "string" then return a < b end
      return tostring(a) < tostring(b)
    end)
    out[#out + 1] = "{"
    for _, k in ipairs(keys) do
      serialize(k, out)
      out[#out + 1] = "="
      serialize(v[k], out)
      out[#out + 1] = ","
    end
    out[#out + 1] = "}"
  elseif t == "string" then
    out[#out + 1] = string.format("%q", v)
  else
    out[#out + 1] = tostring(v)
  end
end

function Sync.SettingsFingerprint(db)
  local out = {}
  serialize({ s = db and db.settings, m = db and db.minimap }, out)
  return table.concat(out)
end

-- Hooks ---------------------------------------------------------------------------

local applied     -- the synced table merged in this session
local fingerprint -- settings at login

local function apply()
  local data = rawget(_G, "M4CompanionData")
  local s = type(data) == "table" and data.Sync
  if not ns.db or type(s) ~= "table" or applied == s then return end
  applied = s
  Sync.last = Sync.Apply(ns.db, s)
end
Sync.ApplyLoaded = apply

if ns.On then
  ns.On("ADDON_LOADED", function(_, name)
    if name == "m4-companion_Data" then apply() end
  end)
  ns.On("PLAYER_LOGIN", function()
    if ns.db then fingerprint = Sync.SettingsFingerprint(ns.db) end
    local st = Sync.last
    if st and (st.added > 0 or st.recipes > 0 or st.settings) then
      local parts = {}
      if st.added > 0 then parts[#parts + 1] = st.added .. " Handelsbuch-Einträge" end
      if st.recipes > 0 then parts[#parts + 1] = st.recipes .. " Berufs-Scans" end
      if st.settings then parts[#parts + 1] = "Einstellungen" end
      print("|cff33ccffm4:|r Von deinen anderen PCs übernommen: " .. table.concat(parts, ", ") .. ".")
    end
  end)
  ns.On("PLAYER_LOGOUT", function()
    if fingerprint and ns.db and Sync.SettingsFingerprint(ns.db) ~= fingerprint then
      ns.db.settingsT = time()
    end
  end)
end
if ns.OnReady then ns.OnReady(apply) end
