-------------------------------------------------------------------------------
--  EUI_Bench_Options.lua
--  Slash commands, login bootstrap, and the options page.
--  Dev-only module: strings stay out of the locale system on purpose.
-------------------------------------------------------------------------------

local _, B = ...

SLASH_EUIBENCH1 = "/euibench"
SlashCmdList["EUIBENCH"] = function(msg)
    local cmd, rest = (msg or ""):match("^(%S*)%s*(.-)%s*$")
    cmd = cmd:lower()
    if cmd == "start" then
        B.StartSession(rest ~= "" and rest or nil)
    elseif cmd == "stop" then
        B.StopSession()
    elseif cmd == "report" then
        B.PrintReport()
    elseif cmd == "hud" then
        B.ToggleHud()
    elseif cmd == "cvaroff" then
        SetCVar("scriptProfile", "0")
        print("|cff0cd29fBench:|r scriptProfile cleared -- takes effect after a reload")
    else
        print("|cff0cd29fBench:|r dev benchmark -- /euibench start [label] | stop | report | hud")
    end
end

local boot = CreateFrame("Frame")
boot:RegisterEvent("PLAYER_LOGIN")
boot:SetScript("OnEvent", function(self)
    self:UnregisterAllEvents()

    -- scriptProfile survives logout and taxes every frame while set. The
    -- function-level deep dive (later phase) needs it; nothing else does.
    -- Left-on is the one way this addon could quietly cost a session, so
    -- say so on every login.
    if GetCVarBool and GetCVarBool("scriptProfile") then
        print("|cff0cd29fBench:|r WARNING: the scriptProfile CVar is ON (adds 10-30% CPU overhead). /euibench cvaroff to clear it.")
    end

    if B.db.profile.benchHudShown then
        B.ToggleHud(true)
    end

    if not (EllesmereUI and EllesmereUI.RegisterModule) then return end
    EllesmereUI:RegisterModule("EllesmereUIBenchmark", {
        title = "Benchmark",
        description = "Dev-only performance benchmark: frame times, memory, and per-module costs.",
        searchTerms = "benchmark performance fps cpu memory profiler dev",
        pages = { "Benchmark" },
        buildPage = function(pageName, parent, yOffset)
            if pageName ~= "Benchmark" then return end
            local ok, result = pcall(function()
                local W = EllesmereUI.Widgets
                local y = yOffset
                local h, _

                _, h = W:SectionHeader(parent, "BENCHMARK (DEV ONLY)", y); y = y - h

                _, h = W:DualRow(parent, y,
                    { type="toggle", text="Show Performance HUD",
                      tooltip="Small movable readout: fps, current frame ms, 5-second peak, Lua heap and allocation rate. The HUD is itself the sampler, so hide it while recording a session for the cleanest numbers.",
                      getValue=function() return B.HudShown() end,
                      setValue=function(v) B.ToggleHud(v and true or false) end }
                ); y = y - h

                do
                    local info = CreateFrame("Frame", nil, parent)
                    info:SetSize(parent:GetWidth(), 76)
                    info:SetPoint("TOP", parent, "TOP", 0, y - 8)
                    info._isSpacer = true
                    local fs = info:CreateFontString(nil, "OVERLAY")
                    fs:SetFont("Interface\\AddOns\\EllesmereUI\\media\\fonts\\Expressway.TTF", 13, "")
                    fs:SetTextColor(1, 1, 1, 0.7)
                    fs:SetPoint("TOPLEFT", info, "TOPLEFT", 24, 0)
                    fs:SetJustifyH("LEFT")
                    fs:SetText("/euibench start [label] -- begin recording a session"
                        .. "\n/euibench stop -- finish and print the report"
                        .. "\n/euibench report -- re-print the last report"
                        .. "\n/euibench hud -- toggle the HUD")
                    y = y - 92
                end

                _, h = W:Spacer(parent, y, 20); y = y - h
                return math.abs(y)
            end)
            if not ok then print("|cffff0000[Bench Options ERROR]|r " .. tostring(result)) end
            return ok and result or 0
        end,
    })
end)
