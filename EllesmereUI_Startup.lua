-------------------------------------------------------------------------------
--  EllesmereUI_Startup.lua
--  Runs as early as possible (first file after the Lite framework).
--  Applies settings that the WoW engine caches at login time, before
--  other addon files or PLAYER_LOGIN handlers have a chance to run.
-------------------------------------------------------------------------------
local ADDON_NAME = ...

-------------------------------------------------------------------------------
--  Pixel-Perfect UI Scale
--
--  SavedVariables (EllesmereUIDB) aren't available at file scope — they load
--  at ADDON_LOADED. So we use events:
--    ADDON_LOADED  -> DB is available. If we have a saved scale, apply it.
--    PLAYER_ENTERING_WORLD -> Blizzard has applied the user's CVar scale.
--                    If no saved scale yet (first install / reset), snapshot
--                    the user's current Blizzard scale and save it.
-------------------------------------------------------------------------------
do
    local GetPhysicalScreenSize = GetPhysicalScreenSize
    local dbReady = false
    local scaleKnown = false   -- true when ppUIScale was already saved

    local function ApplyScaleSafe(scale)
        if InCombatLockdown() then
            local f = CreateFrame("Frame")
            f:RegisterEvent("PLAYER_REGEN_ENABLED")
            f:SetScript("OnEvent", function(self)
                self:UnregisterEvent("PLAYER_REGEN_ENABLED")
                UIParent:SetScale(scale)
                if EllesmereUI and EllesmereUI.PP and EllesmereUI.PP.UpdateMult then
                    EllesmereUI.PP.UpdateMult()
                end
            end)
        else
            UIParent:SetScale(scale)
            if EllesmereUI and EllesmereUI.PP and EllesmereUI.PP.UpdateMult then
                EllesmereUI.PP.UpdateMult()
            end
        end
    end

    local function SyncMultOnly()
        if EllesmereUI and EllesmereUI.PP then
            if EllesmereUI.PP.UpdateMult then EllesmereUI.PP.UpdateMult() end
            if EllesmereUI.PP.ResnapAllBorders then EllesmereUI.PP.ResnapAllBorders() end
        end
    end

    local scaleFrame = CreateFrame("Frame")
    scaleFrame:RegisterEvent("ADDON_LOADED")
    scaleFrame:RegisterEvent("PLAYER_LOGIN")
    scaleFrame:RegisterEvent("PLAYER_ENTERING_WORLD")
    scaleFrame:SetScript("OnEvent", function(self, event, addonName)
        if event == "ADDON_LOADED" then
            if addonName ~= ADDON_NAME then return end
            self:UnregisterEvent("ADDON_LOADED")
            dbReady = true

            if not EllesmereUIDB then EllesmereUIDB = {} end

            local _, physH = GetPhysicalScreenSize()
            local perfect = 768 / physH
            local function PixelBestSize()
                return max(0.4, min(perfect, 1.15))
            end

            if EllesmereUIDB.ppUIScale then
                -- Migrate 0.53 to exact pixel-perfect 0.5333... (768/1440)
                if EllesmereUIDB.ppUIScale == 0.53 then
                    EllesmereUIDB.ppUIScale = 0.5333333333
                -- Migrate 0.71 to exact pixel-perfect 0.7111... (768/1080)
                elseif EllesmereUIDB.ppUIScale == 0.71 then
                    EllesmereUIDB.ppUIScale = 0.7111111111
                end
                scaleKnown = true
            end

        elseif event == "PLAYER_LOGIN" then
            self:UnregisterEvent("PLAYER_LOGIN")

            if scaleKnown and EllesmereUIDB.ppUIScale then
                -- Returning user: single SetScale at PLAYER_LOGIN.
                -- No timers, no repeated calls.
                ApplyScaleSafe(EllesmereUIDB.ppUIScale)

                -- Re-apply our scale whenever Blizzard fires UI_SCALE_CHANGED
                -- (zone transitions, CVar resets, resolution changes).
                self:RegisterEvent("UI_SCALE_CHANGED")
                return
            end

            -- First-time path: just sync mult for child addon OnEnable
            if EllesmereUI and EllesmereUI.PP and EllesmereUI.PP.UpdateMult then
                EllesmereUI.PP.UpdateMult()
            end

        elseif event == "UI_SCALE_CHANGED" then
            local saved = EllesmereUIDB and EllesmereUIDB.ppUIScale
            if saved then
                ApplyScaleSafe(saved)
                SyncMultOnly()
            end
            return

        elseif event == "PLAYER_ENTERING_WORLD" then
            self:UnregisterEvent("PLAYER_ENTERING_WORLD")

            if not dbReady then return end
            if not EllesmereUIDB then EllesmereUIDB = {} end

            -- Returning user: scale was applied once at PLAYER_LOGIN,
            -- nothing else needed.
            if scaleKnown then return end

            -- First install or reset: snapshot the user's Blizzard scale
            if EllesmereUIDB.ppUIScale == nil then
                local blizzScale = UIParent:GetScale()
                local clamped = max(0.4, min(blizzScale, 1.15))
                EllesmereUIDB.ppUIScale = clamped
                EllesmereUIDB.ppUIScaleAuto = false
            end

            local scale = EllesmereUIDB.ppUIScale
            if not scale then return end

            -- First-time install: apply scale with safety net.
            -- Apply scale multiple times to guarantee it sticks even on
            -- slow machines where Blizzard may reset it during init.
            if EllesmereUI and EllesmereUI.PP and EllesmereUI.PP.UpdateMult then
                EllesmereUI.PP.UpdateMult()
            end
            ApplyScaleSafe(scale)
            C_Timer.After(2, function()
                if InCombatLockdown() then return end
                if EllesmereUIDB and EllesmereUIDB.ppUIScale then
                    ApplyScaleSafe(EllesmereUIDB.ppUIScale)
                end
                SyncMultOnly()
            end)
            C_Timer.After(5, function()
                if InCombatLockdown() then return end
                if EllesmereUIDB and EllesmereUIDB.ppUIScale then
                    ApplyScaleSafe(EllesmereUIDB.ppUIScale)
                end
                SyncMultOnly()
            end)
        end
    end)
