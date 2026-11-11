-- PartyPace | Quest-Share anfragen
-- Wer eine Quest nicht hat, kann per Shift-Klick einen Mitspieler bitten, sie zu teilen.
-- Ablauf: P (Anfrage) -> der andere drückt "Teilen" -> liest Blizzards Ergebnis-Meldung
-- (zu weit weg, schon erledigt, ...) -> A (Antwort) zurück. Klappt's bei einem nicht,
-- wird automatisch der Nächste gefragt.
local ADDON, ns = ...

local format, band = string.format, bit.band
local issecret = issecretvalue or function() return false end
local TAG = ns.TAG

-- Blizzards Meldungen nach dem Teilen -> unser Status. Retry = beim Nächsten nochmal probieren.
local RESULTS = {
  { "ERR_QUEST_PUSH_SUCCESS_S",              "sent" },
  { "ERR_QUEST_PUSH_ACCEPTED_S",             "sent" },
  { "ERR_QUEST_PUSH_TOO_FAR_S",              "far",     true },
  { "ERR_QUEST_PUSH_BUSY_S",                 "busy",    true },
  { "ERR_QUEST_PUSH_ALREADY_DONE_S",         "done" },
  { "ERR_QUEST_PUSH_ALREADY_DONE_TO_RECIPIENT_S", "done" },
  { "ERR_QUEST_PUSH_ONQUEST_S",              "onquest" },
  { "ERR_QUEST_PUSH_ONQUEST_TO_RECIPIENT_S", "onquest" },
  { "ERR_QUEST_PUSH_LOG_FULL_S",             "full" },
  { "ERR_QUEST_PUSH_LOG_FULL_TO_RECIPIENT_S", "full" },
  { "ERR_QUEST_PUSH_INVALID_S",              "invalid" },
  { "ERR_QUEST_PUSH_INVALID_TO_RECIPIENT_S", "invalid" },
  { "ERR_QUEST_PUSH_NOT_ALLOWED_S",          "invalid" },
  { "ERR_QUEST_PUSH_DECLINED_S",             "declined" },
}
local RETRY = { gone = true, noshare = false, unknown = true }
local patterns = {}

