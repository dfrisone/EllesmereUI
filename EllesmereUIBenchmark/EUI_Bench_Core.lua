-------------------------------------------------------------------------------
--  EUI_Bench_Core.lua
--  Dev-only benchmark: frame-time + memory samplers and the session recorder.
--  Excluded from release builds via .pkgmeta; ordinary users never load this.
--
--  OFF-STATE INVARIANT: idle means UNREGISTERED, not early-returned. With no
--  session running and the HUD hidden, this addon has no OnUpdate and no
--  events beyond the one-shot PLAYER_LOGIN bootstrap, and C_AddOnProfiler
--  should read ~0 for it. Samplers register on start and unregister on stop.
-------------------------------------------------------------------------------

local _, B = ...

local format = string.format
local floor = math.floor

B.db = EllesmereUI.Lite.NewDB("EllesmereUIBenchmarkDB", {
    profile = {
        benchHudShown = false,
        benchHudPos   = nil,   -- { point, x, y } once dragged
    },
})

-------------------------------------------------------------------------------
--  Frame-time histogram
--  Fixed 0.25ms buckets to 50ms plus one overflow bucket: O(1) per frame,
--  bounded memory for any session length, percentiles to 0.25ms resolution.
--  Preallocated so the sampler never allocates -- the memory metrics would
--  otherwise be measuring the harness.
-------------------------------------------------------------------------------
local BUCKET_MS = 0.25
local BUCKETS   = 200            -- 200 * 0.25ms = 50ms, then overflow
local hist = {}
for i = 1, BUCKETS + 1 do hist[i] = 0 end

local function Percentile(total, q)
    if total == 0 then return 0 end
    local target, cum = total * q, 0
    for i = 1, BUCKETS + 1 do
        cum = cum + hist[i]
        if cum >= target then return i * BUCKET_MS end
    end
    return (BUCKETS + 1) * BUCKET_MS
end

-------------------------------------------------------------------------------
--  Session recorder
-------------------------------------------------------------------------------
local S      -- active session, nil when idle
local last   -- last finished session, kept for /euibench report

local samplerFrame = CreateFrame("Frame")
samplerFrame:Hide()

-- Combat-fraction bookkeeping; registered only while a session runs.
local eventFrame = CreateFrame("Frame")
eventFrame:SetScript("OnEvent", function(_, event)
    if not S then return end
    if event == "PLAYER_REGEN_DISABLED" then
        S.combatT0 = GetTime()
    elseif S.combatT0 then
        S.combatSec = S.combatSec + (GetTime() - S.combatT0)
        S.combatT0 = nil
    end
end)

-- UpdateAddOnMemoryUsage walks every loaded addon and is expensive: session
-- boundaries only, never inside the sampler.
local function SnapshotModuleMemory(out)
    if UpdateAddOnMemoryUsage then UpdateAddOnMemoryUsage() end
    for i = 1, C_AddOns.GetNumAddOns() do
        local name = C_AddOns.GetAddOnInfo(i)
        if name and name:sub(1, 11) == "EllesmereUI" and C_AddOns.IsAddOnLoaded(i) then
            out[name] = GetAddOnMemoryUsage(i)   -- KB
        end
    end
    return out
end

local function SamplerTick(_, elapsed)
    local t0 = debugprofilestop()
    local ms = elapsed * 1000
    S.frames = S.frames + 1
    if ms > S.maxMs then S.maxMs = ms end
    if ms > 16.7 then
        S.over16 = S.over16 + 1
        if ms > 33.4 then S.over33 = S.over33 + 1 end
        if ms > 100 then S.over100 = S.over100 + 1 end
    end
    local b = floor(ms / BUCKET_MS) + 1
    if b > BUCKETS + 1 then b = BUCKETS + 1 end
    hist[b] = hist[b] + 1

    -- 1Hz heap sample: rising deltas sum to the allocation rate, a drop is a
    -- GC cycle. Alloc rate is the number that drives GC stutter; a flat
    -- "addon uses N MB" is mostly trivia.
    S.memAcc = S.memAcc + elapsed
    if S.memAcc >= 1 then
        S.memAcc = 0
        local cur = collectgarbage("count")   -- KB
        if cur > S.luaMax then S.luaMax = cur end
        if cur < S.luaMin then S.luaMin = cur end
        if cur >= S.luaPrev then
            S.allocKB = S.allocKB + (cur - S.luaPrev)
        else
            S.gcCycles = S.gcCycles + 1
        end
        S.luaPrev = cur
    end

    S.selfMs = S.selfMs + (debugprofilestop() - t0)
