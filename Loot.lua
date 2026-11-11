-- PartyPace | Wer braucht das?
-- Wer selbst etwas lootet, schickt den Item-String an die Gruppe. Jeder vergleicht ihn mit seinem
-- EIGENEN Equip und meldet nur zurück, wenn es ein Upgrade ist. Equip wird nie übertragen.
-- Läuft nur bei eigenem Loot (CHAT_MSG_LOOT) – sonst passiert hier nichts.
local ADDON, ns = ...

local floor, max, format, concat, sort = math.floor, math.max, string.format, table.concat, table.sort
local GetItemInfo        = (C_Item and C_Item.GetItemInfo) or GetItemInfo
local GetItemStats       = (C_Item and C_Item.GetItemStats) or GetItemStats
local GetItemInfoInstant = (C_Item and C_Item.GetItemInfoInstant) or GetItemInfoInstant
local issecret           = issecretvalue or function() return false end

---------------------------------------------------------------- Bewertung
local K = { "ITEM_MOD_STRENGTH_SHORT", "ITEM_MOD_AGILITY_SHORT", "ITEM_MOD_INTELLECT_SHORT", "ITEM_MOD_SPIRIT_SHORT",
            "ITEM_MOD_STAMINA_SHORT", "RESISTANCE0_NAME", "ITEM_MOD_DAMAGE_PER_SECOND_SHORT",
            "ITEM_MOD_ATTACK_POWER_SHORT", "ITEM_MOD_SPELL_POWER_SHORT" }
local SHORT = { "Str", "Agi", "Int", "Spi", "Sta", "Armor", "DPS", "AP", "SP" }
local DPS = 7

-- Einfache Leveling-Gewichte (Reihenfolge wie K). Bewusst grob: soll "klar besser" erkennen, kein Sim.
local WEIGHTS = {
  WARRIOR = { 1, .6, 0, 0, .5, .02, 3, .5, 0 },
  PALADIN = { 1, .4, .3, .1, .5, .02, 3, .5, .2 },
  HUNTER  = { .1, 1, .2, .1, .5, .02, .5, .4, 0 },
  ROGUE   = { .4, 1, 0, 0, .5, .02, 3, .5, 0 },
  PRIEST  = { 0, 0, 1, .8, .5, .01, 0, 0, 1 },
  SHAMAN  = { .7, .4, .6, .2, .5, .02, 2.5, .4, .5 },
  MAGE    = { 0, 0, 1, .6, .5, .01, 0, 0, 1 },
  WARLOCK = { 0, 0, .8, .5, .7, .01, 0, 0, 1 },
  DRUID   = { .5, .5, .7, .4, .5, .02, 1, .3, .5 },
}
local DEFAULT_W = { .5, .5, .5, .3, .5, .02, 1, .3, .3 }
local RANGED_DPS = { HUNTER = 3 }                          -- Fernkampfslot: für Jäger zählt die DPS voll
local WAND_DPS   = { MAGE = 2, PRIEST = 2, WARLOCK = 2 }   -- Zauberstäbe beim Leveln wichtig

local function Set(...) local t = {}; for _, v in ipairs({ ... }) do t[v] = true end; return t end
-- Waffen-Unterklassen: 0/1 Axt, 2 Bogen, 3 Gewehr, 4/5 Streitkolben, 6 Stangenwaffe, 7/8 Schwert,
-- 10 Stab, 13 Faust, 15 Dolch, 16 Wurfwaffe, 18 Armbrust, 19 Zauberstab
local WEAPONS = {
  WARRIOR = Set(0, 1, 2, 3, 4, 5, 6, 7, 8, 10, 13, 15, 16, 18),
  PALADIN = Set(0, 1, 4, 5, 6, 7, 8),
  HUNTER  = Set(0, 1, 2, 3, 6, 7, 8, 10, 13, 15, 16, 18),
  ROGUE   = Set(2, 3, 4, 7, 13, 15, 16, 18),
  PRIEST  = Set(4, 10, 15, 19),
  SHAMAN  = Set(0, 1, 4, 5, 10, 13, 15),
  MAGE    = Set(7, 10, 15, 19),
  WARLOCK = Set(7, 10, 15, 19),
  DRUID   = Set(4, 5, 10, 13, 15),
}
local SHIELD = Set("WARRIOR", "PALADIN", "SHAMAN")

local function MaxArmor(class, level)
  if class == "WARRIOR" or class == "PALADIN" then return level >= 40 and 4 or 3 end
  if class == "HUNTER" or class == "SHAMAN" then return level >= 40 and 3 or 2 end
  if class == "ROGUE" or class == "DRUID" then return 2 end
  if class == "PRIEST" or class == "MAGE" or class == "WARLOCK" then return 1 end
  return 4
end

