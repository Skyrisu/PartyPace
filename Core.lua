-- PartyPace | Core
-- Liest das eigene Questlog, schickt nur Änderungen an die Gruppe und sammelt den Stand der anderen.
-- Komplett event-getrieben: kein OnUpdate, Event-Spam wird zusammengefasst.
-- Ziel-Client: WoW Forever (läuft auf dem Midnight-Retail-Client).
local ADDON, ns = ...

local PREFIX    = "PartyPace1"  -- Protokollversion steckt im Prefix: alte Versionen sehen sich nicht
local MAXLEN    = 250       -- Addon-Nachrichten sind auf 255 Byte begrenzt
local HEARTH    = 6948      -- Ruhestein
local Q         = C_QuestLog
local issecret  = issecretvalue or function() return false end
local SendAddon = C_ChatInfo.SendAddonMessage
local band      = bit.band
local tremove, concat = table.remove, table.concat
local floor, min, max, format = math.floor, math.min, math.max, string.format
local GetMeta   = (C_AddOns and C_AddOns.GetAddOnMetadata) or GetAddOnMetadata

ns.VERSION = (GetMeta and GetMeta(ADDON, "Version")) or "dev"
if ns.VERSION:find("@", 1, true) then ns.VERSION = "dev" end -- ungepackte Entwicklerversion
ns.TAG = { GROUP = 1, CLASS = 2, PROF = 4, DUNGEON = 8, RAID = 16, CAMP = 32, SHARE = 64 }
ns.PERSONAL = 2 + 4 + 32 -- Klassen-, Berufs-, Camping-Quests: nicht rot markieren, nicht teilen
local TAG = ns.TAG

ns.handlers = {}  -- weitere Nachrichtentypen aus anderen Dateien (Guide, Share, Loot)
ns.players  = {}  -- [GUID] = { name, quests = {[qid] = {flag, obj}}, done = {[qid] = true}, level, xp, xpMax, rested, class, synced, version, check }
ns.qinfo    = {}  -- [qid] = { title, level, tags, zone }
ns.objText  = {}  -- [qid] = { Zieltexte aus dem eigenen Log }
ns.logIndex = {}  -- [qid] = Index im eigenen Questlog
ns.units    = {}  -- [GUID] = "party1" usw.
ns.order    = {}  -- Spaltenreihenfolge, man selbst zuerst

-- "Party" in der eigenen Klassenfarbe – kleines Easter Egg (Fallback: grün)
function ns.Brand()
  local class = select(2, UnitClass("player"))
  local c = class and ((CUSTOM_CLASS_COLORS and CUSTOM_CLASS_COLORS[class]) or (RAID_CLASS_COLORS and RAID_CLASS_COLORS[class]))
  local hex = c and format("%02x%02x%02x", floor(c.r * 255), floor(c.g * 255), floor(c.b * 255)) or "33ff99"
  return "|cff" .. hex .. "Party|rPace"
end

function ns.Print(msg) print(ns.Brand() .. " " .. msg) end

local function Player(name)
  local p = ns.players[name]
  if not p then
    p = { quests = {}, done = {} }
    ns.players[name] = p
  end
  return p
end

-- Fasst Event-Spam zu einem Aufruf zusammen (liest den Stand erst beim Feuern)
local pending = {}
local function Debounce(key, delay, fn)
  if pending[key] then return end
  pending[key] = true
  C_Timer.After(delay, function() pending[key] = nil; fn() end)
end

---------------------------------------------------------------- Senden
local queue, ticker = {}, nil
local announced = false -- erst nach dem ersten Full-Sync werden Deltas gesendet
local THROTTLED = Enum and Enum.SendAddonMessageResult and Enum.SendAddonMessageResult.AddonMessageThrottle

local function Channel()
  local INST = LE_PARTY_CATEGORY_INSTANCE
  if INST and IsInGroup(INST) then return "INSTANCE_CHAT" end
  if IsInRaid() then return "RAID" end
  if IsInGroup() then return "PARTY" end
end

-- Im Kampf und während Encounter-Lockdown wird nichts gesendet, nur gepuffert
local function Blocked()
  if InCombatLockdown() then return true end
  local lock = C_ChatInfo.InChatMessagingLockdown
  return lock and lock() or false
end