end

-------------------------------------------------------------------------------
--  Undocked chat window position fix
--
--  Root cause (proven by field /euichatfix drift capture, 2026-07-28): the
--  ENGINE's user-placed layout cache, not Blizzard's chat-cache ratios. The
--  chat-cache save/restore (FCF_SavePositionAndDimensions / _Restore...) is
--  self-consistent -- GetScreenWidth/Height track UIParent's actual scale, so
--  its ratios always decode to the exact dropped position. But the restore
--  marks the frame SetUserPlaced(true), so the engine ALSO persists it in
--  layout-local: at logout it converts the anchor offsets out of UIParent
--  units using UIParent's CURRENT scale (our pixel-perfect SetScale value),
--  and at next login it converts back BEFORE our PLAYER_LOGIN SetScale runs,
--  i.e. with Blizzard's CVar scale -- and it applies AFTER the correct
--  chat-cache restore, so it is the last writer. Net effect: both offsets
--  multiply by (euiScale / cvarScale) every session. Field capture: CF4
--  offsets (9.9, 225.6) -> (8.2, 188.0), exactly x0.8333 = 0.5333/0.64, a
--  geometric creep toward the bottom-left corner on every reload or login.
--  Only setups whose EUI scale differs from the CVar scale drift, which is
--  why not every user sees it.
--
--  Fix: re-assert the (correct) chat-cache position after the engine cache
--  has had its turn -- a deferred pass at login (the only moment the engine
--  misplaces anything) and on the chat-window events whose handlers re-run
--  Blizzard's restore (undocking fires UPDATE_CHAT_WINDOWS, which restores
--  every undocked window). The engine may still cache the frames at logout;
--  its one wrong placement per login is corrected by the pass immediately.
--
--  Deliberately NOT part of the fix (both shipped briefly and were pulled
--  after a tester hit the ChatFrameEditBox secret SetText taint error, the
--  documented failure signature of widened taint in the FCF/chat family):
--    - hooksecurefunc("FCF_SavePositionAndDimensions"): the hook body runs
--      inside FCF_StopDragging's execution and taints its continuation
--      (MOVING_CHATFRAME write). Chat-module rule: no synchronous FCF hooks.
--    - SetUserPlaced(false) on the chat frames: insecure write to Blizzard
--      frame state consumed by the engine/secure code; not needed, since the
--      login reassert already corrects the engine's placement.
-------------------------------------------------------------------------------
do
    local function ReassertUndockedPositions()
        if not GetChatWindowSavedPosition then return end
        local W, H = GetScreenWidth(), GetScreenHeight()
        if not (W and H) then return end
        for i = 2, NUM_CHAT_WINDOWS or 10 do
            local cf = _G["ChatFrame" .. i]
            if cf and cf:IsShown() and not cf.isDocked and not cf.isTemporary then
                local point, xOff, yOff = GetChatWindowSavedPosition(i)
                if point and xOff and yOff then
                    -- Blizzard's own restore formula; spaces agree, so this
                    -- is the exact dropped position.
                    cf:ClearAllPoints()
                    cf:SetPoint(point, UIParent, point, xOff * W, yOff * H)
                end
            end
        end
    end

    local loginDone = false
    local fixPending = false
    local function QueueReassert(alsoLate)
        if not loginDone or fixPending then return end
        fixPending = true
        C_Timer.After(0, function()
            fixPending = false
            ReassertUndockedPositions()
        end)
        -- Login belt: the engine layout cache lands before PEW in practice,
        -- but a second pass well after covers slow-load ordering. Idempotent.
        if alsoLate then C_Timer.After(2, ReassertUndockedPositions) end
    end

    local fixFrame = CreateFrame("Frame")
    fixFrame:RegisterEvent("PLAYER_ENTERING_WORLD")
    fixFrame:RegisterEvent("UPDATE_CHAT_WINDOWS")
    fixFrame:RegisterEvent("UPDATE_FLOATING_CHAT_WINDOWS")
    fixFrame:SetScript("OnEvent", function(_, event, arg1, arg2)
        if event == "PLAYER_ENTERING_WORLD" then
            if arg1 or arg2 then
                loginDone = true
                -- Obsolete v2 migration flag; the rebase it gated was a
                -- provable no-op (spaces agree) and was removed.
                if EllesmereUIDB then EllesmereUIDB.chatPosRebased = nil end
                QueueReassert(true)
            end
        else
            QueueReassert(false)
        end
    end)

    -- Tester diagnostics: dump both coordinate spaces, each saved position,
    -- and each undocked window's LIVE anchors and rect. Field lesson from the
    -- first version: `local a, b, c = Fn and Fn(i)` truncates multiple
    -- returns to one -- call the API directly.
    local function DumpChatWindows(tag)
        local W, H = GetScreenWidth(), GetScreenHeight()
        local pw, ph = UIParent:GetWidth(), UIParent:GetHeight()
        print(("EUI chatfix v4: screen %.1fx%.1f, uiparent %.1fx%.1f, scale %.4f%s")
            :format(W or 0, H or 0, pw or 0, ph or 0,
                UIParent:GetScale() or 0, tag or ""))
        for i = 2, NUM_CHAT_WINDOWS or 10 do
            local cf = _G["ChatFrame" .. i]
            local point, x, y
            if GetChatWindowSavedPosition then
                point, x, y = GetChatWindowSavedPosition(i)
            end
            local interesting = point or (cf and cf:IsShown() and not cf.isDocked)
            if interesting then
                print(("  CF%d saved=%s x=%.4f y=%.4f docked=%s shown=%s temp=%s userplaced=%s"):format(
                    i, tostring(point), x or 0, y or 0,
                    tostring(cf and cf.isDocked or false),
                    tostring(cf and cf:IsShown() or false),
                    tostring(cf and cf.isTemporary or false),
                    tostring(cf and cf.IsUserPlaced and cf:IsUserPlaced() or false)))
                if cf and cf:IsShown() and not cf.isDocked then
                    print(("    rect L=%.1f B=%.1f T=%.1f %dx%d"):format(
                        cf:GetLeft() or 0, cf:GetBottom() or 0, cf:GetTop() or 0,
                        cf:GetWidth() or 0, cf:GetHeight() or 0))
                    for j = 1, cf:GetNumPoints() do
                        local p, rel, rp, px, py = cf:GetPoint(j)
                        local relName = "nil"
                        if rel then
                            relName = (rel.GetName and rel:GetName()) or "<anon>"
                        end
                        print(("    pt%d %s -> %s.%s %.1f, %.1f"):format(
                            j, tostring(p), relName, tostring(rp), px or 0, py or 0))
                    end
                end
            end
        end
    end
    SlashCmdList["EUICHATFIX"] = function() DumpChatWindows("") end
    SLASH_EUICHATFIX1 = "/euichatfix"

    -- Drift catcher: snapshot each undocked window's rect at logout (fires on
    -- /reload too) and compare at next login. If a window moved between the
    -- logout snapshot and the settled login state, print the delta
    -- automatically -- the tester no longer has to capture before/after
    -- screenshots, and the exact per-session delta identifies the mover.
    local snapFrame = CreateFrame("Frame")
    snapFrame:RegisterEvent("PLAYER_LOGOUT")
    snapFrame:RegisterEvent("PLAYER_ENTERING_WORLD")
    snapFrame:SetScript("OnEvent", function(_, event, initialLogin, reloadingUi)
        local charKey = UnitGUID and UnitGUID("player")
        if not charKey then return end
        if event == "PLAYER_LOGOUT" then
            if not EllesmereUIDB then return end
            local snap = {}
            for i = 2, NUM_CHAT_WINDOWS or 10 do
                local cf = _G["ChatFrame" .. i]
                if cf and cf:IsShown() and not cf.isDocked and not cf.isTemporary then
                    local l, b = cf:GetLeft(), cf:GetBottom()
                    if l and b then
                        snap[i] = { l = l, b = b, w = cf:GetWidth(), h = cf:GetHeight() }
                    end
                end
            end
            EllesmereUIDB.chatPosSnap = EllesmereUIDB.chatPosSnap or {}
            EllesmereUIDB.chatPosSnap[charKey] = snap
        elseif event == "PLAYER_ENTERING_WORLD" and (initialLogin or reloadingUi) then
            -- Late enough that login-time restores, our rebase, and any
            -- unknown mover have all had their turn.
            C_Timer.After(2, function()
                local snap = EllesmereUIDB and EllesmereUIDB.chatPosSnap
                    and EllesmereUIDB.chatPosSnap[charKey]
                if not snap then return end
                for i, s in pairs(snap) do
                    local cf = _G["ChatFrame" .. i]
                    if cf and cf:IsShown() and not cf.isDocked and not cf.isTemporary then
                        local l, b = cf:GetLeft(), cf:GetBottom()
                        if l and b then
                            local dx, dy = l - s.l, b - s.b
                            if math.abs(dx) > 1 or math.abs(dy) > 1 then
                                print(("EUI chatfix DRIFT: CF%d moved dx=%.1f dy=%.1f (was L=%.1f B=%.1f, now L=%.1f B=%.1f)")
                                    :format(i, dx, dy, s.l, s.b, l, b))
                                DumpChatWindows(" (drift)")
                            end
                        end
                    end
                end
            end)
        end
    end)
