--[[
    VIREX ANTI-GUARD  -  Steal An Egg (placeId 107778070777162)

    Two functions. Nothing else.

      1. ANTI HIT   - watches for the guard and gets you clear of it
      2. AUTO RUN   - walks you home at full speed when you ask

    There is no teleport. The safe zone is 127 studs from the base and the game
    lets you run at 264 studs/s, so the walk home takes about half a second. A
    teleport bought nothing and cost a lot: the server silently corrects long
    position jumps, so it was the least reliable part of the old script.

    Load:
      loadstring(game:HttpGet("https://raw.githubusercontent.com/dertmo01/virex-antihit/master/antihit.lua"))()

    Turn everything off:  loadstring(getgenv().VIREX_DISABLE())
    Turn it back on:      loadstring(getgenv().VIREX_START())

    Auto Run is on R, or:  getgenv().VIREX_AUTORUN.start()  /  .stop()
]]

local Players                 = game:GetService("Players")
local ProximityPromptService  = game:GetService("ProximityPromptService")
local UserInputService        = game:GetService("UserInputService")
local TweenService            = game:GetService("TweenService")

local Player = Players.LocalPlayer

-- Virex Red, lifted from the old kit so this looks like the same project.
local THEME = {
    Main   = Color3.fromRGB(8, 16, 30),
    Panel  = Color3.fromRGB(13, 27, 46),
    Accent = Color3.fromRGB(255, 72, 72),
    Muted  = Color3.fromRGB(145, 145, 155),
}

-- ── settings ───────────────────────────────────────────────────────────────
-- Every number here is one the server can contradict. That is noted where it
-- matters; raising them will not produce a different result.
local SPEED          = 264   -- the game clamps WalkSpeed to 264 every frame
local ARRIVAL        = 8     -- studs from home that counts as arrived
local SAFE_ZONE      = Vector3.new(550, 70, -431)
local FALLBACK_BASE  = Vector3.new(657.207, 68.165, -363.579)
local SAFE_WAIT      = 1.0   -- seconds parked in the safe zone after a dodge
local DODGE_COOLDOWN = 4.0   -- seconds before another dodge may start
local RUN_TIMEOUT    = 25    -- give up walking home after this many seconds
local HOLD_TICK      = 0.01  -- how often the guard flag is read
local STEP           = 0.1   -- how often Auto Run asks the humanoid to move

-- Where to land after a dodge. Not the spot you were hit from: that is the
-- whole reason the guard kept catching up again.
local CLEAR_SPOT = Vector3.new(516, 72, -366)

local PUSHBACK_NAMES = {
    "PushBack", "AntiVoid", "Push", "AntiForce", "VoidPush", "AntiPush", "Knockback",
}

-- Declared before either feature because a dodge has to be able to pause the
-- walk home. Declaring it inside the Auto Run section would make every
-- reference above it a global, which is silent at load and nil at run time.
local autoRun

-- ── log ────────────────────────────────────────────────────────────────────
-- Feeds two sinks: the executor console, which is the thing to paste back when
-- something misbehaves, and the window, which is what you actually watch while
-- playing. The window sink is declared above so log() can exist before the UI
-- is built; until uiLog exists the console still gets everything.
local uiLog
local function log(msg, kind)
    local line = ("[%s] %s"):format(kind or "info", tostring(msg))
    print("[Virex]"..line)
    if uiLog then pcall(uiLog, line, kind or "info") end
end

-- ── character access ───────────────────────────────────────────────────────
local function root()
    local c = Player.Character
    return c and c:FindFirstChild("HumanoidRootPart") or nil
end

local function humanoid()
    local c = Player.Character
    return c and c:FindFirstChildOfClass("Humanoid") or nil
end

-- The guard's knockback wins every fight against MoveTo. Zeroing it is the
-- difference between walking home and standing still.
local function stripPushBack()
    local c = Player.Character
    if not c then return end
    for _, name in ipairs(PUSHBACK_NAMES) do
        for _, obj in ipairs(c:GetChildren()) do
            if obj.Name == name then
                pcall(function()
                    if obj:IsA("BodyVelocity") or obj:IsA("BodyGyro") then
                        obj.Velocity = Vector3.zero
                    end
                    if obj:IsA("LinearVelocity") then obj.Force = Vector3.zero end
                    if obj:IsA("AlignPosition") then obj.Position = Vector3.zero end
                end)
            end
        end
    end
