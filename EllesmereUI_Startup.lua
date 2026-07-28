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
--  Blizzard saves an undocked chat window's position as ratios of
--  GetScreenWidth()/GetScreenHeight() (FCF_SavePositionAndDimensions), using
--  TOP/RIGHT edge distances when the window sits in the top/right half of the
--  screen. The restore (FCF_RestorePositionAndDimensions) turns those ratios
--  back into SetPoint offsets that resolve against UIParent's rect.
--  GetScreenWidth/Height track the uiScale CVar only, while our pixel-perfect
--  scale is applied via UIParent:SetScale() directly, so the two coordinate
--  spaces disagree whenever the EUI scale differs from the CVar scale, and
--  every restore lands TOP/RIGHT-anchored windows shifted by the space
--  difference. The restore does not just run at login: undocking a window
--  (SetChatWindowDocked + FCF_SaveDock) re-fires UPDATE_CHAT_WINDOWS, and
--  FloatingChatFrame_Update re-restores EVERY undocked window, so chasing
--  restores with a post-hoc correction pass leaks (field report: windows
--  shifted down again each time another window was undocked).
--
--  Fix: make the SAVED DATA itself restore-consistent instead of correcting
--  after the fact. Offsets are stored measured from UIParent's edges (still
--  divided by GetScreen* so Blizzard's multiply reproduces them):
--      TOP:    yOff = (top - UIParent height) / GetScreenHeight()
--      BOTTOM: yOff = bottom / GetScreenHeight()
--  and the x-axis equivalents. With that form, Blizzard's own restore lands
--  exactly where the window was dropped, on every restore path, with no
--  post-restore correction to race against.
--
--  Two writers keep the data in that form:
--    1. A one-time per-character rebase at PLAYER_ENTERING_WORLD converts
--       legacy Blizzard-form ratios (flag: EllesmereUIDB.chatPosRebased) and
--       re-anchors shown undocked windows to their true positions.
--    2. A deferred hook after FCF_SavePositionAndDimensions rewrites each new
--       drag-drop save. The hook body only schedules (repo precedent: the
--       FCF_Close/FCF_OpenNewWindow hooks); the rewrite itself runs outside
--       the secure FCF chain via C_Timer.After(0).
-------------------------------------------------------------------------------
do
    -- Rewrite one window's saved position from its live rect, in the
    -- restore-consistent form described above. The frame is a plain UIParent
    -- child with scale 1, so its rect getters share UIParent's space.
    local function RewriteSavedPosition(cf, id)
        if not (SetChatWindowSavedPosition and cf) then return end
        local W, H = GetScreenWidth(), GetScreenHeight()
        local pw, ph = UIParent:GetWidth(), UIParent:GetHeight()
        local left, right = cf:GetLeft(), cf:GetRight()
        local top, bottom = cf:GetTop(), cf:GetBottom()
        if not (W and H and pw and ph and left and right and top and bottom) then return end
        local horiz = ((left + right) / 2 > pw / 2) and "RIGHT" or "LEFT"
        local vert = ((top + bottom) / 2 > ph / 2) and "TOP" or "BOTTOM"
        local xOff = (horiz == "RIGHT") and ((right - pw) / W) or (left / W)
        local yOff = (vert == "TOP") and ((top - ph) / H) or (bottom / H)
        SetChatWindowSavedPosition(id, vert .. horiz, xOff, yOff)
    end

    -- 1. One-time legacy rebase. Converts every saved position analytically
    --    (docked and hidden windows included, so their stale saves are ready
    --    for a future undock) and re-anchors shown undocked windows, which
    --    Blizzard's login restore has already placed at the legacy-shifted
    --    spot. Per character: chat window positions live in the
    --    per-character chat-cache, not in our account-wide DB.
    local rebaseFrame = CreateFrame("Frame")
    rebaseFrame:RegisterEvent("PLAYER_ENTERING_WORLD")
    rebaseFrame:SetScript("OnEvent", function(self, _, initialLogin, reloadingUi)
        if not (initialLogin or reloadingUi) then return end
        self:UnregisterEvent("PLAYER_ENTERING_WORLD")
        C_Timer.After(0, function()
            if not (GetChatWindowSavedPosition and SetChatWindowSavedPosition) then return end
            if not EllesmereUIDB then EllesmereUIDB = {} end
            local charKey = UnitGUID and UnitGUID("player")
            if not charKey then return end
            EllesmereUIDB.chatPosRebased = EllesmereUIDB.chatPosRebased or {}
            if EllesmereUIDB.chatPosRebased[charKey] then return end
            local W, H = GetScreenWidth(), GetScreenHeight()
            local pw, ph = UIParent:GetWidth(), UIParent:GetHeight()
            if not (W and H and pw and ph) then return end
            for i = 2, NUM_CHAT_WINDOWS or 10 do
                local point, xOff, yOff = GetChatWindowSavedPosition(i)
                if point and xOff and yOff then
                    local fx, fy = xOff, yOff
                    if point:find("TOP") then fy = yOff + (H - ph) / H end
                    if point:find("RIGHT") then fx = xOff + (W - pw) / W end
                    SetChatWindowSavedPosition(i, point, fx, fy)
                    local cf = _G["ChatFrame" .. i]
                    if cf and cf:IsShown() and not cf.isDocked and not cf.isTemporary then
                        -- Blizzard's restore formula applied to the rebased
                        -- offsets = the true dropped position.
                        cf:ClearAllPoints()
                        cf:SetPoint(point, UIParent, point, fx * W, fy * H)
                    end
                end
            end
            EllesmereUIDB.chatPosRebased[charKey] = true
        end)
    end)

    -- 2. Deferred rewrite after every Blizzard save (drag-drop).
    local pendingSave = {}
    if FCF_SavePositionAndDimensions then
        hooksecurefunc("FCF_SavePositionAndDimensions", function(chatFrame)
            if not chatFrame or pendingSave[chatFrame] then return end
            pendingSave[chatFrame] = true
            C_Timer.After(0, function()
                pendingSave[chatFrame] = nil
                local id = chatFrame.GetID and chatFrame:GetID()
                if id and id > 1 and not chatFrame.isDocked and not chatFrame.isTemporary then
                    RewriteSavedPosition(chatFrame, id)
                end
            end)
        end)
    end

    -- Tester diagnostics: dump both coordinate spaces, each saved position,
    -- and each undocked window's LIVE anchors and rect. Field lesson from the
    -- first version: `local a, b, c = Fn and Fn(i)` truncates multiple
    -- returns to one -- call the API directly.
    local function DumpChatWindows(tag)
        local W, H = GetScreenWidth(), GetScreenHeight()
        local pw, ph = UIParent:GetWidth(), UIParent:GetHeight()
        local charKey = UnitGUID and UnitGUID("player")
        local rebased = charKey and EllesmereUIDB and EllesmereUIDB.chatPosRebased
            and EllesmereUIDB.chatPosRebased[charKey] and true or false
        print(("EUI chatfix%s: screen %.1fx%.1f, uiparent %.1fx%.1f, scale %.4f, rebased=%s")
            :format(tag or "", W or 0, H or 0, pw or 0, ph or 0,
                UIParent:GetScale() or 0, tostring(rebased)))
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