end

-- Apply the saved combat text font immediately at file scope.
-- DAMAGE_TEXT_FONT must be set before the engine caches it at login.
-- CombatTextFont may not exist yet here, so we also hook ADDON_LOADED
-- to catch it as soon as it becomes available.
do
    local function ApplyCombatTextFont()
        local saved = EllesmereUIDB and EllesmereUIDB.fctFont
        if not saved or type(saved) ~= "string" or saved == "" then return end
        -- Resolve "smf:" prefixed SharedMedia font keys to actual paths
        local fontPath = saved
        local smName = saved:match("^smf:(.+)")
        if smName then
            local LSM = LibStub and LibStub("LibSharedMedia-3.0", true)
            local fetched = LSM and LSM:Fetch("font", smName)
            -- If the SM addon is missing or hasn't loaded yet, skip entirely
            -- so Blizzard's default combat text font stays intact.
            if not fetched then return end
            fontPath = fetched
        end
        _G.DAMAGE_TEXT_FONT = fontPath
        if _G.CombatTextFont then
            _G.CombatTextFont:SetFont(fontPath, 120, "")
        end
    end

    -- Apply immediately (sets DAMAGE_TEXT_FONT before engine caches it)
    ApplyCombatTextFont()

    -- Re-apply on ADDON_LOADED (our addon or Blizzard_CombatText), PLAYER_LOGIN,
    -- and PLAYER_ENTERING_WORLD to cover all timing windows where the engine
    -- may cache or reset the combat text font.
    local f = CreateFrame("Frame")
    f:RegisterEvent("ADDON_LOADED")
    f:RegisterEvent("PLAYER_LOGIN")
    f:RegisterEvent("PLAYER_ENTERING_WORLD")
    f:SetScript("OnEvent", function(self, event, addonName)
        if event == "ADDON_LOADED" then
            if addonName ~= ADDON_NAME and addonName ~= "Blizzard_CombatText" then
                return
            end
        end

        ApplyCombatTextFont()

        if event == "PLAYER_LOGIN" then
            self:UnregisterEvent("PLAYER_LOGIN")
        elseif event == "PLAYER_ENTERING_WORLD" then
            self:UnregisterEvent("PLAYER_ENTERING_WORLD")
        elseif event == "ADDON_LOADED" then
            self:UnregisterEvent("ADDON_LOADED")
        end
    end)