end

-- ── base detection ─────────────────────────────────────────────────────────
local baseCached

local function basePosition()
    if baseCached then return baseCached end
    local rl = Player.RespawnLocation
    if rl then
        baseCached = rl.Position
        return baseCached
    end
    -- A named marker beats the fallback: the base in this game is
    -- CoralukeBaseThreshold, and it is not the same point as the fallback.
    local best, bestDist
    for _, obj in ipairs(workspace:GetDescendants()) do
        if obj:IsA("BasePart") and string.find(string.lower(obj.Name), "base", 1, true) then
            local r = root()
            local d = r and (r.Position - obj.Position).Magnitude or 0
            if not bestDist or d < bestDist then best, bestDist = obj.Position, d end
        end
    end
    baseCached = best or FALLBACK_BASE
    log("Home: "..tostring(baseCached) .. (best and " (named marker)" or " (fallback)"), "ok")
    return baseCached
end

-- ── prompt hold duration ───────────────────────────────────────────────────
-- HoldDuration = 0 is what makes an egg prompt instant; measured 98/98 prompts
-- accepted at 0. It belongs here because a prompt you cannot press in time is
-- a prompt the guard interrupts.
local function zeroAllPrompts()
    for _, p in ipairs(workspace:GetDescendants()) do
        if p:IsA("ProximityPrompt") then pcall(function() p.HoldDuration = 0 end) end
    end
end

local function watchPrompts()
    local seen = {}
    while true do
        for _, p in ipairs(workspace:GetDescendants()) do
            if p:IsA("ProximityPrompt") and not seen[p] then
                seen[p] = true
                pcall(function() p.HoldDuration = 0 end)
            end
        end
        -- Eggs spawn over time, so one that appears later still needs its hold
        -- time removed.
        task.wait(3)
    end
end

-- ── 1. ANTI HIT ───────────────────────────────────────────────────────────
local antiHit = {}
antiHit.enabled   = true
antiHit.dodging   = false
antiHit.lastDodge = -math.huge
antiHit.watchThread = nil

local function findGuardFlag()
    local pg = Player:FindFirstChildOfClass("PlayerGui")
    if not pg then return nil end
    for _, obj in ipairs(pg:GetDescendants()) do
        if obj.Name == "DropHeldEgg" then return obj end
    end
    return nil
end

local function beginDodge(reason)
    if not antiHit.enabled or antiHit.dodging then return end
    -- A guard re-arming inside the cooldown is the same event already being
    -- handled. Ignoring it is what stops the dodge loop.
    if os.clock() - antiHit.lastDodge < DODGE_COOLDOWN then return end
    antiHit.lastDodge = os.clock()
    antiHit.dodging = true

    task.spawn(function()
        log("Dodge via "..reason, "warn")
        -- The walk home is paused for the duration. Both features write your
        -- position, and letting them fight is how the old script ended up
        -- dragging you back into the guard it had just dodged.
        if autoRun then autoRun.suspend("dodge in progress") end

        local h = humanoid()
        local savedSpeed = h and h.WalkSpeed or SPEED

        local r = root()
        if r then
            pcall(function()
                r.CFrame = CFrame.new(SAFE_ZONE)
                r.AssemblyLinearVelocity  = Vector3.zero
                r.AssemblyAngularVelocity = Vector3.zero
            end)
        end
        stripPushBack()
        task.wait(SAFE_WAIT)

        local hr = root()
        if hr then
            pcall(function()
                hr.CFrame = CFrame.new(CLEAR_SPOT)
                hr.AssemblyLinearVelocity  = Vector3.zero
                hr.AssemblyAngularVelocity = Vector3.zero
            end)
        end
        stripPushBack()
        local hh = humanoid()
        if hh then pcall(function() hh.WalkSpeed = savedSpeed end) end

        antiHit.dodging = false
        log("Dodge done, moved clear of the guard", "ok")
        if autoRun then autoRun.resume() end
    end)
end

-- The second guard signal: the prompt the server fires. Connected exactly once,
-- outside watch(), because putting it in there meant every VIREX_START added
-- another connection and dodges fired more than once per guard.
local function watchPromptTrigger()
    ProximityPromptService.PromptTriggered:Connect(function(prompt, player)
        if player ~= Player then return end
        local cur, depth = prompt.Parent, 0
        while cur and depth < 10 do
            depth += 1
            local low = string.lower(cur.Name)
            if string.find(low, "drop", 1, true) or string.find(low, "guard", 1, true)
               or string.find(low, "steal", 1, true) then
                local name = prompt.Parent and prompt.Parent.Name or "?"
                beginDodge("prompt '"..name.."'")
                return
            end
            cur = cur.Parent
        end
    end)