-- Schmuckstücke fehlen absichtlich (Benutzen-Effekte lassen sich nicht sinnvoll bewerten)
local SLOTS = {
  INVTYPE_HEAD = { 1 }, INVTYPE_NECK = { 2 }, INVTYPE_SHOULDER = { 3 }, INVTYPE_CHEST = { 5 }, INVTYPE_ROBE = { 5 },
  INVTYPE_WAIST = { 6 }, INVTYPE_LEGS = { 7 }, INVTYPE_FEET = { 8 }, INVTYPE_WRIST = { 9 }, INVTYPE_HAND = { 10 },
  INVTYPE_FINGER = { 11, 12 }, INVTYPE_CLOAK = { 15 },
  INVTYPE_WEAPON = { 16, 17 }, INVTYPE_WEAPONMAINHAND = { 16 }, INVTYPE_2HWEAPON = { 16 },
  INVTYPE_WEAPONOFFHAND = { 17 }, INVTYPE_SHIELD = { 17 }, INVTYPE_HOLDABLE = { 17 },
  INVTYPE_RANGED = { 18 }, INVTYPE_RANGEDRIGHT = { 18 }, INVTYPE_THROWN = { 18 },
}

local function Stats(link)
  if not link then return nil end
  local ok, s = pcall(GetItemStats, link)
  return ok and s or nil
end

local function Score(stats, w, dpsW)
  if not stats then return 0 end
  local sc = 0
  for i, k in ipairs(K) do
    local v = stats[k]
    if v then sc = sc + v * (i == DPS and dpsW or w[i]) end
  end
  return sc
end

local function EquippedLoc(slot)
  local link = GetInventoryItemLink("player", slot)
  return link and select(4, GetItemInfoInstant(link)), link
end

-- Nebenhand-Slot zählt für eine Einhandwaffe nur, wenn dort eine Waffe liegt oder er leer ist
local OH_WEAPON = { INVTYPE_WEAPON = true, INVTYPE_WEAPONOFFHAND = true }
local function OffhandIsWeaponOrEmpty()
  local loc, link = EquippedLoc(17)
  return not link or OH_WEAPON[loc] or false
end

local function CanDual()
  if CanDualWield then
    local ok, r = pcall(CanDualWield)
    if ok then return r end
  end
  return false
end

