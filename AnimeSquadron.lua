--[[
    Anime Squadron - Automation Script
    PlaceId: 71132543521245

    Identity policy:
      Every ability that interacts with the game runs at the LOWEST identity that
      works -- identity 2, the normal game-script level -- via runLow(). Roblox
      blocks the game's internal require() calls at the executor's elevated
      identity, so identity 2 is required for the game's own UI functions and is
      harmless for everything else (remotes, GUI edits). Elevated identity is used
      only for executor-only APIs that need it (gethui). If the executor exposes no
      identity APIs, runLow() simply runs the code as-is (auto-fallback), and the
      manual fallbacks (self-built viewport / click handler) cover the gap.
]]

--// Self-cache: store this script's source so the auto-execute toggle can queue it
pcall(function()
    local env = getgenv and getgenv()
    if not env then return end
    -- Try to read our own source from known sandbox locations
    if not env._AnimeSquadronSource then
        local paths = { "workspace/AnimeSquadron.lua", "autoexec/AnimeSquadron.lua" }
        for _, p in ipairs(paths) do
            if isfile(p) then
                local s = readfile(p)
                if s and #s > 100 then
                    env._AnimeSquadronSource = s
                    break
                end
            end
        end
    end
    -- If auto-execute was on, re-queue for the next teleport
    if env._AnimeSquadronAutoExec and env._AnimeSquadronSource then
        queue_on_teleport(env._AnimeSquadronSource)
    end
end)

--// Services
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Players = game:GetService("Players")

--// Remotes (timeouts prevent hanging in places that lack some remote folders)
local Remotes = ReplicatedStorage:WaitForChild("Remotes", 10)
if not Remotes then warn("[AnimeSquadron] Remotes not found, aborting.") return end
local SummonRemotes = Remotes:FindFirstChild("Summon")
local CharacterRemotes = Remotes:FindFirstChild("Characters")
local PlayerRemotes = Remotes:FindFirstChild("Player")
local PlayRemotes = Remotes:FindFirstChild("Play")
local GameRemotes = Remotes:FindFirstChild("Game")

--========================================================
--  IDENTITY MANAGEMENT
--========================================================
local _genv = (getgenv and getgenv()) or {}
local _setIdentity = _genv.setthreadidentity or _genv.set_thread_identity or _genv.setidentity
local _getIdentity = _genv.getthreadidentity or _genv.get_thread_identity or _genv.getidentity
local _getConnections = _genv.getconnections or _genv.get_signal_cons

local LOW_IDENTITY = 2  -- normal game-script identity (lowest that supports game calls)

-- Run fn() at the lowest identity that supports the game's own functions, then
-- restore the previous identity. Auto-fallback: if the executor exposes no
-- identity API, fn() just runs as-is. Returns pcall results.
local function runLow(fn)
    if type(_setIdentity) ~= "function" then
        return pcall(fn)
    end
    local prev = (type(_getIdentity) == "function" and _getIdentity()) or 8
    pcall(_setIdentity, LOW_IDENTITY)
    local ok, err = pcall(fn)
    pcall(_setIdentity, prev)
    return ok, err
end

-- Run fn() at an elevated identity (for executor-only APIs such as gethui).
local function runElevated(fn, level)
    if type(_setIdentity) ~= "function" then
        return pcall(fn)
    end
    local prev = (type(_getIdentity) == "function" and _getIdentity()) or 8
    pcall(_setIdentity, level or 8)
    local ok, res = pcall(fn)
    pcall(_setIdentity, prev)
    return ok, res
end

--// Live client modules (already initialised by the game; require returns cached instances)
local function requireClientModule(name)
    local lp = Players.LocalPlayer
    local client = lp and lp:FindFirstChild("PlayerScripts") and lp.PlayerScripts:FindFirstChild("Client")
    local mod = client and client:FindFirstChild(name)
    if mod then
        local ok, ret = pcall(require, mod)
        if ok then return ret end
    end
    return nil
end

local CharactersModule = requireClientModule("Characters")  -- add(unit), info(unit), get_model
local PlayersModule     = requireClientModule("Players")     -- setup_currencies(profile)
local SummonModule      = requireClientModule("Summon")      -- pity(profile)
local MainModule        = requireClientModule("Main")        -- on_teleport() (results -> lobby)

local WorldsModule
pcall(function()
    local lp = Players.LocalPlayer
    local playScript = lp.PlayerScripts.Client:FindFirstChild("Play")
    local wMod = playScript and playScript:FindFirstChild("Worlds")
    if wMod then WorldsModule = require(wMod) end
end)

-- Reads maps and chapters directly from the in-game Play UI by simulating
-- gamemode/world clicks, so the dropdowns always reflect what the player
-- actually sees (and auto-update when the game adds/removes content).

local _playUI  -- cached reference to PlayerGui.Menus.Play
local function getPlayUI()
    if _playUI and _playUI.Parent then return _playUI end
    local pg = Players.LocalPlayer and Players.LocalPlayer:FindFirstChild("PlayerGui")
    _playUI = pg and pg:FindFirstChild("Menus") and pg.Menus:FindFirstChild("Play")
    return _playUI
end

local function clickGameUIButton(btn)
    if not btn then return end
    local conns = _getConnections and _getConnections(btn.Activated)
    if conns then
        for _, c in ipairs(conns) do task.spawn(c.Fire, c) end
    end
end

local function getMapsForMode(mode)
    local maps = {}
    local play = getPlayUI()
    if not play then return maps end

    local modeBtn = play:FindFirstChild("Gamemodes") and play.Gamemodes:FindFirstChild(mode)
    if modeBtn then
        runLow(function()
            clickGameUIButton(modeBtn)
            task.wait(0.3)
        end)
    end

    local worlds = play:FindFirstChild("Worlds")
    if not worlds then return maps end

    if mode == "Challenge" then
        local PlayR = ReplicatedStorage:FindFirstChild("Remotes")
        local playFolder = PlayR and PlayR:FindFirstChild("Play")
        local getCh = playFolder and playFolder:FindFirstChild("get_challenges")
        local chData = {}
        if getCh then
            local ok, ch
            runLow(function() ok, ch = pcall(function() return getCh:InvokeServer() end) end)
            if ok and typeof(ch) == "table" then chData = ch end
        end
        for _, btn in ipairs(worlds:GetChildren()) do
            if btn:IsA("ImageButton") and btn.Visible then
                local nameLabel = btn:FindFirstChild("WorldName")
                local timeLabel = btn:FindFirstChild("WorldNumber")
                local displayName = nameLabel and nameLabel.Text or btn.Name
                local timeText = ""
                if timeLabel then
                    timeText = timeLabel.Text:gsub("<.->", ""):gsub("%[", ""):gsub("%]", "")
                end
                local key = btn.Name
                if chData[key] then
                    local d = chData[key]
                    table.insert(maps, { value = key, text = displayName .. " (" .. timeText .. ")", world = d.world, act = d.act })
                else
                    table.insert(maps, { value = key, text = displayName .. " (" .. timeText .. ")", world = displayName })
                end
            end
        end
    else
        for _, btn in ipairs(worlds:GetChildren()) do
            if btn:IsA("ImageButton") and btn.Visible then
                local nameLabel = btn:FindFirstChild("WorldName")
                local name = nameLabel and nameLabel.Text or btn.Name
                table.insert(maps, name)
            end
        end
        table.sort(maps)
    end
    return maps