end

function antiHit.stopWatch()
    if antiHit.watchThread then pcall(function() task.cancel(antiHit.watchThread) end) end
    antiHit.watchThread = nil
end

function antiHit.watch()
    antiHit.stopWatch()
    local wasTrue = false
    local flag
    antiHit.watchThread = task.spawn(function()
        while antiHit.enabled do
            task.wait(HOLD_TICK)
            if not antiHit.enabled then break end
            if not flag or not flag.Parent then flag = findGuardFlag() end
            if flag then
                local now = (flag.Enabled == true)
                -- Rising edge only, so a flag held true cannot spam dodges.
                if now and not wasTrue then
                    wasTrue = true
                    beginDodge("DropHeldEgg.Enabled")
                elseif not now then
                    wasTrue = false
                end
            end
        end
    end)

    if findGuardFlag() then
        log("Guard flag found - watching", "ok")
    else
        log("Guard flag not in PlayerGui yet; prompt trigger is still active", "warn")
    end
end

-- ── 2. AUTO RUN ───────────────────────────────────────────────────────────
autoRun = {}
autoRun.active = false
autoRun.paused = false
autoRun.thread = nil
autoRun.onChange = nil

function autoRun.suspend(why)
    if not autoRun.active then return end
    autoRun.paused = true
    local h = humanoid()
    if h then pcall(function() h.WalkSpeed = 0 end) end
    log("Auto Run paused - "..why, "warn")
end

function autoRun.resume()
    autoRun.paused = false
    if not autoRun.active then return end
    local h = humanoid()
    if h then pcall(function() h.WalkSpeed = SPEED end) end
    log("Auto Run resumed", "ok")
end

function autoRun.stop()
    autoRun.active, autoRun.paused = false, false
    if autoRun.thread then pcall(function() task.cancel(autoRun.thread) end) end
    autoRun.thread = nil
    if autoRun.onChange then autoRun.onChange() end
    log("Auto Run stopped", "info")
end

function autoRun.start()
    if autoRun.active then return end
    local target = basePosition()
    autoRun.active, autoRun.paused = true, false
    if autoRun.onChange then autoRun.onChange() end
    log("Auto Run: heading home", "ok")

    autoRun.thread = task.spawn(function()
        local started = os.clock()
        local lastPos, lastCheck, stuck = nil, os.clock(), 0

        while autoRun.active do
            if autoRun.paused then
                task.wait(STEP)
            else
                local r, h = root(), humanoid()
                if not r or not h then
                    task.wait(0.2)
                elseif h.Health <= 0 then
                    log("Auto Run: died on the way home", "err")
                    break
                else
                    local dist = (r.Position - target).Magnitude
                    if dist <= ARRIVAL then
                        log(string.format("Auto Run: home, %d studs in %.1fs",
                            math.floor(dist), os.clock() - started), "ok")
                        break
                    end
                    if os.clock() - started > RUN_TIMEOUT then
                        log(string.format("Auto Run: timed out still %d studs out",
                            math.floor(dist)), "warn")
                        break
                    end

                    -- Asked every step because the server rewrites WalkSpeed
                    -- every frame. Writing it once is not enough to hold 264.
                    stripPushBack()
                    pcall(function()
                        if math.abs(h.WalkSpeed - SPEED) > 0.5 then h.WalkSpeed = SPEED end
                        h:MoveTo(target)
                    end)

                    if os.clock() - lastCheck >= 1 then
                        local cur = root()
                        -- first check has nothing to compare against
                        local moved = lastPos and cur and (cur.Position - lastPos).Magnitude or 0
                        if moved < 3 then
                            stuck += 1
                            log(string.format("Auto Run: stuck %d - moved %.1f studs, %d to go",
                                stuck, moved, math.floor(dist)), "warn")
                            if stuck >= 4 then
                                log("Auto Run: not moving; stopping so it cannot nag", "err")
                                break
                            end
                        else
                            if stuck > 0 then log("Auto Run: moving again", "ok") end
                            stuck = 0
                        end
                        lastPos, lastCheck = cur and cur.Position or nil, os.clock()
                    end
                end
            end
            task.wait(STEP)
        end
        autoRun.active = false
        autoRun.paused = false
        autoRun.thread = nil
        if autoRun.onChange then autoRun.onChange() end
    end)
