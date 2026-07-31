-------------------------------------------------------------------------------
--  EllesmereUI_DisplaySetupPopup.lua
--
--  One-time "Display Setup" popup for fresh installs. Offers a guided tune of
--  UI scale, font size and key element sizes so players on 1440p, 4K and
--  ultrawide monitors are not left with a UI that reads too small.
--
--  Without this, a fresh install silently adopts Blizzard's own UIParent scale
--  (EllesmereUI_Startup.lua, PLAYER_ENTERING_WORLD) and never suggests the
--  pixel-perfect value for the player's resolution.
--
--  Shows on the login AFTER the first-install module picker reloads, so every
--  module the player just enabled is loaded and can be previewed live. Armed by
--  EllesmereUIDB.displaySetupPending, written by the picker right before its
--  ReloadUI. Existing users never acquire that flag, so this file is inert for
--  them. Stamped by EllesmereUIDB.displaySetupShown. Reset: /euidisplaysetup.
--
--  Everything applies live while dragging. Cancel restores the snapshot taken
--  when the popup opened.
-------------------------------------------------------------------------------

local EllesmereUI = _G.EllesmereUI
if not EllesmereUI then return end

-- Suite-only: a single-module standalone build has no cross-module sizing to
-- offer. Deriving this from the host addon name (the `...` vararg = real folder
-- name) is rename-immune.
local EUI_HOST_ADDON = ...
local IS_STANDALONE = type(EUI_HOST_ADDON) == "string" and EUI_HOST_ADDON:find("Standalone") ~= nil
if IS_STANDALONE then return end

local PP = EllesmereUI.PanelPP
local MakeBorder = EllesmereUI.MakeBorder
local ELLESMERE_GREEN = EllesmereUI.ELLESMERE_GREEN

local floor, max, min, abs = math.floor, math.max, math.min, math.abs

-- Exact pixel-perfect scales for the two common heights. The options-page UI
-- Scale slider snaps to these same values, so a preset and a manual drag land
-- on identical numbers.
local SCALE_1080 = 0.7111111111   -- 768 / 1080
local SCALE_1440 = 0.5333333333   -- 768 / 1440

local function Round(v) return floor(v + 0.5) end

local function IsLoaded(folder)
    return C_AddOns and C_AddOns.IsAddOnLoaded and C_AddOns.IsAddOnLoaded(folder) and true or false
end

-- Live per-addon profile table. This is the same table the module's own db
-- object holds (EUILite.NewDB returns profileData.addons[folder] as .profile),
-- so writes here are seen immediately by that module's apply hooks.
local function AddonProfile(folder)
    if not EllesmereUIDB or not EllesmereUIDB.profiles then return nil end
    local prof = EllesmereUIDB.profiles[EllesmereUIDB.activeProfile or "Default"]
    if type(prof) ~= "table" or type(prof.addons) ~= "table" then return nil end
    local t = prof.addons[folder]
    return type(t) == "table" and t or nil
end

