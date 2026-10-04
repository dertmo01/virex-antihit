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

local Player = Players.LocalPlayer

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
-- Plain print. No window, no clipboard, nothing extra to break. It already
-- lands in the executor console.
local function log(msg, kind)
    print(("[Virex][%s] %s"):format(kind or "info", tostring(msg)))
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
    log("Auto Run stopped", "info")
end

function autoRun.start()
    if autoRun.active then return end
    local target = basePosition()
    autoRun.active, autoRun.paused = true, false
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