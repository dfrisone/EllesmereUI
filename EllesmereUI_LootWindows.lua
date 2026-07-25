-------------------------------------------------------------------------------
--  EllesmereUI_LootWindows.lua
--  Offscreen rescue for the two Blizzard windows that carry a loot decision:
--  BonusRollFrame and GroupLootContainer (the parent of GroupLootFrame1-N).
--
--  Both are placed by Blizzard's UIParent managed-frame-position pass, which
--  measures the bottom-anchored UI stack. EllesmereUIActionBars empties that
--  stack: MainMenuBar / StanceBar / PetActionBar are reparented away and
--  hidden, ActionBarParent and StatusTrackingBarManager are hidden, and
--  ExtraAbilityContainer / PlayerPowerBarAlt are reparented into EUI holders
--  with ignoreFramePositionManager set. A pass that resolves against those
--  frames can land either window past the screen edge, where it is shown and
--  fully functional but invisible -- the roll timer runs out without the
--  player ever seeing it. Zoning re-runs the pass and the window "comes
--  back", which is exactly what makes the bug read as intermittent.
--
--  The rescue is deliberately narrow. It fires only for a window that is
--  SHOWN with its centre off UIParent, and it moves that window only to the
--  same default the Shifter loot movers use. ignoreFramePositionManager (the
--  sanctioned per-frame opt-out) holds the rescue while the window is up and
--  clears on hide, so a healthy Blizzard pass takes ownership again on the
--  next show. Windows the user placed through the Shifter loot movers are
--  left alone, and protected or forbidden frames are never touched.
--
--  /euiloot dumps the whole loot-decision chain (both windows, the roll
--  frames, the alert anchor, and the bottom-stack frames the pass measures)
--  so one screenshot taken while the rolls are missing says whether they were
--  positioned off screen or never shown at all.
-------------------------------------------------------------------------------
local EUI = _G.EllesmereUI or {}
_G.EllesmereUI = EUI

local WINDOWS = {
    { name = "BonusRollFrame",     defY = 240 },
    { name = "GroupLootContainer", defY = 340 },
}

-- UIParent units the frame's centre must clear on every side.
local EDGE_MARGIN = 8

local rescued = {}
local hooked  = {}
local pending = {}
local writing = {}

-- The live frame, only when repositioning it is safe.
local function SafeFrame(name)
    local frame = _G[name]
    if not frame or not frame.HookScript then return nil end
    if frame.IsForbidden and frame:IsForbidden() then return nil end
    if frame:IsProtected() then return nil end
    return frame
end

-- A Shifter loot mover with a saved position outranks the rescue.
local function ShifterOwns(name)
    local db = EllesmereUIDB
    if not db or not db.shifterLootUnlock then return false end
    return db.shifterLootPositions and db.shifterLootPositions[name] ~= nil
end

-- Centre of the frame in UIParent units. nil = no resolvable rect at all
-- (a broken anchor family), which is always a rescue case.
local function Centre(frame)
    local l, r = frame:GetLeft(), frame:GetRight()
    local t, b = frame:GetTop(), frame:GetBottom()
    if not (l and r and t and b) then return nil end
    local ratio = frame:GetEffectiveScale() / UIParent:GetEffectiveScale()
    return (l + r) * 0.5 * ratio, (t + b) * 0.5 * ratio
end

local function IsOnScreen(frame)
    local cx, cy = Centre(frame)
    if not cx then return false end
    local ul = UIParent:GetLeft() or 0
    local ub = UIParent:GetBottom() or 0
    local uw, uh = UIParent:GetWidth(), UIParent:GetHeight()
    if cx < ul + EDGE_MARGIN or cx > ul + uw - EDGE_MARGIN then return false end
    if cy < ub + EDGE_MARGIN or cy > ub + uh - EDGE_MARGIN then return false end
    return true
end

local function Check(info)
    if ShifterOwns(info.name) then return end
    local frame = SafeFrame(info.name)
    if not frame or not frame:IsShown() then return end
    -- Someone else already opted this window out of the managed pass: they
    -- own the position, including a deliberate park off screen.
    if frame.ignoreFramePositionManager and not rescued[info.name] then return end
    if IsOnScreen(frame) then return end
    writing[info.name] = true
    frame.ignoreFramePositionManager = true
    frame:ClearAllPoints()
    frame:SetPoint("BOTTOM", UIParent, "BOTTOM", 0, info.defY)
    writing[info.name] = nil
    rescued[info.name] = true
end

-- Blizzard re-anchors these on show and again as rolls are added, so every
-- check runs one tick late (coalesced) to read the settled position.
local function CheckSoon(info)
    if pending[info.name] then return end
    pending[info.name] = true
    C_Timer.After(0, function()
        pending[info.name] = nil
        Check(info)
    end)
end

local function Release(info)
    if not rescued[info.name] then return end
    rescued[info.name] = nil
    if ShifterOwns(info.name) then return end
    local frame = SafeFrame(info.name)
    if frame then frame.ignoreFramePositionManager = nil end
end