-------------------------------------------------------------------------------
--  Font targets
--
--  There is no global font-size setting in EUI: sizes live in per-module
--  profile keys. Rather than inventing a global multiplier (which would have to
--  be threaded through every module's SetFont call), the slider multiplies this
--  curated map of existing keys and fires each module's existing refresh hook.
--  Coverage is deliberately partial: this is a coarse first-install tune, and
--  per-module sliders remain the fine-tune path.
--
--  resolve(profile) returns an array of { tbl, key } pairs to scale. Anything
--  missing or non-numeric is skipped, so a module at non-default settings or a
--  future key rename degrades quietly instead of erroring.
-------------------------------------------------------------------------------
local FONT_TARGETS = {
    {
        folder = "EllesmereUIChat",
        hook = "_ECHAT_RefreshAll",
        resolve = function(p)
            local c = p.chat
            if type(c) ~= "table" then return nil end
            return { { c, "fontSize" }, { c, "tabFontSize" } }
        end,
    },
    {
        folder = "EllesmereUIQuestTracker",
        hook = "_EQT_RefreshAll",
        resolve = function(p)
            local q = p.questTracker
            if type(q) ~= "table" then return nil end
            return { { q, "titleFontSize" }, { q, "objectiveFontSize" }, { q, "headerFontSize" } }
        end,
    },
    {
        folder = "EllesmereUINameplates",
        hook = "_ENP_RefreshAllSettings",
        -- Nameplate defaults are flat on the profile (no sub-table).
        resolve = function(p)
            return {
                { p, "friendlyNameTextSize" }, { p, "enemyNameTextSize" },
                { p, "friendlyNPCNameSize" }, { p, "auraDurationTextSize" },
                { p, "auraStackTextSize" }, { p, "buffTextSize" },
                { p, "ccTextSize" }, { p, "rangeTextSize" },
                { p, "questObjectiveTextSize" },
            }
        end,
    },
    {
        folder = "EllesmereUIDataBars",
        hook = "_EDB_Apply",
        -- fontScale is per-bar and expressed as a percent (baseline 100), not a
        -- point size, but it scales linearly all the same.
        resolve = function(p)
            if type(p.bars) ~= "table" then return nil end
            local out = {}
            for _, barCfg in pairs(p.bars) do
                if type(barCfg) == "table" then out[#out + 1] = { barCfg, "fontScale" } end
            end
            return out
        end,
    },
    {
        folder = "EllesmereUIUnitFrames",
        hook = "_EUF_ReloadFrames",
        resolve = function(p)
            local units = { "player", "target", "focus", "pet", "targettarget" }
            local keys = { "textSize", "leftTextSize", "rightTextSize", "centerTextSize", "extraTextSize" }
            local out = {}
            for _, unit in ipairs(units) do
                local u = p[unit]
                if type(u) == "table" then
                    for _, k in ipairs(keys) do out[#out + 1] = { u, k } end
                end
            end
            return out
        end,
    },
}

-------------------------------------------------------------------------------
--  Baseline capture and scaled writes
--
--  Baselines are captured once when the popup opens, and every write is
--  round(baseline * factor). Applying 120% then 100% therefore restores the
--  exact original integer, with no compounding across drags or preset clicks.
-------------------------------------------------------------------------------
local function CaptureNumericTargets(targets)
    local snap = {}
    for _, pair in ipairs(targets) do
        local tbl, key = pair[1], pair[2]
        if type(tbl[key]) == "number" then
            snap[#snap + 1] = { tbl = tbl, key = key, base = tbl[key] }
        end
    end
    return snap
end

local function ApplyFactor(snap, factor)
    for _, e in ipairs(snap) do
        e.tbl[e.key] = max(1, Round(e.base * factor))
    end
end

local function RestoreSnap(snap)
    for _, e in ipairs(snap) do
        e.tbl[e.key] = e.base
    end
end

local function FireHook(name)
    local fn = _G[name]
    if type(fn) == "function" then pcall(fn) end
end

-------------------------------------------------------------------------------
--  Conflict-check handoff
--
--  The addon-conflict check auto-runs a couple of seconds after load, gated on
--  firstInstallPopupShown and the intro pending flags. This popup runs FIRST in
--  the chain, so it must not trigger that check itself while a later intro
--  popup is still queued: it only releases when nothing else is pending.
-------------------------------------------------------------------------------
local function ReleaseConflictCheck()
    EllesmereUI._displaySetupPending = nil
    if EllesmereUI._raidFramesIntroPending
       or EllesmereUI._patchNotesIntroPending
       or EllesmereUI._windowSkinsIntroPending
       or EllesmereUI._specOvIntroPending
       or EllesmereUI._ptrManagersIntroPending then
        return
    end
    if EllesmereUIDB and EllesmereUIDB.firstInstallPopupShown and EllesmereUI._RunConflictCheck then
        C_Timer.After(0.3, EllesmereUI._RunConflictCheck)
    end
end

-------------------------------------------------------------------------------
--  The popup
-------------------------------------------------------------------------------
local function ShowDisplaySetupPopup()
    local FONT = EllesmereUI._font or ("Interface\\AddOns\\EllesmereUI\\media\\fonts\\Expressway.ttf")
    local EG = ELLESMERE_GREEN
    local ppScale = (EllesmereUI.GetSetupPopupScale and EllesmereUI.GetSetupPopupScale())
        or (EllesmereUI.GetPopupScale and EllesmereUI.GetPopupScale()) or 1

    -- Detected resolution. PP.RefreshPhysical falls back to 1920x1080 when the
    -- API reports nothing, so these are always usable numbers.
    local physW, physH = GetPhysicalScreenSize()
    physW = (type(physW) == "number" and physW > 0) and physW or 1920
    physH = (type(physH) == "number" and physH > 0) and physH or 1080
    -- 2.0 is the same threshold the preset gallery uses to pick Ultrawide
    -- Import, so the two never disagree about what this monitor is.
    local aspect = physW / physH
    local isUltrawide = aspect >= 2.0

    -- Which unit frames / action bars exist to size.
    local ufProfile = IsLoaded("EllesmereUIUnitFrames") and AddonProfile("EllesmereUIUnitFrames") or nil
    local abProfile = IsLoaded("EllesmereUIActionBars") and AddonProfile("EllesmereUIActionBars") or nil

    ---------------------------------------------------------------------------
    --  Snapshots (taken before anything is touched)
    ---------------------------------------------------------------------------
    local snapScale     = EllesmereUIDB and EllesmereUIDB.ppUIScale
    local snapScaleAuto = EllesmereUIDB and EllesmereUIDB.ppUIScaleAuto
    local baseScale     = snapScale or (EllesmereUI.PP and EllesmereUI.PP.PixelBestSize and EllesmereUI.PP.PixelBestSize()) or 0.71

    -- Font targets, flattened across every loaded module.
    local fontSnap, fontHooks = {}, {}
    for _, target in ipairs(FONT_TARGETS) do
        if IsLoaded(target.folder) then
            local p = AddonProfile(target.folder)
            if p then
                local resolved = target.resolve(p)
                if resolved and #resolved > 0 then
                    local captured = CaptureNumericTargets(resolved)
                    if #captured > 0 then
                        for _, e in ipairs(captured) do fontSnap[#fontSnap + 1] = e end
                        fontHooks[#fontHooks + 1] = target.hook
                    end
                end
            end
        end
    end

    -- Unit frame sizing: every unit table carrying both a width and a height.
    local ufSnap = {}
    if ufProfile then
        for _, u in pairs(ufProfile) do
            if type(u) == "table" and type(u.frameWidth) == "number" and type(u.healthHeight) == "number" then
                ufSnap[#ufSnap + 1] = { tbl = u, key = "frameWidth", base = u.frameWidth }
                ufSnap[#ufSnap + 1] = { tbl = u, key = "healthHeight", base = u.healthHeight }
            end
        end
    end

    -- Action bar icon sizing. buttonWidth/buttonHeight default to 0 meaning
    -- "use the template size", so 36 is the effective baseline in that case.
    -- Width/height match links are skipped: their size is driven by another
    -- bar, and writing here would fight that. Restore puts back the original
    -- value including 0.
    local abSnap = {}
    if abProfile and type(abProfile.bars) == "table" then
        for barKey, s in pairs(abProfile.bars) do
            if type(s) == "table" then
                local linked = (EllesmereUI.GetWidthMatchTarget and EllesmereUI.GetWidthMatchTarget(barKey))
                    or (EllesmereUI.GetHeightMatchTarget and EllesmereUI.GetHeightMatchTarget(barKey))
                if not linked then
                    local w = (type(s.buttonWidth) == "number" and s.buttonWidth > 0) and s.buttonWidth or 36
                    abSnap[#abSnap + 1] = {
                        tbl = s,
                        baseW = w,
                        origW = s.buttonWidth,
                        origH = s.buttonHeight,
                        origEx = s._matchExtraPixels,
                        origExH = s._matchExtraPixelsH,
                    }
                end
            end
        end
    end

    local hasUF, hasAB = #ufSnap > 0, #abSnap > 0
    local hasFonts = #fontSnap > 0

    ---------------------------------------------------------------------------
    --  Setters (single code path for both sliders and presets)
    ---------------------------------------------------------------------------
    local popup        -- forward declaration; the scale setter counter-scales it
    local fontSample   -- live sample text, resized by the font slider
    local SAMPLE_BASE = 15

    local curScale = baseScale
    local curFont, curUF, curAB = 1.0, 1.0, 1.0

    local function ApplyScale(v)
        -- Match the options-page snapping so a hand-dragged 0.53 lands on the
        -- same exact value a preset would set.
        if abs(v - 0.53) < 0.005 then v = SCALE_1440 end
        if abs(v - 0.71) < 0.005 then v = SCALE_1080 end
        curScale = v
        if not (EllesmereUI.PP and EllesmereUI.PP.SetUIScale) then return end
        -- Keep the popup visually the same size while the world rescales
        -- behind it, exactly as the options panel does during a scale drag.
        local effBefore = popup and popup:GetEffectiveScale() or nil
        EllesmereUI.PP.SetUIScale(v)
        if popup and effBefore then
            local effAfter = popup:GetEffectiveScale()
            if effAfter and effAfter > 0 then
                popup:SetScale((popup:GetScale() or 1) * effBefore / effAfter)
            end
        end
    end

    local function ApplyFonts(f)
        curFont = f
        -- The affected text is often not on screen during setup: no nameplates
        -- spawned yet, no quests tracked, an empty chat. The sample gives the
        -- slider immediate feedback regardless.
        if fontSample then
            fontSample:SetFont(FONT, max(6, Round(SAMPLE_BASE * f)), "")
        end
        if not hasFonts then return end
        ApplyFactor(fontSnap, f)
        for _, hook in ipairs(fontHooks) do FireHook(hook) end
    end

    local function ApplyUF(f)
        curUF = f
        if not hasUF then return end
        ApplyFactor(ufSnap, f)
        FireHook("_EUF_ReloadFrames")
    end

    local function ApplyAB(f)
        curAB = f
        if not hasAB then return end
        for _, e in ipairs(abSnap) do
            local v = max(1, Round(e.baseW * f))
            e.tbl.buttonWidth = v
            e.tbl.buttonHeight = v
            e.tbl._matchExtraPixels = nil
            e.tbl._matchExtraPixelsH = nil
        end
        FireHook("_EAB_Apply")
    end

    ---------------------------------------------------------------------------
    --  Layout
    ---------------------------------------------------------------------------
    local sliderCount = 1 + (hasFonts and 1 or 0) + (hasUF and 1 or 0) + (hasAB and 1 or 0)
    local ROW_H = 46
    local SAMPLE_H = 34
    local POPUP_W = 520
    local UW_H = 66
    local POPUP_H = 258 + sliderCount * ROW_H + (hasFonts and SAMPLE_H or 0)
        + (isUltrawide and UW_H or 0) + 96

    local dimmer = CreateFrame("Frame", "EUIDisplaySetupDimmer", UIParent)
    dimmer:SetFrameStrata("FULLSCREEN_DIALOG")
    dimmer:SetAllPoints(UIParent)
    dimmer:EnableMouse(true)
    dimmer:EnableMouseWheel(true)
    dimmer:SetScript("OnMouseWheel", function() end)
    dimmer:SetScale(ppScale)
    local dimTex = dimmer:CreateTexture(nil, "BACKGROUND")
    dimTex:SetAllPoints()
    dimTex:SetColorTexture(0, 0, 0, 0.35)

    popup = CreateFrame("Frame", "EUIDisplaySetupPopup", dimmer)
    popup:SetScale(ppScale)
    popup:SetFrameStrata("FULLSCREEN_DIALOG")
    popup:SetFrameLevel(dimmer:GetFrameLevel() + 10)
    PP.Size(popup, POPUP_W, POPUP_H)
    popup:SetPoint("CENTER", UIParent, "CENTER", 0, 0)
    popup:EnableMouse(true)

    local bg = popup:CreateTexture(nil, "BACKGROUND")
    bg:SetAllPoints()
    bg:SetColorTexture(0.06, 0.08, 0.10, 1)

    -- 1 physical-pixel white border (alpha 0.15), scale-derived so each edge
    -- stays exactly one physical pixel. Four edge textures, snap disabled.
    local onePhys = 1 / (popup:GetEffectiveScale() or 1)
    local BRD_A = 0.15
    local function MakeEdge()
        local t = popup:CreateTexture(nil, "BORDER")
        t:SetColorTexture(1, 1, 1, BRD_A)
        if t.SetSnapToPixelGrid then t:SetSnapToPixelGrid(false); t:SetTexelSnappingBias(0) end
        return t
    end
    local spT = MakeEdge(); spT:SetPoint("TOPLEFT", 0, 0); spT:SetPoint("TOPRIGHT", 0, 0); spT:SetHeight(onePhys)
    local spB = MakeEdge(); spB:SetPoint("BOTTOMLEFT", 0, 0); spB:SetPoint("BOTTOMRIGHT", 0, 0); spB:SetHeight(onePhys)
    local spL = MakeEdge(); spL:SetPoint("TOPLEFT", spT, "BOTTOMLEFT"); spL:SetPoint("BOTTOMLEFT", spB, "TOPLEFT"); spL:SetWidth(onePhys)
    local spR = MakeEdge(); spR:SetPoint("TOPRIGHT", spT, "BOTTOMRIGHT"); spR:SetPoint("BOTTOMRIGHT", spB, "TOPRIGHT"); spR:SetWidth(onePhys)

    local eyebrow = popup:CreateFontString(nil, "OVERLAY")
    eyebrow:SetFont(FONT, 13, "")
    eyebrow:SetTextColor(EG.r, EG.g, EG.b, 0.9)
    PP.Point(eyebrow, "TOP", popup, "TOP", 0, -26)
    eyebrow:SetText(EllesmereUI.L("SET UP YOUR SCREEN"))

    local title = popup:CreateFontString(nil, "OVERLAY")
    title:SetFont(FONT, 25, "")
    title:SetTextColor(1, 1, 1, 1)
    PP.Point(title, "TOP", eyebrow, "BOTTOM", 0, -6)
    title:SetText(EllesmereUI.L("Display Setup"))

    local desc = popup:CreateFontString(nil, "OVERLAY")
    desc:SetFont(FONT, 14, "")
    desc:SetTextColor(1, 1, 1, 0.5)
    desc:SetWidth(POPUP_W - 80)
    desc:SetJustifyH("CENTER")
    desc:SetWordWrap(true)
    PP.Point(desc, "TOP", title, "BOTTOM", 0, -10)
    desc:SetText(EllesmereUI.L("Pick the preset that matches your monitor, then fine-tune below. Everything updates live as you drag."))

    local resLabel = popup:CreateFontString(nil, "OVERLAY")
    resLabel:SetFont(FONT, 12, "")
    resLabel:SetTextColor(1, 1, 1, 0.35)
    PP.Point(resLabel, "TOP", desc, "BOTTOM", 0, -8)
    resLabel:SetText(string.format("%d x %d", physW, physH))

    ---------------------------------------------------------------------------
    --  Presets
    --
    --  Scale sets apparent size (a UI unit is always scale/768 of screen
    --  height); resolution sets crispness. True 4K pixel-perfect would be
    --  768/2160 = 0.3556, below PP's hard 0.4 floor, and even 0.4 reads
    --  noticeably smaller than the proven 1440p look. So 4K reuses the 1440p
    --  scale (exactly 1.5 physical pixels per UI unit at 2160p, still crisp)
    --  and adds a 10% text and element bump for the finer dot pitch.
    ---------------------------------------------------------------------------
    local PRESETS = {
        { key = "1080p",     label = EllesmereUI.L("1080p"),     scale = SCALE_1080, font = 1.00, elem = 1.00 },
        { key = "1440p",     label = EllesmereUI.L("1440p"),     scale = SCALE_1440, font = 1.00, elem = 1.00 },
        { key = "4K",        label = EllesmereUI.L("4K"),        scale = SCALE_1440, font = 1.10, elem = 1.10 },
        { key = "ultrawide", label = EllesmereUI.L("Ultrawide"), scale = nil,        font = 1.00, elem = 1.00 },
    }

    -- Ultrawide is a width phenomenon, so its scale follows the panel height.
    local uwScale = max(0.4, min(768 / physH, 1.15))

    local detected
    if isUltrawide then detected = "ultrawide"
    elseif physH >= 1900 then detected = "4K"
    elseif physH >= 1300 then detected = "1440p"
    else detected = "1080p" end

    local sliders = {}   -- populated below; presets drive the thumbs through these

    local PRE_W, PRE_H, PRE_GAP = 112, 34, 10
    for i, preset in ipairs(PRESETS) do
        local btn = CreateFrame("Button", nil, popup)
        btn:SetFrameLevel(popup:GetFrameLevel() + 2)
        PP.Size(btn, PRE_W, PRE_H)
        PP.Point(btn, "TOP", popup, "TOP",
            (i - 2.5) * (PRE_W + PRE_GAP), -136)

        local isDetected = (preset.key == detected)
        local bbg = btn:CreateTexture(nil, "BACKGROUND")
        bbg:SetAllPoints()
        bbg:SetColorTexture(0.06, 0.08, 0.10, 0.92)
        local brd = MakeBorder(btn, EG.r, EG.g, EG.b, isDetected and 0.9 or 0.28, PP)

        local lbl = btn:CreateFontString(nil, "OVERLAY")
        lbl:SetFont(FONT, 14, "")
        PP.Point(lbl, "CENTER", btn, "CENTER", 0, isDetected and 4 or 0)
        lbl:SetTextColor(1, 1, 1, isDetected and 0.95 or 0.6)
        lbl:SetText(preset.label)

        if isDetected then
            local tag = btn:CreateFontString(nil, "OVERLAY")
            tag:SetFont(FONT, 10, "")
            tag:SetTextColor(EG.r, EG.g, EG.b, 0.9)
            PP.Point(tag, "CENTER", btn, "CENTER", 0, -9)
            tag:SetText(EllesmereUI.L("Detected"))
        end

        btn:SetScript("OnEnter", function()
            lbl:SetTextColor(1, 1, 1, 1)
            brd:SetColor(EG.r, EG.g, EG.b, 1)
        end)
        btn:SetScript("OnLeave", function()
            lbl:SetTextColor(1, 1, 1, isDetected and 0.95 or 0.6)
            brd:SetColor(EG.r, EG.g, EG.b, isDetected and 0.9 or 0.28)
        end)
        btn:SetScript("OnClick", function()
            local s = preset.scale or uwScale
            if sliders.scale then sliders.scale.Set(s) end
            if sliders.font then sliders.font.Set(preset.font * 100) end
            if sliders.uf then sliders.uf.Set(preset.elem * 100) end
            if sliders.ab then sliders.ab.Set(preset.elem * 100) end
        end)
    end

    ---------------------------------------------------------------------------
    --  Compact slider
    --
    --  Bespoke rather than W:Slider: the widget-library slider is wired to
    --  options-page machinery (row backgrounds, option-row tagging, the global
    --  widget refresh list) that does not belong inside a standalone popup.
    ---------------------------------------------------------------------------
    local TRACK_W, TRACK_H, THUMB = 300, 4, 12
    local rowY = -190

    local function MakeSlider(labelText, minV, maxV, step, initial, formatFn, onChange)
        local row = CreateFrame("Frame", nil, popup)
        row:SetFrameLevel(popup:GetFrameLevel() + 2)
        PP.Size(row, POPUP_W - 100, ROW_H)
        PP.Point(row, "TOP", popup, "TOP", 0, rowY)
        rowY = rowY - ROW_H

        local lbl = row:CreateFontString(nil, "OVERLAY")
        lbl:SetFont(FONT, 14, "")
        lbl:SetTextColor(1, 1, 1, 0.78)
        lbl:SetJustifyH("LEFT")
        PP.Point(lbl, "TOPLEFT", row, "TOPLEFT", 0, -2)
        lbl:SetText(labelText)

        local valTxt = row:CreateFontString(nil, "OVERLAY")
        valTxt:SetFont(FONT, 14, "")
        valTxt:SetTextColor(EG.r, EG.g, EG.b, 0.95)
        valTxt:SetJustifyH("RIGHT")
        PP.Point(valTxt, "TOPRIGHT", row, "TOPRIGHT", 0, -2)

        local track = CreateFrame("Frame", nil, row)
        track:SetFrameLevel(row:GetFrameLevel() + 1)
        PP.Size(track, TRACK_W, THUMB + 6)
        PP.Point(track, "TOPLEFT", row, "TOPLEFT", 0, -22)
        track:EnableMouse(true)

        local trackTex = track:CreateTexture(nil, "ARTWORK")
        trackTex:SetColorTexture(1, 1, 1, 0.12)
        PP.Size(trackTex, TRACK_W, TRACK_H)
        PP.Point(trackTex, "LEFT", track, "LEFT", 0, 0)

        local fillTex = track:CreateTexture(nil, "ARTWORK", nil, 1)
        fillTex:SetColorTexture(EG.r, EG.g, EG.b, 0.85)
        PP.Point(fillTex, "LEFT", track, "LEFT", 0, 0)

        local thumb = track:CreateTexture(nil, "OVERLAY")
        thumb:SetColorTexture(1, 1, 1, 0.92)
        PP.Size(thumb, THUMB, THUMB)

        local api = { value = initial }

        -- Measure the track as drawn rather than from TRACK_W, so the fill and
        -- thumb stay aligned with it after PanelPP has snapped it to the grid.
        local function TrackWidth()
            local w = track:GetWidth()
            return (w and w > 0) and w or TRACK_W
        end

        local function Redraw(v)
            local pct = (v - minV) / (maxV - minV)
            pct = max(0, min(1, pct))
            local w = max(0.001, TrackWidth() * pct)
            PP.Size(fillTex, w, TRACK_H)
            thumb:ClearAllPoints()
            PP.Point(thumb, "CENTER", track, "LEFT", w, 0)
            valTxt:SetText(formatFn(v))
        end

        -- Quantise to the step grid, then clamp.
        local function Quantise(v)
            v = minV + Round((v - minV) / step) * step
            return max(minV, min(maxV, v))
        end

        -- Only fire onChange when the quantised value actually moves. The drag
        -- handler runs every frame, and the scale setter re-snaps every stored
        -- position and pokes four module re-appliers, so firing it per frame
        -- would make dragging crawl.
        function api.Set(v, silent)
            v = Quantise(v)
            local changed = (v ~= api.value)
            api.value = v
            Redraw(v)
            if not silent and changed then onChange(v) end
        end

        local function ValueFromCursor()
            local scale = track:GetEffectiveScale()
            if not scale or scale <= 0 then return api.value end
            local cx = GetCursorPosition() / scale
            local left = track:GetLeft()
            if not left then return api.value end
            local pct = (cx - left) / TrackWidth()
            pct = max(0, min(1, pct))
            return minV + pct * (maxV - minV)
        end

        track:SetScript("OnMouseDown", function(self)
            self._dragging = true
            api.Set(ValueFromCursor())
        end)
        track:SetScript("OnMouseUp", function(self)
            self._dragging = false
        end)
        track:SetScript("OnUpdate", function(self)
            if self._dragging then api.Set(ValueFromCursor()) end
        end)

        Redraw(initial)
        return api
    end

    local function PctFmt(v) return string.format("%d%%", Round(v)) end

    sliders.scale = MakeSlider(EllesmereUI.L("UI Scale"), 0.40, 1.00, 0.01, baseScale,
        function(v) return string.format("%.2f", v) end,
        function(v) ApplyScale(v) end)

    if hasFonts then
        sliders.font = MakeSlider(EllesmereUI.L("Font Size"), 80, 150, 5, 100, PctFmt,
            function(v) ApplyFonts(v / 100) end)
    end
    if hasUF then
        sliders.uf = MakeSlider(EllesmereUI.L("Unit Frame Size"), 80, 140, 5, 100, PctFmt,
            function(v) ApplyUF(v / 100) end)
    end
    if hasAB then
        sliders.ab = MakeSlider(EllesmereUI.L("Action Bar Icon Size"), 80, 140, 5, 100, PctFmt,
            function(v) ApplyAB(v / 100) end)
    end

    -- Font sample. Nameplates only re-skin plates that currently exist, and at
    -- login there are usually none, so without this the font slider can look
    -- like it does nothing.
    if hasFonts then
        fontSample = popup:CreateFontString(nil, "OVERLAY")
        fontSample:SetFont(FONT, SAMPLE_BASE, "")
        fontSample:SetTextColor(1, 1, 1, 0.7)
        fontSample:SetJustifyH("CENTER")
        fontSample:SetWidth(POPUP_W - 100)
        PP.Point(fontSample, "TOP", popup, "TOP", 0, rowY - 4)
        fontSample:SetText(EllesmereUI.L("The quick brown fox jumps over the lazy dog"))
        rowY = rowY - SAMPLE_H
    end

    ---------------------------------------------------------------------------
    --  Finish
    ---------------------------------------------------------------------------
    local function Finish(apply)
        if not EllesmereUIDB then EllesmereUIDB = {} end

        if not apply then
            -- Restore everything through the same paths that changed it.
            if EllesmereUI.PP and EllesmereUI.PP.SetUIScale and snapScale then
                EllesmereUI.PP.SetUIScale(snapScale)
            end
            EllesmereUIDB.ppUIScaleAuto = snapScaleAuto
            if hasFonts then
                RestoreSnap(fontSnap)
                for _, hook in ipairs(fontHooks) do FireHook(hook) end
            end
            if hasUF then
                RestoreSnap(ufSnap)
                FireHook("_EUF_ReloadFrames")
            end
            if hasAB then
                for _, e in ipairs(abSnap) do
                    e.tbl.buttonWidth = e.origW
                    e.tbl.buttonHeight = e.origH
                    e.tbl._matchExtraPixels = e.origEx
                    e.tbl._matchExtraPixelsH = e.origExH
                end
                FireHook("_EAB_Apply")
            end
        end

        local scaleChanged = apply and snapScale and abs(curScale - snapScale) > 0.0001
        if apply then
            if scaleChanged then EllesmereUIDB.ppUIScaleAuto = false end
            EllesmereUIDB.displayFontScale = curFont
        end

        EllesmereUIDB.displaySetupShown = true
        EllesmereUIDB.displaySetupPending = nil
        dimmer:Hide()
        ReleaseConflictCheck()

        -- Same Edit Mode caveat the options-page scale slider raises: Blizzard
        -- snapping stays stale until a reload.
        if scaleChanged and EllesmereUI.ShowConfirmPopup then
            EllesmereUI:ShowConfirmPopup({
                title = "UI Scale Changed",
                message = "Blizzard's Edit Mode snapping may not work correctly until you reload your UI.",
                confirmText = "Reload Now",
                cancelText = "Later",
                onConfirm = function() ReloadUI() end,
            })
        end
    end

    ---------------------------------------------------------------------------
    --  Buttons
    ---------------------------------------------------------------------------
    local BTN_W, BTN_H, BTN_GAP = 184, 38, 14
    local function MakeActionButton(text, r, g, b, secondary)
        local btn = CreateFrame("Button", nil, popup)
        btn:SetFrameLevel(popup:GetFrameLevel() + 2)
        PP.Size(btn, BTN_W, BTN_H)
        local bbg = btn:CreateTexture(nil, "BACKGROUND")
        bbg:SetAllPoints()
        bbg:SetColorTexture(0.06, 0.08, 0.10, 0.92)
        local brd = MakeBorder(btn, r, g, b, secondary and 0.35 or 0.9, PP)
        local lbl = btn:CreateFontString(nil, "OVERLAY")
        lbl:SetFont(FONT, 15, "")
        PP.Point(lbl, "CENTER", btn, "CENTER", 0, 0)
        lbl:SetTextColor(r, g, b, secondary and 0.55 or 0.9)
        lbl:SetText(text)
        btn:SetScript("OnEnter", function()
            lbl:SetTextColor(r, g, b, 1)
            brd:SetColor(r, g, b, secondary and 0.8 or 1)
        end)
        btn:SetScript("OnLeave", function()
            lbl:SetTextColor(r, g, b, secondary and 0.55 or 0.9)
            brd:SetColor(r, g, b, secondary and 0.35 or 0.9)
        end)
        return btn
    end

    local applyBtn = MakeActionButton(EllesmereUI.L("Apply"), EG.r, EG.g, EG.b, false)
    PP.Point(applyBtn, "BOTTOMRIGHT", popup, "BOTTOM", -BTN_GAP / 2, 40)
    applyBtn:SetScript("OnClick", function() Finish(true) end)

    local cancelBtn = MakeActionButton(EllesmereUI.L("Cancel"), 1, 1, 1, true)
    PP.Point(cancelBtn, "BOTTOMLEFT", popup, "BOTTOM", BTN_GAP / 2, 40)
    cancelBtn:SetScript("OnClick", function() Finish(false) end)

    -- Ultrawide: scale and font size cannot fix element placement. Chat, the
    -- minimap and the quest tracker are positioned by Blizzard Edit Mode, and
    -- its 16:9 defaults strand them in the far corners of a 21:9 screen. The
    -- preset gallery already ships ultrawide Edit Mode layouts and auto-selects
    -- Ultrawide Import at this same aspect threshold, so point the player there
    -- rather than rearranging protected frames from here.
    if isUltrawide then
        local uwNote = popup:CreateFontString(nil, "OVERLAY")
        uwNote:SetFont(FONT, 12, "")
        uwNote:SetTextColor(1, 1, 1, 0.45)
        uwNote:SetWidth(POPUP_W - 90)
        uwNote:SetJustifyH("CENTER")
        uwNote:SetWordWrap(true)
        PP.Point(uwNote, "BOTTOM", popup, "BOTTOM", 0, 40 + BTN_H + 44)
        uwNote:SetText(EllesmereUI.L("Ultrawide detected. Blizzard's default layout leaves chat and the minimap in the far corners, which a preset layout fixes."))

        local uwBtn = MakeActionButton(EllesmereUI.L("Browse Ultrawide Layouts"), EG.r, EG.g, EG.b, true)
        PP.Size(uwBtn, BTN_W * 2 + BTN_GAP, BTN_H)
        PP.Point(uwBtn, "BOTTOM", popup, "BOTTOM", 0, 40 + BTN_H + 8)
        uwBtn:SetScript("OnClick", function()
            -- Keep whatever the player already tuned, then hand off.
            Finish(true)
            if EllesmereUI.NavigateToElementSettings then
                EllesmereUI:NavigateToElementSettings("_EUIProfiles", "Presets")
            elseif EllesmereUI.SelectModule then
                EllesmereUI:Show()
                EllesmereUI:SelectModule("_EUIProfiles")
            end
        end)
    end

    local footnote = popup:CreateFontString(nil, "OVERLAY")
    footnote:SetFont(FONT, 12, "")
    footnote:SetTextColor(1, 1, 1, 0.35)
    footnote:SetWidth(POPUP_W - 80)
    footnote:SetJustifyH("CENTER")
    PP.Point(footnote, "BOTTOM", popup, "BOTTOM", 0, 16)
    footnote:SetText(EllesmereUI.L("You can fine-tune all of this later in /eui."))

    -- Escape = Cancel (non-destructive default). Consume Escape, propagate
    -- other keys so chat and UI shortcuts still work behind the dimmer.
    popup:EnableKeyboard(true)
    popup:SetScript("OnKeyDown", function(self, key)
        self:SetPropagateKeyboardInput(key ~= "ESCAPE")
        if key == "ESCAPE" then Finish(false) end
    end)

    dimmer:Show()
end

EllesmereUI.ShowDisplaySetupPopup = ShowDisplaySetupPopup

-------------------------------------------------------------------------------
--  Trigger: fresh installs only, on the login after the picker's reload
-------------------------------------------------------------------------------
local loader = CreateFrame("Frame")
loader:RegisterEvent("ADDON_LOADED")
loader:RegisterEvent("PLAYER_LOGIN")
loader:SetScript("OnEvent", function(self, event, addonName)
    if event == "ADDON_LOADED" then
        if addonName ~= "EllesmereUI" then return end
        self:UnregisterEvent("ADDON_LOADED")
        -- Raise the pending flag this early so the core's conflict-check timer
        -- and every sibling intro popup see it before they schedule.
        if EllesmereUIDB and EllesmereUIDB.displaySetupPending and not EllesmereUIDB.displaySetupShown then
            EllesmereUI._displaySetupPending = true
        end
        return
    end

    self:UnregisterEvent("PLAYER_LOGIN")
    if not (EllesmereUIDB and EllesmereUIDB.displaySetupPending) then return end
    if EllesmereUIDB.displaySetupShown then return end
    if EllesmereUI._externalInstaller then
        EllesmereUIDB.displaySetupPending = nil
        EllesmereUI._displaySetupPending = nil
        return
    end

    local function TryShow()
        if EllesmereUIDB and EllesmereUIDB.displaySetupShown then
            ReleaseConflictCheck()
            return
        end
        -- The picker itself always ends in a reload, but guard anyway so the
        -- two can never overlap.
        if EllesmereUI._firstInstallPending then
            C_Timer.After(0.4, TryShow)
            return
        end
        ShowDisplaySetupPopup()
    end

    -- 0.6s so the Startup PLAYER_ENTERING_WORLD scale adoption has already run
    -- and our baseline snapshot reads the settled value.
    C_Timer.After(0.6, TryShow)
end)

-------------------------------------------------------------------------------
--  Reset command: re-arms the popup for the next /reload. Baselines are always
--  captured from current values, so re-running never double-scales.
-------------------------------------------------------------------------------
SLASH_EUIDISPLAYSETUP1 = "/euidisplaysetup"
SlashCmdList["EUIDISPLAYSETUP"] = function()
    if EllesmereUIDB then
        EllesmereUIDB.displaySetupShown = nil
        EllesmereUIDB.displaySetupPending = true
    end
    print("|cff00ff98EllesmereUI:|r Display Setup reset. The popup fires on your next /reload.")
end
