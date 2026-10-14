if getgenv then
    local env = getgenv()
    if env.ShijinHubLoaded then
        local sameGame = env.ShijinHubGame == game
        local staleLoad = env.ShijinHubLoaded == "loading"
            and (os.clock() - (tonumber(env.ShijinHubLoadT) or 0)) > 45
        if sameGame and not staleLoad then
            local lib = env.ShijinHubLibrary
            local alive = true
            if env.ShijinHubLoaded == true and type(lib) == "table" then
                alive = lib.ScreenGui ~= nil and lib.ScreenGui.Parent ~= nil
                if not alive then
                    -- Orion exposes no ScreenGui handle: fall back to the live GUI.
                    pcall(function()
                        local hui = (gethui and gethui()) or game:GetService("CoreGui")
                        local gui = hui and hui:FindFirstChild("Orion")
                        alive = gui ~= nil and gui.Parent ~= nil
                    end)
                end
            end
            if alive then
                warn("[ShijinHub] Already loaded (or still loading). Unload first to reload.")
                if env.ShijinHubLoaded == true and type(env.ShijinHubNotify) == "function" then
                    pcall(env.ShijinHubNotify, "Shijin Hub is already running - press RightShift for the menu", 8)
                end
                return
            end
        end
        env.ShijinHubLoaded = nil
        env.ShijinHubLibrary = nil
        env.ShijinHubNotify = nil
    end
    env.ShijinHubGame = game
    env.ShijinHubLoadT = os.clock()
    env.ShijinHubLoaded = "loading"
end
local ShijinUnloaded = false
-- True while the UI block below is being built: Orion fires every control
-- Callback once with its Default at creation, so build-time notifications
-- are suppressed until the hub is ready (see notify()).
local ShijinBuilding = false
local startSpeedLoop, startAutoSpinLoop, startStreamerLoop
local checkPlayerForMod

local HubConns = {}
local function safeDisconnect(conn)
    if conn then pcall(function() conn:Disconnect() end) end