local StartPump
local function Pump()
  if #queue == 0 or Blocked() then
    if ticker then ticker:Cancel(); ticker = nil end
    if #queue > 0 and not InCombatLockdown() then C_Timer.After(5, StartPump) end
    return
  end
  local ch = Channel()
  if not ch then wipe(queue); return end
  local msg = tremove(queue, 1)
  local res = SendAddon(PREFIX, msg, ch)
  if THROTTLED and res == THROTTLED then table.insert(queue, 1, msg) end
end

StartPump = function()
  if not ticker and #queue > 0 then ticker = C_Timer.NewTicker(0.3, Pump) end
end

local function Enqueue(msg)
  queue[#queue + 1] = msg
  StartPump()
end

-- Packt viele kleine Einträge in möglichst wenige Nachrichten
local function SendPacked(kind, entries)
  local head = kind .. ":"
  local buf = head
  for i = 1, #entries do
    local e = entries[i]
    if #buf > #head and #buf + #e + 1 > MAXLEN then
      Enqueue(buf)
      buf = head
    end
    buf = (#buf > #head) and (buf .. ";" .. e) or (buf .. e)
  end
  if #buf > #head then Enqueue(buf) end
end

---------------------------------------------------------------- Klassen-/Berufsquests erkennen
-- Im Questlog stehen die unter einer Überschrift mit Klassen- bzw. Berufsnamen.
local CLASS_HEADERS, PROF_HEADERS = {}, {}
local PROF_NAMES = {
  "Alchemie", "Schmiedekunst", "Verzauberkunst", "Ingenieurskunst", "Kräuterkunde", "Lederverarbeitung",
  "Bergbau", "Kürschnerei", "Schneiderei", "Kochkunst", "Erste Hilfe", "Angeln",
  "Alchemy", "Blacksmithing", "Enchanting", "Engineering", "Herbalism", "Leatherworking",
  "Mining", "Skinning", "Tailoring", "Cooking", "First Aid", "Fishing",
}

local function BuildHeaderSets()
  for _, t in ipairs({ LOCALIZED_CLASS_NAMES_MALE, LOCALIZED_CLASS_NAMES_FEMALE }) do
    if t then for _, n in pairs(t) do CLASS_HEADERS[n] = true end end
  end
  for _, n in ipairs(PROF_NAMES) do PROF_HEADERS[n] = true end
  PROF_HEADERS[TRADE_SKILLS or "Professions"] = true
  PROF_HEADERS["Professions"], PROF_HEADERS["Profession"] = true, true
  -- eigene Berufe in Client-Sprache
  if GetProfessions and GetProfessionInfo then
    for _, idx in pairs({ GetProfessions() }) do
      local ok, n = pcall(GetProfessionInfo, idx)
      if ok and type(n) == "string" and n ~= "" then PROF_HEADERS[n] = true end
    end
  end
  local disp = C_TradeSkillUI and C_TradeSkillUI.GetTradeSkillDisplayName
  if disp then
    for _, id in ipairs({ 164, 165, 171, 182, 186, 197, 202, 333, 393, 129, 185, 356 }) do
      local ok, n = pcall(disp, id)
      if ok and type(n) == "string" and n ~= "" then PROF_HEADERS[n] = true end
    end
  end
end

local CAMP_HEADERS = { camp = true, camps = true, camping = true, campfire = true, campsite = true }

local function QuestTags(qid, info, zone)
  local group = (info.suggestedGroup or 0) > 1
  local dungeon, raid = false, false
  local prof = PROF_HEADERS[zone] or false
  local camp = CAMP_HEADERS[(zone or ""):lower()] or false
  local title = (info.title or ""):lower()
  if title:find("^camping") then camp = true end
  -- "Camping 101: Alchemy" usw. zählt auch als Berufsquest
  if camp and not prof then
    for n in pairs(PROF_HEADERS) do
      if #n > 3 and title:find(n:lower(), 1, true) then prof = true; break end
    end
  end
  local ti = Q.GetQuestTagInfo and Q.GetQuestTagInfo(qid)
  if ti then
    local id = ti.tagID
    if id == 81 or id == 85 then dungeon = true
    elseif id == 62 or id == 88 or id == 89 then raid = true
    elseif id == 1 or ti.isElite then group = true end
    -- Berufsquests tragen eine Berufs-ID im Tag, unabhängig von der Überschrift im Log
    if ti.tradeskillLineID and ti.tradeskillLineID > 0 then prof = true end
    local tn = type(ti.tagName) == "string" and ti.tagName:lower() or ""
    if tn:find("profession") or PROF_HEADERS[ti.tagName or ""] then prof = true end
    if tn:find("camp") then camp = true end
  end
  return (group and TAG.GROUP or 0) + (CLASS_HEADERS[zone] and TAG.CLASS or 0)
       + (prof and TAG.PROF or 0) + (dungeon and TAG.DUNGEON or 0) + (raid and TAG.RAID or 0)
       + (camp and TAG.CAMP or 0)
end

-- Vom Spieler per Alt-Klick ausgeblendet (einzelne Quest oder ganze Kategorie)?
function ns.IsUserHidden(qid)
  local db = ns.DB
  if db.hiddenQuests[qid] then return true end
  local qi = ns.qinfo[qid]
  return qi and qi.zone and db.hiddenHeaders[qi.zone] or false
end

-- Debug: wie sortiert der Client die eigenen Quests ein?
function ns.DumpQuests()
  local zone = ""
  for i = 1, Q.GetNumQuestLogEntries() do
    local info = Q.GetInfo(i)
    if info and info.isHeader then
      zone = info.title or ""
    elseif info and info.questID and info.questID > 0 and not info.isHidden then
      local ti = Q.GetQuestTagInfo and Q.GetQuestTagInfo(info.questID)
      local cls = C_QuestInfoSystem and C_QuestInfoSystem.GetQuestClassification
                  and C_QuestInfoSystem.GetQuestClassification(info.questID)
      ns.Print(format("%d %s |cff999999[%s]|r tag=%s/%s skill=%s freq=%s class=%s",
        info.questID, info.title or "?", zone, tostring(ti and ti.tagID), tostring(ti and ti.tagName),
        tostring(ti and ti.tradeskillLineID), tostring(info.frequency), tostring(cls)))
    end
  end
end

---------------------------------------------------------------- Questlog lesen
local function StripCount(text)
  if not text then return "" end
  text = text:gsub("^%s*%d+%s*/%s*%d+%s*", ""):gsub("%s*:?%s*%d+%s*/%s*%d+%s*$", "")
  return text
end

local function ParseObjs(s)
  local t = {}
  for n, r in s:gmatch("(%d+)/(%d+)") do
    t[#t + 1] = tonumber(n)
    t[#t + 1] = tonumber(r)
  end
  return t
end

local function ReadObjectives(qid, texts)
  local parts = {}
  local objs = Q.GetQuestObjectives(qid)
  if objs then
    for i = 1, #objs do
      local o = objs[i]
      local n, r = o.numFulfilled or 0, o.numRequired or 0
      if r <= 0 then r, n = 1, (o.finished and 1 or 0) end
      if n > r then n = r end
      parts[i] = n .. "/" .. r
      texts[i] = StripCount(o.text)
    end
  end
  return concat(parts, ",")
end

-- flag: 0 = läuft, 1 = abgabebereit, 2 = fehlgeschlagen
local function ScanLog()
  local res, zone = {}, ""
  wipe(ns.logIndex)
  for i = 1, Q.GetNumQuestLogEntries() do
    local info = Q.GetInfo(i)
    if info then
      if info.isHeader then
        zone = info.title or ""
      elseif not info.isHidden and not info.isTask and not info.isBounty and info.questID and info.questID > 0 then
        local qid, texts = info.questID, {}
        local flag = 0
        if Q.IsFailed and Q.IsFailed(qid) then flag = 2
        elseif Q.IsComplete(qid) then flag = 1 end
        res[qid] = {
          flag = flag, objs = ReadObjectives(qid, texts), title = info.title or "",
          level = info.level or 0, zone = zone,
          tags = QuestTags(qid, info, zone) + ((Q.IsPushableQuest and Q.IsPushableQuest(qid)) and TAG.SHARE or 0),
        }
        ns.objText[qid], ns.logIndex[qid] = texts, i
      end
    end
  end
  return res
end

local function SafeText(t, len)
  t = (t or ""):gsub("[;~]", "")
  if #t > len then -- UTF-8-sicher kürzen
    local cut = len
    while cut > 0 do
      local b = t:byte(cut + 1)
      if not b or b < 0x80 or b >= 0xC0 then break end
      cut = cut - 1
    end
    t = t:sub(1, cut)
  end
  return t
end

local function SelfLevel()
  local me = Player(ns.me)
  me.level, me.xp, me.xpMax = UnitLevel("player"), UnitXP("player"), UnitXPMax("player")
  me.rested = floor(GetXPExhaustion() or 0)
  me.class, me.synced, me.version, me.name = select(2, UnitClass("player")), true, ns.VERSION, ns.myName
  return concat({ me.level, floor(me.xp), floor(me.xpMax), me.rested }, ",")
end

local function ParseLevel(p, s)
  local l, x, m, r = s:match("^(%d+),(%d+),(%d+),(%d+)")
  if l then p.level, p.xp, p.xpMax, p.rested = tonumber(l), tonumber(x), tonumber(m), tonumber(r) end
end

---------------------------------------------------------------- Versionscheck
local function VerNum(v)
  local a, b, c = (v or ""):match("(%d+)%.(%d+)%.?(%d*)")
  return (tonumber(a) or 0) * 10000 + (tonumber(b) or 0) * 100 + (tonumber(c) or 0)
end

local warned = {}
local function CheckVersion(key, v)
  if not v or v == "" then return end
  Player(key).version = v
  if warned[key] then return end
  local name = ns.DisplayName(key)
  local mine, theirs = VerNum(ns.VERSION), VerNum(v)
  if mine == 0 or theirs == 0 then return end -- Entwicklerversion: kein Vergleich
  if theirs > mine then
    warned[key] = true
    ns.Print(format("%s uses a newer version (%s). You have %s – please update.", name, v, ns.VERSION))
  elseif theirs < mine then
    warned[key] = true
    ns.Print(format("%s uses an older version (%s). Some features may not work for them.", name, v))
  end
end

---------------------------------------------------------------- Abgegebene Quests
local pendingDone = {}
local function QueueDone(qid)
  local me = Player(ns.me)
  if me.done[qid] then return end
  me.done[qid] = true
  pendingDone[#pendingDone + 1] = tostring(qid)
  Debounce("done", 1, function()
    if IsInGroup() and announced and #pendingDone > 0 then SendPacked("T", pendingDone) end
    pendingDone = {}
    ns.MarkDirty()
  end)
end

---------------------------------------------------------------- Ready?-Check
local function BagFree()
  local getFree = (C_Container and C_Container.GetContainerNumFreeSlots) or GetContainerNumFreeSlots
  local free = 0
  for bag = 0, (NUM_BAG_SLOTS or 4) do
    local n, bagType = getFree(bag)
    if n and (bagType == nil or bagType == 0) then free = free + n end -- nur normale Taschen
  end
  return free
end

local function Durability()
  local low = 100
  for slot = 1, 18 do
    local cur, mx = GetInventoryItemDurability(slot)
    if cur and mx and mx > 0 then low = min(low, floor(cur / mx * 100)) end
  end
  return low
end

local function HearthCD()
  local count = ((C_Item and C_Item.GetItemCount) or GetItemCount)(HEARTH)
  if not count or count == 0 then return -1 end
  local start, dur = ((C_Container and C_Container.GetItemCooldown) or GetItemCooldown)(HEARTH)
  if start and start > 0 and dur and dur > 1.5 then return max(0, floor(start + dur - GetTime())) end
  return 0
end

local function StoreCheck(p, s)
  local free, dur, hs = s:match("^(%d+),(%d+),(%-?%d+)")
  if free then
    p.check = { free = tonumber(free), dur = tonumber(dur), hs = tonumber(hs), at = GetTime() }
  end
end

local function SelfCheck()
  local s = concat({ BagFree(), Durability(), HearthCD() }, ",")
  StoreCheck(Player(ns.me), s)
  return s
end

local function ResetChecks()
  for _, p in pairs(ns.players) do p.check = nil end
end

---------------------------------------------------------------- Ruhestein-Sync
-- Gesendet wird nur, wenn sich wirklich was ändert (Ruhestein benutzt, neu gebunden).
local lastHS = ""
local function HearthPayload()
  local rem = HearthCD()
  local bind = SafeText(GetBindLocation and GetBindLocation() or "", 30)
  local me = Player(ns.me)
  me.hsEnd = rem < 0 and -1 or (GetTime() + rem)
  me.bind = bind
  return rem .. "~" .. bind, (rem < 0 and "x" or floor((GetTime() + rem) / 15)) .. bind
end

function ns.SyncHearth(force)
  if not ns.me then return end
  local payload, key = HearthPayload()
  if force or key ~= lastHS then
    lastHS = key
    if IsInGroup() and announced then Enqueue("S:" .. payload) end
    ns.MarkDirty()
  end
end

local function StoreHearth(p, s)
  local rem, bind = s:match("^(%-?%d+)~(.*)$")
  rem = tonumber(rem)
  if rem then
    p.hsEnd = rem < 0 and -1 or (GetTime() + rem)
    p.bind = bind
  end
end

function ns.RequestCheck()
  ResetChecks()
  local s = SelfCheck()
  if IsInGroup() and announced then Enqueue("C:" .. s) end
  ns.ShowCheck(false)
end

---------------------------------------------------------------- Eigenen Stand verteilen
local last, sentInfo = {}, {}

function ns.ScanAndSend(full)
  if not ns.me then return end
  local cur = ScanLog()
  local me = Player(ns.me)
  local lvl = SelfLevel()
  local ups, dels = {}, {}

  for qid, q in pairs(cur) do
    ns.qinfo[qid] = { title = q.title, level = q.level, tags = q.tags, zone = q.zone }
    me.done[qid] = nil
    local key = q.flag .. "~" .. q.objs
    if full or last[qid] ~= key then
      local e = qid .. "~" .. q.flag .. "~" .. q.objs
      if full or not sentInfo[qid] then
        e = e .. "~" .. q.level .. "~" .. q.tags .. "~" .. SafeText(q.zone, 30) .. "~" .. SafeText(q.title, 40)
      end
      ups[#ups + 1] = e
      sentInfo[qid], last[qid] = true, key
      me.quests[qid] = { flag = q.flag, obj = ParseObjs(q.objs) }
    end
  end
  for qid in pairs(last) do
    if not cur[qid] then
      dels[#dels + 1] = tostring(qid)
      last[qid], sentInfo[qid], me.quests[qid], ns.objText[qid] = nil, nil, nil, nil
    end
  end

  if IsInGroup() and ns.Active() and (full or announced) then
    if full then
      Enqueue("F:" .. lvl .. "," .. ns.VERSION .. "," .. ns.me)
      announced = true
    end
    if #ups > 0 then SendPacked("U", ups) end
    if #dels > 0 and not full then SendPacked("D", dels) end
    if full then
      local d = {}
      for qid in pairs(me.done) do d[#d + 1] = tostring(qid) end
      if #d > 0 then SendPacked("T", d) end
      pendingDone = {} -- schon im Full-Sync enthalten
      Enqueue("S:" .. (HearthPayload()))
      if ns.GuideAnnounce then ns.GuideAnnounce(true) end
    end
  end
  ns.MarkDirty()
end

function ns.ScheduleFull() Debounce("full", 1.5, function() ns.ScanAndSend(true) end) end
function ns.SendHello() Debounce("hello", 1, function() if IsInGroup() then Enqueue("H:" .. ns.VERSION .. "," .. ns.me) end end) end

function ns.ShareQuest(qid, quiet)
  if not ns.logIndex[qid] or not IsInGroup() then return false end
  if Q.IsPushableQuest and not Q.IsPushableQuest(qid) then
    if not quiet then ns.Print("This quest can't be shared.") end
    return false
  end
  Q.SetSelectedQuest(qid)
  if QuestLogPushQuest then QuestLogPushQuest() end
  return true
end

-- Im Raid nur aktiv, wenn "eigene Gruppe zeigen" gewählt ist
function ns.Active()
  return not IsInRaid() or ns.DB.raidMode == "group"
end

-- Für andere Dateien: senden, sobald man in der Gruppe angekündigt ist
function ns.Send(msg) if IsInGroup() and announced and ns.Active() then Enqueue(msg) end end
ns.Player = Player

-- Wo bekommt man die Quest? Kommt aus Questies Datenbank, falls installiert (nur lesend, gecacht)
local startCache = {}
function ns.QuestStart(qid)
  local c = startCache[qid]
  if c ~= nil then return c or nil end
  local res = false
  local QL = _G.QuestieLoader
  if QL and QL.ImportModule then
    local ok, r = pcall(function()
      local DB = QL:ImportModule("QuestieDB")
      local q = DB and DB.GetQuest and DB.GetQuest(qid)
      local s = q and q.Starts
      if not s then return end
      if s.NPC and s.NPC[1] then
        local npc = DB:GetNPC(s.NPC[1])
        if npc and npc.name then
          local zone = npc.zoneID and C_Map and C_Map.GetAreaInfo and C_Map.GetAreaInfo(npc.zoneID)
          return npc.name .. ((zone and zone ~= "") and (" (" .. zone .. ")") or "")
        end
      elseif s.GameObject and s.GameObject[1] and DB.GetObject then
        local o = DB:GetObject(s.GameObject[1])
        if o and o.name then return o.name end
      elseif s.Item and s.Item[1] then
        local n = ((C_Item and C_Item.GetItemInfo) or GetItemInfo)(s.Item[1])
        return (n or "an item") .. " (item)"
      end
    end)
    if ok and r then res = r end
  end
  startCache[qid] = res
  return res or nil
end

-- Ein Mitspieler hat eine neue Quest, die ich nicht habe: kurz warten (Auto-Share), dann Bescheid sagen
local function MaybeHint(guid, qid)
  if not ns.DB.questHints or not ns.Active() then return end
  C_Timer.After(5, function()
    local p = ns.players[guid]
    if not p or not p.quests[qid] or ns.logIndex[qid] or Q.IsQuestFlaggedCompleted(qid) then return end
    local qi = ns.qinfo[qid] or {}
    local tags = qi.tags or 0
    if band(tags, ns.PERSONAL) > 0 or ns.IsUserHidden(qid) then return end
    local how
    if band(tags, TAG.SHARE) > 0 then
      how = "shift-click it to ask for a share"
    else
      local s = ns.QuestStart(qid)
      how = s and ("get it from " .. s) or "not shareable"
    end
    ns.Toast("q" .. qid, format("%s has |cffffd100%s|r – %s", ns.ColorName(guid), qi.title or ("#" .. qid), how))
  end)
end

-- Fehlt die Quest jemandem (der sie auch nicht schon abgegeben hat)? Klassen-/Berufsquests nie.
local function NeedsShare(qid)
  if not ns.logIndex[qid] then return false end
  local qi = ns.qinfo[qid]
  if qi and band(qi.tags or 0, ns.PERSONAL) > 0 then return false end
  if ns.IsUserHidden(qid) then return false end
  if Q.IsPushableQuest and not Q.IsPushableQuest(qid) then return false end
  for _, name in ipairs(ns.order) do
    local p = ns.players[name]
    if name ~= ns.me and p and not p.quests[qid] and not p.done[qid] then return true end
  end
  return false
end

-- Alles teilen, was den anderen fehlt (nacheinander, damit die Share-Dialoge nicht kollidieren)
function ns.ShareMissing()
  if not IsInGroup() then ns.Print("You're not in a group."); return end
  local todo = {}
  for qid in pairs(ns.logIndex) do if NeedsShare(qid) then todo[#todo + 1] = qid end end
  if #todo == 0 then ns.Print("Nothing to share – everyone has your quests."); return end
  ns.Print(format("Sharing %d quest%s…", #todo, #todo == 1 and "" or "s"))
  for i, qid in ipairs(todo) do
    C_Timer.After((i - 1) * 1.5, function() ns.ShareQuest(qid, true) end)
  end
end

-- Auto-Share: kurz warten, damit der Sync der anderen ankommt (falls sie die Quest gleichzeitig annehmen)
local function AutoShare(qid)
  if not ns.DB.autoShare or not IsInGroup() or not ns.Active() then return end
  C_Timer.After(2.5, function()
    if NeedsShare(qid) then ns.ShareQuest(qid, true) end
  end)
end

---------------------------------------------------------------- Identität
-- Forever-Namen sind "Vorname Nachname" und kommen je nach Quelle unterschiedlich formatiert an.
-- Deshalb wird jeder Spieler über seine GUID erkannt; der Name ist nur noch zur Anzeige da.
local senderMap = {}  -- [Absendername aus CHAT_MSG_ADDON] = GUID (gelernt aus H/F)
local lastAsk = 0

local function AskSync()
  if GetTime() - lastAsk > 10 then
    lastAsk = GetTime()
    ns.SendHello()
  end
end

function ns.DisplayName(key)
  local p = ns.players[key]
  local n = (p and p.name) or "?"
  n = n:gsub("%-.*$", "")
  return n:match("^(%S+)") or n -- nur Vorname, spart Platz
end

---------------------------------------------------------------- Gruppe
function ns.RebuildOrder()
  wipe(ns.order)
  if not ns.me then return end
  local others = {}
  for name, p in pairs(ns.players) do
    local unit = ns.units[name]
    if unit and not p.class then p.class = select(2, UnitClass(unit)) end
    if name ~= ns.me and p.synced and unit then others[#others + 1] = name end
  end
  table.sort(others, function(x, y) return ns.DisplayName(x) < ns.DisplayName(y) end)
  ns.order[1] = ns.me
  for i = 1, min(#others, 4) do ns.order[i + 1] = others[i] end
end

local rosterPending, lastPresent, lastActive = false, {}, true
function ns.UpdateRoster()
  if not ns.me then return end
  if InCombatLockdown() then rosterPending = true; return end
  rosterPending = false
  wipe(ns.units)
  ns.units[ns.me] = "player"
  Player(ns.me).name = ns.myName
  local present = { [ns.me] = true }
  local raid = IsInRaid()
  local mySub
  if raid then
    for i = 1, (GetNumGroupMembers() or 0) do
      if UnitIsUnit("raid" .. i, "player") then mySub = select(3, GetRaidRosterInfo(i)) end
    end
  end
  for i = 1, (GetNumGroupMembers() or 0) do
    local unit = (raid and "raid" or "party") .. i
    local sameGroup = not raid or (mySub and select(3, GetRaidRosterInfo(i)) == mySub)
    if sameGroup and UnitExists(unit) and not UnitIsUnit(unit, "player") then
      local guid = UnitGUID(unit)
      if guid and not issecret(guid) then
        ns.units[guid], present[guid] = unit, true
        local p = ns.players[guid]
        if p then
          p.class = select(2, UnitClass(unit))
          local n = UnitName(unit)
          if n and not issecret(n) and n ~= UNKNOWNOBJECT then p.name = n end
        end
      end
    end
  end

  local joined = false
  for key in pairs(present) do if not lastPresent[key] then joined = true end end
  for key in pairs(ns.players) do if not present[key] then ns.players[key] = nil end end
  for s, g in pairs(senderMap) do if not present[g] then senderMap[s] = nil end end
  lastPresent = present
  if not IsInGroup() then announced = false end

  -- Raid-Modus gerade aktiv geworden zählt wie ein neuer Beitritt
  local active = ns.Active()
  if active and not lastActive then joined, announced = true, false end
  lastActive = active
  if joined and IsInGroup() and active then ns.SendHello(); ns.ScheduleFull() end
  ns.RebuildOrder()
  ns.UpdateVisibility()
  ns.MarkDirty()
end

---------------------------------------------------------------- Empfang
local function Fields(e)
  local f = {}
  for x in (e .. "~"):gmatch("([^~]*)~") do f[#f + 1] = x end
  return f
end

local function OnAddon(prefix, msg, _, sender)
  if issecret(prefix) or issecret(msg) or issecret(sender) then return end
  if prefix ~= PREFIX or not sender then return end
  local kind, payload = msg:match("^(%u):(.*)$")
  if not kind then return end

  -- H und F tragen die GUID mit; alle anderen Nachrichten werden über den gelernten Absender zugeordnet
  local f, guid
  if kind == "H" or kind == "F" then
    f = {}
    for x in payload:gmatch("[^,]+") do f[#f + 1] = x end
    guid = f[#f]
    if not guid or not guid:match("^Player%-") then return end
    senderMap[sender] = guid
  else
    guid = senderMap[sender]
    if not guid then AskSync(); return end -- unbekannt: neu synchronisieren lassen
  end
  if guid == ns.me then return end -- eigenes Echo

  local p = Player(guid)
  if not p.name then
    local unit = ns.units[guid]
    local n = unit and UnitName(unit)
    p.name = (n and not issecret(n) and n ~= UNKNOWNOBJECT and n) or sender
  end
  local newPeer = not p.synced
  p.synced = true

  if kind == "H" then
    CheckVersion(guid, f[1])
    ns.ScheduleFull()

  elseif kind == "F" then
    wipe(p.quests)
    p.syncUntil = GetTime() + 5 -- Quests aus dem Full-Sync sind nicht "neu"
    ParseLevel(p, payload)
    CheckVersion(guid, f[5])

  elseif kind == "L" then
    ParseLevel(p, payload)

  elseif kind == "U" then
    for e in payload:gmatch("[^;]+") do
      local f = Fields(e)
      local id = tonumber(f[1])
      if id and f[2] then
        local isNew = not p.quests[id] and GetTime() > (p.syncUntil or 0)
        p.quests[id] = { flag = tonumber(f[2]) or 0, obj = ParseObjs(f[3] or "") }
        p.done[id] = nil
        if #f >= 7 and not ns.logIndex[id] then
          ns.qinfo[id] = { level = tonumber(f[4]) or 0, tags = tonumber(f[5]) or 0, zone = f[6], title = f[7] }
        end
        -- Hab ich die schon abgegeben? Dann Bescheid sagen, statt als "fehlt" angezeigt zu werden
        if not ns.logIndex[id] and Q.IsQuestFlaggedCompleted(id) then QueueDone(id)
        elseif isNew and not ns.logIndex[id] then MaybeHint(guid, id) end
      end
    end

  elseif kind == "D" then
    for s in payload:gmatch("%d+") do p.quests[tonumber(s)] = nil end

  elseif kind == "T" then
    for s in payload:gmatch("%d+") do
      local id = tonumber(s)
      p.done[id], p.quests[id] = true, nil
    end

  elseif kind == "C" then
    if not ns.Active() then return end
    ResetChecks()
    StoreCheck(p, payload)
    ns.Send("R:" .. SelfCheck())
    ns.ShowCheck(true)

  elseif kind == "R" then
    StoreCheck(p, payload)
    ns.UpdateCheck()

  elseif kind == "S" then
    StoreHearth(p, payload)

  elseif ns.handlers[kind] then
    ns.handlers[kind](p, payload, guid)
  end

  if newPeer then ns.RebuildOrder() end
  ns.MarkDirty()
end

---------------------------------------------------------------- Events
local ev = CreateFrame("Frame")
ev:RegisterEvent("ADDON_LOADED")
ev:RegisterEvent("PLAYER_LOGIN")
ev:SetScript("OnEvent", function(self, e, ...)
  if e == "ADDON_LOADED" then
    if ... ~= ADDON then return end
    PartyPaceDB = PartyPaceDB or {}
    local db = PartyPaceDB
    if db.show == nil then db.show = true end
    if db.autoShare == nil then db.autoShare = true end
    db.scale = db.scale or 1
    db.guideAhead = db.guideAhead or 3
    if db.guideParty == nil then db.guideParty = true end
    if db.hideCamp == nil then db.hideCamp = true end
    if db.questHints == nil then db.questHints = true end
    if db.lootHints == nil then db.lootHints = true end
    db.hiddenQuests = db.hiddenQuests or {}
    db.hiddenHeaders = db.hiddenHeaders or {}
    db.raidMode = db.raidMode or "hide"
    db.dbVersion = 1 -- für spätere Migrationen
    ns.DB = db
    self:UnregisterEvent("ADDON_LOADED")

  elseif e == "PLAYER_LOGIN" then
    ns.me, ns.myName = UnitGUID("player"), UnitName("player")
    BuildHeaderSets()
    C_ChatInfo.RegisterAddonMessagePrefix(PREFIX)
    for _, x in ipairs({ "QUEST_LOG_UPDATE", "QUEST_TURNED_IN", "QUEST_ACCEPTED", "GROUP_ROSTER_UPDATE", "CHAT_MSG_ADDON",
                         "PLAYER_XP_UPDATE", "PLAYER_LEVEL_UP", "UPDATE_EXHAUSTION", "UNIT_CONNECTION",
                         "PLAYER_REGEN_ENABLED", "PLAYER_ENTERING_WORLD", "BAG_UPDATE_COOLDOWN", "HEARTHSTONE_BOUND" }) do
      self:RegisterEvent(x)
    end
    ns.InitUI()
    ns.GuideInit()
    ns.ScanAndSend(false)
    ns.UpdateRoster()

  elseif e == "QUEST_LOG_UPDATE" then
    Debounce("scan", 0.5, function() ns.ScanAndSend(false) end)

  elseif e == "QUEST_ACCEPTED" then
    local a, b = ...
    local qid = b or a -- ältere Clients: (logIndex, questID), neuere: (questID)
    if qid then AutoShare(qid) end

  elseif e == "QUEST_TURNED_IN" then
    local qid = ...
    if qid then QueueDone(qid) end

  elseif e == "GROUP_ROSTER_UPDATE" or e == "PLAYER_ENTERING_WORLD" then
    Debounce("roster", 0.5, ns.UpdateRoster)

  elseif e == "CHAT_MSG_ADDON" then
    OnAddon(...)

  elseif e == "UNIT_CONNECTION" then
    ns.MarkDirty()

  elseif e == "BAG_UPDATE_COOLDOWN" or e == "HEARTHSTONE_BOUND" then
    Debounce("hs", 2, function() ns.SyncHearth(false) end)

  elseif e == "PLAYER_XP_UPDATE" or e == "PLAYER_LEVEL_UP" or e == "UPDATE_EXHAUSTION" then
    Debounce("xp", 5, function()
      local s = SelfLevel()
      if IsInGroup() and announced then Enqueue("L:" .. s) end
      ns.MarkDirty()
    end)

  elseif e == "PLAYER_REGEN_ENABLED" then
    if rosterPending then ns.UpdateRoster() end
    StartPump()
  end
end)
