-------------------------------------------------------------------------------
--  EUI_Bench_Report.lua
--  Live HUD. Shown = sampling (its OnUpdate IS the measurement); hidden = the
--  OnUpdate never fires, per the off-state invariant. The HUD is itself addon
--  work that C_AddOnProfiler bills to this addon, so hide it while recording
--  a session when the cleanest numbers matter.
-------------------------------------------------------------------------------

local _, B = ...

local floor = math.floor
local FONT = "Interface\\AddOns\\EllesmereUI\\media\\fonts\\Expressway.TTF"

local hud

local function BuildHud()
    hud = CreateFrame("Frame", "EUI_BenchHud", UIParent)
    hud:SetSize(268, 92)
    hud:SetFrameStrata("HIGH")
    local pos = B.db.profile.benchHudPos
    if pos then
        hud:SetPoint(pos[1], UIParent, pos[1], pos[2], pos[3])
    else
        hud:SetPoint("TOP", UIParent, "TOP", 0, -120)
    end
    local bg = hud:CreateTexture(nil, "BACKGROUND")
    bg:SetAllPoints()
    bg:SetColorTexture(0.02, 0.02, 0.02, 0.85)
    if EllesmereUI.PanelPP then
        EllesmereUI.PanelPP.CreateBorder(hud, 0.1, 0.1, 0.1, 1, 1, "OVERLAY", 7)
    end
    hud:EnableMouse(true)
    hud:SetMovable(true)
    hud:RegisterForDrag("LeftButton")
    hud:SetScript("OnDragStart", hud.StartMoving)
    hud:SetScript("OnDragStop", function(self)
        self:StopMovingOrSizing()
        local point, _, _, x, y = self:GetPoint(1)
        B.db.profile.benchHudPos = { point, x, y }
    end)

    hud.title = hud:CreateFontString(nil, "OVERLAY")
    hud.title:SetFont(FONT, 11, "OUTLINE")
    hud.title:SetPoint("TOPLEFT", hud, "TOPLEFT", 10, -6)
    hud.title:SetTextColor(0.05, 0.82, 0.62, 1)
    hud.title:SetText("EllesmereUI Benchmark")

    hud.status = hud:CreateFontString(nil, "OVERLAY")
    hud.status:SetFont(FONT, 11, "OUTLINE")
    hud.status:SetPoint("TOPRIGHT", hud, "TOPRIGHT", -10, -6)

    -- Two columns: labels never change, so only the value strings are
    -- rewritten each refresh.
    local ROWS = { "FPS", "Frame Time", "CPU Load", "Memory" }
    hud.values = {}
    for i, label in ipairs(ROWS) do
        local y = -22 - (i - 1) * 16
        local l = hud:CreateFontString(nil, "OVERLAY")
        l:SetFont(FONT, 12, "OUTLINE")
        l:SetPoint("TOPLEFT", hud, "TOPLEFT", 10, y)
        l:SetJustifyH("LEFT")
        l:SetTextColor(1, 1, 1, 0.55)
        l:SetText(label)
        local v = hud:CreateFontString(nil, "OVERLAY")
        v:SetFont(FONT, 12, "OUTLINE")
        v:SetPoint("TOPRIGHT", hud, "TOPRIGHT", -10, y)
        v:SetJustifyH("RIGHT")
        hud.values[i] = v
    end

    -- 5s peak window + 1Hz heap delta; text refreshed at 2Hz through
    -- SetFormattedText, which formats in C and allocates no Lua strings.
    local textAcc, memAcc = 0, 0
    local winMax, winStart = 0, GetTime()
    local prevKB = collectgarbage("count")
    local rateKB = 0
    hud:SetScript("OnUpdate", function(self, elapsed)
        local ms = elapsed * 1000
        local now = GetTime()
        if now - winStart > 5 then
            winMax, winStart = ms, now
        elseif ms > winMax then
            winMax = ms
        end
        memAcc = memAcc + elapsed
        if memAcc >= 1 then
            memAcc = 0
            local cur = collectgarbage("count")
            rateKB = cur - prevKB   -- negative across a GC cycle, shown as-is
            prevKB = cur
        end
        textAcc = textAcc + elapsed
        if textAcc >= 0.5 then
            textAcc = 0
            local v = self.values
            v[1]:SetFormattedText("%.0f", GetFramerate())
            v[2]:SetFormattedText("%.1f ms   peak(5s) %.0f ms", ms, winMax)
            local cpu = B.OverallCpuMs()
            if cpu then
                v[3]:SetFormattedText("%.2f ms/frame  all addons", cpu)
            else
                v[3]:SetText("n/a")
            end
            v[4]:SetFormattedText("%.1f MB   %+d KB/s", collectgarbage("count") / 1024, rateKB)
            local el = B.SessionElapsed()
            if el then
                self.status:SetFormattedText("|cffff4040REC|r %d:%02d", floor(el / 60), floor(el % 60))
            else
                self.status:SetText("|cff808080idle|r")
            end
        end
    end)
end

function B.HudShown()
    return hud ~= nil and hud:IsShown()
end

function B.ToggleHud(show)
    if show == nil then show = not B.HudShown() end
    if show and not hud then
        -- Nothing here is secure; the no-combat-creation rule is kept uniform
        -- with the rest of the codebase anyway.
        if InCombatLockdown() then
            print("|cff0cd29fBench:|r HUD builds after combat ends")
            return
        end
        BuildHud()
    end
    if show then
        hud:Show()
    elseif hud then
        hud:Hide()
    end
    B.db.profile.benchHudShown = show and true or false
end
