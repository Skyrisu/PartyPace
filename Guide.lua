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
            if not rankT[id] or rank < rankT[id] then rankT[id], whatT[id] = rank, what end
          end
        end
      end
    end
  end
end

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

  -- Vorausschauen (nur klassisches Guide-Fenster; im Beta-Fenster V2 gibt's nur die aktiven Schritte)
  local ahead = ns.DB.guideAhead or 3
  local pool = f and f.ScrollChild and f.ScrollChild.framePool
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
  local s = tostring(_G.RXPCData and _G.RXPCData.currentStep) .. ":" .. (ns.DB.guideAhead or 3)
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
    ns.MarkDirty()
  end
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
