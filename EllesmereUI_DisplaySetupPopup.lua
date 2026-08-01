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

-- The ultrawide Edit Mode layout shipped with the EllesmereUI preset.
-- Blizzard owns the quest tracker and the chat frame: EUI only ever hides and
-- reveals ObjectiveTrackerFrame, it never positions it, so no profile write can
-- move them. An Edit Mode layout is the only lever, and the preset table
-- already carries one keyed by UI scale.
local function UltrawideEditModeString()
    local presets = EllesmereUI.POPULAR_PRESETS
    if type(presets) ~= "table" then return nil end
    local function usable(v) return type(v) == "string" and v ~= "" end
    for _, preset in ipairs(presets) do
        if preset.name == "EllesmereUI" and type(preset.editMode) == "table" then
            local uw = preset.editMode.ultrawide
            if type(uw) == "table" then
                -- Closest scale variant first, then the other as a fallback:
                -- the same rule the preset gallery uses.
                local scale = (EllesmereUIDB and EllesmereUIDB.ppUIScale) or 0.5333333333
                local first, second = "s53", "s64"
                if math.abs(scale - 0.64) <= math.abs(scale - 0.5333333333) then
                    first, second = "s64", "s53"
                end
                if usable(uw[first]) then return uw[first] end
                if usable(uw[second]) then return uw[second] end
            end
        end
    end
    return nil
end

local function FireHook(name)
    local fn = _G[name]
    if type(fn) == "function" then pcall(fn) end
end

-------------------------------------------------------------------------------
--  Font keys
--
--  Found by name, not from a hand-kept list. The first version listed keys
--  explicitly, picked friendlyNameTextSize when the live key was
--  friendlyNameSize, and silently scaled nothing: a list goes stale the moment
--  a module adds a key, and nothing tells you it has.
--
--  The two ways of being wrong are not equally bad. Missing a key leaves that
--  text at its old size, which is visible and easily fixed. Scaling something
--  that is not a font size corrupts it silently, and an alpha, a percentage or
--  a character limit all look like plain numbers in a profile. So this is an
--  allow-list of font-shaped names: anything not positively recognised is left
--  alone, and recognised names still have to hold a plausible value.
-------------------------------------------------------------------------------

-- Names that look font-shaped but are not point sizes.
local FONT_DENY = {
    "[Pp]ct$", "[Pp]ercent$",     -- ratios: maxTextWidthPct
    "[Aa]lpha", "[Oo]pacity",
    "[Cc]olou?r",
    "[Oo]utline", "[Ss]hadow",    -- style flags, often 0/1
    "[Mm]axLength$", "[Mm]axLetters$", "[Pp]recision$",
    "[Ss]pacing", "[Pp]adding",   -- lengths, but not text
}

-- Ordered, first match wins. Deliberately narrow: only names that can only
-- mean text. A bare trailing "Size" is NOT here, because iconSize, mapSize,
-- markerSize and buttonSize all end that way and none of them are fonts.
local FONT_KIND = {
    { "[Ff]ont[Ss]cale$", "percent" },  -- DataBars: 100 = unchanged
    { "[Ff]ont[Ss]ize",   "point"   },  -- fontSize, tabFontSize, titleFontSize
    { "[Tt]ext.*[Ss]ize$", "point"  },  -- textSize, auraDurationTextSize, textSlotLeftSize
    { "[Nn]ame[Ss]ize$",  "point"   },  -- friendlyNameSize, castNameSize
}

-- Plausible ranges. A recognised name holding a wildly out-of-range value is
-- almost certainly something else wearing a font-shaped name, so it is skipped.
local PT_MIN_SEEN, PT_MAX_SEEN = 4, 48
local PCT_MIN_SEEN, PCT_MAX_SEEN = 25, 400
local PT_FLOOR, PCT_FLOOR = 8, 50

local _fontKindCache = {}

local function ClassifyFontKey(key)
    if type(key) ~= "string" then return nil end
    local cached = _fontKindCache[key]
    if cached ~= nil then
        if cached == false then return nil end
        return cached
    end
    for i = 1, #FONT_DENY do
        if key:find(FONT_DENY[i]) then
            _fontKindCache[key] = false
            return nil
        end
    end
    for i = 1, #FONT_KIND do
        if key:find(FONT_KIND[i][1]) then
            _fontKindCache[key] = FONT_KIND[i][2]
            return FONT_KIND[i][2]
        end
    end
    _fontKindCache[key] = false
    return nil
end

