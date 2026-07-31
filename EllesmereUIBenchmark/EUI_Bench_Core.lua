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

-- Always-on engine profiler (no scriptProfile CVar needed): recent average
-- ms/frame across ALL addons. Guarded because the API family is newer than
-- the oldest Interface version in the TOC. Per-module tables are phase 3.
local METRIC_RECENT = Enum and Enum.AddOnProfilerMetric and Enum.AddOnProfilerMetric.RecentAverageTime
function B.OverallCpuMs()
    if C_AddOnProfiler and C_AddOnProfiler.GetOverallMetric and METRIC_RECENT then
        return C_AddOnProfiler.GetOverallMetric(METRIC_RECENT)
    end
end

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
        -- CPU rides the same 1Hz tick: the engine's own recent average, so
        -- sampling it costs a table lookup rather than any measurement work.
        local cpu = B.OverallCpuMs()
        if cpu then
            S.cpuSamples = S.cpuSamples + 1
            S.cpuSum = S.cpuSum + cpu
            if cpu > S.cpuMax then S.cpuMax = cpu end
        end
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
        cpuSamples = 0, cpuSum = 0, cpuMax = 0,
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
    local function Line(label, value)
        print(format("|cff0cd29f%-18s|r %s", label .. ":", value))
    end

    print(format("|cff0cd29f=== EllesmereUI Benchmark ===|r  session \"%s\"", R.label))
    Line("Duration", format("%.1f s   (%d frames, %.1f%% of it in combat)",
        dur, R.frames, R.combatSec / dur * 100))
    Line("Average FPS", format("%.1f", R.frames / dur))

    -- Frame time: the percentiles are the honest smoothness measure. p99 is
    -- what a player calls "it stutters" even when the average looks fine.
    Line("Frame Time", format("p50 %.2f ms   p95 %.2f ms   p99 %.2f ms   worst %.1f ms",
        R.p50, R.p95, R.p99, R.maxMs))
    Line("Hitches", format("%d over 16.7 ms (%.1f%%)   %d over 33 ms   %d over 100 ms",
        R.over16, R.frames > 0 and R.over16 / R.frames * 100 or 0, R.over33, R.over100))

    -- CPU Load: engine figure for ALL addons together, i.e. how much of each
    -- frame every addon costs. NOT EllesmereUI's share -- confusing the two
    -- denominators is what turns a normal number into a scary one. Per-module
    -- attribution lands in phase 3.
    if R.cpuSamples > 0 then
        Line("CPU Load", format("%.2f ms/frame avg   %.2f ms peak   (all addons combined)",
            R.cpuSum / R.cpuSamples, R.cpuMax))
    else
        Line("CPU Load", "unavailable on this client build")
    end

    -- Allocation rate drives GC stutter; the absolute heap size rarely matters.
    Line("Lua Memory", format("%.1f -> %.1f MB   (low %.1f, high %.1f)",
        R.luaStart / 1024, R.luaStop / 1024, R.luaMin / 1024, R.luaMax / 1024))
    Line("Alloc Rate", format("%.0f KB/s   %d garbage collections",
        R.allocKB / dur, R.gcCycles))

    local rows, totalKB = {}, 0
    for name, stopKB in pairs(R.memStop) do
        totalKB = totalKB + stopKB
        rows[#rows + 1] = { name = name, delta = stopKB - (R.memStart[name] or 0) }
    end
    table.sort(rows, function(a, b) return math.abs(a.delta) > math.abs(b.delta) end)
    Line("Module Memory", format("%.1f MB total across %d EllesmereUI addons", totalKB / 1024, #rows))
    print("|cff0cd29f  Biggest movers this session (KB):|r")
    for i = 1, math.min(#rows, 10) do
        print(format("    %-34s %+9.1f KB", rows[i].name, rows[i].delta))
    end

    -- Printed every time on purpose: a benchmark that hides its own cost is
    -- reporting its own overhead as the addon's.
    Line("Harness Cost", format("%.1f ms total   %.1f us/frame   %.2f%% of session",
        R.selfMs, R.frames > 0 and R.selfMs * 1000 / R.frames or 0,
        R.selfMs / (dur * 1000) * 100))
end
