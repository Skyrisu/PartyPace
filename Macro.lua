-- PartyPace | Target-Makro mit Ping
-- Übernimmt die Ziele aus RestedXPs Makro "RXPTargeting" in ein eigenes Makro "PartyPace"
-- und hängt einen Angriffs-Ping an. Standardmäßig aus (/pace macro).
-- Makros dürfen im Kampf nicht geändert werden: dann wird bis nach dem Kampf gewartet.
local ADDON, ns = ...

local MACRO, RXP_MACRO = "PartyPace", "RXPTargeting"
local ICON = "Ability_Hunter_MarkedForDeath"
local PING = "/ping [@target,harm,nodead] attack"
local MAXLEN = 255
local lastSrc, pending, hinted = nil, false, false

-- RestedXP-Makro + Ping-Zeile. Zu lang? Dann fliegen die obersten (unwichtigsten) Ziele raus,
-- genau wie RestedXP es selbst macht.
local function Build(src)
  if not src or src == "" or src:find("^%s*//") then
    return "// PartyPace: no targets in the current RestedXP step"
  end
  local lines = {}
  for l in src:gmatch("[^\n]+") do lines[#lines + 1] = l end
  local function Join() return table.concat(lines, "\n") .. "\n" .. PING end
  local body = Join()
  while #body > MAXLEN do
    local idx
    for i, l in ipairs(lines) do
      if l:find("^/target") and not l:find("^/targetlasttarget") then idx = i; break end
    end
    if not idx then break end
    table.remove(lines, idx)
    body = Join()
  end
  return body
end

local function Write(body)
  if GetMacroInfo(MACRO) then
    local _, _, cur = GetMacroInfo(MACRO)
    if cur ~= body then EditMacro(MACRO, MACRO, nil, body) end
    return true
  end
  if GetNumMacros() >= (MAX_ACCOUNT_MACROS or 120) then
    ns.Print("Your general macro slots are full – can't create the PartyPace macro.")
    return false
  end
  CreateMacro(MACRO, ICON, body)
  ns.Print("Created the macro 'PartyPace' – open /macro and drag it onto your action bar.")
  return true
end

function ns.MacroUpdate(force)
  if not ns.DB.targetMacro then return end
  if InCombatLockdown() then pending = true; return end
  pending = false
  local _, _, src = GetMacroInfo(RXP_MACRO)
  if not src and not hinted then
    hinted = true
    ns.Print("RestedXP's target macro wasn't found – enable it in the RestedXP settings.")
  end
  if not force and src == lastSrc and GetMacroInfo(MACRO) then return end
  lastSrc = src
  Write(Build(src))
end

function ns.MacroToggle()
  local db = ns.DB
  db.targetMacro = not db.targetMacro
  if db.targetMacro then
    if not ((C_AddOns and C_AddOns.IsAddOnLoaded) or IsAddOnLoaded)("RXPGuides") then
      ns.Print("Target macro needs RestedXP Guides.")
    end
    lastSrc = nil
    ns.MacroUpdate(true)
  elseif not InCombatLockdown() and GetMacroInfo(MACRO) then
    -- Makro bleibt (liegt evtl. auf der Leiste), zielt aber auf nichts Altes mehr
    EditMacro(MACRO, MACRO, nil, "// PartyPace target macro is off (/pace macro)")
  end
  ns.Print("Target macro: " .. (db.targetMacro and "on" or "off"))
end

local ev = CreateFrame("Frame")
ev:RegisterEvent("PLAYER_LOGIN")
ev:RegisterEvent("UPDATE_MACROS")
ev:RegisterEvent("PLAYER_REGEN_ENABLED")
local queued = false
ev:SetScript("OnEvent", function(_, e)
  if not ns.DB or not ns.DB.targetMacro then return end
  if e == "PLAYER_REGEN_ENABLED" then
    if pending then ns.MacroUpdate(false) end
  elseif not queued then
    -- RestedXP ändert sein Makro gern mehrmals hintereinander: zusammenfassen
    queued = true
    C_Timer.After(e == "PLAYER_LOGIN" and 3 or 0.5, function()
      queued = false
      ns.MacroUpdate(e == "PLAYER_LOGIN")
    end)
  end
end)
