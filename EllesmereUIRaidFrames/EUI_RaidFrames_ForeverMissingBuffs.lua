if EUI_CLIENT_BLOCKED then return end -- pre-12.1 client failsafe (EllesmereUI_ClientGate.lua)
-------------------------------------------------------------------------------
--  EUI_RaidFrames_ForeverMissingBuffs.lua  (WoW Forever only)
--
--  Missing Buffs indicator: on each raid, party and Extra Frames button, the
--  icon of every group buff the member lacks -- Fortitude, Mark of the Wild,
--  Spirit -- while someone in the group can provide it (a priest, a druid;
--  for Spirit, the player knowing Divine Spirit or any member carrying it,
--  as only priests with the talent cast it). Every rank and the group
--  version count (looked up by name). Settings (Indicators section, same
--  shape as the raid marker): showMissingBuffs, missingBuffsPosition,
--  missingBuffsSize, missingBuffsOffsetX/Y, and the icons' glow on the
--  shared prefix schema (missingBuffsGlow*, EllesmereUI.Glows.PrefixKeys),
--  Forever-only defaults in the main file.
--
--  A member reads as unknown (no icon) while offline or out of sight (the
--  client has no aura data then), and under the game's aura restriction a
--  buff counts only if every rank of it is non-secret (C_Secrets); a secret
--  one would read absent while up, so it shows nothing rather than a false
--  alarm.
--
--  Cost: off everywhere = no events, no overlays. On: UNIT_AURA and
--  UNIT_CONNECTION for the group tokens only, each aura event probing its
--  own added and removed auras against these buffs before a member is
--  looked up again (coalesced to one pass per frame); the roster, the world
--  and the combat edges re-read everyone once. While auras are restricted
--  the payload is secret, so an event re-reads its member only while a buff
--  the group provides stays readable.
--
--  The main file calls ns.RF_FvMissingAnchor from each reload path and
--  ns.RF_FvMissingPreview from the preview pass, the containers file
--  ns.RF_FvMissingUnit from the secure header's unit assignment; on every
--  other client all three stay nil.
-------------------------------------------------------------------------------
local _, ns = ...
local EllesmereUI = _G.EllesmereUI
if not (EllesmereUI and EllesmereUI.IS_FOREVER) then return end

-- One entry per buff, shown in this order. names: spells whose (localized)
-- names cover every rank and the group version; ranks: the player ranks
-- (the restriction test); ids: every spell that applies the buff (ranks,
-- group version, NPC casts) for the aura-event probe.
local FAMILIES = {
    { key = "fort", class = "PRIEST", icon = 1243, names = { 1243, 21562 },
      ranks = { 1243, 1244, 1245, 2791, 10937, 10938, 21562, 21564 },
      ids = { 1243, 1244, 1245, 2791, 10937, 10938, 10939, 10940, 13864, 23947, 23948,
              21562, 21564, 450086 } },
    { key = "mark", class = "DRUID", icon = 1126, names = { 1126, 21849 },
      ranks = { 1126, 5232, 6756, 5234, 8907, 9884, 9885, 21849, 21850 },
      ids = { 1126, 5232, 5234, 5286, 5287, 6756, 8907, 8908, 9884, 9885, 16878, 24752,
              364163, 1291335, 1310503, 21849, 21850 } },
    { key = "spirit", icon = 14752, names = { 14752, 27681 },
      ranks = { 14752, 14818, 14819, 27841, 27681 },
      ids = { 14752, 14818, 14819, 16875, 27841, 27681 } },
}
local NUM_FAMILIES = #FAMILIES
local FAMILY_BY_ID = {}
for i = 1, NUM_FAMILIES do
    for _, id in ipairs(FAMILIES[i].ids) do FAMILY_BY_ID[id] = true end
end

local BANK = Enum.SpellBookSpellBank and Enum.SpellBookSpellBank.Player

