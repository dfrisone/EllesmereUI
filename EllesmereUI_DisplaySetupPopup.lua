-------------------------------------------------------------------------------
--  EllesmereUI_DisplaySetupPopup.lua
--
--  One-time "Display Setup" popup for fresh installs. Offers a short list of
--  opt-in fixes for settings that land wrong on the player's screen, so people
--  on 1440p, 4K and ultrawide monitors are not left with a UI built for 1080p.
--
--  Without this, a fresh install silently adopts Blizzard's own UIParent scale
--  (EllesmereUI_Startup.lua, PLAYER_ENTERING_WORLD) and never suggests the
--  pixel-perfect value, and every element keeps a position chosen for 16:9.
--
--  Shows on the login AFTER the first-install module picker reloads, so every
--  module the player just enabled is loaded and writable. Armed by
--  EllesmereUIDB.displaySetupPending, written by the picker right before its
--  ReloadUI. Existing users never acquire that flag, so this file is inert for
--  them. Stamped by EllesmereUIDB.displaySetupShown. Reset: /euidisplaysetup.
--
--  Tweaks are opt-in and apply on Finish, not while toggling: several of them
--  write the same profile tables, and applying per-click made the ordering
--  matter. Nothing is touched until the player commits.
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

local SIXTEEN_NINE = 16 / 9

local function Round(v) return floor(v + 0.5) end

local function IsLoaded(folder)
    return C_AddOns and C_AddOns.IsAddOnLoaded and C_AddOns.IsAddOnLoaded(folder) and true or false
end

-------------------------------------------------------------------------------
--  Live profile access
--
--  Do NOT rebuild the path by hand. Spec-linked profiles and overrides get
--  re-pointed through RepointAllDBs, so EllesmereUIDB.profiles[active]
--  .addons[folder] can be a table nothing is reading any more, and writes to it
--  vanish silently. The Lite db registry holds each module's live profile
--  table, which is the one its own options pages write to.
-------------------------------------------------------------------------------
local function AddonProfile(folder)
    local reg = EllesmereUI.Lite and EllesmereUI.Lite._dbRegistry
    if type(reg) == "table" then
        for i = 1, #reg do
            local db = reg[i]
            if db and db.folder == folder and type(db.profile) == "table" then
                return db.profile
            end
        end
    end
    -- Fallback for a module that has not built its db yet.
    if not EllesmereUIDB or not EllesmereUIDB.profiles then return nil end
    local prof = EllesmereUIDB.profiles[EllesmereUIDB.activeProfile or "Default"]
    if type(prof) ~= "table" or type(prof.addons) ~= "table" then return nil end
    local t = prof.addons[folder]
    return type(t) == "table" and t or nil
end

local function FireHook(name)
    local fn = _G[name]
    if type(fn) == "function" then pcall(fn) end
end

