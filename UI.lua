-- PartyPace | UI
-- Flaches, dunkles Fenster mit 1px-Rahmen und Klassenfarben (ElvUI/LuckyOne-Look).
-- Wird nur neu gezeichnet, wenn sich Daten ändern und das Fenster sichtbar ist.
local ADDON, ns = ...

local floor, min, max, ceil, format = math.floor, math.min, math.max, math.ceil, string.format
local band = bit.band
local tremove = table.remove
local TAG  = ns.TAG
local WHITE  = "Interface\\Buttons\\WHITE8X8"
local CHECK  = "|TInterface\\RaidFrame\\ReadyCheck-Ready:12:12|t"
local CHECKG = "|TInterface\\RaidFrame\\ReadyCheck-Ready:12:12:0:0:64:64:0:64:0:64:110:110:110|t"
local CROSS  = "|TInterface\\RaidFrame\\ReadyCheck-NotReady:12:12|t"
local WAIT   = "|TInterface\\RaidFrame\\ReadyCheck-Waiting:12:12|t"
local EMPTY  = {}

local ROWH, COLW, PAD, HEADH = 16, 40, 4, 30
local TITLEW, MAXROWS = 170, 18 -- per Zieh-Griff einstellbar (DB.titleW / DB.maxRows)
local sizing = false             -- true, solange am Griff gezogen wird

-- Streifen links an jeder Zeile
local STATE_COLOR = {
  { 0.90, 0.25, 0.25 }, -- 1: jemand hat die Quest nicht
  { 1.00, 0.75, 0.15 }, -- 2: unterschiedlicher Fortschritt
  { 0.35, 0.35, 0.35 }, -- 3: gleicher Stand
  { 0.30, 0.85, 0.35 }, -- 4: alle fertig
}

local media = { font = STANDARD_TEXT_FONT, tex = WHITE }
local DB, frame, info, empty
local cols, rows, list, colOnline = {}, {}, {}, {}
local offset, dirty, pending = 0, true, false
local UpdateHearth, LayoutToasts -- weiter unten definiert, vorher schon benutzt

---------------------------------------------------------------- Helfer
local function GrabMedia()
  if ElvUI then
    local ok, E = pcall(function() return unpack(ElvUI) end)
    if ok and E and E.media then
      media.font = E.media.normFont or media.font
      media.tex  = E.media.normTex or media.tex
    end
  end
end

local function ClassColor(class)
  local c = class and ((CUSTOM_CLASS_COLORS and CUSTOM_CLASS_COLORS[class]) or RAID_CLASS_COLORS[class])
  if c then return c.r, c.g, c.b end
  return 0.8, 0.8, 0.8
end

function ns.ColorName(key)
  local p = ns.players[key]
  local r, g, b = ClassColor(p and p.class)
  return format("|cff%02x%02x%02x%s|r", floor(r * 255), floor(g * 255), floor(b * 255), ns.DisplayName(key))
end

local function Short(key) return ns.DisplayName(key) end

local function NewText(parent, size, justify)
  local fs = parent:CreateFontString(nil, "OVERLAY")
  fs:SetFont(media.font, size, "OUTLINE")
  fs:SetJustifyH(justify or "LEFT")
  fs:SetWordWrap(false)
  return fs
end

local function Skin(f, alpha)
  f:SetBackdrop({ bgFile = WHITE, edgeFile = WHITE, edgeSize = 1 })
  f:SetBackdropColor(0.06, 0.06, 0.06, alpha)
  f:SetBackdropBorderColor(0, 0, 0, 1)
end

function ns.QuestTitle(id)
  local qi = ns.qinfo[id]
  local t = qi and qi.title
  if (not t or t == "") and C_QuestLog.GetTitleForQuestID then t = C_QuestLog.GetTitleForQuestID(id) end
  return (t and t ~= "") and t or ("Quest #" .. id)
end

-- "[23+]" in Schwierigkeitsfarbe; + = Gruppe, D = Dungeon, R = Raid
local function LevelTag(level, tags)
  if not level or level <= 0 then return "" end
  local sfx = (band(tags, TAG.RAID) > 0 and "R") or (band(tags, TAG.DUNGEON) > 0 and "D")
           or (band(tags, TAG.GROUP) > 0 and "+") or ""
  local c = GetQuestDifficultyColor and GetQuestDifficultyColor(level)
  if c then
    return format("|cff%02x%02x%02x[%d%s]|r ", floor(c.r * 255), floor(c.g * 255), floor(c.b * 255), level, sfx)
  end
  return format("[%d%s] ", level, sfx)
end

