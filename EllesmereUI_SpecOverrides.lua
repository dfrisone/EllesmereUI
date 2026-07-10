-------------------------------------------------------------------------------
--  EllesmereUI_SpecOverrides.lua
--
--  Spec Overrides ("Editing as"): per-spec-group values for individual
--  settings inside ONE profile, so users no longer need a full duplicate
--  profile per spec.
--
--  Model:
--  * SPEC GROUPS ("cards"): named icon'd sets of specs (a spec belongs to at
--    most one group). The spec button next to the module search bar opens the
--    cards popup: Yourself (default), saved groups, Add New Spec Group, and a
--    link to the management list.
--  * Selecting a card enters "Editing as <group>": the group's stored values
--    swap into the live profile (captured paths only) and the user edits the
--    suite with the REAL options widgets -- full fidelity by construction.
--  * AUTO-CAPTURE: while editing as a group, any setting the user changes is
--    captured automatically. A watcher diffs the addon profiles on a short
--    ticker; writes are attributed to the options slot under the mouse (or
--    the slot whose dropdown menu / cog popup / color picker is open).
--    Unattributed writes (bar drags, background bookkeeping) are absorbed
--    silently and never captured.
--  * Exiting (selecting Yourself, another card, logging out, switching
--    profiles/specs) harvests the live values of every captured path into
--    ALL member specs of the group, then restores the real spec's values.
--    Values apply per spec on spec change via the profile system's existing
--    handler (save-on-leave / apply-on-enter). Stored maps are the source of
--    truth; a /reload mid-edit self-heals via the login apply.
--  * GOLDEN BORDERS: slots with an active override show a 1px gold pixel
--    border on their real options rows, matched by module + element + page +
--    section + slot label.
--  * Management list ("Spec Overrides" tab under Profiles & Presets): per
--    group, each captured setting with Go To Setting / Remove buttons.
--
--  Storage (active profile root; rides export/import):
--    profile.specOverrides       = { { label, slotLabel, crumb, module, page,
--                                      element, section, group = groupId,
--                                      values = { default = { [fkey]=v },
--                                                 [specID] = { [fkey]=v } } } }
--    profile.specOverrideGroups  = { { id, name, icon = {kind, key}, specs } }
--    profile.specOverrideNextId  = counter
--  fkey = folder .. FS .. path; path segments joined with PS (control chars,
--  so keys containing "." can never corrupt a path). NIL_SENT marks "key not
--  present" (a setter that removes its key at the default value).
-------------------------------------------------------------------------------

local PS  = "\30"   -- path segment separator
local FS  = "\31"   -- folder/path separator inside an fkey
local NIL_SENT = "__SPECOV_NIL__"

-- Spec Overrides theme color: #c7a65a (antique gold). Used for the slot
-- borders and all accent work in the cards popup / creation popup.
local ACCENT_R, ACCENT_G, ACCENT_B = 199/255, 166/255, 90/255
local EDIT_R, EDIT_G, EDIT_B = 1, 0.72, 0.2
local GOLD_R, GOLD_G, GOLD_B = 199/255, 166/255, 90/255

local PROFILES_MODULE = "_EUIProfiles"
local LIST_PAGE = "Spec Overrides"

-- Modules with their own native per-spec systems are excluded wholesale.
local FOLDER_BLACKLIST = {
    EllesmereUICooldownManager = true,
}

-- folder -> global apply-function names (mirrors EllesmereUI.RefreshAllAddons).
-- A touched folder with no entry falls back to a full RefreshAllAddons.
local REFRESH_FNS = {
    EllesmereUIResourceBars      = { "_ERB_Apply" },
    EllesmereUIActionBars        = { "_EAB_Apply" },
    EllesmereUIUnitFrames        = { "_EUF_ReloadFrames", "_EUF_RefreshUnitNames" },
    EllesmereUIRaidFrames        = { "_ERF_RefreshAll" },
    EllesmereUINameplates        = { "_ENP_RefreshAllSettings" },
    EllesmereUIQuestTracker      = { "_EQT_RefreshAll" },
    EllesmereUIChat              = { "_ECHAT_RefreshAll" },
    EllesmereUIFriends           = { "_EFR_ApplyFriends" },
    EllesmereUIMythicTimer       = { "_EMT_Apply" },
    EllesmereUIDamageMeters      = { "_EDM_Apply" },
    EllesmereUIAuraBuffReminders = { "_EABR_RequestRefresh", "_EABR_ApplyUnlockPos" },
}

-- Class glyph sprite (toolbar button) + modern class sprite (group icons)
local GLYPH_SPRITE  = "Interface\\AddOns\\EllesmereUI\\media\\icons\\class-full\\glyph.tga"
local MODERN_SPRITE = "Interface\\AddOns\\EllesmereUI\\media\\icons\\class-full\\modern.tga"
-- Generic multi-spec group icon (standalone image, not a sprite)
local MULTISPEC_ICON = "Interface\\AddOns\\EllesmereUI\\media\\icons\\class-full\\multispec.png"
local CLASS_COORDS = {
    WARRIOR={0,0.125,0,0.125}, MAGE={0.125,0.25,0,0.125}, ROGUE={0.25,0.375,0,0.125},
    DRUID={0.375,0.5,0,0.125}, EVOKER={0.5,0.625,0,0.125}, HUNTER={0,0.125,0.125,0.25},
    SHAMAN={0.125,0.25,0.125,0.25}, PRIEST={0.25,0.375,0.125,0.25}, WARLOCK={0.375,0.5,0.125,0.25},
    PALADIN={0,0.125,0.25,0.375}, DEATHKNIGHT={0.125,0.25,0.25,0.375},
    MONK={0.25,0.375,0.25,0.375}, DEMONHUNTER={0.375,0.5,0.25,0.375},
}
local CLASS_ORDER = {
    "WARRIOR", "PALADIN", "HUNTER", "ROGUE", "PRIEST", "DEATHKNIGHT",
    "SHAMAN", "MAGE", "WARLOCK", "MONK", "DRUID", "DEMONHUNTER", "EVOKER",
}
-- Modern role icons (shipped with RaidFrames; loaded by path, no addon dep)
local ROLE_MEDIA = "Interface\\AddOns\\EllesmereUIRaidFrames\\Media\\"
local ROLE_ICONS = {
    TANK    = ROLE_MEDIA .. "tank-modern.png",
    HEALER  = ROLE_MEDIA .. "healer-modern.png",
    DAMAGER = ROLE_MEDIA .. "dps-modern.png",
}
local ROLE_ORDER = { "TANK", "HEALER", "DAMAGER" }

local L = function(s) return EllesmereUI.L and EllesmereUI.L(s) or s end

-- Forward declarations
local ExitGroupEdit, ShowEditBanner, HideEditBanner, SetEditStatus
local UpdateIndicator, RequestGoldWalk, RefreshCardsPopup, SweepUncaptured
local TeardownEditSession, EnterDefaultView, ExitDefaultView
local EnsurePanelHideHook, PanelShown, ApplyEditOverlay
local _editGroup = nil       -- group table ref while "editing as" is active
local _defaultView = false   -- panel open in Default Editing Mode: live holds
                             -- the stored DEFAULT values for captured paths

-------------------------------------------------------------------------------
--  Small utilities
-------------------------------------------------------------------------------
local function DeepCopy(src)
    local t = {}
    for k, v in pairs(src) do
        if type(v) == "table" then t[k] = DeepCopy(v) else t[k] = v end
    end
    return t
end

local function CurrentSpecID()
    local id = EllesmereUI._specID
    if not id or id == 0 then
        if EllesmereUI._RefreshSpecID then EllesmereUI._RefreshSpecID() end
        id = EllesmereUI._specID
    end
    return (id and id ~= 0) and id or nil
end

local function SpecName(specID)
    local _, name, _, _, _, _, className = GetSpecializationInfoByID(specID)
    if name and className then
        return name .. " - " .. className:sub(1, 1):upper() .. className:sub(2):lower()
    end
    return name or ("Spec " .. tostring(specID))
end

-------------------------------------------------------------------------------
--  Storage
-------------------------------------------------------------------------------
local function GetProfileRoot()
    return EllesmereUI.GetActiveProfileData and EllesmereUI.GetActiveProfileData()
end

local function GetStore(create)
    local prof = GetProfileRoot()
    if not prof then return nil end
    if not prof.specOverrides and create then prof.specOverrides = {} end
    return prof.specOverrides
end

local function GetGroups(create)
    local prof = GetProfileRoot()
    if not prof then return nil end
    if not prof.specOverrideGroups and create then prof.specOverrideGroups = {} end
    return prof.specOverrideGroups
end

local function NextGroupId()
    local prof = GetProfileRoot()
    if not prof then return 1 end
    local id = (prof.specOverrideNextId or 0) + 1
    prof.specOverrideNextId = id
    return id
end

local function GroupById(id)
    for _, g in ipairs(GetGroups() or {}) do
        if g.id == id then return g end
    end
    return nil
end

-- While editing group G, an entry OWNED by another group whose member specs
-- overlap G's is a CONFLICT: the other group's values own that setting for
-- the shared spec(s). Returns the first overlapping specID, or nil.
local function ConflictSpec(entry, group)
    group = group or _editGroup
    if not group or not entry.group or entry.group == group.id then return nil end
    local og = GroupById(entry.group)
    if not og then return nil end
    for _, sid in ipairs(group.specs or {}) do
        for _, osid in ipairs(og.specs or {}) do
            if sid == osid then return sid end
        end
    end
    return nil
end

-- fkey -> owning entry index (rebuilt whenever entries change)
local _fkeyIndex = nil
local function RebuildFKeyIndex()
    _fkeyIndex = {}
    for _, entry in ipairs(GetStore() or {}) do
        for fkey in pairs(entry.values and entry.values.default or {}) do
            _fkeyIndex[fkey] = entry
        end
    end
end
local function EntryOwning(fkey)
    if not _fkeyIndex then RebuildFKeyIndex() end
    return _fkeyIndex[fkey]
end

-------------------------------------------------------------------------------
--  Live profile access by fkey
-------------------------------------------------------------------------------
local function DBFor(folder)
    local reg = EllesmereUI.Lite and EllesmereUI.Lite._dbRegistry
    if not reg then return nil end
    for _, db in ipairs(reg) do
        if db.folder == folder then return db.profile end
    end
    return nil
end

local function SplitFKey(fkey)
    return fkey:match("^([^\31]+)\31(.*)$")
end

