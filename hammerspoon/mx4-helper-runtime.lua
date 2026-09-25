-- Starts the MX Master 4 event bridge only while its tagged-event receiver is
-- alive. The bridge exits within three seconds without these heartbeats.
local helperPath = hs.configdir .. "/mx4-device-helper"
local helperTask = nil
local heartbeatTimer = nil
local paused = false
local shuttingDown = false
local failureCount = 0
local nextAttempt = 0
local lastError = nil
local startedAt = 0
local recentOutput = {}

local function remember(message)
    if not message or message == "" then return end
    recentOutput[#recentOutput + 1] = message
    if #recentOutput > 20 then table.remove(recentOutput, 1) end
end

local function receiverReady()
    if not mx4 or not mx4.status then return false end
    local status = mx4.status()
    return status.receiverEnabled and status.receiverHealthy ~= false
end

local function stopHelper()
    if helperTask and helperTask:isRunning() then helperTask:terminate() end
end

local function scheduleRetry(reason)
    lastError = reason
    failureCount = math.min(failureCount + 1, 6)
    nextAttempt = hs.timer.secondsSinceEpoch() + math.min(30, 2 ^ failureCount)
end

local function launchHelper()
    if paused or shuttingDown or helperTask or not receiverReady() then return false end
    if not hs.accessibilityState() then
        scheduleRetry("Hammerspoon Accessibility permission is missing")
        return false
    end
    local task
    task = hs.task.new(helperPath,
        function(exitCode, stdout, stderr)
            remember(stdout)
            remember(stderr)
            if helperTask ~= task then return end
            helperTask = nil
            mx4.setHelperPID(nil)
            mx4.reset() -- Dismiss an MX-owned AltTab session if the bridge exits.
            if not paused and not shuttingDown then
                scheduleRetry("MX4 helper exited with code " .. tostring(exitCode) ..
                              ": " .. tostring(stderr or ""))
            end
        end,
        function(_, stdout, stderr)
            remember(stdout)
            remember(stderr)
            return true -- Drain pipes so an event tap can never block on them.
        end,
        {"--active", "--parent-pid", tostring(hs.processInfo.processID)})
    -- Queue the first beat before launch so the child's stdin never appears
    -- idle between creating the task and the first timer tick.
    if task then task:setInput("h") end
    if not task or not task:start() then
        scheduleRetry("Could not launch MX4 helper from " .. helperPath)
        return false
    end
    helperTask = task
    startedAt = hs.timer.secondsSinceEpoch()
    mx4.setHelperPID(task:pid())
    lastError = nil
    return true
end

local function pump()
    if paused or shuttingDown then return end
    if not receiverReady() then
        if helperTask then stopHelper() end
        lastError = "Tagged-event receiver is unavailable"
        return
    end
    if helperTask and helperTask:isRunning() then
        helperTask:setInput("h")
        if hs.timer.secondsSinceEpoch() - startedAt > 5 then failureCount = 0 end
        return
    end
    if not helperTask and hs.timer.secondsSinceEpoch() >= nextAttempt then launchHelper() end
end

heartbeatTimer = hs.timer.doEvery(0.5, pump)
launchHelper()

mx4runtime = {
    status = function()
        return {
            running = helperTask ~= nil and helperTask:isRunning(),
            pid = helperTask and helperTask:pid() or nil,
            paused = paused,
            receiverReady = receiverReady(),
            lastError = lastError,
            recentOutput = recentOutput,
        }
    end,
    pause = function()
        paused = true
        stopHelper()
    end,
    resume = function()
        paused = false
        nextAttempt = 0
        pump()
    end,
    stop = function()
        paused = true
        stopHelper()
    end,
}

hs.shutdownCallback = function()
    shuttingDown = true
    if heartbeatTimer then heartbeatTimer:stop() end
    if mx4 and mx4.reset then mx4.reset() end
    stopHelper()
end
