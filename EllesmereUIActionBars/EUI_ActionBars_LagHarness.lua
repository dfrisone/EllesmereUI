-------------------------------------------------------------------------------
--  EUI_ActionBars_LagHarness.lua
--
--  DEV-ONLY repaint-latency harness.  /eablag
--
--  Turns "the cooldown swipe feels late" into a number per button. It times the
--  gap between the ENGINE reporting a button as on cooldown and EUI actually
--  painting that button, then reports mean/max/histogram split by what kind of
--  cooldown it was.
--
--  Why it works on booleans and not timestamps: in combat the duration object
--  behind a cooldown is SECRET and only HasSecretValues is readable on it (see
--  PushButtonCooldown), so there is no start time to subtract. What IS readable
--  is the pair of flags the walk itself reads every pass, isActive/isOnGCD, so
--  the engine side is sampled as an EDGE and the paint side is stamped at the
--  paint call. Resolution is therefore one frame, which is far below the delays
--  worth hunting.
--
--  The three rows that matter:
--    cooldown-start   a real cooldown began and we painted it        (late = bug)
--    gcd-start        a GCD-only swipe began and we painted it       (late = bug)
--    UNRESOLVED       the engine says active and we NEVER painted    (the bug)
--
--  Loaded but inert until /eablag on. Sampling reads every tracked button every
--  frame, so leave it off for normal play.
-------------------------------------------------------------------------------
local addonName, ns = ...

local GetTime, HasAction, pairs, format = GetTime, HasAction, pairs, string.format
local C_ActionBar = C_ActionBar

-- Buckets in seconds; the first is one frame at 60fps.
local HIST = { 0.017, 0.034, 0.05, 0.1, 0.2, 0.5, 1.0 }
local HIST_LABEL = { "<17ms", "<34ms", "<50ms", "<100ms", "<200ms", "<500ms", "<1s", ">=1s" }
local STALE_AFTER = 3.0   -- an arm still unpainted this long is a missing edge

local H = {
    on = false,
    state = {},      -- [btn] = last sampled isActive
    wasGcd = {},     -- [btn] = was the last active cooldown GCD-only
    arm = {},        -- [btn] = { t, want, gcd, dormant, shown, slot }
    lastPaint = {},  -- [btn] = { t, set }  -- resolves the same-frame ordering race
    stats = {},
    unresolved = 0,
    abandoned = 0,
    samples = 0,
}
ns._eabLag = H

local function Bucket(name)
    local b = H.stats[name]
    if not b then
        b = { n = 0, sum = 0, max = 0, worstSlot = nil, hist = { 0, 0, 0, 0, 0, 0, 0, 0 } }
        H.stats[name] = b
    end
    return b
end

