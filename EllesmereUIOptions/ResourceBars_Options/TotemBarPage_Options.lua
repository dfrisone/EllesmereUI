if EUI_CLIENT_BLOCKED then return end -- pre-12.1 client failsafe (EllesmereUI_ClientGate.lua)
-------------------------------------------------------------------------------
--  ResourceBars_Options\TotemBarPage_Options.lua
--  Resource Bars options: Totem Bar page. Definitions only; the shared
--  helpers come from ns._ERB_OptEnv (filled by EUI_ResourceBars_Options.lua).
-------------------------------------------------------------------------------
local ns = EllesmereUI._ModuleNS["EllesmereUIResourceBars"]
if not ns then return end  -- module disabled: no options page

-- Totem Bar options page
function ns.ERB_BuildTotemBarPage(pageName, parent, yOffset)
    local env = ns._ERB_OptEnv
    local DB, PP, _clickMappings = env.DB, env.PP, env._clickMappings
    local W = EllesmereUI.Widgets
    local y = yOffset
    local _, h

    parent._showRowDivider = true

    EllesmereUI:HideContentHeader()

    -- Shared live table; never wiped from a hidden pre-build (see the matching guard in BuildBarDisplayPage).
    if not EllesmereUI._prebuilding then
        wipe(_clickMappings)
    end

    local function RefreshTotem()
        if _G._ERB_Apply then _G._ERB_Apply() end
        if EllesmereUI.NotifyElementResized then
            EllesmereUI.NotifyElementResized("ERB_TotemBar")
        end
    end

    local totemOff = function()
        local p = DB()
        return p and not p.totemBar.enabledClasses
    end

    local timerOff = function()
        local p = DB()
        return p and (not p.totemBar.enabledClasses or not p.totemBar.showTimer)
    end

    -- LAYOUT section
    local layoutSection
    layoutSection, h = W:SectionHeader(parent, "LAYOUT", y);  y = y - h

    local ALL_CLASSES = EllesmereUI.CLASS_TOKEN_ORDER

    -- Row 1: Enabled Classes dropdown | Icon Size (+ spacing cog)
    local row1
    do
        local classItems = {}
        classItems[#classItems + 1] = { key = "NONE", label = EllesmereUI.L("None (Disabled)") }
        for _, cf in ipairs(ALL_CLASSES) do
            local color = RAID_CLASS_COLORS and RAID_CLASS_COLORS[cf]
            local name = (LOCALIZED_CLASS_NAMES_MALE and LOCALIZED_CLASS_NAMES_MALE[cf])
                or (cf:sub(1, 1):upper() .. cf:sub(2):lower())
            local hex = color and color.colorStr or "ffffffff"
            classItems[#classItems + 1] = { key = cf, label = "|c" .. hex .. name .. "|r" }
        end

        row1, h = W:DualRow(parent, y,
            { type = "label", text = "Enabled Classes" },
            { type = "slider", text = "Icon Size",
              min = 16, max = 60, step = 1,
              disabled = totemOff,
              disabledTooltip = "Select a class above", rawTooltip = true,
              getValue = function() local p = DB(); return p and (p.totemBar.iconSize or 30) end,
              setValue = function(v)
                  local p = DB(); if not p then return end
                  p.totemBar.iconSize = v; RefreshTotem()
              end }
        );  y = y - h

        -- Class dropdown on left region
        if not EllesmereUI._prebuilding then
        local leftRgn = row1._leftRegion
        local cbDD, cbDDRefresh
        cbDD, cbDDRefresh = EllesmereUI.BuildVisOptsCBDropdown(
            leftRgn, 210, leftRgn:GetFrameLevel() + 2,
            classItems,
            function(key)
                local p = DB()
                if not p then return false end
                if key == "NONE" then return not p.totemBar.enabledClasses end
                return p.totemBar.enabledClasses and p.totemBar.enabledClasses[key] or false
            end,
            function(key, v)
                local p = DB()
                if not p then return end
                if key == "NONE" then
                    p.totemBar.enabledClasses = nil
                else
                    if not p.totemBar.enabledClasses then
                        p.totemBar.enabledClasses = {}
                    end
                    p.totemBar.enabledClasses[key] = v or nil
                    if not next(p.totemBar.enabledClasses) then
                        p.totemBar.enabledClasses = nil
                    end
                end
                local ddMenu = cbDD._ddMenu
                if ddMenu then
                    for _, sf in ipairs({ ddMenu:GetChildren() }) do
                        local sc = sf.GetScrollChild and sf:GetScrollChild()
                        if sc then
                            for _, row in ipairs({ sc:GetChildren() }) do
                                if row._updateCheck then row._updateCheck() end
                            end
                        end
                    end
                end
                RefreshTotem()
                EllesmereUI:RefreshPage()
            end, nil, 8, false)
        PP.Point(cbDD, "RIGHT", leftRgn, "RIGHT", -20, 0)
        leftRgn._control = cbDD
        leftRgn._lastInline = nil
        EllesmereUI.RegisterWidgetRefresh(cbDDRefresh)

        -- Spacing cog on Icon Size (right region)
        local rgn = row1._rightRegion
        EllesmereUI.BuildInlineCog(rgn, {
            title = "Icon Settings",
            rows = {
                { type = "slider", pixel = true, label = "Spacing", min = 0, max = 20, step = 1,
                  get = function() local p = DB(); return p and (p.totemBar.spacing or 2) end,
                  set = function(v)
                      local p = DB(); if not p then return end
                      p.totemBar.spacing = v; RefreshTotem()
                  end },
            },
        })
        end
    end

    -- Row 2: Timer Size | Show Timer
    _, h = W:DualRow(parent, y,
        { type = "slider", text = "Timer Size",
          min = 6, max = 24, step = 1,
          disabled = timerOff,
          disabledTooltip = "Show Timer",
          getValue = function() local p = DB(); return p and (p.totemBar.timerSize or 11) end,
          setValue = function(v)
              local p = DB(); if not p then return end
              p.totemBar.timerSize = v; RefreshTotem()
          end },
        { type = "toggle", text = "Show Timer",
          disabled = totemOff,
          disabledTooltip = "Select a class above", rawTooltip = true,
          getValue = function() local p = DB(); return p and p.totemBar.showTimer ~= false end,
          setValue = function(v)
              local p = DB(); if not p then return end
              p.totemBar.showTimer = v; RefreshTotem()
              EllesmereUI:RefreshPage()
          end }
    );  y = y - h

    -- Row 3: Border Style | Border Size (+ inline swatch + offset cog)
    do
        local texValues, texOrder = EllesmereUI.GetBorderTextureDropdown()
        local bsRow
        bsRow, h = W:DualRow(parent, y,
            { type = "dropdown", text = "Border Style",
              disabled = totemOff,
              disabledTooltip = "Select a class above", rawTooltip = true,
              values = texValues, order = texOrder,
              getValue = function() local p = DB(); return p and (p.totemBar.borderTexture or "solid") end,
              setValue = function(v)
                  local p = DB(); if not p then return end
                  p.totemBar.borderTexture = v
                  p.totemBar.borderTextureOffset = nil; p.totemBar.borderTextureOffsetY = nil
                  p.totemBar.borderTextureShiftX = nil; p.totemBar.borderTextureShiftY = nil
                  local _bcol, _bbehind = EllesmereUI.GetBorderStyleSelectDefaults(v)
                  p.totemBar.borderR = _bcol.r; p.totemBar.borderG = _bcol.g; p.totemBar.borderB = _bcol.b; p.totemBar.borderA = 1
                  p.totemBar.borderBehind = _bbehind
                  local defSz = EllesmereUI.GetBorderDefaultSize("resourcebars", v)
                  if defSz then p.totemBar.borderSize = defSz end
                  if p.totemBar.borderSizePx then p.totemBar.borderSizePx = false end
                  RefreshTotem(); EllesmereUI:RefreshPage(true)
              end },
            EllesmereUI.BorderPxSliderCfg({ text = "Border Size",
              disabled = totemOff,
              disabledTooltip = "Select a class above", rawTooltip = true,
              getStep = function() local p = DB(); return p and (p.totemBar.borderSize or 0) or 0 end,
              setStep = function(v) local p = DB(); if p then p.totemBar.borderSize = v end end,
              getTex = function() local p = DB(); return p and (p.totemBar.borderTexture or "solid") or "solid" end,
              getPx = function() local p = DB(); return p and p.totemBar.borderSizePx end,
              setPx = function(v) local p = DB(); if p then p.totemBar.borderSizePx = v end end,
              apply = function() RefreshTotem(); EllesmereUI:RefreshPage() end,
            })
        );  y = y - h
        -- Width Offset | Height Offset: own row while a textured style is selected.
        do
            local p = DB()
            local tex = p and p.totemBar.borderTexture or "solid"
            if tex ~= "solid" and tex ~= "" then
                local function step() local p = DB(); return p and (p.totemBar.borderSize or 0) or 0 end
                local ocfgL, ocfgR = EllesmereUI.BorderOffsetRowCfgs({
                    addonKey = "resourcebars",
                    disabled = totemOff,
                    disabledTooltip = "Select a class above", rawTooltip = true,
                    getTex = function() local p = DB(); return p and (p.totemBar.borderTexture or "solid") or "solid" end,
                    getStep = step, getSizeKey = step,
                    getPx = function() local p = DB(); return p and p.totemBar.borderSizePx end,
                    getX = function() local p = DB(); return p and p.totemBar.borderTextureOffset end,
                    setX = function(v) local p = DB(); if p then p.totemBar.borderTextureOffset = v end end,
                    getY = function() local p = DB(); return p and p.totemBar.borderTextureOffsetY end,
                    setY = function(v) local p = DB(); if p then p.totemBar.borderTextureOffsetY = v end end,
                    apply = function() RefreshTotem(); EllesmereUI:RefreshPage() end,
                })
                _, h = W:DualRow(parent, y, ocfgL, ocfgR);  y = y - h
            end
        end

        -- Inline border color swatch on Border Size slider
        do
            local rgn = bsRow._rightRegion
            local ctrl = rgn._control
            local PP = EllesmereUI.PP
            local borderSwatch, updateBorderSwatch = EllesmereUI.BuildColorSwatch(
                rgn, bsRow:GetFrameLevel() + 3,
                function()
                    local p = DB()
                    return (p and p.totemBar.borderR or 0), (p and p.totemBar.borderG or 0),
                           (p and p.totemBar.borderB or 0), (p and p.totemBar.borderA or 1)
                end,
                function(r, g, b, a)
                    local p = DB(); if not p then return end
                    p.totemBar.borderR = r; p.totemBar.borderG = g; p.totemBar.borderB = b; p.totemBar.borderA = a
                    RefreshTotem(); EllesmereUI:RefreshPage()
                end,
                true, 20)
            PP.Point(borderSwatch, "RIGHT", ctrl, "LEFT", -8, 0)
            -- Disable swatch when border size is 0
            local borderSwatchBlock = CreateFrame("Frame", nil, borderSwatch)
            borderSwatchBlock:SetAllPoints()
            borderSwatchBlock:SetFrameLevel(borderSwatch:GetFrameLevel() + 10)
            borderSwatchBlock:EnableMouse(true)
            borderSwatchBlock:SetScript("OnEnter", function()
                EllesmereUI.ShowWidgetTooltip(borderSwatch, EllesmereUI.DisabledTooltip("This option requires a Border Size above 0."))
            end)
            borderSwatchBlock:SetScript("OnLeave", function() EllesmereUI.HideWidgetTooltip() end)
            local function UpdateBorderSwatchState()
                local p = DB()
                local noBorder = not p or (p.totemBar.borderSize or 0) == 0
                if noBorder then borderSwatch:SetAlpha(0.3); borderSwatchBlock:Show()
                else borderSwatch:SetAlpha(1); borderSwatchBlock:Hide() end
            end
            EllesmereUI.RegisterWidgetRefresh(function() updateBorderSwatch(); UpdateBorderSwatchState() end)
            UpdateBorderSwatchState()
        end

        -- Border Options cog on Border Style (left region): hidden for "solid",
        -- disabled with the section's controls while no class is selected
        if not EllesmereUI._prebuilding then
            local rgn = bsRow._leftRegion
            local cogBtn = EllesmereUI.BuildInlineCog(rgn, { icon = EllesmereUI.DIRECTIONS_ICON,
                disabled = totemOff, disabledTooltip = "Select a class above", rawTooltip = true,
                title = "Border Options",
                rows = {
                    { type = "slider", label = "Shift X", min = -10, max = 10, step = 1,
                      get = function()
                          local p = DB(); if not p then return 0 end
                          local v = p.totemBar.borderTextureShiftX
                          if v then return v end
                          local _, _, dsx = EllesmereUI.GetBorderDefaults("resourcebars", p.totemBar.borderTexture or "solid", p.totemBar.borderSize or 0)
                          return dsx
                      end,
                      set = function(v)
                          local p = DB(); if not p then return end
                          p.totemBar.borderTextureShiftX = v == 0 and nil or v; RefreshTotem(); EllesmereUI:RefreshPage()
                      end },
                    { type = "slider", label = "Shift Y", min = -10, max = 10, step = 1,
                      get = function()
                          local p = DB(); if not p then return 0 end
                          local v = p.totemBar.borderTextureShiftY
                          if v then return v end
                          local _, _, _, dsy = EllesmereUI.GetBorderDefaults("resourcebars", p.totemBar.borderTexture or "solid", p.totemBar.borderSize or 0)
                          return dsy
                      end,
                      set = function(v)
                          local p = DB(); if not p then return end
                          p.totemBar.borderTextureShiftY = v == 0 and nil or v; RefreshTotem(); EllesmereUI:RefreshPage()
                      end },
                    { type = "toggle", label = "Show Behind",
                      get = function() local p = DB(); return p and p.totemBar.borderBehind or false end,
                      set = function(v)
                          local p = DB(); if not p then return end
                          p.totemBar.borderBehind = v == false and nil or v; RefreshTotem(); EllesmereUI:RefreshPage()
                      end },
                },
            })
            local function UpdateCogVis()
                local p = DB()
                local tex = p and p.totemBar.borderTexture or "solid"
                if tex == "solid" then cogBtn:Hide() else cogBtn:Show() end
            end
            EllesmereUI.RegisterWidgetRefresh(UpdateCogVis)
            UpdateCogVis()
        end
    end

    -- Row 4: Frame Strata | Orientation
    local tmStrataValues = EllesmereUI.FRAME_STRATA_LABELS
    local tmStrataOrder = EllesmereUI.FRAME_STRATA_ORDER_BASE
    _, h = W:DualRow(parent, y,
        { type = "dropdown", text = "Frame Strata",
          tooltip = "Controls the order that overlapping elements display in. Set higher to show above other elements.",
          disabled = totemOff,
          disabledTooltip = "Select a class above", rawTooltip = true,
          values = tmStrataValues, order = tmStrataOrder,
          getValue = function()
              local p = DB(); return p and p.totemBar.frameStrata or "MEDIUM"
          end,
          setValue = function(v)
              local p = DB(); if not p then return end
              p.totemBar.frameStrata = v; RefreshTotem()
          end },
        { type = "dropdown", text = "Orientation",
          disabled = totemOff,
          disabledTooltip = "Select a class above", rawTooltip = true,
          values = { HORIZONTAL = "Horizontal", VERTICAL = "Vertical" },
          order = { "HORIZONTAL", "VERTICAL" },
          getValue = function() local p = DB(); return p and (p.totemBar.orientation or "HORIZONTAL") end,
          setValue = function(v)
              local p = DB(); if not p then return end
              p.totemBar.orientation = v; RefreshTotem()
          end }
    );  y = y - h

    return math.abs(y)
end