end

function B.IsRunning()
    return S ~= nil
end

function B.SessionElapsed()
    if not S then return nil end
    return GetTime() - S.t0
end

function B.StartSession(label)
    if S then
        print(format("|cff0cd29fBench:|r session \"%s\" already running -- /euibench stop first", S.label))
        return
    end
    for i = 1, BUCKETS + 1 do hist[i] = 0 end
    -- Module snapshot before the heap baseline: the snapshot itself allocates.
    local memStart = SnapshotModuleMemory({})
    local luaNow = collectgarbage("count")
    S = {
        label = label or date("%H:%M:%S"),
        t0 = GetTime(),
        frames = 0, maxMs = 0, over16 = 0, over33 = 0, over100 = 0,
        memAcc = 0, luaStart = luaNow, luaPrev = luaNow,
        luaMin = luaNow, luaMax = luaNow,
        allocKB = 0, gcCycles = 0,
        combatSec = 0, combatT0 = InCombatLockdown() and GetTime() or nil,
        selfMs = 0,
        memStart = memStart,
    }
    eventFrame:RegisterEvent("PLAYER_REGEN_DISABLED")
    eventFrame:RegisterEvent("PLAYER_REGEN_ENABLED")
    samplerFrame:SetScript("OnUpdate", SamplerTick)
    samplerFrame:Show()
    print(format("|cff0cd29fBench:|r recording \"%s\" -- /euibench stop for the report", S.label))
end

function B.StopSession()
    if not S then
        print("|cff0cd29fBench:|r no session running")
        return
    end
    samplerFrame:SetScript("OnUpdate", nil)
    samplerFrame:Hide()
    eventFrame:UnregisterAllEvents()
    if S.combatT0 then
        S.combatSec = S.combatSec + (GetTime() - S.combatT0)
        S.combatT0 = nil
    end
    S.duration = GetTime() - S.t0
    S.luaStop = collectgarbage("count")
    S.memStop = SnapshotModuleMemory({})
    -- Percentiles come off the shared histogram, so they must be computed
    -- here, before the next StartSession zeroes it.
    S.p50 = Percentile(S.frames, 0.50)
    S.p95 = Percentile(S.frames, 0.95)
    S.p99 = Percentile(S.frames, 0.99)
    last = S
    S = nil
    B.PrintReport()
end

function B.PrintReport()
    local R = last
    if not R then
        print("|cff0cd29fBench:|r no finished session yet -- /euibench start")
        return
    end
    local dur = R.duration > 0 and R.duration or 0.001
    print(format("|cff0cd29fBench:|r \"%s\"  %.1fs  %d frames  %.1f avg fps  combat %d%%",
        R.label, dur, R.frames, R.frames / dur, floor(R.combatSec / dur * 100 + 0.5)))
    print(format("|cff0cd29fBench:|r frame ms  p50 %.2f  p95 %.2f  p99 %.2f  max %.1f",
        R.p50, R.p95, R.p99, R.maxMs))
    print(format("|cff0cd29fBench:|r hitches  >16.7ms %d (%.1f%%)  >33ms %d  >100ms %d",
        R.over16, R.frames > 0 and R.over16 / R.frames * 100 or 0, R.over33, R.over100))
    print(format("|cff0cd29fBench:|r lua heap %.1f -> %.1f MB (min %.1f, max %.1f)  alloc %.0f KB/s  gc cycles %d",
        R.luaStart / 1024, R.luaStop / 1024, R.luaMin / 1024, R.luaMax / 1024,
        R.allocKB / dur, R.gcCycles))
    local rows, totalKB = {}, 0
    for name, stopKB in pairs(R.memStop) do
        totalKB = totalKB + stopKB
        rows[#rows + 1] = { name = name, delta = stopKB - (R.memStart[name] or 0) }
    end
    table.sort(rows, function(a, b) return math.abs(a.delta) > math.abs(b.delta) end)
    print(format("|cff0cd29fBench:|r module memory %.1f MB total, session deltas (KB):", totalKB / 1024))
    for i = 1, math.min(#rows, 10) do
        print(format("  %-34s %+9.1f", rows[i].name, rows[i].delta))
    end
    print(format("|cff0cd29fBench:|r harness cost %.1f ms total, %.1f us/frame (%.2f%% of session)",
        R.selfMs, R.frames > 0 and R.selfMs * 1000 / R.frames or 0, R.selfMs / (dur * 1000) * 100))
end