local function Record(name, dt, slot)
    local b = Bucket(name)
    b.n = b.n + 1
    b.sum = b.sum + dt
    if dt > b.max then b.max = dt; b.worstSlot = slot end
    for i = 1, #HIST do
        if dt < HIST[i] then b.hist[i] = b.hist[i] + 1; return end
    end
    b.hist[#HIST + 1] = b.hist[#HIST + 1] + 1
end

local function RowName(a, set)
    local n = set and (a.gcd and "gcd-start" or "cooldown-start") or "cooldown-clear"
    if a.dormant then n = n .. " [dormant bar]" end
    return n
end

-- Paint side. Called from the paint chokepoints in the main chunk; `set` is
-- true for a swipe push, false for a clear.
ns._eabLagPaint = function(btn, set)
    if not H.on then return end
    local now = GetTime()
    local lp = H.lastPaint[btn]
    if not lp then lp = {}; H.lastPaint[btn] = lp end
    lp.t, lp.set = now, set
    local a = H.arm[btn]
    if not a or a.want ~= set then return end
    H.arm[btn] = nil
    Record(RowName(a, set), now - a.t, a.slot)
end

-- Engine side.
local sampler = CreateFrame("Frame")
sampler:Hide()
sampler:SetScript("OnUpdate", function()
    local now = GetTime()
    H.samples = H.samples + 1
    local dormancy = ns._eabBarDormant
    local buttons = ns.barButtons
    if not buttons then return end
    for barKey, btns in pairs(buttons) do
        -- Hidden bars are sampled too, deliberately: skipping them freezes the
        -- remembered state, and the next compare then reports the whole hidden
        -- stretch as latency. They are TAGGED instead, so a bar that is dormant
        -- by design never pollutes the headline rows.
        local dormant = (dormancy and dormancy[barKey]) and true or false
        for i = 1, #btns do
            local btn = btns[i]
            local action = btn:GetAttribute("action")
            local active, gcd = false, false
            if action and HasAction(action) then
                local ci = C_ActionBar.GetActionCooldown(action)
                if ci and ci.isActive then
                    active = true
                    gcd = ci.isOnGCD and true or false
                end
            end
            local prev = H.state[btn]
            if prev == nil then
                -- First sight of this button only SEEDS. Arming here would book
                -- an edge for every button on the first frame, and ~140 bogus
                -- unresolved rows would swamp the one number being hunted.
                H.state[btn] = active
                H.wasGcd[btn] = gcd
            elseif active ~= prev then
                H.state[btn] = active
                -- An arm that never resolved must NOT be inherited by the next
                -- edge, or one stuck button reports the same huge wait forever.
                if H.arm[btn] then
                    H.arm[btn] = nil
                    H.abandoned = H.abandoned + 1
                end
                -- Falling edge of a GCD is not armed: the swipe widget unwinds
                -- to empty on its own, so a missing Clear there is invisible to
                -- the player and would only add noise. A REAL cooldown ending
                -- early (proc, reset) is visible, and was a past bug, so that
                -- one is still timed.
                local track = active or (H.wasGcd[btn] == false)
                if active then H.wasGcd[btn] = gcd end
                if track then
                    -- Our OnUpdate may run AFTER the paint in the same frame,
                    -- which would otherwise book a real repaint as a miss.
                    -- GetTime is frame-constant, so an equal stamp means
                    -- "already painted".
                    local lp = H.lastPaint[btn]
                    if lp and lp.set == active and lp.t == now then
                        Record(RowName({ gcd = gcd, dormant = dormant }, active), 0, action)
                    else
                        H.arm[btn] = { t = now, want = active, gcd = gcd,
                                       dormant = dormant, shown = btn:IsShown(),
                                       slot = action }
                    end
                end
            end
        end
    end
    for btn, a in pairs(H.arm) do
        if now - a.t > STALE_AFTER then
            H.arm[btn] = nil
            H.unresolved = H.unresolved + 1
            local b = Bucket("UNRESOLVED " .. RowName(a, a.want))
            b.n = b.n + 1
            b.worstSlot = a.slot
        end
    end
end)

-- Naming the slot is what makes a row actionable, but action type/id can be
-- secret in combat and formatting a secret throws, so the whole build is
-- protected and falls back to the bare slot number.
local function SlotLabel(slot)
    if not slot then return "?" end
    local ok, label = pcall(function()
        local aType, id = GetActionInfo(slot)
        if not aType then return "slot " .. slot end
        local name
        if aType == "spell" and id and C_Spell and C_Spell.GetSpellInfo then
            local info = C_Spell.GetSpellInfo(id)
            name = info and info.name
        end
        return format("slot %d (%s%s)", slot, aType, name and (" " .. name) or "")
    end)
    return (ok and label) or ("slot " .. tostring(slot))
end

local function Report()
    print("|cff0cd29fEUI action bar repaint latency|r  (" .. (H.on and "|cff00ff00sampling|r" or "|cffff5555off|r")
        .. ", " .. H.samples .. " frames sampled)")
    local any = false
    for name, b in pairs(H.stats) do
        any = true
        if b.sum > 0 or b.n > 0 then
            local mean = b.n > 0 and (b.sum / b.n * 1000) or 0
            print(format("  |cffffd100%-32s|r n=%-4d mean %6.1fms  max %6.1fms  %s",
                name, b.n, mean, b.max * 1000, b.worstSlot and SlotLabel(b.worstSlot) or ""))
            local parts = {}
            for i = 1, #HIST_LABEL do
                if b.hist[i] > 0 then parts[#parts + 1] = HIST_LABEL[i] .. "=" .. b.hist[i] end
            end
            if #parts > 0 then print("      " .. table.concat(parts, "  ")) end
        end
    end
    if not any then print("  (no samples yet)") end
    -- Printed unconditionally: these are the numbers being hunted, and ranking
    -- them away is how the one real finding got buried last time.
    print(format("  |cffff5555UNRESOLVED (engine active, never painted): %d|r", H.unresolved))
    print(format("  abandoned (state fell back before any paint): %d", H.abandoned))
    print("  NOTE: a max above ~2s on a GCD row is an artifact, not a finding.")
end

local function Reset()
    H.stats, H.arm, H.state, H.lastPaint, H.wasGcd = {}, {}, {}, {}, {}
    H.unresolved, H.abandoned, H.samples = 0, 0, 0
end

SLASH_EABLAG1 = "/eablag"
SlashCmdList["EABLAG"] = function(msg)
    msg = (msg or ""):lower():gsub("^%s+", ""):gsub("%s+$", "")
    if msg == "on" then
        Reset(); H.on = true; sampler:Show()
        print("|cff0cd29fEUI|r repaint-latency sampling |cff00ff00ON|r. Fight something, then /eablag.")
    elseif msg == "off" then
        H.on = false; sampler:Hide()
        print("|cff0cd29fEUI|r repaint-latency sampling |cffff5555OFF|r.")
        Report()
    elseif msg == "reset" then
        Reset(); print("|cff0cd29fEUI|r repaint-latency counters reset.")
    else
        Report()
    end
end