end
local function hubConn(signal, fn)
    if not signal or type(fn) ~= "function" then return nil end
    local ok, conn = pcall(function() return signal:Connect(fn) end)
    if ok and conn then
        HubConns[#HubConns + 1] = conn
        return conn
    end
    return nil
end

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")

local VX = {
    set = {}, buf = {}, conns = {}, users = {}, on = false,
    cheapBuf = {}, scanFound = {}, predOwned = {}, predT = 0,
}
VX.clear = table.clear or function(t)
    for k in pairs(t) do t[k] = nil end
end
function VX.destroy(o) o:Destroy() end
function VX.disconnect(c) c:Disconnect() end
function VX.track(v)
    if not v or not v.Parent then return end
    local n = v.Name
    if type(n) == "string" and n:upper():find("BALL", 1, true) then
        VX.set[v] = true
    end
end
function VX.forget(v)
    VX.set[v] = nil
end
function VX.start()
    if VX.on then return end
    VX.on = true
    VX.clear(VX.set)
    for _, v in ipairs(Workspace:GetChildren()) do VX.track(v) end
    local okAdd, addConn = pcall(function() return Workspace.ChildAdded:Connect(VX.track) end)
    local okRemove, removeConn = pcall(function() return Workspace.ChildRemoved:Connect(VX.forget) end)
    if okAdd and addConn then VX.conns[#VX.conns + 1] = addConn end
    if okRemove and removeConn then VX.conns[#VX.conns + 1] = removeConn end
end
function VX.stop()
    if not VX.on and #VX.conns == 0 then return end
    VX.on = false
    for i = #VX.conns, 1, -1 do
        pcall(VX.disconnect, VX.conns[i])
        VX.conns[i] = nil
    end
    VX.clear(VX.set)
end
function VX.use(key, on)
    local enabled = on == true
    if VX.users[key] == enabled then return end
    VX.users[key] = enabled or nil
    if next(VX.users) then VX.start() else VX.stop() end
end
function VX.list()
    VX.clear(VX.buf)
    if not VX.on then
        for _, v in ipairs(Workspace:GetChildren()) do
            local n = v.Name
            if type(n) == "string" and n:upper():find("BALL", 1, true) then
                VX.buf[#VX.buf + 1] = v
            end
        end
        return VX.buf
    end
    for v in pairs(VX.set) do
        if v.Parent == Workspace then
            VX.buf[#VX.buf + 1] = v
        else
            VX.set[v] = nil
        end
    end
    return VX.buf
end

local LocalPlayer = Players.LocalPlayer
while not LocalPlayer do
    Players:GetPropertyChangedSignal("LocalPlayer"):Wait()
    LocalPlayer = Players.LocalPlayer
end

if not LocalPlayer:FindFirstChild("PlayerGui") then
    LocalPlayer:WaitForChild("PlayerGui", 10)
end

local ScriptVersion = "0.0.1 Beta"
local ScriptName = "Shijin Hub"

-- ORION SOURCE: https://raw.githubusercontent.com/Snxdfer/back-ups-for-libs/refs/heads/main/Orion.lua
-- (verified genuine Orion Lib 2026-10-14: MakeWindow/MakeTab/AddSection, Toggle/Slider/Dropdown/Colorpicker/Bind/Textbox/Label/Button, MakeNotification, SaveConfig+Flags, Destroy)
local OrionLib = loadstring(game:HttpGet("https://raw.githubusercontent.com/Snxdfer/back-ups-for-libs/refs/heads/main/Orion.lua"))()
local Library = OrionLib -- compat alias for the hub-loaded guard below
local Options = OrionLib.Flags

-- Dark gaming theme (deep navy background, purple surfaces, white text, rose
-- action accents). Applied by replacing the Default palette before any element
-- is created: Orion resolves theme colors at creation time, so everything
-- built afterwards picks this up.
OrionLib.Themes.Default = {
    Main = Color3.fromRGB(15, 15, 35),
    Second = Color3.fromRGB(30, 28, 53),
    Stroke = Color3.fromRGB(76, 29, 149),
    Divider = Color3.fromRGB(39, 39, 59),
    Text = Color3.fromRGB(255, 255, 255),
    TextDark = Color3.fromRGB(148, 163, 184),
}

-- Filesystem safety net: Orion core and the slot system both touch the
-- executor filesystem. On executors without one, install inert fallbacks so
-- nothing errors; every hub-side call site stays pcall-guarded regardless.
if type(isfile) ~= "function" then isfile = function() return false end end
if type(listfiles) ~= "function" then listfiles = function() return {} end end
if type(readfile) ~= "function" then readfile = function() return nil end end
if type(writefile) ~= "function" then writefile = function() return false end end
if type(makefolder) ~= "function" then makefolder = function() return false end end
if type(delfile) ~= "function" then delfile = function() return false end end

-- Forward-declared close callback (Lua binds upvalues at definition site);
-- assigned to the real cleanup near shijinFullCleanup in the Settings task.
local ShijinCloseCallback = function() end

if getgenv then getgenv().ShijinHubLoaded = true end
if getgenv then getgenv().ShijinHubLibrary = Library end

if type(newcclosure) ~= "function" then
    newcclosure = function(fn) return fn end
end

local FeatureConfig = {
    notifications = true,
    notificationLifetime = 6,
    hitboxMaxDistance = 120,
    hitboxUpdateRate = 0.12,
    hitboxMaterial = Enum.Material.ForceField,
    hitboxMaterialByName = {
        ForceField = Enum.Material.ForceField,
        Neon = Enum.Material.Neon,
        SmoothPlastic = Enum.Material.SmoothPlastic,
    },
    jumpEspFillTransparency = 0.5,
    jumpEspOutlineTransparency = 0,
    jumpEspMaxDistance = 250,
    jumpEspAlwaysOnTop = false,
    predictAimThickness = 0.12,
    predictAimTransparency = 0.15,
    predictAimMaxDistance = 250,
    jumpBoostRefreshRate = 0.12,
    streamerHideSelf = false,
    streamerRefreshRate = 3,
    speedMaxStep = 2.5,
    speedAllowAir = true,
    autoSpinPauseInLobby = true,
    autoSpinMaxFailures = 8,
    autoSpinRunId = 0,
    performanceLevel = "Balanced",
    performanceYieldEvery = 320,
}
local function notify(message, lifetime, force)
    if ShijinUnloaded or ShijinBuilding then return end
    if not force and not FeatureConfig.notifications then return end
    pcall(function()
        OrionLib:MakeNotification({
            Name = "◈ Shijin Hub",
            Content = tostring(message),
            Image = "rbxassetid://4483345998",
            Time = math.clamp(tonumber(lifetime) or FeatureConfig.notificationLifetime, 1, 15),
        })
    end)
end
if getgenv then getgenv().ShijinHubNotify = notify end

local HitboxEnabled = false
local HitboxSize = 10
local HitboxColor = Color3.fromRGB(0, 255, 0)
local HitboxTransparency = 0.8

local JumpESPEnabled = false
local JumpESPColor = Color3.fromRGB(255, 0, 0)

local PredictAimEnabled = false
local PredictAimColor = Color3.fromRGB(255, 255, 0)
local PredictAimLength = 0

local BallESP
local isInLobbyCached

local AutoStrongServeEveryServeEnabled = false
local ServeBoostPower = 1
local StreamerModeEnabled = false
local DirectionalHitEnabled = false
local CameraJumpEnabled = false
local JumpBoostEnabled = false
local JumpBoostMult = 3
local ballInteractRemote = nil
local streamerOriginalDisplay = {}

-- Client-side visual effect reducer. It only changes local rendering properties
-- and restores each original property when disabled or unloaded.
FeatureConfig.performanceMode = {
    enabled = false,
    level = FeatureConfig.performanceLevel,
    changed = {},
    conns = {},
    reduced = 0,
    scanId = 0,
    statusLabel = nil,
}

do
local Lighting = game:GetService("Lighting")
local function setPerformanceStatus(text)
    pcall(function()
        if FeatureConfig.performanceMode.statusLabel then
            FeatureConfig.performanceMode.statusLabel:Set("State: " .. tostring(text))
        end
    end)
end

local function isShijinPerformanceExcluded(instance)
    local ownFolder = instance and instance:FindFirstAncestor("ShijinBallESP")
    return ownFolder ~= nil
end

local function performancePropertyFor(instance)
    if not instance or isShijinPerformanceExcluded(instance) then return nil end
    if instance:IsA("ParticleEmitter") or instance:IsA("Trail") or instance:IsA("Beam")
        or instance:IsA("Smoke") or instance:IsA("Fire") or instance:IsA("Sparkles") then
        return "Enabled"
    end
    if FeatureConfig.performanceMode.level ~= "Light" then
        if instance:IsA("Light") or instance:IsA("PostEffect") then
            return "Enabled"
        end
    end
    if FeatureConfig.performanceMode.level == "Maximum" then
        if instance:IsA("Atmosphere") or instance:IsA("Clouds") then
            return "Density"
        end
    end
    return nil
end

local function reducePerformanceInstance(instance)
    if not FeatureConfig.performanceMode.enabled or FeatureConfig.performanceMode.changed[instance] then return end
    local property = performancePropertyFor(instance)
    if not property then return end
    local okRead, previous = pcall(function() return instance[property] end)
    if not okRead or previous == false or previous == 0 then return end
    local replacement = property == "Density" and 0 or false
    local okWrite = pcall(function() instance[property] = replacement end)
    if okWrite then
        FeatureConfig.performanceMode.changed[instance] = { property = property, value = previous }
        FeatureConfig.performanceMode.reduced = FeatureConfig.performanceMode.reduced + 1
    end
end

local function restorePerformanceMode()
    FeatureConfig.performanceMode.scanId = FeatureConfig.performanceMode.scanId + 1
    for instance, state in pairs(FeatureConfig.performanceMode.changed) do
        pcall(function()
            if instance and instance.Parent then instance[state.property] = state.value end
        end)
        FeatureConfig.performanceMode.changed[instance] = nil
    end
    FeatureConfig.performanceMode.reduced = 0
end

local function disconnectPerformanceMode()
    for index = #FeatureConfig.performanceMode.conns, 1, -1 do
        safeDisconnect(FeatureConfig.performanceMode.conns[index])
        FeatureConfig.performanceMode.conns[index] = nil
    end
end

local function scanPerformanceMode()
    if not FeatureConfig.performanceMode.enabled then return end
    FeatureConfig.performanceMode.scanId = FeatureConfig.performanceMode.scanId + 1
    local scanId = FeatureConfig.performanceMode.scanId
    setPerformanceStatus("ON — scanning local effects...")
    task.spawn(function()
        local checked = 0
        for _, root in ipairs({ Workspace, Lighting }) do
            local ok, descendants = pcall(function() return root:GetDescendants() end)
            if ok and type(descendants) == "table" then
                for _, instance in ipairs(descendants) do
                    if not FeatureConfig.performanceMode.enabled or scanId ~= FeatureConfig.performanceMode.scanId or ShijinUnloaded then return end
                    reducePerformanceInstance(instance)
                    checked = checked + 1
                    if checked % (FeatureConfig.performanceYieldEvery or 320) == 0 then task.wait() end
                end
            end
        end
        if FeatureConfig.performanceMode.enabled and scanId == FeatureConfig.performanceMode.scanId then
            setPerformanceStatus("ON — " .. tostring(FeatureConfig.performanceMode.reduced) .. " local effects reduced")
        end
    end)
end

local function connectPerformanceMode()
    if #FeatureConfig.performanceMode.conns > 0 then return end
    for _, root in ipairs({ Workspace, Lighting }) do
        local ok, conn = pcall(function()
            return root.DescendantAdded:Connect(function(instance)
                if FeatureConfig.performanceMode.enabled then reducePerformanceInstance(instance) end
            end)
        end)
        if ok and conn then FeatureConfig.performanceMode.conns[#FeatureConfig.performanceMode.conns + 1] = conn end
    end
end

function FeatureConfig.performanceMode.setLevel(level)
    if level ~= "Light" and level ~= "Balanced" and level ~= "Maximum" then level = "Balanced" end
    if FeatureConfig.performanceMode.level == level then return end
    FeatureConfig.performanceMode.level = level
    FeatureConfig.performanceLevel = level
    if FeatureConfig.performanceMode.enabled then
        restorePerformanceMode()
        scanPerformanceMode()
    end
end

function FeatureConfig.performanceMode.setEnabled(enabled)
    enabled = enabled == true
    if FeatureConfig.performanceMode.enabled == enabled then
        if enabled then scanPerformanceMode() else setPerformanceStatus("OFF") end
        return
    end
    FeatureConfig.performanceMode.enabled = enabled
    if enabled then
        connectPerformanceMode()
        scanPerformanceMode()
    else
        disconnectPerformanceMode()
        restorePerformanceMode()
        setPerformanceStatus("OFF — restored local effects")
    end
end
end

local KeyDetectorSetKey = "Q"
local KeyDetectorJumpSetKey = "E"
local KeyDetectorSetKeyCode = Enum.KeyCode.Q
local KeyDetectorSetInputType = Enum.UserInputType.Keyboard
local KeyDetectorJumpSetKeyCode = Enum.KeyCode.E
local KeyDetectorJumpSetInputType = Enum.UserInputType.Keyboard
local KeyDetectorSetLabel = nil
local KeyDetectorJumpSetLabel = nil

local function updateKeyDetectorLabels()
    pcall(function()
        if getgenv then
            getgenv().ShijinDetectedKeys = {
                Set = KeyDetectorSetKey,
                JumpSet = KeyDetectorJumpSetKey,
                SetKeyCode = KeyDetectorSetKeyCode,
                JumpSetKeyCode = KeyDetectorJumpSetKeyCode,
                SetInputType = KeyDetectorSetInputType,
                JumpSetInputType = KeyDetectorJumpSetInputType,
            }
            getgenv().ShijinSetKey = KeyDetectorSetKey
            getgenv().ShijinJumpSetKey = KeyDetectorJumpSetKey
        end
    end)
    pcall(function()
        if KeyDetectorSetLabel then
            KeyDetectorSetLabel:Set("Set Key: [" .. tostring(KeyDetectorSetKey) .. "]")
        end
    end)
    pcall(function()
        if KeyDetectorJumpSetLabel then
            KeyDetectorJumpSetLabel:Set("JumpSet Key: [" .. tostring(KeyDetectorJumpSetKey) .. "]")
        end
    end)
end

local function stringToKeyInput(s)
    local raw = tostring(s or "")
    raw = raw:gsub("^%s+", ""):gsub("%s+$", "")
    if raw == "" then return nil, nil, "" end
    local up = string.upper(raw)
    if up == "MB1" or up == "M1" or up == "MOUSEBUTTON1" or up == "LMB" or up == "MOUSE1" then
        return Enum.KeyCode.Unknown, Enum.UserInputType.MouseButton1, "MouseButton1"
    end
    if up == "MB2" or up == "M2" or up == "MOUSEBUTTON2" or up == "RMB" or up == "MOUSE2" then
        return Enum.KeyCode.Unknown, Enum.UserInputType.MouseButton2, "MouseButton2"
    end
    if up == "MB3" or up == "M3" or up == "MOUSEBUTTON3" or up == "MMB" or up == "MOUSE3" then
        return Enum.KeyCode.Unknown, Enum.UserInputType.MouseButton3, "MouseButton3"
    end
    if up == "SPACEBAR" then up = "SPACE" end
    if up == "CTRL" then up = "LEFTCONTROL" end
    if up == "SHIFT" then up = "LEFTSHIFT" end
    if up == "ALT" then up = "LEFTALT" end
    local kc = nil
    pcall(function()
        for _, item in ipairs(Enum.KeyCode:GetEnumItems()) do
            if string.upper(item.Name) == up then
                kc = item
                break
            end
        end
    end)
    if kc then
        return kc, Enum.UserInputType.Keyboard, kc.Name
    end
    local it = nil
    pcall(function()
        for _, item in ipairs(Enum.UserInputType:GetEnumItems()) do
            if string.upper(item.Name) == up then
                it = item
                break
            end
        end
    end)
    if it then
        return Enum.KeyCode.Unknown, it, it.Name
    end
    return nil, nil, raw
end

local function pressDetectedMove(moveName, holdDuration)
    if ShijinUnloaded then return end
    local VIM = game:GetService("VirtualInputManager")
    local hold = math.clamp(tonumber(holdDuration) or 0.05, 0.02, 0.30)
    local kc, it
    if moveName == "JumpSet" then kc, it = KeyDetectorJumpSetKeyCode, KeyDetectorJumpSetInputType
    else kc, it = KeyDetectorSetKeyCode, KeyDetectorSetInputType end
    local sent = false
    local ok = pcall(function()
        if it == Enum.UserInputType.MouseButton1 or it == Enum.UserInputType.MouseButton2 or it == Enum.UserInputType.MouseButton3 then
            local btn = 0
            if it == Enum.UserInputType.MouseButton2 then btn = 1 elseif it == Enum.UserInputType.MouseButton3 then btn = 2 end
            VIM:SendMouseButtonEvent(0, 0, btn, true, game, 1)
            task.delay(hold, function()
                pcall(function() VIM:SendMouseButtonEvent(0, 0, btn, false, game, 1) end)
            end)
            sent = true
        elseif kc and kc ~= Enum.KeyCode.Unknown then
            VIM:SendKeyEvent(true, kc, false, game)
            task.delay(hold, function()
                pcall(function() VIM:SendKeyEvent(false, kc, false, game) end)
            end)
            sent = true
        end
    end)
    return ok and sent
end

pcall(function()
    if getgenv then
        getgenv().ShijinDetectedKeys = {
            Set = KeyDetectorSetKey, JumpSet = KeyDetectorJumpSetKey,
            SetKeyCode = KeyDetectorSetKeyCode, JumpSetKeyCode = KeyDetectorJumpSetKeyCode,
            SetInputType = KeyDetectorSetInputType, JumpSetInputType = KeyDetectorJumpSetInputType,
        }
        getgenv().ShijinGetSetKey = function() return KeyDetectorSetKey, KeyDetectorSetKeyCode, KeyDetectorSetInputType end
        getgenv().ShijinGetJumpSetKey = function() return KeyDetectorJumpSetKey, KeyDetectorJumpSetKeyCode, KeyDetectorJumpSetInputType end
        getgenv().ShijinPressSet = function() pressDetectedMove("Set") end
        getgenv().ShijinPressJumpSet = function() pressDetectedMove("JumpSet") end
    end
end)

local AutoSpinEnabled = false
local AutoSpinType = "Style"
local AutoSpinSlot = 1
local AutoSpinStopOnRarity = ""
local AutoSpinUseLucky = true
local AutoSpinReselectSlot = true
local AutoSpinSpeed = 0.35
local AutoSpinBusy = false
local lastAutoSpin = 0
local AutoSpinCount = 0
local AutoSpinLimit = 0
local AutoSpinStartedAt = 0
local AutoSpinBackoff = 0
local AutoSpinLastRarity = "--"
local AutoSpinStatusLabel = nil
local AutoSpinStatsLabel = nil
local AutoSpinTargetLabel = nil
local resetSpinFails = function() end
local uninstallAutoSpinWatch = function() end

local function autoSpinStatus(overrideState)
    local state = overrideState
    if not state and not AutoSpinEnabled then
        state = "idle"
    elseif not state and os.clock() < AutoSpinBackoff then
        state = "cooling down"
    elseif not state then
        state = "spinning"
    end
    if AutoSpinStatusLabel then
        pcall(function()
            AutoSpinStatusLabel:Set(string.format("State: %s  |  Spins: %d%s",
                state, AutoSpinCount,
                AutoSpinLimit > 0 and ("/" .. AutoSpinLimit) or ""))
        end)
    end
    if AutoSpinStatsLabel then
        local rate = 0
        if AutoSpinStartedAt > 0 then
            rate = AutoSpinCount / math.max((os.clock() - AutoSpinStartedAt) / 60, 1 / 60)
        end
        pcall(function()
            AutoSpinStatsLabel:Set(string.format("Last: %s  |  %.0f spins/min",
                AutoSpinLastRarity, rate))
        end)
    end
    if AutoSpinTargetLabel then
        pcall(function()
            AutoSpinTargetLabel:Set(string.format("Target: %s slot %d  |  Lucky: %s",
                AutoSpinType, AutoSpinSlot, AutoSpinUseLucky and "On" or "Off"))
        end)
    end
end

local RARITY_RANK = { Secret = 5, Godly = 4, Legendary = 3, Ultra = 2, Evo = 1 }
local styleRollRemote, abilityRollRemote = nil, nil
local styleSelectSlot, abilitySelectSlot = nil, nil

local SpeedEnabled = false
local SpeedValue = 0

local speedChar, speedHum, speedRoot = nil, nil, nil
local function speedControl()
    while SpeedEnabled and not ShijinUnloaded do
        local dt = RunService.RenderStepped:Wait()
        local character = LocalPlayer.Character
        if character ~= speedChar or not (speedRoot and speedRoot.Parent) then
            speedChar, speedHum, speedRoot = character, nil, nil
            if character then
                speedHum = character:FindFirstChildOfClass("Humanoid")
                speedRoot = character:FindFirstChild("HumanoidRootPart")
            end
        end
        if speedHum and speedRoot and speedHum.Health > 0 and SpeedValue > 0 then
            local state = speedHum:GetState()
            local airborne = state == Enum.HumanoidStateType.Jumping or state == Enum.HumanoidStateType.Freefall
            local moveDirection = speedHum.MoveDirection
            if moveDirection.Magnitude > 0 and (FeatureConfig.speedAllowAir or not airborne) then
                local step = math.clamp(SpeedValue * 6 * math.clamp(dt, 0, 0.15), 0, FeatureConfig.speedMaxStep)
                if step > 0 then speedRoot.CFrame = speedRoot.CFrame + moveDirection.Unit * step end
            end
        end
    end
end

local speedLoopOn = false
startSpeedLoop = function()
    if speedLoopOn or not SpeedEnabled then return end
    speedLoopOn = true
    task.spawn(function()
        speedControl()
        speedLoopOn = false
    end)
end

local Camera = Workspace.CurrentCamera

local AutoCorner = {
    enabled = false,
    side = "Auto",
    reach = "All",
    drift = nil,
    steer = nil,
    aimed = false,
    maxBallDistance = 95,
    smoothing = 12,
    aimDrop = 0.35,
    refreshRate = 0.04,
    boundsCache = nil,
    boundsCacheT = -10,
    jumpConn = nil,
}
hubConn(Workspace:GetPropertyChangedSignal("CurrentCamera"), function()
    Camera = Workspace.CurrentCamera
    if BallESP and BallESP.folder and BallESP.folder.Parent and Camera then
        pcall(function() BallESP.folder.Parent = Camera end)
    end
end)

do
local function getNearestBallPart()
    local root = LocalPlayer.Character and LocalPlayer.Character:FindFirstChild("HumanoidRootPart")
    if not root then return nil end
    local best, bestDist = nil, math.max(tonumber(AutoCorner.maxBallDistance) or 95, 10)
    for _, v in ipairs(VX.list()) do
        if v:IsA("Model") and string.find(v.Name, "CLIENT_BALL") then
            local part = v:FindFirstChildWhichIsA("BasePart")
            if part then
                local d = (part.Position - root.Position).Magnitude
                if d < bestDist then
                    bestDist = d
                    best = part
                end
            end
        end
    end
    return best
end

AutoCorner.physics = function()
    local common = ReplicatedStorage:FindFirstChild("Common")
    local mod = common and common:FindFirstChild("Physics")
    if not mod then return nil end
    local ok, resolved = pcall(require, mod)
    if ok and type(resolved) == "table" then
        return resolved
    end
    return nil
end

AutoCorner.bounds = function()
    local now = os.clock()
    local cached = AutoCorner.boundsCache
    if cached and now - (AutoCorner.boundsCacheT or 0) < 0.5 then
        return cached.center, cached.half, cached.surfaceY
    end
    local center, half, surfaceY
    local physics = AutoCorner.physics()
    if physics and physics._getCourtlines then
        local found, lines = pcall(physics._getCourtlines)
        if found and lines and lines:IsA("BasePart") then
            center, half, surfaceY = lines.Position, lines.Size * 0.5, lines.Position.Y
        end
    end
    if not center then
        local map = Workspace:FindFirstChild("Map")
        local court = map and map:FindFirstChild("Court")
        if court then
            center, half, surfaceY = court.Position, court.Size * 0.5 - Vector3.new(1, 0, 1), court.Position.Y + court.Size.Y * 0.5
        end
    end
    center, half, surfaceY = center or Vector3.new(0, 0, 0), half or Vector3.new(22, 0, 36), surfaceY or 0
    AutoCorner.boundsCache = { center = center, half = half, surfaceY = surfaceY }
    AutoCorner.boundsCacheT = now
    return center, half, surfaceY
end

AutoCorner.trackBall = function(ball, before, elapsed)
    local shared = nil
    if BallESP and BallESP.ball and BallESP.velocityOf then
        local okV, v = pcall(BallESP.velocityOf, BallESP.ball)
        if okV and typeof(v) == "Vector3" and v.Magnitude > 1 then shared = v end
    end
    if shared then
        local prev = AutoCorner.drift
        if typeof(prev) == "Vector3" then
            AutoCorner.drift = prev:Lerp(shared, 0.5)
        else
            AutoCorner.drift = shared
        end
        return
    end
    if not ball or not ball.Parent or not before or elapsed <= 0 then return end
    elapsed = math.clamp(elapsed, 0.005, 0.25)
    local measured = (ball.Position - before) / elapsed
    if measured.Magnitude <= 500 then AutoCorner.drift = measured end
end

AutoCorner.origin = function()
    local ball = getNearestBallPart()
    local root = LocalPlayer.Character and LocalPlayer.Character:FindFirstChild("HumanoidRootPart")
    if not ball then
        return root and root.Position or Vector3.zero
    end
    local drift = AutoCorner.drift
    if not root or typeof(drift) ~= "Vector3" or drift.Magnitude < 1 then
        return ball.Position
    end
    local gap = ball.Position - root.Position
    local closing = drift - root.AssemblyLinearVelocity
    local speed = closing:Dot(closing)
    if speed < 1 then
        return ball.Position
    end
    local reach = math.clamp(-gap:Dot(closing) / speed, 0, 0.45)
    return ball.Position + drift * reach
end

local function cornerPoint()
    local root = LocalPlayer.Character and LocalPlayer.Character:FindFirstChild("HumanoidRootPart")
    local centre, half, surfaceY = AutoCorner.bounds()
    if not root or not centre then return nil end

    local halfX = math.max(half.X - 2, 1)
    local halfZ = math.max(half.Z - 2, 1)

    local map = Workspace:FindFirstChild("Map")
    local collide = map and map:FindFirstChild("BallCollideOnly")
    local net = collide and collide:FindFirstChild("Net")
    local netZ = net and net.Position.Z or centre.Z

    local index = LocalPlayer.Team and LocalPlayer.Team:GetAttribute("Index")
    local sign
    if index == 1 then
        sign = 1
    elseif index == 2 then
        sign = -1
    else
        sign = (root.Position.Z < netZ) and 1 or -1
    end

    local deepZ = centre.Z + sign * halfZ
    local leftX = centre.X + sign * halfX
    local rightX = centre.X - sign * halfX
    local pivot = AutoCorner.origin()
    local attackLine = half.Z / 3
    local standoff = math.abs(root.Position.Z - netZ)
    local hugging = 1 - math.clamp(standoff / math.max(attackLine, 1), 0, 1)
    local shortZ = centre.Z + sign * halfZ * 0.3
    local reach = AutoCorner.reach
    local wantsNear = reach == "Nearest" or (reach ~= "Back" and hugging > 0)

    if AutoCorner.side == "Left" then
        return Vector3.new(leftX, surfaceY, wantsNear and shortZ or deepZ)
    elseif AutoCorner.side == "Right" then
        return Vector3.new(rightX, surfaceY, wantsNear and shortZ or deepZ)
    end

    local corners = {}
    if reach ~= "Nearest" then
        corners[#corners + 1] = { at = Vector3.new(leftX, surfaceY, deepZ), reward = 0 }
        corners[#corners + 1] = { at = Vector3.new(rightX, surfaceY, deepZ), reward = 0 }
    end
    if wantsNear then
        corners[#corners + 1] = { at = Vector3.new(leftX, surfaceY, shortZ), reward = 0.45 * hugging }
        corners[#corners + 1] = { at = Vector3.new(rightX, surfaceY, shortZ), reward = 0.45 * hugging }
    end
    if #corners == 0 then return nil end

    local eye = Workspace.CurrentCamera or Camera
    local heading = eye and eye.CFrame.LookVector or root.CFrame.LookVector
    heading = Vector3.new(heading.X, 0, heading.Z)
    if heading.Magnitude < 0.01 then
        return corners[1].at
    end
    heading = heading.Unit

    local physics = AutoCorner.physics()
    local bounds = nil
    if physics and physics._getCourtlines then
        local ok, lines = pcall(physics._getCourtlines)
        if ok then bounds = lines end
    end

    local guards = {}
    for _, player in ipairs(Players:GetPlayers()) do
        if player ~= LocalPlayer and (not LocalPlayer.Team or player.Team ~= LocalPlayer.Team) then
            local gr = player.Character and player.Character:FindFirstChild("HumanoidRootPart")
            if gr then
                local lead = gr.AssemblyLinearVelocity * 0.45
                guards[#guards + 1] = Vector3.new(gr.Position.X + lead.X, surfaceY, gr.Position.Z + lead.Z)
            end
        end
    end

    local aligned = {}
    for _, corner in ipairs(corners) do
        local legal = true
        if bounds and physics and physics.isPositionInCourt then
            local ok, inside = pcall(physics.isPositionInCourt, corner.at, bounds, 0, nil)
            legal = not ok or inside
        end
        if legal then
            local line = Vector3.new(corner.at.X - pivot.X, 0, corner.at.Z - pivot.Z)
            if line.Magnitude > 0.01 then
                aligned[#aligned + 1] = {
                    spot = corner.at,
                    dot = line.Unit:Dot(heading),
                    reward = corner.reward,
                }
            end
        end
    end
    if #aligned == 0 then return corners[1].at end

    local pick
    for _, entry in ipairs(aligned) do
        if not pick or entry.dot > pick.dot then
            pick = entry
        end
    end
    local wanted = pick.spot.X >= centre.X

    local best, bestScore
    local sticky, stickyScore = AutoCorner.lastSpot, nil
    for _, entry in ipairs(aligned) do
        if (entry.spot.X >= centre.X) == wanted then
            local nearest = 60
            for _, guard in ipairs(guards) do
                local gap = (guard - entry.spot).Magnitude
                if gap < nearest then nearest = gap end
            end
            local score = math.min(nearest, 45) / 45 + entry.reward
            if sticky and (entry.spot - sticky).Magnitude < 2 then
                stickyScore = score
            end
            if not bestScore or score > bestScore then
                bestScore = score
                best = entry.spot
            end
        end
    end
    if sticky and stickyScore and bestScore and stickyScore > bestScore - 0.12 then
        best, bestScore = sticky, stickyScore
    end
    best = best or pick.spot
    AutoCorner.lastSpot = best
    return best
end

AutoCorner.facing = function()
    local spot = cornerPoint()
    if not spot then return nil end
    local pivot = AutoCorner.origin()
    local flat = Vector3.new(spot.X - pivot.X, 0, spot.Z - pivot.Z)
    local root = LocalPlayer.Character and LocalPlayer.Character:FindFirstChild("HumanoidRootPart")
    if root then
        local map = Workspace:FindFirstChild("Map")
        local collide = map and map:FindFirstChild("BallCollideOnly")
        local net = collide and collide:FindFirstChild("Net")
        local netZ = net and net.Position.Z
        if netZ then
            local ownSide = (root.Position.Z > netZ) and 1 or -1
            if flat.Z * ownSide >= 0 then
                flat = Vector3.new(spot.X - root.Position.X, 0, spot.Z - root.Position.Z)
            end
            if flat.Z * ownSide >= 0 then
                flat = Vector3.new(flat.X, 0, -ownSide * math.max(math.abs(flat.Z), 1))
            end
        end
    end
    if flat.Magnitude < 0.01 then return nil end
    return flat.Unit
end

AutoCorner.refresh = function()
    if not AutoCorner.enabled or ShijinUnloaded then return end
    local nowA = os.clock()
    local prevT = AutoCorner.refreshT or nowA
    if nowA - (AutoCorner.refreshT or 0) < math.clamp(tonumber(AutoCorner.refreshRate) or 0.04, 0.02, 0.2) then return end
    local dt = math.clamp(nowA - prevT, 1 / 240, 0.25)
    AutoCorner.refreshT = nowA

    local char = LocalPlayer.Character
    local root = char and char:FindFirstChild("HumanoidRootPart")
    local hum = char and char:FindFirstChildOfClass("Humanoid")
    if not root or not hum then return end

    local state = hum:GetState()
    local airborne = state == Enum.HumanoidStateType.Jumping
        or state == Enum.HumanoidStateType.Freefall
        or root.AssemblyLinearVelocity.Y > 3
    if not airborne then
        AutoCorner.lastSpot = nil
        return
    end

    AutoCorner.trackBall(nil, nil, 0)

    local want = AutoCorner.facing()
    if not want or want.Magnitude < 0.01 then return end
    local cur = AutoCorner.steer
    if typeof(cur) == "Vector3" and cur.Magnitude > 0.01 then
        local blended = cur:Lerp(want, 1 - math.exp(-math.clamp(tonumber(AutoCorner.smoothing) or 12, 1, 30) * dt))
        if blended.Magnitude > 0.01 then
            AutoCorner.steer = blended.Unit
        end
    else
        AutoCorner.steer = want
    end
end

AutoCorner.installAim = function()
    if AutoCorner.aimed then return true end
    if not (getrawmetatable and setreadonly and getnamecallmethod) then return false end
    if not ballInteractRemote then
        pcall(function()
            local services = ReplicatedStorage.Packages._Index["sleitnick_knit@1.7.0"].knit.Services
            local bs = services:FindFirstChild("BallService")
            local rf = bs and bs:FindFirstChild("RF")
            ballInteractRemote = rf and rf:FindFirstChild("Interact")
        end)
    end
    if not ballInteractRemote then
        warn("[ShijinHub] AutoCorner: Interact remote missing")
        return false
    end
    local mt = getrawmetatable(game)
    local oldNamecall = mt.__namecall
    setreadonly(mt, false)
    mt.__namecall = newcclosure(function(self, ...)
        if ShijinUnloaded then return oldNamecall(self, ...) end
        local method = getnamecallmethod()
        if self == ballInteractRemote and method == "InvokeServer" then
            local data = ...
            if AutoCorner.enabled and type(data) == "table" and (data.Move == "Spike" or data.Move == "ServeSpike") then
                local steer = AutoCorner.steer
                if typeof(steer) == "Vector3" then
                    local flat = Vector3.new(steer.X, 0, steer.Z)
                    if flat.Magnitude > 0.01 then
                        flat = flat.Unit
                        local aim = (flat - Vector3.new(0, math.clamp(tonumber(AutoCorner.aimDrop) or 0.35, 0, 1.5), 0)).Unit
                        data.LookVector = aim
                        data.Direction = aim
                    end
                end
            end
            return oldNamecall(self, data)
        end
        return oldNamecall(self, ...)
    end)
    setreadonly(mt, true)
    AutoCorner._oldNamecall = oldNamecall
    AutoCorner.aimed = true
    return true
end

AutoCorner.uninstallAim = function()
    if not AutoCorner.aimed then return end
    AutoCorner.aimed = false
    AutoCorner.steer = nil
    pcall(function()
        local mt = getrawmetatable(game)
        setreadonly(mt, false)
        mt.__namecall = AutoCorner._oldNamecall
        setreadonly(mt, true)
    end)
end

local function bindAutoCornerJump(character)
    safeDisconnect(AutoCorner.jumpConn)
    AutoCorner.jumpConn = nil
    local humanoid = character:FindFirstChildOfClass("Humanoid") or character:WaitForChild("Humanoid", 5)
    local rootPart = character:FindFirstChild("HumanoidRootPart") or character:WaitForChild("HumanoidRootPart", 5)
    if not humanoid or not rootPart then return end
    AutoCorner.jumpConn = humanoid:GetPropertyChangedSignal("Jump"):Connect(function()
        if not humanoid.Jump then return end
        if AutoCorner.enabled then
            task.defer(function()
                local tracked = getNearestBallPart()
                local before = tracked and tracked.Position
                local stamp = os.clock()
                task.wait(0.03)
                if tracked and before and tracked.Parent then
                    AutoCorner.trackBall(tracked, before, os.clock() - stamp)
                end
                local lookVector = AutoCorner.facing()
                if lookVector and lookVector.Magnitude > 0 then
                    AutoCorner.steer = lookVector
                    rootPart.CFrame = CFrame.lookAt(rootPart.Position, rootPart.Position + lookVector)
                end
            end)
            return
        end
    end)
end

if LocalPlayer.Character then
    task.spawn(bindAutoCornerJump, LocalPlayer.Character)
end
hubConn(LocalPlayer.CharacterAdded, bindAutoCornerJump)

local cameraTurnToken = 0

-- Auto Shiftlock: instant snap to camera direction on jump, held while airborne.
local CameraJumpConns = {}
local function bindShiftlockSnap(character)
    for i = #CameraJumpConns, 1, -1 do
        safeDisconnect(CameraJumpConns[i])
        CameraJumpConns[i] = nil
    end
    local humanoid = character:FindFirstChildOfClass("Humanoid") or character:WaitForChild("Humanoid", 5)
    if not humanoid then return end
    local rootPart = character:FindFirstChild("HumanoidRootPart") or character:WaitForChild("HumanoidRootPart", 5)
    if not rootPart then return end
    local lockedLook = nil
    local holdConn = nil
    local function stopHold()
        lockedLook = nil
        if holdConn then safeDisconnect(holdConn) holdConn = nil end
    end
    CameraJumpConns[#CameraJumpConns + 1] = humanoid.StateChanged:Connect(function(_, newState)
        if newState == Enum.HumanoidStateType.Freefall and CameraJumpEnabled and not ShijinUnloaded then
            humanoid.AutoRotate = false
            local cam = Workspace.CurrentCamera
            if cam then
                local look = cam.CFrame.LookVector
                local flat = Vector3.new(look.X, 0, look.Z)
                if flat.Magnitude > 0.01 then
                    lockedLook = flat.Unit
                    pcall(function()
                        rootPart.CFrame = CFrame.lookAt(rootPart.Position, rootPart.Position + lockedLook)
                    end)
                end
            end
            if not holdConn then
                holdConn = RunService.RenderStepped:Connect(function()
                    if lockedLook then
                        pcall(function()
                            rootPart.CFrame = rootPart.CFrame:Lerp(CFrame.lookAt(rootPart.Position, rootPart.Position + lockedLook), 0.75)
                        end)
                    end
                end)
                CameraJumpConns[#CameraJumpConns + 1] = holdConn
            end
        else
            humanoid.AutoRotate = true
            stopHold()
        end
    end)
end

if LocalPlayer.Character then
    task.spawn(bindShiftlockSnap, LocalPlayer.Character)
end
hubConn(LocalPlayer.CharacterAdded, bindShiftlockSnap)

end

local TSHBarLock = {
    enabled = false,
    value = 1,
    controller = nil,
    patched = nil,
    link = nil,
    active = false,
    saved = nil,
    requireRunup = false,
    minimumRunup = 0.50,
    rawCharge = 0,
    runupReady = true,
}

TSHBarLock.TSH_STYLES = {
    TimeskipShoyo = true,
    TimeskipShoyo2 = true,
    TimeskipShoyo3 = true,
    TimeskipShoyo4 = true,
}

TSHBarLock.getController = function()
    if TSHBarLock.controller then
        return TSHBarLock.controller
    end
    local controllers = game:GetService("ReplicatedFirst"):FindFirstChild("Controllers")
    local module = controllers and controllers:FindFirstChild("SpecialController")
    if not module then return nil end
    local ok, resolved = pcall(require, module)
    if ok and type(resolved) == "table" and resolved.ChargeSpring then
        TSHBarLock.controller = resolved
        return resolved
    end
    return nil
end

TSHBarLock.wearing = function()
    return TSHBarLock.TSH_STYLES[tostring(LocalPlayer:GetAttribute("Gameplay_Style"))] == true
end

TSHBarLock.updateRunupGate = function(raw)
    if type(raw) == "number" then
        TSHBarLock.rawCharge = math.clamp(raw, 0, 1)
    end
    TSHBarLock.runupReady = not TSHBarLock.requireRunup
        or TSHBarLock.rawCharge >= math.clamp(tonumber(TSHBarLock.minimumRunup) or 0.50, 0, 1)
    return TSHBarLock.runupReady
end

TSHBarLock.fullValue = function(special)
    if special and special.Type == "ActionActivatable" then
        local meta = special.Metadata or {}
        return math.clamp(tonumber(meta.MaxActions) or 1, 1, 2)
    end
    return 1
end

TSHBarLock.patch = function(sc)
    if TSHBarLock.patched then return true end
    local spring = sc.ChargeSpring
    if type(spring) ~= "table" then return false end
    local realGet = spring.get
    if type(realGet) ~= "function" then return false end
    rawset(spring, "get", function(self, asDependency)
        local ok, real = pcall(realGet, self, asDependency)
        if TSHBarLock.enabled then
            local ready = TSHBarLock.updateRunupGate(ok and real or 0)
            -- Before the selected natural run-up is reached, return the genuine
            -- bar value. Once it reaches the threshold, lock it full.
            if TSHBarLock.requireRunup and not ready then
                return ok and real or 0
            end
            return math.min(TSHBarLock.value, 1)
        end
        return ok and real or 0
    end)
    TSHBarLock.patched = { spring = spring, get = realGet }
    return true
end

TSHBarLock.unpatch = function()
    local saved = TSHBarLock.patched
    if not saved then return end
    pcall(function()
        rawset(saved.spring, "get", saved.get)
    end)
    TSHBarLock.patched = nil
end

TSHBarLock.rememberState = function()
    if TSHBarLock.saved then return end
    TSHBarLock.saved = {
        cooldown = LocalPlayer:GetAttribute("Special_CooldownTimestamp"),
        charge = LocalPlayer:GetAttribute("Special_Charge"),
    }
end

TSHBarLock.restoreState = function()
    local saved = TSHBarLock.saved
    if not saved then return end
    TSHBarLock.saved = nil
    pcall(function()
        LocalPlayer:SetAttribute("Special_CooldownTimestamp", saved.cooldown)
        LocalPlayer:SetAttribute("Special_Charge", saved.charge)
    end)
end

TSHBarLock.pump = function()
    if not TSHBarLock.wearing() then
        if TSHBarLock.active then
            TSHBarLock.active = false
            TSHBarLock.restoreState()
        end
        return
    end
    local sc = TSHBarLock.getController()
    if not sc then return end
    if not TSHBarLock.patched and not TSHBarLock.patch(sc) then return end
    TSHBarLock.rememberState()
    TSHBarLock.active = true

    local special = nil
    if sc.Special and sc.Special.get then
        special = sc.Special:get()
    end
    if not special then return end
    TSHBarLock.value = TSHBarLock.fullValue(special)
    -- Sample the unpatched spring before touching Charge/attributes. This preserves
    -- the user's genuine run-up, then applies the full lock only after the threshold.
    local raw = TSHBarLock.rawCharge
    local savedPatch = TSHBarLock.patched
    if savedPatch and savedPatch.get then
        pcall(function() raw = savedPatch.get(sc.ChargeSpring) end)
    end
    local ready = TSHBarLock.updateRunupGate(raw)
    if TSHBarLock.requireRunup and not ready then return end

    local kind = special.Type
    if kind == "Charge" then
        if sc.ChargeVisibility and sc.ChargeVisibility.get and sc.ChargeVisibility:get() ~= true then
            sc.ChargeVisibility:set(true)
        end
        if sc.Charge and sc.Charge.set then
            sc.Charge:set(TSHBarLock.value)
        end
        return
    end

    if kind == "Activation" then
        if LocalPlayer:GetAttribute("Special_CooldownTimestamp") ~= 0 then
            LocalPlayer:SetAttribute("Special_CooldownTimestamp", 0)
        end
        return
    end

    if kind == "Action" or kind == "ActionActivatable" then
        local requirement = tonumber((special.Metadata or {}).Requirement) or 0
        if requirement <= 0 then return end
        local filled = requirement * TSHBarLock.value
        if LocalPlayer:GetAttribute("Special_Charge") ~= filled then
            LocalPlayer:SetAttribute("Special_Charge", filled)
        end
    end
end

TSHBarLock.setEnabled = function(state)
    if state then
        TSHBarLock.enabled = true
        TSHBarLock.rawCharge = 0
        TSHBarLock.runupReady = not TSHBarLock.requireRunup
        local sc = TSHBarLock.getController()
        if sc then
            TSHBarLock.patch(sc)
            TSHBarLock.rememberState()
            pcall(function()
                sc.Debounce = false
            end)
        end
        if not TSHBarLock.link then
            TSHBarLock.link = RunService.Heartbeat:Connect(function()
                if TSHBarLock.enabled then
                    pcall(TSHBarLock.pump)
                end
            end)
        end
        return
    end
    TSHBarLock.enabled = false
    TSHBarLock.rawCharge = 0
    TSHBarLock.runupReady = true
    if TSHBarLock.link then
        TSHBarLock.link:Disconnect()
        TSHBarLock.link = nil
    end
    TSHBarLock.restoreState()
    TSHBarLock.active = false
    local sc = TSHBarLock.controller
    if sc and sc.Charge and sc.Charge.set then
        pcall(function()
            sc.Charge:set(0)
        end)
    end
    TSHBarLock.unpatch()
end

local RoninLock = {
    enabled = false,
    style = "Samurai",
    patch = nil,
    controller = nil,
    generation = 0,
}

RoninLock.wearing = function()
    local controller = RoninLock.controller
    local value = controller and controller.Special
    if type(value) == "table" and type(value.get) == "function" then
        local ok, active = pcall(value.get, value)
        if ok and type(active) == "table" and type(active.Id) == "string" and active.Id ~= "" then
            return active.Id == RoninLock.style
        end
    end
    local special = LocalPlayer:GetAttribute("Gameplay_Special")
    if type(special) == "string" and special ~= "" then return special == "Samurai" end
    local style = LocalPlayer:GetAttribute("Gameplay_Style")
    return style == "Samurai" or style == "Samurai2"
end

RoninLock.utility = function()
    local content = ReplicatedStorage:FindFirstChild("Content")
    local specials = content and content:FindFirstChild("Special")
    local samurai = specials and specials:FindFirstChild(RoninLock.style)
    local module = samurai and samurai:FindFirstChild("Utility")
    if not module then return nil, "Ronin's charge module is unavailable" end
    local ok, utility = pcall(require, module)
    if not ok or type(utility) ~= "table" or type(utility.computeSpecialCharge) ~= "function" then
        return nil, "Ronin's charge calculation is unavailable"
    end
    return utility
end

RoninLock.release = function()
    RoninLock.enabled = false
    RoninLock.controller = nil
    RoninLock.generation = RoninLock.generation + 1
    local patch = RoninLock.patch
    RoninLock.patch = nil
    if patch and patch.utility.computeSpecialCharge == patch.wrapper then
        patch.utility.computeSpecialCharge = patch.original
    end
    if patch and patch.heldWrapper and patch.utility.computeHeldSpecialCharge == patch.heldWrapper then
        patch.utility.computeHeldSpecialCharge = patch.heldOriginal
    end
    if patch and patch.endWrapper and patch.utility.endCharge == patch.endWrapper then
        patch.utility.endCharge = patch.endOriginal
    end
end

RoninLock.setEnabled = function(state)
    if not state then
        RoninLock.release()
        return true
    end
    local patch = RoninLock.patch
    if patch and patch.utility.computeSpecialCharge == patch.wrapper
        and (not patch.heldWrapper or patch.utility.computeHeldSpecialCharge == patch.heldWrapper)
        and (not patch.endWrapper or patch.utility.endCharge == patch.endWrapper) then
        RoninLock.enabled = true
        return true
    end
    RoninLock.release()
    local ticket = RoninLock.generation
    local utility, note = RoninLock.utility()
    if ticket ~= RoninLock.generation then return true end
    if not utility then return false, note end
    local found, controller = pcall(function()
        local controllers = game:GetService("ReplicatedFirst"):FindFirstChild("Controllers")
        local module = controllers and controllers:FindFirstChild("SpecialController")
        return module and require(module)
    end)
    if ticket ~= RoninLock.generation then return true end
    if found and type(controller) == "table" then RoninLock.controller = controller end
    local original = utility.computeSpecialCharge
    local wrapper = function(player, startedAt, now, ...)
        if RoninLock.enabled and player == LocalPlayer and RoninLock.wearing()
            and type(startedAt) == "number" and startedAt > 0 and startedAt < math.huge
            and type(now) == "number" and now >= startedAt and now < math.huge then
            return 1
        end
        return original(player, startedAt, now, ...)
    end
    local heldOriginal = utility.computeHeldSpecialCharge
    local heldWrapper
    if type(heldOriginal) == "function" then
        heldWrapper = function(player, heldFor, ...)
            if RoninLock.enabled and player == LocalPlayer and RoninLock.wearing()
                and type(heldFor) == "number" and heldFor >= 0 and heldFor < math.huge then
                return 1
            end
            return heldOriginal(player, heldFor, ...)
        end
    end
    local endOriginal = utility.endCharge
    local endWrapper
    if type(endOriginal) == "function" then
        local config = utility.Configuration
        if type(config) ~= "table" or type(config.ChargeTimestampId) ~= "string"
            or config.ChargeTimestampId == "" or type(config.ChargeTime) ~= "number"
            or not (config.ChargeTime > 0 and config.ChargeTime < math.huge) then
            RoninLock.controller = nil
            return false, "Ronin's charge timing is unavailable"
        end
        endWrapper = function(player, ...)
            local ticket = RoninLock.generation
            local startedAt
            if RoninLock.enabled and player == LocalPlayer and RoninLock.wearing() then
                startedAt = player:GetAttribute("Special_" .. config.ChargeTimestampId)
            end
            local active = type(startedAt) == "number" and startedAt > 0 and startedAt < math.huge
            local function finish(charge, heldFor, ...)
                local chargeTime = config.ChargeTime
                if active and RoninLock.enabled and ticket == RoninLock.generation and RoninLock.wearing()
                    and type(heldFor) == "number" and heldFor >= 0 and heldFor < math.huge
                    and type(chargeTime) == "number" and chargeTime > 0 and chargeTime < math.huge then
                    return 1, math.max(heldFor, chargeTime), ...
                end
                return charge, heldFor, ...
            end
            return finish(endOriginal(player, ...))
        end
    end
    local installed = pcall(function()
        utility.computeSpecialCharge = wrapper
        if heldWrapper then utility.computeHeldSpecialCharge = heldWrapper end
        if endWrapper then utility.endCharge = endWrapper end
    end)
    if not installed or utility.computeSpecialCharge ~= wrapper
        or (heldWrapper and utility.computeHeldSpecialCharge ~= heldWrapper)
        or (endWrapper and utility.endCharge ~= endWrapper) then
        if utility.computeSpecialCharge == wrapper then utility.computeSpecialCharge = original end
        if heldWrapper and utility.computeHeldSpecialCharge == heldWrapper then
            utility.computeHeldSpecialCharge = heldOriginal
        end
        if endWrapper and utility.endCharge == endWrapper then utility.endCharge = endOriginal end
        RoninLock.controller = nil
        return false, "Ronin Bar Lock could not connect to the charge calculation"
    end
    RoninLock.patch = {
        utility = utility, original = original, wrapper = wrapper,
        heldOriginal = heldOriginal, heldWrapper = heldWrapper,
        endOriginal = endOriginal, endWrapper = endWrapper,
    }
    RoninLock.enabled = true
    return true
end

local KazanaCharge = { enabled = false, patch = nil }

KazanaCharge.restore = function()
    KazanaCharge.enabled = false
    local patch = KazanaCharge.patch
    KazanaCharge.patch = nil
    if patch and rawget(patch.bar, "Evaluate") == patch.wrapper then
        rawset(patch.bar, "Evaluate", patch.ownEvaluate)
    end
end

KazanaCharge.setEnabled = function(state)
    if not state then
        KazanaCharge.restore()
        return true
    end
    if KazanaCharge.enabled then return true end

    local controllers = game:GetService("ReplicatedFirst"):FindFirstChild("Controllers")
    local module = controllers and controllers:FindFirstChild("SpecialController")
    if not module then return false end
    local ok, controller = pcall(require, module)
    if not ok or type(controller) ~= "table" then return false end
    local bar = controller.ChargeBar
    if type(bar) ~= "table" or type(bar.Evaluate) ~= "function" then return false end
    if type(controller.Special) ~= "table" or type(controller.Special.get) ~= "function" then
        return false
    end

    local original = bar.Evaluate
    local patch = { bar = bar, ownEvaluate = rawget(bar, "Evaluate") }
    patch.wrapper = function(self, ...)
        local value = original(self, ...)
        if KazanaCharge.enabled and self == bar and type(value) == "number" then
            local special = controller.Special:get()
            if special and special.Id == "Kazana"
                and LocalPlayer:GetAttribute("Special_ChargeJumpDisabled") ~= true then
                return 1
            end
        end
        return value
    end
    local applied = pcall(rawset, bar, "Evaluate", patch.wrapper)
    if not applied then return false end
    KazanaCharge.patch = patch
    KazanaCharge.enabled = true
    return true
end

local function findKnitServices(idx)
    local ok, services = pcall(function()
        if not idx then
            local pkgs = ReplicatedStorage:FindFirstChild("Packages")
            idx = pkgs and pkgs:FindFirstChild("_Index")
        end
        if not idx then return nil end
        local kp = idx:FindFirstChild("sleitnick_knit@1.7.0")
        if not kp then
            for _, child in ipairs(idx:GetChildren()) do
                local n = child.Name
                if type(n) == "string" and n:find("sleitnick_knit", 1, true) then
                    kp = child
                    break
                end
            end
        end
        if not kp then return nil end
        local knit = kp:FindFirstChild("knit")
        return knit and knit:FindFirstChild("Services")
    end)
    if ok then return services end
    return nil
end

task.spawn(function()
    pcall(function()
        local rs = game:GetService("ReplicatedStorage")
        local pkgs = rs:WaitForChild("Packages", 8)
        if not pkgs then return end
        local idx = pkgs:WaitForChild("_Index", 8)
        if not idx then return end
        if not idx:FindFirstChild("sleitnick_knit@1.7.0") then task.wait(2) end
        local services = findKnitServices(idx)
        if not services then return end
    local bs = services:FindFirstChild("BallService")
    local rf = bs and bs:FindFirstChild("RF")
    if rf then
        ballInteractRemote = rf:FindFirstChild("Interact")
    end
    end)
end)

-- Counter Auto Counter uses only a configured normal local input. It activates
-- only for balls moving toward the player and automatically re-arms for each new counter.
FeatureConfig.autoSpike = {
    enabled = false,
    range = 42,
    minIncomingSpeed = 5,
    scanRate = 0.03,
    lastScan = 0,
    motion = {},
    target = nil,
    armed = true,
    busy = false,
    attempts = 0,
    statusLabel = nil,
    lastStatus = "",
}

do
local autoSpike = FeatureConfig.autoSpike

local function setAutoSpikeStatus(text)
    text = tostring(text)
    if autoSpike.lastStatus == text then return end
    autoSpike.lastStatus = text
    pcall(function()
        if autoSpike.statusLabel then autoSpike.statusLabel:Set("State: " .. text) end
    end)
end

local function configuredSpikeInput()
    local value = Options.AutoSpikeInputKey and Options.AutoSpikeInputKey.Value
    if typeof(value) == "EnumItem" then
        if value.EnumType == Enum.KeyCode then return value, Enum.UserInputType.Keyboard, value.Name end
        return Enum.KeyCode.Unknown, value, value.Name
    end
    return stringToKeyInput(value or "MouseButton1")
end

local function pressConfiguredSpike()
    if autoSpike.busy or ShijinUnloaded then return false end
    local keyCode, inputType = configuredSpikeInput()
    if not inputType then
        setAutoSpikeStatus("set a Spike input key")
        return false
    end
    autoSpike.busy = true
    task.spawn(function()
        local sent = false
        pcall(function()
            local input = game:GetService("VirtualInputManager")
            if inputType == Enum.UserInputType.MouseButton1 or inputType == Enum.UserInputType.MouseButton2 or inputType == Enum.UserInputType.MouseButton3 then
                local button = inputType == Enum.UserInputType.MouseButton2 and 1 or (inputType == Enum.UserInputType.MouseButton3 and 2 or 0)
                input:SendMouseButtonEvent(0, 0, button, true, game, 1)
                task.wait(0.025)
                input:SendMouseButtonEvent(0, 0, button, false, game, 1)
                sent = true
            elseif keyCode and keyCode ~= Enum.KeyCode.Unknown then
                input:SendKeyEvent(true, keyCode, false, game)
                task.wait(0.035)
                input:SendKeyEvent(false, keyCode, false, game)
                sent = true
            end
        end)
        autoSpike.busy = false
        if sent then autoSpike.attempts = autoSpike.attempts + 1 end
        setAutoSpikeStatus(sent and ("Input sent (" .. tostring(autoSpike.attempts) .. ") — waiting for next ball") or "Spike input unavailable")
    end)
    return true
end

local function nearestAutoSpikeBall()
    local character = LocalPlayer.Character
    local root = character and character:FindFirstChild("HumanoidRootPart")
    if not root then return nil end
    local closest, closestDistance = nil, math.max(tonumber(autoSpike.range) or 42, 8)
    for _, candidate in ipairs(VX.list()) do
        local part = nil
        if candidate:IsA("Model") then part = candidate.PrimaryPart or candidate:FindFirstChildWhichIsA("BasePart")
        elseif candidate:IsA("BasePart") then part = candidate end
        if part and part.Parent then
            local distance = (part.Position - root.Position).Magnitude
            if distance <= closestDistance then closest, closestDistance = part, distance end
        end
    end
    return closest
end

local function isAirborneForAutoSpike()
    local character = LocalPlayer.Character
    local humanoid = character and character:FindFirstChildOfClass("Humanoid")
    local root = character and character:FindFirstChild("HumanoidRootPart")
    if not (humanoid and root) or humanoid.Health <= 0 then return false end
    local state = humanoid:GetState()
    return state == Enum.HumanoidStateType.Jumping
        or state == Enum.HumanoidStateType.Freefall
        or humanoid.FloorMaterial == Enum.Material.Air
        or math.abs(root.AssemblyLinearVelocity.Y) > 3
end

local function isCounterSpikeBall(ball)
    local character = LocalPlayer.Character
    local root = character and character:FindFirstChild("HumanoidRootPart")
    if not (root and ball) then return false end
    local now = os.clock()
    local distance = (root.Position - ball.Position).Magnitude
    local previous = autoSpike.motion[ball]
    autoSpike.motion[ball] = { distance = distance, time = now }
    local minimum = math.max(tonumber(autoSpike.minIncomingSpeed) or 5, 1)

    -- Primary test: measure whether the ball is actually closing the distance.
    -- This remains reliable when AssemblyLinearVelocity is delayed or replicated as zero.
    if previous then
        local elapsed = now - (previous.time or now)
        if elapsed > 0.005 then
            local closingSpeed = (previous.distance - distance) / elapsed
            if closingSpeed >= minimum then return true end
        end
    end

    -- Fast-path for the first observed sample when client velocity is available.
    local towardPlayer = root.Position - ball.Position
    local velocity = ball.AssemblyLinearVelocity
    if towardPlayer.Magnitude > 0.1 and velocity.Magnitude >= minimum then
        return velocity:Dot(towardPlayer.Unit) >= minimum
    end
    return false
end

function autoSpike.reset()
    autoSpike.target = nil
    autoSpike.armed = true
    autoSpike.busy = false
    autoSpike.lastScan = 0
    autoSpike.attempts = 0
    for ball in pairs(autoSpike.motion) do autoSpike.motion[ball] = nil end
end

function autoSpike.setEnabled(enabled)
    enabled = enabled == true
    autoSpike.enabled = enabled
    autoSpike.reset()
    VX.use("autospike", enabled)
    setAutoSpikeStatus(enabled and "Waiting to be airborne..." or "OFF")
end

hubConn(RunService.Heartbeat, function()
    if not autoSpike.enabled or ShijinUnloaded then return end
    local now = os.clock()
    if now - autoSpike.lastScan < math.clamp(tonumber(autoSpike.scanRate) or 0.03, 0.02, 0.15) then return end
    autoSpike.lastScan = now
    if not isAirborneForAutoSpike() then
        autoSpike.target = nil
        autoSpike.armed = true
        setAutoSpikeStatus("Waiting to be airborne...")
        return
    end
    local ball = nearestAutoSpikeBall()
    if not ball then
        autoSpike.target = nil
        autoSpike.armed = true
        setAutoSpikeStatus("Waiting for an incoming ball...")
        return
    end
    if not isCounterSpikeBall(ball) then
        autoSpike.target = nil
        autoSpike.armed = true
        setAutoSpikeStatus("Waiting for counter ball...")
        return
    end
    if autoSpike.target ~= ball then
        autoSpike.target = ball
        autoSpike.armed = true
    end
    if autoSpike.armed and pressConfiguredSpike() then
        autoSpike.armed = false
    end
end)
end

do
local BlockedRemotes = {
    ["SetFlag"] = true,
    ["ProccessActionBypasses"] = true,
    ["ProcessActionBypasses"] = true,
    ["ReportPlayer"] = true,
    ["FlagPlayer"] = true,
    ["ReportCheat"] = true,
    ["CheatFlag"] = true,
    ["ExploitFlag"] = true,
    ["CheatDetected"] = true,
    ["SecurityAlert"] = true,
    ["SecurityFlag"] = true,
    ["DetectionEvent"] = true,
    ["ClientFlag"] = true,
    ["ActionFlag"] = true,
    ["AntiCheatRemote"] = true,
    ["ACRemote"] = true,
    ["CheckBypass"] = true,
    ["InvalidMove"] = true,
    ["SuspiciousActivity"] = true,
    ["VerifyClient"] = true,
    ["ExploitDetected"] = true,
    ["FlagAccount"] = true,
    ["ReportExploit"] = true,
    ["KickMe"] = true,
    ["BanMe"] = true,
}

local function isAntiCheatRemote(name)
    if BlockedRemotes[name] then return true end
    local lower = string.lower(tostring(name or ""))
    if lower == "requestban" or lower == "requestpartykick" or lower == "playerbanned"
        or lower == "interact" or lower == "serve" or lower == "jump"
        or lower == "registermoved" or lower == "roll" or lower == "selectslot"
        or lower == "selectchance" or lower == "updatekeybind" or lower == "useability"
        or lower == "actionbypass" then
        return false
    end
    if lower:find("cheat") or lower:find("exploit") or lower:find("flag")
        or lower:find("anticheat") or lower:find("suspicious") or lower:find("detection") then
        return true
    end
    return false
end

local function getRemoteName(inst)
    return tostring(inst.Name or "")
end

local function applyDirectionalHit(name, args)
    if DirectionalHitEnabled and name == "Interact" and type(args[1]) == "table" then
        local data = args[1]
        local cam = workspace.CurrentCamera
        if cam and data.LookVector ~= nil then
            local look = cam.CFrame.LookVector
            local y = (typeof(data.LookVector) == "Vector3") and data.LookVector.Y or 0
            local lv = Vector3.new(look.X, y, look.Z)
            if lv.Magnitude > 0.001 then
                data.LookVector = lv.Unit
            end
        end
    end
end

local function applyServeBoost(name, args)
    if AutoStrongServeEveryServeEnabled and name == "Serve" and args[2] ~= nil then
        args[2] = ServeBoostPower
    end
end

local originalNamecall
local remoteNameVerdict = {}
do
    local hookOk, prevNamecall = pcall(hookmetamethod, game, "__namecall", newcclosure(function(self, ...)
    local method = getnamecallmethod()
    if method ~= "InvokeServer" and method ~= "FireServer" then
        return originalNamecall(self, ...)
    end
    if ShijinUnloaded then return originalNamecall(self, ...) end
    local nameOk, nameVal = pcall(getRemoteName, self)
    local name = (nameOk and nameVal) or ""
    local verdict = remoteNameVerdict[name]
    if verdict == nil then
        verdict = isAntiCheatRemote(name) and true or false
        if #name <= 64 then
            remoteNameVerdict[name] = verdict
        end
    end
    if verdict then return end
    if name ~= "Interact" and name ~= "Serve" then
        return originalNamecall(self, ...)
    end
    local args = { ... }
    pcall(applyDirectionalHit, name, args)
    pcall(applyServeBoost, name, args)
    return originalNamecall(self, unpack(args, 1, select("#", ...)))
end))
    originalNamecall = hookOk and prevNamecall or nil
end
end

local AntiModEnabled = true
local VBL_GROUP_ID = 35330702
local ModeratorList = {
    "ask_snapaple", "llotiiee", "Vezire123", "astratoka", "SneakyTiki1",
    "StarlightStarbrighht", "7Stxqr3", "xToruz", "koalacoco345",
    "Chrisdaman1122", "LebronjamesEl7a2e2ee", "PineCrumb", "HeyCrafted",
    "Dondred02", "Place_Reboot", "noahrepublic", "KumagawasFiction",
    "T0tallyN0tATr0ll", "Protori", "BarDowned", "GoodSirVolleyball"
}

local modRankCache = {}
local modRankUnknown = {}
local ModeratorListLower = {}
for _i = 1, #ModeratorList do
    ModeratorListLower[_i] = string.lower(ModeratorList[_i])
end
local function isModerator(player)
    if not player or player == LocalPlayer then return false, "" end
    local pName = tostring(player.Name or ""):lower()
    local pDisplay = tostring(player.DisplayName or ""):lower()
    for _, m in ipairs(ModeratorListLower) do
        if pName == m or pDisplay == m then
            return true, player.Name .. " (Staff List)"
        end
    end
    local rank
    local cached = modRankCache[player]
    if cached and os.clock() - cached.t < 60 then
        rank = cached.rank
    else
        local ok = pcall(function()
            rank = player:GetRankInGroup(VBL_GROUP_ID)
        end)
        if ok and type(rank) == "number" then
            modRankCache[player] = { t = os.clock(), rank = rank }
            modRankUnknown[player] = nil
        else
            rank = nil
            modRankUnknown[player] = true
        end
    end
    if type(rank) == "number" and rank >= 50 then
        return true, player.Name .. " (Group Rank: " .. tostring(rank) .. ")"
    end
    return false, ""
end

checkPlayerForMod = function(player, attempt)
    if not AntiModEnabled or ShijinUnloaded then return false end
    if not player or player == LocalPlayer or not player.Parent then return false end
    local isMod, reason = isModerator(player)
    if isMod then
        LocalPlayer:Kick("Shijin Hub: Staff member detected [" .. tostring(reason) .. "]. Safety kick activated.")
        return true
    end
    attempt = attempt or 1
    if modRankUnknown[player] and attempt < 4 then
        task.delay(4, function() checkPlayerForMod(player, attempt + 1) end)
    end
    return false
end

local function checkForModerators()
    for _, player in ipairs(Players:GetPlayers()) do
        if checkPlayerForMod(player, 1) then
            return true
        end
    end
    return false
end

hubConn(Players.PlayerAdded, function(player)
    checkPlayerForMod(player, 1)
end)

local function cacheSpinRemotes()
    local services = findKnitServices()
    if not services then return false end
    local foundStyleRoll, foundAbilityRoll, foundStyleSelect, foundAbilitySelect = nil, nil, nil, nil
    pcall(function()
        local st = services:FindFirstChild("StyleService")
        local ab = services:FindFirstChild("AbilityService")
        local stRF = st and st:FindFirstChild("RF")
        local abRF = ab and ab:FindFirstChild("RF")
        foundStyleRoll = stRF and stRF:FindFirstChild("Roll")
        foundStyleSelect = stRF and stRF:FindFirstChild("SelectSlot")
        foundAbilityRoll = abRF and abRF:FindFirstChild("Roll")
        foundAbilitySelect = abRF and abRF:FindFirstChild("SelectSlot")
    end)
    if foundStyleRoll then styleRollRemote = foundStyleRoll end
    if foundAbilityRoll then abilityRollRemote = foundAbilityRoll end
    if foundStyleSelect then styleSelectSlot = foundStyleSelect end
    if foundAbilitySelect then abilitySelectSlot = foundAbilitySelect end
    return (styleRollRemote and styleRollRemote.Parent) or (abilityRollRemote and abilityRollRemote.Parent)
end

task.spawn(function()
    for _ = 1, 3 do
        if cacheSpinRemotes() then break end
        task.wait(2)
    end
end)

do
local rollTextWindow, rollWindowOpenAt, rollWindowSeconds = {}, 0, 0
local lastSelectedType, lastSelectedSlot = nil, nil
local spinRemoteFails = 0
local rollWatchConns = {}
local uninstallRollWatch
resetSpinFails = function() spinRemoteFails = 0 end

local function remoteLive(remote)
    return remote ~= nil and remote.Parent ~= nil
end

local function stopAutoSpin(reason)
    FeatureConfig.autoSpinRunId = FeatureConfig.autoSpinRunId + 1
    AutoSpinEnabled = false
    AutoSpinBusy = false
    lastAutoSpin = 0
    if uninstallRollWatch then pcall(uninstallRollWatch) end
    pcall(autoSpinStatus)
    pcall(function()
        local t = OrionLib.Flags["AutoSpinToggle"]
        if t then t:Set(false) end
    end)
    if reason then notify(reason, 6) end
end

local function tryStopOnRarity(res)
    if AutoSpinStopOnRarity == "" or not res or res.rarity == "" then return false end
    local need = RARITY_RANK[AutoSpinStopOnRarity] or 0
    local got = RARITY_RANK[res.rarity]
    if got and need > 0 and got >= need then
        local bonus = (got > need) and (" (better than " .. AutoSpinStopOnRarity .. ")") or ""
        stopAutoSpin("Auto Spin stopped — rolled " .. res.rarity .. bonus)
        return true
    end
    return false
end

local function rarityFromText(low)
    if low:find("%f[%a]secret%f[%A]") then return "Secret"
    elseif low:find("%f[%a]godly%f[%A]") then return "Godly"
    elseif low:find("%f[%a]legendary%f[%A]") then return "Legendary"
    elseif low:find("%f[%a]ultra%f[%A]") then return "Ultra"
    elseif low:find("%f[%a]evo%f[%A]") then return "Evo"
    end
    return nil
end

local function scanResultTexts(texts, result)
    for _, t in ipairs(texts) do
        local low = string.lower(tostring(t or ""))
        local r = rarityFromText(low)
        if r and (RARITY_RANK[r] or 0) > (RARITY_RANK[result.rarity] or 0) then
            result.rarity = r
        end
    end
end

local function hasRollResultContext(obj)
    local current, depth = obj, 0
    while current and depth < 8 do
        local name = string.lower(tostring(current.Name or ""))
        if name:find("chance", 1, true) or name:find("odds", 1, true)
            or name:find("probability", 1, true) or name:find("rate", 1, true) then
            return false
        end
        if name:find("result", 1, true) or name:find("reward", 1, true)
            or name:find("reveal", 1, true) or name:find("rolled", 1, true) then
            return true
        end
        current, depth = current.Parent, depth + 1
    end
    return false
end

local function confirmedRarityFromGui(text, obj)
    local low = string.lower(tostring(text or ""))
    local rarity = rarityFromText(low)
    if not rarity then return nil end
    if low:find("chance", 1, true) or low:find("odds", 1, true)
        or low:find("probability", 1, true) or low:find("rate", 1, true) then
        return nil
    end
    if low:find("you rolled", 1, true) or low:find("rolled", 1, true)
        or low:find("you got", 1, true) or low:find("obtained", 1, true)
        or low:find("received", 1, true) or low:find("new style", 1, true)
        or low:find("new ability", 1, true) then
        return rarity
    end
    if hasRollResultContext(obj) then return rarity end
    return nil
end

local function deepText(v, out, seen, depth)
    local tv = type(v)
    if tv == "string" then
        if #out < 120 then out[#out + 1] = v end
    elseif tv == "table" and depth < 6 then
        seen = seen or {}
        if seen[v] then return end
        seen[v] = true
        for _, val in pairs(v) do
            if #out >= 120 then break end
            deepText(val, out, seen, depth + 1)
        end
    elseif tv == "userdata" and #out < 120 then
        pcall(function() out[#out + 1] = tostring(v) end)
    end
end

local function installRollWatch()
    if #rollWatchConns > 0 then return end
    local pg = LocalPlayer:FindFirstChild("PlayerGui")
    if not pg then return end
    local function inOwnHub(obj)
        local ok, root = pcall(function() return obj:FindFirstAncestorOfClass("ScreenGui") end)
        return ok and root ~= nil and string.find(string.lower(tostring(root.Name)), "uxo", 1, true) ~= nil
    end
    local function inChat(obj)
        local ok, root = pcall(function() return obj:FindFirstAncestorOfClass("ScreenGui") end)
        return ok and root ~= nil and (root.Name == "Chat" or root.Name == "BubbleChat")
    end
    local function record(txt, obj)
        if not AutoSpinEnabled or os.clock() - rollWindowOpenAt > rollWindowSeconds then return end
        if #rollTextWindow >= 80 then return end
        local rarity = confirmedRarityFromGui(txt, obj)
        if rarity then
            rollTextWindow[#rollTextWindow + 1] = rarity
        end
    end
    local function watch(obj)
        if not (obj:IsA("TextLabel") or obj:IsA("TextButton") or obj:IsA("TextBox")) then return end
        if inOwnHub(obj) or inChat(obj) then return end
        rollWatchConns[#rollWatchConns + 1] = obj:GetPropertyChangedSignal("Text"):Connect(function()
            record(obj.Text, obj)
        end)
    end
    for _, obj in ipairs(pg:GetDescendants()) do pcall(watch, obj) end
    rollWatchConns[#rollWatchConns + 1] = pg.DescendantAdded:Connect(function(obj)
        pcall(watch, obj)
        if obj:IsA("TextLabel") or obj:IsA("TextButton") or obj:IsA("TextBox") then
            if not inOwnHub(obj) and not inChat(obj) then record(obj.Text, obj) end
        end
    end)
end

uninstallRollWatch = function()
    for _, c in ipairs(rollWatchConns) do
        pcall(function() c:Disconnect() end)
    end
    rollWatchConns = {}
    rollTextWindow = {}
    rollWindowOpenAt, rollWindowSeconds = 0, 0
end
uninstallAutoSpinWatch = uninstallRollWatch

local function readLastRollResult(rollReturn, guiTexts)
    local remote, gui = { rarity = "" }, { rarity = "" }
    if rollReturn ~= nil then
        local texts = {}
        deepText(rollReturn, texts, {}, 0)
        local seen = {}
        for _, t in ipairs(texts) do
            local r = rarityFromText(string.lower(tostring(t or "")))
            if r then seen[r] = true end
        end
        local only, count = nil, 0
        for r in pairs(seen) do
            count = count + 1
            only = r
        end
        if count == 1 then remote.rarity = only end
    end
    scanResultTexts(guiTexts or rollTextWindow, gui)
    return { rarity = (remote.rarity ~= "" and remote.rarity) or gui.rarity }
end

local function failAutoSpin(message)
    spinRemoteFails = spinRemoteFails + 1
    AutoSpinBusy = false
    local maxFails = math.max(1, math.floor(tonumber(FeatureConfig.autoSpinMaxFailures) or 8))
    AutoSpinBackoff = os.clock() + math.min(5, 0.25 * spinRemoteFails)
    if spinRemoteFails >= maxFails then
        stopAutoSpin("Auto Spin stopped — " .. message)
    else
        autoSpinStatus("Retrying " .. tostring(spinRemoteFails) .. "/" .. tostring(maxFails))
    end
end

local function doAutoSpinOnce()
    if AutoSpinBusy then return end
    if FeatureConfig.autoSpinPauseInLobby and isInLobbyCached and isInLobbyCached() then
        autoSpinStatus("Waiting for match")
        return
    end
    if os.clock() < AutoSpinBackoff then return end
    if AutoSpinLimit > 0 and AutoSpinCount >= AutoSpinLimit then
        stopAutoSpin(string.format("Auto Spin: reached the %d spin limit", AutoSpinLimit))
        return
    end
    local nowSpin = os.clock()
    if nowSpin - lastAutoSpin < AutoSpinSpeed then return end
    lastAutoSpin = nowSpin
    local runId = FeatureConfig.autoSpinRunId
    AutoSpinBusy = true
    cacheSpinRemotes()

    local rollRemote = AutoSpinType == "Style" and styleRollRemote or abilityRollRemote
    local selectRemote = AutoSpinType == "Style" and styleSelectSlot or abilitySelectSlot
    if not remoteLive(rollRemote) then
        failAutoSpin(tostring(AutoSpinType) .. " Roll remote is unavailable")
        return
    end
    if not remoteLive(selectRemote) then
        failAutoSpin(tostring(AutoSpinType) .. " slot selector is unavailable")
        return
    end

    if AutoSpinReselectSlot or lastSelectedType ~= AutoSpinType or lastSelectedSlot ~= AutoSpinSlot then
        local selected, selectErr = pcall(function()
            return selectRemote:InvokeServer(AutoSpinSlot)
        end)
        if not selected then
            cacheSpinRemotes()
            failAutoSpin("could not select slot " .. tostring(AutoSpinSlot) .. " (" .. tostring(selectErr):sub(1, 40) .. ")")
            return
        end
        lastSelectedType, lastSelectedSlot = AutoSpinType, AutoSpinSlot
        task.wait(0.05)
        if not AutoSpinEnabled or runId ~= FeatureConfig.autoSpinRunId then return end
    end

    rollWindowOpenAt = os.clock()
    rollTextWindow = {}
    local evalDelay = math.clamp(AutoSpinSpeed * 0.9, 0.35, 0.9)
    rollWindowSeconds = evalDelay + 0.65
    installRollWatch()
    local callOk, rollReturn = pcall(function()
        if AutoSpinUseLucky then
            return table.pack(rollRemote:InvokeServer(true))
        end
        return table.pack(rollRemote:InvokeServer())
    end)
    if not callOk then
        cacheSpinRemotes()
        failAutoSpin("the server rejected the roll (" .. tostring(rollReturn):sub(1, 40) .. ")")
        return
    end

    spinRemoteFails = 0
    AutoSpinBackoff = 0
    AutoSpinCount = AutoSpinCount + 1
    if AutoSpinStartedAt == 0 then AutoSpinStartedAt = os.clock() end
    autoSpinStatus("Checking result")

    task.delay(evalDelay, function()
        if runId ~= FeatureConfig.autoSpinRunId or not AutoSpinEnabled then return end
        local res = readLastRollResult(rollReturn, rollTextWindow)
        if res and res.rarity and res.rarity ~= "" then
            AutoSpinLastRarity = res.rarity
        end
        local stopped = tryStopOnRarity(res)
        if runId == FeatureConfig.autoSpinRunId and not stopped then
            AutoSpinBusy = false
            autoSpinStatus()
        end
    end)
end

local autoSpinLoopOn = false
startAutoSpinLoop = function()
    if autoSpinLoopOn or not AutoSpinEnabled then return end
    autoSpinLoopOn = true
    local runId = FeatureConfig.autoSpinRunId
    task.spawn(function()
        while AutoSpinEnabled and not ShijinUnloaded and runId == FeatureConfig.autoSpinRunId do
            pcall(doAutoSpinOnce)
            task.wait(math.max(0.08, AutoSpinSpeed * 0.5))
        end
        autoSpinLoopOn = false
        if runId == FeatureConfig.autoSpinRunId then
            uninstallRollWatch()
        elseif AutoSpinEnabled and not ShijinUnloaded then
            task.defer(startAutoSpinLoop)
        end
    end)
end
end
local JumpBoostBaseline = nil
local JumpBoostConn = nil
local JumpBoostLastApply = 0

local function captureJumpBaseline(hum)
    if JumpBoostBaseline and JumpBoostBaseline.Humanoid == hum then return end
    local p, h = 50, 7.2
    pcall(function()
        p = hum.JumpPower
        h = hum.JumpHeight
    end)
    if type(p) ~= "number" or p <= 0 or p > 100 then p = 50 end
    if type(h) ~= "number" or h <= 0 or h > 12 then h = 7.2 end
    JumpBoostBaseline = { Humanoid = hum, Power = p, Height = h }
end

local jbChar, jbHum = nil, nil
local function applyJumpBoost()
    if not JumpBoostEnabled or ShijinUnloaded then return end
    local now = os.clock()
    if now - JumpBoostLastApply < math.clamp(tonumber(FeatureConfig.jumpBoostRefreshRate) or 0.12, 0.03, 1) then return end
    JumpBoostLastApply = now
    local char = LocalPlayer.Character
    if not char then return end
    if char ~= jbChar or not (jbHum and jbHum.Parent) then
        jbChar = char
        jbHum = char:FindFirstChildOfClass("Humanoid")
    end
    local hum = jbHum
    if not hum or hum.Health <= 0 then return end
    captureJumpBaseline(hum)
    local base = JumpBoostBaseline or { Power = 50, Height = 7.2 }
    local targetP = base.Power * JumpBoostMult
    local targetH = base.Height * JumpBoostMult
    pcall(function()
        if hum.JumpPower ~= targetP then hum.JumpPower = targetP end
        if hum.JumpHeight ~= targetH then hum.JumpHeight = targetH end
    end)
end

local function restoreJumpBoost()
    local baseline = JumpBoostBaseline
    local hum = baseline and baseline.Humanoid
    if hum and hum.Parent then
        pcall(function()
            hum.JumpPower = baseline.Power
            hum.JumpHeight = baseline.Height
        end)
    end
    JumpBoostBaseline = nil
    JumpBoostLastApply = 0
end

local function setJumpBoostEnabled(state)
    JumpBoostEnabled = state == true
    JumpBoostLastApply = 0
    if JumpBoostEnabled then
        pcall(applyJumpBoost)
        if not JumpBoostConn then
            JumpBoostConn = RunService.Heartbeat:Connect(function()
                if JumpBoostEnabled then
                    pcall(applyJumpBoost)
                end
            end)
        end
    else
        pcall(restoreJumpBoost)
        if JumpBoostConn then JumpBoostConn:Disconnect() JumpBoostConn = nil end
    end
end

pcall(function()
    hubConn(LocalPlayer.CharacterAdded, function(char)
        if not JumpBoostEnabled then return end
        local hum = char:WaitForChild("Humanoid", 5)
        if hum then
            task.wait(0.1)
            pcall(applyJumpBoost)
        end
    end)
end)

local JumpESPObjects = {}
local PredictAimObjects = {}
local teamWatchConns = {}

local function getPlayerTeam(player)
    if player.Team then return player.Team end
    return nil
end

local function isEnemy(player)
    if player == LocalPlayer then return false end
    local localTeam = getPlayerTeam(LocalPlayer)
    local playerTeam = getPlayerTeam(player)
    if localTeam and playerTeam then return localTeam ~= playerTeam end
    return true
end

local enemyPartCache = {}
local function getEnemyParts(player)
    local char = player.Character
    local e = enemyPartCache[player]
    if e and e.char == char and char then
        local root, head, hum = e.root, e.head, e.hum
        if root and root.Parent and head and head.Parent and (not hum or hum.Parent) then
            return char, hum, root, head
        end
    end
    local hum, root, head = nil, nil, nil
    if char then
        hum = char:FindFirstChildOfClass("Humanoid")
        root = char:FindFirstChild("HumanoidRootPart")
        head = char:FindFirstChild("Head")
    end
    enemyPartCache[player] = { char = char, hum = hum, root = root, head = head }
    return char, hum, root, head
end

local function isJumping(player)
    local _, humanoid, rootPart = getEnemyParts(player)
    if humanoid and rootPart then
        local state = humanoid:GetState()
        if state == Enum.HumanoidStateType.Jumping or state == Enum.HumanoidStateType.Freefall then return true end
        if rootPart.AssemblyLinearVelocity.Y > 5 then return true end
    end
    return false
end

local function createJumpESP(player)
    local character = player.Character
    if not character or not character.Parent then return end
    if JumpESPObjects[player] then JumpESPObjects[player]:Destroy() JumpESPObjects[player] = nil end
    local highlight = Instance.new("Highlight")
    highlight.Name = "JumpESP"
    highlight.Adornee = character
    highlight.FillColor = JumpESPColor
    highlight.OutlineColor = JumpESPColor
    highlight.FillTransparency = math.clamp(FeatureConfig.jumpEspFillTransparency, 0, 1)
    highlight.OutlineTransparency = math.clamp(FeatureConfig.jumpEspOutlineTransparency, 0, 1)
    highlight.DepthMode = FeatureConfig.jumpEspAlwaysOnTop and Enum.HighlightDepthMode.AlwaysOnTop or Enum.HighlightDepthMode.Occluded
    highlight.Parent = character
    JumpESPObjects[player] = highlight
end

local function removeJumpESP(player)
    if JumpESPObjects[player] then JumpESPObjects[player]:Destroy() JumpESPObjects[player] = nil end
end

local function syncPredictLine(player)
    local entry = PredictAimObjects[player]
    local localRoot = LocalPlayer.Character and LocalPlayer.Character:FindFirstChild("HumanoidRootPart")
    if PredictAimLength <= 0 or not player.Parent or not isEnemy(player) then
        if entry then
            if entry.Line then entry.Line:Destroy() end
            PredictAimObjects[player] = nil
            enemyPartCache[player] = nil
        end
        return
    end
    local character, _, rootPart, head = getEnemyParts(player)
    if not character or not rootPart or not head or not rootPart.Parent or not head.Parent
        or (localRoot and (rootPart.Position - localRoot.Position).Magnitude > math.max(FeatureConfig.predictAimMaxDistance, 20)) then
        if entry then
            if entry.Line then entry.Line:Destroy() end
            PredictAimObjects[player] = nil
        end
        enemyPartCache[player] = nil
        return
    end
    local look = rootPart.CFrame.LookVector
    if look.Magnitude < 0.01 then
        if entry then
            if entry.Line then entry.Line:Destroy() end
            PredictAimObjects[player] = nil
        end
        return
    end
    local spikeDirection = look.Unit
    local startPos = head.Position + Vector3.new(0, 1, 0)
    local endPos = startPos + (spikeDirection * PredictAimLength)
    local midPoint = (startPos + endPos) / 2
    local line = entry and entry.Line
    if not line or not line.Parent then
        line = Instance.new("Part")
        line.Name = "PredictLine"
        line.Anchored = true
        line.CanCollide = false
        line.CastShadow = false
        line.Material = Enum.Material.Neon
        line.Color = PredictAimColor
        line.Size = Vector3.new(FeatureConfig.predictAimThickness, FeatureConfig.predictAimThickness, PredictAimLength)
        line.Transparency = FeatureConfig.predictAimTransparency
        line.Parent = Workspace
        PredictAimObjects[player] = { Line = line }
    end
    if line.Size.Z ~= PredictAimLength or line.Size.X ~= FeatureConfig.predictAimThickness then
        line.Size = Vector3.new(FeatureConfig.predictAimThickness, FeatureConfig.predictAimThickness, PredictAimLength)
    end
    if line.Color ~= PredictAimColor then line.Color = PredictAimColor end
    if line.Transparency ~= FeatureConfig.predictAimTransparency then line.Transparency = FeatureConfig.predictAimTransparency end
    line.CFrame = CFrame.lookAt(midPoint, endPos)
end

local function removePredictLine(player)
    if PredictAimObjects[player] then
        if PredictAimObjects[player].Line then PredictAimObjects[player].Line:Destroy() end
        PredictAimObjects[player] = nil
    end
end

local function watchPlayerTeam(player)
    if teamWatchConns[player] then return end
    local ok, conn = pcall(function()
        return player:GetPropertyChangedSignal("Team"):Connect(function()
            pcall(function() removePredictLine(player) end)
            pcall(function() removeJumpESP(player) end)
            enemyPartCache[player] = nil
        end)
    end)
    if ok and conn then teamWatchConns[player] = conn end
end

local function clearAllJumpESP()
    for player, obj in pairs(JumpESPObjects) do if obj then obj:Destroy() end end
    JumpESPObjects = {}
end

local function clearAllPredictAim()
    for player, obj in pairs(PredictAimObjects) do
        if obj and obj.Line then obj.Line:Destroy() end
    end
    PredictAimObjects = {}
end

local localTeamWatchConn = LocalPlayer:GetPropertyChangedSignal("Team"):Connect(function()
    pcall(clearAllPredictAim)
    pcall(clearAllJumpESP)
    enemyPartCache = {}
end)

local lastHitboxPass = 0
local function modifyBallHitbox()
    local size = math.clamp(tonumber(HitboxSize) or 0, 0, 25)
    if size <= 0 then return end
    local root = LocalPlayer.Character and LocalPlayer.Character:FindFirstChild("HumanoidRootPart")
    for _, v in ipairs(VX.list()) do
        if v:IsA("Model") then
            local ballPart
            for _, part in ipairs(v:GetDescendants()) do
                if part:IsA("BasePart") and part.Name ~= "ExtendedHitbox"
                    and part:GetAttribute("ShijinHitbox") ~= true then
                    ballPart = part
                    break
                end
            end
            if ballPart and (not root or (ballPart.Position - root.Position).Magnitude <= math.max(FeatureConfig.hitboxMaxDistance, 10)) then
                local existingHitbox = v:FindFirstChild("ExtendedHitbox")
                if existingHitbox and existingHitbox:IsA("BasePart") then
                    existingHitbox.Size = Vector3.new(size, size, size)
                    existingHitbox.Color = HitboxColor
                    existingHitbox.Transparency = HitboxTransparency
                    existingHitbox.Material = FeatureConfig.hitboxMaterial
                    existingHitbox.CanCollide = false
                    existingHitbox.CanTouch = true
                    pcall(function() existingHitbox.CanQuery = true end)
                    existingHitbox.CastShadow = false
                    existingHitbox.CFrame = ballPart.CFrame
                    local weld = existingHitbox:FindFirstChildWhichIsA("WeldConstraint")
                    if not weld or weld.Part0 ~= ballPart or weld.Part1 ~= existingHitbox then
                        if weld then weld:Destroy() end
                        weld = Instance.new("WeldConstraint")
                        weld.Part0 = ballPart
                        weld.Part1 = existingHitbox
                        weld.Parent = existingHitbox
                    end
                else
                    local hitbox = Instance.new("Part")
                    hitbox.Name = "ExtendedHitbox"
                    hitbox.Size = Vector3.new(size, size, size)
                    hitbox.Transparency = HitboxTransparency
                    hitbox.Color = HitboxColor
                    hitbox.Material = FeatureConfig.hitboxMaterial
                    hitbox.CanCollide = false
                    hitbox.CanTouch = true
                    pcall(function() hitbox.CanQuery = true end)
                    hitbox.CastShadow = false
                    hitbox.Massless = true
                    hitbox.Anchored = false
                    hitbox.Shape = Enum.PartType.Ball
                    hitbox.CFrame = ballPart.CFrame
                    hitbox:SetAttribute("ShijinHitbox", true)
                    hitbox.Parent = v
                    local weld = Instance.new("WeldConstraint")
                    weld.Part0 = ballPart
                    weld.Part1 = hitbox
                    weld.Parent = hitbox
                end
            end
        end
    end
end

local function removeHitboxes()
    for _, v in ipairs(VX.list()) do
        if v:IsA("Model") then
            local hitbox = v:FindFirstChild("ExtendedHitbox")
            if hitbox then pcall(VX.destroy, hitbox) end
        end
    end
    for _, obj in ipairs(Workspace:GetDescendants()) do
        if obj.Name == "ExtendedHitbox" and obj:GetAttribute("ShijinHitbox") == true then
            pcall(VX.destroy, obj)
        end
    end
end

local function setNameTagsEnabled(char, enabled, saved)
    for _, obj in pairs(char:GetDescendants()) do
        if obj:IsA("BillboardGui") or obj:IsA("SurfaceGui") then
            local n = (obj.Name or ""):lower()
            if n:find("name") or n:find("tag") or n:find("overhead") or n:find("rank") then
                if saved and not enabled and saved[obj] == nil then saved[obj] = obj.Enabled end
                if enabled and saved and saved[obj] ~= nil then
                    obj.Enabled = saved[obj]
                else
                    obj.Enabled = enabled
                end
            end
        end
    end
end

local function hidePlayerName(p)
    if not p then return end
    local char = p.Character
    if not char then return end
    local hum = char:FindFirstChildOfClass("Humanoid")
    if hum then
        if streamerOriginalDisplay[p] == nil then
            streamerOriginalDisplay[p] = {
                NameDisplayDistance = hum.NameDisplayDistance,
                DisplayDistanceType = hum.DisplayDistanceType,
                Tags = {},
            }
        end
        pcall(function()
            hum.NameDisplayDistance = 0
            hum.DisplayDistanceType = Enum.HumanoidDisplayDistanceType.None
        end)
    end
    setNameTagsEnabled(char, false, streamerOriginalDisplay[p] and streamerOriginalDisplay[p].Tags)
end

local function restorePlayerName(p)
    if not p then return end
    local data = streamerOriginalDisplay[p]
    local char = p.Character
    if char and data then
        local hum = char:FindFirstChildOfClass("Humanoid")
        if hum then
            pcall(function()
                hum.NameDisplayDistance = data.NameDisplayDistance or 100
                hum.DisplayDistanceType = data.DisplayDistanceType or Enum.HumanoidDisplayDistanceType.Viewer
            end)
        end
        setNameTagsEnabled(char, true, data.Tags)
    end
    streamerOriginalDisplay[p] = nil
end

local function applyStreamerMode()
    for _, p in pairs(Players:GetPlayers()) do
        if FeatureConfig.streamerHideSelf or p ~= LocalPlayer then hidePlayerName(p) end
    end
end
local function disableStreamerMode()
    for _, p in pairs(Players:GetPlayers()) do restorePlayerName(p) end
    streamerOriginalDisplay = {}
end

local playerCharacterConns = {}
local function watchPlayerCharacter(p)
    safeDisconnect(playerCharacterConns[p])
    playerCharacterConns[p] = p.CharacterAdded:Connect(function()
        streamerOriginalDisplay[p] = nil
        enemyPartCache[p] = nil
        if StreamerModeEnabled then task.defer(function() hidePlayerName(p) end) end
    end)
end
hubConn(Players.PlayerAdded, function(p)
    watchPlayerTeam(p)
    watchPlayerCharacter(p)
end)
for _, p in pairs(Players:GetPlayers()) do
    watchPlayerTeam(p)
    watchPlayerCharacter(p)
end
local streamerLoopOn = false
startStreamerLoop = function()
    if streamerLoopOn or not StreamerModeEnabled then return end
    streamerLoopOn = true
    task.spawn(function()
        while StreamerModeEnabled and not ShijinUnloaded do
            task.wait(math.clamp(tonumber(FeatureConfig.streamerRefreshRate) or 3, 0.5, 10))
            if StreamerModeEnabled then pcall(applyStreamerMode) end
        end
        streamerLoopOn = false
    end)
end

local function isInLobby()
    local pg = LocalPlayer:FindFirstChild("PlayerGui")
    local teamSelectionUI = pg and pg:FindFirstChild("Interface")
    if teamSelectionUI then
        local teamSelection = teamSelectionUI:FindFirstChild("TeamSelection")
        if teamSelection and teamSelection.Visible then return true end
    end
    local character = LocalPlayer.Character
    local humanoid = character and character:FindFirstChildOfClass("Humanoid")
    if not humanoid or humanoid.Health <= 0 then return true end
    return false
end

local lobbyCache, lobbyT = false, -10
isInLobbyCached = function()
    local nowLb = os.clock()
    if nowLb - lobbyT < 0.5 then return lobbyCache end
    lobbyT = nowLb
    local okLb, resLb = pcall(isInLobby)
    lobbyCache = (okLb and resLb) or false
    return lobbyCache
end

local BALL_ESP_STEPS = 34
local BALL_ESP_KNOTS = 5
local BALL_ESP_RATE  = 1 / 45
local BALL_ESP_MAX_T = 6

BallESP = {
    enabled      = false,
    lineColor    = Color3.fromRGB(0, 225, 255),
    landColor    = Color3.fromRGB(170, 0, 255),
    transparency = 0.55,
    circleSize   = 7,
    gravityScale = 1,
    folder     = nil,
    segments   = {},
    disc       = nil,
    halo       = nil,
    lastUpdate = 0,
    ball       = nil,
    motion     = {},
    deepCache  = {},
    deepT      = -10,
    samples    = {},
    gravity    = nil,
    smoothLand = nil,
    status     = "off",
    statusLabel = nil,
    lastWarn   = 0,
    shot        = nil,
    alpha       = 0,
    visible     = false,
    renderConn  = nil,
    velFiltered = nil,
    useBeams    = false,
    minSpeed    = 2,
    maxDistance = 500,
    rig         = nil,
    atts        = {},
    beams       = {},
}

function BallESP.setQuality(name)
    if name == "Low" then
        BALL_ESP_STEPS, BALL_ESP_KNOTS, BALL_ESP_RATE = 18, 3, 1 / 30
    elseif name == "High" then
        BALL_ESP_STEPS, BALL_ESP_KNOTS, BALL_ESP_RATE = 50, 7, 1 / 60
    else
        BALL_ESP_STEPS, BALL_ESP_KNOTS, BALL_ESP_RATE = 34, 5, 1 / 45
    end
    BallESP.lastUpdate = 0
end

function BallESP.setStatus(text)
    if BallESP.status == text then return end
    BallESP.status = text
    if BallESP.statusLabel then
        pcall(function() BallESP.statusLabel:Set("State: " .. text) end)
    end
end

function BallESP.container()
    local f = BallESP.folder
    if f and f.Parent then return f end
    f = Instance.new("Folder")
    f.Name = "ShijinBallESP"
    local okCam = pcall(function() f.Parent = Workspace.CurrentCamera end)
    if not okCam or not f.Parent then
        pcall(function() f.Parent = Workspace end)
    end
    BallESP.folder = f
    return f
end

function BallESP.ballPartOf(model)
    local part = model.PrimaryPart or model:FindFirstChildWhichIsA("BasePart")
    if part and part.Name == "ExtendedHitbox" then
        part = nil
        for _, d in ipairs(model:GetDescendants()) do
            if d:IsA("BasePart") and d.Name ~= "ExtendedHitbox" then part = d break end
        end
    end
    return part
end

function BallESP.cheapCandidates()
    local list = VX.cheapBuf
    VX.clear(list)
    for _, v in ipairs(VX.list()) do
        local part = nil
        if not v.Name:find("CLIENT_BALL", 1, true) then
            part = nil
        elseif v:IsA("Model") then
            part = BallESP.ballPartOf(v)
        elseif v:IsA("BasePart") then
            part = v
        end
        if part then list[#list + 1] = part end
    end
    return list
end

function BallESP.deepScan()
    local found = {}
    pcall(function()
        for _, v in ipairs(Workspace:GetDescendants()) do
            if v:IsA("BasePart") and v.Name ~= "ExtendedHitbox" then
                local keep = false
                local n = string.lower(v.Name)
                local pn = v.Parent and string.lower(v.Parent.Name) or ""
                if n:find("ball", 1, true) or pn:find("ball", 1, true) then
                    keep = true
                elseif v:IsA("Part") and v.Shape == Enum.PartType.Ball
                    and math.max(v.Size.X, v.Size.Y, v.Size.Z) <= 6 then
                    keep = true
                end
                if keep and math.max(v.Size.X, v.Size.Y, v.Size.Z) <= 12 then
                    local model = v:FindFirstAncestorOfClass("Model")
                    local isPlayer = model and Players:GetPlayerFromCharacter(model)
                    local isOurs = BallESP.folder and v:IsDescendantOf(BallESP.folder)
                    if not isPlayer and not isOurs then
                        found[#found + 1] = v
                    end
                end
            end
        end
    end)
    return found
end

function BallESP.observe(list)
    local nowO = os.clock()
    local motion = BallESP.motion
    for _, p in ipairs(list) do
        local m = motion[p]
        if m then
            local dt = nowO - m.t
            if dt > 0.008 then
                local delta = p.Position - m.pos
                m.vel = delta / dt
                m.speed = m.vel.Magnitude
                m.pos, m.t = p.Position, nowO
            end
        else
            motion[p] = { t = nowO, pos = p.Position, vel = Vector3.new(0, 0, 0), speed = 0 }
        end
    end
    for p in pairs(motion) do
        if not p.Parent then motion[p] = nil end
    end
end

function BallESP.speedOf(part)
    local sp = part.AssemblyLinearVelocity.Magnitude
    if sp >= 1 then return sp end
    local m = BallESP.motion[part]
    return (m and m.speed) or 0
end

function BallESP.velocityOf(part)
    local v = part.AssemblyLinearVelocity
    if v.Magnitude >= 1 then return v end
    local m = BallESP.motion[part]
    return (m and m.vel) or v
end

function BallESP.pick()
    local list = BallESP.cheapCandidates()
    if #list == 0 then
        local nowD = os.clock()
        if nowD - BallESP.deepT > 1.5 then
            BallESP.deepT = nowD
            BallESP.deepCache = BallESP.deepScan()
        end
        for _, p in ipairs(BallESP.deepCache) do
            if p and p.Parent then list[#list + 1] = p end
        end
    end
    if #list == 0 then return nil end

    BallESP.observe(list)

    local root = LocalPlayer.Character and LocalPlayer.Character:FindFirstChild("HumanoidRootPart")
    local origin = root and root.Position or Vector3.new(0, 0, 0)
    local cur, best, bestScore = BallESP.ball, nil, -math.huge
    local maxDistance = math.max(tonumber(BallESP.maxDistance) or 500, 30)
    for _, p in ipairs(list) do
        local distance = (p.Position - origin).Magnitude
        if distance <= maxDistance then
            local score = -distance
            if BallESP.speedOf(p) >= BallESP.minSpeed then score = score + 1000 end
            if p == cur then score = score + 25 end
            if score > bestScore then best, bestScore = p, score end
        end
    end
    return best
end

function BallESP.sample(part)
    local s = BallESP.samples
    local nowS = os.clock()
    s[#s + 1] = { t = nowS, p = part.Position }
    while #s > 4 do table.remove(s, 1) end

    local vel = BallESP.velocityOf(part)

    if #s >= 3 then
        local a, b, c = s[#s - 2], s[#s - 1], s[#s]
        local dt1, dt2 = b.t - a.t, c.t - b.t
        if dt1 > 0.001 and dt2 > 0.001 then
            local v1y = (b.p.Y - a.p.Y) / dt1
            local v2y = (c.p.Y - b.p.Y) / dt2
            local g = -(v2y - v1y) / ((dt1 + dt2) * 0.5)
            if g > 20 and g < 3000 then
                BallESP.gravity = BallESP.gravity and (BallESP.gravity * 0.7 + g * 0.3) or g
            end
        end
    end
    return vel
end

function BallESP.effectiveGravity()
    local g = BallESP.gravity
    if not g or g <= 0 then g = Workspace.Gravity end
    if not g or g <= 0 then g = 196.2 end
    return g * (BallESP.gravityScale or 1)
end

function BallESP.rayParams()
    local params = RaycastParams.new()
    local okFilter = pcall(function() params.FilterType = Enum.RaycastFilterType.Exclude end)
    if not okFilter then
        pcall(function() params.FilterType = Enum.RaycastFilterType.Blacklist end)
    end
    local ignore = {}
    if BallESP.folder then table.insert(ignore, BallESP.folder) end
    for _, p in ipairs(Players:GetPlayers()) do
        if p.Character then table.insert(ignore, p.Character) end
    end
    local ball = BallESP.ball
    if ball then table.insert(ignore, ball.Parent or ball) end
    params.FilterDescendantsInstances = ignore
    params.IgnoreWater = true
    return params
end

function BallESP.groundY(pos, params)
    local y = nil
    local hit = Workspace:Raycast(pos, Vector3.new(0, -500, 0), params)
    if hit then y = hit.Position.Y end
    if not y then
        local okB, _, _, surfaceY = pcall(AutoCorner.bounds)
        if okB and type(surfaceY) == "number" then y = surfaceY end
    end
    return y or 0
end

function BallESP.solve(pos, vel, floorY, g)
    if g <= 0 then return nil end
    local drop = vel.Y * vel.Y + 2 * g * (pos.Y - floorY)
    if drop < 0 then return nil end
    local t = (vel.Y + math.sqrt(drop)) / g
    if t ~= t or t <= 0 or t > BALL_ESP_MAX_T then return nil end
    return t
end

function BallESP.samplePath(pos, vel, tEnd, g)
    local pts = {}
    local last = BALL_ESP_STEPS - 1
    for i = 0, last do
        local t = tEnd * (i / last)
        pts[i + 1] = Vector3.new(
            pos.X + vel.X * t,
            pos.Y + vel.Y * t - 0.5 * g * t * t,
            pos.Z + vel.Z * t
        )
    end
    return pts
end

function BallESP.segment(i)
    local seg = BallESP.segments[i]
    if seg and seg.Parent then return seg end
    seg = Instance.new("Part")
    seg.Name = "ShijinBallPath"
    seg.Anchored = true
    seg.CanCollide = false
    seg.CastShadow = false
    seg.Material = Enum.Material.Neon
    seg.Size = Vector3.new(0.2, 0.2, 1)
    seg.Color = BallESP.lineColor
    pcall(function() seg.CanQuery = false seg.CanTouch = false seg.Massless = true end)
    seg.Parent = BallESP.container()
    BallESP.segments[i] = seg
    return seg
end

function BallESP.rigPart()
    local rig = BallESP.rig
    if rig and rig.Parent then return rig end
    rig = Instance.new("Part")
    rig.Name = "ShijinBallRig"
    rig.Anchored = true
    rig.CanCollide = false
    rig.CastShadow = false
    rig.Transparency = 1
    rig.Size = Vector3.new(0.05, 0.05, 0.05)
    rig.CFrame = CFrame.new()
    pcall(function() rig.CanQuery = false rig.CanTouch = false rig.Massless = true end)
    rig.Parent = BallESP.container()
    BallESP.rig = rig
    BallESP.atts, BallESP.beams = {}, {}
    return rig
end

function BallESP.knot(i)
    local att = BallESP.atts[i]
    if att and att.Parent then return att end
    att = Instance.new("Attachment")
    att.Name = "ShijinKnot" .. i
    att.Parent = BallESP.rigPart()
    BallESP.atts[i] = att
    return att
end

function BallESP.beam(i)
    local beam = BallESP.beams[i]
    if beam and beam.Parent then return beam end
    beam = Instance.new("Beam")
    beam.Name = "ShijinBallBeam" .. i
    beam.FaceCamera = true
    beam.LightInfluence = 0
    beam.Segments = 16
    beam.Parent = BallESP.rigPart()
    BallESP.beams[i] = beam
    return beam
end

function BallESP.drawBeams(pos, vel, tEnd, g, alpha)
    if not BallESP.useBeams then return false end
    local ok = pcall(function()
        local knots = BALL_ESP_KNOTS
        local step = tEnd / knots
        local drop = Vector3.new(0, 1, 0)

        for i = 0, knots do
            local t = step * i
            local p = pos + vel * t - drop * (0.5 * g * t * t)
            local v = vel - drop * (g * t)
            if v.Magnitude < 0.01 then v = Vector3.new(0, -1, 0) end
            local att = BallESP.knot(i + 1)
            att.CFrame = CFrame.new(p, p + v.Unit) * CFrame.Angles(0, math.rad(90), 0)
            att:SetAttribute("Speed", v.Magnitude)
        end

        for i = 1, knots do
            local a0, a1 = BallESP.knot(i), BallESP.knot(i + 1)
            local f0, f1 = (i - 1) / knots, i / knots
            local beam = BallESP.beam(i)
            beam.Attachment0, beam.Attachment1 = a0, a1
            beam.CurveSize0 = (a0:GetAttribute("Speed") or 0) * step / 3
            beam.CurveSize1 = (a1:GetAttribute("Speed") or 0) * step / 3
            beam.Width0 = 0.26 - 0.13 * f0
            beam.Width1 = 0.26 - 0.13 * f1
            beam.Color = ColorSequence.new(
                BallESP.lineColor:Lerp(BallESP.landColor, math.clamp((f0 - 0.6) / 0.4, 0, 1) * 0.6),
                BallESP.lineColor:Lerp(BallESP.landColor, math.clamp((f1 - 0.6) / 0.4, 0, 1) * 0.6))
            local t0 = math.clamp(BallESP.transparency + 0.28 * f0, 0, 0.97)
            local t1 = math.clamp(BallESP.transparency + 0.28 * f1, 0, 0.97)
            beam.Transparency = NumberSequence.new(
                1 - (1 - t0) * alpha,
                1 - (1 - t1) * alpha)
            beam.Enabled = true
        end
    end)
    if not ok then
        BallESP.useBeams = false
        BallESP.hideBeams()
        return false
    end
    for _, seg in pairs(BallESP.segments) do
        if seg then seg.Transparency = 1 end
    end
    return true
end

function BallESP.hideBeams()
    for _, beam in pairs(BallESP.beams) do
        if beam then pcall(function() beam.Enabled = false end) end
    end
end

function BallESP.drawPath(pts, alpha)
    alpha = alpha or 1
    local n = #pts
    local used = 0
    for i = 1, n - 1 do
        local a, b = pts[i], pts[i + 1]
        local delta = b - a
        local len = delta.Magnitude
        if len > 0.01 then
            used = used + 1
            local seg = BallESP.segment(used)
            local frac = i / n
            local width = 0.26 - 0.13 * frac
            seg.Size = Vector3.new(width, width, len + 0.18)
            seg.CFrame = CFrame.new(a + delta * 0.5, b)
            local blend = math.clamp((frac - 0.65) / 0.35, 0, 1) * 0.55
            seg.Color = BallESP.lineColor:Lerp(BallESP.landColor, blend)
            local base = math.clamp(BallESP.transparency + 0.28 * frac, 0, 0.97)
            seg.Transparency = 1 - (1 - base) * alpha
            if not seg.Parent then seg.Parent = BallESP.container() end
        end
    end
    for i = used + 1, #BallESP.segments do
        local extra = BallESP.segments[i]
        if extra then extra.Transparency = 1 end
    end
    return used
end

function BallESP.marker(key, thickness)
    local part = BallESP[key]
    if part and part.Parent then return part end
    part = Instance.new("Part")
    part.Name = "ShijinBallLanding"
    part.Shape = Enum.PartType.Cylinder
    part.Anchored = true
    part.CanCollide = false
    part.CastShadow = false
    part.Material = Enum.Material.Neon
    part.Size = Vector3.new(thickness, 1, 1)
    part.Color = BallESP.landColor
    pcall(function() part.CanQuery = false part.CanTouch = false part.Massless = true end)
    part.Parent = BallESP.container()
    BallESP[key] = part
    return part
end

function BallESP.drawLanding(point, normal, alpha)
    alpha = alpha or 1
    local pulse = 1 + 0.05 * math.sin(os.clock() * 5.5)
    local d = math.max(BallESP.circleSize, 1) * pulse

    local disc = BallESP.marker("disc", 0.14)
    disc.Size = Vector3.new(0.14, d, d)
    disc.CFrame = CFrame.new(point + normal * 0.06, point + normal * 1.06)
        * CFrame.Angles(0, math.rad(90), 0)
    disc.Color = BallESP.landColor
    local discBase = math.clamp(BallESP.transparency * 0.6, 0, 0.9)
    disc.Transparency = 1 - (1 - discBase) * alpha

    local halo = BallESP.marker("halo", 0.08)
    halo.Size = Vector3.new(0.08, d * 1.5, d * 1.5)
    halo.CFrame = CFrame.new(point + normal * 0.03, point + normal * 1.03)
        * CFrame.Angles(0, math.rad(90), 0)
    halo.Color = BallESP.landColor
    local haloBase = math.clamp(0.55 + BallESP.transparency * 0.35, 0, 0.95)
    halo.Transparency = 1 - (1 - haloBase) * alpha
end

function BallESP.hideLanding()
    if BallESP.disc then BallESP.disc.Transparency = 1 end
    if BallESP.halo then BallESP.halo.Transparency = 1 end
end

function BallESP.hide()
    for _, seg in pairs(BallESP.segments) do
        if seg then seg.Transparency = 1 end
    end
    BallESP.hideBeams()
    BallESP.hideLanding()
    BallESP.smoothLand = nil
end

function BallESP.clear()
    for i, seg in pairs(BallESP.segments) do
        pcall(function() seg:Destroy() end)
        BallESP.segments[i] = nil
    end
    BallESP.segments = {}
    pcall(function() if BallESP.disc then BallESP.disc:Destroy() end end)
    pcall(function() if BallESP.halo then BallESP.halo:Destroy() end end)
    BallESP.disc, BallESP.halo = nil, nil
    for i, beam in pairs(BallESP.beams) do
        pcall(function() beam:Destroy() end)
        BallESP.beams[i] = nil
    end
    for i, att in pairs(BallESP.atts) do
        pcall(function() att:Destroy() end)
        BallESP.atts[i] = nil
    end
    pcall(function() if BallESP.rig then BallESP.rig:Destroy() end end)
    BallESP.rig, BallESP.beams, BallESP.atts = nil, {}, {}
    pcall(function() if BallESP.folder then BallESP.folder:Destroy() end end)
    BallESP.folder = nil
    BallESP.smoothLand, BallESP.ball, BallESP.gravity = nil, nil, nil
    BallESP.samples, BallESP.motion, BallESP.deepCache = {}, {}, {}
    BallESP.velFiltered, BallESP.shot, BallESP.visible = nil, nil, false
    BallESP.lastUpdate, BallESP.alpha = 0, 0
    BallESP.setStatus("off")
end

function BallESP.rescan()
    BallESP.ball, BallESP.deepT = nil, -10
    BallESP.samples, BallESP.motion, BallESP.deepCache = {}, {}, {}
    BallESP.setStatus("rescanning")
end

function BallESP.update()
    if not BallESP.enabled or ShijinUnloaded then return end
    local nowB = os.clock()
    if nowB - BallESP.lastUpdate < BALL_ESP_RATE then return end
    BallESP.lastUpdate = nowB

    local ball = BallESP.pick()
    if ball ~= BallESP.ball then
        BallESP.ball = ball
        BallESP.samples = {}
        BallESP.smoothLand = nil
        BallESP.velFiltered = nil
    end
    if not ball then
        BallESP.shot = nil
        BallESP.setStatus("no ball found")
        return
    end

    local vel = BallESP.sample(ball)

    local prevVel = BallESP.velFiltered
    if typeof(prevVel) == "Vector3" and prevVel.Magnitude > 1 and vel.Magnitude > 1 then
        local turn = prevVel.Unit:Dot(vel.Unit)
        local ratio = vel.Magnitude / prevVel.Magnitude
        if turn > 0.9 and ratio > 0.66 and ratio < 1.5 then
            vel = prevVel:Lerp(vel, 0.45)
        end
    end
    BallESP.velFiltered = vel

    local speed = vel.Magnitude
    if speed < math.max(tonumber(BallESP.minSpeed) or 2, 0.1) then
        BallESP.shot = nil
        BallESP.setStatus(string.format("ball idle (%.0f)", speed))
        return
    end

    local g = BallESP.effectiveGravity()
    local params = BallESP.rayParams()
    local floorY = BallESP.groundY(ball.Position, params)
    local t = BallESP.solve(ball.Position, vel, floorY, g)

    local landing, normal = nil, Vector3.new(0, 1, 0)
    if t then
        landing = Vector3.new(ball.Position.X + vel.X * t, floorY, ball.Position.Z + vel.Z * t)
        local snap = Workspace:Raycast(landing + Vector3.new(0, 6, 0), Vector3.new(0, -24, 0), params)
        if snap then
            landing = snap.Position
            normal = snap.Normal
        end
    end

    BallESP.shot = {
        t0 = nowB, pos = ball.Position, vel = vel, g = g,
        tEnd = t, landing = landing, normal = normal,
    }

    if t then
        BallESP.setStatus(string.format("tracking · lands in %.2fs", t))
    else
        BallESP.setStatus(string.format("tracking · no landing yet (%.0f studs/s)", speed))
    end

end

function BallESP.render(dt)
    if not BallESP.enabled or ShijinUnloaded then return end
    dt = math.clamp(dt or 1 / 60, 1 / 480, 0.1)
    local now = os.clock()
    local shot = BallESP.shot
    local fresh = (shot ~= nil) and (now - shot.t0) < 0.4

    BallESP.alpha = BallESP.alpha + ((fresh and 1 or 0) - BallESP.alpha) * (1 - math.exp(-16 * dt))
    if BallESP.alpha < 0.015 then
        if BallESP.visible then
            BallESP.hide()
            BallESP.visible = false
        end
        return
    end
    BallESP.visible = true
    if not shot then return end

    local g = shot.g
    local e = math.clamp(now - shot.t0, 0, shot.tEnd or 1.25)
    local pos = shot.pos + shot.vel * e - Vector3.new(0, 0.5 * g * e * e, 0)
    local vel = shot.vel - Vector3.new(0, g * e, 0)
    local remaining = shot.tEnd and math.max(shot.tEnd - e, 0) or 1.25

    if shot.landing then
        local prev = BallESP.smoothLand
        if prev and (prev - shot.landing).Magnitude < 30 then
            BallESP.smoothLand = prev:Lerp(shot.landing, 1 - math.exp(-20 * dt))
        else
            BallESP.smoothLand = shot.landing
        end
    end

    if remaining > 0.02 then
        if not BallESP.drawBeams(pos, vel, remaining, g, BallESP.alpha) then
            local pts = BallESP.samplePath(pos, vel, remaining, g)
            if BallESP.smoothLand then pts[#pts] = BallESP.smoothLand end
            BallESP.drawPath(pts, BallESP.alpha)
        end
    else
        BallESP.hideBeams()
        for _, seg in pairs(BallESP.segments) do
            if seg then seg.Transparency = 1 end
        end
    end

    if BallESP.smoothLand and shot.landing then
        BallESP.drawLanding(BallESP.smoothLand, shot.normal, BallESP.alpha)
    else
        BallESP.hideLanding()
    end
end

function BallESP.startRender()
    if BallESP.renderConn then return end
    BallESP.renderConn = RunService.RenderStepped:Connect(function(dt)
        local ok, err = pcall(BallESP.render, dt)
        if not ok then
            local nowR = os.clock()
            if nowR - BallESP.lastWarn > 3 then
                BallESP.lastWarn = nowR
                warn("[Shijin][Ball Trajectory] render: " .. tostring(err))
            end
        end
    end)
end

function BallESP.stopRender()
    if BallESP.renderConn then
        pcall(function() BallESP.renderConn:Disconnect() end)
        BallESP.renderConn = nil
    end
    BallESP.alpha, BallESP.visible, BallESP.shot = 0, false, nil
end

function BallESP.tick()
    local ok, err = pcall(BallESP.update)
    if ok then return end
    local nowE = os.clock()
    BallESP.setStatus("error: " .. tostring(err):sub(1, 60))
    if nowE - BallESP.lastWarn > 3 then
        BallESP.lastWarn = nowE
        warn("[Shijin][Ball Trajectory] " .. tostring(err))
    end
end

pcall(function()
    hubConn(Workspace.ChildAdded, function(child)
        local n = child.Name
        if type(n) == "string" and n:upper():find("BALL", 1, true) then
            BallESP.deepT = -10
        end
    end)
end)

local function updateESPFrame()
    local jumpOn, predOn = JumpESPEnabled, PredictAimEnabled
    for gonePlayer, esp in pairs(JumpESPObjects) do
        if not gonePlayer.Parent then
            pcall(function() if esp then esp:Destroy() end end)
            JumpESPObjects[gonePlayer] = nil
        end
    end
    for gonePlayer, stale in pairs(PredictAimObjects) do
        if not gonePlayer.Parent then
            pcall(function() if stale.Line then stale.Line:Destroy() end end)
            PredictAimObjects[gonePlayer] = nil
            enemyPartCache[gonePlayer] = nil
        end
    end
    for _, player in ipairs(Players:GetPlayers()) do
        pcall(function()
            if isEnemy(player) then
                local localRoot = LocalPlayer.Character and LocalPlayer.Character:FindFirstChild("HumanoidRootPart")
                local _, _, targetRoot = getEnemyParts(player)
                local inRange = not localRoot or not targetRoot
                    or (targetRoot.Position - localRoot.Position).Magnitude <= math.max(FeatureConfig.jumpEspMaxDistance, 20)
                if jumpOn and inRange then
                    if isJumping(player) then
                        local esp = JumpESPObjects[player]
                        if not esp or not esp.Parent then
                            createJumpESP(player)
                        elseif esp.FillColor ~= JumpESPColor or esp.FillTransparency ~= FeatureConfig.jumpEspFillTransparency
                            or esp.OutlineTransparency ~= FeatureConfig.jumpEspOutlineTransparency
                            or esp.DepthMode ~= (FeatureConfig.jumpEspAlwaysOnTop and Enum.HighlightDepthMode.AlwaysOnTop or Enum.HighlightDepthMode.Occluded) then
                            esp.FillColor = JumpESPColor
                            esp.OutlineColor = JumpESPColor
                            esp.FillTransparency = FeatureConfig.jumpEspFillTransparency
                            esp.OutlineTransparency = FeatureConfig.jumpEspOutlineTransparency
                            esp.DepthMode = FeatureConfig.jumpEspAlwaysOnTop and Enum.HighlightDepthMode.AlwaysOnTop or Enum.HighlightDepthMode.Occluded
                        end
                    else
                        removeJumpESP(player)
                    end
                end
            else
                if JumpESPObjects[player] then removeJumpESP(player) end
                enemyPartCache[player] = nil
            end
            if predOn then
                syncPredictLine(player)
            elseif PredictAimObjects[player] then
                removePredictLine(player)
            end
        end)
    end
    if not jumpOn and next(JumpESPObjects) ~= nil then clearAllJumpESP() end
    if not predOn and next(PredictAimObjects) ~= nil then clearAllPredictAim() end
    if predOn or next(PredictAimObjects) ~= nil then
        local nowSweep = os.clock()
        if nowSweep - VX.predT >= 0.5 then
            VX.predT = nowSweep
            local owned = VX.predOwned
            VX.clear(owned)
            for _, entry in pairs(PredictAimObjects) do
                if entry and entry.Line then owned[entry.Line] = true end
            end
            for _, obj in ipairs(Workspace:GetChildren()) do
                if obj.Name == "PredictLine" and not owned[obj] then
                    pcall(VX.destroy, obj)
                end
            end
        end
    end
end

local frameLink = nil
local function runFrameFeatures()
    if HitboxEnabled then
        local nowHb = os.clock()
        if nowHb - lastHitboxPass >= math.clamp(tonumber(FeatureConfig.hitboxUpdateRate) or 0.12, 0.03, 1) then
            lastHitboxPass = nowHb
            pcall(modifyBallHitbox)
        end
    end
    if JumpESPEnabled or PredictAimEnabled then
        pcall(updateESPFrame)
    end
    if BallESP.enabled then
        BallESP.tick()
    end
    if AutoCorner.enabled then
        pcall(AutoCorner.refresh)
    end
end
local function syncFrameLink()
    VX.use("frame", HitboxEnabled or BallESP.enabled or AutoCorner.enabled)
    local need = HitboxEnabled or JumpESPEnabled or PredictAimEnabled or BallESP.enabled
        or AutoCorner.enabled
    if need and not frameLink then
        frameLink = RunService.Heartbeat:Connect(runFrameFeatures)
    elseif not need and frameLink then
        frameLink:Disconnect()
        frameLink = nil
    end
end
syncFrameLink()

hubConn(Players.PlayerRemoving, function(player)
    pcall(function() restorePlayerName(player) end)
    removeJumpESP(player)
    removePredictLine(player)
    enemyPartCache[player] = nil
    modRankCache[player] = nil
    safeDisconnect(playerCharacterConns[player])
    playerCharacterConns[player] = nil
    local twc = teamWatchConns[player]
    if twc then
        teamWatchConns[player] = nil
        pcall(function() twc:Disconnect() end)
    end
end)

local AutoReceiveEnabled = false
local AutoReceiveMode = "Set"
local AutoReceiveMinSpeed = 25
local AutoReceiveCount = 0
local AutoReceiveStatusLabel = nil
local AutoReceiveInfoLabel = nil
local AutoReceiveConn = nil
local arTick

local ballCache, ballCacheT, ballScanConn, deepScanT = {}, -10, nil, -10
FeatureConfig.autoReceive = { net = nil, netT = -10, velocityConns = {}, reactionQueued = false }
function FeatureConfig.autoReceive.isFrontRow(root)
    if not root then return false end
    local state = FeatureConfig.autoReceive
    local now = os.clock()
    local net = state.net
    if not (net and net.Parent) and now - (state.netT or -10) >= 0.5 then
        state.netT = now
        local map = Workspace:FindFirstChild("Map")
        local collide = map and map:FindFirstChild("BallCollideOnly")
        state.net = collide and collide:FindFirstChild("Net") or nil
        net = state.net
    end
    return net and math.abs(root.Position.Z - net.Position.Z) <= 20 or false
end
local arFiredAt = {}
local arLastFire = 0
local arPingPeak = 0.05

local psState, psStateT, psInfoT = "", 0, 0
local psStateTxt, psInfoTxt = nil, nil

local function pushReceiveStatus(state, dist)
    local now = os.clock()
    if state == psState then
        if now - psStateT < 0.15 or now - psInfoT < 0.25 then return end
    else
        psState, psStateT = state, now
    end
    psInfoT = now
    local stateTxt = "State: " .. tostring(state)
    local d = (dist and dist >= 0) and string.format("%.1f", dist) or "--"
    local infoTxt = "Ball: " .. d .. "st  |  Received: " .. tostring(AutoReceiveCount)
    local stateNew = AutoReceiveStatusLabel ~= nil and stateTxt ~= psStateTxt
    local infoNew = AutoReceiveInfoLabel ~= nil and infoTxt ~= psInfoTxt
    if not stateNew and not infoNew then return end
    pcall(function()
        if stateNew then
            psStateTxt = stateTxt
            AutoReceiveStatusLabel:Set(stateTxt)
        end
        if infoNew then
            psInfoTxt = infoTxt
            AutoReceiveInfoLabel:Set(infoTxt)
        end
    end)
end

local function fireAutoReceive(move, holdDuration)
    if ShijinUnloaded then return false end
    local keyCode = move == "JumpSet" and KeyDetectorJumpSetKeyCode or KeyDetectorSetKeyCode
    local inputType = move == "JumpSet" and KeyDetectorSetInputType or KeyDetectorSetInputType
    if move == "JumpSet" then inputType = KeyDetectorJumpSetInputType end
    if not ((keyCode and keyCode ~= Enum.KeyCode.Unknown) or inputType) then return false end
    local ok, sent = pcall(pressDetectedMove, move, holdDuration)
    return ok and sent == true
end
local function scanBalls(root)
    local nowS = os.clock()
    if nowS - ballCacheT > 0.02 then
        ballCacheT = nowS
        local found = VX.scanFound
        VX.clear(found)
        local function consider(v)
            if ((v:IsA("Model") or v:IsA("BasePart")) and type(v.Name) == "string" and v.Name:upper():find("BALL", 1, true)) then
                found[v] = true
                local entry = ballCache[v]
                if not entry or not entry.p or not entry.p.Parent then
                    if entry and entry.vc then
                        safeDisconnect(entry.vc)
                        if entry.p then FeatureConfig.autoReceive.velocityConns[entry.p] = nil end
                    end
                    local part = (v:IsA("BasePart") and v) or v:FindFirstChildWhichIsA("BasePart")
                    if part and part.Name == "ExtendedHitbox" then
                        part = nil
                    end
                    if not part then
                        for _, d in ipairs(v:GetDescendants()) do
                            if d:IsA("BasePart") and d.Name ~= "ExtendedHitbox" then
                                part = d
                                break
                            end
                        end
                    end
                    if not part then part = v:FindFirstChildWhichIsA("BasePart") end
                    entry = { m = v, p = part }
                    ballCache[v] = entry
                    if part then
                        local ok, velocityConn = pcall(function()
                            return part:GetPropertyChangedSignal("AssemblyLinearVelocity"):Connect(function()
                                -- A player hit updates ball velocity before the next ordinary scan.
                                -- Queue one immediate receive pass instead of waiting for the next frame.
                                ballCacheT = -10
                                entry.spd = part.AssemblyLinearVelocity.Magnitude
                                local state = FeatureConfig.autoReceive
                                if AutoReceiveEnabled and not state.reactionQueued then
                                    state.reactionQueued = true
                                    task.defer(function()
                                        state.reactionQueued = false
                                        if arTick then pcall(arTick) end
                                    end)
                                end
                            end)
                        end)
                        if ok and velocityConn then
                            entry.vc = velocityConn
                            FeatureConfig.autoReceive.velocityConns[part] = velocityConn
                        end
                    end
                end
            end
        end
        for _, sv in ipairs(VX.list()) do consider(sv) end
        -- Deep discovery (throttled): balls nested in folders/models, any
        -- casing. The top-level scan above misses those entirely.
        if not next(found) and nowS - (deepScanT or -10) > 0.5 then
            deepScanT = nowS
            for _, dv in ipairs(Workspace:GetDescendants()) do consider(dv) end
        end
        for m, stale in pairs(ballCache) do
            if not found[m] then
                if stale.vc then safeDisconnect(stale.vc) end
                if stale.p then FeatureConfig.autoReceive.velocityConns[stale.p] = nil end
                ballCache[m] = nil
            end
        end
    end
    local list = {}
    for m, entry in pairs(ballCache) do
        local part = entry.p
        if m.Parent and part and part.Parent then
            local pos = part.Position
            entry.d = (pos - root.Position).Magnitude
            if entry.lt and nowS - entry.lt <= 1 then
                local sdt = nowS - entry.lt
                if sdt >= 0.03 then
                    entry.spd = math.max((pos - entry.lp).Magnitude / sdt, part.AssemblyLinearVelocity.Magnitude)
                    entry.lp, entry.lt = pos, nowS
                end
            else
                entry.lp, entry.lt = pos, nowS
                entry.spd = part.AssemblyLinearVelocity.Magnitude
            end
            list[#list + 1] = entry
        else
            if entry.vc then safeDisconnect(entry.vc) end
            if part then FeatureConfig.autoReceive.velocityConns[part] = nil end
            ballCache[m] = nil
        end
    end
    return list
end

arTick = function()
    if not AutoReceiveEnabled or ShijinUnloaded then return end
    local now = os.clock()
    for model in pairs(arFiredAt) do
        if not model.Parent then arFiredAt[model] = nil end
    end
    local char = LocalPlayer.Character
    if not char then
        pushReceiveStatus("No character")
        return
    end
    local rootPart = char:FindFirstChild("HumanoidRootPart")
    local humanoid = char:FindFirstChildOfClass("Humanoid")
    if not rootPart or not humanoid or humanoid.Health <= 0 then return end
    local frontRow = FeatureConfig.autoReceive.isFrontRow(rootPart)
    if isInLobbyCached() then
        pushReceiveStatus("Lobby")
        return
    end
    local arPingSeconds = 0.05
    pcall(function()
        local item = game:GetService("Stats").Network.ServerStatsItem["Data Ping"]
        if item then
            arPingSeconds = math.clamp((tonumber(item:GetValue()) or 50) / 1000, 0, 0.2)
        end
    end)
    -- Spike-tracking peak: reacts to ping spikes immediately, decays slowly,
    -- so public users on jittery connections stay covered.
    arPingPeak = math.max(arPingSeconds, (arPingPeak or 0.05) - 0.004)
    local arPingComp = math.max(arPingSeconds, arPingPeak)
    local balls = scanBalls(rootPart)
    if #balls == 0 then
        pushReceiveStatus("Seeking")
        return
    end
    local target, targetDistance, targetRange, targetScore, targetFast = nil, math.huge, 0, math.huge, false
    local targetEta, targetSpeed = math.huge, 0
    local slowDistance, farDistance, gated = math.huge, math.huge, false
    -- Trajectory horizon: how far ahead we forecast each ball (ping + margin).
    local arPredictT = math.min(arPingComp + 0.20, 0.50)
    local arGravity = 196.2
    pcall(function() arGravity = Workspace.Gravity end)
    for _, entry in ipairs(balls) do
        local velocity = entry.p.AssemblyLinearVelocity
        local speed = math.max(entry.spd or 0, velocity.Magnitude)
        local toPlayer = rootPart.Position - entry.p.Position
        local relativeVelocity = velocity - rootPart.AssemblyLinearVelocity
        local closing = toPlayer.Magnitude > 0.1 and relativeVelocity:Dot(toPlayer.Unit) or 0
        local relativeSpeedSq = relativeVelocity:Dot(relativeVelocity)
        local eta = relativeSpeedSq > 1 and math.clamp(toPlayer:Dot(relativeVelocity) / relativeSpeedSq, 0, 0.5) or math.huge
        local fastIncoming = speed >= 85 and closing >= 15 and eta <= 0.40
        if closing < -15 then
            if entry.d < farDistance then farDistance = entry.d end
        else
        -- Very fast tilted/dunk-style balls get an anticipatory response window.
        -- The normal local input is still used; this only prioritizes timing.
        -- Trajectory forecast: judge the ball where physics says it will be
        -- when the press lands (handles curve/dip, not just straight lines).
        local predPos = entry.p.Position + velocity * arPredictT
            + Vector3.new(0, -0.5 * arGravity * arPredictT * arPredictT, 0)
        local predD = (predPos - rootPart.Position).Magnitude
        entry.predPos = predPos
        local range = fastIncoming and (frontRow and math.clamp(46 + speed * 0.22, 42, 100)
            or math.clamp(40 + speed * 0.20, 36, 84))
            or (frontRow and math.clamp(36 + speed * 0.30, 34, 90)
                or math.clamp(30 + speed * 0.27, 28, 72))
        local last = arFiredAt[entry.m]
        local cooldown = fastIncoming
            and math.clamp(0.10 - math.clamp(speed / 300, 0, 1) * 0.05, 0.08, 0.15)
            or (frontRow
                and math.clamp(0.30 - math.clamp(speed / 250, 0, 1) * 0.10 + (entry.d / range) * 0.05, 0.25, 0.40)
                or math.clamp(0.35 - math.clamp(speed / 220, 0, 1) * 0.10 + (entry.d / range) * 0.05, 0.30, 0.45))
        if last and now - last.t < cooldown then
            gated = true
        elseif speed < AutoReceiveMinSpeed then
            if entry.d < slowDistance then slowDistance = entry.d end
        elseif predD > range then
            if entry.d < farDistance then farDistance = entry.d end
        else
            local approachBonus = math.clamp(closing / math.max(speed, 1), -1, 1) * (fastIncoming and 0.34 or (frontRow and 0.20 or 0.08))
            local timingBonus = fastIncoming and math.clamp((0.30 - eta) / 0.30, 0, 1) * 0.16 or 0
            local score = predD / range - approachBonus - timingBonus
            if score < targetScore or (score == targetScore and predD < targetDistance) then
                target, targetDistance, targetRange, targetScore, targetFast = entry, predD, range, score, fastIncoming
                targetEta, targetSpeed = eta, speed
            end
        end
        end
    end
    if not target then
        if slowDistance < math.huge then
            pushReceiveStatus("Waiting for ball speed", slowDistance)
        elseif farDistance < math.huge then
            pushReceiveStatus("Waiting for closer ball", farDistance)
        elseif gated then
            pushReceiveStatus("Cooldown...")
        else
            pushReceiveStatus("Seeking")
        end
        return
    end
    local globalGap = targetFast
        and math.clamp(0.01 + (targetDistance / targetRange) * 0.01, 0.01, 0.02)
        or (frontRow
            and math.clamp(0.025 + (targetDistance / targetRange) * 0.015, 0.025, 0.04)
            or math.clamp(0.025 + (targetDistance / targetRange) * 0.02, 0.025, 0.045))
    if now - arLastFire < globalGap then return end
    local state = humanoid:GetState()
    local airborne = state == Enum.HumanoidStateType.Jumping
        or state == Enum.HumanoidStateType.Freefall
        or humanoid.FloorMaterial == Enum.Material.Air
        or math.abs(rootPart.AssemblyLinearVelocity.Y) > 3
    local move
    if AutoReceiveMode == "Set" then
        move = "Set"
    elseif AutoReceiveMode == "JumpSet" then
        if not airborne then
            pushReceiveStatus("Waiting for air...", targetDistance)
            return
        end
        move = "JumpSet"
    else
        move = airborne and "JumpSet" or "Set"
    end
    local holdDuration = targetFast and math.clamp(targetEta + 0.12, 0.10, 0.25)
        or (frontRow and 0.09 or 0.06)
    -- Fire while arrival is inside the forecast window; the hold is sized to
    -- still be down at contact, and short cooldowns keep coverage across it.
    if targetFast and targetEta > 0.40 then return end
    -- Arrival gate: never spray presses at balls seconds away. Fire only when
    -- the press will still be down at contact (hold + reaction margin), unless
    -- the ball is already on top of us.
    if targetEta ~= math.huge and targetEta > holdDuration + 0.15 and targetDistance > 12 then
        pushReceiveStatus("Tracking ball...", targetDistance)
        return
    end
    arLastFire = now
    if fireAutoReceive(move, holdDuration) then
        arFiredAt[target.m] = { t = now }
        -- Step-in window follows the press: hold + margin, bounded so a slow
        -- ball costs little control and a fast ball gets the full run.
        local stepWindow = math.clamp(holdDuration + 0.05, 0.1, 0.3)
        do
            local hrp = char and char:FindFirstChild("HumanoidRootPart")
            if hrp and hrp.Parent and humanoid.Parent then
                local dest = target.predPos or target.p.Position
                dest = Vector3.new(dest.X, hrp.Position.Y, dest.Z)
                local t0 = os.clock()
                local stepConn
                stepConn = RunService.Heartbeat:Connect(function(dt)
                    local go = AutoReceiveEnabled and not ShijinUnloaded
                        and (os.clock() - t0) <= stepWindow
                        and humanoid.Parent and hrp.Parent and humanoid.Health > 0
                    if not go then
                        pcall(function() stepConn:Disconnect() end)
                        return
                    end
                    local to = dest - hrp.Position
                    to = Vector3.new(to.X, 0, to.Z)
                    if to.Magnitude < 0.5 then return end
                    local step = math.min(to.Magnitude, (humanoid.WalkSpeed or 16) * math.min(dt or 0.033, 0.1))
                    hrp.CFrame = hrp.CFrame + to.Unit * step
                end)
            end
        end
        AutoReceiveCount = AutoReceiveCount + 1
        local suffix = targetFast and " (Fast)" or (frontRow and " (Front)" or "")
        pushReceiveStatus("Pressed " .. move .. suffix, targetDistance)
    else
        pushReceiveStatus("Input unavailable", targetDistance)
    end
end
local function arResetState()
    arFiredAt = {}
    arLastFire = 0
    FeatureConfig.autoReceive.reactionQueued = false
    psStateTxt, psInfoTxt = nil, nil
    -- Keep live velocity listeners during an in-session reset so reaction
    -- tracking remains immediate; release them only while disabling/unloading.
    if not AutoReceiveEnabled then
        for part, conn in pairs(FeatureConfig.autoReceive.velocityConns) do
            safeDisconnect(conn)
            FeatureConfig.autoReceive.velocityConns[part] = nil
        end
        for _, entry in pairs(ballCache) do entry.vc = nil end
    end
    ballCacheT = -10
end

local function setAutoReceiveEnabled(state)
    AutoReceiveEnabled = state
    VX.use("receive", state)
    if state then
        arResetState()
        AutoReceiveCount = 0
        if not ballScanConn then
            ballScanConn = Workspace.ChildAdded:Connect(function(ch)
                if ch:IsA("Model") or ch:IsA("BasePart") then ballCacheT = -10 end
            end)
        end
        if AutoReceiveConn then
            pcall(function() AutoReceiveConn:Disconnect() end)
            AutoReceiveConn = nil
        end
        local receiveSignal = RunService.Heartbeat
        pcall(function()
            if RunService.PreSimulation then receiveSignal = RunService.PreSimulation end
        end)
        AutoReceiveConn = receiveSignal:Connect(function()
            pcall(arTick)
        end)
        task.defer(arTick)
        pushReceiveStatus("Tracking...", nil)
    else
        if AutoReceiveConn then
            pcall(function() AutoReceiveConn:Disconnect() end)
            AutoReceiveConn = nil
        end
        if ballScanConn then
            pcall(function() ballScanConn:Disconnect() end)
            ballScanConn = nil
        end
        ballCache = {}
        arResetState()
        pushReceiveStatus("OFF", nil)
    end
end

local charResetConn = LocalPlayer.CharacterAdded:Connect(function()
    arResetState()
end)

pcall(function()
    if getgenv then
        getgenv().ShijinAutoReceiveFire = function(move)
            local c = LocalPlayer.Character
            if not (c and c:FindFirstChild("HumanoidRootPart")) then return false end
            return fireAutoReceive(move or "Set")
        end
    end
end)

ShijinBuilding = true
local UI = {}
local Window = OrionLib:MakeWindow({
    Name = "◈ Shijin Hub",
    HidePremium = false,
    SaveConfig = true,
    ConfigFolder = "ShijinHub",
    IntroEnabled = false,
    IntroText = "◈ Shijin Hub",
    CloseCallback = function() pcall(ShijinCloseCallback) end,
})
UI.Window = Window

UI.Tabs = {
    Main = Window:MakeTab({ Name = "Main", Icon = "activity", PremiumOnly = false }),
    Rage = Window:MakeTab({ Name = "Combat", Icon = "flame", PremiumOnly = false }),
    Visuals = Window:MakeTab({ Name = "Visuals", Icon = "eye", PremiumOnly = false }),
    RestoreData = Window:MakeTab({ Name = "Data Rollback", Icon = "history", PremiumOnly = false }),
    Settings = Window:MakeTab({ Name = "Settings", Icon = "settings", PremiumOnly = false }),
}

UI.ReceiveFeatures = UI.Tabs.Main:AddSection({ Name = "Receive" })
UI.ServeFeatures = UI.Tabs.Main:AddSection({ Name = "Serve" })
UI.MoveFeatures = UI.Tabs.Main:AddSection({ Name = "Movement" })
UI.MainVisuals = UI.Tabs.Visuals:AddSection({ Name = "Visual Features" })
UI.RageFeatures = UI.Tabs.Rage:AddSection({ Name = "Ball Control" })
UI.RageTech = UI.Tabs.Rage:AddSection({ Name = "Spike Tech" })
UI.RestoreDataFeatures = UI.Tabs.RestoreData:AddSection({ Name = "Data Rollback" })
UI.SettingsInfo = UI.Tabs.Settings:AddSection({ Name = "Information" })
UI.SettingsKeys = UI.Tabs.Settings:AddSection({ Name = "Key Binds" })
UI.SettingsConfig = UI.Tabs.Settings:AddSection({ Name = "Configuration" })
UI.SettingsProtection = UI.Tabs.Settings:AddSection({ Name = "Protection" })
UI.SettingsPerformance = UI.Tabs.Settings:AddSection({ Name = "Performance" })
UI.SettingsActions = UI.Tabs.Settings:AddSection({ Name = "Hub Actions" })

UI.RageFeatures:AddToggle({
    Color = Color3.fromRGB(244, 63, 94),
    Name = "Ball Hitbox",
    Default = HitboxEnabled,
    Save = true,
    Flag = "HitboxToggle",
    Callback = function(Value)
        HitboxEnabled = Value
        syncFrameLink()
        if HitboxEnabled then notify("Hitbox Enabled")
        else removeHitboxes() notify("Hitbox Disabled") end
    end
})
UI.RageFeatures:AddSlider({
    Color = Color3.fromRGB(167, 139, 250),
    Name = "Hitbox Size",
    Default = 10,
    Min = 0,
    Max = 20,
    Increment = 1,
    ValueName = "studs",
    Save = true,
    Flag = "HitboxSize",
    Callback = function(Value) HitboxSize = Value end
})
UI.RageFeatures:AddColorpicker({
    Name = "Hitbox Color",
    Default = HitboxColor,
    Save = true,
    Flag = "HitboxColor",
    Callback = function(Value) HitboxColor = Value end
})
UI.RageFeatures:AddSlider({
    Color = Color3.fromRGB(167, 139, 250),
    Name = "Hitbox Transparency",
    Default = 80,
    Min = 40,
    Max = 95,
    Increment = 1,
    ValueName = "%",
    Save = true,
    Flag = "HitboxTransparency",
    Callback = function(Value) HitboxTransparency = Value / 100 end
})
UI.RageFeatures:AddSlider({
    Color = Color3.fromRGB(167, 139, 250),
    Name = "Hitbox Range",
    Default = FeatureConfig.hitboxMaxDistance,
    Min = 20,
    Max = 300,
    Increment = 1,
    ValueName = "studs",
    Save = true,
    Flag = "HitboxRange",
    Callback = function(Value) FeatureConfig.hitboxMaxDistance = Value end
})
UI.RageFeatures:AddSlider({
    Color = Color3.fromRGB(167, 139, 250),
    Name = "Hitbox Refresh",
    Default = FeatureConfig.hitboxUpdateRate,
    Min = 0.03,
    Max = 0.5,
    Increment = 0.01,
    ValueName = "s",
    Save = true,
    Flag = "HitboxUpdateRate",
    Callback = function(Value) FeatureConfig.hitboxUpdateRate = Value end
})
UI.RageFeatures:AddDropdown({
    Name = "Hitbox Material",
    Default = "ForceField",
    Options = {"ForceField", "Neon", "SmoothPlastic"},
    Save = true,
    Flag = "HitboxMaterial",
    Callback = function(Value) FeatureConfig.hitboxMaterial = FeatureConfig.hitboxMaterialByName[Value] or Enum.Material.ForceField end
})

UI.RageTech:AddToggle({
    Color = Color3.fromRGB(244, 63, 94),
    Name = "Auto Counter",
    Default = false,
    Save = true,
    Flag = "AutoSpikeToggle",
    Callback = function(Value)
        FeatureConfig.autoSpike.setEnabled(Value)
        notify(Value and "Auto Counter ON" or "Auto Counter OFF", 3)
    end
})
FeatureConfig.autoSpike.statusLabel = UI.RageTech:AddLabel("State: OFF")
UI.RageTech:AddBind({
    Name = "Auto Counter Key",
    Default = Enum.KeyCode.X,
    Hold = false,
    Save = true,
    Flag = "AutoSpikeKeybind",
    Callback = function()
        local t = OrionLib.Flags["AutoSpikeToggle"]
        if t then t:Set(not t.Value) end
    end
})
UI.RageTech:AddSlider({
    Color = Color3.fromRGB(167, 139, 250),
    Name = "Counter Range",
    Default = FeatureConfig.autoSpike.range,
    Min = 12,
    Max = 90,
    Increment = 1,
    ValueName = "studs",
    Save = true,
    Flag = "AutoSpikeRange",
    Callback = function(Value) FeatureConfig.autoSpike.range = Value end
})
UI.RageTech:AddBind({
    Name = "Spike Input Key",
    Default = Enum.UserInputType.MouseButton1,
    Hold = false,
    Save = true,
    Flag = "AutoSpikeInputKey",
    Callback = function() end
})
UI.RageTech:AddSlider({
    Color = Color3.fromRGB(167, 139, 250),
    Name = "Minimum Incoming Speed",
    Default = FeatureConfig.autoSpike.minIncomingSpeed,
    Min = 1,
    Max = 100,
    Increment = 1,
    ValueName = "studs/s",
    Save = true,
    Flag = "AutoSpikeIncomingSpeed",
    Callback = function(Value) FeatureConfig.autoSpike.minIncomingSpeed = Value end
})
UI.RageTech:AddParagraph("Counter Tech", "Activates for balls moving toward you while airborne, using your normal Spike input.")
UI.RageTech:AddButton({
    Name = "Reset Counter Session",
    Callback = function()
        FeatureConfig.autoSpike.reset()
        notify("Counter Spike session reset", 2)
    end
})

local RestoreDataBusy = false
local RestoreDataStatusLabel = nil

local function setRestoreDataStatus(text)
    pcall(function()
        if RestoreDataStatusLabel then
            RestoreDataStatusLabel:Set("Status: " .. tostring(text))
        end
    end)
end

UI.RestoreDataFeatures:AddParagraph("Data Rollback", "Sends the restore request, then reconnects you to the current game")
RestoreDataStatusLabel = UI.RestoreDataFeatures:AddLabel("Status: Ready")
UI.RestoreDataFeatures:AddButton({
    Name = "Restore and Reconnect",
    Callback = function()
        if RestoreDataBusy then
            notify("Restore Data is already in progress", 3)
            return
        end
        RestoreDataBusy = true
        setRestoreDataStatus("Finding restore service...")
        task.spawn(function()
            local ok, message = pcall(function()
                local services = findKnitServices()
                assert(services, "game services are unavailable")
                local settings = services:FindFirstChild("SettingsService")
                local rf = settings and settings:FindFirstChild("RF")
                local remote = rf and rf:FindFirstChild("UpdateKeybind")
                assert(remote and remote:IsA("RemoteFunction"), "restore service is unavailable")
                setRestoreDataStatus("Sending restore request...")
                remote:InvokeServer("MouseButton1", true, "Spike\xE2\x80\x8B\x8F")
                setRestoreDataStatus("Reconnecting...")
                task.wait(0.10)
                local teleported, teleportErr = pcall(function()
                    game:GetService("TeleportService"):Teleport(game.PlaceId, LocalPlayer)
                end)
                assert(teleported, "could not reconnect: " .. tostring(teleportErr))
                return "Restore request sent — reconnecting..."
            end)
            RestoreDataBusy = false
            if ok then
                setRestoreDataStatus(message)
                notify(message, 5)
            else
                local short = tostring(message):gsub("^.-:%d+: ", ""):sub(1, 90)
                setRestoreDataStatus("Failed — " .. short)
                notify("Restore Data failed: " .. short, 6)
            end
        end)
    end
})

UI.ReceiveFeatures:AddToggle({
    Color = Color3.fromRGB(244, 63, 94),
    Name = "Auto Receive",
    Default = false,
    Save = true,
    Flag = "AutoReceiveToggle",
    Callback = function(Value)
        setAutoReceiveEnabled(Value)
        notify(Value and "Auto Receive ON" or "Auto Receive OFF", 4)
    end
})
UI.ReceiveFeatures:AddBind({
    Name = "Bind",
    Default = Enum.KeyCode.G,
    Hold = false,
    Save = true,
    Flag = "AutoReceiveKeybind",
    Callback = function()
        local t = OrionLib.Flags["AutoReceiveToggle"]
        if t then t:Set(not t.Value) end
    end
})
AutoReceiveStatusLabel = UI.ReceiveFeatures:AddLabel("State: OFF")
AutoReceiveInfoLabel = UI.ReceiveFeatures:AddLabel("Ball: --st  |  Received: 0")
do
    KeyDetectorSetLabel = UI.ReceiveFeatures:AddLabel("Set Key: [Q]")
    local SetBind = UI.ReceiveFeatures:AddBind({
        Color = Color3.fromRGB(167, 139, 250),
        Name = "Receive Key",
        Default = Enum.KeyCode.Q,
        Hold = false,
        Save = true,
        Flag = "ManualSetKeyPicker",
        Callback = function() end
    })
    local origSet = SetBind.Set
    function SetBind:Set(Key)
        origSet(self, Key)
        pcall(function()
            local raw = SetBind.Value
            if type(raw) == "string" then
                local kc, it, disp = stringToKeyInput(raw)
                if disp and disp ~= "" and disp ~= "Unknown" and disp ~= "None" then
                    KeyDetectorSetKey = disp
                    if kc then KeyDetectorSetKeyCode = kc end
                    if it then KeyDetectorSetInputType = it end
                    updateKeyDetectorLabels()
                end
            end
        end)
    end
end
UI.ReceiveFeatures:AddSlider({
    Color = Color3.fromRGB(167, 139, 250),
    Name = "Ignore Ball Speeds Under",
    Default = AutoReceiveMinSpeed,
    Min = 0,
    Max = 150,
    Increment = 1,
    ValueName = "studs/s",
    Save = true,
    Flag = "AutoReceiveMinSpeedSlider",
    Callback = function(Value)
        AutoReceiveMinSpeed = Value
    end
})
UI.ReceiveFeatures:AddButton({
    Name = "Reset Receive Session",
    Callback = function()
        AutoReceiveCount = 0
        arResetState()
        pushReceiveStatus(AutoReceiveEnabled and "Tracking..." or "OFF")
        notify("Auto Receive session reset", 3)
    end
})
UI.ServeFeatures:AddToggle({
    Color = Color3.fromRGB(244, 63, 94),
    Name = "Always Max Power Serve",
    Default = AutoStrongServeEveryServeEnabled,
    Save = true,
    Flag = "AutoStrongServeEveryServeToggle",
    Callback = function(Value)
        AutoStrongServeEveryServeEnabled = Value
        notify(Value and "Always Max Power Serve Enabled" or "Always Max Power Serve Disabled")
    end
})

UI.ServeFeatures:AddToggle({
    Color = Color3.fromRGB(244, 63, 94),
    Name = "TSH Bar Lock",
    Default = false,
    Save = true,
    Flag = "TSHBarLockToggle",
    Callback = function(Value)
        TSHBarLock.setEnabled(Value)
        notify(Value and "TSH Bar Lock ON" or "TSH Bar Lock OFF", 5)
    end
})
UI.ServeFeatures:AddBind({
    Name = "TSH Bar Lock Key",
    Default = Enum.KeyCode.T,
    Hold = false,
    Save = true,
    Flag = "TSHBarLockKeybind",
    Callback = function()
        local t = OrionLib.Flags["TSHBarLockToggle"]
        if t then t:Set(not t.Value) end
    end
})
UI.ServeFeatures:AddToggle({
    Color = Color3.fromRGB(244, 63, 94),
    Name = "Require Run-Up Before Full Bar",
    Default = TSHBarLock.requireRunup,
    Save = true,
    Flag = "TSHRunupGate",
    Callback = function(Value)
        TSHBarLock.requireRunup = Value
        TSHBarLock.updateRunupGate(TSHBarLock.rawCharge)
    end
})
UI.ServeFeatures:AddSlider({
    Color = Color3.fromRGB(167, 139, 250),
    Name = "Minimum Run-Up",
    Default = math.floor(TSHBarLock.minimumRunup * 100),
    Min = 0,
    Max = 100,
    Increment = 1,
    ValueName = "%",
    Save = true,
    Flag = "TSHRunupMinimum",
    Callback = function(Value)
        TSHBarLock.minimumRunup = math.clamp((tonumber(Value) or 0) / 100, 0, 1)
        TSHBarLock.updateRunupGate(TSHBarLock.rawCharge)
    end
})

UI.MoveFeatures:AddToggle({
    Color = Color3.fromRGB(244, 63, 94),
    Name = "Auto Shiftlock",
    Default = CameraJumpEnabled,
    Save = true,
    Flag = "CameraJumpToggle",
    Callback = function(Value)
        CameraJumpEnabled = Value
        notify(Value and "Auto Shiftlock Enabled" or "Auto Shiftlock Disabled")
    end
})

UI.MainVisuals:AddToggle({
    Color = Color3.fromRGB(244, 63, 94),
    Name = "Aim Predictor",
    Default = PredictAimEnabled,
    Save = true,
    Flag = "PredictAimToggle",
    Callback = function(Value)
        PredictAimEnabled = Value
        syncFrameLink()
        if PredictAimEnabled then notify("Aim Predictor Enabled")
        else clearAllPredictAim() notify("Aim Predictor Disabled") end
    end
})
UI.MainVisuals:AddSlider({
    Color = Color3.fromRGB(167, 139, 250),
    Name = "Prediction Length",
    Default = PredictAimLength,
    Min = 0,
    Max = 50,
    Increment = 1,
    ValueName = "studs",
    Save = true,
    Flag = "PredictAimLength",
    Callback = function(Value) PredictAimLength = Value end
})
UI.MainVisuals:AddColorpicker({
    Name = "Aim Predictor Color",
    Default = PredictAimColor,
    Save = true,
    Flag = "PredictAimColor",
    Callback = function(Value) PredictAimColor = Value end
})
UI.MainVisuals:AddSlider({
    Color = Color3.fromRGB(167, 139, 250),
    Name = "Prediction Thickness",
    Default = FeatureConfig.predictAimThickness,
    Min = 0.05,
    Max = 1,
    Increment = 0.01,
    Save = true,
    Flag = "PredictAimThickness",
    Callback = function(Value) FeatureConfig.predictAimThickness = Value end
})
UI.MainVisuals:AddSlider({
    Color = Color3.fromRGB(167, 139, 250),
    Name = "Prediction Transparency",
    Default = FeatureConfig.predictAimTransparency,
    Min = 0,
    Max = 1,
    Increment = 0.01,
    Save = true,
    Flag = "PredictAimTransparency",
    Callback = function(Value) FeatureConfig.predictAimTransparency = Value end
})
UI.MainVisuals:AddSlider({
    Color = Color3.fromRGB(167, 139, 250),
    Name = "Prediction Range",
    Default = FeatureConfig.predictAimMaxDistance,
    Min = 50,
    Max = 1000,
    Increment = 1,
    ValueName = "studs",
    Save = true,
    Flag = "PredictAimRange",
    Callback = function(Value) FeatureConfig.predictAimMaxDistance = Value end
})

UI.MainVisuals:AddToggle({
    Color = Color3.fromRGB(244, 63, 94),
    Name = "Ball Trajectory",
    Default = false,
    Save = true,
    Flag = "BallESPToggle",
    Callback = function(Value)
        BallESP.enabled = Value
        syncFrameLink()
        if Value then
            BallESP.rescan()
            BallESP.startRender()
            notify("Ball Trajectory Enabled")
        else
            BallESP.stopRender()
            BallESP.clear()
            notify("Ball Trajectory Disabled")
        end
    end
})
BallESP.statusLabel = UI.MainVisuals:AddLabel("State: off")
UI.MainVisuals:AddColorpicker({
    Name = "Ball Path Color",
    Default = BallESP.lineColor,
    Save = true,
    Flag = "BallESPLineColor",
    Callback = function(Value) BallESP.lineColor = Value end
})
UI.MainVisuals:AddColorpicker({
    Name = "Landing Circle Color",
    Default = BallESP.landColor,
    Save = true,
    Flag = "BallESPLandColor",
    Callback = function(Value) BallESP.landColor = Value end
})
UI.MainVisuals:AddSlider({
    Color = Color3.fromRGB(167, 139, 250),
    Name = "Path Transparency",
    Default = 0.55,
    Min = 0,
    Max = 0.95,
    Increment = 0.01,
    Save = true,
    Flag = "BallESPTransparency",
    Callback = function(Value) BallESP.transparency = Value end
})
UI.MainVisuals:AddSlider({
    Color = Color3.fromRGB(167, 139, 250),
    Name = "Landing Circle Size",
    Default = 7,
    Min = 2,
    Max = 20,
    Increment = 1,
    ValueName = "studs",
    Save = true,
    Flag = "BallESPCircleSize",
    Callback = function(Value) BallESP.circleSize = Value end
})
UI.MainVisuals:AddSlider({
    Color = Color3.fromRGB(167, 139, 250),
    Name = "Gravity Tune",
    Default = 1,
    Min = 0.5,
    Max = 2,
    Increment = 0.01,
    Save = true,
    Flag = "BallESPGravity",
    Callback = function(Value) BallESP.gravityScale = Value end
})
UI.MainVisuals:AddDropdown({
    Name = "Ball ESP Quality",
    Default = "Balanced",
    Options = {"Low", "Balanced", "High"},
    Save = true,
    Flag = "BallESPQuality",
    Callback = function(Value) BallESP.setQuality(Value) end
})
UI.MainVisuals:AddToggle({
    Color = Color3.fromRGB(244, 63, 94),
    Name = "Use Beam Path",
    Default = BallESP.useBeams,
    Save = true,
    Flag = "BallESPBeams",
    Callback = function(Value)
        BallESP.useBeams = Value
        if not Value then BallESP.hideBeams() end
    end
})
UI.MainVisuals:AddSlider({
    Color = Color3.fromRGB(167, 139, 250),
    Name = "Ball Minimum Speed",
    Default = BallESP.minSpeed,
    Min = 0,
    Max = 100,
    Increment = 1,
    ValueName = "studs/s",
    Save = true,
    Flag = "BallESPMinSpeed",
    Callback = function(Value) BallESP.minSpeed = Value end
})
UI.MainVisuals:AddSlider({
    Color = Color3.fromRGB(167, 139, 250),
    Name = "Ball ESP Range",
    Default = BallESP.maxDistance,
    Min = 50,
    Max = 1000,
    Increment = 1,
    ValueName = "studs",
    Save = true,
    Flag = "BallESPRange",
    Callback = function(Value) BallESP.maxDistance = Value end
})
UI.MainVisuals:AddSlider({
    Color = Color3.fromRGB(167, 139, 250),
    Name = "Trajectory Maximum Time",
    Default = BALL_ESP_MAX_T,
    Min = 1,
    Max = 8,
    Increment = 0.1,
    ValueName = "s",
    Save = true,
    Flag = "BallESPMaxTime",
    Callback = function(Value) BALL_ESP_MAX_T = Value end
})
UI.MainVisuals:AddToggle({
    Color = Color3.fromRGB(244, 63, 94),
    Name = "Ghost Mode",
    Default = false,
    Save = true,
    Flag = "StreamerModeToggle",
    Callback = function(Value)
        StreamerModeEnabled = Value
        if Value then applyStreamerMode() startStreamerLoop() notify("Ghost Mode ON", 4)
        else disableStreamerMode() notify("Ghost Mode OFF", 3) end
    end
})
UI.MainVisuals:AddToggle({
    Color = Color3.fromRGB(244, 63, 94),
    Name = "Hide Local Name",
    Default = FeatureConfig.streamerHideSelf,
    Save = true,
    Flag = "StreamerHideSelf",
    Callback = function(Value)
        FeatureConfig.streamerHideSelf = Value
        if StreamerModeEnabled then
            if Value then hidePlayerName(LocalPlayer) else restorePlayerName(LocalPlayer) end
        end
    end
})
UI.MainVisuals:AddSlider({
    Color = Color3.fromRGB(167, 139, 250),
    Name = "Ghost Refresh Rate",
    Default = FeatureConfig.streamerRefreshRate,
    Min = 0.5,
    Max = 10,
    Increment = 0.1,
    ValueName = "s",
    Save = true,
    Flag = "StreamerRefresh",
    Callback = function(Value) FeatureConfig.streamerRefreshRate = Value end
})

UI.MainVisuals:AddToggle({
    Color = Color3.fromRGB(244, 63, 94),
    Name = "Jump Tracker",
    Default = JumpESPEnabled,
    Save = true,
    Flag = "JumpESPToggle",
    Callback = function(Value)
        JumpESPEnabled = Value
        syncFrameLink()
        if JumpESPEnabled then notify("Jump Tracker Enabled")
        else clearAllJumpESP() notify("Jump Tracker Disabled") end
    end
})
UI.MainVisuals:AddColorpicker({
    Name = "Jump Tracker Color",
    Default = JumpESPColor,
    Save = true,
    Flag = "JumpESPColor",
    Callback = function(Value) JumpESPColor = Value end
})
UI.MainVisuals:AddSlider({
    Color = Color3.fromRGB(167, 139, 250),
    Name = "Jump Tracker Fill Transparency",
    Default = FeatureConfig.jumpEspFillTransparency,
    Min = 0,
    Max = 1,
    Increment = 0.01,
    Save = true,
    Flag = "JumpESPFill",
    Callback = function(Value) FeatureConfig.jumpEspFillTransparency = Value end
})
UI.MainVisuals:AddSlider({
    Color = Color3.fromRGB(167, 139, 250),
    Name = "Jump Tracker Outline Transparency",
    Default = FeatureConfig.jumpEspOutlineTransparency,
    Min = 0,
    Max = 1,
    Increment = 0.01,
    Save = true,
    Flag = "JumpESPOutline",
    Callback = function(Value) FeatureConfig.jumpEspOutlineTransparency = Value end
})
UI.MainVisuals:AddSlider({
    Color = Color3.fromRGB(167, 139, 250),
    Name = "Jump Tracker Range",
    Default = FeatureConfig.jumpEspMaxDistance,
    Min = 50,
    Max = 1000,
    Increment = 1,
    ValueName = "studs",
    Save = true,
    Flag = "JumpESPRange",
    Callback = function(Value) FeatureConfig.jumpEspMaxDistance = Value end
})
UI.MainVisuals:AddToggle({
    Color = Color3.fromRGB(244, 63, 94),
    Name = "Jump Tracker Through Walls",
    Default = FeatureConfig.jumpEspAlwaysOnTop,
    Save = true,
    Flag = "JumpESPDepth",
    Callback = function(Value) FeatureConfig.jumpEspAlwaysOnTop = Value end
})

UI.SettingsPerformance:AddParagraph("Performance Mode", "Reduces render effects client-side. Original values are restored when disabled.")
FeatureConfig.performanceMode.statusLabel = UI.SettingsPerformance:AddLabel("State: OFF")
UI.SettingsPerformance:AddToggle({
    Color = Color3.fromRGB(244, 63, 94),
    Name = "Performance Mode",
    Default = false,
    Save = true,
    Flag = "PerformanceModeToggle",
    Callback = function(Value)
        FeatureConfig.performanceMode.setEnabled(Value)
        notify(Value and "Performance Mode ON" or "Performance Mode OFF", 3)
    end
})
UI.SettingsPerformance:AddDropdown({
    Name = "Reduction Level",
    Default = FeatureConfig.performanceLevel,
    Options = { "Light", "Balanced", "Maximum" },
    Save = true,
    Flag = "PerformanceModeLevel",
    Callback = function(Value)
        FeatureConfig.performanceMode.setLevel(Value)
    end
})
UI.SettingsPerformance:AddButton({
    Name = "Refresh Performance Mode",
    Callback = function()
        if FeatureConfig.performanceMode.enabled then
            scanPerformanceMode()
            notify("Performance scan refreshed", 2)
        else
            notify("Enable Performance Mode first", 3)
        end
    end
})

UI.SettingsProtection:AddToggle({
    Color = Color3.fromRGB(244, 63, 94),
    Name = "Anti-Moderator Protection",
    Default = AntiModEnabled,
    Save = true,
    Flag = "AntiModToggle",
    Callback = function(Value)
        AntiModEnabled = Value
        if AntiModEnabled then notify("Anti-Mod Enabled") checkForModerators()
        else notify("Anti-Mod Disabled") end
    end
})
UI.SettingsProtection:AddToggle({
    Color = Color3.fromRGB(244, 63, 94),
    Name = "Feature Notifications",
    Default = FeatureConfig.notifications,
    Save = true,
    Flag = "NotificationsToggle",
    Callback = function(Value) FeatureConfig.notifications = Value end
})
UI.SettingsProtection:AddSlider({
    Color = Color3.fromRGB(167, 139, 250),
    Name = "Notification Duration",
    Default = FeatureConfig.notificationLifetime,
    Min = 1,
    Max = 15,
    Increment = 1,
    ValueName = "s",
    Save = true,
    Flag = "NotificationLifetime",
    Callback = function(Value) FeatureConfig.notificationLifetime = Value end
})

pcall(function()
    UI.SettingsKeys:AddButton({
        Name = "Reset Set Key (Q)",
        Callback = function()
            pcall(function() OrionLib.Flags["ManualSetKeyPicker"]:Set(Enum.KeyCode.Q) end)
            KeyDetectorSetKey = "Q"
            KeyDetectorSetKeyCode = Enum.KeyCode.Q
            KeyDetectorSetInputType = Enum.UserInputType.Keyboard
            updateKeyDetectorLabels()
            notify("Set key reset to [Q]", 4)
        end
    })
    UI.SettingsKeys:AddBind({
        Name = "Menu Bind",
        Default = Enum.KeyCode.RightShift,
        Hold = false,
        Flag = "MenuKeybind",
        Callback = function()
            pcall(function()
                local hui = (gethui and gethui()) or game:GetService("CoreGui")
                local gui = hui and hui:FindFirstChild("Orion")
                if gui then gui.Enabled = not gui.Enabled end
            end)
        end
    })
    updateKeyDetectorLabels()
end)

UI.SettingsInfo:AddLabel(ScriptName .. " v" .. ScriptVersion)
UI.SettingsInfo:AddLabel("UI Library: Orion")

local HubDiagnostics = { sessionLabel = nil }

HubDiagnostics.report = function()
    local mode = "Unknown"
    pcall(function()
        if isInLobbyCached and isInLobbyCached() then mode = "Lobby" else mode = "Match" end
    end)
    local ping = "--"
    pcall(function()
        local item = game:GetService("Stats").Network.ServerStatsItem["Data Ping"]
        if item then ping = tostring(math.floor(tonumber(item:GetValue()) or 0)) .. " ms" end
    end)
    local keyState = "Keyless"
    pcall(function()
        local info = getgenv and getgenv().ShijinKeyInfo
        if type(info) == "table" then
            local expiry = tonumber(info.expiry)
            keyState = tostring(info.type or "Script Key")
            if expiry then keyState = keyState .. " • expires " .. os.date("!%Y-%m-%d %H:%M UTC", expiry) end
        end
    end)
    return table.concat({
        "Shijin Hub v" .. tostring(ScriptVersion),
        "Session: " .. mode .. " | Players: " .. tostring(#Players:GetPlayers()) .. " | Ping: " .. ping,
        "Access: " .. keyState,
    }, "\n")
end

HubDiagnostics.refresh = function()
    local lines = string.split(HubDiagnostics.report(), "\n")
    pcall(function()
        if HubDiagnostics.sessionLabel then HubDiagnostics.sessionLabel:Set(lines[2] or "Session: --") end
    end)
end

UI.SettingsInfo:AddLabel("System Diagnostics")
HubDiagnostics.sessionLabel = UI.SettingsInfo:AddLabel("Session: loading...")
UI.SettingsInfo:AddButton({
    Name = "Refresh Diagnostics",
    Callback = function()
        HubDiagnostics.refresh()
        notify("Diagnostics refreshed", 2)
    end
})
UI.SettingsInfo:AddButton({
    Name = "Copy Support Report",
    Callback = function()
        if type(setclipboard) ~= "function" then
            notify("Clipboard support is unavailable in this executor", 4)
            return
        end
        local ok = pcall(setclipboard, HubDiagnostics.report())
        notify(ok and "Support report copied" or "Could not copy support report", 3)
    end
})
HubDiagnostics.refresh()

-- Named config slots on top of Orion Flags (Orion core only auto-saves the
-- per-game file; slots are our own JSON files next to it). All file access
-- is pcall-guarded so executors without a filesystem degrade to notify.
local OrionSlotService = game:GetService("HttpService")
local function orionSlotsUsable()
    return type(writefile) == "function" and type(readfile) == "function"
        and type(listfiles) == "function" and type(isfile) == "function"
        and type(delfile) == "function"
end
local function orionCleanSlotName(name)
    name = tostring(name or ""):gsub("^%s+", ""):gsub("%s+$", "")
    name = name:gsub("[/\\%.]", "")
    if #name > 40 then name = name:sub(1, 40) end
    return name
end
local function orionSlotPath(name)
    return "ShijinHub/slot_" .. name .. ".json"
end
local function orionListSlots()
    local names = {}
    pcall(function()
        for _, f in ipairs(listfiles("ShijinHub")) do
            local n = tostring(f):match("slot_(.+)%.json$")
            if n then names[#names + 1] = n end
        end
    end)
    table.sort(names)
    return names
end
local function orionPackFlags()
    local data = {}
    for flag, obj in pairs(OrionLib.Flags) do
        if type(obj) == "table" and obj.Save then
            local v = obj.Value
            if obj.Type == "Colorpicker" and typeof(v) == "Color3" then
                data[flag] = {
                    R = math.floor(v.R * 255 + 0.5),
                    G = math.floor(v.G * 255 + 0.5),
                    B = math.floor(v.B * 255 + 0.5),
                }
            else
                data[flag] = v
            end
        end
    end
    return data
end
local function orionApplyFlags(data)
    if type(data) ~= "table" then return false end
    for flag, v in pairs(data) do
        local obj = OrionLib.Flags[flag]
        if type(obj) == "table" and type(obj.Set) == "function" then
            pcall(function()
                if obj.Type == "Colorpicker" and type(v) == "table" then
                    obj:Set(Color3.fromRGB(tonumber(v.R) or 255, tonumber(v.G) or 255, tonumber(v.B) or 255))
                else
                    obj:Set(v)
                end
            end)
        end
    end
    return true
end
local function orionEnsureFolder()
    if not orionSlotsUsable() then return false end
    pcall(function()
        if not isfile("ShijinHub") then makefolder("ShijinHub") end
    end)
    return true
end
local function orionSaveSlot(name)
    name = orionCleanSlotName(name)
    if name == "" or not orionSlotsUsable() then return false end
    orionEnsureFolder()
    local ok = pcall(function()
        writefile(orionSlotPath(name), OrionSlotService:JSONEncode(orionPackFlags()))
    end)
    return ok
end
local function orionLoadSlot(name)
    name = orionCleanSlotName(name)
    if name == "" or not orionSlotsUsable() then return false end
    local body = nil
    pcall(function()
        if isfile(orionSlotPath(name)) then body = readfile(orionSlotPath(name)) end
    end)
    if type(body) ~= "string" or body == "" then return false end
    local data = nil
    pcall(function() data = OrionSlotService:JSONDecode(body) end)
    -- Quiet apply: restored flags must not each fire their own popup.
    local wasBuilding = ShijinBuilding
    ShijinBuilding = true
    local applied = orionApplyFlags(data)
    ShijinBuilding = wasBuilding
    return applied
end
local function orionDeleteSlot(name)
    name = orionCleanSlotName(name)
    if name == "" or not orionSlotsUsable() then return false end
    local ok = pcall(function()
        if isfile(orionSlotPath(name)) then delfile(orionSlotPath(name)) end
    end)
    return ok
end
local function orionRefreshSlotList()
    local names = orionListSlots()
    pcall(function()
        local dd = OrionLib.Flags["ConfigList"]
        if dd and type(dd.Refresh) == "function" then dd:Refresh(names) end
    end)
    return names
end

local uxoConfigName = ""
UI.SettingsConfig:AddTextbox({
    Name = "Config name",
    Default = "",
    TextDisappear = false,
    Callback = function(Value)
        uxoConfigName = tostring(Value or "")
    end
})
local ConfigListSelected = nil
UI.SettingsConfig:AddDropdown({
    Name = "Saved configs",
    Default = "...",
    Options = orionListSlots(),
    Save = false,
    Flag = "ConfigList",
    Callback = function(Value)
        ConfigListSelected = (Value ~= "...") and Value or nil
    end
})
local orionActiveSlot = nil
local orionAutosaveOn = false
local orionLastSlotJson = nil
local ConfigActiveLabel = UI.SettingsConfig:AddLabel("Active slot: none")
local function orionSnapshotActive()
    pcall(function()
        orionLastSlotJson = OrionSlotService:JSONEncode(orionPackFlags())
    end)
end
local function orionSetActive(name)
    orionActiveSlot = name
    pcall(function()
        ConfigActiveLabel:Set("Active slot: " .. (name or "none"))
    end)
    orionSnapshotActive()
end
UI.SettingsConfig:AddButton({
    Name = "Create config",
    Callback = function()
        local name = orionCleanSlotName(uxoConfigName)
        if name == "" then return notify("Type a config name first", 4, true) end
        if not orionSaveSlot(name) then return notify("Could not save config " .. name, 4, true) end
        orionRefreshSlotList()
        pcall(function() OrionLib.Flags["ConfigList"]:Set(name) end)
        ConfigListSelected = name
        orionSetActive(name)
        notify("Saved config " .. name, 4, true)
    end
})
UI.SettingsConfig:AddButton({
    Name = "Save slot",
    Callback = function()
        local name = orionCleanSlotName(ConfigListSelected or orionActiveSlot)
        if name == "" then return notify("Select a config first", 4, true) end
        if orionSaveSlot(name) then
            orionSetActive(name)
            notify("Saved " .. name, 3, true)
        else notify("Could not save " .. name, 4, true) end
    end
})
UI.SettingsConfig:AddButton({
    Name = "Load config",
    Callback = function()
        local name = orionCleanSlotName(ConfigListSelected)
        if name == "" then return notify("Select a config to load", 4, true) end
        if orionLoadSlot(name) then
            orionSetActive(name)
            notify("Loaded config " .. name, 4, true)
        else notify("Could not load config " .. name, 4, true) end
    end
})
UI.SettingsConfig:AddButton({
    Name = "Delete config",
    Callback = function()
        local name = orionCleanSlotName(ConfigListSelected)
        if name == "" then return notify("Select a config to delete", 4, true) end
        if not orionDeleteSlot(name) then return notify("Could not delete config " .. name, 4, true) end
        orionRefreshSlotList()
        ConfigListSelected = nil
        if orionActiveSlot == name then orionSetActive(nil) end
        notify("Deleted config " .. name, 4, true)
    end
})
UI.SettingsConfig:AddToggle({
    Name = "Autosave active slot",
    Default = false,
    Save = false,
    Flag = "ConfigAutosave",
    Callback = function(Value)
        orionAutosaveOn = Value == true
        if Value then
            orionSnapshotActive()
            notify("Autosave on" .. (orionActiveSlot and (" for " .. orionActiveSlot) or ""), 3, true)
        else
            notify("Autosave off", 3, true)
        end
    end
})
local ConfigAutoloadLabel = UI.SettingsConfig:AddLabel("Autoload: none")
pcall(function()
    if orionSlotsUsable() and isfile("ShijinHub/autoload.txt") then
        local n = orionCleanSlotName(readfile("ShijinHub/autoload.txt"))
        if n ~= "" then ConfigAutoloadLabel:Set("Autoload: " .. n) end
    end
end)
UI.SettingsConfig:AddButton({
    Name = "Set as autoload",
    Callback = function()
        local name = orionCleanSlotName(ConfigListSelected)
        if name == "" then return notify("Select a config first", 4, true) end
        orionEnsureFolder()
        local ok = orionSlotsUsable() and pcall(writefile, "ShijinHub/autoload.txt", name)
        if not ok then return notify("Could not set autoload", 4, true) end
        ConfigAutoloadLabel:Set("Autoload: " .. name)
        notify("Autoload set to " .. name, 4, true)
    end
})
UI.SettingsConfig:AddButton({
    Name = "Clear autoload",
    Callback = function()
        pcall(function() if isfile("ShijinHub/autoload.txt") then delfile("ShijinHub/autoload.txt") end end)
        ConfigAutoloadLabel:Set("Autoload: none")
        notify("Autoload cleared", 4, true)
    end
})

-- Smart autosave: every 5s, persist the active slot only if flags changed.
task.spawn(function()
    while not ShijinUnloaded do
        task.wait(5)
        if orionAutosaveOn and orionActiveSlot and not ShijinUnloaded then
            pcall(function()
                local json = OrionSlotService:JSONEncode(orionPackFlags())
                if json ~= orionLastSlotJson then
                    if orionSaveSlot(orionActiveSlot) then
                        orionLastSlotJson = json
                    end
                end
            end)
        end
    end
end)

local function shijinFullCleanup()
    if ShijinUnloaded then return end
    ShijinUnloaded = true
    FeatureConfig.autoSpinRunId = FeatureConfig.autoSpinRunId + 1
    cameraTurnToken = cameraTurnToken + 1
    pcall(function() if getgenv then getgenv().ShijinHubLoaded = false end end)
    for _, conn in ipairs(HubConns) do
        pcall(function() conn:Disconnect() end)
    end
    pcall(function() AutoCorner.uninstallAim() end)
    safeDisconnect(AutoCorner.jumpConn)
    AutoCorner.jumpConn = nil
    for i = #CameraJumpConns, 1, -1 do
        safeDisconnect(CameraJumpConns[i])
        CameraJumpConns[i] = nil
    end
    pcall(uninstallAutoSpinWatch)
    pcall(function()
        if getgenv then
            getgenv().ShijinHubLibrary = nil
            getgenv().ShijinHubNotify = nil
            getgenv().ShijinDetectedKeys = nil
            getgenv().ShijinGetSetKey = nil
            getgenv().ShijinGetJumpSetKey = nil
            getgenv().ShijinPressSet = nil
            getgenv().ShijinPressJumpSet = nil
            getgenv().ShijinAutoReceiveFire = nil
        end
    end)
    HitboxEnabled = false
    pcall(removeHitboxes)
    JumpESPEnabled = false
    pcall(clearAllJumpESP)
    PredictAimEnabled = false
    pcall(clearAllPredictAim)
    BallESP.enabled = false
    pcall(BallESP.stopRender)
    pcall(BallESP.clear)
    pcall(function()
        if localTeamWatchConn then localTeamWatchConn:Disconnect() localTeamWatchConn = nil end
        for twPlayer, twConn in pairs(teamWatchConns) do
            twConn:Disconnect()
            teamWatchConns[twPlayer] = nil
        end
    end)
    pcall(function() if frameLink then frameLink:Disconnect() frameLink = nil end end)
    pcall(function() FeatureConfig.autoSpike.setEnabled(false) end)
    pcall(VX.stop)
    pcall(function() FeatureConfig.performanceMode.setEnabled(false) end)
    SpeedEnabled = false
    speedChar, speedHum, speedRoot = nil, nil, nil
    DirectionalHitEnabled = false
    CameraJumpEnabled = false
    pcall(function()
        local ch = LocalPlayer.Character
        local hum = ch and ch:FindFirstChildOfClass("Humanoid")
        if hum then hum.AutoRotate = true end
    end)
    AutoStrongServeEveryServeEnabled = false
    AntiModEnabled = false
    StreamerModeEnabled = false
    AutoSpinEnabled = false
    JumpBoostEnabled = false
    pcall(function() restoreJumpBoost() end)
    pcall(function() if JumpBoostConn then JumpBoostConn:Disconnect() JumpBoostConn = nil end end)
    JumpBoostLastApply = 0
    AutoReceiveEnabled = false
    pcall(function() if AutoReceiveConn then AutoReceiveConn:Disconnect() AutoReceiveConn = nil end end)
    pcall(function() if ballScanConn then ballScanConn:Disconnect() ballScanConn = nil end end)
    pcall(function() if charResetConn then charResetConn:Disconnect() charResetConn = nil end end)
    AutoCorner.enabled = false
    pcall(function() TSHBarLock.setEnabled(false) end)
    pcall(function() RoninLock.setEnabled(false) end)
    pcall(function() KazanaCharge.setEnabled(false) end)
    pcall(disableStreamerMode)
    for player, conn in pairs(playerCharacterConns) do
        safeDisconnect(conn)
        playerCharacterConns[player] = nil
    end
end

ShijinCloseCallback = function()
    pcall(shijinFullCleanup)
    warn("Shijin Hub unloaded")
end

local UnloadBtn = nil
local UnloadingNow = false
UI.SettingsActions:AddButton({
    Name = "Disable Automation",
    Callback = function()
        for _, index in ipairs({ "AutoSpinToggle", "AutoReceiveToggle", "AutoSpikeToggle" }) do
            pcall(function()
                local t = OrionLib.Flags[index]
                if t then t:Set(false) end
            end)
        end
        notify("Automation disabled", 3)
    end
})
UI.SettingsActions:AddButton({
    Name = "Disable Visual Features",
    Callback = function()
        for _, index in ipairs({ "BallESPToggle", "JumpESPToggle", "PredictAimToggle", "StreamerModeToggle" }) do
            pcall(function()
                local t = OrionLib.Flags[index]
                if t then t:Set(false) end
            end)
        end
        pcall(function() if BallESP then BallESP.clear() end end)
        notify("Visual features disabled", 3)
    end
})
UI.SettingsActions:AddButton({
    Name = "Clear Visual Cache",
    Callback = function()
        pcall(function() if BallESP then BallESP.clear() end end)
        pcall(clearAllJumpESP)
        pcall(clearAllPredictAim)
        notify("Visual cache cleared", 3)
    end
})

UnloadBtn = UI.SettingsActions:AddButton({
    Name = "Unload Script",
    Callback = function()
        if UnloadingNow then return end
        UnloadingNow = true
        pcall(function() if UnloadBtn then UnloadBtn:Set("Unloading...") end end)
        notify("Unloading Shijin Hub...", 2)
        task.delay(0.3, function()
            pcall(shijinFullCleanup)
            pcall(function() OrionLib:Destroy() end)
            pcall(function()
                local hui = (gethui and gethui()) or game:GetService("CoreGui")
                local leftover = hui and hui:FindFirstChild("Orion")
                if leftover then leftover:Destroy() end
            end)
            warn("[ShijinHub] unload finished")
        end)
    end
})
UI.SettingsActions:AddButton({
    Name = "Copy Discord Invite",
    Callback = function()
        local ok = pcall(function() setclipboard("https://discord.gg/wwHXeQaAqS") end)
        notify(ok and "Copied" or "Clipboard is unavailable", 3)
    end
})

-- UXO theme/save blocks removed: Orion SaveConfig is automatic
-- via Save=true flags, and autoload runs in OrionLib:Init() below.

-- Orion binds handle their own assigned key (see Key Binds tab): no polling.
-- Inactive binds never overwrite a manually-enabled feature.

ShijinBuilding = false
notify("Shijin Hub v" .. ScriptVersion .. " ready", 6)
print("[ShijinHub] v" .. ScriptVersion .. " loaded")

task.spawn(function()
    task.wait(2)
    if AntiModEnabled then pcall(checkForModerators) end
end)

pcall(function() OrionLib:Init() end)

-- Named-slot autoload (separate from Orion's own per-game autoload above).
-- Deferred so the window renders first; quiet apply, no popup spam.
task.spawn(function()
    orionEnsureFolder()
    pcall(function()
        if orionSlotsUsable() and isfile("ShijinHub/autoload.txt") then
            local name = orionCleanSlotName(readfile("ShijinHub/autoload.txt"))
            if name ~= "" and orionLoadSlot(name) then orionSetActive(name) end
        end
    end)
end)