end

local function getChaptersForMode(mode, mapName)
    local chapters = {}
    if mode == "Challenge" then
        table.insert(chapters, { value = 1, text = "Auto" })
        return chapters
    end

    local play = getPlayUI()
    if not play then return chapters end

    -- Click the world button in the UI so the Acts frame populates
    local worlds = play:FindFirstChild("Worlds")
    local worldBtn = worlds and worlds:FindFirstChild(mapName)
    if worldBtn then
        runLow(function()
            clickGameUIButton(worldBtn)
            task.wait(0.3)
        end)
    end

    local acts = play:FindFirstChild("Acts")
    if not acts then return chapters end

    local nums = {}
    for _, item in ipairs(acts:GetChildren()) do
        if item:IsA("ImageButton") and item.Visible then
            local locked = item:FindFirstChild("Locked")
            if not (locked and locked.Visible) then
                local n = tonumber(item.Name:match("_(%d+)$"))
                if n then table.insert(nums, n) end
            end
        end
    end
    table.sort(nums)

    local chapterLabel = (mode == "Squadron" and "Floor ") or (mode == "Raid" and "Act ") or "Chapter "
    for _, n in ipairs(nums) do
        table.insert(chapters, { value = n, text = chapterLabel .. n })
    end
    return chapters
end

local SellModule
do
    local lp = Players.LocalPlayer
    local client = lp and lp:FindFirstChild("PlayerScripts") and lp.PlayerScripts:FindFirstChild("Client")
    local charScript = client and client:FindFirstChild("Characters")
    local sellMod = charScript and charScript:FindFirstChild("Sell")
    if sellMod then
        local ok, ret = pcall(require, sellMod)
        if ok then SellModule = ret end
    end
end

--========================================================
--  RARITY (uses the executor's require, which works at any identity)
--========================================================
local rarityCache = {}
local function getRarity(unitName)
    if rarityCache[unitName] ~= nil then
        return rarityCache[unitName]
    end
    local rarity = "Unknown"
    local charFolder = ReplicatedStorage:FindFirstChild("Characters")
    local charObj = charFolder and charFolder:FindFirstChild(unitName)
    local dataMod = charObj and charObj:FindFirstChild("data")
    if dataMod then
        local ok, data = pcall(require, dataMod)
        if ok and typeof(data) == "table" and data.rarity then
            rarity = tostring(data.rarity)
        end
    end
    rarityCache[unitName] = rarity
    return rarity
end

--========================================================
--  AUTO-LOCK
--========================================================
local function refreshLockIcons(lockedIdSet)
    local lp = Players.LocalPlayer
    local pg = lp and lp:FindFirstChild("PlayerGui")
    if not pg then return end
    for _, d in ipairs(pg:GetDescendants()) do
        if lockedIdSet[d.Name] then
            local lockChild = d:FindFirstChild("Locked")
            if lockChild then
                lockChild.Visible = true
            end
        end
    end
end

-- Lock every UNLOCKED unit whose rarity is in targetSet (e.g. { Mythic = true }).
-- Runs at the lowest identity. Returns lockedCount, scannedCount.
local function AutoLock(targetSet)
    local lockedCount, scanned = 0, 0
    runLow(function()
        local lockRemote = CharacterRemotes:WaitForChild("lock")
        local profile = PlayerRemotes:WaitForChild("get"):InvokeServer()
        if typeof(profile) ~= "table" or typeof(profile.characters) ~= "table" then
            return
        end
        local newlyLocked = {}
        for _, unit in pairs(profile.characters) do
            if typeof(unit) == "table" and unit.id then
                scanned = scanned + 1
                if unit.locked ~= true and targetSet[getRarity(tostring(unit.name))] then
                    local ok, result = pcall(function()
                        return lockRemote:InvokeServer(unit.id)
                    end)
                    if ok and result then
                        lockedCount = lockedCount + 1
                        newlyLocked[tostring(unit.id)] = true
                    end
                    task.wait(0.12)
                end
            end
        end
        if lockedCount > 0 then
            refreshLockIcons(newlyLocked)
        end
    end)
    return lockedCount, scanned
end

--========================================================
--  SUMMON
--========================================================

-- Safety-net builder for a tile's 3D preview (pure cloning, no require -> any identity).
local function ensureUnitTileVisuals(unit)
    local lp = Players.LocalPlayer
    local pg = lp and lp:FindFirstChild("PlayerGui")
    if not pg then return end
    local charFolder = ReplicatedStorage:FindFirstChild("Characters")
    local rarities = ReplicatedStorage:FindFirstChild("Rarities")
    local src = charFolder and charFolder:FindFirstChild(tostring(unit.name))
    local rarObj = rarities and rarities:FindFirstChild(getRarity(tostring(unit.name)))
    for _, tile in ipairs(pg:GetDescendants()) do
        if tile.Name == tostring(unit.id) then
            local vf = tile:FindFirstChild("ViewportFrame")
            if vf and src and not vf:FindFirstChildOfClass("WorldModel") then
                local clone = src:Clone()
                local primary = clone.PrimaryPart
                local wm = Instance.new("WorldModel")
                wm.Name = clone.Name
                for _, c in ipairs(clone:GetChildren()) do c.Parent = wm end
                wm.PrimaryPart = primary
                pcall(function() wm:ScaleTo(0.6) end)
                pcall(function()
                    wm:PivotTo(CFrame.new(-402, 4.5, 209.5) * CFrame.Angles(0, math.pi, 0))
                end)
                wm.Parent = vf
            end
            local grad = tile:FindFirstChild("UIGradient")
            if grad and rarObj then
                pcall(function() grad.Color = rarObj.Color end)
            end
        end
    end
end

-- Safety net: give a new tile a working click->details handler. The native one
-- the game wires fires at the executor's identity (where info()'s require fails),
-- so we replace it with our own that runs the detail logic via runLow.
local function wireUnitDetailClick(unit)
    if not CharactersModule or not CharacterRemotes then return end
    local charGet = CharacterRemotes:FindFirstChild("get")
    if not charGet then return end
    local lp = Players.LocalPlayer
    local pg = lp and lp:FindFirstChild("PlayerGui")
    local menus = pg and pg:FindFirstChild("Menus")
    local chars = menus and menus:FindFirstChild("Characters")
    local scroll = chars and chars:FindFirstChild("ScrollingFrame")
    local tile = scroll and scroll:FindFirstChild(tostring(unit.id))
    local clicked = tile and tile:FindFirstChild("Clicked")
    if not clicked then return end

    if type(_getConnections) == "function" then
        pcall(function()
            for _, conn in ipairs(_getConnections(clicked.Activated)) do
                conn:Disconnect()
            end
        end)
    end

    local uid = unit.id
    clicked.Activated:Connect(function()
        runLow(function()
            local data = charGet:InvokeServer(uid)
            if data then
                CharactersModule.selected = data
                if CharactersModule.mode == "sell" then
                    if not data.locked and SellModule then
                        local alreadyIdx = table.find(SellModule.ids, data.id)
                        SellModule.select(tile, data, alreadyIdx)
                    end
                else
                    CharactersModule.info(data)
                end
            end
        end)
    end)