-- Per group token: state[unit][key] = true (has it), false (lacks it) or nil
-- (unknown); inst[unit] = the aura instances found, for the removed-aura probe.
local state, inst = {}, {}
local provider = {}      -- key -> a group member can provide it
local playerSpirit = false
local enabled = false
local trusted            -- key -> readable under restriction (built on first use)
local names = {}         -- family index -> { localized names }
local icons = {}         -- family index -> texture

local function SettingsFor(d)
    return d._isParty and ns._scaledPartyProxy or (d._isExtra and ns._scaledExtraProxy) or ns._scaledProfile
end

local function FamilyNames(i)
    local n = names[i]
    if n then return n end
    n = {}
    for _, id in ipairs(FAMILIES[i].names) do
        local name = C_Spell.GetSpellName(id)
        if name then n[#n + 1] = name end
    end
    -- Spell data can be cold this early: keep an empty answer uncached.
    if #n > 0 then names[i] = n end
    return n
end

local function FamilyIcon(i)
    local tex = icons[i]
    if not tex then
        tex = C_Spell.GetSpellTexture(FAMILIES[i].icon)
        icons[i] = tex
    end
    return tex or 134400
end

-- Whether every player rank of a buff stays readable under the aura
-- restriction; built once (the answer is fixed per spell).
local function Trusted(i)
    if not trusted then
        trusted = {}
        local S = C_Secrets
        for fi = 1, NUM_FAMILIES do
            local ok = true
            if S and S.ShouldSpellAuraBeSecret then
                for _, id in ipairs(FAMILIES[fi].ranks) do
                    local good, secret = pcall(S.ShouldSpellAuraBeSecret, id)
                    if not good or issecretvalue(secret) or secret ~= false then ok = false; break end
                end
            end
            trusted[FAMILIES[fi].key] = ok
        end
    end
    return trusted[FAMILIES[i].key]
end

-------------------------------------------------------------------------------
--  Reading a member
-------------------------------------------------------------------------------
local function Evaluate(unit, restricted)
    local st = state[unit]
    if not st then st = {}; state[unit] = st end
    local found = inst[unit]
    if found then wipe(found) else found = {}; inst[unit] = found end
    local known = UnitExists(unit) and UnitIsConnected(unit) and UnitIsVisible(unit)
    for i = 1, NUM_FAMILIES do
        local key = FAMILIES[i].key
        local value
        if known and not (restricted and not Trusted(i)) then
            local list = FamilyNames(i)
            if #list > 0 then
                value = false
                for n = 1, #list do
                    local ok, aura = pcall(C_UnitAuras.GetAuraDataBySpellName, unit, list[n], "HELPFUL")
                    if not ok or issecretvalue(aura) then value = nil; break end
                    if aura then
                        value = true
                        local iid = aura.auraInstanceID
                        if iid and not issecretvalue(iid) then found[iid] = true end
                        break
                    end
                end
            end
        end
        st[key] = value
    end
end

-- A buff with a providing class counts while any member is that class.
local function CheckClass(unit)
    local _, cls = UnitClass(unit)
    if not cls then return end
    for i = 1, NUM_FAMILIES do
        local fam = FAMILIES[i]
        if fam.class == cls then provider[fam.key] = true end
    end
end

local function ScanProviders()
    for i = 1, NUM_FAMILIES do
        local fam = FAMILIES[i]
        if fam.class then provider[fam.key] = false end
    end
    CheckClass("player")
    if IsInRaid() then
        for i = 1, GetNumGroupMembers() do CheckClass("raid" .. i) end
    else
        for i = 1, 4 do
            if UnitExists("party" .. i) then CheckClass("party" .. i) end
        end
    end
    playerSpirit = false
    if BANK and C_SpellBook.IsSpellInSpellBook then
        for _, id in ipairs(FAMILIES[3].ranks) do
            if C_SpellBook.IsSpellInSpellBook(id, BANK, true) then playerSpirit = true; break end
        end
    end
end

-- Spirit has a provider while the player knows Divine Spirit or any member
-- carries it (only priests with the talent cast it). True when it flipped.
local function SyncSpiritProvider()
    local on = playerSpirit
    if not on then
        for _, st in pairs(state) do
            if st.spirit == true then on = true; break end
        end
    end
    if on ~= (provider.spirit == true) then
        provider.spirit = on
        return true
    end
    return false
end

-------------------------------------------------------------------------------
--  Overlay
-------------------------------------------------------------------------------
local function Overlay(host, level)
    local o = CreateFrame("Frame", nil, host)
    o:SetFrameLevel(level)
    o:EnableMouse(false)
    o.slots = {}
    for i = 1, NUM_FAMILIES do
        local bg = o:CreateTexture(nil, "ARTWORK", nil, 0)
        bg:SetColorTexture(0, 0, 0, 1)
        local tex = o:CreateTexture(nil, "ARTWORK", nil, 1)
        tex:SetTexCoord(0.08, 0.92, 0.08, 0.92)
        bg:Hide(); tex:Hide()
        o.slots[i] = { bg = bg, tex = tex }
    end
    o:Hide()
    return o
end

-- The icons' glow (prefix keys missingBuffsGlow*, style 0 = none): one host
-- per shown icon. Every icon that goes, and every overlay that hides, stops
-- its glow, so nothing hidden stays in the shared glow driver.
local glowSpec = {}
local NO_SHAPE = { [4] = true } -- Shape Glow follows an icon shape; these cells have none

local function StopGlows(o, from)
    for i = from, NUM_FAMILIES do
        local g = o.slots[i].glow
        if g and g.fvOn then
            EllesmereUI.Glows.StopGlow(g)
            g.fvOn = nil
        end
    end
end

local function HideOverlay(o)
    StopGlows(o, 1)
    o:Hide()
end

local function ApplyGlows(o, s, n, size)
    local G = EllesmereUI.Glows
    local spec = G.SpecFromPrefix(glowSpec, s, "missingBuffsGlow")
    if not spec then
        StopGlows(o, 1)
        return
    end
    spec.excludes = NO_SHAPE
    for i = 1, n do
        local slot = o.slots[i]
        local g = slot.glow
        if not g then
            g = CreateFrame("Frame", nil, o)
            g:SetAllPoints(slot.bg)
            g:SetFrameLevel(o:GetFrameLevel() + 2)
            g:EnableMouse(false)
            slot.glow = g
        end
        G.StartSpecGlow(g, spec, size, size, "icon")
        g.fvOn = true
    end
    StopGlows(o, n + 1)
end

-- Lays out n icons (the family indices in list) at the configured position:
-- the overlay is exactly as wide as its icons, so a right-side position grows
-- leftward and a centred one stays centred. Same 9-point spots and edge inset
-- as the raid marker.
local function Layout(o, s, health, list, n)
    local snap = ns.PixelSnap or function(v) return v end
    local size = snap(s.missingBuffsSize or 22)
    -- One physical pixel: the icon edge and the gap between icons.
    local edge = snap(1)
    if edge <= 0 then edge = 1 end
    for i = 1, NUM_FAMILIES do
        local slot = o.slots[i]
        if i <= n then
            local x = (i - 1) * (size + edge)
            slot.bg:ClearAllPoints()
            slot.bg:SetPoint("TOPLEFT", o, "TOPLEFT", x, 0)
            slot.bg:SetSize(size, size)
            slot.tex:ClearAllPoints()
            slot.tex:SetPoint("TOPLEFT", slot.bg, "TOPLEFT", edge, -edge)
            slot.tex:SetPoint("BOTTOMRIGHT", slot.bg, "BOTTOMRIGHT", -edge, edge)
            slot.tex:SetTexture(FamilyIcon(list[i]))
            slot.bg:Show(); slot.tex:Show()
        else
            slot.bg:Hide(); slot.tex:Hide()
        end
    end
    if n == 0 then HideOverlay(o) return end
    o:SetSize(n * size + (n - 1) * edge, size)
    local host = ns.RF_AnchorHost(health, s)
    local pos = s.missingBuffsPosition or "top"
    local ox, oy = s.missingBuffsOffsetX or 0, s.missingBuffsOffsetY or 0
    o:ClearAllPoints()
    if pos == "topleft" then
        o:SetPoint("TOPLEFT", host, "TOPLEFT", 2 + ox, -2 + oy)
    elseif pos == "top" then
        o:SetPoint("TOP", host, "TOP", ox, -2 + oy)
    elseif pos == "topright" then
        o:SetPoint("TOPRIGHT", host, "TOPRIGHT", -2 + ox, -2 + oy)
    elseif pos == "left" then
        o:SetPoint("LEFT", host, "LEFT", 2 + ox, oy)
    elseif pos == "right" then
        o:SetPoint("RIGHT", host, "RIGHT", -2 + ox, oy)
    elseif pos == "bottomleft" then
        o:SetPoint("BOTTOMLEFT", host, "BOTTOMLEFT", 2 + ox, 2 + oy)
    elseif pos == "bottom" then
        o:SetPoint("BOTTOM", host, "BOTTOM", ox, 2 + oy)
    elseif pos == "bottomright" then
        o:SetPoint("BOTTOMRIGHT", host, "BOTTOMRIGHT", -2 + ox, 2 + oy)
    else
        o:SetPoint("CENTER", host, "CENTER", ox, oy)
    end
    ApplyGlows(o, s, n, size)
    o:Show()
end

local paintList = {}
local function PaintButton(btn, d)
    if not d.health then return end
    local s = SettingsFor(d)
    local on = enabled and s and s.showMissingBuffs ~= false
    local o = d.fvMissing
    if not on then
        if o then HideOverlay(o) end
        return
    end
    local unit = btn:GetAttribute("unit")
    local st = unit and state[unit]
    local n = 0
    if st then
        for i = 1, NUM_FAMILIES do
            local key = FAMILIES[i].key
            if st[key] == false and provider[key] then
                n = n + 1
                paintList[n] = i
            end
        end
    end
    if n == 0 and not o then return end
    if not o then
        o = Overlay(btn, btn:GetFrameLevel() + ns.LVL_MARKER)
        d.fvMissing = o
    end
    Layout(o, s, d.health, paintList, n)
end

local function PaintUnit(unit)
    local GetFFD = ns.GetFFD
    local b = ns._raidUnitToButton and ns._raidUnitToButton[unit]
    if b then PaintButton(b, GetFFD(b)) end
    b = ns._partyUnitToButton and ns._partyUnitToButton[unit]
    if b then PaintButton(b, GetFFD(b)) end
    b = ns._xfUnitToButton and ns._xfUnitToButton[unit]
    if b then PaintButton(b, GetFFD(b)) end
end

local function PaintList(list)
    if not list then return end
    local GetFFD = ns.GetFFD
    for i = 1, #list do
        local b = list[i]
        PaintButton(b, GetFFD(b))
    end
end

local function PaintAll()
    PaintList(ns._allButtons)          -- raid + Extra Frames
    PaintList(ns._partyAllButtons)
end

local function Mapped(unit)
    return (ns._raidUnitToButton and ns._raidUnitToButton[unit])
        or (ns._partyUnitToButton and ns._partyUnitToButton[unit])
        or (ns._xfUnitToButton and ns._xfUnitToButton[unit])
end

-------------------------------------------------------------------------------
--  Passes (one per frame)
-------------------------------------------------------------------------------
-- dirty: members to look up again; pendingBtns: buttons that took a new unit
-- (painted directly: the unit maps may not have caught up with them yet).
local dirty, pendingBtns, flushArmed, fullArmed = {}, {}, false, false

-- Full pass: every button's own unit, read off the button itself.
local function EvaluateList(list, restricted)
    if not list then return end
    for i = 1, #list do
        local unit = list[i]:GetAttribute("unit")
        if unit and not state[unit] then Evaluate(unit, restricted) end
    end
end

local function Flush()
    flushArmed = false
    if not enabled then wipe(dirty); wipe(pendingBtns); fullArmed = false; return end
    local restricted = EllesmereUI.AuraKit.AurasRestricted()
    local full = fullArmed
    fullArmed = false
    if full then
        wipe(dirty); wipe(pendingBtns)
        ScanProviders()
        wipe(state); wipe(inst)
        EvaluateList(ns._allButtons, restricted)
        EvaluateList(ns._partyAllButtons, restricted)
        SyncSpiritProvider()
        PaintAll()
        return
    end
    for unit in pairs(dirty) do Evaluate(unit, restricted) end
    if SyncSpiritProvider() then
        PaintAll()
    else
        for unit in pairs(dirty) do PaintUnit(unit) end
        local GetFFD = ns.GetFFD
        for b in pairs(pendingBtns) do PaintButton(b, GetFFD(b)) end
    end
    wipe(dirty); wipe(pendingBtns)
end

local function Arm()
    if flushArmed then return end
    flushArmed = true
    C_Timer.After(0, Flush)
end

local function MarkDirty(unit)
    dirty[unit] = true
    Arm()
end

local function MarkAll()
    fullArmed = true
    Arm()
end

-------------------------------------------------------------------------------
--  Events (registered only while the indicator is on somewhere)
-------------------------------------------------------------------------------
-- The payload is secret while auras are restricted (UNIT_AURA is
-- SecretWhenAurasRestricted): nothing in it can be read, so the member is
-- looked up again, but only while a buff the group provides stays readable
-- under the restriction. The rest read unknown until it lifts, and the
-- combat edges re-read everyone then.
local function Unprobeable(unit)
    for i = 1, NUM_FAMILIES do
        if provider[FAMILIES[i].key] and Trusted(i) then MarkDirty(unit) return end
    end
end

-- Probe the payload first: only an added or removed Missing Buffs aura
-- sends the member back for a look-up; a full update always does.
local function OnUnitAura(unit, info)
    if not Mapped(unit) then return end
    if not info then MarkDirty(unit) return end
    if issecretvalue(info) then Unprobeable(unit) return end
    local full = info.isFullUpdate
    if issecretvalue(full) then Unprobeable(unit) return end
    if full then MarkDirty(unit) return end
    local added = info.addedAuras
    if added then
        if issecretvalue(added) then Unprobeable(unit) return end
        for i = 1, #added do
            local aura = added[i]
            if issecretvalue(aura) then Unprobeable(unit) return end
            local sid = aura.spellId
            if issecretvalue(sid) then Unprobeable(unit) return end
            if sid and FAMILY_BY_ID[sid] then MarkDirty(unit) return end
        end
    end
    local removed, found = info.removedAuraInstanceIDs, inst[unit]
    if removed and found and next(found) then
        if issecretvalue(removed) then Unprobeable(unit) return end
        for i = 1, #removed do
            local iid = removed[i]
            if issecretvalue(iid) then Unprobeable(unit) return end
            if found[iid] then MarkDirty(unit) return end
        end
    end
end

local function OnTrackerEvent(_, event, unit, info)
    if event == "UNIT_AURA" then
        OnUnitAura(unit, info)
    elseif Mapped(unit) then
        MarkDirty(unit)
    end
end

-- RegisterUnitEvent takes two units: the 45 group tokens ride 23 frames
-- (built here, so their events bill this module; registered only while on).
local TOKENS = { "player" }
for i = 1, 4 do TOKENS[#TOKENS + 1] = "party" .. i end
for i = 1, 40 do TOKENS[#TOKENS + 1] = "raid" .. i end
local trackers = {}
for i = 1, #TOKENS, 2 do
    local f = CreateFrame("Frame")
    f._u1, f._u2 = TOKENS[i], TOKENS[i + 1]
    f:SetScript("OnEvent", OnTrackerEvent)
    trackers[#trackers + 1] = f
end

-- A restriction edge matters only while some buff cannot be read under it.
local function AnyUntrusted()
    for i = 1, NUM_FAMILIES do
        if not Trusted(i) then return true end
    end
    return false
end

local world = CreateFrame("Frame")
world:SetScript("OnEvent", function(_, event)
    if event == "SPELLS_CHANGED" then
        -- Only Divine Spirit being learned or unlearned (priests) changes anything.
        local was = playerSpirit
        ScanProviders()
        if playerSpirit ~= was and SyncSpiritProvider() then PaintAll() end
    elseif event == "PLAYER_REGEN_DISABLED" or event == "PLAYER_REGEN_ENABLED" then
        if AnyUntrusted() then MarkAll() end
    else
        MarkAll()
    end
end)

local function SetEvents(on)
    for i = 1, #trackers do
        local f = trackers[i]
        if on then
            f:RegisterUnitEvent("UNIT_AURA", f._u1, f._u2)
            f:RegisterUnitEvent("UNIT_CONNECTION", f._u1, f._u2)
        else
            f:UnregisterAllEvents()
        end
    end
    if on then
        world:RegisterEvent("GROUP_ROSTER_UPDATE")
        -- World and instance changes (the restriction follows instances).
        world:RegisterEvent("PLAYER_ENTERING_WORLD")
        world:RegisterEvent("PLAYER_REGEN_DISABLED")
        world:RegisterEvent("PLAYER_REGEN_ENABLED")
        if select(2, UnitClass("player")) == "PRIEST" then
            world:RegisterEvent("SPELLS_CHANGED")
        end
    else
        world:UnregisterAllEvents()
    end
end

-- On anywhere: the raid, party or Extra Frames settings.
local function Wanted()
    local r = ns._scaledProfile
    if r and r.showMissingBuffs ~= false then return true end
    local p = ns._scaledPartyProxy
    if p and p.showMissingBuffs ~= false then return true end
    local x = ns._scaledExtraProxy
    return (x and x.showMissingBuffs ~= false) and true or false
end

local syncArmed = false
local function Sync()
    syncArmed = false
    local want = Wanted()
    if want == enabled then return end
    enabled = want
    SetEvents(want)
    if want then
        MarkAll()
    else
        wipe(state); wipe(inst); wipe(dirty); wipe(pendingBtns)
        PaintAll()
    end
end

-------------------------------------------------------------------------------
--  Main-file hooks
-------------------------------------------------------------------------------
-- Each reload path, per button: re-lay the icons from what is known (no
-- look-ups), then settle the on/off state once for the whole pass.
function ns.RF_FvMissingAnchor(btn, d)
    PaintButton(btn, d)
    if not syncArmed then
        syncArmed = true
        C_Timer.After(0, Sync)
    end
end

-- The secure header's unit assignment (every roster re-process, same unit
-- included): only a button whose unit really changed looks its member up.
function ns.RF_FvMissingUnit(btn, d, unit)
    if not enabled or d._fvUnit == unit then return end
    d._fvUnit = unit
    if not unit then
        -- An emptied button hides: its glows leave the driver with it.
        if d.fvMissing then HideOverlay(d.fvMissing) end
        return
    end
    pendingBtns[btn] = true
    MarkDirty(unit)
end

-- Options preview: a fixed spread of missing buffs while the indicators
-- preview (the Indicators eye) is on.
local PREVIEW = {
    [2] = { 1 }, [4] = { 1, 2 }, [7] = { 3 }, [9] = { 1, 2, 3 },
    [12] = { 2 }, [15] = { 1, 3 }, [18] = { 1 },
}
function ns.RF_FvMissingPreview(f, index, s, indVis)
    local list = indVis and s.showMissingBuffs ~= false and f._health and PREVIEW[index]
    local o = f._fvMissing
    if not list then
        if o then HideOverlay(o) end
        return
    end
    if not o then
        o = Overlay(f, f:GetFrameLevel() + ns.LVL_MARKER)
        f._fvMissing = o
    end
    Layout(o, s, f._health, list, #list)
end

-- First look once the world is up (the reload paths may not run at login).
local boot = CreateFrame("Frame")
boot:RegisterEvent("PLAYER_ENTERING_WORLD")
boot:SetScript("OnEvent", function(self)
    self:UnregisterAllEvents()
    Sync()
end)