local function Hook(info)
    if hooked[info.name] then return end
    local frame = SafeFrame(info.name)
    if not frame then return end
    hooked[info.name] = true
    hooksecurefunc(frame, "SetPoint", function()
        if writing[info.name] then return end
        CheckSoon(info)
    end)
    frame:HookScript("OnShow", function() CheckSoon(info) end)
    frame:HookScript("OnHide", function() Release(info) end)
    if frame:IsShown() then CheckSoon(info) end
end

local eventFrame = CreateFrame("Frame")
eventFrame:RegisterEvent("PLAYER_LOGIN")
eventFrame:RegisterEvent("PLAYER_ENTERING_WORLD")
eventFrame:SetScript("OnEvent", function()
    for i = 1, #WINDOWS do Hook(WINDOWS[i]) end
end)

-------------------------------------------------------------------------------
--  /euiloot -- read-only state dump for the loot-decision chain.
-------------------------------------------------------------------------------
do
    local function P(msg) print("|cff0cd29fEUI Loot|r " .. msg) end

    local function NameOf(obj)
        if not obj then return "nil" end
        local ok, name = pcall(obj.GetName, obj)
        if ok and name then return name end
        return "<anon>"
    end

    local function PointsOf(frame)
        local ok, n = pcall(frame.GetNumPoints, frame)
        if not ok or not n or n == 0 then return "NO POINTS" end
        local parts = {}
        for i = 1, n do
            local ok2, p, rel, rp, x, y = pcall(frame.GetPoint, frame, i)
            if ok2 and p then
                parts[#parts + 1] = ("%s->%s.%s %d,%d"):format(p, NameOf(rel),
                    tostring(rp), math.floor((x or 0) + 0.5), math.floor((y or 0) + 0.5))
            end
        end
        if #parts == 0 then return "UNREADABLE" end
        return table.concat(parts, " | ")
    end

    local function Dump(name, tag)
        local frame = _G[name]
        if not frame then P(("%s%s: MISSING"):format(name, tag or "")) return end
        if frame.IsForbidden and frame:IsForbidden() then
            P(("%s%s: FORBIDDEN"):format(name, tag or "")) return
        end
        local shown   = frame.IsShown and frame:IsShown()
        local visible = frame.IsVisible and frame:IsVisible()
        local alpha   = frame.GetAlpha and frame:GetAlpha() or -1
        local cx, cy  = Centre(frame)
        local where   = "rect=UNRESOLVED"
        if cx then
            where = ("centre=%d,%d onscreen=%s size=%dx%d"):format(
                math.floor(cx + 0.5), math.floor(cy + 0.5),
                tostring(IsOnScreen(frame)),
                math.floor((frame:GetWidth() or 0) + 0.5),
                math.floor((frame:GetHeight() or 0) + 0.5))
        end
        P(("%s%s shown=%s visible=%s alpha=%.2f parent=%s strata=%s"):format(
            name, tag or "", tostring(shown), tostring(visible), alpha,
            NameOf(frame:GetParent()), tostring(frame.GetFrameStrata and frame:GetFrameStrata())))
        P(("   %s  ignoreFPM=%s euiRescued=%s protected=%s"):format(
            where, tostring(frame.ignoreFramePositionManager),
            tostring(rescued[name] or false), tostring(frame:IsProtected())))
        P("   " .. PointsOf(frame))
    end

    SLASH_EUILOOT1 = "/euiloot"
    SlashCmdList.EUILOOT = function()
        P(("== UIParent %dx%d  scale=%.3f  combat=%s =="):format(
            math.floor(UIParent:GetWidth() + 0.5), math.floor(UIParent:GetHeight() + 0.5),
            UIParent:GetEffectiveScale(), tostring(InCombatLockdown())))

        Dump("GroupLootContainer")
        Dump("BonusRollFrame")

        local anyRoll = false
        for i = 1, 10 do
            local rollName = "GroupLootFrame" .. i
            local frame = _G[rollName]
            if frame then
                if frame.IsShown and frame:IsShown() then
                    anyRoll = true
                    Dump(rollName, (" rollID=%s"):format(tostring(frame.rollID)))
                end
            end
        end
        if not anyRoll then P("GroupLootFrameN: none shown") end

        Dump("GroupLootHistoryFrame")
        local loadedHistory = C_AddOns and C_AddOns.IsAddOnLoaded
            and C_AddOns.IsAddOnLoaded("Blizzard_GroupLootHistoryFrame")
        P("Blizzard_GroupLootHistoryFrame loaded=" .. tostring(loadedHistory))

        local okCount, count = pcall(function() return C_LootHistory.GetNumItems() end)
        P("C_LootHistory items=" .. (okCount and tostring(count) or "unreadable"))

        -- The bottom stack the managed-position pass measures.
        Dump("AlertFrame")
        Dump("ExtraAbilityContainer")
        Dump("MainMenuBar")

        local db = EllesmereUIDB
        local saved = {}
        if db and db.shifterLootPositions then
            for k, v in pairs(db.shifterLootPositions) do
                saved[#saved + 1] = ("%s(%s %d,%d)"):format(k, tostring(v.point),
                    math.floor((v.x or 0) + 0.5), math.floor((v.y or 0) + 0.5))
            end
        end
        P(("shifterLootUnlock=%s saved=%s"):format(
            tostring(db and db.shifterLootUnlock or false),
            #saved > 0 and table.concat(saved, " ") or "none"))
    end
end