end

-- Updates the inventory + currency + pity after a summon. Called from inside a
-- runLow block (already at low identity), so the game's native functions work;
-- the manual fallbacks below cover executors without identity APIs.
local function syncSummonUI(units, profile)
    if CharactersModule and typeof(units) == "table" then
        for _, unit in pairs(units) do
            if typeof(unit) == "table" and not unit.sold then
                pcall(function() CharactersModule.add(unit) end)  -- native tile (full at low identity)
                ensureUnitTileVisuals(unit)                        -- safety net: preview + colour
                wireUnitDetailClick(unit)                          -- safety net: click->details
                task.wait()
            end
        end
    end
    if PlayersModule and typeof(profile) == "table" then
        pcall(function() PlayersModule.setup_currencies(profile) end)
    end
    if SummonModule and typeof(profile) == "table" then
        pcall(function() SummonModule.pity(profile) end)
    end
end

-- Fires the summon and refreshes the UI, all at the lowest identity.
-- Returns accepted (boolean), message (string).
local function Summon(banner, amount)
    local accepted, message = false, "Summon failed"
    runLow(function()
        local startRemote = SummonRemotes:WaitForChild("start")
        local result, payload = startRemote:InvokeServer(banner, amount)
        if typeof(result) == "table" then
            accepted = true
            syncSummonUI(result, payload)
            local n = 0
            for _ in pairs(result) do n = n + 1 end
            message = "Summoned " .. n .. "!"
        else
            message = (typeof(payload) == "string" and payload) or "Summon rejected"
        end
    end)
    return accepted, message
end

local function SummonBasicX1()  return Summon("Basic Banner", 1)  end
local function SummonBasicX10() return Summon("Basic Banner", 10) end

--========================================================
--  AUTO JOIN MAP
--========================================================
local function AutoJoinMap(world, chapter, difficulty, mode)
    local ok, message = false, "Join failed"
    runLow(function()
        local createRoom = PlayRemotes:WaitForChild("create_room")
        local startMatch = PlayRemotes:WaitForChild("start")
        local leave = PlayRemotes:WaitForChild("leave")

        pcall(function() leave:FireServer() end)
        task.wait(0.3)

        local config = {
            world = world,
            act = chapter,
            mode = mode or "Story",
            difficulty = difficulty or "Normal",
            only_friends = false,
        }
        local okCreate, created = pcall(function() return createRoom:InvokeServer(config) end)
        if not (okCreate and created) then
            message = "Create failed"
            return
        end
        task.wait(0.5)
        local okStart, started = pcall(function() return startMatch:InvokeServer() end)
        if okStart and started then
            ok = true
            message = "Joined " .. world .. " Ch." .. tostring(chapter)
        else
            message = "Start failed (locked?)"
        end
    end)
    return ok, message
end

--========================================================
--  STATE HELPERS (currency + lobby/match detection)
--========================================================
-- Basic Banner gem costs, read from the in-game price labels.
local SUMMON_COST = { [1] = 50, [10] = 500 }