local function BuildPatterns()
  for _, r in ipairs(RESULTS) do
    local fmt = _G[r[1]]
    if type(fmt) == "string" then
      -- "%s is too far away..." -> "^.+ is too far away...$"
      local p = fmt:gsub("%%s", "\1"):gsub("%%d", "\2")
      p = p:gsub("([%%%(%)%.%+%-%*%?%[%]%^%$])", "%%%1")
      p = p:gsub("\1", ".+"):gsub("\2", "%%d+")
      patterns[#patterns + 1] = { "^" .. p .. "$", r[2] }
    end
    if r[3] then RETRY[r[2]] = true end
  end
end

local function Title(qid)
  return "|cffffd100" .. (ns.QuestTitle and ns.QuestTitle(qid) or ("#" .. qid)) .. "|r"
end

---------------------------------------------------------------- Anfragende Seite
local asks = {} -- [qid] = { tried = {[guid]=true}, current = guid, timer }

local function Candidates(qid, tried)
  -- Reihenfolge: hat sie + teilbar + in Reichweite, dann teilbar, dann irgendwer der sie hat
  local best
  for _, key in ipairs(ns.order) do
    local p = ns.players[key]
    if key ~= ns.me and p and p.quests[qid] and not tried[key] then
      local unit = ns.units[key]
      local qi = ns.qinfo[qid] or {}
      local score = (band(qi.tags or 0, TAG.SHARE) > 0 and 2 or 0)
      if unit and UnitInRange then
        local ok, inRange = pcall(UnitInRange, unit)
        if ok and inRange and not issecret(inRange) then score = score + 1 end
      end
      if not best or score > best.score then best = { key = key, score = score } end
    end
  end
  return best and best.key
end

local function Ask(qid)
  local a = asks[qid]
  local key = Candidates(qid, a.tried)
  if not key then
    asks[qid] = nil
    local s = ns.QuestStart and ns.QuestStart(qid)
    ns.Print(format("Nobody could share %s.%s", Title(qid), s and (" Get it from " .. s .. ".") or ""))
    return
  end
  a.tried[key], a.current = true, key
  ns.Send("P:" .. qid .. "~" .. key)
  ns.Print(format("Asked %s to share %s…", ns.ColorName(key), Title(qid)))
  if a.timer then a.timer:Cancel() end
  a.timer = C_Timer.NewTimer(8, function()
    a.timer = nil
    ns.Print(format("No answer from %s.", ns.ColorName(key)))
    Ask(qid)
  end)
end

function ns.RequestShare(qid)
  if asks[qid] then return true end -- läuft schon
  asks[qid] = { tried = {} }
  Ask(qid)
  return true
end

local MSG = {
  sent     = "%s shared %s – accept it in the popup.",
  far      = "%s is too far away to share %s.",
  busy     = "%s couldn't share %s (busy).",
  done     = "You already completed %s.",
  onquest  = "You already have %s.",
  full     = "Your quest log is full – can't receive %s.",
  invalid  = "You're not eligible for %s yet (level or prerequisite quest).",
  declined = "You declined %s.",
  noshare  = "%s can't be shared.",
  gone     = "%s doesn't have %s anymore.",
  unknown  = "%s tried to share %s, but nothing came back.",
}

ns.handlers.A = function(p, payload, guid)
  local qid, req, status = payload:match("^(%d+)~([^~]+)~(%a+)$")
  qid = tonumber(qid)
  if not qid or req ~= ns.me then return end
  local a = asks[qid]
  if not a or a.current ~= guid then return end
  if a.timer then a.timer:Cancel(); a.timer = nil end

  local who, t = ns.ColorName(guid), Title(qid)
  local m = MSG[status] or MSG.unknown
  if status == "done" or status == "onquest" or status == "full" or status == "invalid" or status == "declined" then
    ns.Print(format(m, t))
  elseif status == "noshare" then
    local s = ns.QuestStart and ns.QuestStart(qid)
    ns.Print(format(m, t) .. (s and (" Get it from " .. s .. ".") or ""))
  else
    ns.Print(format(m, who, t))
  end

  if RETRY[status] then Ask(qid) else asks[qid] = nil end
end

---------------------------------------------------------------- Teilende Seite
local pending -- { qid, req, timer }

local function Reply(status)
  if not pending then return end
  local pd = pending
  pending = nil
  if pd.timer then pd.timer:Cancel() end
  ns.Send("A:" .. pd.qid .. "~" .. pd.req .. "~" .. status)
  if status == "sent" then
    ns.Print(format("Shared %s with %s (requested).", Title(pd.qid), ns.ColorName(pd.req)))
  end
end

ns.handlers.P = function(p, payload, guid)
  local qid, target = payload:match("^(%d+)~(.+)$")
  qid = tonumber(qid)
  if not qid or target ~= ns.me then return end
  if pending then Reply("busy") end
  pending = { qid = qid, req = guid }
  if not ns.logIndex[qid] then return Reply("gone") end
  if C_QuestLog.IsPushableQuest and not C_QuestLog.IsPushableQuest(qid) then return Reply("noshare") end
  ns.ShareQuest(qid, true)
  -- Kommt keine Meldung von Blizzard, nach 3 s "unbekannt" zurückmelden
  pending.timer = C_Timer.NewTimer(3, function() if pending then pending.timer = nil; Reply("unknown") end end)
end

local ev = CreateFrame("Frame")
ev:RegisterEvent("PLAYER_LOGIN")
ev:RegisterEvent("CHAT_MSG_SYSTEM")
ev:RegisterEvent("UI_INFO_MESSAGE")
ev:RegisterEvent("UI_ERROR_MESSAGE")
ev:SetScript("OnEvent", function(_, e, a1, a2)
  if e == "PLAYER_LOGIN" then BuildPatterns(); return end
  if not pending then return end
  local text = (e == "CHAT_MSG_SYSTEM") and a1 or a2
  if type(text) ~= "string" or issecret(text) then return end
  for _, pt in ipairs(patterns) do
    if text:find(pt[1]) then return Reply(pt[2]) end
  end
end)