local function ReadLive(fkey)
    local folder, path = SplitFKey(fkey)
    local t = folder and DBFor(folder)
    if type(t) ~= "table" then return nil end
    local segs = { strsplit(PS, path) }
    for i = 1, #segs - 1 do
        t = t[segs[i]]
        if type(t) ~= "table" then return nil end
    end
    return t[segs[#segs]]
end

local function WriteLive(fkey, v)
    local folder, path = SplitFKey(fkey)
    local t = folder and DBFor(folder)
    if type(t) ~= "table" then return false end
    local segs = { strsplit(PS, path) }
    for i = 1, #segs - 1 do
        local nxt = t[segs[i]]
        if type(nxt) ~= "table" then
            if v == nil then return false end   -- nothing to remove
            nxt = {}
            t[segs[i]] = nxt
        end
        t = nxt
    end
    t[segs[#segs]] = v
    return true
end

-- Reads a value out of a profiles snapshot (pre-change originals).
local function SnapValue(snap, fkey)
    local folder, path = SplitFKey(fkey)
    local t = folder and snap[folder]
    if type(t) ~= "table" then return nil end
    local segs = { strsplit(PS, path) }
    for i = 1, #segs - 1 do
        t = t[segs[i]]
        if type(t) ~= "table" then return nil end
    end
    return t[segs[#segs]]
end

-------------------------------------------------------------------------------
--  Targeted addon refresh (combat-deferred)
-------------------------------------------------------------------------------
local _combatFolders = nil

local function RunRefreshers(folders)
    if InCombatLockdown() then
        _combatFolders = _combatFolders or {}
        for f in pairs(folders) do _combatFolders[f] = true end
        return
    end
    local fallback = false
    for f in pairs(folders) do
        local fns = REFRESH_FNS[f]
        if fns then
            for _, name in ipairs(fns) do
                local fn = _G[name]
                if fn then pcall(fn) end
            end
        else
            fallback = true
        end
    end
    if fallback and EllesmereUI.RefreshAllAddons then
        EllesmereUI.RefreshAllAddons()
    end
end

-------------------------------------------------------------------------------
--  Harvest / Apply  (save-on-leave, apply-on-enter)
-------------------------------------------------------------------------------
local _inTransition = false   -- suppresses HarvestCurrent between leave & apply
local _activeSpec = nil       -- spec whose values currently sit in the live db
                              -- (ignoring a temporary Editing-as swap)

-- Reads the live value of every captured path into a map.
local function HarvestMap()
    local store = GetStore()
    if not store or #store == 0 then return nil end
    local maps = {}
    for i, entry in ipairs(store) do
        local m = {}
        for fkey in pairs(entry.values.default) do
            local v = ReadLive(fkey)
            if v == nil then
                m[fkey] = NIL_SENT
            elseif type(v) == "table" then
                m[fkey] = entry.values.default[fkey]   -- structure changed; keep default
            else
                m[fkey] = v
            end
        end
        maps[i] = m
    end
    return maps
end

local function Harvest(specID)
    if not specID then return end
    local store = GetStore()
    local maps = HarvestMap()
    if not maps then return end
    for i, entry in ipairs(store) do
        entry.values[specID] = maps[i]
    end
end

-- Banks live values into EVERY member spec of a group. Entries owned by a
-- CONFLICTING group (shared specs) are skipped entirely -- those slots are
-- blocked in the UI and the other group's values must survive untouched.
local function HarvestGroup(group)
    if not group then return end
    local store = GetStore()
    local maps = HarvestMap()
    if not maps then return end
    for i, entry in ipairs(store) do
        if not ConflictSpec(entry, group) then
            for _, specID in ipairs(group.specs or {}) do
                entry.values[specID] = DeepCopy(maps[i])
            end
        end
    end
end

-- Raw writer: puts the given spec's stored values into the live profile
-- tables. Returns the set of folders whose values actually changed, or nil.
local function WriteSpecValues(specID)
    local store = GetStore()
    if not store or #store == 0 or not specID then return nil end
    local touched = nil
    for _, entry in ipairs(store) do
        local m = entry.values[specID] or entry.values.default
        for fkey, def in pairs(entry.values.default) do
            local v = m[fkey]
            if v == nil then v = def end
            if v == NIL_SENT then v = nil end
            local cur = ReadLive(fkey)
            if cur ~= v then
                if WriteLive(fkey, v) then
                    local folder = SplitFKey(fkey)
                    if folder then
                        touched = touched or {}
                        touched[folder] = true
                    end
                end
            end
        end
    end
    return touched
end

-- Group variant: seeds from the group's first member spec.
local function WriteGroupValues(group)
    local seed = group and group.specs and group.specs[1]
    if not seed then return nil end
    return WriteSpecValues(seed)
end

-- Default variant: writes the stored DEFAULT values (what specs outside any
-- group use). Powers the panel's Default Editing Mode view.
local function WriteDefaultValues()
    local store = GetStore()
    if not store or #store == 0 then return nil end
    local touched = nil
    for _, entry in ipairs(store) do
        for fkey, def in pairs(entry.values.default) do
            local v = def
            if v == NIL_SENT then v = nil end
            if ReadLive(fkey) ~= v then
                if WriteLive(fkey, v) then
                    local folder = SplitFKey(fkey)
                    if folder then
                        touched = touched or {}
                        touched[folder] = true
                    end
                end
            end
        end
    end
    return touched
end

-- Banks live values into the entries' DEFAULT maps (Default Editing Mode
-- edits are edits to the shared baseline).
local function HarvestDefaults()
    local store = GetStore()
    local maps = HarvestMap()
    if not maps then return end
    for i, entry in ipairs(store) do
        entry.values.default = maps[i]
    end
end

local function ApplyValuesFor(specID)
    _inTransition = false
    if specID then _activeSpec = specID end
    -- While Editing-as (or the panel's Default view) holds swapped values
    -- live, generic re-applies (e.g. a fallback RefreshAllAddons) must
    -- preserve the swap.
    if _editGroup then
        return WriteGroupValues(_editGroup)
    end
    if _defaultView then
        return WriteDefaultValues()
    end
    return WriteSpecValues(specID)
end

--- Values-only apply, called at the TOP of EllesmereUI.RefreshAllAddons so
--- every profile swap / import picks the current spec's overrides up through
--- the full refresh that follows. No refresh of its own.
function EllesmereUI.SpecOverrides_ApplyValues(specID)
    ApplyValuesFor(specID or _activeSpec or CurrentSpecID())
    -- Unlock layout overrides ride the same hook: stores must hold the
    -- current spec's effective layout before every module refresh that
    -- follows. Always keyed to the REAL spec -- editing-as swaps option
    -- values, never the on-screen layout.
    if EllesmereUI.SpecOverrides_ApplyUnlock then
        EllesmereUI.SpecOverrides_ApplyUnlock(specID or _activeSpec or CurrentSpecID())
    end
end

--- Full apply: values + targeted refresh of the touched addons.
--- deferLogin: first-login call -- waits two frames so child addon OnEnable
--- and deferred registrations complete first (mirrors the profile switcher).
function EllesmereUI.SpecOverrides_Apply(specID, deferLogin)
    if deferLogin then
        C_Timer.After(0, function()
            C_Timer.After(0, function() EllesmereUI.SpecOverrides_Apply(specID) end)
        end)
        return
    end
    local touched = ApplyValuesFor(specID)
    if touched then RunRefreshers(touched) end
    -- Unlock layout overrides: the same-profile spec change never runs
    -- RefreshAllAddons, so this is its only unlock apply; on the
    -- profile-switch path the earlier ApplyValues call already ran it and
    -- this repeat is a value-equal no-op.
    if EllesmereUI.SpecOverrides_ApplyUnlock then
        EllesmereUI.SpecOverrides_ApplyUnlock(specID)
    end
    if UpdateIndicator then UpdateIndicator() end   -- passive owner may change
    -- Spec changed with the cards popup open: rebuild so each group's
    -- unlock icon reflects the new spec's membership (the click handler
    -- re-checks membership regardless).
    if RefreshCardsPopup then RefreshCardsPopup() end
    -- Spec changed with the panel open: return it to the Default view.
    if PanelShown and PanelShown() and not _editGroup and not _defaultView
       and EnterDefaultView then
        EnterDefaultView()
    end
end

--- Spec transition entry point, called by the profile system's spec handler
--- BEFORE any spec-profile switch.
function EllesmereUI.SpecOverrides_OnSpecChanged(oldSpecID, newSpecID)
    if _editGroup then
        -- Bank unsaved Editing-as changes (including a sweep of uncaptured
        -- writes) to the group's members; the real transition takes over from
        -- here (live currently holds group values, so the outgoing spec must
        -- NOT be harvested from it).
        local g = _editGroup
        _editGroup = nil
        if SweepUncaptured then SweepUncaptured(g) end
        HarvestGroup(g)
        if TeardownEditSession then TeardownEditSession() end
    elseif _defaultView then
        -- Live holds the DEFAULT values; bank them there. The outgoing spec's
        -- own values were banked when the view was entered.
        _defaultView = false
        HarvestDefaults()
        if UpdateIndicator then UpdateIndicator() end
    elseif oldSpecID and oldSpecID ~= newSpecID then
        Harvest(oldSpecID)
    end
    _activeSpec = newSpecID
    _inTransition = true
end

--- Harvest the live values of the spec currently in the live db. Called on
--- logout, before manual profile switches/imports, and before profile
--- export, so normal options-page edits are never lost. An active Editing-as
--- session is banked to its group and ended, and canonical live data is
--- restored (the caller is about to snapshot or switch).
function EllesmereUI.SpecOverrides_HarvestCurrent()
    if _inTransition then return end
    if _editGroup then
        local g = _editGroup
        _editGroup = nil
        if SweepUncaptured then SweepUncaptured(g) end
        HarvestGroup(g)
        if TeardownEditSession then TeardownEditSession() end
        local touched = WriteSpecValues(_activeSpec or CurrentSpecID())
        if touched then RunRefreshers(touched) end
        return
    end
    if _defaultView then
        -- Bank default-view edits, then restore the real spec's values so the
        -- caller (export/switch/logout) sees canonical live data.
        _defaultView = false
        HarvestDefaults()
        if UpdateIndicator then UpdateIndicator() end
        local touched = WriteSpecValues(_activeSpec or CurrentSpecID())
        if touched then RunRefreshers(touched) end
        return
    end
    Harvest(_activeSpec or CurrentSpecID())
end

-------------------------------------------------------------------------------
--  Unlock Layout Overrides
--  Per-GROUP overrides for unlock-mode layout aspects: element position (pos),
--  anchor link (anchor), grow direction (grow), width match (wm), height
--  match (hm). Stored OUTSIDE the fkey entries system: anchors and matches
--  live in GLOBAL EllesmereUIDB tables the Lite registry cannot address, and
--  unlock values are banked one-per-group, not one-per-spec.
--
--  Shape (profile root):
--    profile.specUnlockOverrides = {
--        groups   = { [groupId] = { [elementKey] = {
--                        pos    = saved-position entry (incl. tgt* follow
--                                 baselines for CDM/AB grow bars) | NIL_SENT,
--                        anchor = { target, side, offsetX, offsetY } | NIL_SENT,
--                        grow   = direction string | NIL_SENT,
--                        wm     = targetKey | NIL_SENT,
--                        hm     = targetKey | NIL_SENT } } },
--        baseline = { [elementKey] = same aspect shapes },
--        applied  = { [elementKey] = groupId },
--    }
--  baseline shadows the SHARED value of every aspect any group overrides; it
--  is the restore source when swapping to a non-member spec and when an
--  override is removed. applied is PERSISTED: after a /reload the live
--  globals still hold the previous spec's override values, and the map lets
--  the next apply restore exactly the elements that were overlaid -- never
--  the whole baseline bucket, which would clobber legitimate live drift
--  (anchor-offset upkeep) on every RefreshAllAddons.
-------------------------------------------------------------------------------

EllesmereUI.SPECOV_NIL = NIL_SENT
EllesmereUI._SPECOV_GOLD = { GOLD_R, GOLD_G, GOLD_B }

local function GetUnlockStore(create)
    local prof = GetProfileRoot()
    if not prof then return nil end
    local s = prof.specUnlockOverrides
    if not s then
        if not create then return nil end
        s = {}
        prof.specUnlockOverrides = s
    end
    s.groups   = s.groups   or {}
    s.baseline = s.baseline or {}
    s.applied  = s.applied  or {}
    return s
end

--- Deterministic owner: the FIRST group in creation order that contains
--- specID and overrides elementKey. Dual ownership is legal after a later
--- group-membership edit; creation order resolves it the same way every
--- session, and the special-mode conflict locks keep the loser uneditable.
function EllesmereUI.SpecOverrides_UnlockOwner(elementKey, specID)
    if not specID then return nil end
    local s = GetUnlockStore()
    if not s then return nil end
    for _, g in ipairs(GetGroups() or {}) do
        local ge = s.groups[g.id]
        if ge and ge[elementKey] ~= nil then
            for _, sid in ipairs(g.specs or {}) do
                if sid == specID then return g end
            end
        end
    end
    return nil
end

--- Another group that overrides elementKey and shares at least one spec with
--- `group` (the special-mode conflict case). Returns otherGroup, sharedSpecID.
function EllesmereUI.SpecOverrides_UnlockConflictGroup(elementKey, group)
    if not group then return nil end
    local s = GetUnlockStore()
    if not s then return nil end
    for _, og in ipairs(GetGroups() or {}) do
        if og.id ~= group.id then
            local ge = s.groups[og.id]
            if ge and ge[elementKey] ~= nil then
                for _, sid in ipairs(group.specs or {}) do
                    for _, osid in ipairs(og.specs or {}) do
                        if sid == osid then return og, sid end
                    end
                end
            end
        end
    end
    return nil
end

--- True when elementKey's live stores currently hold override values.
function EllesmereUI.SpecOverrides_UnlockApplied(elementKey)
    local s = GetUnlockStore()
    local gid = s and s.applied[elementKey]
    if gid ~= nil then return true, gid end
    return false
end

function EllesmereUI.SpecOverrides_UnlockElementOverridden(elementKey)
    local s = GetUnlockStore()
    if not s then return false end
    for _, ge in pairs(s.groups) do
        if ge[elementKey] ~= nil then return true end
    end
    return false
end

function EllesmereUI.SpecOverrides_UnlockGroupOwns(elementKey, groupId)
    local s = GetUnlockStore()
    local ge = s and s.groups[groupId]
    return (ge and ge[elementKey] ~= nil) and true or false
end

function EllesmereUI.SpecOverrides_CurrentSpec()
    return CurrentSpecID()
end

-- ---- live store readers/writers (value-equal guarded) ----------------------

local function AnchorEq(a, b)
    if not a and not b then return true end
    if not a or not b then return false end
    return a.target == b.target and a.side == b.side
       and a.offsetX == b.offsetX and a.offsetY == b.offsetY
end

-- ov: entry table, NIL_SENT (remove the link), or nil (aspect not overridden).
local function WriteLiveAnchor(elementKey, ov)
    if ov == nil or not EllesmereUIDB then return false end
    local db = EllesmereUIDB.unlockAnchors
    if not db then
        if ov == NIL_SENT then return false end
        db = {}
        EllesmereUIDB.unlockAnchors = db
    end
    local cur = db[elementKey]
    if ov == NIL_SENT then
        if not cur then return false end
        db[elementKey] = nil
    else
        if AnchorEq(cur, ov) then return false end
        -- The fallback link belongs to the child/target pair, not the spec:
        -- carry it over when the override keeps the same target.
        local fb = cur and cur.target == ov.target and cur.fallback or nil
        db[elementKey] = { target = ov.target, side = ov.side,
                           offsetX = ov.offsetX, offsetY = ov.offsetY,
                           fallback = fb }
    end
    EllesmereUI._anchorLinksStamp = (EllesmereUI._anchorLinksStamp or 0) + 1
    return true
end

local function WriteLiveMatch(dbKey, elementKey, ov)
    if ov == nil or not EllesmereUIDB then return false end
    local db = EllesmereUIDB[dbKey]
    if not db then
        if ov == NIL_SENT then return false end
        db = {}
        EllesmereUIDB[dbKey] = db
    end
    local v = ov ~= NIL_SENT and ov or nil
    if db[elementKey] == v then return false end
    db[elementKey] = v
    return true
end

local function ReadLiveGrow(elementKey)
    if elementKey:sub(1, 4) == "CDM_" then
        local raw = elementKey:sub(5)
        local a = EllesmereUI.Lite and EllesmereUI.Lite.GetAddon("EllesmereUICooldownManager", true)
        local bars = a and a.db and a.db.profile and a.db.profile.cdmBars
        if bars and bars.bars then
            for _, bar in ipairs(bars.bars) do
                if bar.key == raw then return bar.growDirection end
            end
        end
        return nil
    end
    local a = EllesmereUI.Lite and EllesmereUI.Lite.GetAddon("EllesmereUIActionBars", true)
    local cfg = a and a.db and a.db.profile and a.db.profile.bars and a.db.profile.bars[elementKey]
    return cfg and cfg.growDirection or nil
end

local function WriteLiveGrow(elementKey, ov)
    if ov == nil then return false end
    local v = ov ~= NIL_SENT and ov or nil
    if elementKey:sub(1, 4) == "CDM_" then
        local raw = elementKey:sub(5)
        local a = EllesmereUI.Lite and EllesmereUI.Lite.GetAddon("EllesmereUICooldownManager", true)
        local bars = a and a.db and a.db.profile and a.db.profile.cdmBars
        if bars and bars.bars then
            -- Resolve by bar.key, never array index (indices are not stable).
            for _, bar in ipairs(bars.bars) do
                if bar.key == raw then
                    if bar.growDirection == v then return false end
                    bar.growDirection = v
                    return true
                end
            end
        end
        -- Bar missing on this spec/profile: skip silently, never prune.
        return false
    end
    local a = EllesmereUI.Lite and EllesmereUI.Lite.GetAddon("EllesmereUIActionBars", true)
    local cfg = a and a.db and a.db.profile and a.db.profile.bars and a.db.profile.bars[elementKey]
    if not cfg or cfg.growDirection == v then return false end
    cfg.growDirection = v
    return true
end

local function PosEq(a, b)
    if not a and not b then return true end
    if not a or not b then return false end
    return a.point == b.point and a.relPoint == b.relPoint
       and a.x == b.x and a.y == b.y
       and a.tgtx == b.tgtx and a.tgty == b.tgty
       and a.tgtL == b.tgtL and a.tgtR == b.tgtR
       and a.tgtT == b.tgtT and a.tgtB == b.tgtB
end

-- Position store per element class: CDM bars and action bars keep raw saved-
-- edge entries (incl. tgt* follow baselines) that must be written verbatim,
-- never routed through savePosition (it would re-convert coordinates).
-- Generic registered elements go through their own savePosition closure.
local function PosStoreFor(elementKey)
    if elementKey:sub(1, 4) == "CDM_" then
        local a = EllesmereUI.Lite and EllesmereUI.Lite.GetAddon("EllesmereUICooldownManager", true)
        local t = a and a.db and a.db.profile and a.db.profile.cdmBarPositions
        return t, elementKey:sub(5), "raw"
    end
    -- Action bars come BEFORE the registered-element branch: their store
    -- entries are raw saved edges (plus tgt* follow baselines) that must be
    -- copied verbatim; routing them through savePosition would re-convert
    -- coordinates against mid-swap geometry.
    local abk = EllesmereUI._abBarKeys
    if abk and abk[elementKey] then
        local a = EllesmereUI.Lite and EllesmereUI.Lite.GetAddon("EllesmereUIActionBars", true)
        local t = a and a.db and a.db.profile and a.db.profile.barPositions
        return t, elementKey, "raw"
    end
    local elems = EllesmereUI._unlockRegisteredElements
    if elems and elems[elementKey] then
        return elems[elementKey], elementKey, "elem"
    end
    local a = EllesmereUI.Lite and EllesmereUI.Lite.GetAddon("EllesmereUIActionBars", true)
    local t = a and a.db and a.db.profile and a.db.profile.barPositions
    return t, elementKey, "raw"
end

local function ReadLivePos(elementKey)
    local store, key, kind = PosStoreFor(elementKey)
    if not store then return nil end
    if kind == "raw" then
        local e = store[key]
        return e and DeepCopy(e) or nil
    end
    local p = store.loadPosition and store.loadPosition(key)
    if p then
        return { point = p.point, relPoint = p.relPoint or p.point, x = p.x, y = p.y }
    end
    return nil
end

-- Generic-element position writes are deferred on profile-switch applies:
-- their savePosition closures are only re-registered AFTER the apply hook
-- runs. Raw CDM/AB stores are reached through the stable Lite db objects, so
-- they are always safe to write immediately.
local _unlockDeferredElemPos = nil
local _unlockSettleWanted = false
local _unlockFlushScheduled = false
local ScheduleUnlockFlush

local function WriteLivePos(elementKey, ov, deferElems)
    if ov == nil then return false end
    local store, key, kind = PosStoreFor(elementKey)
    if not store then return false end
    if kind == "raw" then
        local cur = store[key]
        if ov == NIL_SENT then
            if cur == nil then return false end
            store[key] = nil
        else
            if PosEq(cur, ov) then return false end
            store[key] = DeepCopy(ov)
        end
        return true
    end
    -- generic registered element
    if deferElems then
        _unlockDeferredElemPos = _unlockDeferredElemPos or {}
        _unlockDeferredElemPos[elementKey] = ov
        return true
    end
    if ov == NIL_SENT then
        if EllesmereUI._UnlockClearSavedPosition then
            pcall(EllesmereUI._UnlockClearSavedPosition, elementKey)
            return true
        end
        return false
    end
    local cur = store.loadPosition and store.loadPosition(key)
    if cur and cur.point == ov.point and (cur.relPoint or cur.point) == (ov.relPoint or ov.point)
       and cur.x == ov.x and cur.y == ov.y then
        return false
    end
    if store.savePosition then
        pcall(store.savePosition, key, ov.point, ov.relPoint or ov.point, ov.x, ov.y)
        return true
    end
    return false
end

-- Writes every aspect present in `a` into the live stores. Returns true when
-- anything actually changed (value-equal writes are no-ops).
local function ApplyAspects(elementKey, a, deferElems)
    if not a then return false end
    local changed = false
    if WriteLiveAnchor(elementKey, a.anchor) then changed = true end
    if WriteLiveMatch("unlockWidthMatch", elementKey, a.wm) then changed = true end
    if WriteLiveMatch("unlockHeightMatch", elementKey, a.hm) then changed = true end
    if WriteLiveGrow(elementKey, a.grow) then changed = true end
    if WriteLivePos(elementKey, a.pos, deferElems) then changed = true end
    return changed
end

-- ---- apply engine -----------------------------------------------------------

--- Swaps the live unlock stores to the given spec's effective values:
--- restores the shared baseline for elements that LOSE their override
--- (restore-only-overlaid, driven by the persisted applied map), then
--- overlays the owning groups' values. Value-equal-guarded throughout, so
--- the no-change common path (every mid-play RefreshAllAddons) writes
--- nothing and schedules nothing.
function EllesmereUI.SpecOverrides_ApplyUnlock(specID)
    local s = GetUnlockStore()
    if not s then return end
    specID = specID or _activeSpec or CurrentSpecID()
    if not specID then return end
    -- Live-drift harvest: anchor-offset upkeep legitimately rewrites live
    -- offsets between saves. Mirror them into the applied override entries
    -- BEFORE any restore/overlay, while live still belongs to the outgoing
    -- state.
    EllesmereUI.SpecOverrides_UnlockSyncAnchorOffsets()
    local desired
    for _, g in ipairs(GetGroups() or {}) do
        local ge = s.groups[g.id]
        if ge and next(ge) then
            for _, sid in ipairs(g.specs or {}) do
                if sid == specID then
                    for elementKey in pairs(ge) do
                        desired = desired or {}
                        if desired[elementKey] == nil then desired[elementKey] = g.id end
                    end
                    break
                end
            end
        end
    end
    local changed = false
    for elementKey in pairs(s.applied) do
        if not (desired and desired[elementKey]) then
            if ApplyAspects(elementKey, s.baseline[elementKey], true) then changed = true end
            s.applied[elementKey] = nil
        end
    end
    if desired then
        for elementKey, gid in pairs(desired) do
            local entry = s.groups[gid][elementKey]
            if entry and ApplyAspects(elementKey, entry, true) then changed = true end
            s.applied[elementKey] = gid
        end
    end
    if changed then _unlockSettleWanted = true end
    if _unlockSettleWanted or _unlockDeferredElemPos then
        ScheduleUnlockFlush()
    end
end

--- Completes a pending unlock-override apply: performs deferred generic-
--- element position writes (safe now -- unlock re-registration has run), then
--- runs one settle so the screen reflects the swapped stores. Called from
--- OnSpecSwitchComplete (after CDM's spec rebuild) and from a two-frame
--- fallback timer for paths where that never fires.
function EllesmereUI.SpecOverrides_FlushUnlock()
    _unlockFlushScheduled = false
    local pend = _unlockDeferredElemPos
    _unlockDeferredElemPos = nil
    if pend then
        local elems = EllesmereUI._unlockRegisteredElements
        for elementKey, ov in pairs(pend) do
            if ov == NIL_SENT then
                if EllesmereUI._UnlockClearSavedPosition then
                    pcall(EllesmereUI._UnlockClearSavedPosition, elementKey)
                    _unlockSettleWanted = true
                end
            else
                local elem = elems and elems[elementKey]
                if elem and elem.savePosition then
                    pcall(elem.savePosition, elementKey, ov.point, ov.relPoint or ov.point, ov.x, ov.y)
                    _unlockSettleWanted = true
                end
            end
        end
    end
    if not _unlockSettleWanted then return end
    -- Never fight an open unlock session; its own save/close flows settle.
    if EllesmereUI._unlockModeActive then return end
    _unlockSettleWanted = false
    if EllesmereUI.ApplyAllWidthHeightMatches then pcall(EllesmereUI.ApplyAllWidthHeightMatches) end
    if EllesmereUI._applySavedPositions then pcall(EllesmereUI._applySavedPositions) end
    if EllesmereUI.ResyncAnchorOffsets then pcall(EllesmereUI.ResyncAnchorOffsets) end
    if EllesmereUI.ReapplyAllUnlockAnchorsForced then
        EllesmereUI._reapplyForceEdgePreserve = true
        pcall(EllesmereUI.ReapplyAllUnlockAnchorsForced)
        EllesmereUI._reapplyForceEdgePreserve = false
    end
end

ScheduleUnlockFlush = function()
    if _unlockFlushScheduled then return end
    _unlockFlushScheduled = true
    -- Two frames: a profile-switch RefreshAllAddons finishes its child
    -- applies and unlock re-registration first. The CDM spec-rebuild path
    -- additionally flushes from OnSpecSwitchComplete; whichever runs first
    -- wins and the other becomes a no-op.
    C_Timer.After(0, function()
        C_Timer.After(0, function()
            if _unlockFlushScheduled then EllesmereUI.SpecOverrides_FlushUnlock() end
        end)
    end)
end

-- ---- banking (Save & Exit routing target) -----------------------------------

--- Banks touched aspects into the owning group's entry. baselineVals carries
--- the session-snapshot (pre-edit) values: an aspect's shared-baseline slot
--- is written only the FIRST time that aspect is overridden for the element;
--- later edits never move it.
function EllesmereUI.SpecOverrides_UnlockBank(elementKey, groupId, aspects, baselineVals)
    local s = GetUnlockStore(true)
    if not s then return end
    s.groups[groupId] = s.groups[groupId] or {}
    local entry = s.groups[groupId][elementKey] or {}
    s.groups[groupId][elementKey] = entry
    local base = s.baseline[elementKey] or {}
    s.baseline[elementKey] = base
    for k, v in pairs(aspects) do
        if base[k] == nil and baselineVals and baselineVals[k] ~= nil then
            local bv = baselineVals[k]
            base[k] = type(bv) == "table" and DeepCopy(bv) or bv
        end
        entry[k] = type(v) == "table" and DeepCopy(v) or v
    end
    s.applied[elementKey] = groupId
end

--- Keeps the shared-baseline shadow current when a NON-member spec's normal
--- save writes an element that carries overrides elsewhere. Only aspects the
--- baseline already shadows are mirrored.
function EllesmereUI.SpecOverrides_UnlockMirrorBaseline(elementKey, aspects)
    local s = GetUnlockStore()
    local base = s and s.baseline[elementKey]
    if not base then return end
    for k, v in pairs(aspects) do
        if base[k] ~= nil then
            base[k] = type(v) == "table" and DeepCopy(v) or v
        end
    end
end

-- ---- removal core ------------------------------------------------------------

--- Removes one element's override from a group. When that override is live,
--- restores the shared baseline into the live stores and settles so the
--- element visibly snaps back. Shared by the mover cog item, the management
--- list, and group deletion.
local function RemoveUnlockOverride(elementKey, groupId, skipSettle)
    local s = GetUnlockStore()
    if not s then return false end
    local ge = s.groups[groupId]
    if not ge or ge[elementKey] == nil then return false end
    ge[elementKey] = nil
    if not next(ge) then s.groups[groupId] = nil end
    if s.applied[elementKey] == groupId then
        if ApplyAspects(elementKey, s.baseline[elementKey], false) then
            _unlockSettleWanted = true
        end
        s.applied[elementKey] = nil
    end
    local stillReferenced = false
    for _, g2 in pairs(s.groups) do
        if g2[elementKey] ~= nil then stillReferenced = true; break end
    end
    if not stillReferenced then s.baseline[elementKey] = nil end
    if not skipSettle and _unlockSettleWanted then
        if EllesmereUI._unlockModeActive and EllesmereUI._unlockAfterSpecOvRemove then
            -- Mid-session removal: unlock mode owns the screen; run its
            -- element-scoped reapply instead of the global settle.
            _unlockSettleWanted = false
            pcall(EllesmereUI._unlockAfterSpecOvRemove, elementKey)
        else
            EllesmereUI.SpecOverrides_FlushUnlock()
        end
    end
    return true
end
EllesmereUI.SpecOverrides_RemoveUnlockOverride = RemoveUnlockOverride

--- Deletes every unlock override a group owns (group deletion path).
function EllesmereUI.SpecOverrides_RemoveUnlockGroup(groupId)
    local s = GetUnlockStore()
    local ge = s and s.groups[groupId]
    if not ge then return end
    local keys = {}
    for elementKey in pairs(ge) do keys[#keys + 1] = elementKey end
    for _, elementKey in ipairs(keys) do
        RemoveUnlockOverride(elementKey, groupId, true)
    end
    if _unlockSettleWanted then EllesmereUI.SpecOverrides_FlushUnlock() end
end

-- ---- live-drift write-backs ---------------------------------------------------

--- Mirrors bless-the-pin's tgt* backfill into the owning override entry, so
--- the blessed follow baseline survives the next spec swap instead of being
--- discarded and re-blessed every time.
function EllesmereUI.SpecOverrides_UnlockWriteBackPos(elementKey, liveEntry)
    local s = GetUnlockStore()
    local gid = s and s.applied[elementKey]
    if not gid then return end
    local entry = s.groups[gid] and s.groups[gid][elementKey]
    local pos = entry and entry.pos
    if type(pos) ~= "table" or type(liveEntry) ~= "table" then return end
    pos.tgtx, pos.tgty = liveEntry.tgtx, liveEntry.tgty
    pos.tgtL, pos.tgtR = liveEntry.tgtL, liveEntry.tgtR
    pos.tgtT, pos.tgtB = liveEntry.tgtT, liveEntry.tgtB
end

--- Mirrors anchor-offset upkeep (ResyncAnchorOffsets) into applied override
--- entries so the stored offsets never go stale against legitimate drift.
function EllesmereUI.SpecOverrides_UnlockSyncAnchorOffsets()
    local s = GetUnlockStore()
    if not s or not next(s.applied) then return end
    local db = EllesmereUIDB and EllesmereUIDB.unlockAnchors
    if not db then return end
    for elementKey, gid in pairs(s.applied) do
        local entry = s.groups[gid] and s.groups[gid][elementKey]
        local ov = entry and entry.anchor
        local live = db[elementKey]
        if type(ov) == "table" and live
           and live.target == ov.target and live.side == ov.side then
            ov.offsetX, ov.offsetY = live.offsetX, live.offsetY
        end
    end
end

-- ---- special unlock mode entry -------------------------------------------------

--- Opens unlock mode as a per-group edit session ("Customize Unlock Mode" on
--- a group card). Only valid when the current spec is a member of the group:
--- unlock mode always displays the current spec's layout, so editing a group
--- you cannot see is blocked at the icon AND re-checked here.
function EllesmereUI.SpecOverrides_EnterUnlockForGroup(g)
    if type(g) == "number" then g = GroupById(g) end
    if not g then return end
    local cur = CurrentSpecID()
    local member = false
    for _, sid in ipairs(g.specs or {}) do
        if sid == cur then member = true; break end
    end
    if not member then return end
    if EllesmereUI._unlockModeActive then return end
    -- Editing-as and special unlock both claim edit-context semantics; they
    -- never coexist. Banking the panel session first also restores canonical
    -- live values before the unlock session snapshots them.
    if _editGroup then ExitGroupEdit() end
    local panel = EllesmereUI._mainFrame
    if panel and panel:IsShown() then panel:Hide() end
    EllesmereUI._specialUnlockGroup = g
    C_Timer.After(0, function()
        if EllesmereUI._openUnlockMode then EllesmereUI._openUnlockMode() end
        if not EllesmereUI._unlockModeActive then
            -- Entry refused (combat): never leave the flag armed for a later
            -- manual unlock session.
            EllesmereUI._specialUnlockGroup = nil
        end
    end)
end

-------------------------------------------------------------------------------
--  Element-context providers for selector pages ("which bar / frame is
--  currently selected"). Options pages with an element selector register a
--  provider so captured entries carry their element -- the paths already
--  scope the override; this makes labels and golden borders element-aware.
-------------------------------------------------------------------------------
local _captureContexts = {}

--- fn() -> display label of the module's currently selected element (or nil).
function EllesmereUI.RegisterCaptureContext(folder, fn)
    if type(folder) == "string" and type(fn) == "function" then
        _captureContexts[folder] = fn
    end
end

local function CurrentContext()
    local modFolder = EllesmereUI.GetActiveModule and EllesmereUI:GetActiveModule()
    local ctxFn = modFolder and _captureContexts[modFolder]
    if not ctxFn then return nil end
    local ok, ctx = pcall(ctxFn)
    if ok and type(ctx) == "string" and ctx ~= "" then return ctx end
    return nil
end

-------------------------------------------------------------------------------
--  Profile snapshots + diffs (the auto-capture watcher's engine)
-------------------------------------------------------------------------------
local function SnapshotProfiles()
    local snap = {}
    local reg = EllesmereUI.Lite and EllesmereUI.Lite._dbRegistry
    if not reg then return snap end
    for _, db in ipairs(reg) do
        if db.folder and type(db.profile) == "table" then
            snap[db.folder] = DeepCopy(db.profile)
        end
    end
    return snap
end

local function DiffTables(old, new, prefix, out, numFlag)
    for k, nv in pairs(new) do
        local ov = old[k]
        local isNum = numFlag or (type(k) == "number")
        local path = prefix and (prefix .. PS .. tostring(k)) or tostring(k)
        if type(nv) == "table" and type(ov) == "table" then
            DiffTables(ov, nv, path, out, isNum)
        elseif nv ~= ov then
            out[#out + 1] = { path = path, val = nv, num = isNum }
        end
    end
    for k in pairs(old) do
        if new[k] == nil then
            local isNum = numFlag or (type(k) == "number")
            local path = prefix and (prefix .. PS .. tostring(k)) or tostring(k)
            out[#out + 1] = { path = path, removed = true, num = isNum }
        end
    end
end

local function DiffProfiles(snap)
    local out = {}
    local reg = EllesmereUI.Lite and EllesmereUI.Lite._dbRegistry
    if not reg then return out end
    for _, db in ipairs(reg) do
        local old = db.folder and snap[db.folder]
        if old and type(db.profile) == "table" then
            local changes = {}
            DiffTables(old, db.profile, nil, changes)
            for _, c in ipairs(changes) do
                c.folder = db.folder
                c.fkey = db.folder .. FS .. c.path
                out[#out + 1] = c
            end
        end
    end
    return out
end

-------------------------------------------------------------------------------
--  Contexts excluded from Spec Overrides entirely: no glow overlay, no
--  auto-capture, no slot marks. true = the whole module; a table = specific
--  pages of that module.
-------------------------------------------------------------------------------
local EXCLUDED_CONTEXTS = {
    [PROFILES_MODULE] = true,                  -- Profiles & Presets (incl. list tab)
    ["_EUIPatchNotes"] = true,                 -- Patch Notes
    ["_EUIGlobal"] = { ["General"] = true },   -- Global Settings -> General only
    -- (Global Settings -> Fonts & Colors stays eligible)
}

local function IsExcludedContext()
    local module = EllesmereUI.GetActiveModule and EllesmereUI:GetActiveModule()
    local ex = module and EXCLUDED_CONTEXTS[module]
    if ex == true then return true end
    if type(ex) == "table" then
        local page = EllesmereUI.GetActivePage and EllesmereUI:GetActivePage()
        return (page and ex[page]) and true or false
    end
    return false
end

-------------------------------------------------------------------------------
--  Golden borders: slots with an active override get a 1px gold PP border.
--  Slots are matched to entries by READ-TRACING: a slot's getters read its
--  own paths (getters are side-effect-free by convention -- the refresh
--  system calls them constantly), so during a walk the addon profile tables
--  are swapped for read-tracking proxies, each visible slot's getters run
--  once, and the recorded paths are matched against entry fkeys. This needs
--  no label metadata (migrated entries mark correctly) and is inherently
--  element-aware on selector pages (Bar 1 selected -> getters read bar1
--  paths -> only Bar 1's entries match).
-------------------------------------------------------------------------------
local _traceSink = nil
local _traceReal = nil

local function MakeReadProxy(real, folder, prefix)
    local proxy = {}
    setmetatable(proxy, {
        __index = function(_, k)
            local v = real[k]
            local path = prefix and (prefix .. PS .. tostring(k)) or tostring(k)
            if type(v) == "table" then
                return MakeReadProxy(v, folder, path)
            end
            if _traceSink then
                _traceSink[folder .. FS .. path] = true
            end
            return v
        end,
        __newindex = function(_, k, v) real[k] = v end,
    })
    return proxy
end

local function BeginTrace()
    local reg = EllesmereUI.Lite and EllesmereUI.Lite._dbRegistry
    if not reg or _traceReal then return false end
    _traceReal = {}
    for _, db in ipairs(reg) do
        if db.folder and type(db.profile) == "table" then
            _traceReal[db] = db.profile
            db.profile = MakeReadProxy(db.profile, db.folder, nil)
        end
    end
    return true
end

local function EndTrace()
    if not _traceReal then return end
    for db, real in pairs(_traceReal) do
        db.profile = real
    end
    _traceReal = nil
end

-- Runs a slot's getters under the read proxies; returns the set of fkeys read.
local function TraceSlot(cfg)
    _traceSink = {}
    local accs = cfg.accessors or { cfg }
    for _, acc in ipairs(accs) do
        if acc.getValue then pcall(acc.getValue) end
    end
    local sink = _traceSink
    _traceSink = nil
    return sink
end

local function MakeBorderHost(region, r, g, b)
    local host = CreateFrame("Frame", nil, region)
    host:SetAllPoints()
    host:SetFrameLevel(region:GetFrameLevel() + 30)
    if EllesmereUI.PP and EllesmereUI.PP.CreateBorder then
        EllesmereUI.PP.CreateBorder(host, r, g, b, 0.9, 1, "OVERLAY", 7)
    end
    return host
end

-- mode: false (clear), "gold" (overridden), or "red" (owned by a conflicting
-- group while editing -- red border + a click-blocking tooltip overlay).
local function SetSlotMark(region, mode, conflictSpecID)
    if mode == "gold" and not region._specOvGold then
        region._specOvGold = MakeBorderHost(region, GOLD_R, GOLD_G, GOLD_B)
    end
    if mode == "red" and not region._specOvRed then
        local host = MakeBorderHost(region, 0.9, 0.2, 0.2)
        local blocker = CreateFrame("Button", nil, host)
        blocker:SetAllPoints()
        blocker:SetFrameLevel(region:GetFrameLevel() + 45)
        blocker:EnableMouse(true)
        local tint = blocker:CreateTexture(nil, "OVERLAY")
        tint:SetAllPoints()
        tint:SetColorTexture(0.9, 0.2, 0.2, 0.05)
        blocker:SetScript("OnEnter", function(self)
            if self._tipText and EllesmereUI.ShowWidgetTooltip then
                EllesmereUI.ShowWidgetTooltip(self, self._tipText)
            end
        end)
        blocker:SetScript("OnLeave", function()
            if EllesmereUI.HideWidgetTooltip then EllesmereUI.HideWidgetTooltip() end
        end)
        host._blocker = blocker
        region._specOvRed = host
    end
    if region._specOvGold then region._specOvGold:SetShown(mode == "gold") end
    if region._specOvRed then
        region._specOvRed:SetShown(mode == "red")
        if mode == "red" and region._specOvRed._blocker then
            region._specOvRed._blocker._tipText = string.format(
                L("This setting already has an override for %s"),
                conflictSpecID and SpecName(conflictSpecID) or "?")
        end
    end
end

-------------------------------------------------------------------------------
--  Edit locks: regions that must be non-interactive whenever ANY Editing-as
--  session is active (same red prevention frame as cross-group conflicts).
--  Used by hands-off systems with their own per-spec handling, e.g. Resource
--  Bars' Threshold & Hash Lines slots. Regions register per page build; dead
--  pages release their locks via the weak table.
-------------------------------------------------------------------------------
local _editLocks = setmetatable({}, { __mode = "k" })

local function UpdateEditLocks()
    local on = _editGroup ~= nil
    for _, host in pairs(_editLocks) do
        host:SetShown(on)
    end
end

function EllesmereUI.SpecOverrides_AttachEditLock(region, tip)
    if not region then return end
    local host = _editLocks[region]
    if not host then
        host = MakeBorderHost(region, 0.9, 0.2, 0.2)
        local blocker = CreateFrame("Button", nil, host)
        blocker:SetAllPoints()
        blocker:SetFrameLevel(region:GetFrameLevel() + 45)
        blocker:EnableMouse(true)
        local tint = blocker:CreateTexture(nil, "OVERLAY")
        tint:SetAllPoints()
        tint:SetColorTexture(0.9, 0.2, 0.2, 0.05)
        blocker:SetScript("OnEnter", function(self)
            if self._tipText and EllesmereUI.ShowWidgetTooltip then
                EllesmereUI.ShowWidgetTooltip(self, self._tipText)
            end
        end)
        blocker:SetScript("OnLeave", function()
            if EllesmereUI.HideWidgetTooltip then EllesmereUI.HideWidgetTooltip() end
        end)
        host._blocker = blocker
        _editLocks[region] = host
    end
    host._blocker._tipText = tip
    host:SetShown(_editGroup ~= nil)
end

local function GoldWalk(frame, forceOff)
    local cfg = frame._captureCfg
    if cfg and not cfg.noCapture and not forceOff then
        local entry
        for fkey in pairs(TraceSlot(cfg)) do
            entry = EntryOwning(fkey)
            if entry then break end
        end
        if entry then
            local conflict = ConflictSpec(entry)
            SetSlotMark(frame, conflict and "red" or "gold", conflict)
        else
            SetSlotMark(frame, false)
        end
    else
        if frame._specOvGold then frame._specOvGold:Hide() end
        if frame._specOvRed then frame._specOvRed:Hide() end
    end
    local kids = { frame:GetChildren() }
    for i = 1, #kids do GoldWalk(kids[i], forceOff) end
end

local _goldWalkQueued = false
RequestGoldWalk = function()
    if _goldWalkQueued then return end
    _goldWalkQueued = true
    C_Timer.After(0, function()
        _goldWalkQueued = false
        local root = _G.EllesmereUIFrame
        if not (root and root:IsShown()) then return end
        -- Excluded contexts never show slot marks (walk still clears stale ones)
        if IsExcludedContext() then
            GoldWalk(root, true)
            return
        end
        if BeginTrace() then
            GoldWalk(root)
            EndTrace()
        end
    end)
end

-------------------------------------------------------------------------------
--  Auto-capture watcher (runs while Editing-as is active)
-------------------------------------------------------------------------------
local _watchSnap = nil
local _enterSnap = nil       -- baseline from session start (exit-sweep safety net)
local _watchTicker = nil
local _lastRegion, _lastRegionTime = nil, 0
local _watchResync = false   -- absorb the next tick's diff (page rebuild seeds)
local _sessionIgnored = {}   -- fkeys written on excluded pages this session
                             -- (never captured, and skipped by the exit sweep)

local function PrettyKey(fkey)
    local _, path = SplitFKey(fkey)
    local last = (path and path:match("([^\30]+)$")) or tostring(fkey)
    last = last:gsub("(%l)(%u)", "%1 %2")
    return (last:gsub("^%l", string.upper))
end

-- Tracks which options slot the user is interacting with. Popup frames
-- (dropdown menus, cog popups, the color picker) keep the previous slot
-- attribution; anything outside the options UI clears it.
local function SampleAttribution()
    local foci = GetMouseFoci and GetMouseFoci()
    local f = foci and foci[1]
    if not f or f == WorldFrame then return end
    local inPanel, popup, region = false, false, nil
    local n = f
    while n do
        if n._captureCfg then region = n end
        if n._euiOptionsPopup or n == EllesmereUI._colorPickerPopup then popup = true end
        if n == _G.EllesmereUIFrame then inPanel = true end
        n = n:GetParent()
    end
    if region then
        _lastRegion, _lastRegionTime = region, GetTime()
    elseif popup then
        -- keep the previous attribution (edits flow through the popup)
        _lastRegionTime = GetTime()
    elseif not inPanel then
        _lastRegion = nil   -- interacting with the world / other UI
    end
end

local function EntryForSlot(module, element, page, section, slotLabel)
    for _, entry in ipairs(GetStore() or {}) do
        if entry.slotLabel == slotLabel and entry.module == module
           and (entry.element or "") == (element or "")
           and (entry.page or "") == (page or "")
           and (entry.section or "") == (section or "") then
            return entry
        end
    end
    return nil
end

local function AutoCapture(changes)
    -- Attribution required: without a known slot, absorb silently (background
    -- bookkeeping like drag positions must never become overrides).
    local region = _lastRegion
    if not (region and region._captureCfg and (GetTime() - _lastRegionTime) < 30) then
        return
    end
    -- Excluded contexts (e.g. Global Settings -> General) never factor into
    -- spec overrides: absorb, and shield these paths from the exit sweep.
    if IsExcludedContext() then
        for _, c in ipairs(changes) do
            _sessionIgnored[c.fkey] = true
        end
        return
    end
    local store = GetStore(true)
    if not store then return end

    -- Validate + collect
    local paths, skippedNum, skippedBlack = {}, false, false
    for _, c in ipairs(changes) do
        if c.num then
            skippedNum = true
        elseif FOLDER_BLACKLIST[c.folder] then
            skippedBlack = true
        else
            paths[#paths + 1] = c.fkey
        end
    end
    if #paths == 0 then
        if skippedBlack then
            SetEditStatus(L("Cooldown Manager has its own per-spec system and can't be overridden here."), 1, 0.55, 0.35)
        elseif skippedNum then
            SetEditStatus(L("That setting is stored by list position and can't be safely overridden."), 1, 0.55, 0.35)
        end
        return
    end
    if #paths > 12 then return end   -- burst; not a slot edit

    local cfg = region._captureCfg
    local slotLabel = tostring(cfg.text or "?")
    local module = EllesmereUI.GetActiveModule and EllesmereUI:GetActiveModule()
    local page = EllesmereUI.GetActivePage and EllesmereUI:GetActivePage()
    local element = CurrentContext()
    local row = region._isOptionRow and region or region:GetParent()
    local hdr = row and row._sectionHeader
    local section = hdr and hdr._sectionName or nil

    local entry = EntryForSlot(module, element, page, section, slotLabel)
    local isNew = false
    if not entry then
        isNew = true
        local crumbParts = {}
        local modTitle = module and EllesmereUI.GetModuleTitle and EllesmereUI:GetModuleTitle(module)
        if modTitle then crumbParts[#crumbParts + 1] = L(modTitle) end
        if element then crumbParts[#crumbParts + 1] = L(element) end
        if page then crumbParts[#crumbParts + 1] = L(page) end
        if section then crumbParts[#crumbParts + 1] = L(section) end
        entry = {
            label = slotLabel,
            slotLabel = slotLabel,
            crumb = table.concat(crumbParts, "  >  "),
            module = module, page = page,
            element = element, section = section,
            group = _editGroup and _editGroup.id or nil,
            values = { default = {} },
        }
        store[#store + 1] = entry
    end

    -- Record originals (pre-change snapshot values) as the shared default and
    -- as the real spec's value; the group's members get the live values when
    -- the session is banked.
    local realSpec = _activeSpec or CurrentSpecID()
    for _, fkey in ipairs(paths) do
        if entry.values.default[fkey] == nil then
            local orig = SnapValue(_watchSnap, fkey)
            if type(orig) == "table" then orig = nil end
            entry.values.default[fkey] = (orig == nil) and NIL_SENT or orig
            if realSpec then
                local rm = entry.values[realSpec]
                if not rm then rm = {}; entry.values[realSpec] = rm end
                rm[fkey] = entry.values.default[fkey]
            end
        end
    end

    RebuildFKeyIndex()
    RequestGoldWalk()
    if isNew then
        SetEditStatus(string.format(L("'%s' is now customized for %s."), slotLabel, _editGroup and _editGroup.name or "?"), 0.35, 1, 0.35)
    end
end

local function WatchTick()
    if not _editGroup then return end
    SampleAttribution()
    local root = _G.EllesmereUIFrame
    if not (root and root:IsShown()) then return end
    if not _watchSnap then
        _watchSnap = SnapshotProfiles()
        return
    end
    local diffs = DiffProfiles(_watchSnap)
    if #diffs == 0 then return end
    if not _watchResync then
        local newOnes = nil
        for _, c in ipairs(diffs) do
            if not EntryOwning(c.fkey) then
                newOnes = newOnes or {}
                newOnes[#newOnes + 1] = c
            end
        end
        if newOnes then AutoCapture(newOnes) end
    end
    _watchResync = false
    _watchSnap = SnapshotProfiles()
end

-- Page rebuilds lazily seed defaults into profiles; absorb those writes
-- instead of capturing them. (Fast-path refreshes don't rebuild rows and
-- keep capture armed.) Also the panel-lifecycle bootstrap: page activity
-- means the panel exists/opened, so install the show/hide hooks and enter
-- the Default view when idle.
local function OnPageRebuilt()
    _watchResync = true
    RequestGoldWalk()
    if ApplyEditOverlay then ApplyEditOverlay() end   -- chrome-page suppression
    if EnsurePanelHideHook then EnsurePanelHideHook() end
    if not _editGroup and not _defaultView then
        C_Timer.After(0, function()
            if not _editGroup and not _defaultView
               and _G.EllesmereUIFrame and _G.EllesmereUIFrame:IsShown()
               and EnterDefaultView then
                EnterDefaultView()
            end
        end)
    end
end

-------------------------------------------------------------------------------
--  Notified writes: the widget factory calls _NotifySettingWrite on EVERY
--  widget setValue. This is the primary capture path -- exact frame-based
--  slot attribution, processed next frame, and immune to the page-rebuild
--  seed absorption (a forced refresh triggered by the setter itself can
--  never swallow the user's own edit). The polling ticker remains only as a
--  fallback for writes outside the widget factory.
-------------------------------------------------------------------------------
local _pendingWrites, _pendingWriteQueued = nil, false

local function ProcessNotifiedWrites()
    _pendingWriteQueued = false
    local frames = _pendingWrites
    _pendingWrites = nil
    if not _editGroup or not _watchSnap then return end
    -- Exact attribution from the notified frames (first that resolves wins).
    for _, f in ipairs(frames or {}) do
        if type(f) == "table" then
            local n, region = f, nil
            while n do
                if n._captureCfg then region = n; break end
                n = n:GetParent()
            end
            if region then
                _lastRegion, _lastRegionTime = region, GetTime()
                break
            end
        end
    end
    local diffs = DiffProfiles(_watchSnap)
    if #diffs == 0 then return end
    local newOnes
    for _, c in ipairs(diffs) do
        if not EntryOwning(c.fkey) then
            newOnes = newOnes or {}
            newOnes[#newOnes + 1] = c
        end
    end
    if newOnes then AutoCapture(newOnes) end
    _watchSnap = SnapshotProfiles()
end

--- Called by the widget factory whenever any options widget writes a value.
function EllesmereUI._NotifySettingWrite(frame)
    if not _editGroup then return end
    _pendingWrites = _pendingWrites or {}
    _pendingWrites[#_pendingWrites + 1] = frame or false
    if not _pendingWriteQueued then
        _pendingWriteQueued = true
        C_Timer.After(0, ProcessNotifiedWrites)
    end
end

-------------------------------------------------------------------------------
--  Exit-sweep safety net: anything that changed during the session and never
--  got captured (bespoke widgets, frame drags) must not leak into the real
--  spec. Sweeping it into the group lets the exit restore undo it live.
-------------------------------------------------------------------------------
SweepUncaptured = function(group)
    if not _enterSnap or not group then return end
    local store = GetStore(true)
    if not store then return end
    local realSpec = _activeSpec or CurrentSpecID()
    local added = false
    for _, c in ipairs(DiffProfiles(_enterSnap)) do
        if not EntryOwning(c.fkey) and not c.num and not FOLDER_BLACKLIST[c.folder]
           and not _sessionIgnored[c.fkey] then
            local orig = SnapValue(_enterSnap, c.fkey)
            if type(orig) == "table" then orig = nil end
            local entry = {
                label = PrettyKey(c.fkey),
                crumb = (EllesmereUI.GetModuleTitle and EllesmereUI:GetModuleTitle(c.folder)) or c.folder,
                module = c.folder,
                group = group.id,
                values = { default = { [c.fkey] = (orig == nil) and NIL_SENT or orig } },
            }
            if realSpec then entry.values[realSpec] = DeepCopy(entry.values.default) end
            store[#store + 1] = entry
            added = true
        end
    end
    if added then
        RebuildFKeyIndex()
    end
end

-------------------------------------------------------------------------------
--  Editing-as core
-------------------------------------------------------------------------------
local editBanner, editBannerText, editBannerStatus
local panelHideHooked = false

EnsurePanelHideHook = function()
    if panelHideHooked or not _G.EllesmereUIFrame then return end
    panelHideHooked = true
    _G.EllesmereUIFrame:HookScript("OnHide", function()
        if ExitGroupEdit then ExitGroupEdit() end
        if ExitDefaultView then ExitDefaultView() end
        if EllesmereUI._specOvCardsPopup then EllesmereUI._specOvCardsPopup:Hide() end
    end)
    -- Re-entering the panel returns to the Default Editing Mode view.
    _G.EllesmereUIFrame:HookScript("OnShow", function()
        C_Timer.After(0, function()
            if _G.EllesmereUIFrame and _G.EllesmereUIFrame:IsShown()
               and EnterDefaultView then
                EnterDefaultView()
            end
        end)
    end)
end

local function EnsureEditBanner()
    if editBanner then return editBanner end
    local root = _G.EllesmereUIFrame or UIParent
    editBanner = CreateFrame("Frame", nil, root)
    editBanner:SetSize(680, 44)
    -- Sits ON TOP of the visible panel: banner bottom flush with the window's
    -- top edge (the click area is the actual window; the outer frame includes
    -- the background art's shadow padding).
    editBanner:SetPoint("BOTTOM", _G.EllesmereUIClickArea or root, "TOP", 0, 0)
    editBanner:SetClampedToScreen(true)
    editBanner:SetFrameStrata("DIALOG")
    local bg = editBanner:CreateTexture(nil, "BACKGROUND")
    bg:SetAllPoints()
    bg:SetColorTexture(0.05, 0.05, 0.06, 0.92)
    local brd = editBanner:CreateTexture(nil, "BORDER")
    brd:SetPoint("BOTTOMLEFT"); brd:SetPoint("BOTTOMRIGHT")
    brd:SetHeight(1)
    brd:SetColorTexture(EDIT_R, EDIT_G, EDIT_B, 0.7)
    editBannerText = editBanner:CreateFontString(nil, "OVERLAY")
    editBannerText:SetFont(EllesmereUI.EXPRESSWAY or "Fonts\\FRIZQT__.TTF", 13, "")
    editBannerText:SetPoint("TOPLEFT", editBanner, "TOPLEFT", 16, -8)
    editBannerText:SetTextColor(EDIT_R, EDIT_G, EDIT_B, 1)
    editBannerStatus = editBanner:CreateFontString(nil, "OVERLAY")
    editBannerStatus:SetFont(EllesmereUI.EXPRESSWAY or "Fonts\\FRIZQT__.TTF", 11, "")
    editBannerStatus:SetPoint("BOTTOMLEFT", editBanner, "BOTTOMLEFT", 16, 7)
    editBannerStatus:SetTextColor(1, 1, 1, 0.6)
    local done = CreateFrame("Button", nil, editBanner)
    done:SetSize(74, 24)
    done:SetPoint("RIGHT", editBanner, "RIGHT", -12, 0)
    EllesmereUI.SolidTex(done, "BACKGROUND", 0.10, 0.10, 0.11, 0.9)
    local dbrd = EllesmereUI.MakeBorder(done, 1, 1, 1, 0.22)
    local dlbl = EllesmereUI.MakeFont(done, 11, nil, 1, 1, 1, 0.9)
    dlbl:SetPoint("CENTER")
    dlbl:SetText(L("Done"))
    done:SetScript("OnEnter", function() if dbrd and dbrd.SetColor then dbrd:SetColor(EDIT_R, EDIT_G, EDIT_B, 0.8) end end)
    done:SetScript("OnLeave", function() if dbrd and dbrd.SetColor then dbrd:SetColor(1, 1, 1, 0.22) end end)
    done:SetScript("OnClick", function() ExitGroupEdit() end)
    return editBanner
end

SetEditStatus = function(text, r, g, b)
    if editBannerStatus then
        editBannerStatus:SetText(text or "")
        editBannerStatus:SetTextColor(r or 1, g or 1, b or 0.6)
    end
end

ShowEditBanner = function(group)
    EnsureEditBanner()
    editBannerText:SetText(string.format(L("Editing as %s"), group.name or "?"))
    SetEditStatus(L("Any setting you change now applies only to this group's specs."), 1, 1, 0.6)
    editBanner:Show()
end

HideEditBanner = function()
    if editBanner then editBanner:Hide() end
end

-- Background glow overlay: shown while Editing-as. Aligned 1:1 with the
-- options panel background layers (both fill EllesmereUIFrame edge to edge),
-- drawn one frame level above them and below all content frames.
local EDIT_GLOW_TEXTURE = "Interface\\AddOns\\EllesmereUI\\media\\backgrounds\\eui-glow-override.png"
local editOverlay
local editOverlayTexture = EDIT_GLOW_TEXTURE

function EllesmereUI.SpecOverrides_SetEditBackground(texturePath)
    editOverlayTexture = texturePath or EDIT_GLOW_TEXTURE
    if editOverlay and editOverlay._tex then
        editOverlay._tex:SetTexture(editOverlayTexture)
    end
end

-- The glow suppresses itself on excluded contexts (chrome pages + Global
-- Settings General) and returns on normal module pages.
local _overlayWanted = false

ApplyEditOverlay = function()
    if not editOverlay then return end
    editOverlay:SetShown(_overlayWanted and not IsExcludedContext())
end

local function SetEditOverlayShown(shown)
    _overlayWanted = shown and true or false
    if shown and not editOverlay then
        local root = _G.EllesmereUIFrame
        if not root then return end
        editOverlay = CreateFrame("Frame", nil, root)
        editOverlay:SetAllPoints(root)
        editOverlay:SetFrameLevel(root:GetFrameLevel() + 1)
        editOverlay:EnableMouse(false)
        local tex = editOverlay:CreateTexture(nil, "BACKGROUND")
        tex:SetAllPoints()
        tex:SetTexture(editOverlayTexture)
        editOverlay._tex = tex
    end
    ApplyEditOverlay()
end

TeardownEditSession = function()
    if _watchTicker then _watchTicker:Cancel(); _watchTicker = nil end
    _watchSnap = nil
    _enterSnap = nil
    _sessionIgnored = {}
    HideEditBanner()
    SetEditOverlayShown(false)
    UpdateIndicator()
    UpdateEditLocks()   -- release threshold/hands-off locks
    RequestGoldWalk()   -- clear conflict-red marks back to gold
end

-------------------------------------------------------------------------------
--  Default Editing Mode view: while the options panel is open WITHOUT an
--  Editing-as session, the stored DEFAULT values are swapped into the live
--  paths so the panel always shows and edits the shared baseline -- even when
--  the current spec belongs to an override group. Closing the panel (or
--  entering Editing-as) banks default edits and restores the spec's values.
-------------------------------------------------------------------------------
PanelShown = function()
    local root = _G.EllesmereUIFrame
    return root and root:IsShown() or false
end

EnterDefaultView = function()
    if _defaultView or _editGroup or _inTransition then return end
    local store = GetStore()
    if not store or #store == 0 then return end
    -- Bank the real spec's live edits first, then swap the defaults in.
    EllesmereUI.SpecOverrides_HarvestCurrent()
    _defaultView = true
    local touched = WriteDefaultValues()
    if touched then RunRefreshers(touched) end
    if EllesmereUI.RefreshPage then EllesmereUI:RefreshPage() end
    UpdateIndicator()
end

ExitDefaultView = function(restore)
    if not _defaultView then return end
    _defaultView = false
    HarvestDefaults()
    if restore ~= false then
        local touched = WriteSpecValues(_activeSpec or CurrentSpecID())
        if touched then RunRefreshers(touched) end
    end
    UpdateIndicator()
end

ExitGroupEdit = function()
    if not _editGroup then return end
    WatchTick()   -- catch trailing edits from the last sub-tick window
    local g = _editGroup
    _editGroup = nil
    SweepUncaptured(g)
    HarvestGroup(g)
    TeardownEditSession()
    local touched = WriteSpecValues(_activeSpec or CurrentSpecID())
    if touched then RunRefreshers(touched) end
    -- Re-read open option widgets so they display the restored values.
    if EllesmereUI.RefreshPage then EllesmereUI:RefreshPage() end
    RequestGoldWalk()
    -- Back to Default Editing Mode: the open panel returns to the baseline.
    if PanelShown() then EnterDefaultView() end
end

local function EnterGroupEdit(group)
    if _editGroup == group then return end
    if _editGroup then ExitGroupEdit() end
    if not group or not group.specs or #group.specs == 0 then return end
    -- Leave the Default view (banks default edits, restores spec values),
    -- then bank the real spec's live edits and swap the group in.
    ExitDefaultView()
    EllesmereUI.SpecOverrides_HarvestCurrent()
    _editGroup = group
    local touched = WriteGroupValues(group)
    if touched then RunRefreshers(touched) end
    -- Re-read open option widgets so they display the group's values
    -- (before the snapshot, so any lazy page seeding is absorbed).
    if EllesmereUI.RefreshPage then EllesmereUI:RefreshPage() end
    _watchSnap = SnapshotProfiles()
    _enterSnap = _watchSnap   -- session baseline for the exit sweep
    _sessionIgnored = {}
    _lastRegion = nil
    _watchTicker = C_Timer.NewTicker(0.4, WatchTick)
    ShowEditBanner(group)
    SetEditOverlayShown(true)
    UpdateIndicator()
    UpdateEditLocks()
    RequestGoldWalk()
    EnsurePanelHideHook()
end

-------------------------------------------------------------------------------
--  Group icon rendering
-------------------------------------------------------------------------------
local function ApplyGroupIcon(tex, icon)
    tex:SetTexCoord(0, 1, 0, 1)
    tex:SetDesaturated(false)
    tex:SetVertexColor(1, 1, 1, 1)
    if icon and icon.kind == "multi" then
        tex:SetTexture(MULTISPEC_ICON)
    elseif icon and icon.kind == "role" and ROLE_ICONS[icon.key] then
        tex:SetTexture(ROLE_ICONS[icon.key])
    elseif icon and icon.kind == "class" and CLASS_COORDS[icon.key] then
        tex:SetTexture(MODERN_SPRITE)
        local c = CLASS_COORDS[icon.key]
        tex:SetTexCoord(c[1], c[2], c[3], c[4])
    else
        -- Default (no group icon): the player's class glyph in its natural
        -- colors, matching the toolbar button.
        tex:SetTexture(GLYPH_SPRITE)
        local _, classFile = UnitClass("player")
        local c = classFile and CLASS_COORDS[classFile]
        if c then tex:SetTexCoord(c[1], c[2], c[3], c[4]) end
    end
end

-------------------------------------------------------------------------------
--  Toolbar button + active-group indicator
-------------------------------------------------------------------------------
local specBtn, indicatorBtn

UpdateIndicator = function()
    if not indicatorBtn then return end
    indicatorBtn._passiveOwner = nil
    if _editGroup then
        ApplyGroupIcon(indicatorBtn._tex, _editGroup.icon)
        indicatorBtn:SetAlpha(1)
        indicatorBtn:Show()
        return
    end
    -- Passive awareness: the current spec belongs to a group -> dimmed icon
    -- ("this spec receives overrides from ...").
    local cur = CurrentSpecID()
    local owner
    if cur then
        for _, g in ipairs(GetGroups() or {}) do
            for _, id in ipairs(g.specs or {}) do
                if id == cur then owner = g; break end
            end
            if owner then break end
        end
    end
    if owner then
        ApplyGroupIcon(indicatorBtn._tex, owner.icon)
        indicatorBtn:SetAlpha(0.45)
        indicatorBtn._passiveOwner = owner
        indicatorBtn:Show()
    else
        indicatorBtn:Hide()
    end
end

--- Decorates and wires the toolbar button created in the tab bar (main panel).
function EllesmereUI.SpecOverrides_SetupButton(btn)
    specBtn = btn
    local tex = btn:CreateTexture(nil, "OVERLAY")
    tex:SetAllPoints()
    tex:SetTexture(GLYPH_SPRITE)
    -- Natural-color glyph: 90% opacity idle, full on hover.
    local _, classFile = UnitClass("player")
    local c = classFile and CLASS_COORDS[classFile]
    if c then tex:SetTexCoord(c[1], c[2], c[3], c[4]) end
    btn._tex = tex
    btn:SetAlpha(0.9)
    btn:SetScript("OnEnter", function(self)
        self:SetAlpha(1)
        if EllesmereUI.ShowWidgetTooltip then
            EllesmereUI.ShowWidgetTooltip(self, L("Spec Overrides: edit the suite as a group of specs"))
        end
    end)
    btn:SetScript("OnLeave", function(self)
        self:SetAlpha(0.9)
        if EllesmereUI.HideWidgetTooltip then EllesmereUI.HideWidgetTooltip() end
    end)
    btn:SetScript("OnClick", function(self)
        EllesmereUI.SpecOverrides_ToggleCardsPopup(self)
    end)

    -- Active-group indicator, left of the button
    indicatorBtn = CreateFrame("Button", nil, btn:GetParent() or btn)
    indicatorBtn:SetSize(24, 24)
    indicatorBtn:SetPoint("RIGHT", btn, "LEFT", -8, -1)
    indicatorBtn:SetFrameLevel(btn:GetFrameLevel())
    local itex = indicatorBtn:CreateTexture(nil, "OVERLAY")
    itex:SetAllPoints()
    indicatorBtn._tex = itex
    indicatorBtn:Hide()
    indicatorBtn:SetScript("OnEnter", function(self)
        if not EllesmereUI.ShowWidgetTooltip then return end
        if _editGroup then
            EllesmereUI.ShowWidgetTooltip(self, string.format(L("Editing as %s"), _editGroup.name or "?"))
        elseif self._passiveOwner then
            EllesmereUI.ShowWidgetTooltip(self, string.format(
                L("Your current spec receives overrides from %s"), self._passiveOwner.name or "?"))
        end
    end)
    indicatorBtn:SetScript("OnLeave", function()
        if EllesmereUI.HideWidgetTooltip then EllesmereUI.HideWidgetTooltip() end
    end)
    indicatorBtn:SetScript("OnClick", function()
        EllesmereUI.SpecOverrides_ToggleCardsPopup(specBtn)
    end)
    UpdateIndicator()
end

-------------------------------------------------------------------------------
--  Group creation: spec picker -> name + icon popup
-------------------------------------------------------------------------------
local nameIconPopup

local function ShowNameIconPopup(specIDs)
    if not nameIconPopup then
        local p = CreateFrame("Frame", nil, UIParent)
        p:SetSize(380, 300)
        p:SetPoint("CENTER", UIParent, "CENTER", 0, 60)
        p:SetFrameStrata("FULLSCREEN_DIALOG")
        p:SetFrameLevel(220)
        p:EnableMouse(true)
        local bg = p:CreateTexture(nil, "BACKGROUND")
        bg:SetAllPoints()
        bg:SetColorTexture(0.06, 0.06, 0.07, 0.97)
        EllesmereUI.MakeBorder(p, 1, 1, 1, 0.15)

        local title = EllesmereUI.MakeFont(p, 14, nil, ACCENT_R, ACCENT_G, ACCENT_B, 1)
        title:SetPoint("TOP", p, "TOP", 0, -14)
        title:SetText(L("New Spec Group"))
        p._title = title

        local nameLbl = EllesmereUI.MakeFont(p, 12, nil, 1, 1, 1, 0.6)
        nameLbl:SetPoint("TOPLEFT", p, "TOPLEFT", 20, -44)
        nameLbl:SetText(L("Name"))

        local nameBox = CreateFrame("EditBox", nil, p)
        nameBox:SetSize(340, 26)
        nameBox:SetPoint("TOPLEFT", p, "TOPLEFT", 20, -62)
        nameBox:SetAutoFocus(false)
        nameBox:SetFont(EllesmereUI.EXPRESSWAY or "Fonts\\FRIZQT__.TTF", 13, "")
        nameBox:SetTextColor(1, 1, 1, 1)
        nameBox:SetTextInsets(8, 8, 0, 0)
        nameBox:SetMaxLetters(24)
        EllesmereUI.SolidTex(nameBox, "BACKGROUND", 0.10, 0.10, 0.11, 0.9)
        EllesmereUI.MakeBorder(nameBox, 1, 1, 1, 0.12)
        nameBox:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)
        nameBox:SetScript("OnEnterPressed", function(self) self:ClearFocus() end)
        p._nameBox = nameBox

        local iconLbl = EllesmereUI.MakeFont(p, 12, nil, 1, 1, 1, 0.6)
        iconLbl:SetPoint("TOPLEFT", p, "TOPLEFT", 20, -102)
        iconLbl:SetText(L("Icon"))

        -- Icon grid: multi-spec + 3 modern role icons + 13 modern class icons
        p._iconBtns = {}
        local defs = { { kind = "multi" } }
        for _, role in ipairs(ROLE_ORDER) do
            defs[#defs + 1] = { kind = "role", key = role }
        end
        for _, cls in ipairs(CLASS_ORDER) do
            defs[#defs + 1] = { kind = "class", key = cls }
        end
        local PER_ROW, SZ, GAP = 8, 34, 8
        for i, def in ipairs(defs) do
            local col = (i - 1) % PER_ROW
            local rowI = math.floor((i - 1) / PER_ROW)
            local b = CreateFrame("Button", nil, p)
            b:SetSize(SZ, SZ)
            b:SetPoint("TOPLEFT", p, "TOPLEFT", 20 + col * (SZ + GAP), -122 - rowI * (SZ + GAP))
            local t = b:CreateTexture(nil, "ARTWORK")
            t:SetAllPoints()
            ApplyGroupIcon(t, def)
            local brd = EllesmereUI.MakeBorder(b, 1, 1, 1, 0.10)
            b._def = def
            b._brd = brd
            b:SetScript("OnClick", function(self)
                p._selectedIcon = self._def
                for _, ob in ipairs(p._iconBtns) do
                    if ob._brd and ob._brd.SetColor then
                        ob._brd:SetColor(1, 1, 1, ob == self and 0 or 0.10)
                    end
                    if ob._brd and ob._brd.SetColor and ob == self then
                        ob._brd:SetColor(ACCENT_R, ACCENT_G, ACCENT_B, 0.9)
                    end
                    ob:SetAlpha(ob == self and 1 or 0.7)
                end
            end)
            b:SetAlpha(0.7)
            p._iconBtns[#p._iconBtns + 1] = b
        end

        local create = CreateFrame("Button", nil, p)
        create:SetSize(110, 28)
        create:SetPoint("BOTTOMRIGHT", p, "BOTTOMRIGHT", -16, 14)
        EllesmereUI.SolidTex(create, "BACKGROUND", 0.10, 0.10, 0.11, 0.9)
        local cbrd = EllesmereUI.MakeBorder(create, ACCENT_R, ACCENT_G, ACCENT_B, 0.5)
        local clbl = EllesmereUI.MakeFont(create, 12, nil, ACCENT_R, ACCENT_G, ACCENT_B, 1)
        clbl:SetPoint("CENTER")
        clbl:SetText(L("Create Group"))
        create:SetScript("OnEnter", function() if cbrd and cbrd.SetColor then cbrd:SetColor(ACCENT_R, ACCENT_G, ACCENT_B, 0.9) end end)
        create:SetScript("OnLeave", function() if cbrd and cbrd.SetColor then cbrd:SetColor(ACCENT_R, ACCENT_G, ACCENT_B, 0.5) end end)
        create:SetScript("OnClick", function()
            local specs = p._specs
            if not specs or #specs == 0 then p:Hide(); return end
            local groups = GetGroups(true)
            if not groups then p:Hide(); return end
            local id = NextGroupId()
            local name = p._nameBox:GetText()
            if not name or name == "" then name = L("Group") .. " " .. id end
            groups[#groups + 1] = {
                id = id, name = name,
                icon = p._selectedIcon or { kind = "role", key = "DAMAGER" },
                specs = specs,
            }
            p:Hide()
            if UpdateIndicator then UpdateIndicator() end   -- current spec may have joined
            if RefreshCardsPopup then RefreshCardsPopup() end
        end)

        local cancel = CreateFrame("Button", nil, p)
        cancel:SetSize(80, 28)
        cancel:SetPoint("RIGHT", create, "LEFT", -8, 0)
        EllesmereUI.SolidTex(cancel, "BACKGROUND", 0.10, 0.10, 0.11, 0.9)
        local xbrd = EllesmereUI.MakeBorder(cancel, 1, 1, 1, 0.22)
        local xlbl = EllesmereUI.MakeFont(cancel, 12, nil, 1, 1, 1, 0.7)
        xlbl:SetPoint("CENTER")
        xlbl:SetText(L("Cancel"))
        cancel:SetScript("OnEnter", function() if xbrd and xbrd.SetColor then xbrd:SetColor(1, 1, 1, 0.4) end end)
        cancel:SetScript("OnLeave", function() if xbrd and xbrd.SetColor then xbrd:SetColor(1, 1, 1, 0.22) end end)
        cancel:SetScript("OnClick", function() p:Hide() end)

        nameIconPopup = p
    end
    nameIconPopup._specs = specIDs
    nameIconPopup._nameBox:SetText("")
    nameIconPopup._selectedIcon = nil
    for _, ob in ipairs(nameIconPopup._iconBtns) do
        ob:SetAlpha(0.7)
        if ob._brd and ob._brd.SetColor then ob._brd:SetColor(1, 1, 1, 0.10) end
    end
    nameIconPopup:Show()
end

local function StartGroupCreation()
    if not EllesmereUI.ShowSpecAssignPopup then return end
    local dummyDB = { _specOv = { _specs = {} } }
    EllesmereUI:ShowSpecAssignPopup({
        db        = dummyDB,
        dbKey     = "_specOv",
        presetKey = "_specs",
        title     = L("New Spec Group"),
        subtitle  = L("Select the specs this group edits:"),
        buttonText = L("Next"),
        preCheckedSpecs = {},
        onConfirm = function(assignments)
            -- Specs may belong to multiple groups; settings a shared spec
            -- already has overridden in another group are conflict-locked
            -- (red) while editing this one.
            local specs = {}
            for specID, on in pairs(assignments or {}) do
                if on and type(specID) == "number" then
                    specs[#specs + 1] = specID
                end
            end
            table.sort(specs)
            if #specs == 0 then return end
            ShowNameIconPopup(specs)
        end,
    })
end

-------------------------------------------------------------------------------
--  Cards popup
-------------------------------------------------------------------------------
local cardsPopup

local function BuildCardRow(parent, y, opts)
    local row = CreateFrame("Button", nil, parent)
    row:SetSize(parent:GetWidth() - 20, 40)
    row:SetPoint("TOPLEFT", parent, "TOPLEFT", 10, y)
    local hl = row:CreateTexture(nil, "HIGHLIGHT")
    hl:SetAllPoints()
    hl:SetColorTexture(1, 1, 1, 0.05)
    local brd = EllesmereUI.MakeBorder(row, 1, 1, 1, opts.active and 0 or 0.08)
    if opts.active and brd and brd.SetColor then
        brd:SetColor(ACCENT_R, ACCENT_G, ACCENT_B, 0.8)
    end
    local icon = row:CreateTexture(nil, "ARTWORK")
    icon:SetSize(26, 26)
    icon:SetPoint("LEFT", row, "LEFT", 8, 0)
    if opts.iconApply then opts.iconApply(icon) end
    local name = EllesmereUI.MakeFont(row, 13, nil, 1, 1, 1, opts.dim and 0.55 or 0.9)
    name:SetPoint("LEFT", icon, "RIGHT", 10, 0)
    name:SetText(opts.name)
    if opts.tooltip then
        row:SetScript("OnEnter", function(self)
            if EllesmereUI.ShowWidgetTooltip then EllesmereUI.ShowWidgetTooltip(self, opts.tooltip) end
        end)
        row:SetScript("OnLeave", function()
            if EllesmereUI.HideWidgetTooltip then EllesmereUI.HideWidgetTooltip() end
        end)
    end
    row:SetScript("OnClick", opts.onClick)
    local del
    if opts.deletable then
        del = CreateFrame("Button", nil, row)
        del:SetSize(20, 20)
        del:SetPoint("RIGHT", row, "RIGHT", -6, 1)
        del:SetFrameLevel(row:GetFrameLevel() + 2)
        local xl = EllesmereUI.MakeFont(del, 14, nil, 1, 1, 1, 0.75)
        xl:SetPoint("CENTER")
        xl:SetText("x")
        del:SetScript("OnEnter", function() xl:SetTextColor(1, 1, 1, 1) end)
        del:SetScript("OnLeave", function() xl:SetTextColor(1, 1, 1, 0.75) end)
        del:SetScript("OnClick", opts.onDelete)
    end
    local ed
    if opts.onEdit then
        ed = CreateFrame("Button", nil, row)
        ed:SetSize(16, 16)
        if del then
            -- del sits 1px high; -2 relative lands the pencil 1px low on the row.
            ed:SetPoint("RIGHT", del, "LEFT", -4, -2)
        else
            ed:SetPoint("RIGHT", row, "RIGHT", -8, -1)
        end
        ed:SetFrameLevel(row:GetFrameLevel() + 2)
        local ico = ed:CreateTexture(nil, "OVERLAY")
        ico:SetAllPoints()
        if ico.SetSnapToPixelGrid then ico:SetSnapToPixelGrid(false); ico:SetTexelSnappingBias(0) end
        ico:SetTexture("Interface\\AddOns\\EllesmereUI\\media\\icons\\eui-edit.png")
        ed:SetAlpha(0.75)
        ed:SetScript("OnEnter", function(self)
            self:SetAlpha(1)
            if EllesmereUI.ShowWidgetTooltip then
                EllesmereUI.ShowWidgetTooltip(self, L("Edit this group's specs"))
            end
        end)
        ed:SetScript("OnLeave", function(self)
            self:SetAlpha(0.75)
            if EllesmereUI.HideWidgetTooltip then EllesmereUI.HideWidgetTooltip() end
        end)
        ed:SetScript("OnClick", opts.onEdit)
    end
    if opts.onUnlock then
        local ub = CreateFrame("Button", nil, row)
        -- Native art is 37x42; keep the aspect ratio at 16px height.
        ub:SetSize(16 * 37 / 42, 16)
        if ed then
            -- The pencil sits 1px low; +1 recenters the unlock icon on the row.
            ub:SetPoint("RIGHT", ed, "LEFT", -4, 1)
        elseif del then
            ub:SetPoint("RIGHT", del, "LEFT", -4, -1)
        else
            ub:SetPoint("RIGHT", row, "RIGHT", -8, 0)
        end
        ub:SetFrameLevel(row:GetFrameLevel() + 2)
        local ico = ub:CreateTexture(nil, "OVERLAY")
        ico:SetAllPoints()
        if ico.SetSnapToPixelGrid then ico:SetSnapToPixelGrid(false); ico:SetTexelSnappingBias(0) end
        ico:SetTexture("Interface\\AddOns\\EllesmereUI\\media\\icons\\eui-unlocked-small.png")
        local enabled = opts.unlockEnabled
        ub:SetAlpha(enabled and 0.75 or 0.3)
        ub:SetScript("OnEnter", function(self)
            if enabled then self:SetAlpha(1) end
            if EllesmereUI.ShowWidgetTooltip then
                EllesmereUI.ShowWidgetTooltip(self, enabled
                    and L("Customize Unlock Mode")
                    or L("Switch to a spec in this group to customize its Unlock Mode"))
            end
        end)
        ub:SetScript("OnLeave", function(self)
            self:SetAlpha(enabled and 0.75 or 0.3)
            if EllesmereUI.HideWidgetTooltip then EllesmereUI.HideWidgetTooltip() end
        end)
        ub:SetScript("OnClick", function()
            if enabled then opts.onUnlock() end
        end)
    end
    return row, 44
end

-- Applies a membership change to a group: specs ADDED receive the group's
-- current override values (copied from the seed member, falling back to the
-- defaults), specs REMOVED lose their stored values (they revert to the
-- baseline on their next apply). The live profile re-syncs immediately so a
-- current-spec join/leave takes effect without a spec swap.
local function SetGroupSpecs(g, newSpecs)
    if _editGroup == g then ExitGroupEdit() end
    local oldSet, newSet = {}, {}
    for _, id in ipairs(g.specs or {}) do oldSet[id] = true end
    for _, id in ipairs(newSpecs) do newSet[id] = true end
    local seed = g.specs and g.specs[1]
    for _, entry in ipairs(GetStore() or {}) do
        if entry.group == g.id then
            -- capture the group's canonical values BEFORE removals (the seed
            -- member itself may be leaving)
            local seedMap = seed and entry.values[seed]
            for id in pairs(oldSet) do
                if not newSet[id] then entry.values[id] = nil end
            end
            for _, id in ipairs(newSpecs) do
                if not oldSet[id] then
                    entry.values[id] = DeepCopy(seedMap or entry.values.default)
                end
            end
        end
    end
    g.specs = newSpecs
    if EllesmereUI.SpecOverrides_Apply then
        EllesmereUI.SpecOverrides_Apply(_activeSpec or CurrentSpecID())
    end
    UpdateIndicator()
    RequestGoldWalk()
    RefreshCardsPopup()
end

local function EditGroupSpecs(g)
    if not EllesmereUI.ShowSpecAssignPopup then return end
    if cardsPopup then cardsPopup:Hide() end
    local preChecked = {}
    for _, id in ipairs(g.specs or {}) do preChecked[id] = true end
    local dummyDB = { _specOv = { _specs = {} } }
    EllesmereUI:ShowSpecAssignPopup({
        db        = dummyDB,
        dbKey     = "_specOv",
        presetKey = "_specs",
        title     = string.format(L("Edit Group: %s"), g.name or "?"),
        subtitle  = L("Select the specs this group edits:"),
        buttonText = L("Save"),
        preCheckedSpecs = preChecked,
        onConfirm = function(assignments)
            local specs = {}
            for specID, on in pairs(assignments or {}) do
                if on and type(specID) == "number" then
                    specs[#specs + 1] = specID
                end
            end
            table.sort(specs)
            SetGroupSpecs(g, specs)
        end,
    })
end

RefreshCardsPopup = function()
    local p = cardsPopup
    if not p or not p:IsShown() then return end
    -- clear old rows
    for _, r in ipairs(p._rows or {}) do r:Hide(); r:SetParent(nil) end
    p._rows = {}

    local y = -40
    local function add(row, h)
        p._rows[#p._rows + 1] = row
        y = y - h
    end

    -- Default editing mode (exit editing-as)
    add(BuildCardRow(p, y, {
        name = L("Default Editing Mode"),
        active = not _editGroup,
        iconApply = function(tex) ApplyGroupIcon(tex, nil) end,
        tooltip = L("Edit normally: changes apply to your current spec"),
        onClick = function()
            ExitGroupEdit()
            RefreshCardsPopup()
        end,
    }))

    -- Saved groups
    local curSpec = CurrentSpecID()
    for _, g in ipairs(GetGroups() or {}) do
        local names = {}
        local isMember = false
        for _, id in ipairs(g.specs or {}) do
            names[#names + 1] = SpecName(id)
            if id == curSpec then isMember = true end
        end
        add(BuildCardRow(p, y, {
            name = g.name or "?",
            active = _editGroup == g,
            iconApply = function(tex) ApplyGroupIcon(tex, g.icon) end,
            tooltip = table.concat(names, "\n"),
            deletable = true,
            unlockEnabled = isMember,
            onUnlock = function()
                p:Hide()
                EllesmereUI.SpecOverrides_EnterUnlockForGroup(g)
            end,
            onEdit = function() EditGroupSpecs(g) end,
            onClick = function()
                if _editGroup == g then
                    ExitGroupEdit()
                else
                    EnterGroupEdit(g)
                end
                RefreshCardsPopup()
            end,
            onDelete = function()
                EllesmereUI:ShowConfirmPopup({
                    title = L("Delete Spec Group"),
                    message = string.format(L("Delete the group '%s'? Its captured overrides are removed with it; settings keep their current live values."), g.name or "?"),
                    confirmText = L("Delete"),
                    cancelText = L("Cancel"),
                    onConfirm = function()
                        if _editGroup == g then ExitGroupEdit() end
                        local groups = GetGroups()
                        if groups then
                            for i, gg in ipairs(groups) do
                                if gg == g then table.remove(groups, i); break end
                            end
                        end
                        -- The group's overrides go with it (settings keep
                        -- whatever is live right now -- with the panel open
                        -- that is the Default view's baseline).
                        local st = GetStore()
                        if st then
                            for i = #st, 1, -1 do
                                if st[i].group == g.id then table.remove(st, i) end
                            end
                        end
                        -- Unlock layout overrides go with the group too;
                        -- live elements revert to the shared baseline
                        -- immediately (settle included).
                        if EllesmereUI.SpecOverrides_RemoveUnlockGroup then
                            EllesmereUI.SpecOverrides_RemoveUnlockGroup(g.id)
                        end
                        RebuildFKeyIndex()
                        RequestGoldWalk()
                        UpdateIndicator()   -- current spec may have been a member
                        RefreshCardsPopup()
                        if EllesmereUI.GetActivePage and EllesmereUI:GetActivePage() == LIST_PAGE then
                            EllesmereUI:RefreshPage(true)
                        end
                    end,
                })
            end,
        }))
    end

    -- Add new group
    add(BuildCardRow(p, y, {
        name = L("+ Add New Spec Group"),
        dim = true,
        iconApply = function(tex)
            tex:SetTexture(GLYPH_SPRITE)
            tex:SetTexCoord(0, 0.125, 0, 0.125)
            tex:SetDesaturated(true)
            tex:SetVertexColor(1, 1, 1, 0.25)
        end,
        onClick = function()
            p:Hide()
            StartGroupCreation()
        end,
    }))

    -- Link to the management list
    local link = CreateFrame("Button", nil, p)
    link:SetSize(p:GetWidth() - 20, 22)
    link:SetPoint("TOPLEFT", p, "TOPLEFT", 10, y - 2)
    local ll = EllesmereUI.MakeFont(link, 12, nil, ACCENT_R, ACCENT_G, ACCENT_B, 0.9)
    ll:SetPoint("CENTER")
    ll:SetText(L("View All / Remove Overrides"))
    link:SetScript("OnEnter", function() ll:SetTextColor(ACCENT_R, ACCENT_G, ACCENT_B, 1) end)
    link:SetScript("OnLeave", function() ll:SetTextColor(ACCENT_R, ACCENT_G, ACCENT_B, 0.9) end)
    link:SetScript("OnClick", function()
        p:Hide()
        EllesmereUI:SelectModule(PROFILES_MODULE)
        if EllesmereUI.SelectPage then EllesmereUI:SelectPage(LIST_PAGE) end
    end)
    p._rows[#p._rows + 1] = link
    y = y - 26

    p:SetHeight(-y + 12)
end

function EllesmereUI.SpecOverrides_ToggleCardsPopup(anchorBtn)
    if cardsPopup and cardsPopup:IsShown() then
        cardsPopup:Hide()
        return
    end
    if not cardsPopup then
        local p = CreateFrame("Frame", nil, _G.EllesmereUIFrame or UIParent)
        p:Hide()   -- born hidden so the first Show() fires OnShow (click-off arming)
        p:SetSize(280, 100)
        p:SetFrameStrata("DIALOG")
        p:SetFrameLevel(210)
        p:EnableMouse(true)
        p:SetClampedToScreen(true)
        local bg = p:CreateTexture(nil, "BACKGROUND")
        bg:SetAllPoints()
        bg:SetColorTexture(0.06, 0.06, 0.07, 0.97)
        EllesmereUI.MakeBorder(p, 1, 1, 1, 0.15)
        local title = EllesmereUI.MakeFont(p, 13, nil, ACCENT_R, ACCENT_G, ACCENT_B, 1)
        title:SetPoint("TOP", p, "TOP", 0, -12)
        title:SetText(L("Spec Overrides"))

        -- Click-anywhere-to-close, same pattern as the dropdown widgets:
        -- a global mouse-down listener (non-blocking, world clicks pass
        -- through). Clicks on the spec button / indicator are excluded so
        -- their own OnClick handles the toggle instead of close-then-reopen.
        local clickOff = CreateFrame("Frame")
        clickOff:Hide()
        clickOff:SetScript("OnEvent", function()
            -- A modal dialog (delete confirm / spec picker) owns clicks while
            -- shown; interacting with it must not close the cards popup.
            local confirmDim = _G.EUIConfirmDimmer
            if confirmDim and confirmDim:IsShown() then return end
            local assignDim = _G.EUISpecAssignDimmer
            if assignDim and assignDim:IsShown() then return end
            if p:IsShown() and not p:IsMouseOver()
               and not (specBtn and specBtn:IsMouseOver())
               and not (indicatorBtn and indicatorBtn:IsShown() and indicatorBtn:IsMouseOver()) then
                p:Hide()
            end
        end)
        p:HookScript("OnShow", function()
            -- Defer registration by one frame so the mouse-down that opened
            -- the popup doesn't immediately close it.
            C_Timer.After(0, function()
                if p:IsShown() then
                    clickOff:RegisterEvent("GLOBAL_MOUSE_DOWN")
                    clickOff:Show()
                end
            end)
        end)
        p:HookScript("OnHide", function()
            clickOff:UnregisterEvent("GLOBAL_MOUSE_DOWN")
            clickOff:Hide()
        end)

        cardsPopup = p
        EllesmereUI._specOvCardsPopup = p
    end
    cardsPopup:ClearAllPoints()
    if anchorBtn then
        cardsPopup:SetPoint("TOPRIGHT", anchorBtn, "BOTTOMRIGHT", 4, -8)
    else
        cardsPopup:SetPoint("CENTER", UIParent, "CENTER", 0, 100)
    end
    cardsPopup:Show()
    RefreshCardsPopup()
    EnsurePanelHideHook()
end

-------------------------------------------------------------------------------
--  Management list page ("Spec Overrides" tab under Profiles & Presets).
--  Purely a list: per group, each captured setting with Go To / Remove.
-------------------------------------------------------------------------------
local function TitleCase(s)
    local out = s:gsub("(%a[%w']*)", function(w)
        return w:sub(1, 1):upper() .. w:sub(2):lower()
    end)
    return out
end

local function BuildListRow(parent, y, entry)
    local CONTENT_PAD = EllesmereUI.CONTENT_PAD or 40
    local row = CreateFrame("Frame", nil, parent)
    row:SetSize(parent:GetWidth() - CONTENT_PAD * 2, 36)
    row:SetPoint("TOPLEFT", parent, "TOPLEFT", CONTENT_PAD, y)

    local name = EllesmereUI.MakeFont(row, 13, nil, 1, 1, 1, 0.9)
    name:SetPoint("LEFT", row, "LEFT", 20, 0)
    name:SetText(L(entry.label or "?"))

    local crumb = EllesmereUI.MakeFont(row, 11, nil, 1, 1, 1, 0.3)
    crumb:SetPoint("LEFT", name, "RIGHT", 10, 0)
    crumb:SetText(entry.crumb and TitleCase(entry.crumb) or "")

    local function MakeBtn(text, xOff, w)
        local b = CreateFrame("Button", nil, row)
        b:SetSize(w or 110, 22)
        b:SetPoint("RIGHT", row, "RIGHT", xOff, 0)
        EllesmereUI.SolidTex(b, "BACKGROUND", 0.10, 0.10, 0.11, 0.9)
        local brd = EllesmereUI.MakeBorder(b, 1, 1, 1, 0.22)
        local lbl = EllesmereUI.MakeFont(b, 11, nil, 1, 1, 1, 0.8)
        lbl:SetPoint("CENTER")
        lbl:SetText(L(text))
        return b, brd
    end

    local rm, rmBrd = MakeBtn("Remove Override", -20, 116)
    rm:SetScript("OnEnter", function() if rmBrd and rmBrd.SetColor then rmBrd:SetColor(1, 0.35, 0.35, 0.8) end end)
    rm:SetScript("OnLeave", function() if rmBrd and rmBrd.SetColor then rmBrd:SetColor(1, 1, 1, 0.22) end end)
    rm:SetScript("OnClick", function()
        EllesmereUI:ShowConfirmPopup({
            title = L("Remove Spec Override"),
            message = string.format(L("Remove '%s' from Spec Overrides? The setting keeps its current live value."), entry.label or "?"),
            confirmText = L("Remove"),
            cancelText = L("Cancel"),
            onConfirm = function()
                local st = GetStore()
                if st then
                    for i, e in ipairs(st) do
                        if e == entry then table.remove(st, i); break end
                    end
                end
                RebuildFKeyIndex()
                RequestGoldWalk()
                EllesmereUI:RefreshPage(true)
            end,
        })
    end)

    local go, goBrd = MakeBtn("Go to Setting", -144, 104)
    go:SetScript("OnEnter", function() if goBrd and goBrd.SetColor then goBrd:SetColor(ACCENT_R, ACCENT_G, ACCENT_B, 0.8) end end)
    go:SetScript("OnLeave", function() if goBrd and goBrd.SetColor then goBrd:SetColor(1, 1, 1, 0.22) end end)
    go:SetScript("OnClick", function()
        local mod = entry.module
        if not mod then
            for fkey in pairs(entry.values and entry.values.default or {}) do
                mod = SplitFKey(fkey)
                break
            end
        end
        if mod and EllesmereUI.GetModuleTitle and EllesmereUI:GetModuleTitle(mod) then
            EllesmereUI:SelectModule(mod)
            if entry.page and EllesmereUI.SelectPage then
                EllesmereUI:SelectPage(entry.page)
            end
        end
    end)

    return row, 38
end

-- Prunes entries whose owning group no longer exists (orphans from group
-- deletions made before deletions removed their entries). Entries with no
-- group at all (legacy captures) are kept.
local function PruneOrphanEntries()
    local store = GetStore()
    if not store then return false end
    local removed = false
    for i = #store, 1, -1 do
        local e = store[i]
        if e.group ~= nil and not GroupById(e.group) then
            table.remove(store, i)
            removed = true
        end
    end
    if removed then
        RebuildFKeyIndex()
        RequestGoldWalk()
    end
    return removed
end

local UNLOCK_ASPECT_LABELS = {
    pos = "Position", anchor = "Anchor", grow = "Grow Direction",
    wm = "Width Match", hm = "Height Match",
}

-- List row for an unlock layout override (one element in one group).
local function BuildUnlockListRow(parent, y, g, elementKey, entry)
    local CONTENT_PAD = EllesmereUI.CONTENT_PAD or 40
    local row = CreateFrame("Frame", nil, parent)
    row:SetSize(parent:GetWidth() - CONTENT_PAD * 2, 36)
    row:SetPoint("TOPLEFT", parent, "TOPLEFT", CONTENT_PAD, y)

    local label = (EllesmereUI.GetBarLabel and EllesmereUI.GetBarLabel(elementKey)) or elementKey
    local name = EllesmereUI.MakeFont(row, 13, nil, 1, 1, 1, 0.9)
    name:SetPoint("LEFT", row, "LEFT", 20, 0)
    name:SetText(label)

    local parts = {}
    for k in pairs(entry) do
        parts[#parts + 1] = L(UNLOCK_ASPECT_LABELS[k] or k)
    end
    table.sort(parts)
    local crumb = EllesmereUI.MakeFont(row, 11, nil, 1, 1, 1, 0.3)
    crumb:SetPoint("LEFT", name, "RIGHT", 10, 0)
    crumb:SetText(L("Unlock Layout") .. ": " .. table.concat(parts, ", "))

    local b = CreateFrame("Button", nil, row)
    b:SetSize(116, 22)
    b:SetPoint("RIGHT", row, "RIGHT", -20, 0)
    EllesmereUI.SolidTex(b, "BACKGROUND", 0.10, 0.10, 0.11, 0.9)
    local brd = EllesmereUI.MakeBorder(b, 1, 1, 1, 0.22)
    local lbl = EllesmereUI.MakeFont(b, 11, nil, 1, 1, 1, 0.8)
    lbl:SetPoint("CENTER")
    lbl:SetText(L("Remove Override"))
    b:SetScript("OnEnter", function() if brd and brd.SetColor then brd:SetColor(1, 0.35, 0.35, 0.8) end end)
    b:SetScript("OnLeave", function() if brd and brd.SetColor then brd:SetColor(1, 1, 1, 0.22) end end)
    b:SetScript("OnClick", function()
        EllesmereUI:ShowConfirmPopup({
            title = L("Remove Spec Override"),
            message = string.format(
                L("Revert '%s' to the shared layout? The '%s' specs lose their custom layout for it."),
                label, g.name or "?"),
            confirmText = L("Remove"),
            cancelText = L("Cancel"),
            onConfirm = function()
                EllesmereUI.SpecOverrides_RemoveUnlockOverride(elementKey, g.id)
                EllesmereUI:RefreshPage(true)
            end,
        })
    end)

    return row, 38
end

--- Page builder for the "Spec Overrides" tab (called from the Profiles &
--- Presets module registration).
function EllesmereUI.SpecOverrides_BuildListPage(parent, startY)
    local W = EllesmereUI.Widgets
    local y = startY
    PruneOrphanEntries()
    local store = GetStore()
    local groups = GetGroups() or {}
    local us = GetUnlockStore()
    local hasUnlock = false
    if us then
        for _, ge in pairs(us.groups) do
            if next(ge) then hasUnlock = true; break end
        end
    end

    if (not store or #store == 0) and not hasUnlock then
        local _, h = W:SectionHeader(parent, "Spec Overrides", y);  y = y - h
        local CONTENT_PAD = EllesmereUI.CONTENT_PAD or 40
        local hint = CreateFrame("Frame", nil, parent)
        hint:SetSize(parent:GetWidth() - CONTENT_PAD * 2, 80)
        hint:SetPoint("TOPLEFT", parent, "TOPLEFT", CONTENT_PAD, y)
        local fs = EllesmereUI.MakeFont(hint, 13, nil, 1, 1, 1, 0.5)
        fs:SetPoint("TOPLEFT", hint, "TOPLEFT", 20, -10)
        fs:SetWidth(hint:GetWidth() - 40)
        fs:SetJustifyH("LEFT")
        fs:SetText(L("No spec overrides yet. Click the spec glyph next to the module search bar, select or create a spec group, and any setting you change while editing as that group is saved here."))
        y = y - 90
        return -y + 40
    end

    -- Bucket entries by group id (missing/deleted group -> Ungrouped)
    local byGroup, ungrouped = {}, {}
    for _, entry in ipairs(store or {}) do
        local g = entry.group and GroupById(entry.group)
        if g then
            byGroup[g.id] = byGroup[g.id] or {}
            table.insert(byGroup[g.id], entry)
        else
            ungrouped[#ungrouped + 1] = entry
        end
    end

    for _, g in ipairs(groups) do
        local list = byGroup[g.id]
        local ue = us and us.groups[g.id]
        local ukeys
        if ue and next(ue) then
            ukeys = {}
            for k in pairs(ue) do ukeys[#ukeys + 1] = k end
            table.sort(ukeys)
        end
        if (list and #list > 0) or ukeys then
            local _, hh = W:SectionHeader(parent, g.name or "?", y);  y = y - hh
            for _, entry in ipairs(list or {}) do
                local _, rh = BuildListRow(parent, y, entry)
                y = y - rh
            end
            for _, ek in ipairs(ukeys or {}) do
                local _, rh = BuildUnlockListRow(parent, y, g, ek, ue[ek])
                y = y - rh
            end
        end
    end
    if #ungrouped > 0 then
        local _, hh = W:SectionHeader(parent, "Ungrouped", y);  y = y - hh
        for _, entry in ipairs(ungrouped) do
            local _, rh = BuildListRow(parent, y, entry)
            y = y - rh
        end
    end

    return -y + 40
end

-------------------------------------------------------------------------------
--  Hooks + events
-------------------------------------------------------------------------------
-- Golden borders + watcher seed-absorption on page changes. RefreshPage only
-- rebuilds rows when forced; the fast path neither seeds nor re-rows.
if EllesmereUI.SelectModule then
    hooksecurefunc(EllesmereUI, "SelectModule", OnPageRebuilt)
end
if EllesmereUI.SelectPage then
    hooksecurefunc(EllesmereUI, "SelectPage", OnPageRebuilt)
end
if EllesmereUI.RefreshPage then
    hooksecurefunc(EllesmereUI, "RefreshPage", function(_, force)
        if force then
            _watchResync = true
        end
        RequestGoldWalk()
    end)
end

-- /specov: debug dump of the override state (groups, entries, stored vs live
-- values). Dev tool; inert unless invoked.
SLASH_EUISPECOV1 = "/specov"
SlashCmdList.EUISPECOV = function()
    local p = print
    p("|cff0cd29f[SpecOv]|r activeSpec=" .. tostring(_activeSpec)
        .. "  currentSpec=" .. tostring(CurrentSpecID())
        .. "  editingAs=" .. tostring(_editGroup and _editGroup.name or "none")
        .. "  defaultView=" .. tostring(_defaultView))
    for _, g in ipairs(GetGroups() or {}) do
        local ids = {}
        for _, id in ipairs(g.specs or {}) do ids[#ids + 1] = tostring(id) end
        p(string.format("  group '%s' (id %s): specs %s", g.name or "?", tostring(g.id), table.concat(ids, ", ")))
    end
    for i, e in ipairs(GetStore() or {}) do
        p(string.format("  entry %d: '%s'  [%s]  group=%s", i, e.label or "?", e.crumb or "", tostring(e.group)))
        for fkey, def in pairs(e.values and e.values.default or {}) do
            local _, path = SplitFKey(fkey)
            local parts = { "default=" .. tostring(def) }
            for k, m in pairs(e.values) do
                if k ~= "default" and type(m) == "table" and m[fkey] ~= nil then
                    parts[#parts + 1] = tostring(k) .. "=" .. tostring(m[fkey])
                end
            end
            p("    " .. (path and path:gsub(PS, ".") or fkey)
                .. "  live=" .. tostring(ReadLive(fkey))
                .. "  " .. table.concat(parts, "  "))
        end
    end
end

local evFrame = CreateFrame("Frame")
evFrame:RegisterEvent("PLAYER_LOGIN")
evFrame:RegisterEvent("PLAYER_LOGOUT")
evFrame:RegisterEvent("PLAYER_REGEN_ENABLED")
evFrame:SetScript("OnEvent", function(_, event)
    if event == "PLAYER_LOGIN" then
        -- One-time tidy: drop entries orphaned by pre-fix group deletions.
        PruneOrphanEntries()
    elseif event == "PLAYER_LOGOUT" then
        -- Keep the current spec's stored values in sync with live edits so a
        -- shared profile opened on another character applies fresh data.
        -- (Also banks + restores an active Editing-as session.)
        EllesmereUI.SpecOverrides_HarvestCurrent()
    elseif event == "PLAYER_REGEN_ENABLED" then
        if _combatFolders then
            local fl = _combatFolders
            _combatFolders = nil
            RunRefreshers(fl)
        end
    end
end)