-------------------------------------------------------------------------------
--  Font targets
--
--  EUI has no global font-size setting: sizes live in per-module profile keys.
--  Modules carry more than one family of them and which one is live depends on
--  the module's own layout options, so every known key is listed and anything
--  missing or non-numeric is skipped. Listing a key that is not in use costs
--  nothing; missing the one that IS in use is why this looked broken.
-------------------------------------------------------------------------------
local FONT_TARGETS = {
    {
        folder = "EllesmereUIChat", hook = "_ECHAT_RefreshAll",
        resolve = function(p)
            local c = p.chat
            if type(c) ~= "table" then return nil end
            return { { c, "fontSize" }, { c, "tabFontSize" } }
        end,
    },
    {
        folder = "EllesmereUIQuestTracker", hook = "_EQT_RefreshAll",
        resolve = function(p)
            local q = p.questTracker
            if type(q) ~= "table" then return nil end
            return { { q, "titleFontSize" }, { q, "objectiveFontSize" }, { q, "headerFontSize" } }
        end,
    },
    {
        folder = "EllesmereUINameplates", hook = "_ENP_RefreshAllSettings",
        -- Nameplate defaults are flat on the profile. Both the *TextSize and
        -- the shorter *Size families exist and a given layout uses one or the
        -- other, so scale whichever are present.
        resolve = function(p)
            return {
                { p, "friendlyNameSize" }, { p, "friendlyNameTextSize" },
                { p, "enemyNameSize" }, { p, "enemyNameTextSize" },
                { p, "friendlyNPCNameSize" }, { p, "castNameSize" },
                { p, "textSlotLeftSize" }, { p, "textSlotRightSize" },
                { p, "textSlotTopSize" }, { p, "textSlotBottomSize" },
                { p, "auraDurationTextSize" }, { p, "auraStackTextSize" },
                { p, "buffTextSize" }, { p, "ccTextSize" },
                { p, "rangeTextSize" }, { p, "questObjectiveTextSize" },
            }
        end,
    },
    {
        folder = "EllesmereUIDataBars", hook = "_EDB_Apply",
        -- fontScale is per-bar and a percent (baseline 100), not a point size,
        -- but it scales linearly all the same.
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
        folder = "EllesmereUIUnitFrames", hook = "_EUF_ReloadFrames",
        resolve = function(p)
            local keys = { "textSize", "leftTextSize", "rightTextSize", "centerTextSize", "extraTextSize" }
            local out = {}
            for _, u in pairs(p) do
                if type(u) == "table" then
                    for _, k in ipairs(keys) do
                        if type(u[k]) == "number" then out[#out + 1] = { u, k } end
                    end
                end
            end
            return out
        end,
    },
}

-- Collect every live { tbl, key, base } font target plus the hooks to poke.
local function CollectFontTargets()
    local snap, hooks = {}, {}
    for _, target in ipairs(FONT_TARGETS) do
        if IsLoaded(target.folder) then
            local p = AddonProfile(target.folder)
            if p then
                local resolved = target.resolve(p)
                local found = false
                for _, pair in ipairs(resolved or {}) do
                    local tbl, key = pair[1], pair[2]
                    if type(tbl) == "table" and type(tbl[key]) == "number" then
                        snap[#snap + 1] = { tbl = tbl, key = key, base = tbl[key] }
                        found = true
                    end
                end
                if found then hooks[#hooks + 1] = target.hook end
            end
        end
    end
    return snap, hooks
end

-------------------------------------------------------------------------------
--  Ultrawide position correction
--
--  Derived, not a table of hand-placed coordinates. A layout authored for 16:9
--  puts an element a fixed distance either side of centre; on a wider screen
--  the same UI-unit offset lands much further out, because the screen is wider
--  in UI units while the height is unchanged. Multiplying horizontal offsets by
--  (16:9 / actual aspect) puts each element back where it sat relative to the
--  player's eye line. Vertical offsets are untouched: height is the constant.
--
--  This is why an Edit Mode layout alone did not fix anything. That only moves
--  Blizzard's own frames; every EUI element is placed from these profile keys.
-------------------------------------------------------------------------------
local function HorizontalPullFactor(aspect)
    if not aspect or aspect <= SIXTEEN_NINE then return 1 end
    return SIXTEEN_NINE / aspect
end

-- Anything with a numeric x and a point/relPoint pair is a stored anchor.
local function IsAnchorTable(t)
    return type(t) == "table" and type(t.x) == "number" and type(t.point) == "string"
end

-- Walk a profile sub-table and collect every stored anchor's x, so the same
-- rule covers bar positions, minimap position and damage meter windows without
-- naming each one. Bounded depth: these live 2-3 levels down and a blind deep
-- walk would wander into unrelated data.
local function CollectAnchors(root, depth, out)
    if type(root) ~= "table" or depth > 3 then return end
    for _, v in pairs(root) do
        if IsAnchorTable(v) then
            out[#out + 1] = { tbl = v, key = "x", base = v.x }
        elseif type(v) == "table" then
            CollectAnchors(v, depth + 1, out)
        end
    end
end

local POSITION_MODULES = {
    { folder = "EllesmereUIActionBars", hook = "_EAB_Apply", key = "barPositions" },
    { folder = "EllesmereUIMinimap",    hook = "_EMM_FullRebuildMinimap", key = "minimap" },
    { folder = "EllesmereUIDamageMeters", hook = "_EDM_Apply", key = "dm" },
    { folder = "EllesmereUIUnitFrames", hook = "_EUF_ReloadFrames", key = nil },
}

local function CollectPositionTargets()
    local snap, hooks = {}, {}
    for _, m in ipairs(POSITION_MODULES) do
        if IsLoaded(m.folder) then
            local p = AddonProfile(m.folder)
            if p then
                local root = m.key and p[m.key] or p
                local before = #snap
                CollectAnchors(root, 1, snap)
                if #snap > before then hooks[#hooks + 1] = m.hook end
            end
        end
    end
    return snap, hooks
end

-------------------------------------------------------------------------------
--  Conflict-check handoff
--
--  The addon-conflict check auto-runs a couple of seconds after load, gated on
--  firstInstallPopupShown and the intro pending flags. This popup runs FIRST in
--  the chain, so it only releases when nothing else is queued behind it.
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

    local physW, physH = GetPhysicalScreenSize()
    physW = (type(physW) == "number" and physW > 0) and physW or 1920
    physH = (type(physH) == "number" and physH > 0) and physH or 1080
    local aspect = physW / physH
    -- Same threshold the preset gallery uses, so the two never disagree.
    local isUltrawide = aspect >= 2.0

    local bestScale = (EllesmereUI.PP and EllesmereUI.PP.PixelBestSize
        and EllesmereUI.PP.PixelBestSize()) or 0.7111111111
    local curScale = (EllesmereUIDB and EllesmereUIDB.ppUIScale) or bestScale
    local scaleIsOff = abs(curScale - bestScale) > 0.005

    local fontSnap, fontHooks = CollectFontTargets()
    local posSnap, posHooks = CollectPositionTargets()
    local pullFactor = HorizontalPullFactor(aspect)

    local screenLabel = string.format("%dx%d", physW, physH)
    local kindLabel
    if isUltrawide then kindLabel = EllesmereUI.L("Ultrawide")
    elseif physH >= 1900 then kindLabel = EllesmereUI.L("4K")
    elseif physH >= 1300 then kindLabel = EllesmereUI.L("1440p")
    else kindLabel = EllesmereUI.L("1080p") end

    ---------------------------------------------------------------------------
    --  Tweak list. Each entry is a named, opt-in fix; only offered when it has
    --  something to change, so nobody is shown a toggle that would do nothing.
    ---------------------------------------------------------------------------
    local fontFactor = 1.15
    local tweaks = {}

    if scaleIsOff then
        tweaks[#tweaks + 1] = {
            key = "scale",
            label = EllesmereUI.L("Pixel Perfect Scale"),
            apply = function()
                if EllesmereUI.PP and EllesmereUI.PP.SetUIScale then
                    EllesmereUI.PP.SetUIScale(bestScale)
                    EllesmereUIDB.ppUIScaleAuto = false
                end
            end,
        }
    end

    if #fontSnap > 0 then
        tweaks[#tweaks + 1] = {
            key = "font",
            label = EllesmereUI.L("Change Font Size"),
            stepper = true,
            apply = function()
                for _, e in ipairs(fontSnap) do
                    e.tbl[e.key] = max(1, Round(e.base * fontFactor))
                end
                for _, h in ipairs(fontHooks) do FireHook(h) end
            end,
        }
    end

    if isUltrawide and #posSnap > 0 then
        tweaks[#tweaks + 1] = {
            key = "positions",
            label = EllesmereUI.L("Element Positions"),
            apply = function()
                for _, e in ipairs(posSnap) do
                    e.tbl[e.key] = e.base * pullFactor
                end
                for _, h in ipairs(posHooks) do FireHook(h) end
            end,
        }
    end

    if isUltrawide and IsLoaded("EllesmereUIMinimap") then
        local mm = AddonProfile("EllesmereUIMinimap")
        local mmCfg = mm and mm.minimap
        if type(mmCfg) == "table" and type(mmCfg.mapSize) == "number" then
            local baseSize = mmCfg.mapSize
            tweaks[#tweaks + 1] = {
                key = "minimap",
                label = EllesmereUI.L("Bigger Minimap"),
                apply = function()
                    mmCfg.mapSize = Round(baseSize * 1.25)
                    FireHook("_EMM_FullRebuildMinimap")
                end,
            }
        end
    end

    ---------------------------------------------------------------------------
    --  Layout. Fixed content box; every number below is derived from it.
    ---------------------------------------------------------------------------
    local POPUP_W = 470
    local HEADER_H = 26
    local ROW_H, BTN_W, COL = 28, 190, 98
    local rows = floor((#tweaks + 1) / 2)
    local DESC_TOP = HEADER_H + 44
    local GRID_TOP = DESC_TOP + 52
    local POPUP_H = GRID_TOP + rows * ROW_H + 84

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

    local popup = CreateFrame("Frame", "EUIDisplaySetupPopup", dimmer)
    popup:SetScale(ppScale)
    popup:SetFrameStrata("FULLSCREEN_DIALOG")
    popup:SetFrameLevel(dimmer:GetFrameLevel() + 10)
    PP.Size(popup, POPUP_W, POPUP_H)
    popup:SetPoint("CENTER", UIParent, "CENTER", 0, 0)
    popup:EnableMouse(true)

    local bg = popup:CreateTexture(nil, "BACKGROUND")
    bg:SetAllPoints()
    bg:SetColorTexture(0.06, 0.08, 0.10, 1)

    -- 1 physical-pixel white border, scale-derived so each edge stays exactly
    -- one physical pixel. Four edge textures, snap disabled.
    local onePhys = 1 / (popup:GetEffectiveScale() or 1)
    local function MakeEdge()
        local t = popup:CreateTexture(nil, "BORDER")
        t:SetColorTexture(1, 1, 1, 0.15)
        if t.SetSnapToPixelGrid then t:SetSnapToPixelGrid(false); t:SetTexelSnappingBias(0) end
        return t
    end
    local spT = MakeEdge(); spT:SetPoint("TOPLEFT", 0, 0); spT:SetPoint("TOPRIGHT", 0, 0); spT:SetHeight(onePhys)
    local spB = MakeEdge(); spB:SetPoint("BOTTOMLEFT", 0, 0); spB:SetPoint("BOTTOMRIGHT", 0, 0); spB:SetHeight(onePhys)
    local spL = MakeEdge(); spL:SetPoint("TOPLEFT", spT, "BOTTOMLEFT"); spL:SetPoint("BOTTOMLEFT", spB, "TOPLEFT"); spL:SetWidth(onePhys)
    local spR = MakeEdge(); spR:SetPoint("TOPRIGHT", spT, "BOTTOMRIGHT"); spR:SetPoint("BOTTOMRIGHT", spB, "TOPRIGHT"); spR:SetWidth(onePhys)

    -- Header strip: addon name on the left, detected screen on the right.
    local headerBg = popup:CreateTexture(nil, "BORDER")
    headerBg:SetColorTexture(0.09, 0.11, 0.13, 1)
    PP.Size(headerBg, POPUP_W, HEADER_H)
    PP.Point(headerBg, "TOP", popup, "TOP", 0, 0)

    local brand = popup:CreateFontString(nil, "OVERLAY")
    brand:SetFont(FONT, 13, "")
    brand:SetTextColor(EG.r, EG.g, EG.b, 0.95)
    PP.Point(brand, "LEFT", popup, "TOPLEFT", 12, -HEADER_H / 2)
    brand:SetText("EllesmereUI")

    local screenTag = popup:CreateFontString(nil, "OVERLAY")
    screenTag:SetFont(FONT, 11, "")
    screenTag:SetTextColor(1, 1, 1, 0.45)
    PP.Point(screenTag, "RIGHT", popup, "TOPRIGHT", -12, -HEADER_H / 2)
    screenTag:SetText(screenLabel .. "  " .. kindLabel)

    local title = popup:CreateFontString(nil, "OVERLAY")
    title:SetFont(FONT, 20, "")
    title:SetTextColor(1, 1, 1, 1)
    PP.Point(title, "TOP", popup, "TOP", 0, -(HEADER_H + 12))
    title:SetText(EllesmereUI.L("Display Setup"))

    local desc = popup:CreateFontString(nil, "OVERLAY")
    desc:SetFont(FONT, 13, "")
    desc:SetTextColor(1, 1, 1, 0.5)
    desc:SetWidth(POPUP_W - 60)
    desc:SetJustifyH("CENTER")
    desc:SetWordWrap(true)
    PP.Point(desc, "TOP", popup, "TOP", 0, -DESC_TOP)
    desc:SetText(EllesmereUI.Lf("Detected a %1$s display. These correct settings that land wrong on this screen. Enable what you want, they apply when you click Finish.", screenLabel))

    ---------------------------------------------------------------------------
    --  Toggle rows
    ---------------------------------------------------------------------------
    local function MakeToggle(tweak, index)
        local col = (index % 2 == 1) and -COL or COL
        local row = floor((index - 1) / 2)

        local b = CreateFrame("Button", nil, popup)
        b:SetFrameLevel(popup:GetFrameLevel() + 2)
        PP.Size(b, BTN_W, 24)
        PP.Point(b, "TOP", popup, "TOP", col, -(GRID_TOP + row * ROW_H))

        local bbg = b:CreateTexture(nil, "BACKGROUND")
        bbg:SetAllPoints()
        bbg:SetColorTexture(0.10, 0.12, 0.14, 0.95)
        local brd = MakeBorder(b, 1, 1, 1, 0.12, PP)

        local lbl = b:CreateFontString(nil, "OVERLAY")
        lbl:SetFont(FONT, 12, "")
        PP.Point(lbl, "CENTER", b, "CENTER", 0, 0)
        lbl:SetText(tweak.label)

        local function Paint()
            if tweak.on then
                lbl:SetTextColor(EG.r, EG.g, EG.b, 1)
                brd:SetColor(EG.r, EG.g, EG.b, 0.85)
            else
                lbl:SetTextColor(1, 1, 1, 0.55)
                brd:SetColor(1, 1, 1, 0.12)
            end
        end
        b:SetScript("OnClick", function() tweak.on = not tweak.on; Paint() end)
        b:SetScript("OnEnter", function() if not tweak.on then lbl:SetTextColor(1, 1, 1, 0.85) end end)
        b:SetScript("OnLeave", Paint)
        tweak._paint = Paint
        Paint()
        return b
    end

    local toggleBtns = {}
    for i, tweak in ipairs(tweaks) do
        toggleBtns[i] = MakeToggle(tweak, i)
    end

    -- Font stepper, parked beside its own toggle.
    local fontTweak
    for _, t in ipairs(tweaks) do if t.key == "font" then fontTweak = t end end
    if fontTweak then
        local idx
        for i, t in ipairs(tweaks) do if t == fontTweak then idx = i end end
        local col = (idx % 2 == 1) and -COL or COL
        local row = floor((idx - 1) / 2)

        local wrap = CreateFrame("Frame", nil, popup)
        wrap:SetFrameLevel(popup:GetFrameLevel() + 2)
        PP.Size(wrap, BTN_W, 22)
        PP.Point(wrap, "TOP", popup, "TOP", col, -(GRID_TOP + row * ROW_H + 26))

        local valTxt = wrap:CreateFontString(nil, "OVERLAY")
        valTxt:SetFont(FONT, 12, "")
        valTxt:SetTextColor(EG.r, EG.g, EG.b, 0.95)
        PP.Point(valTxt, "CENTER", wrap, "CENTER", 0, 0)

        local minusBtn, plusBtn
        local function Refresh()
            valTxt:SetText(string.format("%d%%", Round(fontFactor * 100)))
            minusBtn:SetAlpha(fontFactor > 1.0 and 1 or 0.35)
            plusBtn:SetAlpha(fontFactor < 1.6 and 1 or 0.35)
        end

        local function MakeArrow(text, point, delta)
            local b = CreateFrame("Button", nil, wrap)
            b:SetFrameLevel(wrap:GetFrameLevel() + 1)
            PP.Size(b, 20, 20)
            PP.Point(b, point, wrap, point, 0, 0)
            local t = b:CreateFontString(nil, "OVERLAY")
            t:SetFont(FONT, 14, "")
            t:SetTextColor(1, 1, 1, 0.8)
            PP.Point(t, "CENTER", b, "CENTER", 0, 0)
            t:SetText(text)
            b:SetScript("OnClick", function()
                fontFactor = max(1.0, min(1.6, fontFactor + delta))
                Refresh()
            end)
            return b
        end
        minusBtn = MakeArrow("-", "LEFT", -0.05)
        plusBtn  = MakeArrow("+", "RIGHT", 0.05)
        Refresh()
    end

    ---------------------------------------------------------------------------
    --  Finish
    ---------------------------------------------------------------------------
    local function Finish()
        if not EllesmereUIDB then EllesmereUIDB = {} end

        local scaleChanged = false
        for _, tweak in ipairs(tweaks) do
            if tweak.on then
                pcall(tweak.apply)
                if tweak.key == "scale" then scaleChanged = true end
            end
        end

        EllesmereUIDB.displaySetupShown = true
        EllesmereUIDB.displaySetupPending = nil
        dimmer:Hide()
        ReleaseConflictCheck()

        -- Positions and scale both need a settle; the Edit Mode snapping
        -- caveat is the same one the options-page scale slider raises.
        local touched = scaleChanged
        for _, tweak in ipairs(tweaks) do
            if tweak.on and tweak.key == "positions" then touched = true end
        end
        if touched and EllesmereUI.ShowConfirmPopup then
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
    local function MakeActionButton(text, r, g, b, secondary, w)
        local btn = CreateFrame("Button", nil, popup)
        btn:SetFrameLevel(popup:GetFrameLevel() + 2)
        PP.Size(btn, w or 150, 28)
        local bbg = btn:CreateTexture(nil, "BACKGROUND")
        bbg:SetAllPoints()
        bbg:SetColorTexture(0.06, 0.08, 0.10, 0.92)
        local brd = MakeBorder(btn, r, g, b, secondary and 0.35 or 0.9, PP)
        local lbl = btn:CreateFontString(nil, "OVERLAY")
        lbl:SetFont(FONT, 13, "")
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

    local allBtn = MakeActionButton(EllesmereUI.L("Enable All"), 1, 1, 1, true, 130)
    PP.Point(allBtn, "BOTTOM", popup, "BOTTOM", 0, 46)
    allBtn:SetScript("OnClick", function()
        for _, t in ipairs(tweaks) do
            t.on = true
            if t._paint then t._paint() end
        end
    end)

    local finishBtn = MakeActionButton(EllesmereUI.L("Finish"), EG.r, EG.g, EG.b, false, 130)
    PP.Point(finishBtn, "BOTTOMRIGHT", popup, "BOTTOMRIGHT", -14, 12)
    finishBtn:SetScript("OnClick", Finish)

    local skipBtn = MakeActionButton(EllesmereUI.L("Skip"), 1, 1, 1, true, 100)
    PP.Point(skipBtn, "BOTTOMLEFT", popup, "BOTTOMLEFT", 14, 12)
    skipBtn:SetScript("OnClick", function()
        for _, t in ipairs(tweaks) do t.on = false end
        Finish()
    end)

    -- Escape = Skip (nothing applied). Consume Escape, propagate other keys so
    -- chat and UI shortcuts still work behind the dimmer.
    popup:EnableKeyboard(true)
    popup:SetScript("OnKeyDown", function(self, key)
        self:SetPropagateKeyboardInput(key ~= "ESCAPE")
        if key == "ESCAPE" then
            for _, t in ipairs(tweaks) do t.on = false end
            Finish()
        end
    end)

    -- Nothing to offer: stamp and hand off rather than showing an empty panel.
    if #tweaks == 0 then
        EllesmereUIDB.displaySetupShown = true
        EllesmereUIDB.displaySetupPending = nil
        ReleaseConflictCheck()
        return
    end

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
        -- Raised this early so the core's conflict-check timer and every
        -- sibling intro popup see it before they schedule.
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
        if EllesmereUI._firstInstallPending then
            C_Timer.After(0.4, TryShow)
            return
        end
        ShowDisplaySetupPopup()
    end

    -- 0.6s so the Startup PLAYER_ENTERING_WORLD scale adoption has already run
    -- and the baseline reads the settled value.
    C_Timer.After(0.6, TryShow)
end)

-------------------------------------------------------------------------------
--  Reset command: re-arms the popup for the next /reload.
-------------------------------------------------------------------------------
SLASH_EUIDISPLAYSETUP1 = "/euidisplaysetup"
SlashCmdList["EUIDISPLAYSETUP"] = function()
    if EllesmereUIDB then
        EllesmereUIDB.displaySetupShown = nil
        EllesmereUIDB.displaySetupPending = true
    end
    print("|cff00ff98EllesmereUI:|r Display Setup reset. The popup fires on your next /reload.")
end

-------------------------------------------------------------------------------
--  Layout capture (authoring tool)
--
--  Positions that "just look right" cannot be derived: a multiplier only
--  rescales whatever the player already had. They have to be authored once, on
--  the target screen, by arranging the UI and recording where things ended up.
--
--  This writes the current anchor set into EllesmereUIDB._layoutCapture rather
--  than printing it: the useful dump is far past the ~255 character chat input
--  limit, and SavedVariables flush on /reload, so the values can be read
--  straight out of the account file afterwards.
--
--  Author-facing only. It records, it never applies.
-------------------------------------------------------------------------------
local CAPTURE_MODULES = {
    { folder = "EllesmereUIActionBars",   key = "barPositions" },
    { folder = "EllesmereUIMinimap",      key = "minimap" },
    { folder = "EllesmereUIDamageMeters", key = "dm" },
    { folder = "EllesmereUIUnitFrames",   key = nil },
    { folder = "EllesmereUIResourceBars", key = nil },
    { folder = "EllesmereUICooldownManager", key = nil },
}

-- Record path -> anchor for every stored anchor under a module, so the capture
-- says WHERE each value came from and can be pasted back as a defaults table.
local function CaptureAnchors(root, path, depth, out)
    if type(root) ~= "table" or depth > 4 then return end
    for k, v in pairs(root) do
        if type(k) == "string" or type(k) == "number" then
            local here = path .. "." .. tostring(k)
            if IsAnchorTable(v) then
                out[here] = {
                    point = v.point, relPoint = v.relPoint,
                    x = v.x, y = v.y,
                }
            elseif type(v) == "table" then
                CaptureAnchors(v, here, depth + 1, out)
            end
        end
    end
end

SLASH_EUIUWCAPTURE1 = "/euiuwcapture"
SlashCmdList["EUIUWCAPTURE"] = function()
    if not EllesmereUIDB then
        print("|cffff6600EllesmereUI:|r no saved variables yet.")
        return
    end
    local physW, physH = GetPhysicalScreenSize()
    local out = {
        screenW = physW, screenH = physH,
        uiScale = EllesmereUIDB.ppUIScale,
        panelScale = EllesmereUIDB.panelScale,
        profile = EllesmereUIDB.activeProfile,
        anchors = {},
    }
    local count = 0
    for _, m in ipairs(CAPTURE_MODULES) do
        if IsLoaded(m.folder) then
            local p = AddonProfile(m.folder)
            if p then
                local root = m.key and p[m.key] or p
                local base = m.folder .. (m.key and ("." .. m.key) or "")
                local before = {}
                CaptureAnchors(root, base, 1, before)
                for path, anchor in pairs(before) do
                    out.anchors[path] = anchor
                    count = count + 1
                end
            end
        end
    end
    -- Sizes worth carrying alongside the anchors: a layout is positions AND
    -- the footprint of the things being positioned.
    local mm = IsLoaded("EllesmereUIMinimap") and AddonProfile("EllesmereUIMinimap")
    if mm and type(mm.minimap) == "table" then out.minimapSize = mm.minimap.mapSize end

    EllesmereUIDB._layoutCapture = out
    print(string.format("|cff00ff98EllesmereUI:|r captured %d anchors at %dx%d (profile: %s).",
        count, physW or 0, physH or 0, tostring(EllesmereUIDB.activeProfile)))
    print("|cff00ff98EllesmereUI:|r now /reload so it is written to disk.")
end