-- Authoritative current gem balance (nil if it couldn't be read).
local function getGems()
    local gems
    runLow(function()
        local p = PlayerRemotes:WaitForChild("get"):InvokeServer()
        if typeof(p) == "table" and typeof(p.stats) == "table" then
            gems = tonumber(p.stats.Gems)
        end
    end)
    return gems
end

-- workspace.Game exists only during a match; absent in the lobby.
local function isInLobby()
    return workspace:FindFirstChild("Game") == nil
end

--========================================================
--  GUI
--========================================================

-- gethui needs elevated identity; CoreGui/PlayerGui work at the low identity too.
local function getGuiParent()
    local hui
    runElevated(function()
        if gethui then hui = gethui() end
    end)
    if hui then return hui end
    local ok, core = pcall(function() return game:GetService("CoreGui") end)
    if ok and core then return core end
    return Players.LocalPlayer:WaitForChild("PlayerGui")
end

local function buildGui()
    local TweenService = game:GetService("TweenService")
    local parent = getGuiParent()
    local existing = parent:FindFirstChild("AnimeSquadronGui")
    if existing then existing:Destroy() end

    local screenGui = Instance.new("ScreenGui")
    screenGui.Name = "AnimeSquadronGui"
    screenGui.ResetOnSpawn = false
    screenGui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
    screenGui.IgnoreGuiInset = true
    screenGui.DisplayOrder = 999999
    screenGui.Parent = parent

    -- Color palette
    local C = {
        bg        = Color3.fromRGB(18, 18, 24),
        surface   = Color3.fromRGB(28, 28, 38),
        elevated  = Color3.fromRGB(38, 38, 52),
        border    = Color3.fromRGB(55, 55, 75),
        accent    = Color3.fromRGB(99, 102, 241),
        accentLit = Color3.fromRGB(129, 132, 255),
        green     = Color3.fromRGB(34, 197, 94),
        greenDark = Color3.fromRGB(22, 163, 74),
        red       = Color3.fromRGB(239, 68, 68),
        redDark   = Color3.fromRGB(185, 28, 28),
        text      = Color3.fromRGB(245, 245, 250),
        textDim   = Color3.fromRGB(160, 160, 180),
        trackOff  = Color3.fromRGB(55, 55, 70),
        save      = Color3.fromRGB(59, 130, 246),
        saveLit   = Color3.fromRGB(96, 165, 250),
    }
    local TWEEN_FAST = TweenInfo.new(0.15, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
    local TWEEN_MED  = TweenInfo.new(0.25, Enum.EasingStyle.Quint, Enum.EasingDirection.Out)

    -- Drop shadow behind main frame
    local shadow = Instance.new("ImageLabel")
    shadow.Name = "Shadow"
    shadow.BackgroundTransparency = 1
    shadow.Image = "rbxassetid://6015897843"
    shadow.ImageColor3 = Color3.fromRGB(0, 0, 0)
    shadow.ImageTransparency = 0.5
    shadow.ScaleType = Enum.ScaleType.Slice
    shadow.SliceCenter = Rect.new(49, 49, 450, 450)
    shadow.Size = UDim2.new(1, 36, 1, 36)
    shadow.Position = UDim2.new(0.5, 0, 0.5, 0)
    shadow.AnchorPoint = Vector2.new(0.5, 0.5)
    shadow.Parent = screenGui

    local frame = Instance.new("Frame")
    frame.Name = "Main"
    frame.Size = UDim2.fromOffset(270, 440)
    frame.Position = UDim2.fromScale(0.5, 0.4)
    frame.AnchorPoint = Vector2.new(0.5, 0.5)
    frame.BackgroundColor3 = C.bg
    frame.BorderSizePixel = 0
    frame.Active = true
    frame.Parent = screenGui
    Instance.new("UICorner", frame).CornerRadius = UDim.new(0, 12)
    local frameStroke = Instance.new("UIStroke")
    frameStroke.Color = C.border
    frameStroke.Transparency = 0.4
    frameStroke.Thickness = 1
    frameStroke.Parent = frame

    -- Keep shadow following the frame
    local function syncShadow()
        shadow.Position = frame.Position
        shadow.AnchorPoint = frame.AnchorPoint
    end
    frame:GetPropertyChangedSignal("Position"):Connect(syncShadow)
    syncShadow()

    local uiScale = Instance.new("UIScale")
    uiScale.Scale = 1
    uiScale.Parent = frame

    -- Title bar with gradient
    local titleBar = Instance.new("Frame")
    titleBar.Name = "TitleBar"
    titleBar.Size = UDim2.new(1, 0, 0, 36)
    titleBar.BackgroundColor3 = C.surface
    titleBar.BorderSizePixel = 0
    titleBar.Parent = frame
    Instance.new("UICorner", titleBar).CornerRadius = UDim.new(0, 12)
    local titleGrad = Instance.new("UIGradient")
    titleGrad.Color = ColorSequence.new(C.accent, C.surface)
    titleGrad.Rotation = 90
    titleGrad.Transparency = NumberSequence.new({
        NumberSequenceKeypoint.new(0, 0.7),
        NumberSequenceKeypoint.new(1, 1),
    })
    titleGrad.Parent = titleBar
    -- Bottom square fill to avoid rounded bottom corners showing bg
    local titleFill = Instance.new("Frame")
    titleFill.Size = UDim2.new(1, 0, 0, 12)
    titleFill.Position = UDim2.new(0, 0, 1, -12)
    titleFill.BackgroundColor3 = C.surface
    titleFill.BorderSizePixel = 0
    titleFill.ZIndex = 0
    titleFill.Parent = titleBar

    local titleLabel = Instance.new("TextLabel")
    titleLabel.Name = "TitleText"
    titleLabel.BackgroundTransparency = 1
    titleLabel.Size = UDim2.new(1, -40, 1, 0)
    titleLabel.Position = UDim2.new(0, 14, 0, 0)
    titleLabel.Text = "Anime Squadron"
    titleLabel.TextColor3 = C.text
    titleLabel.Font = Enum.Font.GothamBold
    titleLabel.TextSize = 15
    titleLabel.TextXAlignment = Enum.TextXAlignment.Left
    titleLabel.Parent = titleBar

    local closeBtn = Instance.new("TextButton")
    closeBtn.Name = "Close"
    closeBtn.Size = UDim2.fromOffset(24, 24)
    closeBtn.Position = UDim2.new(1, -30, 0.5, -12)
    closeBtn.BackgroundColor3 = C.red
    closeBtn.Text = "X"
    closeBtn.TextColor3 = C.text
    closeBtn.Font = Enum.Font.GothamBold
    closeBtn.TextSize = 12
    closeBtn.BorderSizePixel = 0
    closeBtn.AutoButtonColor = false
    closeBtn.ZIndex = 2
    closeBtn.Parent = titleBar
    Instance.new("UICorner", closeBtn).CornerRadius = UDim.new(0, 6)
    closeBtn.MouseEnter:Connect(function()
        TweenService:Create(closeBtn, TWEEN_FAST, {BackgroundColor3 = C.redDark}):Play()
    end)
    closeBtn.MouseLeave:Connect(function()
        TweenService:Create(closeBtn, TWEEN_FAST, {BackgroundColor3 = C.red}):Play()
    end)
    closeBtn.Activated:Connect(function() screenGui:Destroy() end)

    -- Resize grip
    local resizeHandle = Instance.new("TextButton")
    resizeHandle.Name = "Resize"
    resizeHandle.Size = UDim2.fromOffset(14, 14)
    resizeHandle.Position = UDim2.new(1, -16, 1, -16)
    resizeHandle.BackgroundColor3 = C.accent
    resizeHandle.BackgroundTransparency = 0.5
    resizeHandle.AutoButtonColor = false
    resizeHandle.Text = ""
    resizeHandle.BorderSizePixel = 0
    resizeHandle.ZIndex = 5
    resizeHandle.Parent = frame
    Instance.new("UICorner", resizeHandle).CornerRadius = UDim.new(0, 4)
    -- Three small dots for the grip icon
    for i = 0, 2 do
        local dot = Instance.new("Frame")
        dot.Size = UDim2.fromOffset(3, 3)
        dot.Position = UDim2.fromOffset(3 + i * 4, 8 - i * 3)
        dot.BackgroundColor3 = C.text
        dot.BackgroundTransparency = 0.4
        dot.BorderSizePixel = 0
        dot.ZIndex = 6
        dot.Parent = resizeHandle
        Instance.new("UICorner", dot).CornerRadius = UDim.new(1, 0)
    end

    -- Tabs — underline style
    local TAB_COUNT = 3
    local tabContainer = Instance.new("Frame")
    tabContainer.Name = "TabBar"
    tabContainer.Size = UDim2.new(1, -20, 0, 30)
    tabContainer.Position = UDim2.new(0, 10, 0, 40)
    tabContainer.BackgroundColor3 = C.surface
    tabContainer.BorderSizePixel = 0
    tabContainer.Parent = frame
    Instance.new("UICorner", tabContainer).CornerRadius = UDim.new(0, 8)

    local tabIndicator = Instance.new("Frame")
    tabIndicator.Name = "Indicator"
    tabIndicator.Size = UDim2.new(1 / TAB_COUNT, -4, 0, 3)
    tabIndicator.Position = UDim2.new(0, 2, 1, -3)
    tabIndicator.BackgroundColor3 = C.accent
    tabIndicator.BorderSizePixel = 0
    tabIndicator.ZIndex = 3
    tabIndicator.Parent = tabContainer
    Instance.new("UICorner", tabIndicator).CornerRadius = UDim.new(0, 2)

    local tabButtons = {}
    local function makeTabButton(name, index)
        local b = Instance.new("TextButton")
        b.Name = name .. "Tab"
        b.Size = UDim2.new(1 / TAB_COUNT, 0, 1, -3)
        b.Position = UDim2.new((index - 1) / TAB_COUNT, 0, 0, 0)
        b.BackgroundTransparency = 1
        b.Text = name
        b.TextColor3 = C.textDim
        b.Font = Enum.Font.GothamBold
        b.TextSize = 11
        b.BorderSizePixel = 0
        b.ZIndex = 2
        b.Parent = tabContainer
        tabButtons[index] = b
        return b
    end
    local lobbyTab = makeTabButton("Lobby", 1)
    local playTab = makeTabButton("Play", 2)
    local ingameTab = makeTabButton("In-Game", 3)

    local function makePage(name)
        local p = Instance.new("Frame")
        p.Name = name .. "Page"
        p.BackgroundTransparency = 1
        p.Position = UDim2.new(0, 0, 0, 76)
        p.Size = UDim2.new(1, 0, 1, -76)
        p.Parent = frame
        return p
    end
    local lobbyPage = makePage("Lobby")
    local playPage = makePage("Play")
    local ingamePage = makePage("InGame")

    -- Shared widgets
    local busy = false
    local function makeButton(pageParent, name, label, color, yPos)
        local btn = Instance.new("TextButton")
        btn.Name = name
        btn.Size = UDim2.new(1, -20, 0, 36)
        btn.Position = UDim2.new(0, 10, 0, yPos)
        btn.BackgroundColor3 = color
        btn.Text = label
        btn.TextColor3 = C.text
        btn.Font = Enum.Font.GothamBold
        btn.TextSize = 13
        btn.BorderSizePixel = 0
        btn.AutoButtonColor = false
        btn.Parent = pageParent
        Instance.new("UICorner", btn).CornerRadius = UDim.new(0, 8)
        local btnGrad = Instance.new("UIGradient")
        btnGrad.Rotation = 90
        btnGrad.Transparency = NumberSequence.new({
            NumberSequenceKeypoint.new(0, 0),
            NumberSequenceKeypoint.new(1, 0.3),
        })
        btnGrad.Parent = btn
        btn.MouseEnter:Connect(function()
            TweenService:Create(btn, TWEEN_FAST, {BackgroundColor3 = Color3.new(
                math.min(color.R * 1.2, 1), math.min(color.G * 1.2, 1), math.min(color.B * 1.2, 1)
            )}):Play()
        end)
        btn.MouseLeave:Connect(function()
            TweenService:Create(btn, TWEEN_FAST, {BackgroundColor3 = color}):Play()
        end)
        return btn
    end

    local function bind(button, label, action)
        button.Activated:Connect(function()
            if busy then return end
            busy = true
            button.Text = "Working..."
            local ok, message = pcall(action)
            if ok then
                button.Text = tostring(message)
                print("[AnimeSquadron] " .. label .. ": " .. tostring(message))
            else
                button.Text = "Error - retry"
                warn("[AnimeSquadron] " .. label .. " failed:", message)
            end
            task.wait(1)
            button.Text = label
            busy = false
        end)
    end

    local function makeToggle(pageParent, name, label, yPos, onChanged)
        local row = Instance.new("Frame")
        row.Name = name .. "Row"
        row.Size = UDim2.new(1, -20, 0, 38)
        row.Position = UDim2.new(0, 10, 0, yPos)
        row.BackgroundColor3 = C.surface
        row.BorderSizePixel = 0
        row.Parent = pageParent
        Instance.new("UICorner", row).CornerRadius = UDim.new(0, 8)
        local rowStroke = Instance.new("UIStroke")
        rowStroke.Color = C.border
        rowStroke.Transparency = 0.7
        rowStroke.Parent = row

        local lbl = Instance.new("TextLabel")
        lbl.BackgroundTransparency = 1
        lbl.Size = UDim2.new(1, -64, 1, 0)
        lbl.Position = UDim2.new(0, 12, 0, 0)
        lbl.TextXAlignment = Enum.TextXAlignment.Left
        lbl.Text = label
        lbl.TextColor3 = C.text
        lbl.Font = Enum.Font.GothamMedium
        lbl.TextSize = 12
        lbl.Parent = row

        local track = Instance.new("TextButton")
        track.Size = UDim2.fromOffset(44, 22)
        track.Position = UDim2.new(1, -52, 0.5, -11)
        track.Text = ""
        track.AutoButtonColor = false
        track.BorderSizePixel = 0
        track.BackgroundColor3 = C.trackOff
        track.Parent = row
        Instance.new("UICorner", track).CornerRadius = UDim.new(1, 0)

        local knob = Instance.new("Frame")
        knob.Size = UDim2.fromOffset(18, 18)
        knob.Position = UDim2.new(0, 2, 0.5, -9)
        knob.BackgroundColor3 = C.text
        knob.BorderSizePixel = 0
        knob.Parent = track
        Instance.new("UICorner", knob).CornerRadius = UDim.new(1, 0)
        -- Knob shadow
        local knobStroke = Instance.new("UIStroke")
        knobStroke.Color = Color3.fromRGB(0, 0, 0)
        knobStroke.Transparency = 0.8
        knobStroke.Thickness = 1
        knobStroke.Parent = knob

        local state = false
        local function render()
            if state then
                TweenService:Create(track, TWEEN_MED, {BackgroundColor3 = C.green}):Play()
                TweenService:Create(knob, TWEEN_MED, {Position = UDim2.new(1, -20, 0.5, -9)}):Play()
            else
                TweenService:Create(track, TWEEN_MED, {BackgroundColor3 = C.trackOff}):Play()
                TweenService:Create(knob, TWEEN_MED, {Position = UDim2.new(0, 2, 0.5, -9)}):Play()
            end
        end
        -- Hover glow on row
        row.InputBegan:Connect(function(input)
            if input.UserInputType == Enum.UserInputType.MouseMovement then
                TweenService:Create(rowStroke, TWEEN_FAST, {Transparency = 0.3}):Play()
            end
        end)
        row.InputEnded:Connect(function(input)
            if input.UserInputType == Enum.UserInputType.MouseMovement then
                TweenService:Create(rowStroke, TWEEN_FAST, {Transparency = 0.7}):Play()
            end
        end)
        track.Activated:Connect(function()
            state = not state
            render()
            print("[AnimeSquadron] " .. label .. ": " .. (state and "ON" or "OFF"))
            if onChanged then task.spawn(onChanged, state) end
        end)
        return {
            get = function() return state end,
            set = function(val)
                if state ~= val then
                    state = val
                    render()
                    if onChanged then task.spawn(onChanged, state) end
                end
            end,
        }
    end

    local dropdownClosers = {}
    local function closeAllDropdowns()
        for _, fn in ipairs(dropdownClosers) do fn() end
    end

    local function makeDropdown(pageParent, name, yPos, options, onSelect, placeholder)
        local selected = placeholder and nil or options[1].value
        local isOpen = false

        local header = Instance.new("TextButton")
        header.Name = name
        header.Size = UDim2.new(1, -20, 0, 34)
        header.Position = UDim2.new(0, 10, 0, yPos)
        header.BackgroundColor3 = C.surface
        header.TextXAlignment = Enum.TextXAlignment.Left
        header.TextColor3 = C.text
        header.Font = Enum.Font.GothamMedium
        header.TextSize = 12
        header.BorderSizePixel = 0
        header.AutoButtonColor = false
        header.Parent = pageParent
        Instance.new("UICorner", header).CornerRadius = UDim.new(0, 8)
        local headerStroke = Instance.new("UIStroke")
        headerStroke.Color = C.border
        headerStroke.Transparency = 0.6
        headerStroke.Parent = header

        -- Chevron indicator
        local chevron = Instance.new("TextLabel")
        chevron.BackgroundTransparency = 1
        chevron.Size = UDim2.fromOffset(20, 34)
        chevron.Position = UDim2.new(1, -28, 0, 0)
        chevron.Text = "v"
        chevron.TextColor3 = C.textDim
        chevron.Font = Enum.Font.GothamBold
        chevron.TextSize = 11
        chevron.Parent = header

        local function setHeaderText(txt)
            header.Text = "   " .. txt
        end
        setHeaderText(placeholder or options[1].text)

        header.MouseEnter:Connect(function()
            TweenService:Create(headerStroke, TWEEN_FAST, {Color = C.accent, Transparency = 0.2}):Play()
        end)
        header.MouseLeave:Connect(function()
            if not isOpen then
                TweenService:Create(headerStroke, TWEEN_FAST, {Color = C.border, Transparency = 0.6}):Play()
            end
        end)

        local MAX_VISIBLE = 8
        local ROW_H = 30
        local visibleRows = math.min(#options, MAX_VISIBLE)
        local list = Instance.new("ScrollingFrame")
        list.Name = name .. "_Options"
        list.Size = UDim2.new(1, -20, 0, visibleRows * ROW_H)
        list.Position = UDim2.new(0, 10, 0, yPos + 36)
        list.BackgroundColor3 = C.elevated
        list.BorderSizePixel = 0
        list.Visible = false
        list.ZIndex = 100
        list.CanvasSize = UDim2.fromOffset(0, #options * ROW_H)
        list.ScrollBarThickness = 4
        list.ScrollBarImageColor3 = C.accent
        list.ScrollingDirection = Enum.ScrollingDirection.Y
        list.Parent = pageParent
        Instance.new("UICorner", list).CornerRadius = UDim.new(0, 8)
        local listStroke = Instance.new("UIStroke")
        listStroke.Color = C.accent
        listStroke.Transparency = 0.3
        listStroke.Parent = list
        Instance.new("UIListLayout", list).SortOrder = Enum.SortOrder.LayoutOrder

        local function makeOption(opt, i)
            local ob = Instance.new("TextButton")
            ob.Size = UDim2.new(1, 0, 0, ROW_H)
            ob.BackgroundColor3 = C.elevated
            ob.BackgroundTransparency = 0
            ob.BorderSizePixel = 0
            ob.Text = "  " .. opt.text
            ob.TextXAlignment = Enum.TextXAlignment.Left
            ob.TextColor3 = C.text
            ob.Font = Enum.Font.GothamMedium
            ob.TextSize = 12
            ob.ZIndex = 101
            ob.AutoButtonColor = false
            ob.LayoutOrder = i
            ob.Parent = list
            ob.MouseEnter:Connect(function()
                TweenService:Create(ob, TWEEN_FAST, {BackgroundColor3 = C.accent, BackgroundTransparency = 0.3}):Play()
            end)
            ob.MouseLeave:Connect(function()
                TweenService:Create(ob, TWEEN_FAST, {BackgroundColor3 = C.elevated, BackgroundTransparency = 0}):Play()
            end)
            ob.Activated:Connect(function()
                selected = opt.value
                setHeaderText(opt.text)
                list.Visible = false
                isOpen = false
                TweenService:Create(headerStroke, TWEEN_FAST, {Color = C.border, Transparency = 0.6}):Play()
                if onSelect then task.spawn(onSelect, opt) end
            end)
        end

        for i, opt in ipairs(options) do
            makeOption(opt, i)
        end

        local function close()
            list.Visible = false
            isOpen = false
            TweenService:Create(headerStroke, TWEEN_FAST, {Color = C.border, Transparency = 0.6}):Play()
        end
        table.insert(dropdownClosers, close)

        header.Activated:Connect(function()
            if isOpen then close() return end
            closeAllDropdowns()
            list.Visible = true
            isOpen = true
            TweenService:Create(headerStroke, TWEEN_FAST, {Color = C.accent, Transparency = 0}):Play()
        end)

        local function updateOptions(newOptions, ph)
            selected = nil
            setHeaderText(ph or "Select...")
            for _, c in ipairs(list:GetChildren()) do
                if c:IsA("TextButton") then c:Destroy() end
            end
            local vr = math.min(#newOptions, MAX_VISIBLE)
            list.Size = UDim2.new(1, -20, 0, vr * ROW_H)
            list.CanvasSize = UDim2.fromOffset(0, #newOptions * ROW_H)
            for i, opt in ipairs(newOptions) do
                makeOption(opt, i)
            end
            options = newOptions
        end

        return {
            get = function() return selected end,
            set = function(val)
                for _, opt in ipairs(options) do
                    if opt.value == val then
                        selected = val
                        setHeaderText(opt.text)
                        return
                    end
                end
            end,
            update = updateOptions,
        }
    end

    ------------------------------------------------------------------
    -- SUMMON PAGE
    ------------------------------------------------------------------
    -- Auto-summon toggles: while on, summon repeatedly but ONLY when the gem
    -- balance covers the cost (x1 = 50, x10 = 500). A shared lock keeps the two
    -- loops from overlapping; a rejected pull would cost nothing anyway.
    local autoSummon = { [1] = false, [10] = false }
    local summonLock = false
    local function startAutoSummon(amount)
        task.spawn(function()
            while screenGui.Parent and autoSummon[amount] do
                local gems = getGems()
                if gems and gems >= SUMMON_COST[amount] and not summonLock then
                    summonLock = true
                    pcall(function() Summon("Basic Banner", amount) end)
                    summonLock = false
                    task.wait(1.2)          -- respect the summon cooldown
                else
                    task.wait(2.5)          -- not enough gems / busy: poll less often
                end
            end
        end)
    end
    local tAutoSummon1 = makeToggle(lobbyPage, "AutoSummon1",  "Auto Summon x1 (50)",   4, function(on)
        autoSummon[1] = on
        if on then startAutoSummon(1) end
    end)
    local tAutoSummon10 = makeToggle(lobbyPage, "AutoSummon10", "Auto Summon x10 (500)", 44, function(on)
        autoSummon[10] = on
        if on then startAutoSummon(10) end
    end)

    local lockState = { Mythic = false, Legendary = false }
    local tLockMythic = makeToggle(lobbyPage, "LockMythic", "Auto-Lock Mythic", 84, function(on)
        lockState.Mythic = on
        if on then AutoLock({ Mythic = true }) end
    end)
    local tLockLegend = makeToggle(lobbyPage, "LockLegend", "Auto-Lock Legendary", 124, function(on)
        lockState.Legendary = on
        if on then AutoLock({ Legendary = true }) end
    end)

    task.spawn(function()
        while screenGui.Parent do
            if (lockState.Mythic or lockState.Legendary) and not busy then
                local targetSet = {}
                if lockState.Mythic then targetSet.Mythic = true end
                if lockState.Legendary then targetSet.Legendary = true end
                AutoLock(targetSet)
            end
            task.wait(2.5)
        end
    end)

    ------------------------------------------------------------------
    -- PLAY PAGE
    ------------------------------------------------------------------
    local selectedMode = "Story"
    local challengeData = {}

    local function refreshMapDropdown() end
    local function refreshChapterDropdown() end

    local modeOptions = {
        { text = "Story", value = "Story" },
        { text = "Squadron", value = "Squadron" },
        { text = "Challenge", value = "Challenge" },
        { text = "Raid", value = "Raid" },
    }

    local chapterDropdown
    local mapDropdown

    local modeDropdown = makeDropdown(playPage, "ModeSelect", 4, modeOptions, function(opt)
        selectedMode = opt.value
        local maps = getMapsForMode(selectedMode)
        local mapOpts = {}
        if selectedMode == "Challenge" then
            challengeData = {}
            for _, m in ipairs(maps) do
                if type(m) == "table" then
                    table.insert(mapOpts, { text = m.text, value = m.value })
                    challengeData[m.value] = m
                end
            end
        else
            for _, name in ipairs(maps) do
                table.insert(mapOpts, { text = name, value = name })
            end
        end
        if #mapOpts == 0 then
            table.insert(mapOpts, { text = "No maps available", value = "" })
        end
        mapDropdown.update(mapOpts, "Map")
        chapterDropdown.update({}, "Chapter")
    end)

    mapDropdown = makeDropdown(playPage, "MapSelect", 42, {{ text = "Map", value = "" }}, function(opt)
        if selectedMode == "Challenge" then
            chapterDropdown.update({{ text = "Auto", value = 1 }}, "Chapter")
        else
            local chapters = getChaptersForMode(selectedMode, opt.value)
            if #chapters == 0 then
                chapters = {{ text = "Chapter 1", value = 1 }}
            end
            chapterDropdown.update(chapters, "Chapter")
        end
    end, "Map")

    chapterDropdown = makeDropdown(playPage, "ChapterSelect", 80, {{ text = "Chapter", value = "" }}, nil, "Chapter")

    local difficulty = "Normal"
    local tHardMode = makeToggle(playPage, "HardMode", "Hard Mode", 118, function(on)
        difficulty = on and "Hard" or "Normal"
    end)

    local autoReplay = false
    local tAutoReplay = makeToggle(playPage, "AutoReplay", "Auto-Replay", 156, function(on)
        autoReplay = on
    end)

    local autoLeave = false
    local tAutoLeave = makeToggle(playPage, "AutoLeave", "Auto-Leave on End", 194, function(on)
        autoLeave = on
    end)

    local autoJoin = false
    local joinBusy = false
    local tAutoJoin = makeToggle(playPage, "AutoJoin", "Auto-Join Map", 234, function(on)
        autoJoin = on
        if on then
            task.spawn(function()
                while screenGui.Parent and autoJoin do
                    if isInLobby() and not joinBusy then
                        joinBusy = true
                        pcall(function()
                            local world = mapDropdown.get()
                            local chapter = chapterDropdown.get()
                            if selectedMode == "Challenge" and challengeData[world] then
                                local cd = challengeData[world]
                                AutoJoinMap(cd.world or world, cd.act or 1, difficulty, "Challenge")
                            else
                                AutoJoinMap(world, chapter or 1, difficulty, selectedMode)
                            end
                        end)
                        task.wait(5)
                        joinBusy = false
                    else
                        task.wait(2)
                    end
                end
            end)
        end
    end)

    local tAutoExec = makeToggle(playPage, "AutoExec", "Auto-Execute on Teleport", 272, function(on)
        local env = getgenv and getgenv()
        if env then env._AnimeSquadronAutoExec = on end
        if on then
            local src = env and env._AnimeSquadronSource
            if src and #src > 0 then
                queue_on_teleport(src)
                print("[AnimeSquadron] Queued for next teleport (" .. #src .. " bytes)")
            else
                warn("[AnimeSquadron] No cached source to queue")
            end
        else
            queue_on_teleport("")
            print("[AnimeSquadron] Teleport queue cleared")
        end
    end)

    ------------------------------------------------------------------
    -- SETTINGS PERSISTENCE
    ------------------------------------------------------------------
    local _SETTINGS_PATH = "workspace/AnimeSquadron_settings.json"

    local function saveSettings()
        local data = {
            AutoSummon1 = tAutoSummon1.get(),
            AutoSummon10 = tAutoSummon10.get(),
            LockMythic = tLockMythic.get(),
            LockLegend = tLockLegend.get(),
            Mode = modeDropdown.get(),
            Map = mapDropdown.get(),
            Chapter = chapterDropdown.get(),
            HardMode = tHardMode.get(),
            AutoReplay = tAutoReplay.get(),
            AutoLeave = tAutoLeave.get(),
            AutoJoin = tAutoJoin.get(),
            AutoExec = tAutoExec.get(),
            AutoNext = tAutoNext.get(),
        }
        local parts = {}
        for k, v in pairs(data) do
            local val = tostring(v)
            if type(v) == "string" then val = '"' .. v .. '"' end
            table.insert(parts, '"' .. k .. '":' .. val)
        end
        local json = "{" .. table.concat(parts, ",") .. "}"
        pcall(function() writefile(_SETTINGS_PATH, json) end)
        return json
    end

    local function loadSettings()
        local ok, raw = pcall(readfile, _SETTINGS_PATH)
        if not ok or not raw or #raw < 2 then return false end
        local data = {}
        for k, v in raw:gmatch('"(%w+)":([^,}]+)') do
            v = v:match("^%s*(.-)%s*$")
            if v == "true" then data[k] = true
            elseif v == "false" then data[k] = false
            elseif tonumber(v) then data[k] = tonumber(v)
            else data[k] = v:gsub('"', '')
            end
        end
        if data.Mode then
            modeDropdown.set(data.Mode)
            selectedMode = data.Mode
            local maps = getMapsForMode(selectedMode)
            local mapOpts = {}
            if selectedMode == "Challenge" then
                challengeData = {}
                for _, m in ipairs(maps) do
                    if type(m) == "table" then
                        table.insert(mapOpts, { text = m.text, value = m.value })
                        challengeData[m.value] = m
                    end
                end
            else
                for _, name in ipairs(maps) do
                    table.insert(mapOpts, { text = name, value = name })
                end
            end
            if #mapOpts > 0 then
                mapDropdown.update(mapOpts, "Map")
            end
        end
        if data.Map then
            mapDropdown.set(data.Map)
            if selectedMode == "Challenge" then
                chapterDropdown.update({{ text = "Auto", value = 1 }}, "Chapter")
            else
                local chapters = getChaptersForMode(selectedMode, data.Map)
                if #chapters > 0 then chapterDropdown.update(chapters, "Chapter") end
            end
        end
        if data.Chapter then chapterDropdown.set(data.Chapter) end
        if data.HardMode ~= nil then tHardMode.set(data.HardMode) end
        if data.AutoReplay ~= nil then tAutoReplay.set(data.AutoReplay) end
        if data.AutoLeave ~= nil then tAutoLeave.set(data.AutoLeave) end
        if data.AutoJoin ~= nil then tAutoJoin.set(data.AutoJoin) end
        if data.AutoExec ~= nil then tAutoExec.set(data.AutoExec) end
        if data.AutoSummon1 ~= nil then tAutoSummon1.set(data.AutoSummon1) end
        if data.AutoSummon10 ~= nil then tAutoSummon10.set(data.AutoSummon10) end
        if data.LockMythic ~= nil then tLockMythic.set(data.LockMythic) end
        if data.LockLegend ~= nil then tLockLegend.set(data.LockLegend) end
        if data.AutoNext ~= nil then tAutoNext.set(data.AutoNext) end
        return true
    end

    local function makeSaveButton(pageParent, yPos)
        local btn = Instance.new("TextButton")
        btn.Name = "SaveSettings"
        btn.Size = UDim2.new(1, -20, 0, 32)
        btn.Position = UDim2.new(0, 10, 0, yPos)
        btn.BackgroundColor3 = C.save
        btn.Text = "Save Settings"
        btn.TextColor3 = C.text
        btn.Font = Enum.Font.GothamBold
        btn.TextSize = 12
        btn.BorderSizePixel = 0
        btn.AutoButtonColor = false
        btn.Parent = pageParent
        Instance.new("UICorner", btn).CornerRadius = UDim.new(0, 8)
        btn.MouseEnter:Connect(function()
            TweenService:Create(btn, TWEEN_FAST, {BackgroundColor3 = C.saveLit}):Play()
        end)
        btn.MouseLeave:Connect(function()
            TweenService:Create(btn, TWEEN_FAST, {BackgroundColor3 = C.save}):Play()
        end)
        bind(btn, "Save Settings", function()
            saveSettings()
            return "Settings Saved!"
        end)
        return btn
    end
    ------------------------------------------------------------------
    -- IN-GAME PAGE
    ------------------------------------------------------------------
    local autoNext = false
    local tAutoNext = makeToggle(ingamePage, "AutoNext", "Auto-Next Chapter", 4, function(on)
        autoNext = on
    end)

    makeSaveButton(lobbyPage, 164)
    makeSaveButton(playPage, 312)
    makeSaveButton(ingamePage, 44)

    -- Auto-load saved settings on startup
    if loadSettings() then
        print("[AnimeSquadron] Settings loaded from file")
    end

    -- Match end is signalled by Remotes.Game.ending (fires only in a match).
    local endingRemote = GameRemotes and GameRemotes:FindFirstChild("ending")
    local replayRemote = GameRemotes and GameRemotes:FindFirstChild("replay")
    local endBusy = false
    local function onMatchEnded()
        if endBusy or not screenGui.Parent then return end
        if not (autoReplay or autoLeave or autoNext) then return end
        endBusy = true
        task.wait(1)
        if autoNext then
            local pg = Players.LocalPlayer and Players.LocalPlayer:FindFirstChild("PlayerGui")
            local endScreen = pg and pg:FindFirstChild("Menus") and pg.Menus:FindFirstChild("EndScreen")
            local buttons = endScreen and endScreen:FindFirstChild("Buttons")
            local nextBtn = buttons and buttons:FindFirstChild("Next")
            if nextBtn and nextBtn.Visible then
                runLow(function()
                    clickGameUIButton(nextBtn)
                end)
                task.wait(1.5)
                endBusy = false
                return
            end
        end
        if autoReplay and replayRemote then
            runLow(function() replayRemote:FireServer() end)
        elseif autoLeave and MainModule and MainModule.on_teleport then
            runLow(function() MainModule.on_teleport() end)
        end
        task.wait(1.5)
        endBusy = false
    end
    if endingRemote then
        endingRemote.OnClientEvent:Connect(onMatchEnded)
    end

    ------------------------------------------------------------------
    -- Tab switching + dragging
    ------------------------------------------------------------------
    local tabMap = { Lobby = 1, Play = 2, InGame = 3 }
    local function switchTab(which)
        closeAllDropdowns()
        lobbyPage.Visible = (which == "Lobby")
        playPage.Visible = (which == "Play")
        ingamePage.Visible = (which == "InGame")
        local idx = tabMap[which] or 1
        TweenService:Create(tabIndicator, TWEEN_MED, {
            Position = UDim2.new((idx - 1) / TAB_COUNT, 2, 1, -3)
        }):Play()
        for i, btn in ipairs(tabButtons) do
            TweenService:Create(btn, TWEEN_FAST, {
                TextColor3 = (i == idx) and C.text or C.textDim
            }):Play()
        end
    end
    lobbyTab.Activated:Connect(function() switchTab("Lobby") end)
    playTab.Activated:Connect(function() switchTab("Play") end)
    ingameTab.Activated:Connect(function() switchTab("InGame") end)
    switchTab("Lobby")

    local UserInputService = game:GetService("UserInputService")
    local dragging, dragStart, startPos
    titleBar.InputBegan:Connect(function(input)
        if input.UserInputType == Enum.UserInputType.MouseButton1
            or input.UserInputType == Enum.UserInputType.Touch then
            closeAllDropdowns()
            dragging = true
            dragStart = input.Position
            startPos = frame.Position
            input.Changed:Connect(function()
                if input.UserInputState == Enum.UserInputState.End then dragging = false end
            end)
        end
    end)

    local resizing, resizeStart, startScale
    resizeHandle.InputBegan:Connect(function(input)
        if input.UserInputType == Enum.UserInputType.MouseButton1
            or input.UserInputType == Enum.UserInputType.Touch then
            closeAllDropdowns()
            resizing = true
            resizeStart = input.Position
            startScale = uiScale.Scale
            input.Changed:Connect(function()
                if input.UserInputState == Enum.UserInputState.End then resizing = false end
            end)
        end
    end)

    UserInputService.InputChanged:Connect(function(input)
        if input.UserInputType ~= Enum.UserInputType.MouseMovement
            and input.UserInputType ~= Enum.UserInputType.Touch then
            return
        end
        if dragging then
            local delta = input.Position - dragStart
            frame.Position = UDim2.new(
                startPos.X.Scale, startPos.X.Offset + delta.X,
                startPos.Y.Scale, startPos.Y.Offset + delta.Y
            )
        elseif resizing then
            local delta = input.Position - resizeStart
            uiScale.Scale = math.clamp(startScale + (delta.X + delta.Y) / 400, 0.6, 2.5)
        end
    end)

    return screenGui
end

--========================================================
--  RUN
--========================================================
buildGui()