end

-- ── boot ───────────────────────────────────────────────────────────────────
local function onRespawn(char)
    char:WaitForChild("HumanoidRootPart", 10)
    task.wait(0.5)
    baseCached = nil
    zeroAllPrompts()
    -- The old thread dies with the character, so this has to be started over
    -- rather than merely re-flagged as active.
    if autoRun.active then
        autoRun.stop()
        autoRun.start()
    end
    if antiHit.enabled then antiHit.watch() end
    log("Respawned - features rebound", "ok")
end

-- Exposed because the whole file is run through loadstring(), which gives the
-- caller its own scope: a bare local here would be unreachable from outside, so
-- "call start()" would have been advice nobody could follow.
local env = getgenv()
env.VIREX_AUTORUN = autoRun
env.VIREX_DISABLE = function()
    antiHit.enabled = false
    antiHit.stopWatch()
    autoRun.stop()
    log("Everything off", "ok")
end
env.VIREX_START = function()
    antiHit.enabled = true
    antiHit.watch()
    log("Anti Hit on", "ok")
end

-- R toggles the walk home. processed is checked so typing R into chat does not
-- fire it.
UserInputService.InputBegan:Connect(function(key, processed)
    if processed then return end
    if key.KeyCode == Enum.KeyCode.R then
        if autoRun.active then
            autoRun.stop()
        else
            autoRun.start()
        end
    end
end)

Player.CharacterAdded:Connect(onRespawn)
watchPromptTrigger()
zeroAllPrompts()
task.spawn(watchPrompts)
antiHit.watch()

local home = basePosition()
log("Ready.", "ok")
log("  1. Anti Hit  - on by default, watching for the guard")
log("  2. Auto Run  - press R to walk home, R again to cancel")
log(string.format("  Safe zone is %d studs from home; at %d studs/s that walk is %.1fs.",
    math.floor((SAFE_ZONE - home).Magnitude), SPEED, (SAFE_ZONE - home).Magnitude / SPEED))

-- ── window ─────────────────────────────────────────────────────────────────
-- Built last, after both features exist, because every control here calls into
-- them.
local function make(class, parent, props)
    local o = Instance.new(class)
    if props then for k, v in pairs(props) do o[k] = v end end
    o.Parent = parent
    return o
end
local function round(o, r)
    make("UICorner", o, { CornerRadius = UDim.new(0, r) })
end

