-- PartyPace | RestedXP-Anbindung
-- Liest die aktuellen (und die nächsten) Guide-Schritte aus RestedXP und merkt sich,
-- welche Quests dort vorkommen. Nur lesend, RestedXP wird nicht verändert.
-- Quellen in RestedXP: RXPFrame.activeSteps (aktive Schritte), RXPFrame.ScrollChild.framePool[n].step
-- (Schrittliste fürs Vorausschauen), RXPCData.currentStep (Fortschritt).
local ADDON, ns = ...

local abs, tonumber, type = math.abs, tonumber, type

-- Element-Typen, die sich auf eine konkrete Quest beziehen (Bedingungen wie isOnQuest zählen nicht)
local QTAGS = { accept = "accept", turnin = "turn in", complete = "complete", collect = "collect",
                daily = "accept", dailyturnin = "turn in" }

ns.guide = {
  loaded = false,  -- RestedXP vorhanden
  active = false,  -- ein Guide läuft
  rank   = {},     -- [qid] = 0 aktueller Schritt, 1..n = so viele Schritte voraus
  what   = {},     -- [qid] = "turn in" / "complete" / ...
}
local G = ns.guide
local sig = ""

local function Add(step, rank, rankT, whatT)
  local els = type(step) == "table" and step.elements
  if type(els) ~= "table" then return end
  for _, el in ipairs(els) do
    local what = type(el) == "table" and QTAGS[el.tag]
    if what and not el.skip then
      local ids = el.ids
      if el.questId then ids = { el.questId } end
      if type(ids) == "table" then
        for _, id in ipairs(ids) do
          id = tonumber(id)
          if id and id ~= 0 then
            id = abs(id)
            -- näher am eigenen Schritt gewinnt
            if not rankT[id] or abs(rank) < abs(rankT[id]) then rankT[id], whatT[id] = rank, what end
          end
        end
      end
    end
  end
end

local function GuideID()
  local d = _G.RXPCData
  if not d or not d.currentGuideName then return nil end
  return ((d.currentGuideGroup or "") .. "/" .. d.currentGuideName):gsub("[~;]", ""):sub(1, 120)
end

-- Schritte der anderen (nur wer denselben Guide läuft): kleinster und größter Schritt
local function PartySteps(myID)
  local lo, hi
  if not ns.DB.guideParty or not myID then return end
  for _, key in ipairs(ns.order) do
    local p = ns.players[key]
    if key ~= ns.me and p and p.gid == myID and p.gstep then
      lo = (not lo or p.gstep < lo) and p.gstep or lo
      hi = (not hi or p.gstep > hi) and p.gstep or hi
    end
  end
  return lo, hi
end

local mySent -- zuletzt verschickter eigener Schritt

local function Rebuild()
  local f = _G.RXPFrame
  local active = f and f.activeSteps
  local rankT, whatT = {}, {}
  local last = 0

  if type(active) == "table" then
    for _, step in ipairs(active) do
      Add(step, 0, rankT, whatT)
      local idx = type(step) == "table" and tonumber(step.index)
      if idx and idx > last then last = idx end
    end
  end
  if last == 0 then last = tonumber(_G.RXPCData and _G.RXPCData.currentStep) or 0 end

  G.step, G.id = last, GuideID()

  -- Vorausschauen (nur klassisches Guide-Fenster; im Beta-Fenster V2 gibt's nur die aktiven Schritte)
  local ahead = ns.DB.guideAhead or 3
  local pool = f and f.ScrollChild and f.ScrollChild.framePool

  -- Gruppe: zurück bis zum Langsamsten, vor bis zum Schnellsten (max. 30 Schritte je Richtung).
  -- Schritte, die ICH schon erledigt habe, zählen hier mit – die anderen brauchen sie ja noch.
  local lo, hi = PartySteps(G.id)
  if last > 0 and type(pool) == "table" then
    local from = lo and math.max(math.min(lo, last), last - 30) or last
    local to = hi and math.min(math.max(hi, last), last + 30) or last
    for i = from, to do
      local fr = pool[i]
      local step = fr and fr.step
      if i ~= last and step and step.index == i then Add(step, i - last, rankT, whatT) end
    end
  end

  if ahead > 0 and last > 0 and type(pool) == "table" then
    local n = 0
    for i = last + 1, last + 40 do
      local fr = pool[i]
      local step = fr and fr.step
      if not step or step.index ~= i or not fr:IsShown() then break end
      if not step.completed and not step.optional then
        n = n + 1
        Add(step, n, rankT, whatT)
        if n >= ahead then break end
      end
    end
  end

  G.rank, G.what = rankT, whatT
  G.active = next(rankT) ~= nil or (type(active) == "table" and #active > 0)
end

-- Billiger Fingerabdruck: ändert sich, sobald RestedXP andere Schritte aktiv hat
local function Signature()
  local f = _G.RXPFrame
  local active = f and f.activeSteps
  local s = tostring(_G.RXPCData and _G.RXPCData.currentStep) .. ":" .. (ns.DB.guideAhead or 3) .. ":" .. tostring(GuideID())
  if type(active) == "table" then
    for _, step in ipairs(active) do
      s = s .. "," .. tostring(type(step) == "table" and step.index)
    end
  end
  return s
end

function ns.GuideCheck(force)
  if not G.loaded then return end
  local okSig, s = pcall(Signature)
  if not okSig then return end
  if force or s ~= sig then
    sig = s
    -- RestedXP-Interna können sich mit Updates ändern: bei Fehlern sauber abschalten statt jede Sekunde zu crashen
    local ok = pcall(Rebuild)
    if not ok then
      G.loaded, G.active = false, false
      wipe(G.rank); wipe(G.what)
      ns.Print("RestedXP integration disabled – this RestedXP version isn't supported yet.")
    end
    ns.GuideAnnounce(false)
    ns.MarkDirty()
  end
end

-- Eigenen Guide-Schritt an die Gruppe schicken (nur bei Änderung oder beim Full-Sync)
function ns.GuideAnnounce(force)
  if not G.loaded or not G.id or not G.step or G.step == 0 then return end
  local key = G.step .. "~" .. G.id
  if force or key ~= mySent then
    mySent = key
    ns.Send("G:" .. key)
  end
end

ns.handlers.G = function(p, payload)
  local idx, gid = payload:match("^(%d+)~(.+)$")
  if not idx then return end
  p.gstep, p.gid = tonumber(idx), gid
  ns.GuideCheck(true)
end

function ns.GuideInit()
  local loaded = (C_AddOns and C_AddOns.IsAddOnLoaded or IsAddOnLoaded)("RXPGuides")
  G.loaded = loaded and _G.RXPFrame ~= nil or false
  if not G.loaded then return end
  -- RestedXP feuert keine öffentlichen Events, deshalb ein ruhiger 1-s-Check.
  -- Kostet praktisch nichts und läuft nur, solange das PartyPace-Fenster offen ist.
  C_Timer.NewTicker(1, function()
    local tq = _G.PartyPaceFrame
    if tq and tq:IsShown() then ns.GuideCheck(false) end
  end)
  C_Timer.After(2, function() ns.GuideCheck(true) end)
end