local function TypeText(tags)
  local t = {}
  if band(tags, TAG.CLASS) > 0 then t[#t + 1] = "Class quest" end
  if band(tags, TAG.PROF) > 0 then t[#t + 1] = "Profession quest" end
  if band(tags, TAG.CAMP) > 0 then t[#t + 1] = "Camping quest" end
  if band(tags, TAG.RAID) > 0 then t[#t + 1] = "Raid"
  elseif band(tags, TAG.DUNGEON) > 0 then t[#t + 1] = "Dungeon"
  elseif band(tags, TAG.GROUP) > 0 then t[#t + 1] = "Group" end
  return table.concat(t, " · ")
end

local function Progress(q)
  if q.flag == 1 then return 1 end
  local o = q.obj
  local n = #o / 2
  if n == 0 then return 0 end
  local s = 0
  for i = 1, #o, 2 do s = s + ((o[i + 1] > 0) and (o[i] / o[i + 1]) or 0) end
  return s / n
end

local function CellText(p, id)
  local q = p.quests[id]
  if not q then
    if p.done[id] then return CHECKG, 1 end
    return "|cffcc4444-|r", nil
  end
  if q.flag == 2 then return CROSS, 0 end
  local f = Progress(q)
  if q.flag == 1 or f >= 1 then return CHECK, 1 end
  local o = q.obj
  if #o == 2 then return o[1] .. "/" .. o[2], f end
  return floor(f * 100 + 0.5) .. "%", f
end

-- personal = Klassen-/Berufsquest: dass sie anderen fehlt, ist normal und wird nicht rot markiert
local function RowState(id, personal)
  local missing, differ, allDone, first = false, false, true, nil
  for _, name in ipairs(ns.order) do
    local p = ns.players[name]
    if p then
      local q, f = p.quests[id], nil
      if q then f = Progress(q)
      elseif p.done[id] then f = 2
      elseif not personal then missing = true end
      if f then
        if f < 1 then allDone = false end
        if first == nil then first = f elseif math.abs(first - f) > 0.001 then differ = true end
      end
    end
  end
  if missing and #ns.order > 1 then return 1 end
  if allDone then return 4 end
  if differ then return 2 end
  return 3
end

local function GuideOn() return DB.guideOnly and ns.guide.loaded and ns.guide.active end

local function Visible(e)
  if GuideOn() and not ns.guide.rank[e.id] then return false end
  if DB.hideClass and band(e.tags, TAG.CLASS) > 0 then return false end
  if DB.hideProf and band(e.tags, TAG.PROF) > 0 then return false end
  if DB.hideCamp and band(e.tags, TAG.CAMP) > 0 then return false end
  if ns.IsUserHidden(e.id) then return false end
  if DB.hideDone and e.state == 4 then return false end
  if DB.onlyDiff and e.state > 2 then return false end
  return true
end

---------------------------------------------------------------- Tooltip / Klicks
local function RowEnter(self)
  local e = self.entry
  if not e or e.header then return end
  local id = e.id
  GameTooltip:SetOwner(self, "ANCHOR_LEFT")
  GameTooltip:AddLine(LevelTag(e.level, e.tags) .. e.title, 1, 0.82, 0)
  local sub = TypeText(e.tags)
  if e.zone ~= "" then sub = (sub ~= "" and (e.zone .. " · " .. sub)) or e.zone end
  if sub ~= "" then GameTooltip:AddLine(sub, 0.55, 0.55, 0.55) end
  local gr = ns.guide.rank[id]
  if gr then
    local when = gr == 0 and "current step" or (gr == 1 and "next step")
      or (gr < 0 and (-gr .. (gr == -1 and " step" or " steps") .. " back – party is still here")) or ("in " .. gr .. " steps")
    GameTooltip:AddLine("Guide: " .. (ns.guide.what[id] or "quest") .. " · " .. when, 1, 0.82, 0)
  end

  local nObj = 0
  for _, name in ipairs(ns.order) do
    local q = ns.players[name] and ns.players[name].quests[id]
    if q then nObj = max(nObj, #q.obj / 2) end
  end
  local texts = ns.objText[id]

  for i = 1, max(nObj, 1) do
    if nObj > 0 then
      local t = texts and texts[i]
      GameTooltip:AddLine((t and t ~= "") and t or ("Objective " .. i), 0.85, 0.85, 0.85)
    end
    for j, name in ipairs(ns.order) do
      local p = ns.players[name]
      local q = p.quests[id]
      local right
      if not q then
        right = p.done[id] and "|cff888888turned in|r" or "|cffcc4444missing|r"
      elseif q.flag == 2 then
        right = "|cffcc4444failed|r"
      elseif nObj == 0 then
        right = (q.flag == 1) and "|cff55dd55complete|r" or "in progress"
      else
        local n, r = q.obj[i * 2 - 1], q.obj[i * 2]
        right = n and ((n >= r and "|cff55dd55" or "|cffffffff") .. n .. "/" .. r .. "|r") or "-"
      end
      if not colOnline[j] then right = right .. " |cff777777(offline)|r" end
      local cr, cg, cb = ClassColor(p.class)
      GameTooltip:AddDoubleLine("  " .. Short(name), right, cr, cg, cb)
    end
  end
  if ns.logIndex[id] then
    if IsInGroup() then GameTooltip:AddLine("Shift-click: share quest", 0.5, 0.5, 0.5) end
  elseif not ns.players[ns.me].done[id] then
    GameTooltip:AddLine(" ")
    GameTooltip:AddLine("You don't have this quest", 1, 0.4, 0.4)
    if band(e.tags, TAG.SHARE) > 0 then
      GameTooltip:AddLine("Shift-click: ask for a share", 0.5, 0.5, 0.5)
    else
      local s = ns.QuestStart(id)
      GameTooltip:AddLine(s and ("Starts at: " .. s) or "Not shareable", 0.85, 0.85, 0.85)
      GameTooltip:AddLine("Shift-click: ask for a share anyway", 0.5, 0.5, 0.5)
    end
  end
  GameTooltip:AddLine("Alt-click: hide quest · Alt+Ctrl-click: hide category", 0.5, 0.5, 0.5)
  GameTooltip:Show()
end

local function RowClick(self)
  local e = self.entry
  if not e then return end
  if IsAltKeyDown() then
    if IsControlKeyDown() or e.header then
      local cat = e.header and e.title or e.zone
      DB.hiddenHeaders[cat] = true
      ns.Print("Hidden category: " .. cat .. "  (menu → Unhide all)")
    else
      DB.hiddenQuests[e.id] = true
    end
    GameTooltip:Hide()
    ns.Refresh()
  elseif not e.header and IsShiftKeyDown() then
    if ns.logIndex[e.id] then ns.ShareQuest(e.id) else ns.RequestShare(e.id) end
  end
end

---------------------------------------------------------------- Bausteine (lazy, werden wiederverwendet)
local function GetCol(i)
  local c = cols[i]
  if c then return c end
  c = CreateFrame("Frame", nil, frame)
  c:SetSize(COLW - 2, HEADH - 5)
  c:SetPoint("TOPLEFT", frame, "TOPLEFT", PAD + TITLEW + (i - 1) * COLW + 1, -3)
  c.name = NewText(c, 10, "CENTER")
  c.name:SetPoint("TOP")
  c.name:SetWidth(COLW - 2)
  c.lvl = NewText(c, 9, "CENTER")
  c.lvl:SetPoint("TOP", c.name, "BOTTOM", 0, -1)
  c.lvl:SetWidth(COLW - 2)

  c.rest = CreateFrame("StatusBar", nil, c)
  c.rest:SetStatusBarTexture(media.tex)
  c.rest:SetStatusBarColor(0.3, 0.55, 1, 0.45)
  c.rest:SetPoint("BOTTOMLEFT")
  c.rest:SetPoint("BOTTOMRIGHT")
  c.rest:SetHeight(3)
  local bg = c.rest:CreateTexture(nil, "BACKGROUND")
  bg:SetAllPoints()
  bg:SetColorTexture(0, 0, 0, 0.8)

  c.xp = CreateFrame("StatusBar", nil, c)
  c.xp:SetStatusBarTexture(media.tex)
  c.xp:SetAllPoints(c.rest)
  c.xp:SetFrameLevel(c.rest:GetFrameLevel() + 1)
  cols[i] = c
  return c
end

local function GetCell(r, i)
  local c = r.cells[i]
  if c then return c end
  c = CreateFrame("Frame", nil, r)
  c:SetSize(COLW - 2, ROWH - 2)
  c:SetPoint("LEFT", r, "LEFT", TITLEW + (i - 1) * COLW + 1, 0)
  c.bg = c:CreateTexture(nil, "BACKGROUND")
  c.bg:SetAllPoints()
  c.bg:SetColorTexture(0, 0, 0, 0.35)
  c.bar = c:CreateTexture(nil, "BORDER")
  c.bar:SetTexture(media.tex)
  c.bar:SetPoint("TOPLEFT")
  c.bar:SetPoint("BOTTOMLEFT")
  c.text = NewText(c, 10, "CENTER")
  c.text:SetAllPoints()
  r.cells[i] = c
  return c
end

local function GetRow(i)
  local r = rows[i]
  if r then return r end
  r = CreateFrame("Button", nil, frame)
  r:SetHeight(ROWH)
  r:SetPoint("TOPLEFT", frame, "TOPLEFT", PAD, -(HEADH + 2 + (i - 1) * ROWH))
  r:SetPoint("RIGHT", frame, "RIGHT", -PAD, 0)
  r.stripe = r:CreateTexture(nil, "ARTWORK")
  r.stripe:SetColorTexture(1, 1, 1, 1)
  r.stripe:SetPoint("TOPLEFT", 0, -1)
  r.stripe:SetPoint("BOTTOMLEFT", 0, 1)
  r.stripe:SetWidth(2)
  r.hl = r:CreateTexture(nil, "HIGHLIGHT")
  r.hl:SetAllPoints()
  r.hl:SetColorTexture(1, 1, 1, 0.06)
  r.title = NewText(r, 11)
  r.title:SetPoint("LEFT", 6, 0)
  r.cells = {}
  r:RegisterForClicks("AnyUp")
  r:SetScript("OnEnter", RowEnter)
  r:SetScript("OnLeave", GameTooltip_Hide)
  r:SetScript("OnClick", RowClick)
  rows[i] = r
  return r
end

---------------------------------------------------------------- Zeichnen
function ns.Render()
  local order = ns.order
  local maxOff = max(0, #list - MAXROWS)
  if offset > maxOff then offset = maxOff end
  local shown = DB.collapsed and 0 or min(MAXROWS, #list)

  for i = 1, shown do
    local e, r = list[i + offset], GetRow(i)
    r.entry = e
    if e.header then
      -- Zonen-Überschrift
      r.title:SetFont(media.font, 10, "OUTLINE")
      r.title:SetWidth(TITLEW + #order * COLW - 10)
      r.title:SetText(e.title)
      r.title:SetTextColor(1, 0.82, 0)
      r.stripe:Hide()
      r.hl:SetAlpha(0)
      for j = 1, #r.cells do r.cells[j]:Hide() end
    else
      r.title:SetFont(media.font, 11, "OUTLINE")
      r.title:SetWidth(TITLEW - 10)
      r.title:SetText(e.display)
      if e.state == 4 then r.title:SetTextColor(0.6, 0.6, 0.6) else r.title:SetTextColor(1, 1, 1) end
      local sc = STATE_COLOR[e.state]
      r.stripe:SetVertexColor(sc[1], sc[2], sc[3])
      r.stripe:Show()
      r.hl:SetAlpha(1)
      for j = 1, #order do
        local p, c = ns.players[order[j]], GetCell(r, j)
        local txt, f = CellText(p, e.id)
        c.text:SetText(txt)
        if f and f > 0 then
          local cr, cg, cb = ClassColor(p.class)
          c.bar:SetWidth((COLW - 2) * min(f, 1))
          c.bar:SetVertexColor(cr, cg, cb, 0.45)
          c.bar:Show()
        else
          c.bar:Hide()
        end
        c:SetAlpha(colOnline[j] and 1 or 0.35)
        c:Show()
      end
      for j = #order + 1, #r.cells do r.cells[j]:Hide() end
    end
    r:Show()
  end
  for i = shown + 1, #rows do rows[i]:Hide() end

  local isEmpty = not DB.collapsed and #list == 0
  empty:SetShown(isEmpty)
  local body = isEmpty and ROWH or shown * ROWH
  if sizing and not DB.collapsed then body = MAXROWS * ROWH end -- Vorschau der eingestellten Höhe
  frame:SetHeight(body > 0 and (HEADH + body + 4) or HEADH)
  if frame.grip then frame.grip:SetShown(not DB.locked and not DB.collapsed) end
end

function ns.Refresh()
  if not frame then return end
  dirty = false
  local order = ns.order

  -- alle Quests aller Spieler einsammeln, bewerten, filtern
  wipe(list)
  local seen, total, off, hidden = {}, 0, 0, 0
  for _, name in ipairs(order) do
    local p = ns.players[name]
    if p then
      for id in pairs(p.quests) do
        if not seen[id] then
          seen[id] = true
          local qi = ns.qinfo[id] or EMPTY
          local tags = qi.tags or 0
          local e = {
            id = id, title = ns.QuestTitle(id), level = qi.level or 0, tags = tags,
            zone = (qi.zone and qi.zone ~= "") and qi.zone or "Other",
          }
          e.state = RowState(id, band(tags, ns.PERSONAL) > 0)
          e.grank = ns.guide.rank[id] or 99
          e.display = (e.grank == 0 and "|TInterface\\Buttons\\WHITE8X8:9:2:0:0:8:8:0:8:0:8:255:209:0|t " or "") .. LevelTag(e.level, tags) .. e.title
          total = total + 1
          if e.state <= 2 then off = off + 1 end
          if Visible(e) then list[#list + 1] = e else hidden = hidden + 1 end
        end
      end
    end
  end
  local guideOn = GuideOn()
  table.sort(list, function(a, b)
    if DB.groupZone and a.zone ~= b.zone then return a.zone < b.zone end
    if guideOn and a.grank ~= b.grank then return a.grank < b.grank end
    if a.state ~= b.state then return a.state < b.state end
    if a.level ~= b.level then return a.level < b.level end
    return a.title < b.title
  end)
  if DB.groupZone then
    local out, cur = {}, nil
    for _, e in ipairs(list) do
      if e.zone ~= cur then
        cur = e.zone
        out[#out + 1] = { header = true, title = cur }
      end
      out[#out + 1] = e
    end
    list = out
  end

  -- Kopfzeile: pro Spieler Name, Level, XP + Rested; offline = ausgegraut
  frame:SetWidth(PAD * 2 + TITLEW + max(1, #order) * COLW)
  for i = 1, #cols do cols[i]:Hide() end
  wipe(colOnline)
  for i, name in ipairs(order) do
    local p, c = ns.players[name], GetCol(i)
    local unit = ns.units[name]
    colOnline[i] = not unit or UnitIsConnected(unit) and true or false
    local r, g, b = ClassColor(p.class)
    c.name:SetText(Short(name))
    c.name:SetTextColor(r, g, b)
    local lvl = (unit and UnitLevel(unit)) or p.level or 0
    if lvl <= 0 then lvl = p.level or 0 end
    local maxv = (p.xpMax and p.xpMax > 0) and p.xpMax or nil
    if not colOnline[i] then
      c.lvl:SetText("|cff777777offline|r")
    else
      c.lvl:SetText(maxv and format("%d |cff999999%d%%|r", lvl, floor((p.xp or 0) / maxv * 100)) or tostring(lvl))
    end
    c.xp:SetMinMaxValues(0, maxv or 1)
    c.xp:SetValue(p.xp or 0)
    c.xp:SetStatusBarColor(r, g, b)
    c.rest:SetMinMaxValues(0, maxv or 1)
    c.rest:SetValue(min(maxv or 1, (p.xp or 0) + (p.rested or 0)))
    c:SetAlpha(colOnline[i] and 1 or 0.4)
    c:Show()
  end

  local txt = format(total == 1 and "%d quest" or "%d quests", total)
  if off > 0 then txt = txt .. format(" · |cffffbf26%d diff|r", off) end
  if hidden > 0 then txt = txt .. format(" · |cff777777%d hidden|r", hidden) end
  if DB.guideOnly then
    if not ns.guide.loaded then txt = txt .. " · |cffdd4444no RestedXP|r"
    elseif not ns.guide.active then txt = txt .. " · |cff777777no guide|r"
    else txt = txt .. " · |cffffd100guide|r" end
  end
  empty:SetText(GuideOn() and "No quests in current guide steps" or "No quests")
  info:SetText(txt)
  UpdateHearth()

  ns.Render()
end

function ns.MarkDirty()
  dirty = true
  if not frame or pending or not frame:IsShown() then return end
  pending = true
  C_Timer.After(0.2, function()
    pending = false
    if dirty and frame:IsShown() then ns.Refresh() end
  end)
end

function ns.UpdateVisibility()
  if not frame then return end
  frame:SetShown(DB.show and (IsInGroup() or DB.solo) and ns.Active() and true or false)
end

---------------------------------------------------------------- Ready?-Panel
local check, checkLines, checkTimer = nil, {}, nil
local CHECKW = 262

local function BuildCheck()
  check = CreateFrame("Frame", "PartyPaceCheck", UIParent, BackdropTemplateMixin and "BackdropTemplate" or nil)
  Skin(check, 0.9)
  check:SetFrameStrata("MEDIUM")
  check:SetWidth(CHECKW)
  check:EnableMouse(true)
  check:SetScript("OnMouseUp", function(self) self:Hide() end)

  local t = NewText(check, 11)
  t:SetPoint("TOPLEFT", 6, -5)
  t:SetText("|cff33ff99Ready?|r")
  for _, h in ipairs({ { "Bags", 72, 50 }, { "Armor", 124, 46 }, { "Hearth", 172, 58 } }) do
    local fs = NewText(check, 9, "RIGHT")
    fs:SetPoint("TOPLEFT", h[2], -6)
    fs:SetWidth(h[3])
    fs:SetTextColor(0.55, 0.55, 0.55)
    fs:SetText(h[1])
  end
  check:Hide()
end

local function CheckLine(i)
  local l = checkLines[i]
  if l then return l end
  local y = -(20 + (i - 1) * 14)
  l = {
    name = NewText(check, 10),           bag = NewText(check, 10, "RIGHT"),
    dur  = NewText(check, 10, "RIGHT"),  hs  = NewText(check, 10, "RIGHT"),
    ok   = NewText(check, 10, "CENTER"),
  }
  l.name:SetPoint("TOPLEFT", 6, y);   l.name:SetWidth(64)
  l.bag:SetPoint("TOPLEFT", 72, y);   l.bag:SetWidth(50)
  l.dur:SetPoint("TOPLEFT", 124, y);  l.dur:SetWidth(46)
  l.hs:SetPoint("TOPLEFT", 172, y);   l.hs:SetWidth(58)
  l.ok:SetPoint("TOPLEFT", 234, y);   l.ok:SetWidth(24)
  checkLines[i] = l
  return l
end

local function Col(v, red, orange)
  if v <= red then return "|cffdd4444" end
  if v <= orange then return "|cffffaa33" end
  return "|cffffffff"
end

function ns.UpdateCheck()
  if not check or not check:IsShown() then return end
  local n = #ns.order
  for i, name in ipairs(ns.order) do
    local p, l = ns.players[name], CheckLine(i)
    local unit = ns.units[name]
    local r, g, b = ClassColor(p.class)
    l.name:SetText(Short(name))
    l.name:SetTextColor(r, g, b)
    local c = p.check
    if not c then
      l.bag:SetText(""); l.dur:SetText(""); l.hs:SetText("")
      l.ok:SetText(WAIT)
    else
      l.bag:SetText(Col(c.free, 0, 3) .. c.free .. "|r")
      l.dur:SetText(Col(c.dur, 15, 40) .. c.dur .. "%|r")
      if c.hs < 0 then
        l.hs:SetText("|cff777777none|r")
      else
        local left = c.hs - (GetTime() - c.at)
        l.hs:SetText(left <= 0 and "|cff55dd55ready|r" or format("%dm", ceil(left / 60)))
      end
      local dead = unit and UnitIsDeadOrGhost(unit)
      if dead then l.ok:SetText("|cffdd4444dead|r")
      else l.ok:SetText((c.free >= 2 and c.dur > 15) and CHECK or CROSS) end
    end
    for _, fs in pairs(l) do fs:Show() end
  end
  for i = n + 1, #checkLines do for _, fs in pairs(checkLines[i]) do fs:Hide() end end
  check:SetHeight(24 + n * 14)
end

function ns.ShowCheck(fromOther)
  if not check then BuildCheck(); check:HookScript("OnHide", function() LayoutToasts() end) end
  check:SetScale(DB.scale or 1)
  check:ClearAllPoints()
  if frame and frame:IsShown() then
    check:SetPoint("TOPLEFT", frame, "BOTTOMLEFT", 0, -2)
  else
    check:SetPoint("TOP", UIParent, "TOP", 0, -180)
  end
  check:Show()
  ns.UpdateCheck()
  if fromOther then pcall(PlaySound, SOUNDKIT and SOUNDKIT.READY_CHECK or 8960) end
  if checkTimer then checkTimer:Cancel() end
  checkTimer = C_Timer.NewTimer(30, function() check:Hide() end)
end

---------------------------------------------------------------- Kurzmeldungen (Loot-Upgrades, Quest-Hinweise)
local toastBox, toasts, toastPool = nil, {}, {}
local TOAST_TIME, TOAST_MAX, TOASTH = 12, 4, 18

local function ToastEnter(self)
  local t = self.data
  if not t then return end
  GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
  if t.link then GameTooltip:SetHyperlink(t.link) else GameTooltip:AddLine(t.text, 1, 1, 1, true) end
  if t.extra then
    GameTooltip:AddLine(" ")
    for _, l in ipairs(t.extra) do GameTooltip:AddDoubleLine(l[1], l[2], 1, 1, 1, 0.33, 0.87, 0.33) end
  end
  GameTooltip:Show()
end

function LayoutToasts()
  if not toastBox then return end
  toastBox:SetScale(DB.scale or 1)
  toastBox:ClearAllPoints()
  if check and check:IsShown() then
    toastBox:SetPoint("TOPLEFT", check, "BOTTOMLEFT", 0, -2)
  elseif frame:IsShown() then
    toastBox:SetPoint("TOPLEFT", frame, "BOTTOMLEFT", 0, -2)
  else
    toastBox:SetPoint("TOP", UIParent, "TOP", 0, -150)
  end
  local w = max(260, frame:GetWidth())
  toastBox:SetSize(w, max(1, #toasts * (TOASTH + 1)))
  for i, t in ipairs(toasts) do
    local b = t.btn
    b:ClearAllPoints()
    b:SetPoint("TOPLEFT", toastBox, "TOPLEFT", 0, -(i - 1) * (TOASTH + 1))
    b:SetSize(w, TOASTH)
    b.text:SetWidth(w - 10)
    b:Show()
  end
end

local function RemoveToast(t)
  for i, x in ipairs(toasts) do
    if x == t then
      table.remove(toasts, i)
      t.btn:Hide()
      t.btn.data = nil
      toastPool[#toastPool + 1] = t.btn
      if t.timer then t.timer:Cancel() end
      break
    end
  end
  LayoutToasts()
end

function ns.Toast(key, text, link, extra)
  if not frame or not ns.Active() then return end
  if not toastBox then
    toastBox = CreateFrame("Frame", "PartyPaceToasts", UIParent)
    toastBox:SetFrameStrata("MEDIUM")
  end
  local t
  for _, x in ipairs(toasts) do if x.key == key then t = x end end
  if not t then
    if #toasts >= TOAST_MAX then RemoveToast(toasts[1]) end
    local b = tremove(toastPool)
    if not b then
      b = CreateFrame("Button", nil, toastBox, BackdropTemplateMixin and "BackdropTemplate" or nil)
      Skin(b, 0.85)
      b.text = NewText(b, 10)
      b.text:SetPoint("LEFT", 5, 0)
      b:SetScript("OnEnter", ToastEnter)
      b:SetScript("OnLeave", GameTooltip_Hide)
      b:SetScript("OnClick", function(self) if self.data then RemoveToast(self.data) end end)
    end
    t = { key = key, btn = b }
    toasts[#toasts + 1] = t
  end
  t.text, t.link, t.extra = text, link, extra
  t.btn.data = t
  t.btn.text:SetText(text)
  if t.timer then t.timer:Cancel() end
  t.timer = C_Timer.NewTimer(TOAST_TIME, function() t.timer = nil; RemoveToast(t) end)
  LayoutToasts()
end

---------------------------------------------------------------- Ruhestein-Anzeige ("HS 2/3")
local hsBtn, hsTimerAt = nil, nil

local function HearthLeft(p)
  if not p or not p.hsEnd then return nil end -- unbekannt (alte Version)
  if p.hsEnd < 0 then return -1 end
  return max(0, p.hsEnd - GetTime())
end

function UpdateHearth()
  if not hsBtn then return end
  local ready, known, soonest = 0, 0, nil
  for _, key in ipairs(ns.order) do
    local left = HearthLeft(ns.players[key])
    if left and left >= 0 then
      known = known + 1
      if left <= 0 then ready = ready + 1 elseif not soonest or left < soonest then soonest = left end
    end
  end
  local col = (known > 0 and ready == known) and "|cff55dd55" or (ready == 0 and "|cffdd4444" or "|cffffbf26")
  hsBtn.text:SetText(col .. "HS " .. ready .. "/" .. #ns.order .. "|r")
  -- Nächsten Ablauf vormerken, damit die Anzeige ohne Dauer-Update umspringt
  if soonest then
    local at = GetTime() + soonest + 0.5
    if not hsTimerAt or at < hsTimerAt or hsTimerAt < GetTime() then
      hsTimerAt = at
      C_Timer.After(soonest + 0.5, function() hsTimerAt = nil; ns.MarkDirty() end)
    end
  end
end

local function HearthEnter(self)
  GameTooltip:SetOwner(self, "ANCHOR_TOP")
  GameTooltip:AddLine("Hearthstones")
  local maxLeft, binds, sameBind = 0, nil, true
  for _, key in ipairs(ns.order) do
    local p = ns.players[key]
    local left = HearthLeft(p)
    local right
    if left == nil then right = "|cff777777unknown|r"
    elseif left < 0 then right = "|cff777777no hearthstone|r"
    elseif left <= 0 then right = "|cff55dd55ready|r"
    else right = format("%dm", math.ceil(left / 60)); maxLeft = max(maxLeft, left) end
    if p and p.bind and p.bind ~= "" then
      right = right .. " |cff999999· " .. p.bind .. "|r"
      if binds and binds ~= p.bind then sameBind = false end
      binds = binds or p.bind
    end
    local r, g, b = ClassColor(p and p.class)
    GameTooltip:AddDoubleLine(Short(key), right, r, g, b)
  end
  if maxLeft > 0 then GameTooltip:AddLine(format("All ready in %dm", math.ceil(maxLeft / 60)), 0.8, 0.8, 0.8) end
  if binds and not sameBind then GameTooltip:AddLine("Different bind locations!", 1, 0.5, 0.2) end
  GameTooltip:Show()
end

---------------------------------------------------------------- Aufbau
local function Place()
  frame:ClearAllPoints()
  local p = DB.point
  if p then
    frame:SetPoint("TOPLEFT", UIParent, "BOTTOMLEFT", p[1], p[2])
  else
    frame:SetPoint("TOPRIGHT", UIParent, "TOPRIGHT", -260, -240)
  end
end

-- Skalieren, ohne dass das Fenster wegspringt (obere linke Ecke bleibt fix)
-- Spaltenbreite/Zeilenzahl übernehmen und vorhandene Elemente neu ausrichten
local function ApplyLayout()
  TITLEW, MAXROWS = DB.titleW or 170, DB.maxRows or 18
  for i, c in ipairs(cols) do
    c:ClearAllPoints()
    c:SetPoint("TOPLEFT", frame, "TOPLEFT", PAD + TITLEW + (i - 1) * COLW + 1, -3)
  end
  for _, r in ipairs(rows) do
    for i, c in ipairs(r.cells) do
      c:ClearAllPoints()
      c:SetPoint("LEFT", r, "LEFT", TITLEW + (i - 1) * COLW + 1, 0)
    end
  end
  if info then info:SetWidth(TITLEW - 8) end
end

local function BuildGrip()
  local g = CreateFrame("Button", nil, frame)
  g:SetSize(14, 14)
  g:SetPoint("BOTTOMRIGHT", -1, 1)
  g:SetFrameLevel(frame:GetFrameLevel() + 10)
  g:SetNormalTexture("Interface\\ChatFrame\\UI-ChatIM-SizeGrabber-Up")
  g:SetHighlightTexture("Interface\\ChatFrame\\UI-ChatIM-SizeGrabber-Highlight")
  g:SetPushedTexture("Interface\\ChatFrame\\UI-ChatIM-SizeGrabber-Down")
  g:SetAlpha(0.7)
  g:SetScript("OnEnter", function(self)
    GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
    GameTooltip:AddLine("Drag: width of quest names / number of rows", 0.8, 0.8, 0.8)
    GameTooltip:Show()
  end)
  g:SetScript("OnLeave", GameTooltip_Hide)
  g:SetScript("OnMouseDown", function(self, button)
    if button ~= "LeftButton" then return end
    GameTooltip:Hide()
    local s = frame:GetEffectiveScale()
    local cx, cy = GetCursorPosition()
    local start = { x = cx / s, y = cy / s, w = TITLEW, r = MAXROWS }
    sizing = true
    ns.Render()
    -- OnUpdate nur während des Ziehens, danach wieder weg
    self:SetScript("OnUpdate", function()
      local x, y = GetCursorPosition()
      x, y = x / s, y / s
      local w = floor(min(360, max(110, start.w + (x - start.x))))
      local r = floor(min(30, max(4, start.r + (start.y - y) / ROWH + 0.5)))
      if w ~= TITLEW or r ~= MAXROWS then
        DB.titleW, DB.maxRows = w, r
        ApplyLayout()
        ns.Refresh()
      end
    end)
  end)
  g:SetScript("OnMouseUp", function(self)
    self:SetScript("OnUpdate", nil)
    sizing = false
    ns.Render()
  end)
  frame.grip = g
end

local function ResetLayout()
  DB.titleW, DB.maxRows = nil, nil
  ApplyLayout()
  ns.Refresh()
end

local function SetScaleKeepPos(s)
  s = floor(min(2, max(0.5, s)) * 100 + 0.5) / 100
  local l, t, old = frame:GetLeft(), frame:GetTop(), frame:GetScale()
  DB.scale = s
  frame:SetScale(s)
  if check then check:SetScale(s) end
  if toastBox then LayoutToasts() end
  if l and t then
    DB.point = { l * old / s, t * old / s }
    Place()
  end
end

local function Toggle(key)
  return function()
    DB[key] = not DB[key]
    offset = 0
    ns.Refresh()
  end
end

local function IsOn(key) return function() return DB[key] and true or false end end

local function OpenMenu(owner)
  if not MenuUtil then
    DB.collapsed = not DB.collapsed
    ns.Render()
    return
  end
  MenuUtil.CreateContextMenu(owner, function(_, root)
    root:CreateTitle(ns.Brand())
    root:CreateCheckbox("Collapsed", IsOn("collapsed"), function() DB.collapsed = not DB.collapsed; ns.Render() end)
    root:CreateDivider()
    root:CreateTitle("Display")
    root:CreateCheckbox("Group by zone", IsOn("groupZone"), Toggle("groupZone"))
    root:CreateCheckbox("Only differences", IsOn("onlyDiff"), Toggle("onlyDiff"))
    root:CreateCheckbox("Hide completed", IsOn("hideDone"), Toggle("hideDone"))
    root:CreateCheckbox("Hide class quests", IsOn("hideClass"), Toggle("hideClass"))
    root:CreateCheckbox("Hide profession quests", IsOn("hideProf"), Toggle("hideProf"))
    root:CreateCheckbox("Hide camping quests", IsOn("hideCamp"), Toggle("hideCamp"))
    local nh = 0
    for _ in pairs(DB.hiddenQuests) do nh = nh + 1 end
    for _ in pairs(DB.hiddenHeaders) do nh = nh + 1 end
    if nh > 0 then
      root:CreateButton(format("Unhide all (%d)", nh), function()
        wipe(DB.hiddenQuests); wipe(DB.hiddenHeaders); ns.Refresh()
      end)
    end
    root:CreateDivider()
    root:CreateTitle("RestedXP")
    root:CreateCheckbox("Only current guide steps", IsOn("guideOnly"), Toggle("guideOnly"))
    root:CreateCheckbox("Include party's guide steps", IsOn("guideParty"), function()
      DB.guideParty = not DB.guideParty; ns.GuideCheck(true)
    end)
    local ahead = root:CreateButton("Look ahead")
    for _, n in ipairs({ 0, 1, 3, 5, 10 }) do
      ahead:CreateRadio(n == 0 and "Current step only" or (n .. " steps"),
        function(v) return (DB.guideAhead or 3) == v end,
        function(v) DB.guideAhead = v; ns.GuideCheck(true) end, n)
    end
    root:CreateCheckbox("Target macro with ping", IsOn("targetMacro"), function() ns.MacroToggle() end)
    root:CreateDivider()
    root:CreateTitle("Hints")
    root:CreateCheckbox("Loot upgrades (who needs this?)", IsOn("lootHints"), function() DB.lootHints = not DB.lootHints end)
    root:CreateCheckbox("Missing quest hints", IsOn("questHints"), function() DB.questHints = not DB.questHints end)
    root:CreateDivider()
    root:CreateTitle("Sharing")
    root:CreateCheckbox("Auto-share new quests", IsOn("autoShare"), function() DB.autoShare = not DB.autoShare end)
    root:CreateButton("Share missing quests", function() ns.ShareMissing() end)
    root:CreateDivider()
    local raid = root:CreateButton("In raids")
    raid:CreateRadio("Hide", function() return DB.raidMode ~= "group" end,
      function() DB.raidMode = "hide"; ns.UpdateRoster() end)
    raid:CreateRadio("Show my raid group", function() return DB.raidMode == "group" end,
      function() DB.raidMode = "group"; ns.UpdateRoster() end)
    root:CreateCheckbox("Lock window", IsOn("locked"), function() DB.locked = not DB.locked end)
    root:CreateButton("Reset size", function() SetScaleKeepPos(1); ResetLayout() end)
  end)
end

function ns.InitUI()
  DB = ns.DB
  GrabMedia()

  frame = CreateFrame("Frame", "PartyPaceFrame", UIParent, BackdropTemplateMixin and "BackdropTemplate" or nil)
  Skin(frame, 0.8)
  frame:SetFrameStrata("MEDIUM")
  frame:SetClampedToScreen(true)
  frame:SetMovable(true)
  frame:SetScale(DB.scale or 1)
  frame:SetSize(PAD * 2 + TITLEW + COLW, HEADH)
  Place()

  -- Kopfzeile: ziehen = verschieben, Rechtsklick = Menü
  local hdr = CreateFrame("Button", nil, frame)
  hdr:SetPoint("TOPLEFT")
  hdr:SetPoint("TOPRIGHT")
  hdr:SetHeight(HEADH)
  hdr:RegisterForDrag("LeftButton")
  hdr:RegisterForClicks("RightButtonUp")
  hdr:SetScript("OnDragStart", function() if not DB.locked then frame:StartMoving() end end)
  hdr:SetScript("OnDragStop", function()
    frame:StopMovingOrSizing()
    DB.point = { frame:GetLeft(), frame:GetTop() }
    Place()
  end)
  hdr:SetScript("OnClick", function(self) OpenMenu(self) end)

  local title = NewText(frame, 11)
  title:SetPoint("TOPLEFT", PAD + 2, -5)
  title:SetText(ns.Brand())
  info = NewText(frame, 9)
  info:SetPoint("TOPLEFT", title, "BOTTOMLEFT", 0, -2)
  info:SetWidth(TITLEW - 8)
  info:SetTextColor(0.6, 0.6, 0.6)

  -- Ready?-Knopf
  local btn = CreateFrame("Button", nil, frame, BackdropTemplateMixin and "BackdropTemplate" or nil)
  btn:SetSize(46, 14)
  btn:SetPoint("LEFT", title, "RIGHT", 8, 0)
  btn:SetFrameLevel(hdr:GetFrameLevel() + 2)
  Skin(btn, 0.6)
  local bt = NewText(btn, 9, "CENTER")
  bt:SetAllPoints()
  bt:SetText("Ready?")
  btn:SetScript("OnEnter", function(self)
    self:SetBackdropBorderColor(0.2, 1, 0.6, 1)
    GameTooltip:SetOwner(self, "ANCHOR_TOP")
    GameTooltip:AddLine("Ready?")
    GameTooltip:AddLine("Checks bag space, armor and hearthstone for everyone.", 0.8, 0.8, 0.8, true)
    GameTooltip:Show()
  end)
  btn:SetScript("OnLeave", function(self) self:SetBackdropBorderColor(0, 0, 0, 1); GameTooltip:Hide() end)
  btn:SetScript("OnClick", function() ns.RequestCheck() end)

  hsBtn = CreateFrame("Button", nil, frame)
  hsBtn:SetSize(40, 14)
  hsBtn:SetPoint("LEFT", btn, "RIGHT", 4, 0)
  hsBtn:SetFrameLevel(hdr:GetFrameLevel() + 2)
  hsBtn.text = NewText(hsBtn, 9, "CENTER")
  hsBtn.text:SetAllPoints()
  hsBtn:SetScript("OnEnter", HearthEnter)
  hsBtn:SetScript("OnLeave", GameTooltip_Hide)

  local line = frame:CreateTexture(nil, "ARTWORK")
  line:SetColorTexture(0, 0, 0, 1)
  line:SetPoint("TOPLEFT", 1, -HEADH)
  line:SetPoint("TOPRIGHT", -1, -HEADH)
  line:SetHeight(1)

  empty = NewText(frame, 10)
  empty:SetPoint("TOPLEFT", PAD + 6, -(HEADH + 4))
  empty:SetText("No quests")
  empty:SetTextColor(0.5, 0.5, 0.5)
  empty:Hide()

  frame:EnableMouseWheel(true)
  frame:SetScript("OnMouseWheel", function(_, delta)
    if IsControlKeyDown() then
      SetScaleKeepPos(DB.scale + delta * 0.05)
      return
    end
    local o = min(max(0, #list - MAXROWS), max(0, offset - delta))
    if o ~= offset then offset = o; ns.Render() end
  end)
  frame:SetScript("OnShow", function() if dirty then ns.Refresh() end end)
  BuildGrip()
  ApplyLayout()

  frame:Hide()
  ns.UpdateVisibility()
end

---------------------------------------------------------------- Addon-Menü an der Minimap
-- Die Funktionen sind in der TOC eingetragen (AddonCompartmentFunc) und müssen global sein.
function PartyPace_OnCompartmentClick(_, button, menuFrame)
  if button == "RightButton" then
    OpenMenu(menuFrame or frame)
    return
  end
  DB.show = not DB.show
  ns.UpdateVisibility()
  if DB.show and not frame:IsShown() then
    ns.Print(IsInRaid() and "Hidden in raids (menu → In raids)." or "Shows up when you're in a group (/pace solo to always show).")
  end
end

function PartyPace_OnCompartmentEnter(_, menuFrame)
  GameTooltip:SetOwner(menuFrame or UIParent, "ANCHOR_LEFT")
  GameTooltip:AddLine(ns.Brand())
  GameTooltip:AddLine("Left-click: show/hide", 0.8, 0.8, 0.8)
  GameTooltip:AddLine("Right-click: options", 0.8, 0.8, 0.8)
  GameTooltip:Show()
end

function PartyPace_OnCompartmentLeave() GameTooltip:Hide() end

---------------------------------------------------------------- Slash-Befehle
local FILTERS = { zone = "groupZone", diff = "onlyDiff", done = "hideDone", class = "hideClass", prof = "hideProf", camp = "hideCamp" }

SLASH_PARTYPACE1, SLASH_PARTYPACE2 = "/pace", "/partypace"
SlashCmdList.PARTYPACE = function(msg)
  local cmd, arg = (msg or ""):lower():match("^%s*(%S*)%s*(.-)%s*$")
  if cmd == "" then
    DB.show = not DB.show
  elseif FILTERS[cmd] then
    Toggle(FILTERS[cmd])()
    ns.Print(cmd .. ": " .. (DB[FILTERS[cmd]] and "on" or "off"))
  elseif cmd == "ready" or cmd == "check" or cmd == "weiter" then
    ns.RequestCheck()
  elseif cmd == "debug" and arg == "quests" then
    ns.DumpQuests()
    return
  elseif cmd == "debug" then
    -- wer ist bekannt, unter welchem Namen, mit welcher Unit
    ns.Print("Version " .. ns.VERSION .. " · /pace debug quests lists your quest log categories")
    for name, p in pairs(ns.players) do
      ns.Print(format("%s (%s)  unit=%s  synced=%s  v=%s", tostring(p.name), name, tostring(ns.units[name]), tostring(p.synced), tostring(p.version)))
    end
    return
  elseif cmd == "guide" then
    Toggle("guideOnly")()
    if DB.guideOnly and not ns.guide.loaded then ns.Print("RestedXP isn't loaded – showing all quests.") end
    ns.Print("Only current guide steps: " .. (DB.guideOnly and "on" or "off"))
  elseif cmd == "ahead" and tonumber(arg) then
    DB.guideAhead = min(20, max(0, floor(tonumber(arg))))
    ns.GuideCheck(true)
    ns.Print("Guide look-ahead: " .. DB.guideAhead .. " steps")
  elseif cmd == "macro" then
    ns.MacroToggle()
  elseif cmd == "raid" then
    DB.raidMode = DB.raidMode == "group" and "hide" or "group"
    ns.Print("In raids: " .. (DB.raidMode == "group" and "show my raid group" or "hide"))
    ns.UpdateRoster()
  elseif cmd == "unhide" then
    wipe(DB.hiddenQuests); wipe(DB.hiddenHeaders)
    ns.Print("All hidden quests/categories are visible again.")
    ns.Refresh()
  elseif cmd == "share" then
    ns.ShareMissing()
  elseif cmd == "autoshare" then
    DB.autoShare = not DB.autoShare
    ns.Print("Auto-share: " .. (DB.autoShare and "on" or "off"))
  elseif cmd == "solo" then
    DB.solo = not DB.solo
    ns.Print("Show while solo: " .. (DB.solo and "on" or "off"))
  elseif cmd == "lock" then
    DB.locked = not DB.locked
    ns.Print("Window " .. (DB.locked and "locked" or "unlocked"))
  elseif cmd == "scale" and tonumber(arg) then
    SetScaleKeepPos(tonumber(arg))
  elseif cmd == "reset" then
    DB.point = nil
    SetScaleKeepPos(1)
    ResetLayout()
    DB.point = nil
    Place()
  elseif cmd == "sync" then
    ns.SendHello()
    ns.ScheduleFull()
    ns.Print("Sync requested.")
  else
    ns.Print("Commands:")
    ns.Print("  /pace – show/hide · /pace ready – ready check · /pace share – share missing quests")
    ns.Print("  /pace guide – only current RestedXP steps · /pace ahead 3 – guide look-ahead · /pace macro – target macro with ping")
    ns.Print("  /pace zone|diff|done|class|prof|camp – filters · /pace unhide · /pace raid · /pace autoshare")
    ns.Print("  /pace solo · /pace lock · /pace scale 1.1 (or Ctrl+wheel) · /pace reset · /pace sync")
    ns.Print("Right-click the header for the menu.")
    return
  end
  ns.UpdateVisibility()
end
