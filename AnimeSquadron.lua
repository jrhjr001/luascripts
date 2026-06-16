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

    local frame = Instance.new("Frame")
    frame.Name = "Main"
    frame.Size = UDim2.fromOffset(230, 430)
    frame.Position = UDim2.fromScale(0.5, 0.4)
    frame.AnchorPoint = Vector2.new(0.5, 0.5)
    frame.BackgroundColor3 = Color3.fromRGB(28, 28, 34)
    frame.BorderSizePixel = 0
    frame.Active = true
    frame.Parent = screenGui
    local corner = Instance.new("UICorner"); corner.CornerRadius = UDim.new(0, 8); corner.Parent = frame
    local stroke = Instance.new("UIStroke"); stroke.Color = Color3.fromRGB(70, 70, 90); stroke.Parent = frame

    -- UIScale drives resizing: scaling this one value uniformly resizes the whole
    -- window AND its text/fonts (everything is a descendant of the frame), so font
    -- size stays tied to the GUI size. The resize grip at the bottom-right edits it.
    local uiScale = Instance.new("UIScale")
    uiScale.Scale = 1
    uiScale.Parent = frame

    local titleBar = Instance.new("TextLabel")
    titleBar.Name = "TitleBar"
    titleBar.Size = UDim2.new(1, 0, 0, 32)
    titleBar.BackgroundColor3 = Color3.fromRGB(40, 40, 50)
    titleBar.BorderSizePixel = 0
    titleBar.Text = "Anime Squadron"
    titleBar.TextColor3 = Color3.fromRGB(235, 235, 245)
    titleBar.Font = Enum.Font.GothamBold
    titleBar.TextSize = 14
    titleBar.Parent = frame
    local titleCorner = Instance.new("UICorner"); titleCorner.CornerRadius = UDim.new(0, 8); titleCorner.Parent = titleBar

    local closeBtn = Instance.new("TextButton")
    closeBtn.Name = "Close"
    closeBtn.Size = UDim2.fromOffset(22, 22)
    closeBtn.Position = UDim2.new(1, -27, 0, 5)
    closeBtn.BackgroundColor3 = Color3.fromRGB(220, 60, 60)
    closeBtn.Text = "X"
    closeBtn.TextColor3 = Color3.fromRGB(255, 255, 255)
    closeBtn.Font = Enum.Font.GothamBold
    closeBtn.TextSize = 13
    closeBtn.BorderSizePixel = 0
    closeBtn.ZIndex = 2
    closeBtn.Parent = titleBar
    local closeCorner = Instance.new("UICorner"); closeCorner.CornerRadius = UDim.new(0, 6); closeCorner.Parent = closeBtn
    closeBtn.Activated:Connect(function() screenGui:Destroy() end)

    -- Resize grip (bottom-right). Dragging it edits the UIScale, scaling the whole
    -- window and its fonts together. Clamped so it can't get unusably small/large.
    local resizeHandle = Instance.new("TextButton")
    resizeHandle.Name = "Resize"
    resizeHandle.Size = UDim2.fromOffset(16, 16)
    resizeHandle.Position = UDim2.new(1, -18, 1, -18)
    resizeHandle.AnchorPoint = Vector2.new(0, 0)
    resizeHandle.BackgroundColor3 = Color3.fromRGB(88, 101, 242)
    resizeHandle.AutoButtonColor = false
    resizeHandle.Text = "//"
    resizeHandle.TextColor3 = Color3.fromRGB(255, 255, 255)
    resizeHandle.TextSize = 11
    resizeHandle.Font = Enum.Font.GothamBold
    resizeHandle.BorderSizePixel = 0
    resizeHandle.ZIndex = 5
    resizeHandle.Parent = frame
    local rhc = Instance.new("UICorner"); rhc.CornerRadius = UDim.new(0, 4); rhc.Parent = resizeHandle

    -- Tabs
    local ACTIVE_TAB = Color3.fromRGB(88, 101, 242)
    local INACTIVE_TAB = Color3.fromRGB(50, 50, 62)
    local function makeTabButton(name, posScale)
        local b = Instance.new("TextButton")
        b.Name = name .. "Tab"
        b.Size = UDim2.new(0.5, -12, 0, 26)
        b.Position = UDim2.new(posScale, posScale == 0 and 8 or 4, 0, 38)
        b.BackgroundColor3 = INACTIVE_TAB
        b.Text = name
        b.TextColor3 = Color3.fromRGB(235, 235, 245)
        b.Font = Enum.Font.GothamBold
        b.TextSize = 13
        b.BorderSizePixel = 0
        b.Parent = frame
        local c = Instance.new("UICorner"); c.CornerRadius = UDim.new(0, 6); c.Parent = b
        return b
    end
    local summonTab = makeTabButton("Summon", 0)
    local playTab = makeTabButton("Play", 0.5)

    local function makePage(name)
        local p = Instance.new("Frame")
        p.Name = name .. "Page"
        p.BackgroundTransparency = 1
        p.Position = UDim2.new(0, 0, 0, 70)
        p.Size = UDim2.new(1, 0, 1, -70)
        p.Parent = frame
        return p
    end
    local summonPage = makePage("Summon")
    local playPage = makePage("Play")

    -- Shared widgets
    local busy = false
    local function makeButton(pageParent, name, label, color, yPos)
        local btn = Instance.new("TextButton")
        btn.Name = name
        btn.Size = UDim2.new(1, -20, 0, 38)
        btn.Position = UDim2.new(0, 10, 0, yPos)
        btn.BackgroundColor3 = color
        btn.Text = label
        btn.TextColor3 = Color3.fromRGB(255, 255, 255)
        btn.Font = Enum.Font.GothamBold
        btn.TextSize = 14
        btn.BorderSizePixel = 0
        btn.Parent = pageParent
        local c = Instance.new("UICorner"); c.CornerRadius = UDim.new(0, 6); c.Parent = btn
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
        row.Size = UDim2.new(1, -20, 0, 36)
        row.Position = UDim2.new(0, 10, 0, yPos)
        row.BackgroundColor3 = Color3.fromRGB(40, 40, 50)
        row.BorderSizePixel = 0
        row.Parent = pageParent
        local rc = Instance.new("UICorner"); rc.CornerRadius = UDim.new(0, 6); rc.Parent = row

        local lbl = Instance.new("TextLabel")
        lbl.BackgroundTransparency = 1
        lbl.Size = UDim2.new(1, -64, 1, 0)
        lbl.Position = UDim2.new(0, 10, 0, 0)
        lbl.TextXAlignment = Enum.TextXAlignment.Left
        lbl.Text = label
        lbl.TextColor3 = Color3.fromRGB(235, 235, 245)
        lbl.Font = Enum.Font.GothamBold
        lbl.TextSize = 13
        lbl.Parent = row

        local track = Instance.new("TextButton")
        track.Size = UDim2.fromOffset(42, 20)
        track.Position = UDim2.new(1, -50, 0.5, -10)
        track.Text = ""
        track.AutoButtonColor = false
        track.BorderSizePixel = 0
        track.BackgroundColor3 = Color3.fromRGB(80, 80, 92)
        track.Parent = row
        local tcc = Instance.new("UICorner"); tcc.CornerRadius = UDim.new(1, 0); tcc.Parent = track

        local knob = Instance.new("Frame")
        knob.Size = UDim2.fromOffset(16, 16)
        knob.Position = UDim2.new(0, 2, 0.5, -8)
        knob.BackgroundColor3 = Color3.fromRGB(240, 240, 245)
        knob.BorderSizePixel = 0
        knob.Parent = track
        local kc = Instance.new("UICorner"); kc.CornerRadius = UDim.new(1, 0); kc.Parent = knob

        local state = false
        local function render()
            if state then
                track.BackgroundColor3 = Color3.fromRGB(49, 201, 90)
                knob:TweenPosition(UDim2.new(1, -18, 0.5, -8), Enum.EasingDirection.Out, Enum.EasingStyle.Quad, 0.12, true)
            else
                track.BackgroundColor3 = Color3.fromRGB(80, 80, 92)
                knob:TweenPosition(UDim2.new(0, 2, 0.5, -8), Enum.EasingDirection.Out, Enum.EasingStyle.Quad, 0.12, true)
            end
        end
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
        header.Size = UDim2.new(1, -20, 0, 32)
        header.Position = UDim2.new(0, 10, 0, yPos)
        header.BackgroundColor3 = Color3.fromRGB(44, 44, 56)
        header.Text = "  " .. (placeholder or options[1].text) .. "      v"
        header.TextXAlignment = Enum.TextXAlignment.Left
        header.TextColor3 = Color3.fromRGB(235, 235, 245)
        header.Font = Enum.Font.GothamBold
        header.TextSize = 13
        header.BorderSizePixel = 0
        header.Parent = pageParent
        local hc = Instance.new("UICorner"); hc.CornerRadius = UDim.new(0, 6); hc.Parent = header

        -- The list is nested under the page (not the ScreenGui) so the frame's
        -- UIScale resizes it too; a high ZIndex keeps it above the other controls,
        -- and neither the page nor frame clips, so it overlays cleanly.
        local MAX_VISIBLE = 8
        local visibleRows = math.min(#options, MAX_VISIBLE)
        local list = Instance.new("ScrollingFrame")
        list.Name = name .. "_Options"
        list.Size = UDim2.new(1, -20, 0, visibleRows * 28)
        list.Position = UDim2.new(0, 10, 0, yPos + 34)
        list.BackgroundColor3 = Color3.fromRGB(24, 24, 30)
        list.BorderSizePixel = 0
        list.Visible = false
        list.ZIndex = 100
        list.CanvasSize = UDim2.fromOffset(0, #options * 28)
        list.ScrollBarThickness = 5
        list.ScrollingDirection = Enum.ScrollingDirection.Y
        list.Parent = pageParent
        local lc = Instance.new("UICorner"); lc.CornerRadius = UDim.new(0, 6); lc.Parent = list
        local ls = Instance.new("UIStroke"); ls.Color = Color3.fromRGB(88, 101, 242); ls.Parent = list
        local layout = Instance.new("UIListLayout"); layout.SortOrder = Enum.SortOrder.LayoutOrder; layout.Parent = list

        for i, opt in ipairs(options) do
            local ob = Instance.new("TextButton")
            ob.Size = UDim2.new(1, 0, 0, 28)
            ob.BackgroundColor3 = Color3.fromRGB(44, 44, 56)
            ob.BorderSizePixel = 0
            ob.Text = opt.text
            ob.TextColor3 = Color3.fromRGB(230, 230, 240)
            ob.Font = Enum.Font.Gotham
            ob.TextSize = 13
            ob.ZIndex = 101
            ob.LayoutOrder = i
            ob.Parent = list
            ob.Activated:Connect(function()
                selected = opt.value
                header.Text = "  " .. opt.text .. "      v"
                list.Visible = false
                isOpen = false
                if onSelect then task.spawn(onSelect, opt) end
            end)
        end

        local function close() list.Visible = false; isOpen = false end
        table.insert(dropdownClosers, close)

        header.Activated:Connect(function()
            if isOpen then close() return end
            closeAllDropdowns()
            list.Visible = true
            isOpen = true
        end)

        local function updateOptions(newOptions, placeholder)
            selected = nil
            header.Text = "  " .. (placeholder or "Select...") .. "      v"
            for _, c in ipairs(list:GetChildren()) do
                if c:IsA("TextButton") then c:Destroy() end
            end
            local visibleRows = math.min(#newOptions, MAX_VISIBLE)
            list.Size = UDim2.new(1, -20, 0, visibleRows * 28)
            list.CanvasSize = UDim2.fromOffset(0, #newOptions * 28)
            for i, opt in ipairs(newOptions) do
                local ob = Instance.new("TextButton")
                ob.Size = UDim2.new(1, 0, 0, 28)
                ob.BackgroundColor3 = Color3.fromRGB(44, 44, 56)
                ob.BorderSizePixel = 0
                ob.Text = opt.text
                ob.TextColor3 = Color3.fromRGB(230, 230, 240)
                ob.Font = Enum.Font.Gotham
                ob.TextSize = 13
                ob.ZIndex = 101
                ob.LayoutOrder = i
                ob.Parent = list
                ob.Activated:Connect(function()
                    selected = opt.value
                    header.Text = "  " .. opt.text .. "      v"
                    list.Visible = false
                    isOpen = false
                    if onSelect then task.spawn(onSelect, opt) end
                end)
            end
            options = newOptions
        end

        return {
            get = function() return selected end,
            set = function(val)
                for _, opt in ipairs(options) do
                    if opt.value == val then
                        selected = val
                        header.Text = "  " .. opt.text .. "      v"
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
    local tAutoSummon1 = makeToggle(summonPage, "AutoSummon1",  "Auto Summon x1 (50)",   4, function(on)
        autoSummon[1] = on
        if on then startAutoSummon(1) end
    end)
    local tAutoSummon10 = makeToggle(summonPage, "AutoSummon10", "Auto Summon x10 (500)", 44, function(on)
        autoSummon[10] = on
        if on then startAutoSummon(10) end
    end)

    local lockState = { Mythic = false, Legendary = false }
    local tLockMythic = makeToggle(summonPage, "LockMythic", "Auto-Lock Mythic", 84, function(on)
        lockState.Mythic = on
        if on then AutoLock({ Mythic = true }) end
    end)
    local tLockLegend = makeToggle(summonPage, "LockLegend", "Auto-Lock Legendary", 124, function(on)
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
    local tHardMode = makeToggle(playPage, "HardMode", "Hard Mode (off = Normal)", 118, function(on)
        difficulty = on and "Hard" or "Normal"
    end)

    local autoReplay = false
    local tAutoReplay = makeToggle(playPage, "AutoReplay", "Auto-Replay (in match)", 156, function(on)
        autoReplay = on
    end)

    local autoLeave = false
    local tAutoLeave = makeToggle(playPage, "AutoLeave", "Auto-Leave on End", 194, function(on)
        autoLeave = on
    end)

    local autoJoin = false
    local joinBusy = false
    local tAutoJoin = makeToggle(playPage, "AutoJoin", "Auto-Join Map (lobby)", 234, function(on)
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
        return true
    end

    local saveBtn = makeButton(playPage, "SaveSettings", "Save Settings", Color3.fromRGB(49, 130, 220), 312)
    bind(saveBtn, "Save Settings", function()
        saveSettings()
        return "Settings Saved!"
    end)

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
        if not (autoReplay or autoLeave) then return end
        endBusy = true
        task.wait(1)  -- let the results screen settle
        if autoReplay and replayRemote then
            runLow(function() replayRemote:FireServer() end)            -- native replay, same stage
        elseif autoLeave and MainModule and MainModule.on_teleport then
            runLow(function() MainModule.on_teleport() end)             -- return to lobby
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
    local function switchTab(which)
        closeAllDropdowns()
        local isSummon = (which == "Summon")
        summonPage.Visible = isSummon
        playPage.Visible = not isSummon
        summonTab.BackgroundColor3 = isSummon and ACTIVE_TAB or INACTIVE_TAB
        playTab.BackgroundColor3 = isSummon and INACTIVE_TAB or ACTIVE_TAB
    end
    summonTab.Activated:Connect(function() switchTab("Summon") end)
    playTab.Activated:Connect(function() switchTab("Play") end)
    switchTab("Summon")

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