-- Liefert z. B. "+12 Agi, +5 Sta" wenn das Item für MICH ein klares Upgrade ist, sonst nil
local function Evaluate(link)
  local _, _, quality, _, minLevel, _, _, _, equipLoc, _, _, classID, subID = GetItemInfo(link)
  if not quality or quality < 1 then return end
  local slots = SLOTS[equipLoc]
  if not slots then return end
  local class, level = select(2, UnitClass("player")), UnitLevel("player")
  minLevel = minLevel or 0
  if minLevel > level + 3 then return end

  if classID == 4 then
    if subID == 6 then
      if not SHIELD[class] then return end
    elseif subID >= 1 and subID <= 4 and equipLoc ~= "INVTYPE_CLOAK" then
      if subID > MaxArmor(class, level) then return end
    elseif subID > 6 then
      return -- Buchbände, Götzen, Totems
    end
  elseif classID == 2 then
    local ok = WEAPONS[class]
    if ok and not ok[subID] then return end
  else
    return
  end

  local w = WEIGHTS[class] or DEFAULT_W
  local dpsW = w[DPS]
  if slots[1] == 18 then dpsW = (subID == 19 and WAND_DPS[class]) or RANGED_DPS[class] or .3 end

  local new = Stats(link) or {}
  local newScore = Score(new, w, dpsW)
  local mhLoc, mhLink = EquippedLoc(16)
  local mhIs2H = mhLoc == "INVTYPE_2HWEAPON"

  -- Vergleichsbasis bestimmen
  local oldStats, oldScore, empty = {}, 0, false
  if equipLoc == "INVTYPE_2HWEAPON" then
    local a, b = Stats(mhLink), Stats(GetInventoryItemLink("player", 17))
    oldScore = Score(a, w, dpsW) + Score(b, w, dpsW)
    for _, s in ipairs({ a or {}, b or {} }) do
      for k, v in pairs(s) do oldStats[k] = (oldStats[k] or 0) + v end
    end
    empty = not mhLink
  else
    if slots[1] == 17 and mhIs2H then return end -- Nebenhand bei Zweihänder: nicht vergleichbar
    local best
    for _, slot in ipairs(slots) do
      local usable = slot ~= 17 or equipLoc ~= "INVTYPE_WEAPON"
                     or (CanDual() and not mhIs2H and OffhandIsWeaponOrEmpty())
      if usable then
        local l = GetInventoryItemLink("player", slot)
        local st = Stats(l)
        local sc = Score(st, w, dpsW)
        if not best or sc < best.sc then best = { sc = sc, st = st or {}, empty = not l } end
      end
    end
    if not best then return end
    oldStats, oldScore, empty = best.st, best.sc, best.empty
  end

  if newScore - oldScore <= max(0.5, oldScore * 0.03) then return end

  local text
  if empty then
    text = "empty slot"
  else
    local diffs = {}
    for i, k in ipairs(K) do
      local d = (new[k] or 0) - (oldStats[k] or 0)
      local wt = i == DPS and dpsW or w[i]
      if d > 0 and wt > 0 then
        diffs[#diffs + 1] = { d * wt, (i == DPS and format("+%.1f", d) or ("+" .. floor(d + 0.5))) .. " " .. SHORT[i] }
      end
    end
    sort(diffs, function(a, b) return a[1] > b[1] end)
    text = (diffs[1] and diffs[1][2] or "better") .. (diffs[2] and (", " .. diffs[2][2]) or "")
  end
  if minLevel > level then text = text .. " @" .. minLevel end
  return (text:gsub("[~;]", ""))
end

---------------------------------------------------------------- Ablauf
local items = {} -- [itemID] = { link, icon, looter, ups = { [guid] = text }, t }

local function Show(id)
  local it = items[id]
  if not it or not it.link or not ns.DB.lootHints then return end
  local relevant, parts, extra = false, {}, {}
  for guid, text in pairs(it.ups) do
    -- Upgrade nur für den, der es selbst gelootet hat? Interessiert nur ihn selbst.
    if guid ~= it.looter or guid == ns.me then relevant = true end
    local who = guid == ns.me and "you" or ns.ColorName(guid)
    parts[#parts + 1] = who .. " |cff55dd55" .. text .. "|r"
    extra[#extra + 1] = { (guid == ns.me and "You" or ns.DisplayName(guid)), text }
  end
  if not relevant then return end
  local icon = it.icon and ("|T" .. it.icon .. ":14:14:0:0:64:64:5:59:5:59|t ") or ""
  local by = it.looter == ns.me and "" or (ns.ColorName(it.looter) .. ": ")
  ns.Toast("i" .. id, icon .. by .. it.link .. " → " .. concat(parts, ", "), it.link, extra)
end

local function Cleanup()
  local n, now = 0, GetTime()
  for id, it in pairs(items) do
    n = n + 1
    if now - it.t > 120 then items[id] = nil end
  end
  return n
end

local function Entry(id)
  local it = items[id]
  if not it then
    if Cleanup() > 30 then wipe(items) end
    it = { ups = {}, t = GetTime() }
    items[id] = it
  end
  return it
end

local function OnItem(looter, itemString)
  local id = tonumber(itemString:match("^item:(%d+)"))
  if not id then return end
  local it = Entry(id)
  it.looter, it.t = looter, GetTime()
  if C_Item and C_Item.DoesItemExistByID and not C_Item.DoesItemExistByID(id) then return end
  local item = Item:CreateFromItemID(id)
  item:ContinueOnItemLoad(function()
    -- Link aus dem vollständigen Item-String holen, sonst fehlen Zufallswerte ("of the Monkey")
    local _, link = GetItemInfo(itemString)
    it.link = link or itemString
    it.icon = item:GetItemIcon()
    local ok, text = pcall(Evaluate, it.link)
    if ok and text then
      it.ups[ns.me] = text
      ns.Send("W:" .. id .. "~" .. text)
    end
    Show(id)
  end)
end

-- Jemand anderes hat gelootet
ns.handlers.I = function(p, payload, guid)
  if not ns.DB.lootHints or not ns.Active() then return end
  local s = payload:match("^(item:[%-%d:]+)")
  if s then OnItem(guid, s) end
end

-- Jemand meldet: ist ein Upgrade für mich
ns.handlers.W = function(p, payload, guid)
  local id, text = payload:match("^(%d+)~(.+)$")
  id = tonumber(id)
  if not id then return end
  local it = Entry(id)
  it.ups[guid] = text
  Show(id)
end

---------------------------------------------------------------- Eigenen Loot erkennen
local function Prefix(fmt) return fmt and fmt:match("^(.-)%%") end
local SKIP = {} -- Questbelohnungen und Hergestelltes zählen nicht als Loot

local ev = CreateFrame("Frame")
ev:RegisterEvent("CHAT_MSG_LOOT")
ev:RegisterEvent("PLAYER_LOGIN")
ev:SetScript("OnEvent", function(_, e, text, ...)
  if e == "PLAYER_LOGIN" then
    for _, fmt in ipairs({ LOOT_ITEM_PUSHED_SELF, LOOT_ITEM_PUSHED_SELF_MULTIPLE,
                           LOOT_ITEM_CREATED_SELF, LOOT_ITEM_CREATED_SELF_MULTIPLE }) do
      local p = Prefix(fmt)
      if p and p ~= "" then SKIP[#SKIP + 1] = p end
    end
    return
  end
  if not ns.DB or not ns.DB.lootHints or not IsInGroup() or not ns.Active() then return end
  local guid = select(11, ...) -- 12. Argument von CHAT_MSG_LOOT: GUID des Empfängers
  if issecret(text) or issecret(guid) or guid ~= ns.me then return end
  for i = 1, #SKIP do
    if text:sub(1, #SKIP[i]) == SKIP[i] then return end
  end
  local s = text:match("|H(item:[^|]+)|h")
  if not s or text:find("|cff9d9d9d", 1, true) then return end -- graue Items interessieren nicht
  local _, _, _, equipLoc = GetItemInfoInstant(s)
  if not SLOTS[equipLoc] then return end -- nur ausrüstbare Sachen
  ns.Send("I:" .. s)
  OnItem(ns.me, s)
end)