-- Walk a profile for font keys. Bounded depth: profile blobs are shallow, and
-- the limit is a cycle guard rather than a real constraint.
local function CollectFontKeys(node, depth, out)
    if type(node) ~= "table" or depth > 8 then return end
    for k, v in pairs(node) do
        if type(v) == "table" then
            CollectFontKeys(v, depth + 1, out)
        elseif type(v) == "number" then
            local kind = ClassifyFontKey(k)
            if kind == "point" and v >= PT_MIN_SEEN and v <= PT_MAX_SEEN then
                out[#out + 1] = { tbl = node, key = k, base = v, kind = kind }
            elseif kind == "percent" and v >= PCT_MIN_SEEN and v <= PCT_MAX_SEEN then
                out[#out + 1] = { tbl = node, key = k, base = v, kind = kind }
            end
        end
    end
end

-- Every module that registers a profile DB, so a module added later is covered
-- without naming it here.
local function CollectFontTargets()
    local out = {}
    local reg = EllesmereUI.Lite and EllesmereUI.Lite._dbRegistry
    if type(reg) ~= "table" then return out end
    local seen = {}
    for i = 1, #reg do
        local db = reg[i]
        if db and type(db.profile) == "table" and not seen[db.profile] then
            seen[db.profile] = true
            CollectFontKeys(db.profile, 1, out)
        end
    end
    return out
end

-- Apply a factor to a collected set, clamped so nothing lands unreadable.
local function ApplyFontFactor(snap, factor)
    for _, e in ipairs(snap) do
        local v = Round(e.base * factor)
        if e.kind == "percent" then
            e.tbl[e.key] = max(PCT_FLOOR, v)
        else
            e.tbl[e.key] = max(PT_FLOOR, v)
        end
    end
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
-- x means different things depending on the anchor, which is the whole trick:
--
--   CENTER / TOP / BOTTOM   x is an offset either side of the screen midline.
--                           Widening the screen does not move the midline, but
--                           a layout authored for 16:9 chose that offset
--                           against a narrower screen, so scale it by
--                           (16:9 / aspect) to keep the same relative reach.
--
--   LEFT / RIGHT / corners  x is an offset from a screen EDGE, and the edge
--                           itself has moved outward by half the extra width.
--                           Push it back in by exactly that much. Scaling these
--                           drags them further INTO the corner, which is why
--                           edge-anchored elements ended up worse, not better.
--
-- Net effect: every element lands where it would sit on a 16:9 screen of the
-- same height. Vertical offsets are never touched; height is the constant.
local function HorizontalPullFactor(aspect)
    if not aspect or aspect <= SIXTEEN_NINE then return 1 end
    return SIXTEEN_NINE / aspect
end

-- UI units of extra width per side versus a 16:9 screen of the same height.
local function HalfExcessWidth()
    local w, h = GetScreenWidth(), GetScreenHeight()
    if type(w) ~= "number" or type(h) ~= "number" or h <= 0 then return 0 end
    return max(0, (w - h * SIXTEEN_NINE) / 2)
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
            out[#out + 1] = { tbl = v, key = "x", base = v.x, point = v.point }
        elseif type(v) == "table" then
            CollectAnchors(v, depth + 1, out)
        end
    end
end

-- Every movable element registers a loadPosition/savePosition pair with Unlock
-- Mode, keyed by element. Going through that registry reaches minimap, chat,
-- damage meters, the cooldown manager and everything else in one pass, using
-- each module's own storage convention. Walking profile tables by guessed key
-- paths reached almost nothing, which is why only a couple of things shifted.
-- Offset of a frame's centre from UIParent's centre, in UIParent units.
-- Both sides are converted through their effective scale because an element
-- may be running at a different scale to UIParent.
local function CentreOffset(f)
    if not f or not f.GetCenter then return nil end
    local fx, fy = f:GetCenter()
    local ux, uy = UIParent:GetCenter()
    if not (fx and fy and ux and uy) then return nil end
    local fs = f:GetEffectiveScale() or 1
    local us = UIParent:GetEffectiveScale() or 1
    if us == 0 then return nil end
    return (fx * fs - ux * us) / us, (fy * fs - uy * us) / us
end

local function CollectRegisteredPositions()
    local out = {}
    local reg = EllesmereUI._unlockRegisteredElements
    if type(reg) ~= "table" then return out end
    for key, elem in pairs(reg) do
        if type(elem) == "table" and elem.savePosition then
            local pos
            if elem.loadPosition then
                local ok, p = pcall(elem.loadPosition, key)
                if ok and type(p) == "table"
                   and type(p.x) == "number" and type(p.point) == "string" then
                    pos = p
                end
            end
            if pos then
                out[#out + 1] = { key = key, elem = elem, pos = pos }
            else
                -- No stored position: the element is sitting on its default
                -- anchor, which is computed at runtime and has nothing to
                -- correct. This is most of them on a fresh install, and it is
                -- why almost nothing moved. Read where the frame actually IS,
                -- and store that as an explicit CENTER anchor so there is a
                -- position to correct. Repositioning has to CREATE anchors
                -- here, not just adjust the handful the player has dragged.
                local f
                if elem.getFrame then
                    local ok, got = pcall(elem.getFrame, key)
                    if ok then f = got end
                end
                if f and f.GetCenter and f:IsShown() then
                    local ox, oy = CentreOffset(f)
                    if ox and oy then
                        out[#out + 1] = {
                            key = key, elem = elem, synthesised = true,
                            pos = { point = "CENTER", relPoint = "CENTER", x = ox, y = oy },
                        }
                    end
                end
            end
        end
    end
    return out
end

-- Action bars are NOT registered elements: they fall back to their own
-- barPositions store, so they need the direct walk.
local function CollectBarPositions()
    local snap = {}
    if IsLoaded("EllesmereUIActionBars") then
        local p = AddonProfile("EllesmereUIActionBars")
        if p and type(p.barPositions) == "table" then
            CollectAnchors(p.barPositions, 1, snap)
        end
    end
    return snap
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

    local fontSnap = CollectFontTargets()

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
    -- Font size is chosen as a point size, not a percentage: "14" means
    -- something, "115%" does not. EUI's own sizes cluster around 12 (chat 12,
    -- nameplate names 12, quest title 12, quest header 13, quest objective 10),
    -- so 12 is the anchor and every mapped key scales by size/anchor.
    -- Bounds: below 10 the smallest mapped text (quest objectives) stops being
    -- readable; above 20 the largest (quest headers) overruns its own row.
    local FONT_ANCHOR, FONT_MIN, FONT_MAX = 12, 10, 20
    local chatProfile = IsLoaded("EllesmereUIChat") and AddonProfile("EllesmereUIChat")
    if chatProfile and type(chatProfile.chat) == "table"
       and type(chatProfile.chat.fontSize) == "number" then
        FONT_ANCHOR = chatProfile.chat.fontSize
    end
    local fontSize = max(FONT_MIN, min(FONT_MAX, FONT_ANCHOR + 2))
    local fontFactor = fontSize / FONT_ANCHOR
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
            label = EllesmereUI.L("Font Size"),
            stepper = true,
            apply = function()
                ApplyFontFactor(fontSnap, fontSize / FONT_ANCHOR)
            end,
            -- Settled by the reload rather than by poking each module's own
            -- refresh: the keys are discovered generically, so there is no
            -- reliable hook list to keep alongside them.
            needsReload = true,
        }
    end

    -- Ultrawide layout.
    --
    -- Derived from screen geometry. /euiuwdebug confirmed every EUI element
    -- sits inside the centred 16:9 region, leaving a band of unused width down
    -- each side of an ultrawide screen. These few elements read better out in
    -- that space; everything the player watches while fighting stays centred.
    --
    -- Placement is expressed as flush-to-edge rules rather than measured
    -- coordinates, so the same expressions hold at 21:9 and 32:9. Each element
    -- is positioned from the screen edge and its own footprint:
    --
    --   minimap   inset from the top-right corner
    --   meters    flush into the bottom-right corner, side by side
    --   raid      flush to the left edge, below the centre line
    if isUltrawide then
        local EDGE_INSET = 20

        -- Walk a dotted path, creating tables, and set the leaf. Numeric
        -- segments become NUMBER keys: profile arrays are indexed windows[1],
        -- and a string "1" is a different key that nothing ever reads.
        local function SetPath(root, path, value)
            if type(root) ~= "table" then return false end
            local parts = {}
            for part in path:gmatch("[^.]+") do
                parts[#parts + 1] = tonumber(part) or part
            end
            if #parts == 0 then return false end
            local node = root
            for i = 1, #parts - 1 do
                local k = parts[i]
                if type(node[k]) ~= "table" then node[k] = {} end
                node = node[k]
            end
            node[parts[#parts]] = value
            return true
        end

        local function Anchor(x, y)
            return { point = "CENTER", relPoint = "CENTER", x = x, y = y }
        end

        local planned = {}
        local halfW = (GetScreenWidth() or 0) / 2
        local halfH = (GetScreenHeight() or 0) / 2

        -- Minimap: flush into the top-right corner.
        --
        -- Measured off the live frame, not off mapSize. mapSize is the map
        -- texture; the frame that actually gets positioned carries a border on
        -- top of it, so at mapSize 270 the footprint is 288. Using the setting
        -- would leave a 9-unit gap down two edges that no amount of tuning the
        -- inset fixes, because the error scales with the border, not the size.
        local mmProfile = IsLoaded("EllesmereUIMinimap") and AddonProfile("EllesmereUIMinimap")
        local mmCfg = mmProfile and mmProfile.minimap
        local mapSize = 200
        if type(mmCfg) == "table" then
            if type(mmCfg.mapSize) == "number" then mapSize = mmCfg.mapSize end
            local footprint = mapSize
            local mmFrame = _G.Minimap
            if mmFrame and mmFrame.GetWidth then
                local fw = mmFrame:GetWidth()
                -- Guard against a frame that has not been sized yet: a bogus
                -- reading would park the minimap somewhere arbitrary.
                if type(fw) == "number" and fw > mapSize * 0.5 and fw < mapSize * 2 then
                    footprint = fw
                end
            end
            planned[#planned + 1] = {
                profile = mmProfile, path = "minimap.position",
                value = Anchor(halfW - footprint / 2, halfH - footprint / 2),
            }
        end

        -- Damage meters: flush into the bottom-right corner, side by side so
        -- the pair reads as one block rather than a tall column.
        local DM_W, DM_H = 250, 263
        local dmProfile = IsLoaded("EllesmereUIDamageMeters") and AddonProfile("EllesmereUIDamageMeters")
        if type(dmProfile) == "table" then
            local y = -halfH + DM_H / 2
            for i = 1, 2 do
                local x = halfW - DM_W / 2 - (i - 1) * DM_W
                planned[#planned + 1] = { profile = dmProfile,
                    path = "dm.windows." .. i .. ".position", value = Anchor(x, y) }
                planned[#planned + 1] = { profile = dmProfile,
                    path = "dm.windows." .. i .. ".width",  value = DM_W }
                planned[#planned + 1] = { profile = dmProfile,
                    path = "dm.windows." .. i .. ".height", value = DM_H }
            end
        end

        -- Raid frames: flush to the left edge. The container is as wide as a
        -- full row of five frames, so its half-width comes from the configured
        -- frame width rather than a fixed number.
        local rfProfile = IsLoaded("EllesmereUIRaidFrames") and AddonProfile("EllesmereUIRaidFrames")
        if type(rfProfile) == "table" then
            local frameW = (type(rfProfile.frameWidth) == "number" and rfProfile.frameWidth) or 100
            local halfRaid = frameW * 5 / 2
            planned[#planned + 1] = {
                profile = rfProfile, path = "unlockPos",
                value = Anchor(-halfW + halfRaid, -halfH * 0.365),
            }
        end

        if #planned > 0 then
            tweaks[#tweaks + 1] = {
                key = "positions",
                label = EllesmereUI.L("Ultrawide Layout"),
                -- Replaces the active Edit Mode layout, so it is called out
                -- rather than left as a surprise.
                note = EllesmereUI.L("Also replaces your Edit Mode layout"),
                apply = function()
                    for _, item in ipairs(planned) do
                        SetPath(item.profile, item.path, item.value)
                    end
                    -- Blizzard-owned frames (quest tracker, chat) cannot be
                    -- placed from the profile, so the matching Edit Mode layout
                    -- goes in alongside. This imports an Account layout and
                    -- makes it active, replacing the current Edit Mode setup.
                    local emStr = UltrawideEditModeString()
                    if emStr and EllesmereUI.ApplyPresetEditMode and not InCombatLockdown() then
                        pcall(EllesmereUI.ApplyPresetEditMode, emStr, "EUI Ultrawide")
                    end
                end,
                -- Written to the profile and settled by the reload rather than
                -- pushed onto live frames, which left elements behind before.
                needsReload = true,
            }
        end
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
    -- Fixed content box; every number below is derived from it.
    local POPUP_W   = 408
    local HEADER_H  = 26
    local ROW_H     = 25
    local BTN_W     = 172
    local COL       = 92
    local rows      = floor((#tweaks + 1) / 2)
    local hasNote   = false
    for _, t in ipairs(tweaks) do if t.note then hasNote = true end end
    local NOTE_H    = hasNote and 16 or 0
    local DESC_TOP  = HEADER_H + 33
    local GRID_TOP  = DESC_TOP + 33
    local POPUP_H   = GRID_TOP + rows * ROW_H + NOTE_H + 62

    -- Theme accent rather than the hardcoded green: this follows Class Colored
    -- and the faction themes like the rest of the suite.
    local ar, ag, ab = EllesmereUI.GetAccentColor()
    -- Accent lifted halfway to white: legible as label text while still
    -- unmistakably the accent. A pure white label was what made a selected
    -- toggle read as a white button no matter how green the fill behind it was.
    local lr, lg, lb = (ar + 1) / 2, (ag + 1) / 2, (ab + 1) / 2

    local dimmer = CreateFrame("Frame", "EUIDisplaySetupDimmer", UIParent)
    dimmer:SetFrameStrata("FULLSCREEN_DIALOG")
    dimmer:SetAllPoints(UIParent)
    dimmer:EnableMouse(true)
    dimmer:EnableMouseWheel(true)
    dimmer:SetScript("OnMouseWheel", function() end)
    dimmer:SetScale(ppScale)
    local dimTex = dimmer:CreateTexture(nil, "BACKGROUND")
    dimTex:SetAllPoints()
    dimTex:SetColorTexture(0, 0, 0, 0.45)

    local popup = CreateFrame("Frame", "EUIDisplaySetupPopup", dimmer)
    popup:SetScale(ppScale)
    popup:SetFrameStrata("FULLSCREEN_DIALOG")
    popup:SetFrameLevel(dimmer:GetFrameLevel() + 10)
    PP.Size(popup, POPUP_W, POPUP_H)
    popup:SetPoint("CENTER", UIParent, "CENTER", 0, 0)
    popup:EnableMouse(true)
    popup:SetMovable(true)
    popup:SetClampedToScreen(true)

    local bg = popup:CreateTexture(nil, "BACKGROUND")
    bg:SetAllPoints()
    bg:SetColorTexture(0.05, 0.06, 0.07, 0.97)

    -- 1 physical-pixel border in the accent colour.
    local onePhys = 1 / (popup:GetEffectiveScale() or 1)
    local function MakeEdge(alpha)
        local t = popup:CreateTexture(nil, "BORDER")
        t:SetColorTexture(ar, ag, ab, alpha)
        if t.SetSnapToPixelGrid then t:SetSnapToPixelGrid(false); t:SetTexelSnappingBias(0) end
        return t
    end
    local spT = MakeEdge(0.55); spT:SetPoint("TOPLEFT", 0, 0); spT:SetPoint("TOPRIGHT", 0, 0); spT:SetHeight(onePhys)
    local spB = MakeEdge(0.28); spB:SetPoint("BOTTOMLEFT", 0, 0); spB:SetPoint("BOTTOMRIGHT", 0, 0); spB:SetHeight(onePhys)
    local spL = MakeEdge(0.28); spL:SetPoint("TOPLEFT", spT, "BOTTOMLEFT"); spL:SetPoint("BOTTOMLEFT", spB, "TOPLEFT"); spL:SetWidth(onePhys)
    local spR = MakeEdge(0.28); spR:SetPoint("TOPRIGHT", spT, "BOTTOMRIGHT"); spR:SetPoint("BOTTOMRIGHT", spB, "TOPRIGHT"); spR:SetWidth(onePhys)

    -- Header strip doubles as the drag handle, the same way the options window
    -- moves from its own title area.
    local header = CreateFrame("Frame", nil, popup)
    header:SetFrameLevel(popup:GetFrameLevel() + 1)
    PP.Size(header, POPUP_W, HEADER_H)
    PP.Point(header, "TOP", popup, "TOP", 0, 0)
    header:EnableMouse(true)
    header:RegisterForDrag("LeftButton")
    header:SetScript("OnDragStart", function() popup:StartMoving() end)
    header:SetScript("OnDragStop",  function() popup:StopMovingOrSizing() end)

    local headerBg = header:CreateTexture(nil, "BACKGROUND")
    headerBg:SetAllPoints()
    headerBg:SetColorTexture(0.08, 0.09, 0.11, 1)
    local headerRule = header:CreateTexture(nil, "ARTWORK")
    headerRule:SetColorTexture(ar, ag, ab, 0.30)
    headerRule:SetPoint("BOTTOMLEFT", 0, 0)
    headerRule:SetPoint("BOTTOMRIGHT", 0, 0)
    headerRule:SetHeight(onePhys)

    local logo = header:CreateTexture(nil, "ARTWORK")
    logo:SetTexture("Interface\\AddOns\\EllesmereUI\\media\\eg-logo.tga")
    logo:SetVertexColor(ar, ag, ab, 0.95)
    PP.Size(logo, 19, 19)
    PP.Point(logo, "LEFT", header, "LEFT", 11, 0)

    local brand = header:CreateFontString(nil, "OVERLAY")
    brand:SetFont(FONT, 12, "")
    brand:SetTextColor(1, 1, 1, 0.75)
    PP.Point(brand, "LEFT", logo, "RIGHT", 7, 0)
    brand:SetText(EllesmereUI.L("Display Setup"))

    local screenTag = header:CreateFontString(nil, "OVERLAY")
    screenTag:SetFont(FONT, 11, "")
    screenTag:SetTextColor(ar, ag, ab, 0.80)
    PP.Point(screenTag, "RIGHT", header, "RIGHT", -12, 0)
    screenTag:SetText(screenLabel .. "  " .. kindLabel)

    local title = popup:CreateFontString(nil, "OVERLAY")
    title:SetFont(FONT, 17, "")
    title:SetTextColor(1, 1, 1, 1)
    PP.Point(title, "TOP", popup, "TOP", 0, -(HEADER_H + 11))
    title:SetText(EllesmereUI.L("Tune EllesmereUI for this screen"))

    local desc = popup:CreateFontString(nil, "OVERLAY")
    desc:SetFont(FONT, 12, "")
    desc:SetTextColor(1, 1, 1, 0.45)
    desc:SetWidth(POPUP_W - 56)
    desc:SetJustifyH("CENTER")
    desc:SetWordWrap(true)
    PP.Point(desc, "TOP", popup, "TOP", 0, -DESC_TOP)
    desc:SetText(EllesmereUI.L("Pick what you want changed. Nothing is applied until you click Finish."))

    ---------------------------------------------------------------------------
    --  Toggle rows
    ---------------------------------------------------------------------------
    local function MakeToggle(tweak, index)
        local col = (index % 2 == 1) and -COL or COL
        local row = floor((index - 1) / 2)

        local b = CreateFrame("Button", nil, popup)
        b:SetFrameLevel(popup:GetFrameLevel() + 2)
        PP.Size(b, BTN_W, 20)
        PP.Point(b, "TOP", popup, "TOP", col, -(GRID_TOP + row * ROW_H))

        local fill = b:CreateTexture(nil, "BACKGROUND")
        fill:SetAllPoints()
        local brd = MakeBorder(b, 1, 1, 1, 0.10, PP)

        -- Accent bar on the leading edge: reads as on or off at a glance
        -- without depending on the label colour alone.
        local tick = b:CreateTexture(nil, "ARTWORK")
        PP.Size(tick, 3, 20)
        PP.Point(tick, "LEFT", b, "LEFT", 0, 0)

        local lbl = b:CreateFontString(nil, "OVERLAY")
        lbl:SetFont(FONT, 12, "")
        lbl:SetJustifyH("LEFT")
        PP.Point(lbl, "LEFT", b, "LEFT", 12, 0)
        lbl:SetText(tweak.label)

        local function Paint(hover)
            if tweak.on then
                -- Faint accent wash, accent-tinted label, accent border:
                -- nothing in the selected state is white.
                fill:SetColorTexture(ar, ag, ab, hover and 0.20 or 0.11)
                tick:SetColorTexture(ar, ag, ab, 1)
                lbl:SetTextColor(lr, lg, lb, 1)
                brd:SetColor(ar, ag, ab, hover and 0.95 or 0.70)
            else
                -- Hover glows in the accent even when off, so the whole
                -- panel stays in one colour family instead of flashing white.
                if hover then
                    fill:SetColorTexture(ar, ag, ab, 0.14)
                    tick:SetColorTexture(ar, ag, ab, 0.85)
                    lbl:SetTextColor(lr, lg, lb, 0.95)
                    brd:SetColor(ar, ag, ab, 0.70)
                else
                    fill:SetColorTexture(1, 1, 1, 0.02)
                    tick:SetColorTexture(1, 1, 1, 0.12)
                    lbl:SetTextColor(1, 1, 1, 0.50)
                    brd:SetColor(1, 1, 1, 0.10)
                end
            end
        end
        b:SetScript("OnClick", function() tweak.on = not tweak.on; Paint(true) end)
        b:SetScript("OnEnter", function() Paint(true) end)
        b:SetScript("OnLeave", function() Paint(false) end)
        tweak._paint = function() Paint(false) end
        Paint(false)
        return b
    end

    local toggleBtns = {}
    for i, tweak in ipairs(tweaks) do
        toggleBtns[i] = MakeToggle(tweak, i)
    end

    -- Caveats for tweaks that reach beyond EllesmereUI's own settings.
    if hasNote then
        local noteTxt = popup:CreateFontString(nil, "OVERLAY")
        noteTxt:SetFont(FONT, 11, "")
        noteTxt:SetTextColor(1, 0.82, 0.30, 0.75)
        noteTxt:SetWidth(POPUP_W - 40)
        noteTxt:SetJustifyH("CENTER")
        PP.Point(noteTxt, "TOP", popup, "TOP", 0, -(GRID_TOP + rows * ROW_H + 2))
        local parts = {}
        for _, t in ipairs(tweaks) do
            if t.note then parts[#parts + 1] = t.label .. ": " .. t.note end
        end
        noteTxt:SetText(table.concat(parts, "   |   "))
    end

    -- Font stepper, tucked against the right edge of its own toggle row.
    local fontTweak, fontIdx
    for i, t in ipairs(tweaks) do if t.key == "font" then fontTweak, fontIdx = t, i end end
    if fontTweak then
        local col = (fontIdx % 2 == 1) and -COL or COL
        local row = floor((fontIdx - 1) / 2)

        local wrap = CreateFrame("Frame", nil, popup)
        wrap:SetFrameLevel(popup:GetFrameLevel() + 3)
        -- Right-aligned inside its own toggle row, narrow enough that the
        -- minus clears the label rather than overlapping it.
        PP.Size(wrap, 58, 20)
        PP.Point(wrap, "TOP", popup, "TOP", col + BTN_W / 2 - 35,
            -(GRID_TOP + row * ROW_H))

        local valTxt = wrap:CreateFontString(nil, "OVERLAY")
        valTxt:SetFont(FONT, 12, "")
        valTxt:SetTextColor(ar, ag, ab, 1)
        PP.Point(valTxt, "CENTER", wrap, "CENTER", 0, 0)

        local minusBtn, plusBtn
        local function Refresh()
            valTxt:SetText(tostring(Round(fontSize)))
            minusBtn:SetAlpha(fontSize > FONT_MIN and 1 or 0.3)
            plusBtn:SetAlpha(fontSize < FONT_MAX and 1 or 0.3)
        end
        local function MakeArrow(text, point, delta)
            local b = CreateFrame("Button", nil, wrap)
            b:SetFrameLevel(wrap:GetFrameLevel() + 1)
            PP.Size(b, 16, 16)
            PP.Point(b, point, wrap, point, 0, 0)
            local t = b:CreateFontString(nil, "OVERLAY")
            t:SetFont(FONT, 13, "")
            t:SetTextColor(1, 1, 1, 0.7)
            PP.Point(t, "CENTER", b, "CENTER", 0, 0)
            t:SetText(text)
            b:SetScript("OnEnter", function() t:SetTextColor(ar, ag, ab, 1) end)
            b:SetScript("OnLeave", function() t:SetTextColor(1, 1, 1, 0.7) end)
            b:SetScript("OnClick", function()
                fontSize = max(FONT_MIN, min(FONT_MAX, fontSize + delta))
                Refresh()
            end)
            return b
        end
        minusBtn = MakeArrow("-", "LEFT", -1)
        plusBtn  = MakeArrow("+", "RIGHT", 1)
        Refresh()
    end

    ---------------------------------------------------------------------------
    --  Finish
    ---------------------------------------------------------------------------
    local function Finish()
        if not EllesmereUIDB then EllesmereUIDB = {} end

        local scaleChanged, mustReload = false, false
        for _, tweak in ipairs(tweaks) do
            if tweak.on then
                pcall(tweak.apply)
                if tweak.key == "scale" then scaleChanged = true end
                if tweak.needsReload then mustReload = true end
            end
        end

        EllesmereUIDB.displaySetupShown = true
        EllesmereUIDB.displaySetupPending = nil
        EllesmereUIDB.displaySetupForced = nil
        dimmer:Hide()
        ReleaseConflictCheck()

        -- Repositioning is only half-done until the reload, so it is not
        -- offered as a choice: a "Later" would leave elements split between
        -- their old and new spots for the rest of the session.
        if mustReload then
            ReloadUI()
            return
        end

        -- Scale alone settles live; the reload only fixes Blizzard's Edit Mode
        -- snapping, which is the same caveat the options-page slider raises.
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
    -- Filled primary, outlined secondary: the same read as the rest of the
    -- suite's paired dialog buttons.
    local function MakeActionButton(text, primary, w)
        local btn = CreateFrame("Button", nil, popup)
        btn:SetFrameLevel(popup:GetFrameLevel() + 2)
        PP.Size(btn, w or 96, 20)
        local fill = btn:CreateTexture(nil, "BACKGROUND")
        fill:SetAllPoints()
        local brd = MakeBorder(btn, ar, ag, ab, primary and 0.85 or 0.22, PP)
        local lbl = btn:CreateFontString(nil, "OVERLAY")
        lbl:SetFont(FONT, 12, "")
        PP.Point(lbl, "CENTER", btn, "CENTER", 0, 0)
        lbl:SetText(text)

        local function Paint(hover)
            if primary then
                fill:SetColorTexture(ar, ag, ab, hover and 0.22 or 0.12)
                lbl:SetTextColor(lr, lg, lb, 1)
                brd:SetColor(ar, ag, ab, hover and 0.95 or 0.75)
            else
                fill:SetColorTexture(ar, ag, ab, hover and 0.22 or 0.02)
                lbl:SetTextColor(1, 1, 1, hover and 1 or 0.55)
                brd:SetColor(ar, ag, ab, hover and 0.95 or 0.15)
            end
        end
        btn:SetScript("OnEnter", function() Paint(true) end)
        btn:SetScript("OnLeave", function() Paint(false) end)
        Paint(false)
        return btn
    end

    -- Enable All sits as a quiet text link above the buttons: it is a shortcut,
    -- not a third choice competing with Finish.
    local allBtn = CreateFrame("Button", nil, popup)
    PP.Size(allBtn, 90, 16)
    PP.Point(allBtn, "BOTTOM", popup, "BOTTOM", 0, 38)
    allBtn:SetFrameLevel(popup:GetFrameLevel() + 2)
    local allLbl = allBtn:CreateFontString(nil, "OVERLAY")
    allLbl:SetFont(FONT, 11, "")
    allLbl:SetTextColor(1, 1, 1, 0.40)
    PP.Point(allLbl, "CENTER", allBtn, "CENTER", 0, 0)
    allLbl:SetText(EllesmereUI.L("Enable All"))
    allBtn:SetScript("OnEnter", function() allLbl:SetTextColor(ar, ag, ab, 0.95) end)
    allBtn:SetScript("OnLeave", function() allLbl:SetTextColor(1, 1, 1, 0.40) end)
    allBtn:SetScript("OnClick", function()
        for _, t in ipairs(tweaks) do
            t.on = true
            if t._paint then t._paint() end
        end
    end)

    -- Paired and centred, primary on the right.
    local GAP = 10
    local skipBtn = MakeActionButton(EllesmereUI.L("Skip"), false, 96)
    PP.Point(skipBtn, "BOTTOMRIGHT", popup, "BOTTOM", -GAP / 2, 10)
    skipBtn:SetScript("OnClick", function()
        for _, t in ipairs(tweaks) do t.on = false end
        Finish()
    end)

    local finishBtn = MakeActionButton(EllesmereUI.L("Finish"), true, 96)
    PP.Point(finishBtn, "BOTTOMLEFT", popup, "BOTTOM", GAP / 2, 10)
    finishBtn:SetScript("OnClick", Finish)

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
        -- Only worth showing unprompted on an ultrawide, where the defaults
        -- genuinely land wrong. Everyone else gets the scale and font work
        -- applied silently by the startup seed and never sees a popup they
        -- would have skipped. /euidisplaysetup forces it regardless.
        local forced = EllesmereUIDB and EllesmereUIDB.displaySetupForced
        local pw, ph = GetPhysicalScreenSize()
        local wide = (type(pw) == "number" and type(ph) == "number" and ph > 0
            and (pw / ph) >= 2.0) or false
        if not forced and not wide then
            EllesmereUIDB.displaySetupShown = true
            EllesmereUIDB.displaySetupPending = nil
            ReleaseConflictCheck()
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
        EllesmereUIDB.displaySetupForced = true
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

-------------------------------------------------------------------------------
--  Repositioning diagnostics
--
--  Four attempts at this failed because each fix was a guess about why nothing
--  moved, verified only by "it still does not work". This reports what the code
--  actually sees so the next change is aimed at a measured cause: how many
--  elements the registry holds, how many are usable, why the rest are skipped,
--  and what would change for the ones that qualify.
--
--  Read-only. It never writes and never applies.
-------------------------------------------------------------------------------
SLASH_EUIUWDEBUG1 = "/euiuwdebug"
SlashCmdList["EUIUWDEBUG"] = function()
    local function say(fmt, ...)
        print("|cff00ff98EUI-UW:|r " .. string.format(fmt, ...))
    end

    local physW, physH = GetPhysicalScreenSize()
    physW = (type(physW) == "number" and physW > 0) and physW or 1920
    physH = (type(physH) == "number" and physH > 0) and physH or 1080
    local aspect = physW / physH
    say("screen %dx%d  aspect %.3f  ultrawide=%s", physW, physH, aspect,
        tostring(aspect >= 2.0))
    say("screen units %.0fx%.0f  halfExcess %.0f  centreFactor %.3f",
        GetScreenWidth() or 0, GetScreenHeight() or 0,
        HalfExcessWidth(), HorizontalPullFactor(aspect))

    local reg = EllesmereUI._unlockRegisteredElements
    if type(reg) ~= "table" then
        say("|cffff6600registry MISSING|r (EllesmereUI._unlockRegisteredElements is %s)",
            type(reg))
        return
    end

    local total, noSave, stored, synth, noFrame, hidden, noCentre = 0, 0, 0, 0, 0, 0, 0
    local samples = {}
    for key, elem in pairs(reg) do
        total = total + 1
        if type(elem) ~= "table" or not elem.savePosition then
            noSave = noSave + 1
        else
            local pos
            if elem.loadPosition then
                local ok, p = pcall(elem.loadPosition, key)
                if ok and type(p) == "table" and type(p.x) == "number"
                   and type(p.point) == "string" then
                    pos = p
                end
            end
            if pos then
                stored = stored + 1
                if #samples < 6 then
                    samples[#samples + 1] = string.format(
                        "%s stored %s x=%.0f", tostring(key), pos.point, pos.x)
                end
            else
                local f
                if elem.getFrame then
                    local ok, got = pcall(elem.getFrame, key)
                    if ok then f = got end
                end
                if not (f and f.GetCenter) then
                    noFrame = noFrame + 1
                elseif not f:IsShown() then
                    hidden = hidden + 1
                else
                    local ox = CentreOffset(f)
                    if not ox then
                        noCentre = noCentre + 1
                    else
                        synth = synth + 1
                        if #samples < 6 then
                            samples[#samples + 1] = string.format(
                                "%s live x=%.0f", tostring(key), ox)
                        end
                    end
                end
            end
        end
    end

    say("registry %d elements: %d stored, %d from live frame, usable=%d",
        total, stored, synth, stored + synth)
    say("skipped: %d no savePosition, %d no frame, %d hidden, %d no centre",
        noSave, noFrame, hidden, noCentre)
    for _, s in ipairs(samples) do say("  %s", s) end

    local bars = CollectBarPositions()
    say("action bar anchors: %d", #bars)
end