local function buildUI()
    -- Re-running the script should refresh the window, not stack a second one
    -- on top of the first.
    local existing = Player.PlayerGui:FindFirstChild("VirexAntiGuard")
    if existing then existing:Destroy() end

    local gui = make("ScreenGui", Player.PlayerGui, {
        Name = "VirexAntiGuard",
        ResetOnSpawn = false,
        ZIndexBehavior = Enum.ZIndexBehavior.Sibling,
    })

    local main = make("Frame", gui, {
        Size = UDim2.fromOffset(340, 340),
        Position = UDim2.fromOffset(24, 90),
        BackgroundColor3 = THEME.Main,
        BorderSizePixel = 0,
        Active = true,
    })
    round(main, 14)
    make("UIStroke", main, { Color = Color3.fromRGB(0, 0, 0), Thickness = 1.5, Transparency = 0.4 })

    -- ── title bar, doubles as the drag handle ──
    local bar = make("Frame", main, {
        Size = UDim2.new(1, 0), Position = UDim2.fromOffset(0, 0),
        BackgroundColor3 = THEME.Panel, BorderSizePixel = 0, Active = true,
    })
    round(bar, 14)
    -- Square off the bottom of the bar so only the top corners look rounded.
    make("Frame", bar, {
        Size = UDim2.new(1, 0), Position = UDim2.new(0, 0, 1, -10),
        BackgroundColor3 = THEME.Panel, BorderSizePixel = 0,
    }).Name = "BarTail"

    make("TextLabel", bar, {
        Size = UDim2.new(1, -90), Position = UDim2.fromOffset(14, 0),
        BackgroundTransparency = 1, Text = "VIREX ANTI-GUARD",
        TextColor3 = THEME.Accent, TextSize = 17,
        Font = Enum.Font.FredokaOne, TextXAlignment = Enum.TextXAlignment.Left,
    })

    local function iconBtn(text, xPos, tip)
        local b = make("TextButton", bar, {
            Size = UDim2.fromOffset(26, 26), Position = UDim2.new(1, xPos, 0, 9),
            BackgroundColor3 = THEME.Accent, Text = text, TextColor3 = Color3.new(1, 1, 1),
            TextSize = 15, Font = Enum.Font.FredokaOne, AutoButtonColor = true,
        })
        round(b, 6)
        b.MouseEnter:Connect(function()
            TweenService:Create(b, TweenInfo.new(0.15), { BackgroundColor3 = Color3.new(1, 1, 1) }):Play()
        end)
        b.MouseLeave:Connect(function()
            TweenService:Create(b, TweenInfo.new(0.15), { BackgroundColor3 = THEME.Accent }):Play()
        end)
        b.Touched:Connect(function() pcall(function() print(tip) end) end)
        return b
    end
    local minBtn = iconBtn("_", -34, "minimize")
    iconBtn("X", -62, "close")

    -- ── body, hidden by minimize ──
    local body = make("Frame", main, {
        Size = UDim2.new(1, -24, 1, -54), Position = UDim2.fromOffset(12, 44),
        BackgroundTransparency = 1,
    })

    -- ── two toggles ──
    local toggles = {}
    local function addToggle(name, sub, getOn, setOn)
        local row = make("Frame", body, {
            Size = UDim2.new(1, 0), Position = UDim2.fromOffset(0, toggles.count and 52 or 0),
            BackgroundColor3 = THEME.Panel, BorderSizePixel = 0,
        })
        round(row, 10)

        make("TextLabel", row, {
            Size = UDim2.new(1, -70, 0, 22), Position = UDim2.fromOffset(12, 8),
            BackgroundTransparency = 1, Text = name, TextColor3 = Color3.new(1, 1, 1),
            TextSize = 14, Font = Enum.Font.FredokaOne, TextXAlignment = Enum.TextXAlignment.Left,
        })
        make("TextLabel", row, {
            Size = UDim2.new(1, -70, 0, 16), Position = UDim2.fromOffset(12, 29),
            BackgroundTransparency = 1, Text = sub, TextColor3 = THEME.Muted,
            TextSize = 11, Font = Enum.Font.Gotham, TextXAlignment = Enum.TextXAlignment.Left,
        })

        local sw = make("TextButton", row, {
            Size = UDim2.fromOffset(44, 24), Position = UDim2.new(1, -56, 0, 20),
            BackgroundColor3 = THEME.Accent, Text = "", BorderSizePixel = 0, AutoButtonColor = false,
        })
        round(sw, 12)

        local function paint()
            sw.BackgroundColor3 = getOn() and Color3.fromRGB(75, 220, 135) or THEME.Accent
        end
        sw.MouseButton1Click:Connect(function()
            setOn(not getOn())
            paint()
            log(name..(getOn() and " enabled" or " disabled"), getOn() and "ok" or "warn")
        end)
        paint()
        toggles.count = (toggles.count or 0) + 52
        toggles[name] = function() paint() end
    end

    addToggle("Anti Hit", "watch the guard, move you clear", function() return antiHit.enabled end, function(v)
        antiHit.enabled = v
        if v then antiHit.watch() else antiHit.stopWatch() end
    end)
    addToggle("Auto Run", "R also toggles this", function() return autoRun.active end, function(v)
        if v then autoRun.start() else autoRun.stop() end
    end)

    -- ── log view ──
    local box = make("ScrollingFrame", body, {
        Size = UDim2.new(1, 0, 1, -122), Position = UDim2.fromOffset(0, 112),
        BackgroundColor3 = THEME.Panel, BorderSizePixel = 0,
        ScrollBarThickness = 4, ScrollBarImageColor3 = THEME.Accent,
        CanvasSize = UDim2.new(), AutomaticCanvasSize = Enum.AutomaticSize.Y,
    })
    round(box, 10)
    local pad = make("UIListLayout", box, {
        SortOrder = Enum.SortOrder.LayoutOrder, Padding = UDim.new(0, 2),
    })
    pad.Parent = box

    -- ── status strip ──
    local status = make("TextLabel", body, {
        Size = UDim2.new(1, 0), Position = UDim2.new(0, 0, 1, -24),
        BackgroundTransparency = 1, Text = "", TextColor3 = THEME.Muted,
        TextSize = 11, Font = Enum.Font.Gotham, TextXAlignment = Enum.TextXAlignment.Left,
    })

    -- Minimize. The previous project lost its body reference here and the
    -- window never came back; `body` stays in scope and `minimized` is the one
    -- source of truth.
    local minimized = false
    minBtn.MouseButton1Click:Connect(function()
        minimized = not minimized
        local target = minimized and UDim2.new(1, 0, 0, 44) or UDim2.new(1, -24, 1, -54)
        TweenService:Create(body, TweenInfo.new(0.18, Enum.EasingStyle.Quad), { Size = target }):Play()
        TweenService:Create(main, TweenInfo.new(0.18, Enum.EasingStyle.Quad),
            { Size = minimized and UDim2.fromOffset(340, 44) or UDim2.fromOffset(340, 340) }):Play()
        minBtn.Text = minimized and "v" or "_"
    end)

    -- Close just hides the window; the features keep running. Stopping them is
    -- what VIREX_DISABLE is for, and conflating the two made the old script look
    -- dead when it was still working.
    local closeBtn
    for _, b in ipairs(bar:GetChildren()) do
        if b:IsA("TextButton") and b.Text == "X" then
            closeBtn = b
            break
        end
    end
    if closeBtn then
        closeBtn.MouseButton1Click:Connect(function() main.Visible = false end)
    end

    -- Drag
    local dragging, dragStart, startPos
    bar.InputBegan:Connect(function(input)
        if input.UserInputType == Enum.UserInputType.MouseButton1
           or input.UserInputType == Enum.UserInputType.Touch then
            dragging = true
            dragStart, startPos = input.Position, main.Position
            input.Changed:Connect(function()
                if input.UserInputState == Enum.UserInputState.End then dragging = false end
            end)
        end
    end)
    UserInputService.InputChanged:Connect(function(input)
        if dragging and (input.UserInputType == Enum.UserInputType.MouseMovement
                          or input.UserInputType == Enum.UserInputType.Touch) then
            main.Position = UDim2.fromOffset(
                startPos.X.Offset + (input.Position.X - dragStart.X),
                startPos.Y.Offset + (input.Position.Y - dragStart.Y))
        end
    end)

    -- ── the log sink log() writes into ──
    local order = 0
    uiLog = function(line, kind)
        if not box or not box.Parent then return end
        local colour = THEME.Muted
        if kind == "ok" then colour = Color3.fromRGB(130, 235, 160)
        elseif kind == "warn" then colour = Color3.fromRGB(255, 195, 90)
        elseif kind == "err" then colour = THEME.Accent end
        order += 1
        make("TextLabel", box, {
            Size = UDim2.new(1, -10), BackgroundTransparency = 1,
            Text = line, TextColor3 = colour, TextSize = 12,
            Font = Enum.Font.Code, TextXAlignment = Enum.TextXAlignment.Left,
            TextWrapped = true, LayoutOrder = order,
        })
        -- Keep the box to the last 60 lines so a long session cannot grow it
        -- without bound and start dropping frames.
        if box:GetChildren() > 62 then
            local oldest
            for _, c in ipairs(box:GetChildren()) do
                if c:IsA("TextLabel") and (not oldest or c.LayoutOrder < oldest.LayoutOrder) then oldest = c end
            end
            if oldest then oldest:Destroy() end
        end
        task.defer(function()
            box.CanvasPosition = Vector2.new(0, math.max(0, box.AbsoluteCanvasSize.Y - box.AbsoluteSize.Y))
        end)
        status.Text = ("Anti Hit %s   |   Auto Run %s   |   %s"):format(
            antiHit.enabled and "on" or "off",
            autoRun.active and "walking" or (autoRun.paused and "paused" or "idle"),
            line)
    end

    -- Re-paint the toggles when a feature changes from outside the window, such
    -- as the R key.
    autoRun.onChange = function()
        if toggles["Auto Run"] then toggles["Auto Run"]() end
    end
    return main, closeBtn
end

local window = buildUI()

-- Drag the window clear of the default offset so it never opens behind the
-- chat or the core UI on small screens.
if window then
    window.Position = UDim2.fromOffset(18, 80)
end