end

-- NOTE: the global _G.STANDARD_TEXT_FONT override that used to live here was
-- removed. It was gated on the "Reskin Blizzard Elements" (customTooltips) toggle
-- and read a dead legacy key (EllesmereUIDB.fontSettings.global), so it always
-- forced STANDARD_TEXT_FONT to the bundled Expressway.TTF -- a Latin-only face --
-- regardless of the user's actual font choice. In CJK/Cyrillic locales that broke
-- glyphs across the whole Blizzard UI AND other addons (square boxes), because it
-- bypassed the locale-aware ResolveFontName fallback.
--
-- Changing the global game-text font is now handled exclusively by the opt-in,
-- locale-aware EllesmereUI.ApplyGlobalFontToGameText() ("Apply to All Game Text"),
-- which runs once at PLAYER_LOGIN. Reskinned Blizzard elements still pick up the
-- EllesmereUI font on their own via per-element, locale-aware SetFont calls
-- (EllesmereUI.GetFontPath("blizzardSkin")), so reskinning no longer touches the
-- global font and never affects other addons.

-------------------------------------------------------------------------------
--  Auto-disable EllesmereUIBags when a dedicated bag addon is present.
--  Once the user manually toggles the Bags module (sidebar power button or
--  first-install popup), we set EllesmereUIDB.bagsUserChosen and never
--  override their preference again.
-------------------------------------------------------------------------------
do
    local BAG_ADDONS = {
        "AdiBags", "ArkInventory", "Baganator", "Bagnon", "BetterBags", "Sorted",
    }
    local f = CreateFrame("Frame")
    f:RegisterEvent("ADDON_LOADED")
    f:SetScript("OnEvent", function(self, event, addonName)
        if addonName ~= ADDON_NAME then return end
        self:UnregisterAllEvents()
        if not EllesmereUIDB then EllesmereUIDB = {} end
        if EllesmereUIDB.bagsUserChosen then return end
        if not C_AddOns or not C_AddOns.GetAddOnEnableState then return end
        -- If we previously auto-disabled bags but the user re-enabled it
        -- (via Blizzard addon list or any other means), respect their choice.
        local bagsEnabled = C_AddOns.GetAddOnEnableState("EllesmereUIBags") > 0
        if EllesmereUIDB.bagsAutoDisabled and bagsEnabled then
            EllesmereUIDB.bagsUserChosen = true
            EllesmereUIDB.bagsAutoDisabled = nil
            return
        end
        for _, name in ipairs(BAG_ADDONS) do
            if C_AddOns.GetAddOnEnableState(name) > 0 then
                C_AddOns.DisableAddOn("EllesmereUIBags")
                EllesmereUIDB.bagsAutoDisabled = true
                return
            end
        end
        EllesmereUIDB.bagsAutoDisabled = nil
    end)
end

-- (The DataBars auto-disable block was removed 2026-07-13: after the
-- multi-bar rewrite the module does literally nothing until the user
-- creates a bar, so it ships enabled with zero cost. If a prior build
-- auto-disabled it, re-enabling once sticks -- the latch keys
-- dataBarsAutoDisabled/dataBarsUserChosen are simply no longer read.)

-- /rl reload shortcut -- only
if not SlashCmdList["RL"] then
    SlashCmdList["RL"] = function() ReloadUI() end
    SLASH_RL1 = "/rl"
end
