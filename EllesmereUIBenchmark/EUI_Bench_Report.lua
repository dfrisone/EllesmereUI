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
    hud:SetSize(250, 42)
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

    hud.line1 = hud:CreateFontString(nil, "OVERLAY")
    hud.line1:SetFont(FONT, 13, "OUTLINE")
    hud.line1:SetPoint("TOP", hud, "TOP", 0, -7)
    hud.line2 = hud:CreateFontString(nil, "OVERLAY")
    hud.line2:SetFont(FONT, 12, "OUTLINE")
    hud.line2:SetPoint("TOP", hud.line1, "BOTTOM", 0, -4)

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
            self.line1:SetFormattedText("%.0f fps   %.1f ms   peak(5s) %.0f ms",
                GetFramerate(), ms, winMax)
            local el = B.SessionElapsed()
            if el then
                self.line2:SetFormattedText("%.1f MB   %+d KB/s   |cffff4040REC|r %d:%02d",
                    collectgarbage("count") / 1024, rateKB, floor(el / 60), floor(el % 60))
            else
                self.line2:SetFormattedText("%.1f MB   %+d KB/s   idle",
                    collectgarbage("count") / 1024, rateKB)
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
