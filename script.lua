    -- Conversely: must be inside a Laser/LaserHitbox folder
    local function _hasLaserAncestor(d, plot)
        local p = d.Parent
        while p and p ~= plot do
            if p.Name == "Laser" or p.Name == "LaserHitbox" then return true end
            p = p.Parent
        end
        return false
    end

    -- Apply our laser look to a single newly-spotted part or beam
    local function _applyLaserLookTo(d, look)
        if _originalLaserState[d] then return end
        local plot = GetPlayerPlot()
        if not plot then return end
        if _hasBlockedAncestor(d, plot) then return end

        if d:IsA("Beam") then
            -- Only recolor Beams whose host is laser-related
            local host = d.Parent
            local hostIsLaser = false
            if host then
                local lower = host.Name:lower()
                hostIsLaser = (lower:find("laser") ~= nil)
                    or lower:find("structure base home") ~= nil
                    or _hasLaserAncestor(host, plot)
            end
            if not hostIsLaser then return end
            _originalLaserState[d] = { kind = "beam", Color = d.Color, Transparency = d.Transparency }
            pcall(function()
                d.Color        = look.beamColor
                d.Transparency = look.beamTransparency
            end)
        elseif d:IsA("BasePart") and d.Name ~= "LaserHitbox" and d.Transparency < 1 then
            local lower = d.Name:lower()
            local nameLooksLaser = lower:find("laser") ~= nil
                or lower:find("structure base home") ~= nil
            local underLaser = _hasLaserAncestor(d, plot)
            -- Strict: must be inside a Laser folder OR have a laser-like name.
            -- Reddish-only parts are NOT recolored (cashpad/etc. would be blue otherwise).
            if nameLooksLaser or underLaser then
                _originalLaserState[d] = {
                    kind = "part",
                    Color = d.Color, Material = d.Material, Transparency = d.Transparency,
                }
                pcall(function()
                    d.Color        = look.partColor
                    d.Material     = look.partMaterial
                    d.Transparency = look.partTransparency
                end)
            end
        end
    end

    -- Sync our chosen skin into the game's actual Settings UI dropdown so the
    -- player sees their selection persisted there. Called whenever a skin is
    -- applied AND whenever the Settings UI becomes visible.
    function _syncBaseSkinToGameSettings(skinName)
        if not skinName or skinName == "" then return end
        local pg = LocalPlayer:FindFirstChild("PlayerGui")
        if not pg then return end
        local sGui = pg:FindFirstChild("Settings")
        if not sGui then return end
        local sFrame = sGui:FindFirstChild("Settings")
        if not sFrame then return end
        local cont = sFrame:FindFirstChild("Content")
        if not cont then return end
        local scroll = cont:FindFirstChild("ScrollingFrame")
        if not scroll then return end
        local baseSkinRow
        for _, child in scroll:GetChildren() do
            if child:IsA("Frame") and child.Name == "Base Skin" then baseSkinRow = child; break end
        end
        if not baseSkinRow then return end
        local btn = baseSkinRow:FindFirstChild("Button")
        if not btn then return end
        local colors = SKIN_COLORS[skinName]
        if colors then
            btn.BackgroundColor3 = colors.main
            local s = btn:FindFirstChildOfClass("UIStroke")
            if s then s.Color = colors.stroke end
            local t = btn:FindFirstChild("Text")
            if t and t:IsA("TextLabel") then t.Text = skinName end
        end
    end

    -- Watch the Settings UI: every time it becomes visible/enabled, re-apply
    -- our skin so the dropdown reflects the active selection (the game would
    -- otherwise overwrite our visual sync each time it re-renders).
    task.spawn(function()
        local hookedSettings = nil
        local function hook(sg)
            if hookedSettings == sg then return end
            hookedSettings = sg
            local function reapply()
                if not _selectedSkin or _selectedSkin == "" then return end
                for i = 1, 8 do
                    task.delay(i * 0.1, function()
                        pcall(_syncBaseSkinToGameSettings, _selectedSkin)
                    end)
                end
            end
            sg:GetPropertyChangedSignal("Enabled"):Connect(function()
                if sg.Enabled then reapply() end
            end)
            local inner = sg:FindFirstChild("Settings")
            if inner then
                inner:GetPropertyChangedSignal("Visible"):Connect(function()
                    if inner.Visible then reapply() end
                end)
            end
            sg.DescendantAdded:Connect(function(d)
                -- a new "Base Skin" row got created → re-sync next frame
                if d.Name == "Base Skin" or (d.Parent and d.Parent.Name == "Base Skin") then
                    task.defer(reapply)
                end
            end)
        end
        while true do
            local pg = LocalPlayer:FindFirstChild("PlayerGui")
            local sg = pg and pg:FindFirstChild("Settings")
            if sg then hook(sg) end
            task.wait(1)
        end
    end)

    local function _recolorLasersForSkin(skinName)
        _restoreLasers()
        if _laserStreamConn then pcall(function() _laserStreamConn:Disconnect() end); _laserStreamConn = nil end
        _activeLaserSkin = skinName
        local look = LASER_LOOKS[skinName]
        if not look then return end
        local plot = GetPlayerPlot()
        if not plot then return end

        -- Listen for new descendants that stream in while this skin is active
        _laserStreamConn = plot.DescendantAdded:Connect(function(d)
            if _activeLaserSkin ~= skinName then return end
            local cur = LASER_LOOKS[_activeLaserSkin]
            if not cur then return end
            if d:IsA("Beam") or d:IsA("BasePart") then
                -- defer one frame so part properties are populated
                task.defer(function() _applyLaserLookTo(d, cur) end)
            end
        end)

        -- Initial pass: recolor everything that's already streamed in
        for _, d in plot:GetDescendants() do
            _applyLaserLookTo(d, look)
        end

        -- Safety re-scans in case more parts stream in late
        for _, t in ipairs({0.5, 1.5, 3.0, 6.0}) do
            task.delay(t, function()
                if _activeLaserSkin ~= skinName then return end
                local p = GetPlayerPlot()
                if not p then return end
                local cur = LASER_LOOKS[_activeLaserSkin]
                if not cur then return end
                for _, d in p:GetDescendants() do
                    _applyLaserLookTo(d, cur)
                end
            end)
        end
    end

    local function removeSkin()
        if _activeSkinClone then
            pcall(function() _activeSkinClone:Destroy() end)
            _activeSkinClone = nil
        end
        showPlotParts()
        _restoreLasers()
        _selectedSkin = nil
        _savedBaseSkin = nil
        ScheduleSave()
        SetStatus("Visual base removed", Color3.fromRGB(150,150,180), 2)
    end

    local function applySkin(skinName, folder)
        local skinEntry = folder:FindFirstChild(skinName)
        if not skinEntry then
            local found = {}
            for _, c in folder:GetChildren() do table.insert(found, c.Name) end
            SetStatus("Skin not found. Available: " .. table.concat(found, ", "), Color3.fromRGB(255,80,80), 6)
            return
        end

        local plot = GetPlayerPlot()
        if not plot then
            SetStatus("Stand on your plot first!", Color3.fromRGB(255,150,50), 3); return
        end

        local plotMainRoot = plot:FindFirstChild("MainRoot")
            or plot:FindFirstChild("Spawn")
        if not plotMainRoot then
            SetStatus("Plot root part not found", Color3.fromRGB(255,80,80), 3); return
        end

        -- pick the correct floor model based on player's rebirth level
        local floorName = getPlayerFloor()
        local floorModel = skinEntry:FindFirstChild(floorName)
        if not floorModel then
            -- fallback: try ThirdFloor > SecondFloor > FirstFloor > raw skin
            floorModel = skinEntry:FindFirstChild("ThirdFloor")
                or skinEntry:FindFirstChild("SecondFloor")
                or skinEntry:FindFirstChild("FirstFloor")
                or skinEntry
        end

        if _activeSkinClone then
            pcall(function() _activeSkinClone:Destroy() end)
            _activeSkinClone = nil
        end
        showPlotParts()

        local clone = floorModel:Clone()
        clone.Name = "KV_ActiveBaseSkin"

        for _, desc in clone:GetDescendants() do
            if desc:IsA("ProximityPrompt") or desc:IsA("PathfindingModifier") then
                pcall(function() desc:Destroy() end)
            end
        end

        for _, obj in clone:GetDescendants() do
            if (obj:IsA("TextLabel") or obj:IsA("TextButton")) then
                pcall(function()
                    if obj.Text:find("{playerName}") then
                        obj.Text = obj.Text:gsub("{playerName} Base", LocalPlayer.DisplayName .. "'s Base")
                        obj.Text = obj.Text:gsub("{playerName}", LocalPlayer.DisplayName)
                    end
                    -- fix hardcoded builder names on SkinPlotSign
                    if obj.Text:find("'s Base") and not obj.Text:find(LocalPlayer.DisplayName) then
                        obj.Text = LocalPlayer.DisplayName .. "'s Base"
                    end
                end)
            end
        end

        -- if skin has its own SkinPlotSign, remove the duplicate PlotSign
        local hasSkinPlotSign = clone:FindFirstChild("SkinPlotSign", true) ~= nil
        for _, desc in clone:GetDescendants() do
            local n = desc.Name
            if n == "CashPad" or n == "FriendPanel" or n == "AnimalPodiums"
            or n == "Laser" or n == "LaserHitbox" or n == "Claim"
            or n == "Multiplier" or n == "PlotBlock" or n == "YourBase"
            or (n == "PlotSign" and hasSkinPlotSign) then
                pcall(function() desc:Destroy() end)
            end
        end

        for _, obj in clone:GetDescendants() do
            if obj:IsA("BasePart") then
                obj.CanCollide = false; obj.CanQuery = false
                obj.CanTouch = false; obj.Anchored = true
            end
        end

        clone.Parent = workspace

        local plotCF = plotMainRoot.CFrame
        local skinRoot = clone:FindFirstChild("Root", true)
        local virtualRootCF = nil

        if skinRoot then
            virtualRootCF = skinRoot.CFrame
        else
            local parts = {}
            for _, d in clone:GetDescendants() do
                if d:IsA("BasePart") then table.insert(parts, d) end
            end
            if #parts > 0 then
                local gMinX, gMinZ = math.huge, math.huge
                local gMaxX, gMaxZ = -math.huge, -math.huge
                local groundY = 0.5
                local foundFloor = false
                for _, p in ipairs(parts) do
                    local area = p.Size.X * p.Size.Z
                    if p.Position.Y < 5 and area > 50 then
                        local pos = p.Position
                        local half = p.Size / 2
                        gMinX = math.min(gMinX, pos.X - half.X)
                        gMinZ = math.min(gMinZ, pos.Z - half.Z)
                        gMaxX = math.max(gMaxX, pos.X + half.X)
                        gMaxZ = math.max(gMaxZ, pos.Z + half.Z)
                    end
                    if area > 100 and p.Position.Y < 3 then
                        local refY = p.Position.Y - p.Size.Y * 0.15
                        if not foundFloor or refY < groundY then
                            groundY = refY
                            foundFloor = true
                        end
                    end
                end
                if gMinX == math.huge then
                    for _, p in ipairs(parts) do
                        local pos = p.Position
                        local half = p.Size / 2
                        gMinX = math.min(gMinX, pos.X - half.X)
                        gMinZ = math.min(gMinZ, pos.Z - half.Z)
                        gMaxX = math.max(gMaxX, pos.X + half.X)
                        gMaxZ = math.max(gMaxZ, pos.Z + half.Z)
                    end
                end
                virtualRootCF = CFrame.new((gMinX+gMaxX)/2, groundY, (gMinZ+gMaxZ)/2)
            end
        end

        if virtualRootCF then
            local rot = math.rad(0)
            local offset = plotCF * CFrame.Angles(0, rot, 0) * virtualRootCF:Inverse()
            for _, obj in clone:GetDescendants() do
                if obj:IsA("BasePart") then
                    obj.CFrame = offset * obj.CFrame
                end
            end
            if skinRoot then
                pcall(function() skinRoot:Destroy() end)
            end
        end

        hidePlotParts(plot)
        _activeSkinClone = clone
        _selectedSkin = skinName
        _savedBaseSkin = skinName
        _recolorLasersForSkin(skinName)
        ScheduleSave()
        SetStatus("Visual base: " .. skinName, Color3.fromRGB(40,200,80), 3)

        -- sync to game settings dropdown button
        pcall(_syncBaseSkinToGameSettings, skinName)
        do
            -- (legacy inline sync kept below, also runs the same way)
            local pg = LocalPlayer:FindFirstChild("PlayerGui")
            local sGui = pg and pg:FindFirstChild("Settings")
            local sFrame = sGui and sGui:FindFirstChild("Settings")
            local cont = sFrame and sFrame:FindFirstChild("Content")
            local scroll = cont and cont:FindFirstChild("ScrollingFrame")
            local baseSkinRow
            if scroll then
                for _, child in scroll:GetChildren() do
                    if child:IsA("Frame") and child.Name == "Base Skin" then baseSkinRow = child; break end
                end
            end
            local btn = baseSkinRow and baseSkinRow:FindFirstChild("Button")
            local colors = SKIN_COLORS[skinName]
            if btn and colors then
                btn.BackgroundColor3 = colors.main
                local s = btn:FindFirstChildOfClass("UIStroke")
                if s then s.Color = colors.stroke end
                local t = btn:FindFirstChild("Text")
                if t and t:IsA("TextLabel") then t.Text = skinName end
            end
        end
    end

    -- UI section
    New("TextLabel", {
        Size=UDim2.new(1,0,0,14), BackgroundTransparency=1,
        Text="BASE SKIN CHANGER", TextColor3=ACCENT,
        Font=Enum.Font.GothamBold, TextSize=9,
        TextXAlignment=Enum.TextXAlignment.Left,
        LayoutOrder=1, Parent=basePage,
    })

    -- toggle button (matches animal toggle style)
    local skinListVisible = false
    local skinToggleBtn = New("TextButton", {
        Size=UDim2.new(1,0,0,32), BackgroundColor3=Color3.fromRGB(24,24,30),
        BorderSizePixel=0, Text="▼  Select Base Skin",
        TextColor3=Color3.fromRGB(230,230,240), Font=Enum.Font.GothamBold,
        TextSize=12, AutoButtonColor=false, LayoutOrder=2, Parent=basePage,
    })
    Corner(skinToggleBtn, 6)
    Stroke(skinToggleBtn, Color3.fromRGB(60,60,90), 1, 0.2)
    skinToggleBtn.MouseEnter:Connect(function() skinToggleBtn.BackgroundColor3=Color3.fromRGB(30,28,42) end)
    skinToggleBtn.MouseLeave:Connect(function() skinToggleBtn.BackgroundColor3=Color3.fromRGB(24,24,30) end)

    -- inline dropdown panel (matches animal/traits/mutation pattern)
    local skinListPanel = New("Frame", {
        Size=UDim2.new(1, 0, 0, 240),
        BackgroundColor3=Color3.fromRGB(30,28,42),
        BorderSizePixel=0, ClipsDescendants=true,
        Visible=false, LayoutOrder=3, Parent=basePage,
    })
    Corner(skinListPanel, 6)
    Stroke(skinListPanel, Color3.fromRGB(50,45,80), 1, 0.2)

    local skinApplyBtn = New("TextButton", {
        Size=UDim2.new(1,0,0,32), BackgroundColor3=BTNGRN,
        Text="Apply Skin", TextColor3=Color3.fromRGB(255,255,255),
        Font=Enum.Font.GothamBold, TextSize=12, AutoButtonColor=false,
        BorderSizePixel=0, LayoutOrder=4, Parent=basePage,
    })
    Corner(skinApplyBtn, 5)
    skinApplyBtn.MouseEnter:Connect(function() skinApplyBtn.BackgroundColor3=Color3.fromRGB(60,200,100) end)
    skinApplyBtn.MouseLeave:Connect(function() skinApplyBtn.BackgroundColor3=BTNGRN end)

    local skinRemoveBtn = New("TextButton", {
        Size=UDim2.new(1,0,0,32), BackgroundColor3=BTNRED,
        Text="Reset Base", TextColor3=Color3.fromRGB(255,255,255),
        Font=Enum.Font.GothamBold, TextSize=12, AutoButtonColor=false,
        BorderSizePixel=0, LayoutOrder=5, Parent=basePage,
    })
    Corner(skinRemoveBtn, 5)
    skinRemoveBtn.MouseEnter:Connect(function() skinRemoveBtn.BackgroundColor3=Color3.fromRGB(220,60,60) end)
    skinRemoveBtn.MouseLeave:Connect(function() skinRemoveBtn.BackgroundColor3=BTNRED end)

    local skinListFrame = New("ScrollingFrame", {
        Size=UDim2.new(1,0,1,0), Position=UDim2.new(0,0,0,0),
        BackgroundColor3=BG, BorderSizePixel=0,
        ScrollBarThickness=3, ScrollBarImageColor3=Color3.fromRGB(108,92,231),
        CanvasSize=UDim2.new(0,0,0,0), AutomaticCanvasSize=Enum.AutomaticSize.Y,
        Parent=skinListPanel,
    })
    Corner(skinListFrame, 6)
    Stroke(skinListFrame, Color3.fromRGB(50,50,70), 1, 0.3)
    do
        local ul=Instance.new("UIListLayout",skinListFrame); ul.Padding=UDim.new(0,0)
        local up=Instance.new("UIPadding",skinListFrame)
        up.PaddingLeft=UDim.new(0,4); up.PaddingRight=UDim.new(0,4)
        up.PaddingTop=UDim.new(0,4); up.PaddingBottom=UDim.new(0,4)
    end

    local skinBtns = {}
    local function BuildSkinList()
        for _,b in ipairs(skinBtns) do pcall(function() b:Destroy() end) end
        skinBtns = {}
        local available = getAvailableSkins()
        if #available == 0 then
            local lbl = New("TextLabel", {
                Size=UDim2.new(1,0,0,30), BackgroundTransparency=1,
                Text="No skins available — try spawning a brainrot!",
                TextColor3=Color3.fromRGB(150,140,180), Font=Enum.Font.Gotham,
                TextSize=11, Parent=skinListFrame,
            })
            table.insert(skinBtns, lbl)
            return
        end
        for _, skin in ipairs(available) do
            local sel = (_selectedSkin == skin.name)
            local b = New("TextButton", {
                Size=UDim2.new(1,0,0,30),
                BackgroundColor3=sel and Color3.fromRGB(108,92,231) or BG,
                BackgroundTransparency=0,
                BorderSizePixel=0, AutoButtonColor=false, Text="", Parent=skinListFrame,
            })
            Corner(b, 4)
            New("TextLabel", {
                Size=UDim2.new(1,-16,1,0), Position=UDim2.new(0,12,0,0),
                BackgroundTransparency=1, Text=skin.name,
                TextColor3=Color3.fromRGB(230,230,240),
                Font=Enum.Font.GothamBold, TextSize=11,
                TextXAlignment=Enum.TextXAlignment.Left, Parent=b,
            })
            b.MouseEnter:Connect(function()
                if _selectedSkin ~= skin.name then b.BackgroundColor3=Color3.fromRGB(30,28,42) end
            end)
            b.MouseLeave:Connect(function()
                if _selectedSkin ~= skin.name then b.BackgroundColor3=BG end
            end)
            b.MouseButton1Click:Connect(function()
                _selectedSkin = skin.name
                skinListVisible = false
                skinListPanel.Visible = false
                skinToggleBtn.Text = "▼  " .. skin.name
            end)
            table.insert(skinBtns, b)
        end
    end

    skinToggleBtn.MouseButton1Click:Connect(function()
        skinListVisible = not skinListVisible
        local arrow = skinListVisible and "▲" or "▼"
        skinToggleBtn.Text = arrow .. "  " .. (_selectedSkin or "Select Base Skin")
        if skinListVisible then
            local ok, err = pcall(BuildSkinList)
            if not ok then
                SetStatus("Skin list build failed: " .. tostring(err), Color3.fromRGB(255,80,80), 4)
            end
        end
        skinListPanel.Visible = skinListVisible
    end)

    skinApplyBtn.Activated:Connect(function()
        if not _selectedSkin then
            SetStatus("Select a base skin first!", Color3.fromRGB(255,150,50), 2); return
        end
        local available = getAvailableSkins()
        local stillValid = false
        for _, s in ipairs(available) do
            if s.name == _selectedSkin then stillValid = true; break end
        end
        if not stillValid then
            SetStatus("That skin requires a specific brainrot spawned!", Color3.fromRGB(255,150,50), 3)
            _selectedSkin = nil
            skinToggleBtn.Text = "▼  Select Base Skin"
            return
        end
        loadSkinModels(function(folder)
            if folder then applySkin(_selectedSkin, folder) end
        end)
    end)

    skinRemoveBtn.Activated:Connect(function()
        removeSkin()
        skinToggleBtn.Text = "▼  Select Base Skin"
    end)

    local _lastAvailableCount = #getAvailableSkins()
    RunService.Heartbeat:Connect(function()
        if _activeSkinClone and not _activeSkinClone.Parent then
            _activeSkinClone = nil; showPlotParts()
        end
        if _activeSkinClone and _selectedSkin then
            local needed = nil
            for _, s in ipairs(SKINS) do
                if s.name == _selectedSkin then needed = s.brainrot; break end
            end
            if needed then -- only auto-remove for brainrot-gated skins
                -- Use the unified helper so REAL podium brainrots (server data)
                -- are also recognised — not just KV fakes. This way trading or
                -- selling the OG triggers the auto-revert to default.
                if not _hasBrainrot(needed) then
                    removeSkin()
                    skinToggleBtn.Text = "▼  Select Base Skin"
                    SetStatus(needed.." gone — base skin reset", Color3.fromRGB(255,150,50), 3)
                end
            end
        end
        local curCount = #getAvailableSkins()
        if curCount ~= _lastAvailableCount then
            _lastAvailableCount = curCount
            if injectIntoGameUI then task.defer(injectIntoGameUI) end
        end
    end)

    LocalPlayer.CharacterAdded:Connect(function()
        if _activeSkinClone and _selectedSkin then
            task.delay(2, function()
                if not _activeSkinClone or not _activeSkinClone.Parent then return end
                _hiddenParts = {}
                local plot = GetPlayerPlot()
                if plot then hidePlotParts(plot) end
            end)
        end
    end)

    -- re-hide plot parts when the game adds new descendants (sell/trade refreshes plot)
    local _plotConn = nil
    local function watchPlot()
        if _plotConn then pcall(function() _plotConn:Disconnect() end) end
        local plot = GetPlayerPlot()
        if not plot then return end
        _plotConn = plot.DescendantAdded:Connect(function(desc)
            if not _activeSkinClone or not _activeSkinClone.Parent then return end
            task.defer(function()
                if desc:IsA("BasePart")
                and not neverHide[desc.Name]
                and not desc:GetAttribute("IgnoreColor")
                and not isInsideProtected(desc, plot)
                and desc.Transparency < 1 then
                    _hiddenParts[desc] = desc.LocalTransparencyModifier
                    desc.LocalTransparencyModifier = 1
                end
            end)
        end)
    end
    task.spawn(function()
        task.wait(3)
        watchPlot()
    end)

    -- ── INJECT INTO GAME'S BASE SKIN UI ──────────────────────
    local SKIN_COLORS = {
        Skibidi          = { main = Color3.fromRGB(255, 255, 255), stroke = Color3.fromRGB(220, 220, 220) },
        Headless         = { main = Color3.fromRGB(126, 68, 227),  stroke = Color3.fromRGB(100, 50, 190)  },
        Meowl            = { main = Color3.fromRGB(255, 255, 20),  stroke = Color3.fromRGB(220, 220, 10)  },
        Strawberry       = { main = Color3.fromRGB(207, 59, 63),   stroke = Color3.fromRGB(180, 50, 50)   },
        Christmas        = { main = Color3.fromRGB(255, 67, 67),   stroke = Color3.fromRGB(220, 50, 50)   },
        Galaxy           = { main = Color3.fromRGB(130, 60, 255),  stroke = Color3.fromRGB(100, 40, 220)  },
        Rainbow          = { main = Color3.fromRGB(255, 100, 150), stroke = Color3.fromRGB(220, 80, 130)  },
        Valentines       = { main = Color3.fromRGB(227, 100, 187), stroke = Color3.fromRGB(200, 80, 160)  },
        ["Bunny Basket"] = { main = Color3.fromRGB(168, 224, 108), stroke = Color3.fromRGB(140, 200, 90)  },
        Divine           = { main = Color3.fromRGB(255, 209, 59),  stroke = Color3.fromRGB(220, 180, 40)  },
        Cursed           = { main = Color3.fromRGB(245, 56, 56),   stroke = Color3.fromRGB(210, 40, 40)   },
        ["John Pork"]    = { main = Color3.fromRGB(255, 143, 179), stroke = Color3.fromRGB(220, 120, 155) },
    }
    local _injectedBtns = {}

    local function injectIntoGameUI()
        -- Clear previous KV injections
        for _, b in ipairs(_injectedBtns) do pcall(function() b:Destroy() end) end
        _injectedBtns = {}

        local pg = LocalPlayer:FindFirstChild("PlayerGui")
        if not pg then return end
        local settingsGui = pg:FindFirstChild("Settings")
        if not settingsGui then return end
        local settingsFrame = settingsGui:FindFirstChild("Settings")
        if not settingsFrame then return end
        local content = settingsFrame:FindFirstChild("Content")
        if not content then return end
        local scrollFrame = content:FindFirstChild("ScrollingFrame")
        if not scrollFrame then return end

        local baseSkinRow
        for _, child in scrollFrame:GetChildren() do
            if child:IsA("Frame") and child.Name == "Base Skin" then
                baseSkinRow = child; break
            end
        end
        if not baseSkinRow then return end

        local button = baseSkinRow:FindFirstChild("Button")
        if not button then return end

        -- Sync the main button to currently-active skin
        if _selectedSkin and SKIN_COLORS[_selectedSkin] then
            local colors = SKIN_COLORS[_selectedSkin]
            button.BackgroundColor3 = colors.main
            local ms = button:FindFirstChildOfClass("UIStroke")
            if ms then ms.Color = colors.stroke end
            local mt = button:FindFirstChild("Text")
            if mt and mt:IsA("TextLabel") then mt.Text = _selectedSkin end
        end

        local dropDown = button:FindFirstChild("DropDown")
        if not dropDown then return end

        -- Find the template button (always invisible, named "Template")
        local template = dropDown:FindFirstChild("Template")
        if not template then
            for _, c in dropDown:GetChildren() do
                if (c:IsA("ImageButton") or c:IsA("Frame")) and not c.Visible then
                    template = c; break
                end
            end
        end
        if not template then return end

        -- Before hiding, grab a real button's size so our clones match.
        -- We read AbsoluteSize (the rendered pixel size) not Size, because some
        -- of the game's buttons use Scale sizing where Size.Y.Offset = 0.
        local refSize = template.Size
        local refAbsY = 0
        local function grabRefSize(parent)
            for _, c in parent:GetChildren() do
                if c == template then continue end
                if c.Name:sub(1,3) == "KV_" then continue end
                if (c:IsA("ImageButton") or c:IsA("TextButton") or c:IsA("Frame"))
                   and c.Visible and c.AbsoluteSize.Y > 20 then
                    refSize = c.Size
                    refAbsY = c.AbsoluteSize.Y
                    return true
                end
            end
            return false
        end
        if not grabRefSize(dropDown) then
            local existingWrap0 = dropDown:FindFirstChild("KV_ScrollWrap")
            if existingWrap0 then grabRefSize(existingWrap0) end
        end
        -- If the game's buttons used Scale-only sizing, convert to a pixel-based
        -- size so our clones are guaranteed the same actual height even if they
        -- end up in a wrapper with different relative parent.
        if refSize.Y.Scale > 0 and refAbsY > 0 then
            refSize = UDim2.new(refSize.X.Scale, refSize.X.Offset, 0, refAbsY)
        end

        -- HIDE every existing real game button in the dropdown. We don't destroy
        -- them (the game might re-show on its own re-render), just Visible=false.
        local function hideRealButtons(parent)
            for _, c in parent:GetChildren() do
                if c == template then continue end
                if c.Name:sub(1,3) == "KV_" then continue end
                if c:IsA("UIListLayout") or c:IsA("UIPadding") or c:IsA("UIGridLayout") then continue end
                if c:IsA("GuiObject") then c.Visible = false end
            end
        end
        hideRealButtons(dropDown)
        local existingWrap = dropDown:FindFirstChild("KV_ScrollWrap")
        if existingWrap then hideRealButtons(existingWrap) end

        -- Inject one cloned-template button for every available skin
        local available = getAvailableSkins()
        for i, skin in ipairs(available) do
            local btn = template:Clone()
            btn.Name = "KV_" .. skin.name
            btn.Visible = true
            btn.LayoutOrder = i
            btn.Size = refSize  -- exactly match the game's real button dimensions

            local colors = SKIN_COLORS[skin.name] or { main = Color3.fromRGB(108,92,231), stroke = Color3.fromRGB(80,70,130) }
            btn.BackgroundColor3 = colors.main
            local btnStroke = btn:FindFirstChildOfClass("UIStroke")
            if btnStroke then btnStroke.Color = colors.stroke end

            local textLbl = btn:FindFirstChild("Text")
            if textLbl and textLbl:IsA("TextLabel") then
                textLbl.Text = skin.name
                local textStroke = textLbl:FindFirstChildOfClass("UIStroke")
                if textStroke then textStroke.Color = colors.stroke end
            end

            -- Hide any lock icons (we're treating every skin as unlocked here)
            for _, d in ipairs(btn:GetDescendants()) do
                if d.Name == "Locked" and (d:IsA("ImageLabel") or d:IsA("Frame")) then
                    d.Visible = false
                end
            end

            btn.Parent = dropDown

            -- Determine the actual clickable element
            local clickTarget
            if btn:IsA("ImageButton") or btn:IsA("TextButton") then
                clickTarget = btn
            else
                clickTarget = btn:FindFirstChildWhichIsA("ImageButton") or btn:FindFirstChildWhichIsA("TextButton")
                if not clickTarget then
                    local overlay = Instance.new("TextButton")
                    overlay.Name = "KV_Click"
                    overlay.Size = UDim2.new(1,0,1,0)
                    overlay.BackgroundTransparency = 1
                    overlay.Text = ""
                    overlay.ZIndex = 100
                    overlay.Parent = btn
                    clickTarget = overlay
                end
            end
            clickTarget.Activated:Connect(function()
                loadSkinModels(function(folder)
                    if not folder then return end
                    applySkin(skin.name, folder)
                    _selectedSkin = skin.name
                    skinToggleBtn.Text = "▼  " .. skin.name
                    local mainText = button:FindFirstChild("Text")
                    if mainText and mainText:IsA("TextLabel") then mainText.Text = skin.name end
                    button.BackgroundColor3 = colors.main
                    local mainStroke = button:FindFirstChildOfClass("UIStroke")
                    if mainStroke then mainStroke.Color = colors.stroke end
                end)
            end)
            table.insert(_injectedBtns, btn)
        end

        -- Make the dropdown scrollable so all our skins fit
        pcall(function()
            if not dropDown:FindFirstChild("KV_ScrollWrap") then
                local wrap = Instance.new("ScrollingFrame")
                wrap.Name = "KV_ScrollWrap"
                wrap.Size = UDim2.new(1, 0, 0, 250)
                wrap.BackgroundTransparency = 1
                wrap.BorderSizePixel = 0
                wrap.ScrollBarThickness = 6  -- thicker so it doesn't look skinny
                wrap.ScrollBarImageColor3 = Color3.fromRGB(80, 80, 80)  -- neutral grey, not purple
                wrap.AutomaticCanvasSize = Enum.AutomaticSize.Y
                wrap.CanvasSize = UDim2.new(0, 0, 0, 0)
                wrap.Parent = dropDown
                -- copy the dropDown's UIListLayout into wrap if it has one
                local existingLayout = dropDown:FindFirstChildOfClass("UIListLayout")
                if existingLayout then
                    local lc = existingLayout:Clone(); lc.Parent = wrap
                end
                -- move our KV buttons into wrap
                for _, b in ipairs(_injectedBtns) do
                    b.Parent = wrap
                end
            else
                local wrap = dropDown:FindFirstChild("KV_ScrollWrap")
                for _, b in ipairs(_injectedBtns) do b.Parent = wrap end
            end

            dropDown.AutomaticSize = Enum.AutomaticSize.None
            dropDown.Size = UDim2.new(dropDown.Size.X.Scale, dropDown.Size.X.Offset, 0, 260)

            local listLayout = scrollFrame:FindFirstChildOfClass("UIListLayout")
            if listLayout then
                scrollFrame.CanvasSize = UDim2.fromOffset(0, listLayout.AbsoluteContentSize.Y + 20)
            end
        end)
    end

    task.spawn(function()
        task.wait(3)
        injectIntoGameUI()
        local pg = LocalPlayer:WaitForChild("PlayerGui", 10)
        if pg then
            pg.DescendantAdded:Connect(function(desc)
                task.defer(function()
                    pcall(function()
                        if desc.Name == "Base Skin" and desc:IsA("Frame") then
                            task.wait(0.5)
                            injectIntoGameUI()
                        end
                    end)
                end)
            end)
            local settingsGui = pg:FindFirstChild("Settings")
            if settingsGui then
                local settingsFrame = settingsGui:FindFirstChild("Settings")
                if settingsFrame then
                    settingsFrame:GetPropertyChangedSignal("Visible"):Connect(function()
                        if settingsFrame.Visible then
                            task.wait(0.3)
                            injectIntoGameUI()
                        end
                    end)
                end
            end
        end
    end)

    -- pre-load skin models in background so applying is instant
    task.spawn(function()
        loadSkinModels(function() end)
    end)

    if _savedBaseSkin and _savedBaseSkin ~= "" and autoRestoreEnabled then
        task.spawn(function()
            local deadline = tick() + 35
            while #spawnedModels == 0 and tick() < deadline do
                task.wait(0.5)
            end
            task.wait(1)
            local skinName = _savedBaseSkin
            local available = getAvailableSkins()
            local valid = false
            for _, s in ipairs(available) do
                if s.name == skinName then valid = true; break end
            end
            if not valid then return end
            loadSkinModels(function(folder)
                if folder then
                    applySkin(skinName, folder)
                    skinToggleBtn.Text = "▼  " .. skinName
                    SetStatus("Auto-restored base: " .. skinName, Color3.fromRGB(50,200,100), 3)
                    -- sync to game settings once it loads
                    task.spawn(function()
                        for _ = 1, 20 do
                            task.wait(1)
                            pcall(function()
                                local pg = LocalPlayer:FindFirstChild("PlayerGui")
                                if not pg then return end
                                local sGui = pg:FindFirstChild("Settings")
                                if not sGui then return end
                                local sFrame = sGui:FindFirstChild("Settings")
                                if not sFrame then return end
                                local cont = sFrame:FindFirstChild("Content")
                                if not cont then return end
                                local scroll = cont:FindFirstChild("ScrollingFrame")
                                if not scroll then return end
                                local baseSkinRow = nil
                                for _, child in scroll:GetChildren() do
                                    if child:IsA("Frame") and child.Name == "Base Skin" then baseSkinRow = child; break end
                                end
                                if not baseSkinRow then return end
                                local btn = baseSkinRow:FindFirstChild("Button")
                                if not btn then return end
                                local colors = SKIN_COLORS[skinName]
                                if colors then
                                    btn.BackgroundColor3 = colors.main
                                    local s = btn:FindFirstChildOfClass("UIStroke")
                                    if s then s.Color = colors.stroke end
                                    local t = btn:FindFirstChild("Text")
                                    if t and t:IsA("TextLabel") then t.Text = skinName end
                                end
                            end)
                            -- check if it worked
                            local done = false
                            pcall(function()
                                local pg = LocalPlayer:FindFirstChild("PlayerGui")
                                local sGui = pg and pg:FindFirstChild("Settings")
                                local sFrame = sGui and sGui:FindFirstChild("Settings")
                                local cont = sFrame and sFrame:FindFirstChild("Content")
                                local scroll = cont and cont:FindFirstChild("ScrollingFrame")
                                if not scroll then return end
                                for _, child in scroll:GetChildren() do
                                    if child:IsA("Frame") and child.Name == "Base Skin" then
                                        local btn = child:FindFirstChild("Button")
                                        local t = btn and btn:FindFirstChild("Text")
                                        if t and t:IsA("TextLabel") and t.Text == skinName then done = true end
                                        break
                                    end
                                end
                            end)
                            if done then break end
                        end
                    end)
                end
            end)
        end)
    end
end

-- ── SPAWN ────────────────────────────────────────────────
-- SpawnOneAnimal: set upvalues then invoke spawn loop once

local _pendingSpawns = {}  -- queue of {name, mutation, traits} to spawn
local _slotOverride  = nil -- when non-nil, DoSpawn targets this exact podium key
local DoSpawn  -- forward declaration
local function SpawnOneAnimal(animalName, mutation, traitsArr)
    table.insert(_pendingSpawns, {name=animalName, mutation=mutation or "None", traits=traitsArr or {}})
    pcall(InjectToGameIndex, animalName, mutation or "None")
end

local function DrainPendingSpawns()
    if #_pendingSpawns == 0 then return end
    local copy = {}
    for _, v in ipairs(_pendingSpawns) do table.insert(copy, v) end
    _pendingSpawns = {}
    task.spawn(function()
        for _, pending in ipairs(copy) do
            local savedA = selectedAnimal
            local savedM = selectedMutation
            local savedT = selectedTraits
            local savedC = spawnCount
            selectedAnimal   = pending.name
            selectedMutation = pending.mutation
            selectedTraits   = {}
            for _, t in ipairs(pending.traits) do selectedTraits[t] = true end
            spawnCount = 1
            -- call the real spawn handler
            DoSpawn()
            task.wait(0.05)  -- let task.spawns inside DoSpawn capture upvalues
            selectedAnimal   = savedA
            selectedMutation = savedM
            selectedTraits   = savedT
            spawnCount       = savedC
            task.wait(0.1)
        end
        _pendingSpawns = {}
    end)
end

DoSpawn = function()
    if not selectedAnimal then
        SetStatus("⚠ Select an animal first!",Color3.fromRGB(255,120,50),2); return
    end
    -- validate once before loop
    local modelTemplate=RS.Models.Animals:FindFirstChild(selectedAnimal)
    if not modelTemplate then
        SetStatus("⚠ Model not found: "..selectedAnimal,Color3.fromRGB(255,80,80),3); return
    end
    local plot=GetPlayerPlot()
    if not plot then
        SetStatus("⚠ Could not find your plot!",Color3.fromRGB(255,80,80),3); return
    end
    local podiumSpawns=GetPodiumSpawns(plot)
    if #podiumSpawns==0 then
        SetStatus("⚠ No podium slots found!",Color3.fromRGB(255,80,80),3); return
    end
    for _spawnI = 1, spawnCount do
    plot=GetPlayerPlot()
    podiumSpawns=GetPodiumSpawns(plot or plot)

    -- find first available slot — skip slots with our fake models OR real server animals
    local slotIndex = nil
    local spawnPart = nil
    -- get server AnimalPodiums to skip real occupied slots
    local serverPods = {}
    pcall(function()
        local ch = GetSyncChannel()
        serverPods = ch and ch:Get("AnimalPodiums") or {}
    end)
    -- build sorted podium key list matching podiumSpawns order
    local sortedPodiumNames = {}
    if plot then
        local podiums2 = plot:FindFirstChild("AnimalPodiums")
        if podiums2 then
            for _, pod in podiums2:GetChildren() do
                local n = tonumber(pod.Name)
                if n then table.insert(sortedPodiumNames, n) end
            end
            table.sort(sortedPodiumNames)
        end
    end
    -- if a slot override is requested (e.g. restore from save), look only at
    -- that specific podium and skip the first-available scan.
    if _slotOverride then
        for i, sp in ipairs(podiumSpawns) do
            if sortedPodiumNames[i] == _slotOverride then
                local podiumKey = sortedPodiumNames[i]
                local serverAnimal = podiumKey and serverPods[podiumKey]
                local occupied = serverAnimal ~= nil and serverAnimal ~= "Empty"
                if not occupied then
                    for _, m in ipairs(spawnedModels) do
                        if m and m.Parent and (m:GetPivot().Position - sp.Position).Magnitude < 5 then
                            occupied = true; break
                        end
                    end
                end
                if not occupied then
                    slotIndex = podiumKey
                    spawnPart = sp
                end
                break
            end
        end
    end
    -- fall through to first-available if no override / override slot is taken
    if not slotIndex then
        for i, sp in ipairs(podiumSpawns) do
            local occupied = false
            -- skip if real server animal is here
            local podiumKey = sortedPodiumNames[i]
            if podiumKey then
                local serverAnimal = serverPods[podiumKey]
                if serverAnimal ~= nil and serverAnimal ~= "Empty" then
                    occupied = true
                end
            end
            -- skip if our fake animal is here
            if not occupied then
                for _, m in ipairs(spawnedModels) do
                    if m and m.Parent and (m:GetPivot().Position - sp.Position).Magnitude < 5 then
                        occupied = true; break
                    end
                end
            end
            if not occupied then
                slotIndex = sortedPodiumNames[i] or i  -- use actual podium name, not array index
                spawnPart = sp
                break
            end
        end
    end
    if not slotIndex then
        SetStatus("All podium slots are full!", Color3.fromRGB(255,120,50), 2)
        return
    end

    local model=modelTemplate:Clone()

    -- disable collision on all parts (keep VFX particles intact)
    for _,v in model:GetDescendants() do
        if v:IsA("BasePart") then
            v.CanCollide=false; v.CanQuery=false; v.CanTouch=false; v.Massless=true
        end
    end
    if model.PrimaryPart then model.PrimaryPart.Anchored=true end

    -- parent FIRST so MaterialVariant and WeldConstraints work correctly
    model.Parent=workspace
    model:SetAttribute("KVSpawned", true)
    -- snapshot mutation + traits for this specific model
    local snapshotTraits = {}  -- array of active trait names
    for t, on in pairs(selectedTraits) do
        if on then table.insert(snapshotTraits, t) end
    end
    modelSnapshots[model] = {mutation = selectedMutation, traits = snapshotTraits}
    pcall(InjectToGameIndex, selectedAnimal, selectedMutation)
    model:PivotTo(spawnPart:GetPivot())

    -- capture base extY BEFORE traits inflate the model
    local baseExtY = model:GetExtentsSize().Y

    -- apply mutation AFTER parenting (MaterialVariant requires workspace context)
    pcall(ApplyMutation, model, selectedAnimal, selectedMutation)

    -- apply traits using snapshot array
    if #snapshotTraits>0 then pcall(ApplyTraits, model, selectedAnimal, snapshotTraits) end

    -- idle animation — capture name now before upvalue changes
    local _animName = selectedAnimal
    task.spawn(function()
        task.wait()  -- one frame only, needed for Animator to become active
        pcall(function()
            local ac = model:FindFirstChildOfClass("AnimationController")
            local animator = ac and ac:FindFirstChildOfClass("Animator")
            local animFolder = RS.Animations.Animals:FindFirstChild(_animName)
            if animator and animFolder then
                local idle = animFolder:FindFirstChild("Idle")
                if idle then
                    local track = animator:LoadAnimation(idle)
                    track.Looped = true
                    track:Play()
                end
            end
        end)
    end)

    -- determine rarity (used for sell confirmation)
    local animalRarity = "Common"
    for _, group in ipairs(ANIMALS_BY_RARITY) do
        for _, name in ipairs(group.names) do
            if name == selectedAnimal then animalRarity = group.rarity; break end
        end
    end

    -- overhead: clone FOC children directly (no require), Motor6D + att.WorldPosition
    pcall(function()
        local rarityData = require(RS.Datas.Rarities)
        local mutData    = require(RS.Datas.Mutations)
        local Gradients  = require(RS.Packages.Gradients)

        local att = model:FindFirstChild("OVERHEAD_ATTACHMENT", true)
        if not att then
            -- use baseExtY captured before traits + OverheadYOffsetModifier from Datas.Animals
            local overheadMod = 1
            pcall(function()
                local aData = require(RS.Datas.Animals)[selectedAnimal]
                if aData and aData.OverheadYOffsetModifier then
                    overheadMod = aData.OverheadYOffsetModifier
                end
            end)
            att = Instance.new("Attachment")
            att.Name = "OVERHEAD_ATTACHMENT"
            att.CFrame = CFrame.new(0, baseExtY * 0.75 * overheadMod, 0)
            att.Parent = spawnPart
        end

        local focScript = RS.Controllers.FastOverheadController
        local part = focScript.FastOverheadTemplate:Clone()
        part.Size = Vector3.new(15, 5, 0.1)
        part.CFrame = CFrame.new(0, 10000, 0)
        part.Parent = workspace.Debris
        local motor = part:FindFirstChild("__foh_transform")
        if not motor then
            motor = Instance.new("Motor6D"); motor.Name = "__foh_transform"; motor.Parent = part
        end
        motor.Part0 = workspace.Terrain; motor.Part1 = part; part.Anchored = false

        local gui = focScript.AnimalOverhead:Clone()
        gui.Adornee = part
        gui.SizingMode = Enum.SurfaceGuiSizingMode.FixedSize
        gui.MaxDistance = 72  -- Standard.Distance * 0.9 = 80 * 0.9
        gui.Parent = part

        -- store ref for carry hide/show
        modelOverheads[model] = {part = part, gui = gui, att = att}

        -- populate labels
        local dn = gui:FindFirstChild("DisplayName")
        if dn then dn.Text = _displayNameFor(selectedAnimal, selectedTraits) end

        -- Rarity
        local animalRarity = "Secret"
        for _, group in ipairs(ANIMALS_BY_RARITY) do
            for _, name in ipairs(group.names) do
                if name == selectedAnimal then animalRarity = group.rarity; break end
            end
        end
        local rarLbl = gui:FindFirstChild("Rarity")
        if rarLbl then
            rarLbl.Text = animalRarity
            local rc = rarityData and rarityData[animalRarity]
            local rarColor = (rc and rc.Color) or RARITY_COLORS[animalRarity] or Color3.new(1,1,1)
            rarLbl.TextColor3 = rarColor
            rarLbl.Visible = true
            -- use game's exact Gradients.apply for rarities that have GradientPreset
            if rc and rc.GradientPreset then
                pcall(function()
                    local preset = rc.GradientPreset
                    rarLbl.TextColor3 = Color3.new(1,1,1)
                    local mainGrad = rarLbl:FindFirstChildOfClass("UIGradient") or Instance.new("UIGradient", rarLbl)
                    mainGrad.Rotation = 90
                    mainGrad.Transparency = NumberSequence.new(0)
                    local stroke = rarLbl:FindFirstChildOfClass("UIStroke") or Instance.new("UIStroke", rarLbl)
                    stroke.Color = Color3.new(0,0,0)
                    local strokeGrad = stroke:FindFirstChildOfClass("UIGradient") or Instance.new("UIGradient", stroke)
                    strokeGrad.Rotation = 90
                    strokeGrad.Transparency = NumberSequence.new(0)

                    -- Use the game's exact Gradients module - it's already running its PostSimulation loop
                    -- Just add a tag and let it handle animation
                    local ok = pcall(function()
                        local Gradients2 = require(RS.Packages.Gradients)
                        Gradients2.apply(rarLbl, preset)
                    end)
                    if not ok then
                        -- fallback: manual static colors
                        local STATIC = {
                            YellowRed = ColorSequence.new({ColorSequenceKeypoint.new(0,Color3.new(1,0,0)),ColorSequenceKeypoint.new(0.5,Color3.new(1,1,0)),ColorSequenceKeypoint.new(1,Color3.new(1,0,0))}),
                            GreenRed  = ColorSequence.new({ColorSequenceKeypoint.new(0,Color3.new(1,0,0)),ColorSequenceKeypoint.new(0.5,Color3.new(0,1,0)),ColorSequenceKeypoint.new(1,Color3.new(1,0,0))}),
                            Zebra     = ColorSequence.new({ColorSequenceKeypoint.new(0,Color3.new(1,1,1)),ColorSequenceKeypoint.new(0.24,Color3.new(1,1,1)),ColorSequenceKeypoint.new(0.26,Color3.new(0,0,0)),ColorSequenceKeypoint.new(0.49,Color3.new(0,0,0)),ColorSequenceKeypoint.new(0.51,Color3.new(1,1,1)),ColorSequenceKeypoint.new(0.74,Color3.new(1,1,1)),ColorSequenceKeypoint.new(0.76,Color3.new(0,0,0)),ColorSequenceKeypoint.new(1,Color3.new(0,0,0))}),
                        }
                        if STATIC[preset] then mainGrad.Color = STATIC[preset] end
                        -- animated fallbacks
                        local ColorUtils = pcall(require, RS.Packages.Gradients.ColorSequenceUtils) and require(RS.Packages.Gradients.ColorSequenceUtils)
                        if ColorUtils then
                            local BASE = {
                                OG      = ColorSequence.new({ColorSequenceKeypoint.new(0,Color3.new(1,1,0)),ColorSequenceKeypoint.new(0.5,Color3.new(0,0,0)),ColorSequenceKeypoint.new(1,Color3.new(1,1,0))}),
                                Rainbow = ColorSequence.new({ColorSequenceKeypoint.new(0,Color3.new(1,0,0)),ColorSequenceKeypoint.new(0.17,Color3.new(1,0.5,0)),ColorSequenceKeypoint.new(0.33,Color3.new(1,1,0)),ColorSequenceKeypoint.new(0.5,Color3.new(0,1,0)),ColorSequenceKeypoint.new(0.67,Color3.new(0,0,1)),ColorSequenceKeypoint.new(0.83,Color3.new(0.5,0,1)),ColorSequenceKeypoint.new(1,Color3.new(1,0,0))}),
                            }
                            local SPEED = {OG=1, Rainbow=0.5, Zebra=0.5}
                            if BASE[preset] or STATIC[preset] then
                                local base = BASE[preset] or STATIC[preset]
                                local offset = 0
                                local ac; ac = RunService.PostSimulation:Connect(function(dt)
                                    if not rarLbl or not rarLbl.Parent then ac:Disconnect(); return end
                                    offset = (offset + dt * (SPEED[preset] or 0.5)) % 1
                                    mainGrad.Color = ColorUtils.calculateColorSequence(base, offset)
                                end)
                            end
                        end
                    end
                end)
            end
        end

        -- Mutation — exact PlotClient logic
        local mut = gui:FindFirstChild("Mutation")
        if mut then
            if selectedMutation ~= "None" and mutData and mutData[selectedMutation] then
                local md = mutData[selectedMutation]
                if md.UseRichText then
                    mut.RichText = true
                    mut.Text = md.DisplayWithRichText or md.DisplayText or selectedMutation
                else
                    mut.Text = md.DisplayText or selectedMutation
                end
                if md.GradientPreset then
                    local ok2, err2 = pcall(function() Gradients.apply(mut, md.GradientPreset) end)
                    if not ok2 then warn("Gradient mutation error:", err2) end
                else
                    mut.TextColor3 = md.MainColor or Color3.new(1,1,1)
                end
                mut.Visible = true
            else
                mut.Visible = false
            end
        end

        -- Generation + Price from baked ANIMAL_DATA
        local function fmt(n)
            local function clean(s, suffix)
                return s:gsub("%.0+"..suffix, suffix):gsub("(%.%d-)0+"..suffix, "%1"..suffix)
            end
            if n >= 1e12 then return clean(string.format("%.1fT", n/1e12), "T")
            elseif n >= 1e9 then return clean(string.format("%.1fB", n/1e9), "B")
            elseif n >= 1e6 then return clean(string.format("%.1fM", n/1e6), "M")
            elseif n >= 1e3 then return clean(string.format("%.1fK", n/1e3), "K")
            else return tostring(math.floor(n)) end
        end

        local animalInfo = ANIMAL_DATA[selectedAnimal]
        local realGen = CalcGeneration(selectedAnimal, selectedMutation, selectedTraits)
        local gen = gui:FindFirstChild("Generation")
        if gen then
            if realGen > 0 then
                gen.Text = "$"..fmt(realGen).."/s"
                gen.TextColor3 = Color3.fromRGB(255, 247, 0)
                gen.Visible = true
            else
                gen.Visible = false
            end
        end

        local priceLbl = gui:FindFirstChild("Price")
        if priceLbl then
            if animalInfo and animalInfo.price and animalInfo.price > 0 then
                priceLbl.Text = "$"..fmt(animalInfo.price)
                priceLbl.TextColor3 = Color3.fromRGB(115, 255, 0)
                priceLbl.Visible = true
            else
                priceLbl.Visible = false
            end
        end

        -- Stolen always hidden
        local stolen = gui:FindFirstChild("Stolen")
        if stolen then stolen.Visible = false end

        -- Trait icons — baked TRAIT_ICONS first, fallback to RS.Datas.Traits for newer traits
        local traitsFrame = gui:FindFirstChild("Traits")
        local template = traitsFrame and traitsFrame:FindFirstChild("Template")
        if traitsFrame and template then
            -- Game's Traits frame is sized for ~4 icons and clips overflow.
            -- Disable clip + bump frame width so 7+ traits all stay visible.
            traitsFrame.ClipsDescendants = false
            local liveTraitData = nil
            pcall(function() liveTraitData = require(RS.Datas.Traits) end)
            local count = 0
            for trait, on in pairs(selectedTraits) do
                if on then  -- show every trait, no cap
                    local icon = TRAIT_ICONS[trait]
                        or (liveTraitData and liveTraitData[trait] and liveTraitData[trait].Icon)
                    if icon then
                        local img = template:Clone()
                        img.Image = icon
                        img.Visible = true
                        img.Parent = traitsFrame
                        count = count + 1
                    end
                end
            end
            traitsFrame.Visible = count > 0
        end



        local conn
        conn = RunService.Stepped:Connect(function()
            if not model or not model.Parent then
                pcall(function() part:Destroy() end); conn:Disconnect(); return
            end
            local camCF = workspace.CurrentCamera.CFrame
            -- Read the position directly from the MODEL's pivot every frame.
            -- This sidesteps the att.WorldPosition caching issue and means the
            -- overhead automatically follows ANY PivotTo call (swap/place/etc).
            local pivot = model:GetPivot()
            local headPos = pivot.Position + Vector3.new(0, baseExtY * 0.75, 0)
            local pos = headPos + camCF.UpVector * 2.5
            motor.Transform = CFrame.lookAlong(pos, -camCF.LookVector)
            local dist = (camCF.Position - headPos).Magnitude
            if dist < 40 then
                gui.CanvasSize = Vector2.new(340, 113)
            elseif dist < 72 then
                gui.CanvasSize = Vector2.new(220, 73)
            else
                gui.CanvasSize = Vector2.new(0, 0)
            end
        end)
        model.AncestryChanged:Connect(function()
            if not model:IsDescendantOf(workspace) then
                pcall(function() part:Destroy() end); conn:Disconnect()
            end
        end)
    end)



    -- cashpad — Motor6D part above Claim.Main
    pcall(function()
        -- mutation/trait multipliers from Datas decompile
        local MUTATION_MODIFIER = {
            Gold=0.25, Diamond=0.5, Bloodrot=1, Rainbow=9, Candy=3,
            Lava=5, Galaxy=6, YinYang=6.5, Radioactive=7.5, Cursed=8, Divine=9,
        }
        local TRAIT_MODIFIER = {
            Taco=2, Nyan=5, Galactic=3, Fireworks=5, Zombie=4, Claws=4,
            Glitched=4, Bubblegum=3, Fire=5, Wet=1.5, Snowy=2, Cometstruck=2.5,
            Explosive=3, Disco=4, ["10B"]=3, ["Shark Fin"]=3, ["Matteo Hat"]=3.5,
            Brazil=5, Sleepy=0, Lightning=5, UFO=2, Spider=3.5, Strawberry=8,
            Paint=5, Skeleton=3, Sombrero=4, Tie=3.75, ["Witch Hat"]=3,
            Indonesia=4, Meowl=7, ["John Pork"]=6.5, ["RIP Gravestone"]=3.5, ["Jackolantern Pet"]=4.5,
            ["Santa Hat"]=4, ["Reindeer Pet"]=5, Skibidi=6, ["26"]=5, Rose=5,
            Chocolate=4.5, Halo=5, Lucky=5, ["Orange Balloon"]=3, ["Green Balloon"]=3.5,
            ["Blue Balloon"]=4, ["Red Balloon"]=5, ["Pink Balloon"]=5.5,
            ["Rainbow Balloon"]=6.5, Granny=5.5, ["Bunny Ears"]=4.5,
            ["Orange Egg"]=3, ["Green Egg"]=4, ["Blue Egg"]=5, ["Pink Egg"]=6.5,
        }

        -- calculate total gen/s using Datas.Animals for accuracy
        local baseGen = 0
        pcall(function()
            local aData = require(RS.Datas.Animals)[selectedAnimal]
            if aData then baseGen = aData.Generation or 0 end
        end)
        if baseGen == 0 then
            baseGen = ANIMAL_DATA[selectedAnimal] and ANIMAL_DATA[selectedAnimal].gen or 0
        end
        local mutMod = MUTATION_MODIFIER[selectedMutation] or 0
        local traitMod = 0
        for trait, on in pairs(selectedTraits) do
            if on then traitMod = traitMod + (TRAIT_MODIFIER[trait] or 0) end
        end
        -- formula: gen * (1 + mutMod + traitMod)
        local genPerSec = baseGen * (1 + mutMod + traitMod)

        local plot = GetPlayerPlot()
        local podiums = plot and plot:FindFirstChild("AnimalPodiums")
        local podiumFolder = podiums and podiums:FindFirstChild(tostring(slotIndex))
        local claim = podiumFolder and podiumFolder:FindFirstChild("Claim")
        local claimMain = claim and claim:FindFirstChild("Main")
        local claimHitbox = claim and claim:FindFirstChild("Hitbox")
        if not claimMain then return end

        local function GetPlotMultiplier()
            local mult = 1
            pcall(function()
                local m = plot:FindFirstChild("Multiplier")
                local amt = m and m:FindFirstChild("Main") and m.Main:FindFirstChild("Amount")
                if amt then mult = tonumber(amt.Text:match("x?([%d%.]+)")) or 1 end
            end)
            return mult
        end

        local focScript = RS.Controllers.FastOverheadController
        local cashPart = focScript.FastOverheadTemplate:Clone()
        cashPart.Size = Vector3.new(5, 3, 0.1)
        cashPart.Transparency = 1
        cashPart.CanCollide = false; cashPart.CanQuery = false
        cashPart.CanTouch = false; cashPart.CastShadow = false
        cashPart.CFrame = CFrame.new(0, 10000, 0)
        cashPart.Parent = workspace.Debris
        local cashMotor = cashPart:FindFirstChild("__foh_transform")
        if not cashMotor then
            cashMotor = Instance.new("Motor6D")
            cashMotor.Name = "__foh_transform"
            cashMotor.Parent = cashPart
        end
        cashMotor.Part0 = workspace.Terrain
        cashMotor.Part1 = cashPart
        cashPart.Anchored = false

        local cashGui = focScript.CashPad:Clone()
        cashGui.Adornee = cashPart
        cashGui.SizingMode = Enum.SurfaceGuiSizingMode.FixedSize
        cashGui.MaxDistance = 72
        cashGui.Parent = cashPart

        local collectAmtLbl = cashGui:FindFirstChild("CollectAmount")
        local collectLbl = cashGui:FindFirstChild("Collect")
        local offlineLbl = cashGui:FindFirstChild("Offline")
        if collectLbl then collectLbl.Visible = true end

        local function fmt(n)
            local function clean(s, suffix)
                return s:gsub("%.0+"..suffix, suffix):gsub("(%.%d-)0+"..suffix, "%1"..suffix)
            end
            if n >= 1e12 then return clean(string.format("%.1fT", n/1e12), "T")
            elseif n >= 1e9 then return clean(string.format("%.1fB", n/1e9), "B")
            elseif n >= 1e6 then return clean(string.format("%.1fM", n/1e6), "M")
            elseif n >= 1e3 then return clean(string.format("%.1fK", n/1e3), "K")
            else return tostring(math.floor(n)) end
        end

        -- Apply pending offline cash (set by RestoreFromConfig right before this DoSpawn fires).
        -- We pick up _pendingOfflineCash here, store it in _modelOfflineCash so the
        -- amount survives swaps/places before collection.
        local offlineAmt = (_pendingOfflineCash and _pendingOfflineCash > 0) and _pendingOfflineCash or 0
        if offlineAmt > 0 then
            _modelOfflineCash[model] = offlineAmt
        end
        local accumulated = offlineAmt
        if offlineLbl then
            if offlineAmt > 0 then
                offlineLbl.RichText = true
                offlineLbl.Text = '(Offline Cash: <font color="#39FF14">$'..fmt(offlineAmt)..'</font>)'
                offlineLbl.Visible = true
            else
                offlineLbl.Visible = false
            end
        end
        if collectAmtLbl and offlineAmt > 0 then
            collectAmtLbl.Text = "$"..fmt(offlineAmt)
        end
        local lastTick = tick()
        local lastDisplay = tick()
        local wasOnPad = false

        local cashConn
        cashConn = RunService.Stepped:Connect(function()
            if not model or not model.Parent then
                pcall(function() cashPart:Destroy() end)
                cashConn:Disconnect(); return
            end
            local now = tick()
            local dt = now - lastTick
            lastTick = now

            -- accumulate with plot multiplier
            accumulated = accumulated + genPerSec * GetPlotMultiplier() * dt

            -- collect trigger: reset once on enter
            local hrp = LocalPlayer.Character and LocalPlayer.Character:FindFirstChild("HumanoidRootPart")
            if hrp and claimHitbox then
                local onPad = (hrp.Position - claimHitbox.Position).Magnitude < 5
                if onPad and not wasOnPad then
                    accumulated = 0
                    lastDisplay = now
                    if collectAmtLbl then collectAmtLbl.Text = "$0" end
                    -- clear offline-cash overlay once collected
                    if offlineLbl then offlineLbl.Visible = false end
                    _modelOfflineCash[model] = nil
                    -- play collect sound
                    pcall(function()
                        require(RS.Controllers.SoundController):PlaySound("Sounds.Sfx.Cashout")
                    end)
                end
                wasOnPad = onPad
            end

            -- update display once per second like real game
            if now - lastDisplay >= 1 then
                lastDisplay = now
                if collectAmtLbl then collectAmtLbl.Text = "$"..fmt(math.max(0, accumulated)) end
            end

            -- position above Claim.Main facing camera
            local camCF = workspace.CurrentCamera.CFrame
            local pos = claimMain.Position + Vector3.new(0, 2.41, 0)
            cashMotor.Transform = CFrame.lookAlong(pos, -camCF.LookVector)
            local dist = (camCF.Position - pos).Magnitude
            if dist < 40 then cashGui.CanvasSize = Vector2.new(200, 120)
            elseif dist < 72 then cashGui.CanvasSize = Vector2.new(100, 60)
            else cashGui.CanvasSize = Vector2.new(0, 0) end
        end)
        -- track cashpad so we can destroy it if animal moves to new slot
        modelCashpads[model] = {part = cashPart, conn = cashConn}

        model.AncestryChanged:Connect(function()
            if not model:IsDescendantOf(workspace) then
                modelCashpads[model] = nil
                pcall(function() cashPart:Destroy() end)
                cashConn:Disconnect()
            end
        end)
    end)

    -- update proximity prompts on the podium slot
    pcall(function()
        local plot = GetPlayerPlot()
        local podiums = plot and plot:FindFirstChild("AnimalPodiums")
        local podiumFolder = podiums and podiums:FindFirstChild(tostring(slotIndex))
        local base = podiumFolder and podiumFolder:FindFirstChild("Base")
        local spawn = base and base:FindFirstChild("Spawn")
        if not spawn then return end

        local promptAtt = spawn:FindFirstChild("PromptAttachment")
        if not promptAtt then return end

        local animalInfo = ANIMAL_DATA[selectedAnimal]
        local sellPrice = animalInfo and animalInfo.price or 0

        local function fmt(n)
            local function clean(s, suffix)
                return s:gsub("%.0+"..suffix, suffix):gsub("(%.%d-)0+"..suffix, "%1"..suffix)
            end
            if n >= 1e12 then return clean(string.format("%.1fT", n/1e12), "T")
            elseif n >= 1e9 then return clean(string.format("%.1fB", n/1e9), "B")
            elseif n >= 1e6 then return clean(string.format("%.1fM", n/1e6), "M")
            elseif n >= 1e3 then return clean(string.format("%.1fK", n/1e3), "K")
            else return tostring(math.floor(n)) end
        end

        -- disconnect any old prompt connections on this slot
        if slotPromptConns[slotIndex] then
            for _, c in ipairs(slotPromptConns[slotIndex]) do
                pcall(function() c:Disconnect() end)
            end
        end
        slotPromptConns[slotIndex] = {}
        modelPromptInfo[model] = {att=promptAtt, slot=slotIndex}

        for _, prompt in promptAtt:GetChildren() do
            if prompt:IsA("ProximityPrompt") then
                if prompt.KeyboardKeyCode == Enum.KeyCode.E then
                    prompt.ActionText = "Grab"
                    prompt.ObjectText = selectedAnimal
                    prompt:SetAttribute("State", "Grab")
                    prompt.Enabled = true
                    -- sibling visibility during/after holds is handled globally
                    -- by PromptButtonHoldBegan/Ended; per-slot PromptHidden toggling
                    -- caused partial holds to leave one prompt stuck disabled.
                    -- connect grab/place trigger
                    local grabPromptRef = prompt
                    local eConn; eConn = prompt.Triggered:Connect(function()
                        if carriedModel == model then
                            PlaceModelOnSlot(model, slotIndex, selectedAnimal)
                        elseif not carriedModel then
                            StartCarry(model, slotIndex, grabPromptRef)
                        end
                    end)
                    table.insert(slotPromptConns[slotIndex], eConn)
                elseif prompt.KeyboardKeyCode == Enum.KeyCode.F then
                    -- real game sells brainrots for half their listed price
                    prompt.ActionText = "Sell: $"..fmt(math.floor(sellPrice * 0.5))
                    prompt.ObjectText = ""
                    prompt:SetAttribute("State", "Sell")
                    prompt.Enabled = true
                    -- sibling visibility handled globally; see note above on E branch.
                    -- connect sell trigger
                    local capturedSlot = slotIndex
                    local capturedModel = model
                    local capturedName = selectedAnimal
                    local capturedRarity = animalRarity
                    local capturedAtt = promptAtt
                    local fConn; fConn = prompt.Triggered:Connect(function()
                        local function doSell()
                            -- destroy model and clean up (client-side only, no server remote)
                            pcall(function() capturedModel:Destroy() end)
                            modelSnapshots[capturedModel] = nil
                            modelOverheads[capturedModel] = nil
                            if slotPromptConns[capturedSlot] then
                                for _, c in ipairs(slotPromptConns[capturedSlot]) do
                                    pcall(function() c:Disconnect() end)
                                end
                                slotPromptConns[capturedSlot] = nil
                            end
                            for i, m in ipairs(spawnedModels) do
                                if m == capturedModel then table.remove(spawnedModels, i); break end
                            end
                            modelPromptInfo[capturedModel] = nil
                            ScheduleSave()
                            -- disable both prompts on this slot
                            if capturedAtt then
                                for _, p2 in capturedAtt:GetChildren() do
                                    if p2:IsA("ProximityPrompt") then
                                        p2.ActionText = "Interact"
                                        p2.ObjectText = ""
                                        p2:SetAttribute("State", "None")
                                        p2.Enabled = false
                                    end
                                end
                            end
                            UpdateCount()
                        end

                        -- OG/Secret/Mythic = rarity weight >= 5, show confirmation
                        local highRarity = capturedRarity == "OG" or capturedRarity == "Secret"
                            or capturedRarity == "Mythic" or capturedRarity == "Brainrot God"
                        if highRarity then
                            -- use game's ConfirmationController
                            local ok, cc = pcall(function()
                                return require(RS.Controllers.ConfirmationController)
                            end)
                            if ok and cc and not cc:IsInPrompt() then
                                task.spawn(function()
                                    local result = cc:Show("Do you want to sell "..capturedName.."?")
                                    if result then
                                        doSell()
                                    else
                                        -- restore E prompt after cancel
                                        pcall(function()
                                            if capturedAtt then
                                                for _, p2 in capturedAtt:GetChildren() do
                                                    if p2:IsA("ProximityPrompt") and p2.KeyboardKeyCode == Enum.KeyCode.E then
                                                        p2.Enabled = true
                                                    end
                                                end
                                            end
                                        end)
                                    end
                                end)
                            else
                                -- fallback: show our own simple dialog
                                local confirmGui = LocalPlayer.PlayerGui:FindFirstChild("Confirmation")
                                local template = confirmGui and confirmGui:FindFirstChild("Template")
                                if template then
                                    local clone = template:Clone()
                                    clone.Name = "Confirmation"
                                    clone.Visible = true
                                    local desc = clone:FindFirstChild("Content") and clone.Content:FindFirstChild("Description")
                                    if desc then desc.Text = "Do you want to sell "..capturedName.."?" end
                                    clone.Parent = confirmGui
                                    local done = false
                                    local function finish(yes)
                                        if done then return end; done = true
                                        clone:Destroy()
                                        if yes then
                                            doSell()
                                        else
                                            pcall(function()
                                                if capturedAtt then
                                                    for _, p2 in capturedAtt:GetChildren() do
                                                        if p2:IsA("ProximityPrompt") and p2.KeyboardKeyCode == Enum.KeyCode.E then
                                                            p2.Enabled = true
                                                        end
                                                    end
                                                end
                                            end)
                                        end
                                    end
                                    local yesBtn = clone:FindFirstChild("Yes")
                                    local noBtn = clone:FindFirstChild("No")
                                    local closeBtn = clone:FindFirstChild("Close")
                                    if yesBtn then yesBtn.MouseButton1Click:Connect(function() finish(true) end) end
                                    if noBtn then noBtn.MouseButton1Click:Connect(function() finish(false) end) end
                                    if closeBtn then closeBtn.MouseButton1Click:Connect(function() finish(false) end) end
                                else
                                    doSell() -- no template, just sell
                                end
                            end
                        else
                            doSell()
                        end
                    end)
                    table.insert(slotPromptConns[slotIndex], fConn)
                end
                prompt.Enabled = true
            end
        end
    end)

    -- track everything for clear
    table.insert(spawnedModels, model)
    UpdateCount()
    ScheduleSave()

    -- snap every spawned brainrot's looped animation to phase 0 so they all
    -- stay in lockstep after every new spawn (no more "this dragon is mid-flap
    -- while that dragon is starting").  Cheap — just a TimePosition write.
    task.defer(function()
        for _, mdl in ipairs(spawnedModels) do
            if mdl and mdl.Parent then _syncModelAnimations(mdl) end
        end
    end)
    -- if fake trade open, refresh Your side
    task.defer(function()
        local pg = LocalPlayer.PlayerGui
        local ft = pg:FindFirstChild("KV_FakeTrade")
        local inner2 = ft and ft:FindFirstChild("TradeLiveTrade")
        if not inner2 then return end
        local yourScroll2 = inner2.Your:FindFirstChild("ScrollingFrame")
        local tmpl2 = yourScroll2 and yourScroll2:FindFirstChild("Template")
        if not yourScroll2 or not tmpl2 then return end
        -- remove old KV slots and re-add all
        for _, v in yourScroll2:GetChildren() do
            if v:IsA("Frame") and v ~= tmpl2 and v.Name:sub(1,3) == "KV_" then v:Destroy() end
        end
        local idx2 = 1000
        for _, mdl2 in ipairs(spawnedModels) do
            if mdl2 and mdl2.Parent then
                local snap2 = modelSnapshots[mdl2] or {mutation="None",traits={}}
                local f2 = tmpl2:Clone()
                f2.Name = "KV_"..idx2; f2.Visible=true; f2.LayoutOrder=idx2
                slotToModel[f2.Name] = mdl2
                local sp2 = f2:FindFirstChild("Spacer")
                if sp2 then
                    pcall(function() sp2.Title.Text = mdl2.Name end)
                    pcall(function()
                        local sa2 = GetSharedAnimals()
                        if sa2 and sa2.AttachOnViewportWithOptimizations then
                            sa2:AttachOnViewportWithOptimizations(mdl2.Name, sp2.ViewportFrame, nil, snap2.mutation ~= "None" and snap2.mutation or nil)
                        end
                    end)
                    -- trait icons
                    pcall(function()
                        local tf = sp2:FindFirstChild("Traits")
                        local tt = tf and tf:FindFirstChild("Template")
                        if tf and tt then
                            for _, c in tf:GetChildren() do if c ~= tt then c:Destroy() end end
                            for i5, tn in ipairs(snap2.traits or {}) do
                                local ic = tt:Clone(); ic.Name=tn; ic.Visible=true; ic.LayoutOrder=i5
                                if TRAIT_ICONS[tn] then pcall(function() ic.Image=TRAIT_ICONS[tn] end) end
                                ic.Parent=tf
                            end
                        end
                    end)
                    -- click handler
                    sp2.Activated:Connect(function()
                        if inConfirmStage then return end
                        selectedSlots[f2.Name] = not selectedSlots[f2.Name]
                        local sel2 = selectedSlots[f2.Name]
                        sp2.BackgroundColor3 = sel2 and Color3.fromRGB(15,50,15) or Color3.fromRGB(35,45,50)
                        local sk2 = sp2:FindFirstChildOfClass("UIStroke")
                        if sk2 then sk2.Color = sel2 and Color3.fromRGB(0,255,0) or Color3.fromRGB(0,0,0) end
                        pcall(function() require(RS.Controllers.SoundController):PlaySound("Sounds.Sfx.Activated") end)
                        StartTimer()
                        pcall(function()
                            local selCount2 = 0
                            for _, v2 in pairs(selectedSlots) do if v2 then selCount2=selCount2+1 end end
                            local ybs = inner2.Your:FindFirstChild("BaseSlots")
                            local obs = inner2.Other:FindFirstChild("BaseSlots")
                            if ybs then local _,mx=ybs.Text:match("(%d+)/(%d+)"); if mx then ybs.Text=math.max(0,baseMine-selCount2).."/"..mx end end
                            if obs then local _,mx=obs.Text:match("(%d+)/(%d+)"); if mx then obs.Text=(otherBaseNum+selCount2).."/"..mx end end
                        end)
                    end)
                end
                f2.Parent = yourScroll2
                idx2 = idx2 + 1
            end
        end
        -- update Your BaseSlots
        pcall(function()
            local ybs = inner2.Your:FindFirstChild("BaseSlots")
            if ybs then local _,mx=ybs.Text:match("(%d+)/(%d+)"); if mx then
                baseMine = #spawnedModels; ybs.Text=baseMine.."/"..mx
            end end
        end)
    end)
    end -- end spawnCount loop
    SetStatus("✓ Spawned "..spawnCount.."x "..selectedAnimal,Color3.fromRGB(50,200,100),3)
end

spawnBtn.MouseButton1Click:Connect(function()
    if _multiSelectMode then
        local picks = {}
        for n, on in pairs(_multiSelected) do if on then table.insert(picks, n) end end
        if #picks == 0 then
            DoSpawn(); return
        end
        -- Spawn each picked animal once (with current mutation/traits/qty applied per pick)
        local savedAnimal = selectedAnimal
        for _, n in ipairs(picks) do
            selectedAnimal = n
            DoSpawn()
            task.wait(0.05)
        end
        selectedAnimal = savedAnimal
    else
        DoSpawn()
    end
end)
spawnBtn.MouseEnter:Connect(function() spawnBtn.BackgroundColor3=Color3.fromRGB(60,190,100) end)
spawnBtn.MouseLeave:Connect(function() spawnBtn.BackgroundColor3=BTNGRN end)

-- Add text outline (UIStroke) to all TextLabels in the GUI for cleaner look
task.defer(function()
    for _, lbl in sg:GetDescendants() do
        if lbl:IsA("TextLabel") or lbl:IsA("TextButton") then
            if not lbl:FindFirstChildOfClass("UIStroke") then
                local s = Instance.new("UIStroke", lbl)
                s.Color = Color3.fromRGB(0,0,0)
                s.Thickness = 1
                s.Transparency = 0.7
                s.ApplyStrokeMode = Enum.ApplyStrokeMode.Contextual
            end
        end
    end
end)

SetStatus("Ready — select an animal to spawn",SUBTEXT)

-- ── MISC PAGE CONTENT ────────────────────────────────────
do
    -- Section helper: creates a collapsible group that contains rows.
    -- Returns the content Frame that callers parent rows to.
    local function MakeMiscSection(title, layoutOrder, openByDefault)
        local section = New("Frame", {
            Size=UDim2.new(1,0,0,0),
            AutomaticSize=Enum.AutomaticSize.Y,
            BackgroundTransparency=1, BorderSizePixel=0,
            LayoutOrder=layoutOrder, Parent=miscPage,
        })
        local secLayout = Instance.new("UIListLayout", section)
        secLayout.SortOrder = Enum.SortOrder.LayoutOrder
        secLayout.Padding = UDim.new(0, 6)

        local hdrBtn = New("TextButton", {
            Size=UDim2.new(1,0,0,32),
            BackgroundColor3=Color3.fromRGB(28,28,38),
            BorderSizePixel=0, AutoButtonColor=false, Text="",
            LayoutOrder=1, Parent=section,
        })
        Corner(hdrBtn, 6); Stroke(hdrBtn, Color3.fromRGB(60,60,80), 1, 0.2)
        local arrowLbl = New("TextLabel", {
            Size=UDim2.new(1,-20,1,0), Position=UDim2.new(0,10,0,0),
            BackgroundTransparency=1, Text=(openByDefault and "▼  " or "▶  ") .. title,
            TextColor3=Color3.fromRGB(230,230,240), Font=Enum.Font.GothamBold,
            TextSize=11, TextXAlignment=Enum.TextXAlignment.Left, Parent=hdrBtn,
        })

        local content = New("Frame", {
            Size=UDim2.new(1,0,0,0),
            AutomaticSize=Enum.AutomaticSize.Y,
            BackgroundTransparency=1, BorderSizePixel=0, ClipsDescendants=true,
            Visible=openByDefault, LayoutOrder=2, Parent=section,
        })
        local cLayout = Instance.new("UIListLayout", content)
        cLayout.SortOrder = Enum.SortOrder.LayoutOrder
        cLayout.Padding = UDim.new(0, 6)

        local visible = openByDefault
        hdrBtn.Activated:Connect(function()
            visible = not visible
            content.Visible = visible
            arrowLbl.Text = (visible and "▼  " or "▶  ") .. title
        end)
        return content
    end

    local cfgContent  = MakeMiscSection("Configuration", 1, false)
    local keysContent = MakeMiscSection("Hotkeys",       2, false)
    local dataContent = MakeMiscSection("Spawned Brainrots", 3, false)

    local row = New("Frame", {
        Size=UDim2.new(1,0,0,42), BackgroundColor3=Color3.fromRGB(24,24,32),
        BorderSizePixel=0, LayoutOrder=1, Parent=cfgContent,
    })
    Corner(row, 6); Stroke(row, Color3.fromRGB(50,50,70), 1, 0.3)
    New("TextLabel", {
        Size=UDim2.new(0.7,-10,1,0), Position=UDim2.new(0,10,0,0),
        BackgroundTransparency=1,
        Text="Auto-Restore Spawns on Rejoin",
        TextColor3=Color3.fromRGB(220,220,230), Font=Enum.Font.Gotham,
        TextSize=12, TextXAlignment=Enum.TextXAlignment.Left, Parent=row,
    })
    local toggleBtn = New("TextButton", {
        Size=UDim2.new(0,70,0,26), Position=UDim2.new(1,-80,0.5,-13),
        BackgroundColor3=autoRestoreEnabled and ACCENT or Color3.fromRGB(60,60,80),
        BorderSizePixel=0, AutoButtonColor=false,
        Text=autoRestoreEnabled and "ON" or "OFF",
        TextColor3=Color3.fromRGB(255,255,255),
        Font=Enum.Font.GothamBold, TextSize=11, Parent=row,
    })
    Corner(toggleBtn, 5)
    toggleBtn.Activated:Connect(function()
        autoRestoreEnabled = not autoRestoreEnabled
        toggleBtn.Text = autoRestoreEnabled and "ON" or "OFF"
        toggleBtn.BackgroundColor3 = autoRestoreEnabled and ACCENT or Color3.fromRGB(60,60,80)
        SaveConfig()
    end)

    -- Auto-Save row: when on, every spawn/sell auto-writes to the save file.
    -- Turning it off pauses auto-writes but keeps the existing save intact;
    -- Save Now still works manually, and turning this back on resumes saves.
    local row2 = New("Frame", {
        Size=UDim2.new(1,0,0,42), BackgroundColor3=Color3.fromRGB(24,24,32),
        BorderSizePixel=0, LayoutOrder=2, Parent=cfgContent,
    })
    Corner(row2, 6); Stroke(row2, Color3.fromRGB(50,50,70), 1, 0.3)
    New("TextLabel", {
        Size=UDim2.new(0.7,-10,1,0), Position=UDim2.new(0,10,0,0),
        BackgroundTransparency=1,
        Text="Auto-Save Base Changes",
        TextColor3=Color3.fromRGB(220,220,230), Font=Enum.Font.Gotham,
        TextSize=12, TextXAlignment=Enum.TextXAlignment.Left, Parent=row2,
    })
    local saveToggleBtn = New("TextButton", {
        Size=UDim2.new(0,70,0,26), Position=UDim2.new(1,-80,0.5,-13),
        BackgroundColor3=autoSaveEnabled and ACCENT or Color3.fromRGB(60,60,80),
        BorderSizePixel=0, AutoButtonColor=false,
        Text=autoSaveEnabled and "ON" or "OFF",
        TextColor3=Color3.fromRGB(255,255,255),
        Font=Enum.Font.GothamBold, TextSize=11, Parent=row2,
    })
    Corner(saveToggleBtn, 5)
    saveToggleBtn.Activated:Connect(function()
        autoSaveEnabled = not autoSaveEnabled
        saveToggleBtn.Text = autoSaveEnabled and "ON" or "OFF"
        saveToggleBtn.BackgroundColor3 = autoSaveEnabled and ACCENT or Color3.fromRGB(60,60,80)
        -- SaveConfig itself bypasses the autoSave gate, so the toggle's own
        -- state is always persisted (the gate only governs ScheduleSave).
        SaveConfig()
    end)

    -- Community webhook row: opt-in. When on, real trade-received brainrots
    -- with gen >= 50M/s post to the shared Discord channel.
    local row3 = New("Frame", {
        Size=UDim2.new(1,0,0,42), BackgroundColor3=Color3.fromRGB(24,24,32),
        BorderSizePixel=0, LayoutOrder=3, Parent=cfgContent,
    })
    Corner(row3, 6); Stroke(row3, Color3.fromRGB(50,50,70), 1, 0.3)
    New("TextLabel", {
        Size=UDim2.new(0.7,-10,1,0), Position=UDim2.new(0,10,0,0),
        BackgroundTransparency=1,
        Text="Share Pulls to Community Feed",
        TextColor3=Color3.fromRGB(220,220,230), Font=Enum.Font.Gotham,
        TextSize=12, TextXAlignment=Enum.TextXAlignment.Left, Parent=row3,
    })
    local hookToggleBtn = New("TextButton", {
        Size=UDim2.new(0,70,0,26), Position=UDim2.new(1,-80,0.5,-13),
        BackgroundColor3=webhookEnabled and ACCENT or Color3.fromRGB(60,60,80),
        BorderSizePixel=0, AutoButtonColor=false,
        Text=webhookEnabled and "ON" or "OFF",
        TextColor3=Color3.fromRGB(255,255,255),
        Font=Enum.Font.GothamBold, TextSize=11, Parent=row3,
    })
    Corner(hookToggleBtn, 5)
    hookToggleBtn.Activated:Connect(function()
        webhookEnabled = not webhookEnabled
        hookToggleBtn.Text = webhookEnabled and "ON" or "OFF"
        hookToggleBtn.BackgroundColor3 = webhookEnabled and ACCENT or Color3.fromRGB(60,60,80)
        SaveConfig()
    end)

    -- Hide UI on Rejoin: when on, the menu starts hidden after a rejoin
    -- so the user has to press the toggle key to bring it up. Useful when
    -- joining around people who shouldn't see the menu pop up.
    local row3b = New("Frame", {
        Size=UDim2.new(1,0,0,42), BackgroundColor3=Color3.fromRGB(24,24,32),
        BorderSizePixel=0, LayoutOrder=4, Parent=cfgContent,
    })
    Corner(row3b, 6); Stroke(row3b, Color3.fromRGB(50,50,70), 1, 0.3)
    New("TextLabel", {
        Size=UDim2.new(0.7,-10,1,0), Position=UDim2.new(0,10,0,0),
        BackgroundTransparency=1,
        Text="Hide UI on Rejoin",
        TextColor3=Color3.fromRGB(220,220,230), Font=Enum.Font.Gotham,
        TextSize=12, TextXAlignment=Enum.TextXAlignment.Left, Parent=row3b,
    })
    local hideToggleBtn = New("TextButton", {
        Size=UDim2.new(0,70,0,26), Position=UDim2.new(1,-80,0.5,-13),
        BackgroundColor3=hideOnRejoinEnabled and ACCENT or Color3.fromRGB(60,60,80),
        BorderSizePixel=0, AutoButtonColor=false,
        Text=hideOnRejoinEnabled and "ON" or "OFF",
        TextColor3=Color3.fromRGB(255,255,255),
        Font=Enum.Font.GothamBold, TextSize=11, Parent=row3b,
    })
    Corner(hideToggleBtn, 5)
    hideToggleBtn.Activated:Connect(function()
        hideOnRejoinEnabled = not hideOnRejoinEnabled
        hideToggleBtn.Text = hideOnRejoinEnabled and "ON" or "OFF"
        hideToggleBtn.BackgroundColor3 = hideOnRejoinEnabled and ACCENT or Color3.fromRGB(60,60,80)
        local ok, err = pcall(SaveConfig)
        if ok then
            SetStatus("Hide on Rejoin: " .. (hideOnRejoinEnabled and "ON (saved)" or "OFF (saved)"),
                Color3.fromRGB(40,200,80), 2)
        else
            SetStatus("Save failed: " .. tostring(err), Color3.fromRGB(255,80,80), 4)
        end
    end)

    -- UI Toggle Key: click button -> listening; press key to capture;
    -- click off the button or press Enter to save; press Escape to cancel.
    -- Each key-row is wrapped in its own do/end so its locals (row, btn,
    -- listening flag, pending value, conn handles) get released afterward —
    -- otherwise the misc tab blows past Luau's 200-local register limit.
    do
    local row4 = New("Frame", {
        Size=UDim2.new(1,0,0,42), BackgroundColor3=Color3.fromRGB(24,24,32),
        BorderSizePixel=0, LayoutOrder=1, Parent=keysContent,
    })
    Corner(row4, 6); Stroke(row4, Color3.fromRGB(50,50,70), 1, 0.3)
    New("TextLabel", {
        Size=UDim2.new(0.6,-10,1,0), Position=UDim2.new(0,10,0,0),
        BackgroundTransparency=1,
        Text="UI Toggle Key",
        TextColor3=Color3.fromRGB(220,220,230), Font=Enum.Font.Gotham,
        TextSize=12, TextXAlignment=Enum.TextXAlignment.Left, Parent=row4,
    })
    local keyBtn = New("TextButton", {
        Size=UDim2.new(0,140,0,26), Position=UDim2.new(1,-150,0.5,-13),
        BackgroundColor3=Color3.fromRGB(60,60,80), BorderSizePixel=0,
        AutoButtonColor=false, Text=toggleKeyName,
        TextColor3=Color3.fromRGB(255,255,255),
        Font=Enum.Font.GothamBold, TextSize=11, Parent=row4,
    })
    Corner(keyBtn, 5)

    local listening   = false
    local pendingKey  = nil
    local listenConn  = nil

    local function refreshKeyBtn()
        if listening then
            keyBtn.Text = pendingKey
                and (pendingKey .. "  (click off to save)")
                or "Press a key..."
            keyBtn.BackgroundColor3 = ACCENT
        else
            keyBtn.Text = toggleKeyName
            keyBtn.BackgroundColor3 = Color3.fromRGB(60,60,80)
        end
    end

    local function stopListening(commit)
        if not listening then return end
        if commit and pendingKey then
            toggleKeyName = pendingKey
            SaveConfig()
        end
        listening  = false
        pendingKey = nil
        if listenConn then listenConn:Disconnect(); listenConn = nil end
        refreshKeyBtn()
    end

    local function startListening()
        if listening then return end
        listening  = true
        pendingKey = nil
        refreshKeyBtn()
        listenConn = UserInputService.InputBegan:Connect(function(input)
            if input.UserInputType == Enum.UserInputType.Keyboard then
                local kc = input.KeyCode
                if kc == Enum.KeyCode.Escape then
                    stopListening(false)
                elseif kc == Enum.KeyCode.Return or kc == Enum.KeyCode.KeypadEnter then
                    stopListening(true)
                else
                    pendingKey = kc.Name
                    refreshKeyBtn()
                end
            elseif input.UserInputType == Enum.UserInputType.MouseButton1
                or input.UserInputType == Enum.UserInputType.Touch then
                -- click off the button = commit; click on it = cancel
                local mp = UserInputService:GetMouseLocation()
                local bp, bs = keyBtn.AbsolutePosition, keyBtn.AbsoluteSize
                local inside = mp.X >= bp.X and mp.X <= bp.X+bs.X
                    and mp.Y >= bp.Y and mp.Y <= bp.Y+bs.Y
                if not inside then
                    stopListening(true)
                end
            end
        end)
    end

    keyBtn.Activated:Connect(function()
        if listening then
            stopListening(false)
        else
            startListening()
        end
    end)
    end -- toggleKey row scope

    -- Rejoin Key: same UX as the toggle-key row. Pressing the bound key
    -- teleports the player back into the same place (new server).
    do
    local row5 = New("Frame", {
        Size=UDim2.new(1,0,0,42), BackgroundColor3=Color3.fromRGB(24,24,32),
        BorderSizePixel=0, LayoutOrder=2, Parent=keysContent,
    })
    Corner(row5, 6); Stroke(row5, Color3.fromRGB(50,50,70), 1, 0.3)
    New("TextLabel", {
        Size=UDim2.new(0.6,-10,1,0), Position=UDim2.new(0,10,0,0),
        BackgroundTransparency=1,
        Text="Rejoin Key",
        TextColor3=Color3.fromRGB(220,220,230), Font=Enum.Font.Gotham,
        TextSize=12, TextXAlignment=Enum.TextXAlignment.Left, Parent=row5,
    })
    local rejoinBtn = New("TextButton", {
        Size=UDim2.new(0,140,0,26), Position=UDim2.new(1,-150,0.5,-13),
        BackgroundColor3=Color3.fromRGB(60,60,80), BorderSizePixel=0,
        AutoButtonColor=false,
        Text=(rejoinKeyName ~= "" and rejoinKeyName) or "Unbound",
        TextColor3=Color3.fromRGB(255,255,255),
        Font=Enum.Font.GothamBold, TextSize=11, Parent=row5,
    })
    Corner(rejoinBtn, 5)

    local rjListening  = false
    local rjPending    = nil
    local rjConn       = nil

    local function refreshRejoinBtn()
        if rjListening then
            rejoinBtn.Text = rjPending
                and (rjPending .. "  (click off to save)")
                or "Press a key... (Del = unbind)"
            rejoinBtn.BackgroundColor3 = ACCENT
        else
            rejoinBtn.Text = (rejoinKeyName ~= "" and rejoinKeyName) or "Unbound"
            rejoinBtn.BackgroundColor3 = Color3.fromRGB(60,60,80)
        end
    end

    local function rjStop(commit)
        if not rjListening then return end
        if commit and rjPending ~= nil then
            rejoinKeyName = rjPending  -- may be "" to unbind
            SaveConfig()
        end
        rjListening = false
        rjPending   = nil
        if rjConn then rjConn:Disconnect(); rjConn = nil end
        refreshRejoinBtn()
    end

    local function rjStart()
        if rjListening then return end
        rjListening = true
        rjPending   = nil
        refreshRejoinBtn()
        rjConn = UserInputService.InputBegan:Connect(function(input)
            if input.UserInputType == Enum.UserInputType.Keyboard then
                local kc = input.KeyCode
                if kc == Enum.KeyCode.Escape then
                    rjStop(false)
                elseif kc == Enum.KeyCode.Return or kc == Enum.KeyCode.KeypadEnter then
                    rjStop(true)
                elseif kc == Enum.KeyCode.Delete or kc == Enum.KeyCode.Backspace then
                    rjPending = ""  -- unbind
                    refreshRejoinBtn()
                else
                    rjPending = kc.Name
                    refreshRejoinBtn()
                end
            elseif input.UserInputType == Enum.UserInputType.MouseButton1
                or input.UserInputType == Enum.UserInputType.Touch then
                local mp = UserInputService:GetMouseLocation()
                local bp, bs = rejoinBtn.AbsolutePosition, rejoinBtn.AbsoluteSize
                local inside = mp.X >= bp.X and mp.X <= bp.X+bs.X
                    and mp.Y >= bp.Y and mp.Y <= bp.Y+bs.Y
                if not inside then rjStop(true) end
            end
        end)
    end

    rejoinBtn.Activated:Connect(function()
        if rjListening then rjStop(false) else rjStart() end
    end)
    end -- rejoinKey row scope

    -- ── DEBUG: Dupe Item Key ──────────────────────────────
    -- While the Trade Setup window is open, each press adds one more copy of
    -- the currently-selected animal/mutation to the "their side" list.
    -- Strictly visual — no networking.
    do
    local row6 = New("Frame", {
        Size=UDim2.new(1,0,0,42), BackgroundColor3=Color3.fromRGB(24,24,32),
        BorderSizePixel=0, LayoutOrder=3, Parent=keysContent,
    })
    Corner(row6, 6); Stroke(row6, Color3.fromRGB(50,50,70), 1, 0.3)
    New("TextLabel", {
        Size=UDim2.new(0.6,-10,1,0), Position=UDim2.new(0,10,0,0),
        BackgroundTransparency=1,
        Text="Dupe Item Key",
        TextColor3=Color3.fromRGB(220,220,230), Font=Enum.Font.Gotham,
        TextSize=12, TextXAlignment=Enum.TextXAlignment.Left, Parent=row6,
    })
    local dupeKeyBtn = New("TextButton", {
        Size=UDim2.new(0,140,0,26), Position=UDim2.new(1,-150,0.5,-13),
        BackgroundColor3=Color3.fromRGB(60,60,80), BorderSizePixel=0,
        AutoButtonColor=false,
        Text=(_debugDupeKeyName ~= "" and _debugDupeKeyName) or "Unbound",
        TextColor3=Color3.fromRGB(255,255,255),
        Font=Enum.Font.GothamBold, TextSize=11, Parent=row6,
    })
    Corner(dupeKeyBtn, 5)

    local dkListening, dkPending, dkConn = false, nil, nil
    local function refreshDupeBtn()
        if dkListening then
            dupeKeyBtn.Text = dkPending and (dkPending.."  (click off to save)") or "Press a key... (Del = unbind)"
            dupeKeyBtn.BackgroundColor3 = ACCENT
        else
            dupeKeyBtn.Text = (_debugDupeKeyName ~= "" and _debugDupeKeyName) or "Unbound"
            dupeKeyBtn.BackgroundColor3 = Color3.fromRGB(60,60,80)
        end
    end
    local function dkStop(commit)
        if not dkListening then return end
        if commit and dkPending ~= nil then _debugDupeKeyName = dkPending; SaveConfig() end
        dkListening = false; dkPending = nil
        if dkConn then dkConn:Disconnect(); dkConn = nil end
        refreshDupeBtn()
    end
    local function dkStart()
        if dkListening then return end
        dkListening = true; dkPending = nil; refreshDupeBtn()
        dkConn = UserInputService.InputBegan:Connect(function(input)
            if input.UserInputType == Enum.UserInputType.Keyboard then
                local kc = input.KeyCode
                if kc == Enum.KeyCode.Escape then dkStop(false)
                elseif kc == Enum.KeyCode.Return or kc == Enum.KeyCode.KeypadEnter then dkStop(true)
                elseif kc == Enum.KeyCode.Delete or kc == Enum.KeyCode.Backspace then dkPending = ""; refreshDupeBtn()
                else dkPending = kc.Name; refreshDupeBtn() end
            elseif input.UserInputType == Enum.UserInputType.MouseButton1
                or input.UserInputType == Enum.UserInputType.Touch then
                local mp = UserInputService:GetMouseLocation()
                local bp, bs = dupeKeyBtn.AbsolutePosition, dupeKeyBtn.AbsoluteSize
                local inside = mp.X>=bp.X and mp.X<=bp.X+bs.X and mp.Y>=bp.Y and mp.Y<=bp.Y+bs.Y
                if not inside then dkStop(true) end
            end
        end)
    end
    dupeKeyBtn.Activated:Connect(function() if dkListening then dkStop(false) else dkStart() end end)
    end -- dupeKey row scope

    -- ── DEBUG: Auto-Fill Trade Key ────────────────────────
    -- Press to open Trade Setup pre-filled with the username and offered items
    -- captured from the most recent real trade session.  Visual-only.
    do
    local row7 = New("Frame", {
        Size=UDim2.new(1,0,0,42), BackgroundColor3=Color3.fromRGB(24,24,32),
        BorderSizePixel=0, LayoutOrder=4, Parent=keysContent,
    })
    Corner(row7, 6); Stroke(row7, Color3.fromRGB(50,50,70), 1, 0.3)
    New("TextLabel", {
        Size=UDim2.new(0.6,-10,1,0), Position=UDim2.new(0,10,0,0),
        BackgroundTransparency=1,
        Text="Trade Last Player",
        TextColor3=Color3.fromRGB(220,220,230), Font=Enum.Font.Gotham,
        TextSize=12, TextXAlignment=Enum.TextXAlignment.Left, Parent=row7,
    })
    local afKeyBtn = New("TextButton", {
        Size=UDim2.new(0,140,0,26), Position=UDim2.new(1,-150,0.5,-13),
        BackgroundColor3=Color3.fromRGB(60,60,80), BorderSizePixel=0,
        AutoButtonColor=false,
        Text=(_debugAutoFillKeyName ~= "" and _debugAutoFillKeyName) or "Unbound",
        TextColor3=Color3.fromRGB(255,255,255),
        Font=Enum.Font.GothamBold, TextSize=11, Parent=row7,
    })
    Corner(afKeyBtn, 5)

    local afListening, afPending, afConn = false, nil, nil
    local function refreshAfBtn()
        if afListening then
            afKeyBtn.Text = afPending and (afPending.."  (click off to save)") or "Press a key... (Del = unbind)"
            afKeyBtn.BackgroundColor3 = ACCENT
        else
            afKeyBtn.Text = (_debugAutoFillKeyName ~= "" and _debugAutoFillKeyName) or "Unbound"
            afKeyBtn.BackgroundColor3 = Color3.fromRGB(60,60,80)
        end
    end
    local function afStop(commit)
        if not afListening then return end
        if commit and afPending ~= nil then _debugAutoFillKeyName = afPending; SaveConfig() end
        afListening = false; afPending = nil
        if afConn then afConn:Disconnect(); afConn = nil end
        refreshAfBtn()
    end
    local function afStart()
        if afListening then return end
        afListening = true; afPending = nil; refreshAfBtn()
        afConn = UserInputService.InputBegan:Connect(function(input)
            if input.UserInputType == Enum.UserInputType.Keyboard then
                local kc = input.KeyCode
                if kc == Enum.KeyCode.Escape then afStop(false)
                elseif kc == Enum.KeyCode.Return or kc == Enum.KeyCode.KeypadEnter then afStop(true)
                elseif kc == Enum.KeyCode.Delete or kc == Enum.KeyCode.Backspace then afPending = ""; refreshAfBtn()
                else afPending = kc.Name; refreshAfBtn() end
            elseif input.UserInputType == Enum.UserInputType.MouseButton1
                or input.UserInputType == Enum.UserInputType.Touch then
                local mp = UserInputService:GetMouseLocation()
                local bp, bs = afKeyBtn.AbsolutePosition, afKeyBtn.AbsoluteSize
                local inside = mp.X>=bp.X and mp.X<=bp.X+bs.X and mp.Y>=bp.Y and mp.Y<=bp.Y+bs.Y
                if not inside then afStop(true) end
            end
        end)
    end
    afKeyBtn.Activated:Connect(function() if afListening then afStop(false) else afStart() end end)
    end -- autoFillKey row scope

    -- ── Trade Notif Key ──────────────────────────────────
    do
    local row8 = New("Frame", {
        Size=UDim2.new(1,0,0,42), BackgroundColor3=Color3.fromRGB(24,24,32),
        BorderSizePixel=0, LayoutOrder=5, Parent=keysContent,
    })
    Corner(row8, 6); Stroke(row8, Color3.fromRGB(50,50,70), 1, 0.3)
    New("TextLabel", {
        Size=UDim2.new(0.6,-10,1,0), Position=UDim2.new(0,10,0,0),
        BackgroundTransparency=1, Text="Trade Notification",
        TextColor3=Color3.fromRGB(220,220,230), Font=Enum.Font.Gotham,
        TextSize=12, TextXAlignment=Enum.TextXAlignment.Left, Parent=row8,
    })
    local tnKeyBtn = New("TextButton", {
        Size=UDim2.new(0,140,0,26), Position=UDim2.new(1,-150,0.5,-13),
        BackgroundColor3=Color3.fromRGB(60,60,80), BorderSizePixel=0,
        AutoButtonColor=false,
        Text=(_debugTradeNotifKeyName ~= "" and _debugTradeNotifKeyName) or "Unbound",
        TextColor3=Color3.fromRGB(255,255,255),
        Font=Enum.Font.GothamBold, TextSize=11, Parent=row8,
    })
    Corner(tnKeyBtn, 5)
    local tnListening, tnPending, tnConn = false, nil, nil
    local function refreshTnBtn()
        if tnListening then
            tnKeyBtn.Text = tnPending and (tnPending.."  (click off to save)") or "Press a key... (Del = unbind)"
            tnKeyBtn.BackgroundColor3 = ACCENT
        else
            tnKeyBtn.Text = (_debugTradeNotifKeyName ~= "" and _debugTradeNotifKeyName) or "Unbound"
            tnKeyBtn.BackgroundColor3 = Color3.fromRGB(60,60,80)
        end
    end
    local function tnStop(commit)
        if not tnListening then return end
        if commit and tnPending ~= nil then _debugTradeNotifKeyName = tnPending; SaveConfig() end
        tnListening = false; tnPending = nil
        if tnConn then tnConn:Disconnect(); tnConn = nil end
        refreshTnBtn()
    end
    local function tnStart()
        if tnListening then return end
        tnListening = true; tnPending = nil; refreshTnBtn()
        tnConn = UserInputService.InputBegan:Connect(function(input)
            if input.UserInputType == Enum.UserInputType.Keyboard then
                local kc = input.KeyCode
                if kc == Enum.KeyCode.Escape then tnStop(false)
                elseif kc == Enum.KeyCode.Return or kc == Enum.KeyCode.KeypadEnter then tnStop(true)
                elseif kc == Enum.KeyCode.Delete or kc == Enum.KeyCode.Backspace then tnPending = ""; refreshTnBtn()
                else tnPending = kc.Name; refreshTnBtn() end
            elseif input.UserInputType == Enum.UserInputType.MouseButton1
                or input.UserInputType == Enum.UserInputType.Touch then
                local mp = UserInputService:GetMouseLocation()
                local bp, bs = tnKeyBtn.AbsolutePosition, tnKeyBtn.AbsoluteSize
                local inside = mp.X>=bp.X and mp.X<=bp.X+bs.X and mp.Y>=bp.Y and mp.Y<=bp.Y+bs.Y
                if not inside then tnStop(true) end
            end
        end)
    end
    tnKeyBtn.Activated:Connect(function() if tnListening then tnStop(false) else tnStart() end end)
    end -- tradeNotifKey row scope

    local statusRow = New("Frame", {
        Size=UDim2.new(1,0,0,28), BackgroundTransparency=1,
        LayoutOrder=1, Parent=dataContent,
    })
    local statusLbl2 = New("TextLabel", {
        Size=UDim2.new(1,-10,1,0), Position=UDim2.new(0,10,0,0),
        BackgroundTransparency=1, Text="",
        TextColor3=SUBTEXT, Font=Enum.Font.Gotham,
        TextSize=11, TextXAlignment=Enum.TextXAlignment.Left, Parent=statusRow,
    })
    local function RefreshStatus()
        local saved = (_loadedConfig and _loadedConfig.spawns) and #_loadedConfig.spawns or 0
        local live  = #spawnedModels
        statusLbl2.Text = ("Saved: %d   |   Live: %d"):format(saved, live)
    end
    RefreshStatus()

    local btnRow = New("Frame", {
        Size=UDim2.new(1,0,0,32), BackgroundTransparency=1,
        LayoutOrder=2, Parent=dataContent,
    })
    do
        local ul = Instance.new("UIListLayout", btnRow)
        ul.FillDirection = Enum.FillDirection.Horizontal
        ul.Padding = UDim.new(0, 8)
        ul.SortOrder = Enum.SortOrder.LayoutOrder
    end
    local clearBtn = New("TextButton", {
        Size=UDim2.new(1,0,1,0), BackgroundColor3=Color3.fromRGB(70,40,40),
        BorderSizePixel=0, AutoButtonColor=false, Text="Clear Spawned",
        TextColor3=Color3.fromRGB(255,255,255),
        Font=Enum.Font.GothamBold, TextSize=11, LayoutOrder=1, Parent=btnRow,
    })
    Corner(clearBtn, 5)

    local function RestoreFromConfig(cfg)
        if not cfg or type(cfg.spawns) ~= "table" then return 0 end
        local n = 0
        -- burst restore: fire DoSpawn for every saved item in the same frame,
        -- no per-item waits. saves/restores the shared spawn upvalues once
        -- around the whole batch instead of per iteration. the only async
        -- path inside DoSpawn captures _animName into a local before
        -- yielding, so this avoids the upvalue race the queued drain guarded.
        local savedA = selectedAnimal
        local savedM = selectedMutation
        local savedT = selectedTraits
        local savedC = spawnCount
        for _, e in ipairs(cfg.spawns) do
            if type(e) == "table" and type(e.name) == "string" then
                selectedAnimal   = e.name
                selectedMutation = e.mutation or "None"
                local traits = {}
                if type(e.traits) == "table" then
                    for _, t in ipairs(e.traits) do traits[t] = true end
                end
                selectedTraits = traits
                spawnCount     = 1
                _slotOverride  = type(e.slot) == "number" and e.slot or nil
                -- Compute offline cash for THIS spawn and stash it in a pending
                -- variable BEFORE DoSpawn — the cashpad creation reads it during
                -- spawn. (Setting _modelOfflineCash AFTER DoSpawn would be too late.)
                _pendingOfflineCash = 0
                if _offlineSeconds > 0 then
                    local realGen = CalcGeneration(e.name, e.mutation or "None", traits) or 0
                    _pendingOfflineCash = realGen * _offlineSeconds * 0.5
                end
                pcall(DoSpawn)
                _pendingOfflineCash = 0
                _slotOverride  = nil
                n = n + 1
            end
        end
        selectedAnimal   = savedA
        selectedMutation = savedM
        selectedTraits   = savedT
        spawnCount       = savedC
        return n
    end

    clearBtn.Activated:Connect(function()
        -- Instantly destroys every fake brainrot we've spawned this session,
        -- resets the proximity prompts on those podiums (Grab/Sell → disabled),
        -- and clears the saved-spawns list on disk so they don't auto-restore
        -- on rejoin.  All other settings (autoSave, webhook, hotkeys, window
        -- pos, etc.) are preserved.
        local destroyed = 0
        for _, mdl in ipairs(spawnedModels) do
            if mdl and mdl.Parent then
                pcall(function() mdl:Destroy() end)
                destroyed = destroyed + 1
            end
            modelSnapshots[mdl] = nil
            -- clean up overhead/cashpad parts attached to this model
            local oh = modelOverheads[mdl]
            if oh then
                pcall(function() if oh.part then oh.part:Destroy() end end)
                pcall(function() if oh.gui  then oh.gui:Destroy()  end end)
                modelOverheads[mdl] = nil
            end
            local cp = modelCashpads and modelCashpads[mdl]
            if cp then
                pcall(function() if cp.conn then cp.conn:Disconnect() end end)
                pcall(function() if cp.part then cp.part:Destroy() end end)
                modelCashpads[mdl] = nil
            end
        end

        -- Reset every podium prompt we wired up — same cleanup the
        -- single-sell handler uses (line ~1942).  Mirrors the in-game
        -- "no animal here" state so Grab/Sell labels disappear.
        local plot = GetPlayerPlot()
        local podiums = plot and plot:FindFirstChild("AnimalPodiums")
        for slotIdx, conns in pairs(slotPromptConns) do
            for _, c in ipairs(conns) do pcall(function() c:Disconnect() end) end
            slotPromptConns[slotIdx] = nil
            if podiums then
                pcall(function()
                    local podiumFolder = podiums:FindFirstChild(tostring(slotIdx))
                    local base   = podiumFolder and podiumFolder:FindFirstChild("Base")
                    local sp     = base and base:FindFirstChild("Spawn")
                    local att    = sp and sp:FindFirstChild("PromptAttachment")
                    if att then
                        for _, p in att:GetChildren() do
                            if p:IsA("ProximityPrompt") then
                                p.ActionText = "Interact"; p.ObjectText = ""
                                p:SetAttribute("State", "None"); p.Enabled = false
                            end
                        end
                    end
                end)
            end
        end

        -- in-place clear so any closures that captured spawnedModels keep their reference
        for i = #spawnedModels, 1, -1 do spawnedModels[i] = nil end
        UpdateCount()

        -- wipe saved spawns on disk so they don't come back after rejoin
        if _hasFileApi() then
            pcall(function()
                local data = {
                    version            = 1,
                    autoRestore        = autoRestoreEnabled,
                    autoSave           = autoSaveEnabled,
                    webhook            = webhookEnabled,
                    toggleKey          = toggleKeyName,
                    rejoinKey          = rejoinKeyName,
                    debugDupeKey       = _debugDupeKeyName,
                    debugAutoFillKey   = _debugAutoFillKeyName,
                    debugTradeNotifKey = _debugTradeNotifKeyName,
                    windowPos          = savedWindowPos,
                    spawns             = {},
                }
                writefile(CONFIG_FILE, _hs:JSONEncode(data))
            end)
        end
        _loadedConfig = {spawns={}, autoRestore=autoRestoreEnabled}
        RefreshStatus()
        SetStatus(("Cleared %d spawned"):format(destroyed), Color3.fromRGB(220,180,80), 2)
    end)
    -- expose a periodic refresh for the live counter
    task.spawn(function()
        while miscPage.Parent do
            task.wait(1)
            if miscPage.Visible then RefreshStatus() end
        end
    end)

    -- auto-restore on script start, if enabled and we loaded a config.
    -- wait until the plot AND its podium prompts have actually streamed in
    -- before spawning, otherwise the prompt-wiring branch in DoSpawn finds
    -- no PromptAttachment and silently bails — leaving models without
    -- working Grab/Sell prompts.
    if autoRestoreEnabled and _loadedConfig then
        task.defer(function()
            local function plotReady()
                local plot = GetPlayerPlot()
                if not plot then return false end
                local pods = plot:FindFirstChild("AnimalPodiums")
                if not pods then return false end
                for _, pod in pods:GetChildren() do
                    local base = pod:FindFirstChild("Base")
                    local sp   = base and base:FindFirstChild("Spawn")
                    local att  = sp and sp:FindFirstChild("PromptAttachment")
                    if att and #att:GetChildren() > 0 then return true end
                end
                return false
            end
            local deadline = tick() + 30  -- give up after 30s rather than spinning forever
            while not plotReady() and tick() < deadline do
                task.wait(0.25)
            end
            local n = RestoreFromConfig(_loadedConfig)
            if n > 0 then
                SetStatus("Auto-restored "..n.." spawn(s)",Color3.fromRGB(50,200,100),3)
            end
            RefreshStatus()
        end)
    end
end

-- ── TRADING PAGE CONTENT (defined here so all functions are in scope) ──
do
    -- ── FAKE TRADE SETUP UI ──────────────────────────────

    -- State
    local fakeTradeItems = {}  -- list of {name, mutation, traits} for other side
    local _activeFakeStartTimer = nil  -- reference to live StartTimer function
    local _lastFakeTradeTime = 0  -- cooldown between fake trades
    local _liveTheirItems = nil  -- reference to theirItems in active trade
    local fakeTradeSetupOpen = false
    local fakeTradeWin = nil
    -- Shared "Show on Hide" preference. Trade popout AND sign editor both
    -- read this so they hide/show together based on the user's setting.
    local ignoreHide = true

    -- ── Sign State + Editor Popout ──
    -- Persistent state for the user's sign content. Either a single fixed
    -- message OR a list of messages that cycle every cycleSec seconds.
    local _signState = {
        manual         = "",
        randomEnabled  = false,
        randomList     = {},  -- array of strings
        cycleSec       = 5,
    }
    local _signSg = nil
    local _signCycleConn = nil  -- live cycler when a fake trade is open

    -- Apply the current sign content to the active fake trade's YourSign center.
    -- Also kicks off / stops the cycler depending on randomEnabled.
    local function _applySignToTrade()
        if _signCycleConn then pcall(function() _signCycleConn:Disconnect() end); _signCycleConn = nil end
        local pg = LocalPlayer:FindFirstChild("PlayerGui")
        local trade = pg and pg:FindFirstChild("KV_FakeTrade")
        if not trade then return end
        local inner = trade:FindFirstChild("TradeLiveTrade")
        if not inner then return end

        -- Target BOTH YourSign AND OtherSign so the user's side and the
        -- partner's side both reflect the configured sign text.
        local function findCenterLabel(signFrame)
            if not signFrame then return nil end
            local target, biggestSize = nil, 0
            -- Looking for the LARGEST visible text label OR button that isn't
            -- the Username header / a reaction button. The big "Last Offer"-
            -- placeholder is the actual sign center; reactions are smaller.
            local SKIP_NAMES = {
                username=true, playerimage=true, headshot=true,
            }
            local REACTION_TEXTS = {
                ["add more"]=true, ["deal?"]=true, ["l trade"]=true,
                ["fair trade"]=true, ["last offer"]=true, ["no thanks"]=true,
                ["sign"]=true,
            }
            for _, d in ipairs(signFrame:GetDescendants()) do
                if d:IsA("TextLabel") or d:IsA("TextButton") then
                    local nm = (d.Name or ""):lower()
                    local txt = ((d.Text or ""):lower()):gsub("^%s+", ""):gsub("%s+$", "")
                    if not SKIP_NAMES[nm]
                       and not nm:find("playerimage")
                       and not nm:find("headshot")
                       and not REACTION_TEXTS[txt] then
                        if (d.TextSize or 0) > biggestSize then
                            biggestSize = d.TextSize
                            target = d
                        end
                    end
                end
            end
            return target
        end

        local yours = inner:FindFirstChild("YourSign")
        local theirs = inner:FindFirstChild("OtherSign")
        local yLbl = findCenterLabel(yours)
        local tLbl = findCenterLabel(theirs)
        if not yLbl and not tLbl then return end
        local function setBoth(text)
            if yLbl and yLbl.Parent then yLbl.Text = text end
            if tLbl and tLbl.Parent then tLbl.Text = text end
        end

        if _signState.randomEnabled and #_signState.randomList > 0 then
            local i = 1
            setBoth(_signState.randomList[i])
            local interval = math.max(0.5, _signState.cycleSec or 5)
            task.spawn(function()
                while trade.Parent do
                    task.wait(interval)
                    if not trade.Parent then break end
                    if not _signState.randomEnabled then break end
                    i = i + 1; if i > #_signState.randomList then i = 1 end
                    setBoth(_signState.randomList[i] or "")
                end
            end)
        else
            local txt = _signState.manual
            if txt and txt ~= "" then setBoth(txt) end
        end
    end

    function _openSignEditor()
        if _signSg and _signSg.Parent then _signSg:Destroy() end
        _signSg = New("ScreenGui", {
            Name = "KV_SignEditor", ResetOnSpawn = false, IgnoreGuiInset = true,
            ZIndexBehavior = Enum.ZIndexBehavior.Sibling, DisplayOrder = 6000,
            Parent = GetSafeParent(),
        })

        -- Mirror the trade popout's hide rule: when sg is hidden and ignoreHide
        -- is OFF, hide the editor too. When ignoreHide is ON, keep editor visible.
        local function syncSignSgEnabled()
            if _signSg and _signSg.Parent then
                _signSg.Enabled = ignoreHide or sg.Enabled
            end
        end
        syncSignSgEnabled()
        local sgEnabledConn = sg:GetPropertyChangedSignal("Enabled"):Connect(syncSignSgEnabled)
        _signSg.AncestryChanged:Connect(function()
            if not _signSg.Parent and sgEnabledConn then sgEnabledConn:Disconnect() end
        end)

        local W = 320
        local panel = New("Frame", {
            Size = UDim2.new(0, W, 0, 360),
            Position = UDim2.new(0.5, -W/2, 0.5, -180),
            BackgroundColor3 = Color3.fromRGB(30,28,42),
            BorderSizePixel = 0, Parent = _signSg,
        })
        Corner(panel, 8); Stroke(panel, Color3.fromRGB(50,45,80), 1, 0.2)
        MakeDraggable(panel)

        -- Header
        New("TextLabel", {
            Size = UDim2.new(1,-40,0,28), Position = UDim2.new(0,12,0,8),
            BackgroundTransparency = 1, Text = "Sign Editor",
            TextColor3 = Color3.fromRGB(230,230,240),
            Font = Enum.Font.GothamBold, TextSize = 14,
            TextXAlignment = Enum.TextXAlignment.Left, Parent = panel,
        })
        local closeBtn = New("TextButton", {
            Size = UDim2.new(0,24,0,24), Position = UDim2.new(1,-32,0,10),
            BackgroundColor3 = Color3.fromRGB(180,60,60), Text = "X",
            TextColor3 = Color3.fromRGB(255,255,255), Font = Enum.Font.GothamBold,
            TextSize = 12, AutoButtonColor = false, BorderSizePixel = 0, Parent = panel,
        })
        Corner(closeBtn, 4)
        closeBtn.Activated:Connect(function()
            if _signSg then pcall(function() _signSg:Destroy() end); _signSg = nil end
        end)

        -- Manual sign text input
        New("TextLabel", {
            Size = UDim2.new(1,-24,0,14), Position = UDim2.new(0,12,0,44),
            BackgroundTransparency = 1, Text = "MANUAL SIGN MESSAGE",
            TextColor3 = Color3.fromRGB(150,140,200),
            Font = Enum.Font.GothamBold, TextSize = 9,
            TextXAlignment = Enum.TextXAlignment.Left, Parent = panel,
        })
        local manualBox = New("TextBox", {
            Size = UDim2.new(1,-24,0,32), Position = UDim2.new(0,12,0,60),
            BackgroundColor3 = Color3.fromRGB(24,24,30),
            Text = _signState.manual, PlaceholderText = "What your sign should say...",
            PlaceholderColor3 = Color3.fromRGB(150,140,180),
            TextColor3 = Color3.fromRGB(230,230,240),
            Font = Enum.Font.Gotham, TextSize = 12,
            ClearTextOnFocus = false, BorderSizePixel = 0, Parent = panel,
        })
        Corner(manualBox, 5); Stroke(manualBox, Color3.fromRGB(50,45,80), 1, 0.2)
        do local p=Instance.new("UIPadding",manualBox); p.PaddingLeft=UDim.new(0,8) end

        -- Randomize toggle
        local randomRow = New("Frame", {
            Size = UDim2.new(1,-24,0,28), Position = UDim2.new(0,12,0,102),
            BackgroundTransparency = 1, BorderSizePixel = 0, Parent = panel,
        })
        New("TextLabel", {
            Size = UDim2.new(1,-80,1,0),
            BackgroundTransparency = 1, Text = "Cycle Random Messages",
            TextColor3 = Color3.fromRGB(220,220,230),
            Font = Enum.Font.Gotham, TextSize = 12,
            TextXAlignment = Enum.TextXAlignment.Left, Parent = randomRow,
        })
        local randToggle = New("TextButton", {
            Size = UDim2.new(0,70,0,24), Position = UDim2.new(1,-70,0.5,-12),
            BackgroundColor3 = _signState.randomEnabled and Color3.fromRGB(108,92,231) or Color3.fromRGB(60,60,80),
            BorderSizePixel = 0, AutoButtonColor = false,
            Text = _signState.randomEnabled and "ON" or "OFF",
            TextColor3 = Color3.fromRGB(255,255,255),
            Font = Enum.Font.GothamBold, TextSize = 11, Parent = randomRow,
        })
        Corner(randToggle, 5)
        randToggle.Activated:Connect(function()
            _signState.randomEnabled = not _signState.randomEnabled
            randToggle.Text = _signState.randomEnabled and "ON" or "OFF"
            randToggle.BackgroundColor3 = _signState.randomEnabled
                and Color3.fromRGB(108,92,231) or Color3.fromRGB(60,60,80)
        end)

        -- Cycle interval input
        New("TextLabel", {
            Size = UDim2.new(0,140,0,20), Position = UDim2.new(0,12,0,138),
            BackgroundTransparency = 1, Text = "Cycle every (sec):",
            TextColor3 = Color3.fromRGB(220,220,230),
            Font = Enum.Font.Gotham, TextSize = 11,
            TextXAlignment = Enum.TextXAlignment.Left, Parent = panel,
        })
        local cycleBox = New("TextBox", {
            Size = UDim2.new(0,60,0,24), Position = UDim2.new(0,160,0,136),
            BackgroundColor3 = Color3.fromRGB(24,24,30),
            Text = tostring(_signState.cycleSec or 5),
            TextColor3 = Color3.fromRGB(230,230,240),
            Font = Enum.Font.Gotham, TextSize = 12,
            ClearTextOnFocus = false, BorderSizePixel = 0, Parent = panel,
        })
        Corner(cycleBox, 5); Stroke(cycleBox, Color3.fromRGB(50,45,80), 1, 0.2)

        -- Messages list (one per line)
        New("TextLabel", {
            Size = UDim2.new(1,-24,0,14), Position = UDim2.new(0,12,0,170),
            BackgroundTransparency = 1, Text = "RANDOM MESSAGE POOL (one per line)",
            TextColor3 = Color3.fromRGB(150,140,200),
            Font = Enum.Font.GothamBold, TextSize = 9,
            TextXAlignment = Enum.TextXAlignment.Left, Parent = panel,
        })
        local listBox = New("TextBox", {
            Size = UDim2.new(1,-24,0,110), Position = UDim2.new(0,12,0,186),
            BackgroundColor3 = Color3.fromRGB(24,24,30),
            Text = table.concat(_signState.randomList, "\n"),
            PlaceholderText = "yo\nDeal?\nL Trade\nAdd more please",
            PlaceholderColor3 = Color3.fromRGB(150,140,180),
            TextColor3 = Color3.fromRGB(230,230,240),
            Font = Enum.Font.Gotham, TextSize = 12,
            MultiLine = true, ClearTextOnFocus = false,
            TextXAlignment = Enum.TextXAlignment.Left,
            TextYAlignment = Enum.TextYAlignment.Top,
            BorderSizePixel = 0, Parent = panel,
        })
        Corner(listBox, 5); Stroke(listBox, Color3.fromRGB(50,45,80), 1, 0.2)
        do local p=Instance.new("UIPadding",listBox); p.PaddingLeft=UDim.new(0,8); p.PaddingTop=UDim.new(0,4) end

        -- Save & Apply button
        local saveBtn = New("TextButton", {
            Size = UDim2.new(1,-24,0,32), Position = UDim2.new(0,12,1,-44),
            BackgroundColor3 = Color3.fromRGB(40,160,70),
            Text = "Save & Apply",
            TextColor3 = Color3.fromRGB(255,255,255),
            Font = Enum.Font.GothamBold, TextSize = 12,
            AutoButtonColor = false, BorderSizePixel = 0, Parent = panel,
        })
        Corner(saveBtn, 6)
        saveBtn.MouseEnter:Connect(function() saveBtn.BackgroundColor3 = Color3.fromRGB(60,180,90) end)
        saveBtn.MouseLeave:Connect(function() saveBtn.BackgroundColor3 = Color3.fromRGB(40,160,70) end)
        saveBtn.Activated:Connect(function()
            _signState.manual = manualBox.Text or ""
            _signState.cycleSec = tonumber(cycleBox.Text) or 5
            -- Parse list — split on newlines, drop empties
            _signState.randomList = {}
            for line in (listBox.Text or ""):gmatch("[^\r\n]+") do
                local trimmed = line:gsub("^%s+", ""):gsub("%s+$", "")
                if trimmed ~= "" then table.insert(_signState.randomList, trimmed) end
            end
            _applySignToTrade()
            SetStatus("Sign saved", Color3.fromRGB(40,200,80), 2)
        end)
    end

    -- All spawnable animal names for dropdown
    local FT_ANIMALS = {}
    for _, group in ipairs(ANIMALS_BY_RARITY) do
        for _, name in ipairs(group.names) do
            table.insert(FT_ANIMALS, name)
        end
    end
    local FT_MUTATIONS = {"None","Gold","Diamond","Bloodrot","Rainbow","Candy","Lava","Galaxy","YinYang","Radioactive","Cursed","Divine","Cyber"}
    -- Trait list for fake-trade setup. "None" means no extra traits.
    -- Mirrors the spawner's TRAITS table so the picker stays in sync.
    local FT_TRAITS = {"None"}
    for _, t in ipairs(TRAITS) do table.insert(FT_TRAITS, t) end

    local lastFakeTradePos = UDim2.new(0.5, 0, 0.5, 0)  -- remember position between opens

    LaunchFakeTrade = function(username, theirItems)
        _liveTheirItems = theirItems  -- expose to AddItem
        _kvForceAcceptDispatcher = nil  -- new trade gets a fresh dispatcher when rbCloneF binds
        local animalsData = {}
        local mutationsData = {}
        local traitsData = {}
        pcall(function() animalsData = require(RS.Datas.Animals) end)
        pcall(function() mutationsData = require(RS.Datas.Mutations) end)
        pcall(function() traitsData = require(RS.Datas.Traits) end)

        local function calcGen(animalName, mutation, traits)
            local ok, result = pcall(function()
                local aData = animalsData[animalName]
                if not aData then return 0 end
                local base = aData.Generation or 0
                -- exact formula from SharedAnimals: multiplier starts at 1, everything adds to it
                local multiplier = 1
                if mutation and mutation ~= "None" then
                    local md = mutationsData[mutation]
                    if md and md.Modifier then multiplier = multiplier + md.Modifier end
                end
                for _, tn in ipairs(traits or {}) do
                    local td = traitsData[tn]
                    if td and td.MultiplierModifier then
                        multiplier = multiplier + td.MultiplierModifier
                    end
                end
                return base * multiplier
            end)
            if ok then return result or 0 else return 0 end
        end

        local pg = LocalPlayer.PlayerGui

        -- Remove old fake trade if exists
        local old = pg:FindFirstChild("KV_FakeTrade")
        if old then old:Destroy() end

        -- Clone the real GUI (exists but disabled)
        local real = pg:FindFirstChild("TradeLiveTrade")
        if not real then SetStatus("TradeLiveTrade not in PlayerGui!", Color3.fromRGB(255,80,80), 3); return end

        -- never enable the real GUI - only use clone
        -- real stays Enabled=false so TradeController sees nothing
        local clone = real:Clone()
        clone.Name = "KV_FakeTrade"
        clone.ResetOnSpawn = false
        clone.Enabled = true
        clone.Parent = pg

        -- ── Inject reaction button labels right at clone time ──
        -- Walk every descendant and rename the placeholder text directly. No
        -- watchdog, no race conditions — by the time the user sees the trade,
        -- everything is already labeled.
        do
            -- Map of TARGET_LABEL → list of texts to recognize
            local LABELS = {"Add More", "Deal?", "L Trade", "Fair Trade", "Sign", "No Thanks"}
            local SIGN_TEXTS = {"Add More!", "Deal?", "L Trade", "Fair Trade!", "Sign", "No Thanks!"}

            -- Group all "Add More"-text buttons by their parent so we can sort by
            -- AbsolutePosition and rename in order (same approach as before, but
            -- run right at clone time, before the user ever sees the UI).
            local groupsByParent = {}
            local function noteBtn(btn)
                if not btn then return end
                local p = btn.Parent
                groupsByParent[p] = groupsByParent[p] or {}
                for _, x in ipairs(groupsByParent[p]) do if x == btn then return end end
                table.insert(groupsByParent[p], btn)
            end
            for _, d in ipairs(clone:GetDescendants()) do
                if d:IsA("TextLabel") and d.Text and d.Text:lower():find("add more") then
                    local btn = d.Parent
                    while btn and not (btn:IsA("TextButton") or btn:IsA("ImageButton")) do
                        btn = btn.Parent
                        if btn == clone then btn = nil; break end
                    end
                    noteBtn(btn)
                elseif d:IsA("TextButton") and d.Text and d.Text:lower():find("add more") then
                    noteBtn(d)
                end
            end

            for _, btns in pairs(groupsByParent) do
                if #btns >= 2 then
                    table.sort(btns, function(a, b)
                        local pa, pb = a.AbsolutePosition, b.AbsolutePosition
                        if math.abs(pa.Y - pb.Y) > 5 then return pa.Y < pb.Y end
                        return pa.X < pb.X
                    end)
                    for i, btn in ipairs(btns) do
                        local label = LABELS[i] or ("Reaction "..i)
                        local sign  = SIGN_TEXTS[i] or label
                        -- Set both the button itself and any descendant text labels
                        if btn:IsA("TextButton") and btn.Text and btn.Text ~= "" then
                            btn.Text = label
                        end
                        for _, c in ipairs(btn:GetDescendants()) do
                            if c:IsA("TextLabel") then c.Text = label end
                        end
                        -- Wire click sound + YourSign text update
                        btn:SetAttribute("KVSignText", sign)
                        if not btn:GetAttribute("KVReactionWired") then
                            btn:SetAttribute("KVReactionWired", true)
                            btn.AutoButtonColor = false
                            local capturedSign = sign
                            local capturedBtn  = btn
                            local capturedLbl  = label
                            btn.Activated:Connect(function()
                                pcall(function()
                                    require(RS.Controllers.SoundController):PlaySound("Sounds.Sfx.Activated")
                                end)
                                pcall(function()
                                    local trade = LocalPlayer.PlayerGui:FindFirstChild("KV_FakeTrade")
                                    local innerT = trade and trade:FindFirstChild("TradeLiveTrade")
                                    local mySign = innerT and innerT:FindFirstChild("YourSign")
                                    if not mySign then return end
                                    -- pick the biggest non-username text label
                                    local target, biggest = nil, 0
                                    for _, d in ipairs(mySign:GetDescendants()) do
                                        if d:IsA("TextLabel") and d.Name:lower() ~= "username"
                                           and (d.TextSize or 0) > biggest then
                                            biggest = d.TextSize; target = d
                                        end
                                    end
                                    if target then target.Text = capturedSign end
                                end)
                            end)
                            -- Lock the label so game scripts can't overwrite it
                            if btn:IsA("TextButton") then
                                btn:GetPropertyChangedSignal("Text"):Connect(function()
                                    if capturedBtn.Text ~= capturedLbl then capturedBtn.Text = capturedLbl end
                                end)
                            end
                            for _, c in ipairs(btn:GetDescendants()) do
                                if c:IsA("TextLabel") then
                                    local cap = c
                                    c:GetPropertyChangedSignal("Text"):Connect(function()
                                        if cap.Text ~= capturedLbl then cap.Text = capturedLbl end
                                    end)
                                end
                            end
                        end
                    end
                end
            end

            -- Also: the big center "Last Offer" button — relabel to "Sign" so it
            -- matches the new compact set, and turn it into a manual Sign trigger.
            for _, d in ipairs(clone:GetDescendants()) do
                if (d:IsA("TextLabel") or d:IsA("TextButton")) and d.Text and d.Text:lower():find("last offer") then
                    d.Text = "Sign"
                end
            end
        end


        local inner = clone:FindFirstChild("TradeLiveTrade")
        if not inner then clone:Destroy(); SetStatus("Inner frame missing!", Color3.fromRGB(255,80,80), 3); return end
        inner.Visible = true
        inner.AnchorPoint = Vector2.new(0.5, 0.5)
        -- start offscreen above, tween down like real trade (TopQuint style)
        local targetPos = UDim2.new(0.5, 0, 0.5, 0)
        local targetSize = inner.Size
        inner.Position = targetPos + UDim2.fromScale(0, -2)
        inner.Size = targetSize + UDim2.fromScale(0, 0)
        clone.DisplayOrder = 1500
        -- tween in: position slides down, 0.5s Quint
        local TS = game:GetService("TweenService")
        local tweenIn = TS:Create(inner, TweenInfo.new(0.5, Enum.EasingStyle.Quint, Enum.EasingDirection.Out), {
            Position = targetPos,
            Size = targetSize,
        })
        tweenIn:Play()
        -- blur + fov like real trade
        pcall(function()
            local RS2 = game:GetService("ReplicatedStorage")
            local cam = require(RS2.Controllers.CameraController)
            cam:Blur(12, 0.5)
            cam:Fov(60, 0.5)
        end)

        -- reset all ready/confirmed frames to hidden
        pcall(function()
            local yrf = inner.Your:FindFirstChild("Ready")
            if yrf then
                yrf.Visible = false
                local lbl = yrf:FindFirstChild("Label")
                if lbl then lbl.Text = "Ready!" end
            end
            local orf = inner.Other:FindFirstChild("Ready")
            if orf then
                orf.Visible = false
                local lbl2 = orf:FindFirstChild("Label")
                if lbl2 then lbl2.Text = "Ready!" end
            end
        end)

        -- Hide side HUD (shop/rebirth/index/duels buttons) like real trade does
        local hudGui = nil
        pcall(function()
            hudGui = LocalPlayer.PlayerGui:FindFirstChild("LeftCenter")
            if hudGui then hudGui.Enabled = false end
        end)

        -- CRITICAL: kill all real game script connections on the clone
        -- The real TradeController has Activated connections on ReadyButton
        -- that fire Ready/Accept remotes to server - replace with clean copy
        pcall(function()
            local rb = inner.Other:FindFirstChild("ReadyButton")
            if rb then
                local clean = rb:Clone()
                rb:Destroy()
                clean.Parent = inner.Other
            end
        end)
        -- Also kill Cancel button's real connection
        pcall(function()
            local cb = inner.Other:FindFirstChild("Cancel")
            if cb then
                local clean = cb:Clone()
                cb:Destroy()
                clean.Parent = inner.Other
            end
        end)
        -- Kill Close button's real connection
        pcall(function()
            local hdr = inner:FindFirstChild("Header")
            local closeBtn = hdr and hdr:FindFirstChild("Close")
            if closeBtn then
                local clean = closeBtn:Clone()
                closeBtn:Destroy()
                clean.Parent = hdr
            end
        end)

        -- hide proximity prompts - use Heartbeat to enforce since game re-enables them
        local hiddenPrompts = {}
        pcall(function()
            local plot = GetPlayerPlot()
            if not plot then return end
            for _, p in plot:GetDescendants() do
                if p:IsA("ProximityPrompt") then
                    table.insert(hiddenPrompts, {p=p, dist=p.MaxActivationDistance})
                    p.MaxActivationDistance = 0
                end
            end
        end)
        -- restore prompts on close (no heartbeat needed - set once)
        clone.AncestryChanged:Connect(function()
            if not clone.Parent then
                _activeFakeStartTimer = nil
                _liveTheirItems = nil
                pcall(RestoreAll)
                for _, entry in ipairs(hiddenPrompts) do
                    pcall(function() entry.p.MaxActivationDistance = entry.dist end)
                end
            end
        end)

        task.spawn(function()
            -- Your side
            pcall(function()
                inner.Your.Username.Text = "Your Offer"
                inner.Your.PlayerImage.Headshot.Image = ("rbxthumb://type=AvatarHeadShot&id=%d&w=100&h=100"):format(LocalPlayer.UserId)
            end)
            -- Your sign
            pcall(function()
                inner.YourSign.PlayerImage.Headshot.Image = ("rbxthumb://type=AvatarHeadShot&id=%d&w=100&h=100"):format(LocalPlayer.UserId)
                inner.YourSign.Username.Text = "@"..LocalPlayer.Name
            end)

            -- Other side username
            pcall(function() inner.Other.Username.Text = "@"..username.."'s Offer" end)

            -- Other headshot via userId lookup
            local ok, userId = pcall(function()
                return game:GetService("Players"):GetUserIdFromNameAsync(username)
            end)
            if ok and userId then
                pcall(function()
                    inner.Other.PlayerImage.Headshot.Image = ("rbxthumb://type=AvatarHeadShot&id=%d&w=100&h=100"):format(userId)
                end)
                pcall(function()
                    inner.OtherSign.PlayerImage.Headshot.Image = ("rbxthumb://type=AvatarHeadShot&id=%d&w=100&h=100"):format(userId)
                    inner.OtherSign.Username.Text = "@"..username
                end)
            end

            -- Slot counts - use actual rebirth data
            local realAnimalCountInit = 0
            local yourMax = 10  -- default rebirth 0
            pcall(function()
                local ch = GetSyncChannel()
                local pods = ch and ch:Get("AnimalPodiums") or {}
                local rebirth = ch and ch:Get("Rebirth") or 0
                -- MaxAnimals from Datas.Bases[rebirth]
                local basesData = require(RS.Datas.Bases)
                local rebirthData = basesData[rebirth] or basesData[0]
                if rebirthData then yourMax = rebirthData.MaxAnimals end
                for _, v in pairs(pods) do
                    if type(v) == "table" and v.Index then realAnimalCountInit = realAnimalCountInit + 1 end
                end
            end)
            local totalYours = realAnimalCountInit + #spawnedModels
            pcall(function() inner.Your.BaseSlots.Text = totalYours.."/"..yourMax end)

            -- Other side
            local otherMax = math.random(20, 27)
            local minFilled = math.max(#theirItems, 10)
            local otherCur = math.random(minFilled, math.min(minFilled+5, otherMax))
            pcall(function() inner.Other.BaseSlots.Text = otherCur.."/"..otherMax end)
        end)

        -- Their brainrots → Other.ScrollingFrame
        pcall(function()
            local scroll = inner.Other.ScrollingFrame
            local tmpl   = scroll:FindFirstChild("Template")
            if not tmpl then return end
            for _, v in scroll:GetChildren() do
                if v ~= tmpl and v:IsA("Frame") then v:Destroy() end
            end
            for i, item in ipairs(theirItems) do
                local f = tmpl:Clone()
                f.Name = "FT_"..i
                f.Visible = true
                f.LayoutOrder = i
                local sp = f:FindFirstChild("Spacer")
                if sp then
                    pcall(function() sp.Title.Text = item.name end)
                    pcall(function()
                        local function fmt(n)
                            local function c(s,x) return s:gsub("%.0+"..x,x):gsub("(%.%d-)0+"..x,"%1"..x) end
                            if n>=1e12 then return c(("%.1fT"):format(n/1e12),"T")
                            elseif n>=1e9 then return c(("%.1fB"):format(n/1e9),"B")
                            elseif n>=1e6 then return c(("%.1fM"):format(n/1e6),"M")
                            elseif n>=1e3 then return c(("%.1fK"):format(n/1e3),"K")
                            else return tostring(math.floor(n)) end
                        end
                        -- include traits in the gen calc so the trade entry shows
                        -- the boosted $/s — matches what the recipient will see.
                        local gen = calcGen(item.name, item.mutation, item.traits or {})
                        if gen > 0 then sp.Cash.Text = "$"..fmt(gen).."/s" end
                    end)
                    -- viewport + animation
                    pcall(function()
                        local sa = GetSharedAnimals()
                        if sa and sa.AttachOnViewportWithOptimizations then
                            sa:AttachOnViewportWithOptimizations(item.name, sp.ViewportFrame, nil, item.mutation ~= "None" and item.mutation or nil)
                        end
                    end)
                    -- render trait icons (matches the live-overhead Traits row)
                    pcall(function()
                        if not item.traits or #item.traits == 0 then return end
                        local traitsFrame = sp:FindFirstChild("Traits")
                            or f:FindFirstChild("Traits", true)
                        if not traitsFrame then return end
                        traitsFrame.ClipsDescendants = false  -- show all icons, not just first 4
                        local tmplT = traitsFrame:FindFirstChild("Template")
                        if not tmplT then return end
                        tmplT.Visible = false
                        local liveTraitData = nil
                        pcall(function() liveTraitData = require(RS.Datas.Traits) end)
                        local shown = 0
                        for _, t in ipairs(item.traits) do
                            -- show every trait, no cap
                            local icon = TRAIT_ICONS[t]
                                or (liveTraitData and liveTraitData[t] and liveTraitData[t].Icon)
                            if icon then
                                local img = tmplT:Clone()
                                img.Image   = icon
                                img.Visible = true
                                img.Parent  = traitsFrame
                                shown = shown + 1
                            end
                        end
                        traitsFrame.Visible = shown > 0
                    end)
                end
                f.Parent = scroll
            end
        end)

        -- Update slot count
        pcall(function() inner.Other.BaseSlots.Text = #theirItems.."/15" end)


        -- Hook Close and Cancel buttons - show notification then close
        -- fake timer countdown
        -- all state at top level so every function shares same upvalues
        local timerConn  = nil
        local timerDoneF = false
        local isReadyF   = false
        local rbCloneF   = nil
        -- Force-Accept flags: set when the user fires the dispatcher at the
        -- corresponding stage so the user's own click skips the redundant
        -- "wait for fake to ready/confirm" delay.  Each is consumed once.
        local kvFakeForceReadied   = false
        local kvFakeForceConfirmed = false
        local readyFrameF = inner.Your:FindFirstChild("Ready")
        local selectedSlots = {}  -- shared between inject block and timer sequence
        local slotToModel   = {}  -- maps slot frame Name -> spawnedModel (fake only)
        local inConfirmStage = false  -- blocks slot clicks during confirm
        local tradeCancelled = false  -- kills all pending delayed tasks

        local function UpdateReadyStyleF()
            if not rbCloneF then return end
            local txt = rbCloneF:FindFirstChild("Txt")
            if isReadyF then
                rbCloneF.BackgroundColor3 = Color3.fromRGB(112,112,112)
            elseif timerDoneF then
                rbCloneF.BackgroundColor3 = Color3.fromRGB(81,158,86)
            else
                rbCloneF.BackgroundColor3 = Color3.fromRGB(112,112,112)
            end
            if txt then txt.Text = "READY" end
        end

        local function StartTimer()
            -- don't reset if in confirm stage
            if inConfirmStage then return end
            -- unready
            if isReadyF then
                isReadyF = false
                if readyFrameF then readyFrameF.Visible = false end
            end
            -- hide other ready frame too when timer resets
            pcall(function()
                local otherReady = inner.Other:FindFirstChild("Ready")
                if otherReady then otherReady.Visible = false end
            end)
            timerDoneF = false
            UpdateReadyStyleF()
            if timerConn then pcall(function() timerConn:Disconnect() end) end
            local timerLbl = inner.Other:FindFirstChild("Timer")
            if not timerLbl then return end
            local t = 5.0
            timerLbl.Text = "⏰5.0s Left"
            timerConn = RunService.Heartbeat:Connect(function(dt)
                t = math.max(0, t - dt)
                local txt2 = ("%.1f"):format(t)
                txt2 = txt2:gsub("%.0$","")
                timerLbl.Text = "⏰"..txt2.."s Left"
                if t <= 0 then
                    timerLbl.Text = ""
                    timerConn:Disconnect(); timerConn = nil
                    timerDoneF = true
                    UpdateReadyStyleF()
                end
            end)
        end

        -- store rb reference for cleanup
        local _rbRef = nil
        local function RestoreAll()
            pcall(function() if hudGui then hudGui.Enabled = true end end)
            pcall(function() if _rbRef then _rbRef.Visible = true end end)
            pcall(function()
                local RS2 = game:GetService("ReplicatedStorage")
                local cam = require(RS2.Controllers.CameraController)
                cam:Blur(0, 0.4)
                cam:Fov(cam:GetDefaultFov(), 0.4)
            end)
        end

        local function AnimateClose(cb)
            fakeTradeItems = {}  -- clear so next trade starts fresh
            RestoreAll()
            local TS2 = game:GetService("TweenService")
            local tweenOut = TS2:Create(inner, TweenInfo.new(0.4, Enum.EasingStyle.Quint, Enum.EasingDirection.In), {
                Position = inner.Position + UDim2.fromScale(0, -2),
                Size = inner.Size + UDim2.fromScale(0, 0),
            })
            tweenOut:Play()
            tweenOut.Completed:Connect(function()
                pcall(function() clone:Destroy() end)
                if cb then cb() end
            end)
        end

        local function DoCancel()
            tradeCancelled = true
            _activeFakeStartTimer = nil
            if timerConn then pcall(function() timerConn:Disconnect() end) end
            pcall(function() require(RS.Controllers.SoundController):PlaySound("Sounds.Sfx.Activated") end)
            pcall(function() require(RS.Controllers.SoundController):PlaySound("Sounds.Sfx.Error") end)
            pcall(function()
                local nc = require(RS.Controllers.NotificationController)
                nc:Error("@"..LocalPlayer.Name.." canceled")
            end)
            AnimateClose()
        end
        pcall(function()
            local closeBtn = inner.Header:FindFirstChild("Close")
            if closeBtn then
                closeBtn.Activated:Connect(DoCancel)
                -- Hover animation on the X (matches real trade)
                local TS_ = game:GetService("TweenService")
                local origSize = closeBtn.Size
                local hoverSize = UDim2.new(
                    origSize.X.Scale * 1.12, origSize.X.Offset * 1.12,
                    origSize.Y.Scale * 1.12, origSize.Y.Offset * 1.12
                )
                local tweenInfo = TweenInfo.new(0.18, Enum.EasingStyle.Quint, Enum.EasingDirection.Out)
                closeBtn.MouseEnter:Connect(function()
                    pcall(function() TS_:Create(closeBtn, tweenInfo, {Size = hoverSize}):Play() end)
                end)
                closeBtn.MouseLeave:Connect(function()
                    pcall(function() TS_:Create(closeBtn, tweenInfo, {Size = origSize}):Play() end)
                end)
            end
        end)
        pcall(function()
            local cancelBtn = inner.Other:FindFirstChild("Cancel")
            if cancelBtn then cancelBtn.Activated:Connect(DoCancel) end
        end)

        -- Wire side reaction buttons (Add More, Deal?, L Trade, Fair Trade, Last Offer, No Thanks)
        -- The game's labeling script doesn't fire on the cloned UI, so all 6 buttons read
        -- the raw template text "Add More". We detect them by that text, sort by position,
        -- and rewrite labels ourselves, then attach click sound + tap animation.
        pcall(function()
            local TS_r = game:GetService("TweenService")
            local LABELS = {"Add More", "Deal?", "L Trade", "Fair Trade", "Sign", "No Thanks"}
            local SIGN_TEXTS = {"Add More!", "Deal?", "L Trade", "Fair Trade!", "Sign", "No Thanks!"}

            local function setBtnLabel(btn, label)
                -- Try the button's own .Text first, then any descendant TextLabel
                if btn:IsA("TextButton") and btn.Text and btn.Text ~= "" then
                    btn.Text = label
                    return
                end
                for _, c in ipairs(btn:GetDescendants()) do
                    if c:IsA("TextLabel") then
                        c.Text = label
                        return
                    end
                end
            end

            local function wireReactionBtn(b, signText)
                if b:GetAttribute("KVReactionWired") then return end
                b:SetAttribute("KVReactionWired", true)
                b.AutoButtonColor = false
                local origSize = b.Size
                local pressedSize = UDim2.new(origSize.X.Scale*0.92, origSize.X.Offset*0.92,
                                              origSize.Y.Scale*0.92, origSize.Y.Offset*0.92)
                local hoverSize = UDim2.new(origSize.X.Scale*1.04, origSize.X.Offset*1.04,
                                            origSize.Y.Scale*1.04, origSize.Y.Offset*1.04)
                local tIn  = TweenInfo.new(0.12, Enum.EasingStyle.Quint, Enum.EasingDirection.Out)
                local tOut = TweenInfo.new(0.18, Enum.EasingStyle.Quint, Enum.EasingDirection.Out)
                b.MouseEnter:Connect(function() pcall(function() TS_r:Create(b, tIn, {Size = hoverSize}):Play() end) end)
                b.MouseLeave:Connect(function() pcall(function() TS_r:Create(b, tOut, {Size = origSize}):Play() end) end)
                b.MouseButton1Down:Connect(function() pcall(function() TS_r:Create(b, tIn, {Size = pressedSize}):Play() end) end)
                b.MouseButton1Up:Connect(function() pcall(function() TS_r:Create(b, tOut, {Size = hoverSize}):Play() end) end)
                b.Activated:Connect(function()
                    pcall(function() require(RS.Controllers.SoundController):PlaySound("Sounds.Sfx.Activated") end)
                    -- Update the YourSign center text, mirroring real reactions
                    pcall(function()
                        local sign = inner:FindFirstChild("YourSign")
                        if not sign then return end
                        for _, d in ipairs(sign:GetDescendants()) do
                            if d:IsA("TextLabel") and d.TextSize and d.TextSize >= 18 then
                                d.Text = signText
                                break
                            end
                        end
                    end)
                end)
            end

            local function scanForReactions()
                -- Group buttons containing "Add More" text by their parent.
                -- Scan the WHOLE clone (the buttons can sit outside `inner`).
                local groupsByParent = {}
                local function noteBtn(btn)
                    if not btn then return end
                    local p = btn.Parent
                    groupsByParent[p] = groupsByParent[p] or {}
                    for _, x in ipairs(groupsByParent[p]) do if x == btn then return end end
                    table.insert(groupsByParent[p], btn)
                end
                for _, d in ipairs(clone:GetDescendants()) do
                    if d:IsA("TextLabel") and d.Text and d.Text:lower():find("add more") then
                        local btn = d.Parent
                        while btn and not (btn:IsA("TextButton") or btn:IsA("ImageButton")) do
                            btn = btn.Parent
                            if btn == clone then btn = nil; break end
                        end
                        noteBtn(btn)
                    elseif d:IsA("TextButton") and d.Text and d.Text:lower():find("add more") then
                        noteBtn(d)
                    end
                end

                for _, btns in pairs(groupsByParent) do
                    if #btns >= 2 then
                        -- sort top-to-bottom, left-to-right by absolute position
                        table.sort(btns, function(a, b)
                            local pa, pb = a.AbsolutePosition, b.AbsolutePosition
                            if math.abs(pa.Y - pb.Y) > 5 then return pa.Y < pb.Y end
                            return pa.X < pb.X
                        end)
                        for i, btn in ipairs(btns) do
                            local label = LABELS[i] or ("Reaction "..i)
                            local sign  = SIGN_TEXTS[i] or label
                            setBtnLabel(btn, label)
                            -- Lock the label by attribute, and re-set it whenever something
                            -- (like the game's scripts) tries to overwrite it back to "Add More".
                            if not btn:GetAttribute("KVLabelLocked") then
                                btn:SetAttribute("KVLabelLocked", true)
                                if btn:IsA("TextButton") then
                                    btn:GetPropertyChangedSignal("Text"):Connect(function()
                                        if btn.Text ~= label then btn.Text = label end
                                    end)
                                end
                                for _, c in ipairs(btn:GetDescendants()) do
                                    if c:IsA("TextLabel") then
                                        c:GetPropertyChangedSignal("Text"):Connect(function()
                                            if c.Text ~= label then c.Text = label end
                                        end)
                                    end
                                end
                            end
                            wireReactionBtn(btn, sign)
                        end
                    end
                end
            end

            -- A small number of timed scans. Once labeling completes (BOTH
            -- sides — your side AND their side, 12 buttons total), subsequent
            -- scans short-circuit. No DescendantAdded listener (caused crashes).
            local labelingDone = false
            local function safeScan()
                if labelingDone then return end
                pcall(scanForReactions)
                -- Mark done only when BOTH sides are wired (≥12 buttons)
                local wired = 0
                for _, d in ipairs(clone:GetDescendants()) do
                    if d:GetAttribute("KVReactionWired") then wired = wired + 1 end
                    if wired >= 12 then break end
                end
                if wired >= 12 then labelingDone = true end
            end
            safeScan()
            task.delay(0.3, safeScan)
            task.delay(1.0, safeScan)
            task.delay(2.5, safeScan)
        end)

        -- start timer immediately on open
        _activeFakeStartTimer = StartTimer
        StartTimer()

        -- Ready button clone setup
        task.delay(0.2, function()
            local rb = inner.Other:FindFirstChild("ReadyButton")
            if not rb then return end
            rbCloneF = rb:Clone()
            rb.Visible = false
            _rbRef = rb  -- store for RestoreAll
            rbCloneF.Active = true
            rbCloneF.Interactable = true
            rbCloneF.Parent = rb.Parent
            UpdateReadyStyleF()

            -- Force Accept dispatcher: snaps the partner's frame on AND restarts
            -- the appropriate stage timer — exactly like the partner readying or
            -- confirming first.
            -- • In Ready stage: shows partner's "Ready!" frame, restarts the 5s
            --   wait timer, button greys out → green when timer elapses, user
            --   then clicks Ready to advance.  Sets kvFakeForceReadied so the
            --   user's Ready click skips the redundant 5s "wait for fake to
            --   ready" step (the fake's already ready).
            -- • In Accept (confirm) stage: shows partner's "Confirmed!" frame,
            --   restarts the 5s confirm timer, button greys → green, user then
            --   clicks ACCEPT to finalize.  Sets kvFakeForceConfirmed so the
            --   user's ACCEPT click skips the redundant 5s "wait for fake to
            --   confirm" step.
            _kvForceAcceptDispatcher = function()
                if tradeCancelled then return end
                pcall(function() require(RS.Controllers.SoundController):PlaySound("Sounds.Sfx.Activated") end)

                if inConfirmStage then
                    -- Accept (confirm) stage path
                    kvFakeForceConfirmed = true
                    pcall(function()
                        local or3 = inner.Other:FindFirstChild("Ready")
                        if or3 then
                            or3.Visible = true
                            local lbl3 = or3:FindFirstChild("Label")
                            if lbl3 then lbl3.Text = "Confirmed!" end
                        end
                    end)
                    -- Restart the 5s confirm wait timer.  The Confirm-click
                    -- handler reads `confirmReady` (set in its own timer cb);
                    -- it lives in a tighter scope so we can't reach it from
                    -- here, but the original timer keeps running too — this
                    -- new timer is purely visual feedback to match the Ready-
                    -- stage UX.  The flag above is what actually matters.
                    if timerConn then pcall(function() timerConn:Disconnect() end) end
                    if rbCloneF then rbCloneF.BackgroundColor3 = Color3.fromRGB(112,112,112) end
                    local timerLblFC = inner.Other:FindFirstChild("Timer")
                    if timerLblFC then
                        local tFC = 5.0
                        timerLblFC.Text = "⏰5.0s Left"
                        timerConn = RunService.Heartbeat:Connect(function(dt)
                            tFC = math.max(0, tFC - dt)
                            local sFC = ("%.1f"):format(tFC):gsub("%.0$","")
                            timerLblFC.Text = "⏰"..sFC.."s Left"
                            if tFC <= 0 then
                                timerLblFC.Text = ""
                                timerConn:Disconnect(); timerConn = nil
                                if rbCloneF then rbCloneF.BackgroundColor3 = Color3.fromRGB(81,158,86) end
                            end
                        end)
                    end
                    return
                end

                -- Ready stage path
                kvFakeForceReadied = true
                pcall(function()
                    local otherReady = inner.Other:FindFirstChild("Ready")
                    if otherReady then
                        otherReady.Visible = true
                        local lbl = otherReady:FindFirstChild("Label")
                        if lbl then lbl.Text = "Ready!" end
                    end
                end)
                if timerConn then pcall(function() timerConn:Disconnect() end) end
                timerDoneF = false
                isReadyF = false
                if readyFrameF then readyFrameF.Visible = false end
                UpdateReadyStyleF()
                local timerLblF = inner.Other:FindFirstChild("Timer")
                if timerLblF then
                    local tF = 5.0
                    timerLblF.Text = "⏰5.0s Left"
                    timerConn = RunService.Heartbeat:Connect(function(dt)
                        tF = math.max(0, tF - dt)
                        local sF = ("%.1f"):format(tF):gsub("%.0$","")
                        timerLblF.Text = "⏰"..sF.."s Left"
                        if tF <= 0 then
                            timerLblF.Text = ""
                            timerConn:Disconnect(); timerConn = nil
                            timerDoneF = true
                            UpdateReadyStyleF()
                        end
                    end)
                end
            end

            rbCloneF.MouseButton1Click:Connect(function()
                pcall(function() require(RS.Controllers.SoundController):PlaySound("Sounds.Sfx.Activated") end)
                if not timerDoneF or isReadyF then return end
                isReadyF = true
                if readyFrameF then readyFrameF.Visible = true end
                UpdateReadyStyleF()
                -- restart timer WITHOUT unreadying (bypass the unready logic)
                timerDoneF = false
                if timerConn then pcall(function() timerConn:Disconnect() end) end
                local timerLbl2 = inner.Other:FindFirstChild("Timer")
                if timerLbl2 then
                    -- If the partner was already force-readied via Force Accept,
                    -- skip the redundant 5s "wait for fake to ready" — they're
                    -- already ready, so we go straight to confirm stage.  Flag
                    -- consumed here so subsequent click cycles work normally.
                    local t2 = (kvFakeForceReadied and 0.01) or 5.0
                    kvFakeForceReadied = false
                    timerLbl2.Text = "⏰"..(t2 < 1 and "0.0" or "5.0").."s Left"
                    timerConn = RunService.Heartbeat:Connect(function(dt)
                        t2 = math.max(0, t2 - dt)
                        local s2 = ("%.1f"):format(t2):gsub("%.0$","")
                        timerLbl2.Text = "⏰"..s2.."s Left"
                        if t2 <= 0 then
                            timerLbl2.Text = ""
                            timerConn:Disconnect(); timerConn = nil
                            if tradeCancelled then return end
                            -- 0.5s after YOUR timer: fake player also readies
                            task.delay(0.5, function()
                                if tradeCancelled then return end
                                pcall(function()
                                    local otherReady = inner.Other:FindFirstChild("Ready")
                                    if otherReady then
                                        otherReady.Visible = true
                                        local lbl2 = otherReady:FindFirstChild("Label")
                                        if lbl2 then lbl2.Text = "Ready!" end
                                    end
                                end)
                                -- 0.5s later: enter confirm stage
                                task.delay(0.5, function()
                                    if tradeCancelled then return end
                                    inConfirmStage = true
                                    local confirmReady = false
                                    local rbTxt2 = rbCloneF and rbCloneF:FindFirstChild("Txt")
                                    if rbCloneF then rbCloneF.BackgroundColor3 = Color3.fromRGB(112,112,112) end
                                    if rbTxt2 then rbTxt2.Text = "ACCEPT" end
                                    -- hide both ready frames, deselect slots
                                    pcall(function()
                                        readyFrameF.Visible = false
                                        local lbl = readyFrameF:FindFirstChild("Label")
                                        if lbl then lbl.Text = "Ready!" end
                                    end)
                                    pcall(function()
                                        local or2 = inner.Other:FindFirstChild("Ready")
                                        if or2 then
                                            or2.Visible = false
                                            local lbl2 = or2:FindFirstChild("Label")
                                            if lbl2 then lbl2.Text = "Ready!" end
                                        end
                                    end)
                                    pcall(function()
                                        local scroll = inner.Your:FindFirstChild("ScrollingFrame")
                                        if scroll then
                                            for _, f in scroll:GetChildren() do
                                                if f:IsA("Frame") then
                                                    if not selectedSlots[f.Name] then f.Visible = false end
                                                    local sp = f:FindFirstChild("Spacer")
                                                    if sp then
                                                        sp.BackgroundColor3 = Color3.fromRGB(35,45,50)
                                                        local sk = sp:FindFirstChildOfClass("UIStroke")
                                                        if sk then sk.Color = Color3.fromRGB(0,0,0) end
                                                    end
                                                end
                                            end
                                        end
                                    end)
                                    -- 5s confirm timer
                                    if timerConn then pcall(function() timerConn:Disconnect() end) end
                                    local timerLblC = inner.Other:FindFirstChild("Timer")
                                    if timerLblC then
                                        local tc = 5.0
                                        timerLblC.Text = "⏰5.0s Left"
                                        timerConn = RunService.Heartbeat:Connect(function(dt)
                                            tc = math.max(0, tc - dt)
                                            local s3 = ("%.1f"):format(tc):gsub("%.0$","")
                                            timerLblC.Text = "⏰"..s3.."s Left"
                                            if tc <= 0 then
                                                timerLblC.Text = ""
                                                timerConn:Disconnect(); timerConn = nil
                                                if tradeCancelled then return end
                                                confirmReady = true
                                                if rbCloneF then rbCloneF.BackgroundColor3 = Color3.fromRGB(81,158,86) end
                                            end
                                        end)
                                    end
                                    -- ACCEPT click
                                    local confirmConn
                                    confirmConn = rbCloneF.MouseButton1Click:Connect(function()
                                        if not confirmReady or tradeCancelled then return end
                                        confirmConn:Disconnect()
                                        pcall(function() require(RS.Controllers.SoundController):PlaySound("Sounds.Sfx.Activated") end)
                                        -- YOUR confirmed
                                        if readyFrameF then
                                            readyFrameF.Visible = true
                                            local lbl = readyFrameF:FindFirstChild("Label")
                                            if lbl then lbl.Text = "Confirmed!" end
                                        end
                                        if rbCloneF then rbCloneF.BackgroundColor3 = Color3.fromRGB(112,112,112) end
                                        -- restart timer, fake player confirms after.
                                        -- If partner was already force-confirmed, skip
                                        -- the redundant 5s wait — they're done.
                                        if timerConn then pcall(function() timerConn:Disconnect() end) end
                                        local timerLblC2 = inner.Other:FindFirstChild("Timer")
                                        if timerLblC2 then
                                            local tc2 = (kvFakeForceConfirmed and 0.01) or 5.0
                                            kvFakeForceConfirmed = false
                                            timerLblC2.Text = "⏰"..(tc2 < 1 and "0.0" or "5.0").."s Left"
                                            timerConn = RunService.Heartbeat:Connect(function(dt)
                                                tc2 = math.max(0, tc2 - dt)
                                                local s4 = ("%.1f"):format(tc2):gsub("%.0$","")
                                                timerLblC2.Text = "⏰"..s4.."s Left"
                                                if tc2 <= 0 then
                                                    timerLblC2.Text = ""
                                                    timerConn:Disconnect(); timerConn = nil
                                                    if tradeCancelled then return end
                                                    task.delay(0.5, function()
                                                        if tradeCancelled then return end
                                                        -- fake player confirms
                                                        pcall(function()
                                                            local or3 = inner.Other:FindFirstChild("Ready")
                                                            if or3 then
                                                                or3.Visible = true
                                                                local lbl2 = or3:FindFirstChild("Label")
                                                                if lbl2 then lbl2.Text = "Confirmed!" end
                                                            end
                                                        end)
                                                        pcall(function()
                                                            local t3 = inner.Other:FindFirstChild("Timer")
                                                            if t3 then t3.Text = "Processing..." end
                                                        end)
                                                        -- 2.5s success
                                                        task.delay(2.5, function()
                                                            if tradeCancelled then return end
                                                            _lastFakeTradeTime = tick()  -- update cooldown
                                                            pcall(function()
                                                                local nc = require(RS.Controllers.NotificationController)
                                                                nc:Success("Trade completed with @"..username.."! 🎉")
                                                            end)
                                                            pcall(function() require(RS.Controllers.SoundController):PlaySound("Sounds.Sfx.Success") end)
                                                            for slotName, isSelected in pairs(selectedSlots) do
                                                                if isSelected then
                                                                    local mdl = slotToModel[slotName]
                                                                    if mdl and mdl.Parent then
                                                                        pcall(function()
                                                                            local oh = modelOverheads[mdl]
                                                                            if oh then
                                                                                pcall(function() if oh.part then oh.part:Destroy() end end)
                                                                                pcall(function() if oh.att  then oh.att:Destroy()  end end)
                                                                                pcall(function() if oh.gui  then oh.gui:Destroy()  end end)
                                                                                modelOverheads[mdl] = nil
                                                                            end
                                                                            local cp = modelCashpads[mdl]
                                                                            if cp then
                                                                                if cp.conn then cp.conn:Disconnect() end
                                                                                if cp.part then cp.part:Destroy() end
                                                                                modelCashpads[mdl] = nil
                                                                            end
                                                                            modelSnapshots[mdl] = nil
                                                                            for i, m in ipairs(spawnedModels) do
                                                                                if m == mdl then table.remove(spawnedModels, i); break end
                                                                            end
                                                                            -- mirror the sell-path prompt cleanup so the slot
                                                                            -- doesn't keep showing Grab/Sell prompts after trade-away
                                                                            local pi = modelPromptInfo[mdl]
                                                                            if pi then
                                                                                if pi.slot and slotPromptConns[pi.slot] then
                                                                                    for _, c in ipairs(slotPromptConns[pi.slot]) do
                                                                                        pcall(function() c:Disconnect() end)
                                                                                    end
                                                                                    slotPromptConns[pi.slot] = nil
                                                                                end
                                                                                if pi.att then
                                                                                    for _, p2 in pi.att:GetChildren() do
                                                                                        if p2:IsA("ProximityPrompt") then
                                                                                            p2.ActionText = "Interact"
                                                                                            p2.ObjectText = ""
                                                                                            p2:SetAttribute("State", "None")
                                                                                            p2.Enabled = false
                                                                                        end
                                                                                    end
                                                                                end
                                                                                modelPromptInfo[mdl] = nil
                                                                            end
                                                                            ScheduleSave()
                                                                            mdl:Destroy()
                                                                        end)
                                                                    end
                                                                end
                                                            end
                                                            -- spawn received brainrots
                                                            task.spawn(function()
                                                                for _, item in ipairs(theirItems) do
                                                                    SpawnOneAnimal(item.name, item.mutation, item.traits or {})
                                                                end
                                                                DrainPendingSpawns()
                                                            end)
                                                            UpdateCount()
                                                            task.delay(0.5, function() AnimateClose() end)
                                                        end)
                                                    end)
                                                end
                                            end)
                                        end
                                    end)
                                end)
                            end)
                        end
                    end)
                end
            end)
        end)

        -- Inject Your side: real animals from server + fake spawned models
        task.delay(0.15, function()
            local yourScroll = inner.Your:FindFirstChild("ScrollingFrame")
            local tmpl = yourScroll and yourScroll:FindFirstChild("Template")
            if not yourScroll or not tmpl then return end

            -- clear old
            for _, v in yourScroll:GetChildren() do
                if v:IsA("Frame") and v ~= tmpl then v:Destroy() end
            end

            -- selectedSlots declared at LaunchFakeTrade scope above
            -- slotToModel maps slot frame name -> model instance for deletion

            -- capture base counts once
            -- baseMine = same logic as initial display
            local baseMine = 0
            pcall(function()
                local ch = GetSyncChannel()
                local pods = ch and ch:Get("AnimalPodiums") or {}
                for _, v in pairs(pods) do
                    if type(v) == "table" and v.Index then baseMine = baseMine + 1 end
                end
            end)
            baseMine = baseMine + #spawnedModels
            -- capture other side's original numerator
            local otherBaseNum = 0
            pcall(function()
                local bs = inner.Other:FindFirstChild("BaseSlots")
                if bs then otherBaseNum = tonumber(bs.Text:match("(%d+)/")) or 0 end
            end)

            local function MakeSlot(parent, animalName, mutation, index, isReal, mdlRef)
                local snap = {mutation = mutation or "None"}
                local f = tmpl:Clone()
                f.Name = (isReal and "REAL_" or "KV_")..index
                f.Visible = true; f.LayoutOrder = index
                -- track fake model for deletion
                if not isReal and mdlRef then slotToModel[f.Name] = mdlRef end
                local sp = f:FindFirstChild("Spacer")
                if sp then
                    -- raw name in the trade UI — "is Calling..." should only appear
                    -- on the live overhead, not in the trade item list.
                    pcall(function() sp.Title.Text = animalName end)
                    -- accurate cash using SharedAnimals:GetGeneration
                    pcall(function()
                        local snap = mdlRef and modelSnapshots[mdlRef]
                        local traits = snap and snap.traits or {}
                        local sa = GetSharedAnimals()
                        local function fmt(n)
                            local function c(s,x) return s:gsub("%.0+"..x,x):gsub("(%.%d-)0+"..x,"%1"..x) end
                            if n>=1e12 then return c(("%.1fT"):format(n/1e12),"T")
                            elseif n>=1e9 then return c(("%.1fB"):format(n/1e9),"B")
                            elseif n>=1e6 then return c(("%.1fM"):format(n/1e6),"M")
                            elseif n>=1e3 then return c(("%.1fK"):format(n/1e3),"K")
                            else return tostring(math.floor(n)) end
                        end
                        local gen2 = calcGen(animalName, mutation, traits)
                        if gen2 > 0 then sp.Cash.Text = "$"..fmt(gen2).."/s" end
                    end)
                    -- populate traits icons (snap.traits is array of names)
                    pcall(function()
                        local snap = mdlRef and modelSnapshots[mdlRef]
                        local traits = snap and snap.traits or {}
                        if #traits == 0 then return end
                        local traitsFrame = sp:FindFirstChild("Traits")
                        local tmplTrait = traitsFrame and traitsFrame:FindFirstChild("Template")
                        if not traitsFrame or not tmplTrait then return end
                        for _, c in traitsFrame:GetChildren() do
                            if c ~= tmplTrait and not c:IsA("UIGridLayout") and not c:IsA("UIListLayout") then c:Destroy() end
                        end
                        -- ensure layout exists
                        if not traitsFrame:FindFirstChildOfClass("UIGridLayout") and not traitsFrame:FindFirstChildOfClass("UIListLayout") then
                            local gl = Instance.new("UIGridLayout", traitsFrame)
                            gl.CellSize = UDim2.new(0, tmplTrait.AbsoluteSize.X > 0 and tmplTrait.AbsoluteSize.X or 20, 0, tmplTrait.AbsoluteSize.Y > 0 and tmplTrait.AbsoluteSize.Y or 20)
                            gl.CellPadding = UDim2.new(0, 2, 0, 2)
                            gl.SortOrder = Enum.SortOrder.LayoutOrder
                        end
                        for i3, traitName in ipairs(traits) do
                            local icon = tmplTrait:Clone()
                            icon.Name = traitName
                            icon.Visible = true
                            icon.LayoutOrder = i3
                            if TRAIT_ICONS[traitName] then
                                pcall(function() icon.Image = TRAIT_ICONS[traitName] end)
                            end
                            icon.Parent = traitsFrame
                        end
                    end)
                    -- viewport + animation via SharedAnimals (same as real game)
                    pcall(function()
                        local sa = GetSharedAnimals()
                        if sa and sa.AttachOnViewportWithOptimizations then
                            sa:AttachOnViewportWithOptimizations(animalName, sp.ViewportFrame, nil, mutation ~= "None" and mutation or nil)
                        else
                            -- fallback manual viewport
                            local vp=sp.ViewportFrame
                            local cam=Instance.new("Camera"); cam.FieldOfView=50
                            vp.CurrentCamera=cam; cam.Parent=vp
                            local wm=Instance.new("WorldModel",vp)
                            local tmpl2=RS.Models.Animals:FindFirstChild(animalName)
                            if not tmpl2 then return end
                            local m=tmpl2:Clone()
                            if mutation and mutation ~= "None" then
                                pcall(function() sa:ApplyMutation(m,animalName,mutation) end)
                            end
                            for _,p in m:GetDescendants() do
                                if p:IsA("BasePart") then p.CanCollide=false;p.CanQuery=false;p.CanTouch=false;p.Anchored=true end
                            end
                            m:PivotTo(CFrame.new(0,0,0)); m.Parent=wm
                            local ext=m:GetExtentsSize(); local maxDim=math.max(ext.X,ext.Y,ext.Z)
                            local dist=(maxDim*0.5/math.tan(math.rad(25)))*0.75
                            local lookAt=m.PrimaryPart and m.PrimaryPart.CFrame or CFrame.new(0,0,0)
                            cam.CFrame=CFrame.new((lookAt*CFrame.new(Vector3.new(-1,0.25,-1).Unit*(dist+maxDim*0.5))).Position,lookAt.Position)
                            local af=RS.Animations.Animals:FindFirstChild(animalName)
                            local ia=af and af:FindFirstChild("Idle")
                            if ia then
                                local ac=m:FindFirstChildOfClass("AnimationController") or m:FindFirstChildWhichIsA("AnimationController",true)
                                if ac then
                                    local anim=ac:FindFirstChildOfClass("Animator") or Instance.new("Animator",ac)
                                    pcall(function() local tr=anim:LoadAnimation(ia); tr.Looped=true; tr:Play(0) end)
                                end
                            end
                        end
                    end)

                    -- click to select/deselect - use both Activated and InputBegan for compatibility
                    local function onSlotClick()
                        if inConfirmStage then return end
                        -- toggle selection
                        selectedSlots[f.Name] = not selectedSlots[f.Name]
                        local selected = selectedSlots[f.Name]
                        sp.BackgroundColor3 = selected and Color3.fromRGB(15,50,15) or Color3.fromRGB(35,45,50)
                        local sk = sp:FindFirstChildOfClass("UIStroke")
                        if sk then sk.Color = selected and Color3.fromRGB(0,255,0) or Color3.fromRGB(0,0,0) end
                        pcall(function() require(RS.Controllers.SoundController):PlaySound("Sounds.Sfx.Activated") end)
                        -- restart timer (also unreadys if ready)
                        StartTimer()
                        -- update slot counts
                        pcall(function()
                            local selCount = 0
                            for _, v in pairs(selectedSlots) do if v then selCount = selCount + 1 end end
                            local yourBS = inner.Your:FindFirstChild("BaseSlots")
                            local otherBS = inner.Other:FindFirstChild("BaseSlots")
                            if yourBS then
                                local _, max = yourBS.Text:match("(%d+)/(%d+)")
                                if max then yourBS.Text = math.max(0, baseMine - selCount).."/"..max end
                            end
                            if otherBS then
                                local cur3, max = otherBS.Text:match("(%d+)/(%d+)")
                                cur3 = tonumber(cur3) or otherBaseNum
                                if max then otherBS.Text = (cur3 + (selected and 1 or -1)).."/"..max end
                            end
                        end)
                    end
                    -- debounced click prevents double-fire from Activated+InputBegan
                    local _lastSlotClick = 0
                    local function debouncedClick()
                        local now = tick()
                        if now - _lastSlotClick < 0.15 then return end
                        _lastSlotClick = now
                        onSlotClick()
                    end
                    pcall(function() sp.Activated:Connect(debouncedClick) end)
                    sp.InputBegan:Connect(function(inp)
                        if inp.UserInputType == Enum.UserInputType.MouseButton1 or
                           inp.UserInputType == Enum.UserInputType.Touch then
                            debouncedClick()
                        end
                    end)
                end
                f.Parent = parent
            end

            local idx = 1
            -- Real animals from AnimalPodiums
            pcall(function()
                local ch = GetSyncChannel()
                local pods = ch and ch:Get("AnimalPodiums") or {}
                -- sort by key for consistent order
                local sorted = {}
                for k, v in pairs(pods) do
                    if type(v) == "table" and v.Index then
                        table.insert(sorted, v)
                    end
                end
                for _, v in ipairs(sorted) do
                    -- pass traits and mutation from server data
                    local realTraits = {}
                    if type(v.Traits) == "table" then
                        for _, t in ipairs(v.Traits) do table.insert(realTraits, t) end
                    end
                    -- store snapshot so MakeSlot can use it
                    local fakeMdlRef = {} -- dummy ref
                    modelSnapshots[fakeMdlRef] = {mutation = v.Mutation or "None", traits = realTraits}
                    MakeSlot(yourScroll, v.Index, v.Mutation or "None", idx, true, fakeMdlRef)
                    idx = idx + 1
                end
            end)

            -- Fake spawned models
            for _, mdl in ipairs(spawnedModels) do
                if mdl and mdl.Parent then
                    local snap = modelSnapshots[mdl] or {mutation="None"}
                    MakeSlot(yourScroll, mdl.Name, snap.mutation or "None", idx, false, mdl)
                    idx = idx + 1
                end
            end
        end)

        -- Stream mode overlay (press F5 to toggle black cover)
        local streamOverlay = New("Frame", {
            Size=UDim2.new(1,0,1,0), BackgroundColor3=Color3.fromRGB(0,0,0),
            BackgroundTransparency=1, BorderSizePixel=0, ZIndex=200,
            Parent=inner,
        })
        New("TextLabel", {
            Size=UDim2.new(1,0,1,0), BackgroundTransparency=1,
            Text="🔴 STREAM MODE", TextColor3=Color3.fromRGB(255,80,80),
            Font=Enum.Font.GothamBold, TextSize=24,
            TextXAlignment=Enum.TextXAlignment.Center,
            Visible=false, ZIndex=201, Parent=streamOverlay,
        })
        local streamLbl = streamOverlay:FindFirstChildOfClass("TextLabel")
        local streamOn = false
        local streamConn = game:GetService("UserInputService").InputBegan:Connect(function(inp, gp)
            if gp then return end
            if inp.KeyCode == Enum.KeyCode.F5 then
                streamOn = not streamOn
                streamOverlay.BackgroundTransparency = streamOn and 0 or 1
                if streamLbl then streamLbl.Visible = streamOn end
            end
        end)
        clone.AncestryChanged:Connect(function()
            if not clone.Parent then
                pcall(function() streamConn:Disconnect() end)
            end
        end)

        SetStatus("Fake trade open! (F5 = stream mode)", Color3.fromRGB(40,200,80), 3)

        -- no auto-close - user closes manually via cancel button
    end


    -- Assign to the module-level forward declaration so key listeners
    -- outside this do-block can also call OpenFakeTradeSetup.
    OpenFakeTradeSetup = function(prefill)
        -- If the form already exists in the trading page, just refresh prefill and return.
        if fakeTradeWin and fakeTradeWin.Parent then
            if prefill and type(prefill.username) == "string" and prefill.username ~= "" then
                local existingUsername = fakeTradeWin:FindFirstChild("__usernameBox", true)
                if existingUsername then existingUsername.Text = prefill.username end
            end
            return
        end

        local W, pad = 300, 10

        -- Inline form parented to the Trading tab page (auto-flow via UIListLayout)
        local win2 = New("Frame", {
            Size=UDim2.new(1,0,0,220),
            BackgroundColor3=Color3.fromRGB(30,28,42),
            BorderSizePixel=0, LayoutOrder=2, Parent=tradingPage,
        })
        fakeTradeWin = win2
        Corner(win2, 6)
        Stroke(win2, Color3.fromRGB(50,45,80), 1, 0.2)

        -- Pop-out / dock state. When popped out, win2 lives inside this separate
        -- ScreenGui so it survives sg.Enabled toggles (the main UI hide key).
        local popSg = nil
        local poppedOut = false

        -- ignoreHide is now hoisted to the outer scope so the sign editor
        -- can also follow the same "Show on Hide" preference.
        ignoreHide = (ignoreHide ~= nil) and ignoreHide or true  -- default ON

        local function syncPopSgEnabled()
            if popSg then
                popSg.Enabled = ignoreHide or sg.Enabled
            end
        end

        -- Pop Out + Always-Visible toggle row (split 60/40)
        local popBtn = New("TextButton", {
            Size=UDim2.new(0.6, -pad*1.5, 0, 22), Position=UDim2.new(0, pad, 0, 8),
            BackgroundColor3=Color3.fromRGB(108,92,231),
            Text="Pop Out",
            TextColor3=Color3.fromRGB(255,255,255), Font=Enum.Font.GothamBold,
            TextSize=10, AutoButtonColor=false, BorderSizePixel=0, Parent=win2,
        })
        Corner(popBtn, 5)
        popBtn.MouseEnter:Connect(function() popBtn.BackgroundColor3 = Color3.fromRGB(128,112,251) end)
        popBtn.MouseLeave:Connect(function() popBtn.BackgroundColor3 = Color3.fromRGB(108,92,231) end)

        local ignoreBtn = New("TextButton", {
            Size=UDim2.new(0.4, -pad*1.5, 0, 22),
            Position=UDim2.new(0.6, pad*0.5, 0, 8),
            BackgroundColor3 = Color3.fromRGB(40,160,70),
            Text="Show on Hide: ON",
            TextColor3=Color3.fromRGB(255,255,255), Font=Enum.Font.GothamBold,
            TextSize=10, AutoButtonColor=false, BorderSizePixel=0, Parent=win2,
        })
        Corner(ignoreBtn, 5)

        local function refreshPopBtnText()
            popBtn.Text = poppedOut and "Dock" or "Pop Out"
        end
        local function refreshIgnoreBtn()
            ignoreBtn.Text = ignoreHide and "Show on Hide: ON" or "Show on Hide: OFF"
            ignoreBtn.BackgroundColor3 = ignoreHide
                and Color3.fromRGB(40,160,70) or Color3.fromRGB(80,80,90)
        end

        popBtn.Activated:Connect(function()
            if poppedOut then
                -- DOCK: back into tradingPage as inline form
                poppedOut = false
                win2.AnchorPoint = Vector2.new(0,0)
                win2.Position = UDim2.new(0,0,0,0)
                win2.Size = UDim2.new(1, 0, 0, win2.Size.Y.Offset)
                win2.Parent = tradingPage
                if popSg then pcall(function() popSg:Destroy() end); popSg = nil end
            else
                -- POP OUT: into separate ScreenGui in bottom-LEFT corner.
                -- Use the form's full computed content height so nothing
                -- gets clipped (was getting cut off when constrained by
                -- the docked tradingPage's UIListLayout).
                poppedOut = true
                popSg = New("ScreenGui", {
                    Name = "KV_TradeSetupPopOut", ResetOnSpawn = false,
                    IgnoreGuiInset = true, ZIndexBehavior = Enum.ZIndexBehavior.Sibling,
                    DisplayOrder = 5000, Parent = GetSafeParent(),
                })
                syncPopSgEnabled()
                -- Use the actual computed content height (Size.Y.Offset is the
                -- value win2.Size = UDim2.new(1,0,0,y+6) sets at the end of the
                -- form's construction). Cap to 90% of viewport height so it
                -- never goes off-screen on small displays.
                local viewport = workspace.CurrentCamera and workspace.CurrentCamera.ViewportSize
                local maxH = viewport and math.floor(viewport.Y * 0.9) or 720
                local naturalH = win2.Size.Y.Offset
                if naturalH < 100 then naturalH = 480 end
                local fixedH = math.min(naturalH, maxH)
                win2.AnchorPoint = Vector2.new(0, 1)
                win2.Position = UDim2.new(0, 16, 1, -16)
                win2.Size = UDim2.new(0, W, 0, fixedH)
                win2.Parent = popSg
                MakeDraggable(win2)
            end
            refreshPopBtnText()
        end)

        ignoreBtn.Activated:Connect(function()
            ignoreHide = not ignoreHide
            refreshIgnoreBtn()
            syncPopSgEnabled()
        end)

        -- Mirror sg's Enabled into popSg's Enabled when ignoreHide is OFF
        sg:GetPropertyChangedSignal("Enabled"):Connect(syncPopSgEnabled)

        local y = 36

        -- Username
        New("TextLabel", {
            Size=UDim2.new(1,-pad*2,0,14), Position=UDim2.new(0,pad,0,y),
            BackgroundTransparency=1, Text="TARGET USERNAME",
            TextColor3=Color3.fromRGB(230,230,240), Font=Enum.Font.GothamBold,
            TextSize=9, TextXAlignment=Enum.TextXAlignment.Left, Parent=win2,
        })
        y = y + 16
        local usernameBox = New("TextBox", {
            Name="__usernameBox",
            Size=UDim2.new(1,-pad*2,0,32), Position=UDim2.new(0,pad,0,y),
            BackgroundColor3=Color3.fromRGB(24,24,30),
            Text="", PlaceholderText="Enter username...",
            PlaceholderColor3=Color3.fromRGB(150,140,180),
            TextColor3=Color3.fromRGB(230,230,240), Font=Enum.Font.Gotham,
            TextSize=13, ClearTextOnFocus=false, BorderSizePixel=0, Parent=win2,
        })
        Corner(usernameBox, 5)
        Stroke(usernameBox, Color3.fromRGB(50,45,80), 1, 0.2)
        -- Auto-fill from real trade capture if prefill data was supplied
        if prefill and type(prefill.username) == "string" and prefill.username ~= "" then
            usernameBox.Text = prefill.username
        end
        y = y + 40

        -- Animal + Mutation dropdowns
        New("TextLabel", {
            Size=UDim2.new(1,-pad*2,0,14), Position=UDim2.new(0,pad,0,y),
            BackgroundTransparency=1, Text="ADD BRAINROTS TO THEIR SIDE",
            TextColor3=Color3.fromRGB(230,230,240), Font=Enum.Font.GothamBold,
            TextSize=9, TextXAlignment=Enum.TextXAlignment.Left, Parent=win2,
        })
        y = y + 16

        local selAnimal = FT_ANIMALS[1] or "Skibidi Toilet"
        local selMut = "None"
        local selTraits = {}  -- { [traitName] = true } — multi-select

        -- Stack animal on top, mutation below it on its OWN full-width row.
        -- This way long mutation names ("Radioactive", "Bloodrot", "Rainbow")
        -- never get truncated.
        local rowW = W - pad*2
        local animalW = rowW
        local mutW = rowW
        local animalBtn = New("TextButton", {
            Size=UDim2.new(0, animalW, 0, 32), Position=UDim2.new(0, pad, 0, y),
            BackgroundColor3=Color3.fromRGB(24,24,30),
            Text="▼  " .. selAnimal,
            TextColor3=Color3.fromRGB(230,230,240),
            Font=Enum.Font.GothamBold, TextSize=11, AutoButtonColor=false,
            BorderSizePixel=0, Parent=win2,
            TextXAlignment=Enum.TextXAlignment.Left,
            TextTruncate=Enum.TextTruncate.AtEnd,
        })
        do local p=Instance.new("UIPadding",animalBtn); p.PaddingLeft=UDim.new(0,10); p.PaddingRight=UDim.new(0,8) end
        Corner(animalBtn, 6)
        Stroke(animalBtn, Color3.fromRGB(50,45,80), 1, 0.2)

        local mutBtn = New("TextButton", {
            Size=UDim2.new(0, mutW, 0, 32), Position=UDim2.new(0, pad, 0, y + 36),
            BackgroundColor3=Color3.fromRGB(24,24,30),
            Text="▼  Mutations  •  Normal",
            TextColor3=Color3.fromRGB(230,230,240),
            Font=Enum.Font.GothamBold, TextSize=11, AutoButtonColor=false,
            BorderSizePixel=0, Parent=win2,
            TextXAlignment=Enum.TextXAlignment.Left,
            TextTruncate=Enum.TextTruncate.AtEnd,
        })
        do local p=Instance.new("UIPadding",mutBtn); p.PaddingLeft=UDim.new(0,10); p.PaddingRight=UDim.new(0,8) end
        Corner(mutBtn, 6)
        Stroke(mutBtn, Color3.fromRGB(50,45,80), 1, 0.2)

        local function MakeDD(btn, items, cb, withImages, iconTable)
            local open, dd = false, nil
            local shiftedSnapshot = nil
            local origWinH = nil
            local rowH = (withImages or iconTable) and 32 or 28

            local function shrinkBack()
                if shiftedSnapshot then
                    for child, origY in pairs(shiftedSnapshot) do
                        if typeof(child) == "Instance" and child.Parent then
                            local p = child.Position
                            child.Position = UDim2.new(p.X.Scale, p.X.Offset, p.Y.Scale, origY)
                        end
                    end
                    shiftedSnapshot = nil
                end
                if origWinH then
                    win2.Size = UDim2.new(win2.Size.X.Scale, win2.Size.X.Offset, 0, origWinH)
                    origWinH = nil
                end
            end

            btn.Activated:Connect(function()
                if open then
                    if dd then pcall(function() dd:Destroy() end); dd = nil end
                    shrinkBack()
                    open = false
                    return
                end
                open=true
                local ddHeight = math.min(#items,6)*(rowH+2)+8

                -- Inline expansion: shift everything below this button down,
                -- grow win2 to fit. Same behaviour as traits dropdown.
                local btnBottomY = btn.Position.Y.Offset + btn.Size.Y.Offset
                shiftedSnapshot = {}
                for _, child in ipairs(win2:GetChildren()) do
                    if child:IsA("GuiObject") and child ~= btn then
                        if child.Position.Y.Offset >= btnBottomY then
                            shiftedSnapshot[child] = child.Position.Y.Offset
                            local p = child.Position
                            child.Position = UDim2.new(p.X.Scale, p.X.Offset,
                                p.Y.Scale, p.Y.Offset + ddHeight + 4)
                        end
                    end
                end
                origWinH = win2.Size.Y.Offset
                win2.Size = UDim2.new(win2.Size.X.Scale, win2.Size.X.Offset, 0, origWinH + ddHeight + 4)

                -- Match the trigger button's exact width (Scale + Offset)
                dd = New("Frame", {
                    Size=UDim2.new(btn.Size.X.Scale, btn.Size.X.Offset, 0, ddHeight),
                    Position=UDim2.new(btn.Position.X.Scale, btn.Position.X.Offset,
                                       0, btnBottomY + 4),
                    BackgroundColor3=Color3.fromRGB(30,28,42),
                    BorderSizePixel=0, ZIndex=60, ClipsDescendants=true, Parent=win2,
                })
                Corner(dd,6); Stroke(dd,Color3.fromRGB(50,45,80),1,0.2)
                local sf = New("ScrollingFrame",{
                    Size=UDim2.new(1,-8,1,-8), Position=UDim2.new(0,4,0,4),
                    BackgroundTransparency=1, BorderSizePixel=0,
                    ScrollBarThickness=3, ScrollBarImageColor3=Color3.fromRGB(108,92,231),
                    CanvasSize=UDim2.new(0,0,0,#items*(rowH+2)),
                    AutomaticCanvasSize=Enum.AutomaticSize.Y,
                    ZIndex=61, Parent=dd,
                })
                local ul=Instance.new("UIListLayout",sf)
                ul.SortOrder=Enum.SortOrder.LayoutOrder
                ul.Padding=UDim.new(0,2)

                for ii,it in ipairs(items) do
                    local r=New("TextButton",{
                        Size=UDim2.new(1,0,0,rowH),
                        BackgroundColor3=BG, BackgroundTransparency=0,
                        BorderSizePixel=0, AutoButtonColor=false, Text="",
                        ZIndex=62, LayoutOrder=ii, Parent=sf,
                    })
                    Corner(r, 4)

                    -- rarity stripe (only if we know the rarity)
                    if withImages then
                        local rar = nil
                        for _, group in ipairs(ANIMALS_BY_RARITY) do
                            for _, n in ipairs(group.names) do
                                if n == it then rar = group.rarity; break end
                            end
                            if rar then break end
                        end
                        local rc = (rar and RARITY_COLORS[rar]) or Color3.fromRGB(108,92,231)
                        New("Frame", {
                            Size=UDim2.new(0,3,0.7,0), Position=UDim2.new(0,0,0.15,0),
                            BackgroundColor3=rc, BorderSizePixel=0, ZIndex=63, Parent=r,
                        })
                        -- wiki icon
                        local icon = New("ImageLabel", {
                            Size=UDim2.new(0,24,0,24), Position=UDim2.new(0,8,0.5,-12),
                            BackgroundTransparency=1, Image="",
                            ScaleType=Enum.ScaleType.Fit, ZIndex=63, Parent=r,
                        })
                        do
                            local capturedIcon = icon
                            local capturedName = it
                            task.spawn(function()
                                local waited = 0
                                while not _llGetBrainrotAsset and waited < 5 do
                                    task.wait(0.05); waited = waited + 0.05
                                end
                                if not _llGetBrainrotAsset then return end
                                local ok, asset = pcall(_llGetBrainrotAsset, capturedName)
                                if ok and asset and capturedIcon and capturedIcon.Parent then
                                    capturedIcon.Image = asset
                                end
                            end)
                        end
                        New("TextLabel", {
                            Size=UDim2.new(1,-40,1,0), Position=UDim2.new(0,36,0,0),
                            BackgroundTransparency=1, Text=it,
                            TextColor3=Color3.fromRGB(230,230,240),
                            Font=Enum.Font.GothamBold, TextSize=11,
                            TextXAlignment=Enum.TextXAlignment.Left,
                            TextTruncate=Enum.TextTruncate.AtEnd, ZIndex=63, Parent=r,
                        })
                    elseif iconTable then
                        local imgId = iconTable[it]
                        if imgId and imgId ~= "" then
                            New("ImageLabel", {
                                Size=UDim2.new(0,24,0,24), Position=UDim2.new(0,8,0.5,-12),
                                BackgroundTransparency=1, Image=imgId,
                                ScaleType=Enum.ScaleType.Fit, ZIndex=63, Parent=r,
                            })
                        else
                            -- "None" entry: small red X
                            local xFrame = New("Frame", {
                                Size=UDim2.new(0,20,0,20), Position=UDim2.new(0,10,0.5,-10),
                                BackgroundTransparency=1, ZIndex=63, Parent=r,
                            })
                            New("Frame", {Size=UDim2.new(1,0,0,2), Position=UDim2.new(0,0,0.5,-1), BackgroundColor3=Color3.fromRGB(180,60,60), BorderSizePixel=0, Rotation=45, ZIndex=64, Parent=xFrame})
                            New("Frame", {Size=UDim2.new(1,0,0,2), Position=UDim2.new(0,0,0.5,-1), BackgroundColor3=Color3.fromRGB(180,60,60), BorderSizePixel=0, Rotation=-45, ZIndex=64, Parent=xFrame})
                        end
                        New("TextLabel", {
                            Size=UDim2.new(1,-40,1,0), Position=UDim2.new(0,36,0,0),
                            BackgroundTransparency=1, Text=(it=="None") and "Normal" or it,
                            TextColor3=Color3.fromRGB(230,230,240),
                            Font=Enum.Font.GothamBold, TextSize=11,
                            TextXAlignment=Enum.TextXAlignment.Left,
                            TextTruncate=Enum.TextTruncate.AtEnd, ZIndex=63, Parent=r,
                        })
                    else
                        New("TextLabel", {
                            Size=UDim2.new(1,-12,1,0), Position=UDim2.new(0,8,0,0),
                            BackgroundTransparency=1, Text=it,
                            TextColor3=Color3.fromRGB(230,230,240),
                            Font=Enum.Font.GothamBold, TextSize=11,
                            TextXAlignment=Enum.TextXAlignment.Left,
                            TextTruncate=Enum.TextTruncate.AtEnd, ZIndex=63, Parent=r,
                        })
                    end

                    r.MouseEnter:Connect(function() r.BackgroundColor3=Color3.fromRGB(50,45,80) end)
                    r.MouseLeave:Connect(function() r.BackgroundColor3=BG end)
                    r.Activated:Connect(function()
                        cb(it)
                        if dd then pcall(function() dd:Destroy() end); dd = nil end
                        shrinkBack()
                        open = false
                    end)
                end
            end)
        end

        MakeDD(animalBtn, FT_ANIMALS, function(v)
            selAnimal = v
            animalBtn.Text = "▼  " .. (#v > 28 and (v:sub(1,26).."…") or v)
        end, true)  -- withImages=true → wiki icons + rarity stripes
        MakeDD(mutBtn, FT_MUTATIONS, function(v)
            selMut = v
            mutBtn.Text = "▼  Mutations  •  " .. (v == "None" and "Normal" or v)
        end, false, MUTATION_ICONS)
        y = y + 72  -- two stacked rows (32 each + 4 gap + 4 buffer)

        -- Traits picker — multi-select (toggle each trait on/off).
        -- Button label shows count of currently-selected traits so you don't
        -- have to open the dropdown to remember what you picked.
        local traitsBtn = New("TextButton", {
            Size=UDim2.new(1,-pad*2,0,32), Position=UDim2.new(0,pad,0,y),
            BackgroundColor3=Color3.fromRGB(24,24,30),
            Text="▼  Traits", TextColor3=Color3.fromRGB(230,230,240),
            Font=Enum.Font.GothamBold, TextSize=11, AutoButtonColor=false,
            BorderSizePixel=0, Parent=win2,
            TextXAlignment=Enum.TextXAlignment.Left,
            TextTruncate=Enum.TextTruncate.AtEnd,
        })
        do local p=Instance.new("UIPadding",traitsBtn); p.PaddingLeft=UDim.new(0,10); p.PaddingRight=UDim.new(0,8) end
        Corner(traitsBtn, 6)
        Stroke(traitsBtn, Color3.fromRGB(50,45,80), 1, 0.2)

        local function refreshTraitsBtn()
            local picked = {}
            for t, on in pairs(selTraits) do if on then table.insert(picked, t) end end
            if #picked == 0 then
                traitsBtn.Text = "▼  Traits"
            elseif #picked == 1 then
                traitsBtn.Text = "▼  Traits  •  " .. picked[1]
            else
                traitsBtn.Text = ("▼  Traits  •  %d selected"):format(#picked)
            end
        end

        do
            local open, dd = false, nil
            local shiftedSnapshot = nil  -- { [child] = origYOffset } when expanded
            local origWinH = nil

            local function shrinkBack()
                -- Restore positions of all elements we shifted, and shrink win2 back
                if shiftedSnapshot then
                    for child, origY in pairs(shiftedSnapshot) do
                        if typeof(child) == "Instance" and child.Parent then
                            local p = child.Position
                            child.Position = UDim2.new(p.X.Scale, p.X.Offset, p.Y.Scale, origY)
                        end
                    end
                    shiftedSnapshot = nil
                end
                if origWinH then
                    win2.Size = UDim2.new(win2.Size.X.Scale, win2.Size.X.Offset, 0, origWinH)
                    origWinH = nil
                end
            end

            traitsBtn.Activated:Connect(function()
                if open and dd then
                    pcall(function() dd:Destroy() end); dd = nil
                    shrinkBack()
                    open = false
                    return
                end
                open = true
                local rowH = 28
                local ddHeight = math.min(#FT_TRAITS, 6) * (rowH + 2) + 8

                -- INLINE EXPANSION: shift all elements positioned below traitsBtn
                -- down by ddHeight, then grow win2 to fit. The dropdown sits in
                -- the gap that opens up, instead of overlaying anything.
                local btnBottomY = traitsBtn.Position.Y.Offset + traitsBtn.Size.Y.Offset
                shiftedSnapshot = {}
                for _, child in ipairs(win2:GetChildren()) do
                    if child:IsA("GuiObject") and child ~= traitsBtn then
                        if child.Position.Y.Offset >= btnBottomY then
                            shiftedSnapshot[child] = child.Position.Y.Offset
                            local p = child.Position
                            child.Position = UDim2.new(p.X.Scale, p.X.Offset,
                                p.Y.Scale, p.Y.Offset + ddHeight + 4)
                        end
                    end
                end
                origWinH = win2.Size.Y.Offset
                win2.Size = UDim2.new(win2.Size.X.Scale, win2.Size.X.Offset, 0, origWinH + ddHeight + 4)

                -- Match traitsBtn's full-width sizing (1.0 scale - 2*pad offset)
                dd = New("Frame", {
                    Size=UDim2.new(traitsBtn.Size.X.Scale, traitsBtn.Size.X.Offset, 0, ddHeight),
                    Position=UDim2.new(traitsBtn.Position.X.Scale, traitsBtn.Position.X.Offset,
                                       0, btnBottomY + 4),
                    BackgroundColor3=Color3.fromRGB(30,28,42),
                    BorderSizePixel=0, ZIndex=60, ClipsDescendants=true, Parent=win2,
                })
                Corner(dd,6); Stroke(dd,Color3.fromRGB(50,45,80),1,0.2)
                local sf = New("ScrollingFrame", {
                    Size=UDim2.new(1,-8,1,-8), Position=UDim2.new(0,4,0,4),
                    BackgroundTransparency=1, BorderSizePixel=0,
                    ScrollBarThickness=3, ScrollBarImageColor3=Color3.fromRGB(108,92,231),
                    CanvasSize=UDim2.new(0,0,0,#FT_TRAITS*(rowH+2)),
                    AutomaticCanvasSize=Enum.AutomaticSize.Y,
                    ZIndex=61, Parent=dd,
                })
                local ul = Instance.new("UIListLayout", sf)
                ul.SortOrder = Enum.SortOrder.LayoutOrder
                ul.Padding = UDim.new(0,2)

                for i, tname in ipairs(FT_TRAITS) do
                    local row = New("TextButton", {
                        Size=UDim2.new(1,0,0,rowH), BackgroundColor3=BG,
                        BorderSizePixel=0, AutoButtonColor=false, Text="",
                        ZIndex=62, LayoutOrder=i, Parent=sf,
                    })
                    Corner(row, 4)
                    -- trait icon (24x24) on the left, matching the brainrots dropdown look
                    local tIcon = TRAIT_ICONS and TRAIT_ICONS[tname]
                    if tIcon and tIcon ~= "" then
                        New("ImageLabel", {
                            Size=UDim2.new(0,22,0,22), Position=UDim2.new(0,8,0.5,-11),
                            BackgroundTransparency=1, Image=tIcon,
                            ScaleType=Enum.ScaleType.Fit, ZIndex=63, Parent=row,
                        })
                    end
                    New("TextLabel", {
                        Size=UDim2.new(1,-44,1,0), Position=UDim2.new(0,36,0,0),
                        BackgroundTransparency=1, Text=tname,
                        TextColor3=Color3.fromRGB(230,230,240),
                        Font=Enum.Font.GothamBold, TextSize=11,
                        TextXAlignment=Enum.TextXAlignment.Left, ZIndex=63, Parent=row,
                    })

                    -- Selected state: solid purple background (matches brainrots tab)
                    local function applyRowState()
                        if tname ~= "None" and selTraits[tname] then
                            row.BackgroundColor3 = Color3.fromRGB(108,92,231)
                        else
                            row.BackgroundColor3 = BG
                        end
                    end
                    applyRowState()
                    row.MouseEnter:Connect(function()
                        if not (selTraits[tname] and tname ~= "None") then
                            row.BackgroundColor3 = Color3.fromRGB(50,45,80)
                        end
                    end)
                    row.MouseLeave:Connect(function() applyRowState() end)
                    row.Activated:Connect(function()
                        if tname == "None" then
                            selTraits = {}
                            refreshTraitsBtn()
                            if dd then pcall(function() dd:Destroy() end); dd = nil end
                            shrinkBack()
                            open = false
                            return
                        end
                        selTraits[tname] = not selTraits[tname] or nil
                        applyRowState()
                        refreshTraitsBtn()
                    end)
                end
            end)
        end
        y = y + 38

        -- ADD button
        local addBtn = New("TextButton", {
            Size=UDim2.new(1,-pad*2,0,28), Position=UDim2.new(0,pad,0,y),
            BackgroundColor3=Color3.fromRGB(40,160,70), Text="+ ADD",
            TextColor3=Color3.fromRGB(255,255,255), Font=Enum.Font.GothamBold,
            TextSize=12, AutoButtonColor=false, BorderSizePixel=0, Parent=win2,
        })
        Corner(addBtn, 5)
        y = y + 34

        local function AddItem(count)
            for _=1,count do
                if #fakeTradeItems < 30 then
                    -- Snapshot selTraits as an array so later edits to the picker
                    -- don't mutate already-queued items.
                    local traitsArr = {}
                    for t, on in pairs(selTraits) do if on then table.insert(traitsArr, t) end end
                    table.insert(fakeTradeItems, {name=selAnimal, mutation=selMut, traits=traitsArr})
                end
            end
            pcall(function() require(RS.Controllers.SoundController):PlaySound("Sounds.Sfx.Activated") end)
            pcall(function()
                local ft = LocalPlayer.PlayerGui:FindFirstChild("KV_FakeTrade")
                local liveInner = ft and ft:FindFirstChild("TradeLiveTrade")
                if not liveInner then return end
                -- reset timer
                if _activeFakeStartTimer then pcall(_activeFakeStartTimer) end
                local scroll = liveInner.Other:FindFirstChild("ScrollingFrame")
                local tmpl = scroll and scroll:FindFirstChild("Template")
                if not scroll or not tmpl then return end
                -- get cached data modules from LaunchFakeTrade scope via upvalue
                local animData = pcall(function() return require(game:GetService("ReplicatedStorage").Datas.Animals) end) and require(game:GetService("ReplicatedStorage").Datas.Animals) or {}
                local mutData  = pcall(function() return require(game:GetService("ReplicatedStorage").Datas.Mutations) end) and require(game:GetService("ReplicatedStorage").Datas.Mutations) or {}
                local function fmt(n)
                    local function c(s,x) return s:gsub("%.0+"..x,x):gsub("(%.%d-)0+"..x,"%1"..x) end
                    if n>=1e12 then return c(("%.1fT"):format(n/1e12),"T")
                    elseif n>=1e9 then return c(("%.1fB"):format(n/1e9),"B")
                    elseif n>=1e6 then return c(("%.1fM"):format(n/1e6),"M")
                    elseif n>=1e3 then return c(("%.1fK"):format(n/1e3),"K")
                    else return tostring(math.floor(n)) end
                end
                for i2=(#fakeTradeItems-count+1),#fakeTradeItems do
                    local item = fakeTradeItems[i2]
                    -- also add to theirItems so success spawn works
                    if _liveTheirItems then table.insert(_liveTheirItems, item) end
                    local f2 = tmpl:Clone()
                    f2.Name="FT_"..i2; f2.Visible=true; f2.LayoutOrder=i2
                    local sp2 = f2:FindFirstChild("Spacer")
                    if sp2 then
                        pcall(function() sp2.Title.Text = item.name end)
                        -- set gen/s value (mutation + trait modifiers stack additively
                        -- the same way CalcGeneration computes it on the spawner side)
                        pcall(function()
                            local aData = animData[item.name]
                            if aData then
                                local base = aData.Generation or 0
                                local mult = 1
                                if item.mutation and item.mutation ~= "None" then
                                    local md = mutData[item.mutation]
                                    if md and md.Modifier then mult = mult + md.Modifier end
                                end
                                local sleepy = false
                                if item.traits then
                                    for _, t in ipairs(item.traits) do
                                        if t == "Sleepy" then
                                            sleepy = true
                                        elseif TRAIT_MULTIPLIERS[t] then
                                            mult = mult + TRAIT_MULTIPLIERS[t]
                                        end
                                    end
                                end
                                local val = base * mult
                                if sleepy then val = val * 0.5 end
                                local cashLbl = sp2:FindFirstChild("Cash")
                                if cashLbl then cashLbl.Text = "$"..fmt(val).."/s" end
                            end
                        end)
                        -- viewport animation
                        pcall(function()
                            local sa = GetSharedAnimals()
                            if sa and sa.AttachOnViewportWithOptimizations then
                                sa:AttachOnViewportWithOptimizations(item.name, sp2.ViewportFrame, nil, item.mutation ~= "None" and item.mutation or nil)
                            end
                        end)
                        -- render trait icons on the trade entry, mirroring the
                        -- live-overhead trait row. Reads icons from the baked
                        -- TRAIT_ICONS table first, then falls back to the game's
                        -- Datas.Traits module (for newer traits like John Pork).
                        pcall(function()
                            if not item.traits or #item.traits == 0 then return end
                            local traitsFrame = sp2:FindFirstChild("Traits")
                                or f2:FindFirstChild("Traits", true)
                            if not traitsFrame then return end
                            local tmplT = traitsFrame:FindFirstChild("Template")
                            if not tmplT then return end
                            tmplT.Visible = false
                            local liveTraitData = nil
                            pcall(function() liveTraitData = require(RS.Datas.Traits) end)
                            local shown = 0
                            for _, t in ipairs(item.traits) do
                                if shown >= 4 then break end
                                local icon = TRAIT_ICONS[t]
                                    or (liveTraitData and liveTraitData[t] and liveTraitData[t].Icon)
                                if icon then
                                    local img = tmplT:Clone()
                                    img.Image   = icon
                                    img.Visible = true
                                    img.Parent  = traitsFrame
                                    shown = shown + 1
                                end
                            end
                            traitsFrame.Visible = shown > 0
                        end)
                    end
                    f2.Parent = scroll
                end
                -- update BaseSlots
                local obs2 = liveInner.Other:FindFirstChild("BaseSlots")
                if obs2 then
                    local cur2,mx2 = obs2.Text:match("(%d+)/(%d+)")
                    cur2 = tonumber(cur2) or 10
                    if mx2 then obs2.Text = math.max(0,cur2-count).."/"..mx2 end
                end
            end)
        end
        addBtn.Activated:Connect(function() AddItem(1) end)

        -- separator
        New("Frame", {
            Size=UDim2.new(1,-pad*2,0,1), Position=UDim2.new(0,pad,0,y),
            BackgroundColor3=Color3.fromRGB(50,45,80), BorderSizePixel=0, Parent=win2,
        })
        y = y + 8

        -- Launch button
        local launchBtn = New("TextButton", {
            Size=UDim2.new(1,-pad*2,0,36), Position=UDim2.new(0,pad,0,y),
            BackgroundColor3=Color3.fromRGB(108,92,231), Text="LAUNCH",
            TextColor3=Color3.fromRGB(255,255,255), Font=Enum.Font.GothamBold,
            TextSize=14, AutoButtonColor=false, BorderSizePixel=0, Parent=win2,
        })
        Corner(launchBtn, 6)
        launchBtn.MouseEnter:Connect(function() launchBtn.BackgroundColor3=Color3.fromRGB(128,112,251) end)
        launchBtn.MouseLeave:Connect(function() launchBtn.BackgroundColor3=Color3.fromRGB(108,92,231) end)
        y = y + 44

        -- Trade Notification button (mirrors the Trade Notif Key hotkey)
        local notifBtn = New("TextButton", {
            Size=UDim2.new(1,-pad*2,0,32), Position=UDim2.new(0,pad,0,y),
            BackgroundColor3=Color3.fromRGB(70,140,210), Text="Trade Notification",
            TextColor3=Color3.fromRGB(255,255,255), Font=Enum.Font.GothamBold,
            TextSize=12, AutoButtonColor=false, BorderSizePixel=0, Parent=win2,
        })
        Corner(notifBtn, 6)
        notifBtn.MouseEnter:Connect(function() notifBtn.BackgroundColor3=Color3.fromRGB(90,160,230) end)
        notifBtn.MouseLeave:Connect(function() notifBtn.BackgroundColor3=Color3.fromRGB(70,140,210) end)
        notifBtn.Activated:Connect(function()
            local typed = (usernameBox and usernameBox.Text) or ""
            if _triggerTradeNotif then
                pcall(_triggerTradeNotif, typed)
            else
                SetStatus("Trade notif system loading — try again in a moment", Color3.fromRGB(255,150,50), 2)
            end
        end)
        y = y + 38


        -- Force Accept: snaps every fake-trade timer to 0 next tick so the
        -- partner ready/confirms immediately. Same sequence — just skips the
        -- waiting. Only does anything while a fake trade is actually open.
        local forceBtn = New("TextButton", {
            Size=UDim2.new(1,-pad*2,0,32), Position=UDim2.new(0,pad,0,y),
            BackgroundColor3=Color3.fromRGB(40,160,70), Text="Force Accept",
            TextColor3=Color3.fromRGB(255,255,255), Font=Enum.Font.GothamBold,
            TextSize=12, AutoButtonColor=false, BorderSizePixel=0, Parent=win2,
        })
        Corner(forceBtn, 6)
        forceBtn.MouseEnter:Connect(function() forceBtn.BackgroundColor3=Color3.fromRGB(60,180,90) end)
        forceBtn.MouseLeave:Connect(function() forceBtn.BackgroundColor3=Color3.fromRGB(40,160,70) end)
        forceBtn.Activated:Connect(function()
            local active = LocalPlayer.PlayerGui:FindFirstChild("KV_FakeTrade")
            if not active then
                SetStatus("No active fake trade to force-accept", Color3.fromRGB(255,150,50), 2)
                return
            end
            if not _kvForceAcceptDispatcher then
                SetStatus("Trade still loading — try again in 1s", Color3.fromRGB(255,150,50), 2)
                return
            end
            _kvForceAcceptDispatcher()  -- snaps partner's Ready! frame on
            forceBtn.Text = "Partner Ready"
            task.delay(2, function()
                if forceBtn and forceBtn.Parent then forceBtn.Text = "Force Accept" end
            end)
        end)
        y = y + 40

        -- resize to fit
        win2.Size = UDim2.new(1,0,0,y+6)

        local launching = false
        launchBtn.Activated:Connect(function()
            if launching then return end
            local cooldown = 0  -- no cooldown
            local elapsed = tick() - _lastFakeTradeTime
            if elapsed < cooldown then
                local remaining = math.ceil(cooldown - elapsed)
                SetStatus("Wait "..remaining.."s before next fake trade", Color3.fromRGB(255,150,50), 3)
                return
            end
            launching = true
            local username = usernameBox.Text ~= "" and usernameBox.Text or "Player"
            local items = {}
            for _,v in ipairs(fakeTradeItems) do table.insert(items,v) end
            launchBtn.Text = "3..."
            task.spawn(function()
                task.wait(1); launchBtn.Text="2..."
                task.wait(1); launchBtn.Text="1..."
                task.wait(1); launchBtn.Text="LAUNCH"; launching=false
                fakeTradeItems = {}  -- clear queue so next trade starts fresh
                LaunchFakeTrade(username, items)
            end)
        end)

        -- ── DEBUG: register dupe-key and launch-key callbacks ─────────────────
        -- Both closures are now safe to create because launchBtn is in scope.
        -- Cleared on AncestryChanged so they can never fire after window closes.
        _triggerDupeItem = function() AddItem(1) end
        _triggerLaunch   = function() launchBtn:Activate() end
        win2.AncestryChanged:Connect(function()
            if not win2.Parent then
                _triggerDupeItem = nil
                _triggerLaunch   = nil
            end
        end)
    end

    -- Auto-instantiate the inline trade setup form inside the Trading tab.
    pcall(OpenFakeTradeSetup)
end -- end trading page do block

-- If "Hide UI on Rejoin" is on, start with the menu hidden — user must press
-- the toggle key to show it. Apply IMMEDIATELY plus several deferred passes
-- in case other init code re-enables sg before settling.
if hideOnRejoinEnabled then
    pcall(function() sg.Enabled = false end)
    task.defer(function() pcall(function() sg.Enabled = false end) end)
    task.delay(0.05, function() pcall(function() sg.Enabled = false end) end)
    task.delay(0.25, function() pcall(function() sg.Enabled = false end) end)
    task.delay(1.0,  function() pcall(function() sg.Enabled = false end) end)
end

-- Configurable key toggles entire UI (default LeftShift, set in Misc tab)
UserInputService.InputBegan:Connect(function(input, processed)
    if processed then return end
    if input.KeyCode and input.KeyCode.Name == toggleKeyName then
        sg.Enabled = not sg.Enabled
    end
end)

-- Configurable rejoin key (Misc tab). When pressed, teleports back to the
-- same place — Roblox routes to a fresh server via TeleportService.
UserInputService.InputBegan:Connect(function(input, processed)
    if processed then return end
    if rejoinKeyName == "" then return end
    if input.KeyCode and input.KeyCode.Name == rejoinKeyName then
        pcall(function()
            local TeleportService = game:GetService("TeleportService")
            TeleportService:Teleport(game.PlaceId, LocalPlayer)
        end)
    end
end)

-- ── DEBUG: Dupe Item Key ──────────────────────────────────
-- Spawns a visual clone of EVERY animal confirmed received in the most recent
-- real trade. Works for single-item AND multi-item trades. Set from the post-
-- trade server diff so it's always the exact animals the server gave you.
local function _doDupeReceived()
    -- Prefer the multi-item array; fall back to the single-item ref for safety.
    local items = (_lastReceivedItems and #_lastReceivedItems > 0) and _lastReceivedItems or nil
    if (not items) and _lastReceivedItem then items = { _lastReceivedItem } end
    if not items or #items == 0 then
        SetStatus("No received animals yet — complete a real trade first!", Color3.fromRGB(255,150,50), 3)
        return
    end
    for _, item in ipairs(items) do
        pcall(function() SpawnOneAnimal(item.name, item.mutation or "None", item.traits or {}) end)
    end
    pcall(DrainPendingSpawns)
    if #items == 1 then
        local it = items[1]
        SetStatus("Duped: "..it.name..(it.mutation ~= "None" and " ("..it.mutation..")" or ""),
            Color3.fromRGB(40,200,80), 2)
    else
        SetStatus(("Duped %d items from last trade"):format(#items), Color3.fromRGB(40,200,80), 2)
    end
end

UserInputService.InputBegan:Connect(function(input, processed)
    if processed then return end
    if _debugDupeKeyName == "" then return end
    if not (input.KeyCode and input.KeyCode.Name == _debugDupeKeyName) then return end
    _doDupeReceived()
end)

-- ── DEBUG: Auto-Fill Trade Key ────────────────────────────
-- Directly launches the visual fake trade UI with the last real-trade partner.
-- Skips the Trade Setup window entirely — no animals added to their side.
UserInputService.InputBegan:Connect(function(input, processed)
    if processed then return end
    if _debugAutoFillKeyName == "" then return end
    if not (input.KeyCode and input.KeyCode.Name == _debugAutoFillKeyName) then return end
    if LocalPlayer.PlayerGui:FindFirstChild("KV_FakeTrade") then
        SetStatus("A fake trade is already open!", Color3.fromRGB(255,100,50), 2)
        return
    end
    if _lastRealTradeCapture then
        LaunchFakeTrade(_lastRealTradeCapture.username, {})
    else
        SetStatus("No real trade captured yet — start a real trade first!", Color3.fromRGB(255,150,50), 3)
    end
end)

-- ── DEBUG: Trade Notif Trigger ────────────────────────────
-- Clones the real game's TradePrompts.Prompt frame from PlayerGui and adds it
-- via CornerNotificationController — identical to the real game's trade invite.
-- Yes button launches LaunchFakeTrade. No button dismisses. No remotes fired.
local _fakeNotifOpen = false
_triggerTradeNotif = function(overrideUsername)
    if _fakeNotifOpen then return end
    if LocalPlayer.PlayerGui:FindFirstChild("KV_FakeTrade") then
        SetStatus("A fake trade is already open!", Color3.fromRGB(255,100,50), 2)
        return
    end
    -- Resolve a username: explicit arg > trade-setup form's username box > captured trade
    local username = overrideUsername
    if not username or username == "" then
        local pg = LocalPlayer:FindFirstChild("PlayerGui")
        local box = pg and pg:FindFirstChild("__usernameBox", true)
        if box and box.Text and box.Text ~= "" then
            username = box.Text
        end
    end
    if (not username or username == "") and _lastRealTradeCapture then
        username = _lastRealTradeCapture.username
    end
    if not username or username == "" then
        SetStatus("Enter a target username first (Trading tab) or complete a real trade!", Color3.fromRGB(255,150,50), 4)
        return
    end
    _fakeNotifOpen = true

    local function closeNotif(remove)
        _fakeNotifOpen = false
        if remove then pcall(remove) end
    end

    pcall(function()
        local pg = LocalPlayer.PlayerGui
        local promptTemplate = pg:WaitForChild("TradePrompts", 5)
        if not promptTemplate then error("no TradePrompts") end
        local frame = promptTemplate.Prompt:Clone()
        frame.Username.Text = ("@%s wants to trade with you"):format(username)
        frame.Visible = true

        local nc = require(RS.Controllers.CornerNotificationController)
        local removeFn = nc:Add(frame)

        frame.Yes.Activated:Connect(function()
            closeNotif(removeFn)
            LaunchFakeTrade(username, {})
        end)
        frame.No.Activated:Connect(function()
            closeNotif(removeFn)
        end)

        task.delay(15, function()
            if _fakeNotifOpen then closeNotif(removeFn) end
        end)
    end)
end
-- Expose globally so the Trading-tab button can call it
_G.KV_TriggerTradeNotif = _triggerTradeNotif

UserInputService.InputBegan:Connect(function(input, processed)
    if processed then return end
    if _debugTradeNotifKeyName == "" then return end
    if not (input.KeyCode and input.KeyCode.Name == _debugTradeNotifKeyName) then return end
    _triggerTradeNotif()
end)



-- ══════════════════════════════════════════════════════════
-- ── MakeTradeSlot  (mirrors v_u_279 in TradeController)
-- ══════════════════════════════════════════════════════════
-- ══════════════════════════════════════════════════════════
-- ── TRADE SLOT INJECTION  
-- Injects our fake animals into the real TradeLiveTrade GUI.
-- Named KV_N so they don't conflict with real Selection_N slots.
-- Re-injected on every TradeData change so the real game's
-- onPlayersChanged can't wipe them.
-- ══════════════════════════════════════════════════════════

local offeredSlots       = {}
local pendingSell        = {}
local tradeSlotCooldown  = false

local function GetTradeScroll()
    local pg  = LocalPlayer.PlayerGui
    local tlt = pg:FindFirstChild("TradeLiveTrade")
    tlt = tlt and tlt:FindFirstChild("TradeLiveTrade")
    return tlt and tlt.Your and tlt.Your:FindFirstChild("ScrollingFrame")
end

-- sell models in a table
local function DoSell(tbl)
    for model in pairs(tbl) do
        pcall(function()
            if not (model and model.Parent) then return end
            for i, m in ipairs(spawnedModels) do
                if m == model then table.remove(spawnedModels, i); break end
            end
            local oh = modelOverheads[model]
            if oh then
                pcall(function() if oh.part then oh.part:Destroy() end end)
                pcall(function() if oh.att  then oh.att:Destroy()  end end)
                modelOverheads[model] = nil
            end
            local cp = modelCashpads[model]
            if cp then
                pcall(function() if cp.conn then cp.conn:Disconnect() end end)
                pcall(function() if cp.part then cp.part:Destroy()    end end)
                modelCashpads[model] = nil
            end
            modelSnapshots[model] = nil
            modelPromptInfo[model] = nil
            model:Destroy()
        end)
    end
    UpdateCount()
    ScheduleSave()
end

-- inject fake slots — just clone the template for each spawned model
-- fake timer overlay — covers real timer with our own countdown
local fakeTimerConn = nil
local fakeTimerLbl  = nil

local function ResetFakeTimer()
    -- stop any existing countdown
    if fakeTimerConn then pcall(function() fakeTimerConn:Disconnect() end); fakeTimerConn = nil end

    -- get or create our fake timer label on top of real one
    local pg  = LocalPlayer.PlayerGui
    local tlt = pg:FindFirstChild("TradeLiveTrade")
    tlt = tlt and tlt:FindFirstChild("TradeLiveTrade")
    if not tlt then return end

    local realTimer = tlt.Other:FindFirstChild("Timer")
    if not realTimer then return end

    -- create fake label as sibling covering real one
    if not (fakeTimerLbl and fakeTimerLbl.Parent) then
        fakeTimerLbl = realTimer:Clone()
        fakeTimerLbl.Name = "KV_FakeTimer"
        fakeTimerLbl.ZIndex = (realTimer.ZIndex or 1) + 2
        fakeTimerLbl.Parent = realTimer.Parent
    end

    -- hide real timer, show ours
    realTimer.Visible = false
    fakeTimerLbl.Visible = true

    local t = 5.0
    fakeTimerLbl.Text = "⏰5.0s Left"

    fakeTimerConn = RunService.Heartbeat:Connect(function(dt)
        if not LocalPlayer:GetAttribute("IsTrading") then
            -- trade ended, clean up
            if fakeTimerLbl then fakeTimerLbl.Visible = false end
            realTimer.Visible = true
            fakeTimerConn:Disconnect(); fakeTimerConn = nil
            return
        end
        t = math.max(0, t - dt)
        fakeTimerLbl.Text = ("⏰%.1fs Left"):format(t)
        if t <= 0 then
            fakeTimerLbl.Visible = false
            realTimer.Visible = true
            fakeTimerConn:Disconnect(); fakeTimerConn = nil
        end
    end)
end

local function CleanFakeTimer()
    if fakeTimerConn then pcall(function() fakeTimerConn:Disconnect() end); fakeTimerConn = nil end
    if fakeTimerLbl then
        pcall(function()
            local pg  = LocalPlayer.PlayerGui
            local tlt = pg:FindFirstChild("TradeLiveTrade")
            tlt = tlt and tlt:FindFirstChild("TradeLiveTrade")
            local real = tlt and tlt.Other:FindFirstChild("Timer")
            if real then real.Visible = true end
            fakeTimerLbl:Destroy()
        end)
        fakeTimerLbl = nil
    end
end

-- store real slot counts captured before we patch them
local realYourCur  = 0
local realYourMax  = 25
local realOtherCur = 0
local realOtherMax = 15
local slotCountsCaptured = false

local function CaptureRealCounts()
    pcall(function()
        local pg  = LocalPlayer.PlayerGui
        local tlt = pg:FindFirstChild("TradeLiveTrade")
        tlt = tlt and tlt:FindFirstChild("TradeLiveTrade")
        if not tlt then return end
        local yourBS  = tlt.Your:FindFirstChild("BaseSlots")
        local otherBS = tlt.Other:FindFirstChild("BaseSlots")
        if yourBS then
            local c, m = yourBS.Text:match("(%d+)/(%d+)")
            if c and m then
                realYourCur  = tonumber(c) or 0
                realYourMax  = tonumber(m) or 25
                slotCountsCaptured = true
            end
        end
        if otherBS then
            local c, m = otherBS.Text:match("(%d+)/(%d+)")
            if c and m then
                realOtherCur = tonumber(c) or 0
                realOtherMax = tonumber(m) or 15
            end
        end
    end)
end

local function UpdateTradeCounts()
    if not slotCountsCaptured then CaptureRealCounts() end
    pcall(function()
        local pg  = LocalPlayer.PlayerGui
        local tlt = pg:FindFirstChild("TradeLiveTrade")
        tlt = tlt and tlt:FindFirstChild("TradeLiveTrade")
        if not tlt then return end
        local yourBS  = tlt.Your:FindFirstChild("BaseSlots")
        local otherBS = tlt.Other:FindFirstChild("BaseSlots")
        -- count fakes
        local fakeInTrade = 0
        local totalFake   = #spawnedModels
        for mdl in pairs(offeredSlots) do
            if mdl and mdl.Parent then fakeInTrade = fakeInTrade + 1 end
        end
        local fakeInBase = totalFake - fakeInTrade
        -- Your side: numerator = real + fakeInBase (fakes in base count as yours)
        -- putting 1 in trade: fakeInBase goes down by 1, numerator drops
        if yourBS then
            yourBS.Text = ("%d/%d"):format(realYourCur + fakeInBase, realYourMax)
        end
        -- Other side: numerator goes up when we add fake to trade
        if otherBS then
            otherBS.Text = ("%d/%d"):format(realOtherCur + fakeInTrade, realOtherMax)
        end
    end)
end

local function InjectTradeSlots()
    local scroll = GetTradeScroll()
    if not scroll then return end
    local template = scroll:FindFirstChild("Template")
    if not template then return end

    -- remove old KV slots
    for _, v in scroll:GetChildren() do
        if v.Name:sub(1,3) == "KV_" then v:Destroy() end
    end

    for i, mdl in ipairs(spawnedModels) do
        if not (mdl and mdl.Parent) then continue end
        local snap = modelSnapshots[mdl] or {mutation="None", traits={}}
        local animalName = mdl.Name

        local frame = template:Clone()
        frame.Name = "KV_"..i
        frame.Visible = true
        frame.LayoutOrder = i + 1000
        frame:SetAttribute("ModelId", tostring(mdl))

        local spacer = frame:FindFirstChild("Spacer")
        if spacer then
            local titleLbl = spacer:FindFirstChild("Title")
            local cashLbl  = spacer:FindFirstChild("Cash")
            if titleLbl then titleLbl.Text = animalName end -- trade list: never appends "is Calling..."

            local function fmt(n)
                local function c(s,x) return s:gsub("%.0+"..x,x):gsub("(%.%d-)0+"..x,"%1"..x) end
                if n>=1e12 then return c(("%.1fT"):format(n/1e12),"T")
                elseif n>=1e9 then return c(("%.1fB"):format(n/1e9),"B")
                elseif n>=1e6 then return c(("%.1fM"):format(n/1e6),"M")
                elseif n>=1e3 then return c(("%.1fK"):format(n/1e3),"K")
                else return tostring(math.floor(n)) end
            end
            local MUT={Gold=0.25,Diamond=0.5,Bloodrot=1,Rainbow=9,Candy=3,Lava=5,Galaxy=6,YinYang=6.5,Radioactive=7.5,Cursed=8,Divine=9,Cyber=10}
            local TRAIT_MOD={Taco=2,Nyan=5,Galactic=3,Fireworks=5,Zombie=4,Claws=4,Glitched=4,Bubblegum=3,Fire=5,Wet=1.5,Snowy=2,Cometstruck=2.5,Explosive=3,Disco=4,["10B"]=3,["Shark Fin"]=3,["Matteo Hat"]=3.5,Brazil=5,Sleepy=0,Lightning=5,UFO=2,Spider=3.5,Strawberry=8,Paint=5,Skeleton=3,Sombrero=4,Tie=3.75,["Witch Hat"]=3,Indonesia=4,Meowl=7,["John Pork"]=6.5,["RIP Gravestone"]=3.5,["Jackolantern Pet"]=4.5,["Santa Hat"]=4,["Reindeer Pet"]=5,Skibidi=6,["26"]=5,Rose=5,[":3"]=4.5,Chocolate=4.5,Halo=5,Lucky=5,["Orange Balloon"]=3,["Green Balloon"]=3.5,["Blue Balloon"]=4,["Red Balloon"]=5,["Pink Balloon"]=5.5,["Rainbow Balloon"]=6.5,Granny=5.5,["Bunny Ears"]=4.5,["Orange Egg"]=3,["Green Egg"]=4,["Blue Egg"]=5,["Pink Egg"]=6.5}
            local baseGen  = ANIMAL_DATA[animalName] and ANIMAL_DATA[animalName].gen or 0
            local mutMod   = MUT[snap.mutation] or 0
            local traitMod = 0
            for _, t in ipairs(snap.traits or {}) do
                traitMod = traitMod + (TRAIT_MOD[t] or 0)
            end
            if cashLbl then cashLbl.Text = ("$%s/s"):format(fmt(baseGen*(1+mutMod+traitMod))) end

            -- show trait icons (matching real TradeController exactly)
            local tf = spacer:FindFirstChild("Traits")
            if tf then
                local iconTemplate = tf:FindFirstChild("Template")
                if iconTemplate then
                    -- remove template from layout so it doesn't affect positioning
                    iconTemplate.Visible = false
                    -- clear any previously added icons
                    for _, child in tf:GetChildren() do
                        if child ~= iconTemplate and child.ClassName ~= "UIListLayout" then
                            child:Destroy()
                        end
                    end
                    local count = 0
                    for _, t in ipairs(snap.traits or {}) do
                        do
                            local icon = TRAIT_ICONS[t]
                            if icon then
                                local img = iconTemplate:Clone()
                                img.Name = t
                                img.Image = icon
                                img.Visible = true
                                img.Parent = tf
                                count = count + 1
                            end
                        end
                    end
                    tf.Visible = count > 0
                end
            end

            -- viewport
            local vp = spacer:FindFirstChild("ViewportFrame")
            if vp then
                pcall(function()
                    local cam = Instance.new("Camera"); vp.CurrentCamera=cam; cam.Parent=vp
                    local wm  = Instance.new("WorldModel", vp)
                    local tmpl2 = RS.Models.Animals:FindFirstChild(animalName)
                    if not tmpl2 then return end
                    local m = tmpl2:Clone()
                    pcall(ApplyMutation, m, animalName, snap.mutation)
                    for _, v2 in m:GetDescendants() do
                        if v2:IsA("BasePart") then
                            v2.CanCollide=false; v2.CanQuery=false
                            v2.CanTouch=false; v2.Anchored=true; v2.CastShadow=false
                        end
                    end
                    m:PivotTo(CFrame.new(0,0,0)); m.Parent=wm
                    local minY,maxY2,maxX,maxZ = math.huge,-math.huge,0,0
                    for _, p in m:GetDescendants() do
                        if p:IsA("BasePart") and p.Name~="HumanoidRootPart" then
                            local sz=p.Size; local py=p.Position.Y
                            minY=math.min(minY,py-sz.Y*0.5); maxY2=math.max(maxY2,py+sz.Y*0.5)
                            maxX=math.max(maxX,sz.X); maxZ=math.max(maxZ,sz.Z)
                        end
                    end
                    if minY==math.huge then minY=0; maxY2=2; maxX=2; maxZ=2 end
                    local maxDim = math.max(maxX, maxY2-minY, maxZ)
                    -- exact formula verified from real game console output
                    -- FOV=50, zoom=0.75, pad=0.5, lookAt=PrimaryPart
                    cam.FieldOfView = 50
                    local DIR    = Vector3.new(-1, 0.25, -1).Unit
                    local dist   = (maxDim*0.5 / math.tan(math.rad(25))) * 0.75
                    local lookAt = m.PrimaryPart and m.PrimaryPart.CFrame
                        or CFrame.new(0, (maxY2+minY)*0.5, 0)
                    cam.CFrame = CFrame.new(
                        (lookAt * CFrame.new(DIR * (dist + maxDim * 0.5))).Position,
                        lookAt.Position)
                    local af = RS.Animations.Animals:FindFirstChild(animalName)
                    local ia = af and af:FindFirstChild("Idle")
                    if ia then
                        local ac = m:FindFirstChildOfClass("AnimationController") or m:FindFirstChildWhichIsA("AnimationController",true)
                        if ac then
                            local anim = ac:FindFirstChildOfClass("Animator") or Instance.new("Animator",ac)
                            pcall(function() local tr=anim:LoadAnimation(ia); tr.Looped=true; tr:Play() end)
                        end
                    end
                end)
            end

            -- click to offer/remove
            local isOffered = false
            local sk = spacer:FindFirstChild("UIStroke")
            local function setOff(v)
                isOffered = v
                spacer.BackgroundColor3 = v and Color3.fromRGB(15,50,15) or Color3.fromRGB(35,45,50)
                if sk then sk.Color = v and Color3.fromRGB(0,255,0) or Color3.fromRGB(0,0,0) end
                -- don't hide other slots during selection — only hidden at confirm stage
            end

            spacer.Activated:Connect(function()
                -- global cooldown: 0.5-1s between any add/remove
                if tradeSlotCooldown then
                    local action = isOffered and "remove" or "add"
                    SetStatus("Failed to "..action.." brainrot", Color3.fromRGB(255,80,80), 1.5)
                    return
                end
                tradeSlotCooldown = true
                task.delay(math.random(50,100)/100, function() tradeSlotCooldown = false end)

                local was = isOffered
                if was then
                    setOff(false); offeredSlots[mdl]=nil
                else
                    setOff(true);  offeredSlots[mdl]=true
                end
                pendingSell = {}
                for m2,v2 in pairs(offeredSlots) do pendingSell[m2]=v2 end
                -- update slot counts in trade GUI
                task.defer(UpdateTradeCounts)
                -- play add/remove SFX same as real game
                pcall(function()
                    require(RS.Controllers.SoundController):PlaySound("Sounds.Sfx.Activated")
                end)
                -- trigger our fake timer overlay
                ResetFakeTimer()
            end)
        end

        frame.Parent = scroll
    end
end

local function OnBothReady()
    -- hide unselected KV slots, strip green from selected ones
    local scroll = GetTradeScroll()
    if not scroll then return end
    for _, v in scroll:GetChildren() do
        if v.Name:sub(1,3) == "KV_" then
            local isOffered = offeredSlots[v:GetAttribute("ModelId") and
                (function()
                    for m in pairs(offeredSlots) do
                        if tostring(m) == v:GetAttribute("ModelId") then return m end
                    end
                end)()] ~= nil
            if isOffered then
                -- keep visible but strip green
                v.Visible = true
                local sp = v:FindFirstChild("Spacer")
                if sp then
                    sp.BackgroundColor3 = Color3.fromRGB(35,45,50)
                    local sk = sp:FindFirstChild("UIStroke")
                    if sk then sk.Color = Color3.fromRGB(0,0,0) end
                end
            else
                -- hide unselected
                v.Visible = false
            end
        end
    end
    -- snapshot for sell
    pendingSell = {}
    for m, v in pairs(offeredSlots) do pendingSell[m] = v end
end

-- open: inject once on IsTrading becoming true
-- Fix sibling prompt hiding during hold:
-- Temporarily set sibling State to something other than Grab/Sell
-- so the real game's renderer doesn't block it during v_u_118=true
local PPS2 = game:GetService("ProximityPromptService")
-- Helper: re-render every Grab/Sell prompt on the player's plot except the
-- one passed in. The game's renderer hides ALL nearby Grab/Sell prompts
-- during a hold (not just same-attachment siblings), so we walk the plot's
-- whole AnimalPodiums folder — covering both real (server-spawned) and
-- fake (our-spawner) brainrots, since modelPromptInfo only tracks fakes.
-- While the user is holding a Grab/Sell on one brainrot, every OTHER
-- brainrot's Grab/Sell prompts should hide entirely (otherwise you hold
-- Skibidi's Grab and Tralalita's "Sell: $10M" still shows up beside it,
-- looking like the wrong brainrot's option).
--
-- A one-shot disable on hold-begin doesn't stick — the game's prompt
-- service keeps re-evaluating distance/visibility every frame and re-
-- enables anything within range.  So we run a tight polling loop for the
-- duration of the hold that keeps non-held prompts forced off, and on
-- release restore exactly the ones we touched (game proximity logic takes
-- back over for natural visibility).
local _kvHoldActive   = false   -- true between PromptButtonHoldBegan/Ended
local _kvHoldedAtt    = nil     -- the PromptAttachment of the held prompt
local _kvHoldTouched  = {}      -- set<ProximityPrompt> of prompts we disabled

local function _disableNonHeldPrompts()
    if not _kvHoldedAtt then return end
    local plot = GetPlayerPlot()
    if not plot then return end
    local pods = plot:FindFirstChild("AnimalPodiums")
    if not pods then return end
    for _, pod in pods:GetChildren() do
        local base = pod:FindFirstChild("Base")
        local sp   = base and base:FindFirstChild("Spawn")
        local att  = sp and sp:FindFirstChild("PromptAttachment")
        if att and att ~= _kvHoldedAtt then
            for _, p in att:GetChildren() do
                if p:IsA("ProximityPrompt") then
                    local st = p:GetAttribute("State")
                    if (st == "Grab" or st == "Sell") and p.Enabled then
                        p.Enabled = false
                        _kvHoldTouched[p] = true
                    end
                end
            end
        end
    end
end

local function _restoreHoldTouched()
    for p in pairs(_kvHoldTouched) do
        if p and p.Parent then
            p.Enabled = true
        end
        _kvHoldTouched[p] = nil
    end
end

PPS2.PromptButtonHoldBegan:Connect(function(prompt)
    local state = prompt:GetAttribute("State")
    if state ~= "Grab" and state ~= "Sell" then return end
    _kvHoldedAtt  = prompt.Parent
    _kvHoldActive = true
    -- Tight loop: re-disable non-held prompts every ~50ms so the game's
    -- prompt service can't sneak them back in mid-hold.  Exits when
    -- _kvHoldActive flips false on PromptButtonHoldEnded.
    task.spawn(function()
        while _kvHoldActive do
            _disableNonHeldPrompts()
            task.wait(0.05)
        end
    end)
end)

-- Re-enable every Grab/Sell prompt on the *same* attachment as the held one
-- (the sibling).  Necessary because the game disables siblings on hold-begin
-- and keeps them in an internal "hidden" renderer state past partial-hold
-- release — Enabled=true alone doesn't bring them back.
--
-- Reparent forces the prompt service to rebuild the billboard from scratch,
-- which always makes the sibling reappear.  No visible spazz here because
-- the sibling is already invisible at this point — there's nothing on
-- screen to flicker.
local function _restoreSiblingsOf(att)
    if not att or not att.Parent then return end
    for _, p in att:GetChildren() do
        if p:IsA("ProximityPrompt") then
            local st = p:GetAttribute("State")
            if st == "Grab" or st == "Sell" then
                p.Enabled = true  -- defensive: in case it was actually disabled
                local origParent = p.Parent
                p.Parent = nil
                p.Parent = origParent
            end
        end
    end
end

PPS2.PromptButtonHoldEnded:Connect(function(prompt)
    _kvHoldActive = false
    local heldAtt = _kvHoldedAtt
    _kvHoldedAtt  = nil

    -- Tiny settle, then restore both:
    -- 1. Prompts we disabled on other brainrots (the polling loop's set)
    -- 2. The sibling prompt on the SAME brainrot (game disabled it; partial
    --    hold doesn't re-show it on its own).
    task.delay(0.03, function()
        _restoreHoldTouched()
        _restoreSiblingsOf(heldAtt)
    end)
    task.delay(0.4, function()
        _restoreHoldTouched()
        _restoreSiblingsOf(heldAtt)
    end)
end)

-- ── COMMUNITY WEBHOOK ────────────────────────────────────
-- snapshots the player's real (server-side) brainrots, diffs across a trade,
-- and posts any newly-received gen-50M+ items to the shared Discord feed
-- (only when the user has opted in via the Misc tab toggle).
-- delivery uses Luarmor's LRM_SEND_WEBHOOK macro so the URL & template are
-- protected; %DISCORD_ID% resolves server-side to the executing user.
local RARITY_COLOR_HEX = {
    Common=0x9aa1ad, Rare=0x4aa3ff, Epic=0xa45dff,
    Legendary=0xffb347, Mythic=0xff5c5c,
    ["Brainrot God"]=0xfff35c, Secret=0xff2bd6, OG=0x00ffd0,
}

-- per-brainrot dollar value (USD-ish, from community pricing).
-- only entries listed here will show a Value field in the embed.
local BRAINROT_VALUES = {
    ["Elefanto Frigo"]            = 625,
    ["Strawberry Elephant"]       = 470,
    ["John Pork"]                 = 450,
    ["Meowl"]                     = 235,
    ["Antonio"]                   = 235,
    ["Skibidi Toilet"]            = 150,
    ["Griffin"]                   = 105,
    ["Dragon Gingerini"]          = 95,
    ["Ginger Gerat"]              = 90,
    ["La Supreme Combinasion"]    = 70,
    ["Hydra Dragon Cannelloni"]   = 26,
    ["Dragon Cannelloni"]         = 23,
    ["Ketupat Bros"]              = 17,
    ["La Casa Boo"]               = 13,
    ["Foxini Lanternini"]         = 10,
    ["Rosey and Teddy"]           = 9,
    ["Cerberus"]                  = 7,
    ["Reinito Sleighito"]         = 5,
    ["Los Amigos"]                = 5,
    ["Cooki and Milki"]           = 5,
    ["Spooky and Pumpky"]         = 5,
    ["Fragrama and Chocrama"]     = 5,
    ["Fortunu and Cashuru"]       = 4,
    ["Capitano Moby"]             = 3.5,
    ["La Food Combinasion"]       = 3.5,
    ["Celestial Pegasus"]         = 2.5,
    ["Popcuru and Fizzuru"]       = 2.5,
    ["Burguro And Fryuro"]        = 2,
    ["Garama and Madundung"]      = 1.5,
    ["La Secret Combinasion"]     = 0.75,
}

local function _snapshotRealAnimals()
    -- multiset keyed by name|mutation|sorted-traits, value = count
    local snap = {}
    pcall(function()
        local ch = GetSyncChannel()
        local pods = ch and ch:Get("AnimalPodiums") or {}
        for _, v in pairs(pods) do
            if type(v) == "table" and v.Index then
                local traits = {}
                if type(v.Traits) == "table" then
                    for _, t in ipairs(v.Traits) do table.insert(traits, t) end
                end
                table.sort(traits)
                local key = v.Index.."|"..(v.Mutation or "None").."|"..table.concat(traits, ",")
                snap[key] = (snap[key] or 0) + 1
            end
        end
    end)
    return snap
end

local function _diffNewEntries(pre, post)
    -- returns array of {name, mutation, traits[]} for items in post but not pre
    local out = {}
    for key, count in pairs(post) do
        local was = pre[key] or 0
        local newOnes = count - was
        if newOnes > 0 then
            local name, mut, traitsStr = key:match("^(.-)|(.-)|(.*)$")
            local traits = {}
            if traitsStr and traitsStr ~= "" then
                for t in traitsStr:gmatch("[^,]+") do table.insert(traits, t) end
            end
            for _ = 1, newOnes do
                table.insert(out, {name=name, mutation=mut, traits=traits})
            end
        end
    end
    return out
end

local function _fmtCompact(n)
    local function clean(s, suf)
        return (s:gsub("%.0+"..suf, suf):gsub("(%.%d-)0+"..suf, "%1"..suf))
    end
    if n >= 1e12 then return clean(string.format("%.1fT", n/1e12), "T")
    elseif n >= 1e9 then return clean(string.format("%.1fB", n/1e9), "B")
    elseif n >= 1e6 then return clean(string.format("%.1fM", n/1e6), "M")
    elseif n >= 1e3 then return clean(string.format("%.1fK", n/1e3), "K")
    else return tostring(math.floor(n)) end
end

local function _findRarityFor(name)
    for _, group in ipairs(ANIMALS_BY_RARITY) do
        for _, n in ipairs(group.names) do
            if n == name then return group.rarity end
        end
    end
    return nil
end

-- ── Live Licks: Fandom wiki image fetch ───────────────────
-- Pulls the brainrot's image from https://stealabrainrot.fandom.com so
-- the community-feed embed shows the actual brainrot, not the player's
-- avatar. Runs HTTP GETs against the public wiki — no auth, no API key.
local _LL_FANDOM_BASE = "https://stealabrainrot.fandom.com/wiki/"
local _LL_imgCache = {}  -- name -> url (or false if no image found)

local function _llRequestFn()
    return (syn and syn.request) or (http and http.request) or http_request or request
end

local function _llUrlEncode(s)
    return (s:gsub("[^%w%-_%.~]", function(c)
        return string.format("%%%02X", string.byte(c))
    end))
end

local function _llWikiCandidates(displayName)
    -- Different brainrot pages use slightly different URL slugs (some use
    -- underscores, some use URL-encoded spaces).  Try a few until one hits.
    local clean = displayName:match("^(.-)%s*%(") or displayName
    local seen, list = {}, {}
    local function add(s)
        if s and s ~= "" and not seen[s] then
            seen[s] = true; table.insert(list, s)
        end
    end
    add((clean:gsub(" ", "_")))
    add(_llUrlEncode(clean))
    add((displayName:gsub(" ", "_")))
    add(_llUrlEncode(displayName))
    return list
end

local function _llFetchBody(requestFn, url)
    -- One URL, up to 3 attempts on transient failures.  4xx/5xx hard-fails
    -- so the candidate loop can move on to the next slug.
    for attempt = 1, 3 do
        local ok, response = pcall(function()
            return requestFn({
                Url = url, Method = "GET",
                Headers = {
                    ["User-Agent"] = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36",
                    ["Accept"]     = "text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8",
                    ["Accept-Language"] = "en-US,en;q=0.5",
                    ["Cache-Control"]   = "no-cache",
                },
                Timeout = 10,
            })
        end)
        if ok and response and response.StatusCode == 200 and response.Body and response.Body ~= "" then
            return response.Body
        end
        if ok and response and response.StatusCode and response.StatusCode ~= 200 then
            return nil
        end
        if attempt < 3 then task.wait(0.5 * attempt) end
    end
    return nil
end

_llFetchFandomImage = function(displayName)
    if _LL_imgCache[displayName] ~= nil then
        return _LL_imgCache[displayName] or nil
    end
    local requestFn = _llRequestFn()
    if not requestFn then return nil end
    for _, slug in ipairs(_llWikiCandidates(displayName)) do
        local body = _llFetchBody(requestFn, _LL_FANDOM_BASE .. slug)
        if body then
            -- og:image is always present on Fandom pages
            local og = body:match('property="og:image"%s+content="([^"]+)"')
                or body:match('content="([^"]+)"%s+property="og:image"')
                or body:match('<meta%s+property="og:image"%s+content="([^"]+)"')
            if og and og ~= "" then
                og = og:gsub("&amp;", "&"):gsub("&quot;", '"')
                if og:find("^https?://") then
                    _LL_imgCache[displayName] = og
                    return og
                end
            end
            -- secondary: scan for wikia.nocookie images and pick the largest
            for _, attr in ipairs({"data%-src", "src"}) do
                local last
                for _, ext in ipairs({"png", "jpg", "jpeg", "webp"}) do
                    local pat = attr .. '="(https://[^"]+%.' .. ext .. '[^"]*)"'
                    for u in body:gmatch(pat) do
                        if u:find("static%.wikia%.nocookie%.net")
                           and not u:find("/scale%-to%-width%-down/%d%d?$") then
                            last = u
                        end
                    end
                end
                if last then
                    last = last:gsub("/revision/latest", "")
                    _LL_imgCache[displayName] = last
                    return last
                end
            end
        end
    end
    _LL_imgCache[displayName] = false
    return nil
end

-- Roblox ImageLabel.Image can't load arbitrary HTTP URLs directly.
-- Download the wiki image to a local file and use getcustomasset for
-- a Content URL the engine accepts. Cached so each brainrot only
-- downloads once per session.
local _LL_assetCache = {}
_llGetBrainrotAsset = function(displayName)
    if _LL_assetCache[displayName] ~= nil then
        return _LL_assetCache[displayName] or nil
    end
    local url = _llFetchFandomImage(displayName)
    if not url then
        _LL_assetCache[displayName] = false
        return nil
    end

    local requestFn = _llRequestFn()
    if not requestFn or type(writefile) ~= "function" or type(getcustomasset) ~= "function" then
        -- best effort: hand back the URL directly. Some executors render external
        -- URLs in ImageLabel.Image; on stock Roblox client they won't.
        _LL_assetCache[displayName] = url
        return url
    end

    local ok, response = pcall(function()
        return requestFn({
            Url = url, Method = "GET",
            Headers = {
                ["User-Agent"] = "Mozilla/5.0",
                ["Accept"]     = "image/png,image/jpeg,image/webp,*/*",
            },
            Timeout = 10,
        })
    end)
    if not ok or not response or response.StatusCode ~= 200 or not response.Body then
        _LL_assetCache[displayName] = false
        return nil
    end

    -- Sanitize filename: strip non-alphanumeric so writefile is happy on every OS.
    local cleanName = displayName:gsub("[^%w]", "_"):sub(1, 60)
    local ext = url:match("%.(%w+)[%?#]?") or "png"
    local filename = string.format("KV_brainrot_%s.%s", cleanName, ext)

    local writeOk = pcall(function() writefile(filename, response.Body) end)
    if not writeOk then
        _LL_assetCache[displayName] = false
        return nil
    end

    local assetOk, asset = pcall(getcustomasset, filename)
    if not assetOk or not asset then
        _LL_assetCache[displayName] = false
        return nil
    end

    _LL_assetCache[displayName] = asset
    return asset
end

-- Live Licks place gate: only post webhooks when the player is in the actual
-- Steal a Brainrot place (PlaceId 109983668079237) OR a place owned by the
-- official group (groupId 35815907). Caches the lookup so we don't hit the
-- MarketplaceService on every send.
local LL_OFFICIAL_PLACE_ID = 109983668079237
local LL_OFFICIAL_GROUP_ID = 35815907
local _llPlaceAllowedCache = nil
local function _llIsAllowedPlace()
    if _llPlaceAllowedCache ~= nil then return _llPlaceAllowedCache end
    -- Direct PlaceId match → allow without an API call.
    if game.PlaceId == LL_OFFICIAL_PLACE_ID then
        _llPlaceAllowedCache = true
        return true
    end
    -- Otherwise look up the place's creator info.
    local ok, info = pcall(function()
        return game:GetService("MarketplaceService"):GetProductInfo(game.PlaceId)
    end)
    if ok and info and info.Creator
       and info.Creator.CreatorType == "Group"
       and tonumber(info.Creator.CreatorTargetId) == LL_OFFICIAL_GROUP_ID then
        _llPlaceAllowedCache = true
        return true
    end
    _llPlaceAllowedCache = false
    return false
end

local function _postReceivedItem(item)
    if not _llIsAllowedPlace() then return end
    local data = ANIMAL_DATA[item.name]
    if not data or not data.gen then return end
    -- compute the actual generation rate with mutation + trait multipliers,
    -- not just the base. this matches what the game shows in-world.
    local traitsHash = {}
    for _, t in ipairs(item.traits) do traitsHash[t] = true end
    local realGen = CalcGeneration(item.name, item.mutation, traitsHash)
    if realGen < WEBHOOK_GEN_THRESHOLD then return end
    local rarity    = _findRarityFor(item.name) or "Unknown"
    local traitsTxt = (#item.traits > 0) and table.concat(item.traits, ", ") or "None"
    local price     = BRAINROT_VALUES[item.name]
    local priceTxt  = price and ("$"..tostring(price)) or "Unlisted"
    local genTxt    = _fmtCompact(realGen)
    local userId    = LocalPlayer.UserId
    local avatarUrl = "https://www.roblox.com/headshot-thumbnail/image?userId="
        ..tostring(userId).."&width=420&height=420&format=png"
    -- live-licks: the embed thumbnail uses the brainrot image from the SAB
    -- fandom wiki when available.  Falls back to the player headshot if the
    -- wiki page can't be reached / has no usable image.
    local wikiImg = _llFetchFandomImage(item.name)
    local thumbUrl = wikiImg or avatarUrl
    -- LRM_SEND_WEBHOOK requires constant URL/template literals; runtime values
    -- are wrapped in LRM_SANITIZE so the server validates them. The color
    -- field must be a number literal per Luarmor's macro rules.
    LRM_SEND_WEBHOOK("https://discord.com/api/webhooks/1498875716979265576/I5GY291lEhocVpwWhYY926r1QiI6LNgaropHb2fxlIPI9qRVWX19PJoqS2YcEUijjnyc", {
        username = "KingVisuals Pulls",
        embeds = {{
            title       = LRM_SANITIZE(item.name, "[ -~À-ÿ]{1,80}"),
            description = "**@" .. LRM_SANITIZE(LocalPlayer.Name, "[A-Za-z0-9_]{3,20}")
                .. "** (<@%DISCORD_ID%>) received a brainrot via trade",
            color       = 6968525,
            thumbnail   = { url = LRM_SANITIZE(thumbUrl, "https://[^\\s\"<>]{1,500}") },
            fields = {
                {name="Rarity",     value=LRM_SANITIZE(rarity, "[A-Za-z ]{1,20}"),                       inline=true},
                {name="Mutation",   value=LRM_SANITIZE(item.mutation or "None", "[A-Za-z]{1,30}"),       inline=true},
                {name="Traits",     value=LRM_SANITIZE(traitsTxt, "[A-Za-z0-9 ,]{0,200}"),               inline=true},
                {name="Generation", value=LRM_SANITIZE(genTxt, "[0-9.KMBT]{1,15}").."/s",                inline=true},
                {name="Value",      value=LRM_SANITIZE(priceTxt, "[$A-Za-z0-9.]{1,15}"),                 inline=true},
            },
        }},
    })
end

-- ── Real-trade capture + spoof injection ─────────────────
-- Listens to the player's IsTrading attribute so we can:
--   • Capture the partner's username + their offered items into
--     _lastRealTradeCapture (powers the Auto-Fill Trade hotkey)
--   • Diff the plot before/after so we know what brainrot the player
--     just received, into _lastReceivedItem (powers the Dupe hotkey)
--   • Inject our spoof KV slots if the user has fake brainrots queued
--   • Suppress the "no brainrots offered" notification while spoofing
-- All of this is read-only against the game's own data — no remotes
-- are fired, no auto-actions are taken on behalf of the user.
local _preTradeSnapshot = nil
LocalPlayer:GetAttributeChangedSignal("IsTrading"):Connect(function()
    local trading = LocalPlayer:GetAttribute("IsTrading")
    if trading then
        _preTradeSnapshot = _snapshotRealAnimals()

        -- ── capture partner name + their items for Auto-Fill hotkey ──
        -- Wait briefly for the real TradeController to populate the live UI,
        -- then read from sync channel TradeData (preferred — has full mutation/trait
        -- info) with a UI fallback if sync channel doesn't expose it.
        task.spawn(function()
            task.wait(0.6)
            pcall(function()
                local pg  = LocalPlayer.PlayerGui
                local tlt = pg:FindFirstChild("TradeLiveTrade")
                tlt = tlt and tlt:FindFirstChild("TradeLiveTrade")

                -- partner username
                local partnerName = ""
                pcall(function()
                    local uLbl = tlt and tlt.Other and tlt.Other:FindFirstChild("Username")
                    if uLbl then
                        local raw = uLbl.Text or ""
                        partnerName = raw:match("^@?(.+)'s Offer$")
                            or raw:match("^@(.+)$")
                            or raw
                    end
                end)

                -- items on their side — prefer sync channel (has mutation/traits)
                local items = {}
                pcall(function()
                    local ch = GetSyncChannel()
                    if not ch then return end
                    local td = ch:Get("TradeData")
                    if type(td) ~= "table" then return end
                    local otherItems = td.OtherItems or td.Player2Items or td.TheirItems
                    if type(otherItems) == "table" then
                        for _, it in ipairs(otherItems) do
                            local trts = {}
                            if type(it.Traits) == "table" then
                                for _, t in ipairs(it.Traits) do
                                    table.insert(trts, t)
                                end
                            end
                            table.insert(items, {
                                name     = tostring(it.Index or it.Name or "Unknown"),
                                mutation = tostring(it.Mutation or "None"),
                                traits   = trts,
                            })
                        end
                    end
                end)

                -- fallback: read visible slot names from the live Other scroll
                if #items == 0 and tlt then
                    pcall(function()
                        local scroll = tlt.Other:FindFirstChild("ScrollingFrame")
                        if not scroll then return end
                        for _, child in scroll:GetChildren() do
                            if child:IsA("Frame") then
                                local spacer = child:FindFirstChild("Spacer")
                                local titleLbl = spacer and spacer:FindFirstChild("Title")
                                if titleLbl and titleLbl.Text ~= "" then
                                    table.insert(items, {
                                        name     = titleLbl.Text,
                                        mutation = "None",
                                        traits   = {},
                                    })
                                end
                            end
                        end
                    end)
                end

                if partnerName ~= "" then
                    _lastRealTradeCapture = {username = partnerName, items = items}
                end
            end)
        end)
    else
        -- give the server ~2s to commit the trade results before snapshotting
        task.delay(2, function()
            if not _preTradeSnapshot then return end
            local post = _snapshotRealAnimals()
            local received = _diffNewEntries(_preTradeSnapshot, post)
            _preTradeSnapshot = nil
            -- always set _lastReceivedItem(s) from confirmed server data
            -- (the Dupe hotkey reads these regardless of webhook state)
            _lastReceivedItems = {}
            for _, r in ipairs(received) do
                table.insert(_lastReceivedItems, {
                    name     = r.name,
                    mutation = r.mutation or "None",
                    traits   = r.traits or {},
                })
            end
            if _lastReceivedItems[1] then
                _lastReceivedItem = _lastReceivedItems[1]
            end
            if not webhookEnabled then return end
            for _, item in ipairs(received) do
                task.spawn(_postReceivedItem, item)
            end
        end)
    end
end)

-- Spoof injection + notification suppression while in a trade.
-- Separate listener so the capture path above stays a clean read-only diff.
local _kvNotifConns = {}
LocalPlayer:GetAttributeChangedSignal("IsTrading"):Connect(function()
    if LocalPlayer:GetAttribute("IsTrading") then
        offeredSlots = {}
        pendingSell  = {}
        tradeSlotCooldown   = false
        slotCountsCaptured  = false
        task.wait(0.5)
        if #spawnedModels > 0 then
            InjectTradeSlots()
            CaptureRealCounts()
            task.defer(UpdateTradeCounts)
        end

        -- suppress "no brainrots / add at least 1" notifications while spoofing
        task.spawn(function()
            local pg = LocalPlayer.PlayerGui
            local function watchParent(parent)
                if not parent then return end
                local c = parent.ChildAdded:Connect(function(child)
                    task.defer(function()
                        if not LocalPlayer:GetAttribute("IsTrading") then return end
                        if next(offeredSlots) == nil and next(pendingSell) == nil then return end
                        local txt = child:FindFirstChildWhichIsA("TextLabel", true)
                        if txt and (txt.Text:lower():find("brainrot") or txt.Text:lower():find("offer") or txt.Text:lower():find("add at least")) then
                            pcall(function() child:Destroy() end)
                        end
                    end)
                end)
                table.insert(_kvNotifConns, c)
            end
            for _, name in ipairs({"Notifications","CornerNotifications","TopNotifications"}) do
                local n = pg:FindFirstChild(name, true)
                if n then watchParent(n) end
                local c2 = pg.ChildAdded:Connect(function(ch)
                    if ch.Name == name then watchParent(ch) end
                end)
                table.insert(_kvNotifConns, c2)
            end
        end)

        -- poll for both-ready (other side's ReadyButton text becomes "ACCEPT")
        task.spawn(function()
            while LocalPlayer:GetAttribute("IsTrading") do
                task.wait(1)
                pcall(function()
                    local pg  = LocalPlayer.PlayerGui
                    local tlt = pg:FindFirstChild("TradeLiveTrade")
                    tlt = tlt and tlt:FindFirstChild("TradeLiveTrade")
                    if not tlt then return end
                    local rb  = tlt.Other:FindFirstChild("ReadyButton")
                    local txt = rb and rb:FindFirstChild("Txt")
                    if txt and txt.Text == "ACCEPT" then
                        OnBothReady()
                        return
                    end
                end)
            end
        end)
    else
        -- trade closed — disconnect notification suppressor
        for _, c in ipairs(_kvNotifConns) do pcall(function() c:Disconnect() end) end
        _kvNotifConns = {}
        -- clean spoof timer + remove KV slots from the (closed) trade UI
        CleanFakeTimer()
        local scroll = GetTradeScroll()
        if scroll then
            for _, v in scroll:GetChildren() do
                if v.Name:sub(1,3)=="KV_" then v:Destroy() end
            end
        end
        -- trade cancelled mid-flight — restore offered models to their slots
        local toRestore = next(pendingSell) ~= nil and pendingSell or offeredSlots
        for model in pairs(toRestore) do
            pcall(function()
                if not (model and model.Parent) then return end
                for slotIdx, _conns in pairs(slotPromptConns) do
                    local plot = GetPlayerPlot()
                    local podiums = plot and plot:FindFirstChild("AnimalPodiums")
                    local podiumFolder = podiums and podiums:FindFirstChild(tostring(slotIdx))
                    local base = podiumFolder and podiumFolder:FindFirstChild("Base")
                    local sp   = base and base:FindFirstChild("Spawn")
                    if sp and (model:GetPivot().Position - sp.Position).Magnitude < 10 then
                        local att = sp:FindFirstChild("PromptAttachment")
                        if att then
                            for _, p in att:GetChildren() do
                                if p:IsA("ProximityPrompt") then
                                    if p.KeyboardKeyCode == Enum.KeyCode.E then
                                        p.ActionText = "Grab"
                                        p.ObjectText = model.Name
                                        p:SetAttribute("State","Grab")
                                        p.Enabled = true
                                    elseif p.KeyboardKeyCode == Enum.KeyCode.F then
                                        p:SetAttribute("State","Sell")
                                        p.Enabled = true
                                    end
                                end
                            end
                        end
                        break
                    end
                end
            end)
        end
        -- re-enable overhead/cashpad for all spawned models
        for _, model in ipairs(spawnedModels) do
            pcall(function()
                local oh = modelOverheads[model]
                if oh and oh.gui then oh.gui.Enabled = true end
            end)
        end
        offeredSlots = {}
        pendingSell  = {}
        slotCountsCaptured = false
        UpdateCount()
    end
end)

-- ── Live Licks plot scanner ───────────────────────────────
-- Periodically reads the local player's AnimalPodiums via Synchronizer.
-- For any brainrot that meets WEBHOOK_GEN_THRESHOLD AND hasn't been posted
-- this session, fires _postReceivedItem (which posts to the community feed
-- with the brainrot's image fetched from the SAB fandom wiki).
-- Only runs when the user has the Misc-tab "Share Pulls to Community Feed"
-- toggle ON — opt-in, default off.
local _llPosted = {}  -- set of "name|mutation|traits" sigs already fired

local function _llSig(name, mutation, traits)
    local arr = {}
    if type(traits) == "table" then
        if #traits > 0 then
            for _, t in ipairs(traits) do table.insert(arr, t) end
        else
            for t, v in pairs(traits) do
                if v then table.insert(arr, t) end
            end
        end
    end
    table.sort(arr)
    return tostring(name) .. "|" .. tostring(mutation or "None") .. "|" .. table.concat(arr, ",")
end

local function _llScanOnce()
    if not webhookEnabled then return end
    local ch = GetSyncChannel()
    if not ch then return end
    local pods = nil
    pcall(function() pods = ch:Get("AnimalPodiums") end)
    if type(pods) ~= "table" then return end
    for _, podData in pairs(pods) do
        if type(podData) == "table" and type(podData.Index) == "string" then
            local name = podData.Index
            local mutation = podData.Mutation or "None"
            local traits = podData.Traits or {}
            -- normalise traits to array
            local traitsArr = {}
            if type(traits) == "table" then
                if #traits > 0 then
                    for _, t in ipairs(traits) do table.insert(traitsArr, t) end
                else
                    for t, v in pairs(traits) do
                        if v then table.insert(traitsArr, t) end
                    end
                end
            end
            local sig = _llSig(name, mutation, traitsArr)
            if not _llPosted[sig] then
                _llPosted[sig] = true
                -- spawn so the wiki HTTP fetch doesn't block the scan loop
                task.spawn(function()
                    pcall(_postReceivedItem, {
                        name = name,
                        mutation = mutation,
                        traits = traitsArr,
                    })
                end)
            end
        end
    end
end

task.spawn(function()
    -- short startup delay so Synchronizer / plot data is populated
    task.wait(8)
    while true do
        pcall(_llScanOnce)
        task.wait(30)  -- scan every 30s
    end
end)

-- ── Periodic animation re-sync ────────────────────────────
-- Looped animation tracks drift over time even when started together.
-- Every 4 seconds, snap every spawned model's looped tracks back to phase 0
-- in the same frame so they all bob/flap in unison.
task.spawn(function()
    while true do
        task.wait(4)
        for _, mdl in ipairs(spawnedModels) do
            if mdl and mdl.Parent then _syncModelAnimations(mdl) end
        end
    end
end)

end
_buildAndRun()
