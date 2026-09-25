-- MX Master 4 macros. Mouse events are classified and filtered by the native
-- helper before they reach this file. This file never watches ordinary clicks
-- or scrolling and accepts only the helper's tagged F15 events.

require("hs.ipc")

local event = hs.eventtap.event
local types = event.types
local fields = event.properties
local F15 = hs.keycodes.map.f15
local TAG_BASE = 0x4D5800
local KEY_PRESS_USEC = 50000
local ALT_TAB = "/Applications/AltTab.app/Contents/MacOS/AltTab"
local ALT_TAB_BUNDLE = "com.lwouis.alt-tab-macos"

local ACTION = {
    thumbWheelUp = 1, thumbWheelDown = 2,
    thumbLeft = 3, thumbRight = 4,
    thirdWheelUp = 5, thirdWheelDown = 6,
    thirdCopy = 7, thirdPaste = 8, thirdSelectAll = 9,
    thirdRelease = 10,
}

local trace = {}
local windowNav = nil
local pendingWindowActions = {}
local windowWorkScheduled = false
local windowQueueGeneration = 0
local mouseShowIssued = false
local pendingTabSteps = {}
local tabWorkScheduled = false
local tabQueueGeneration = 0
local helperPID = nil
local lastTaggedSourcePID = nil
local receiverHealthy = true
local receiverError = nil
local sendShortcut
local clearNavigation

local function receiverFailed(err)
    receiverHealthy = false
    receiverError = tostring(err)
    if clearNavigation then clearNavigation() end
    trace[#trace + 1] = {
        t = hs.timer.secondsSinceEpoch(), action = "receiver-error",
    }
end

local function runSafely(fn)
    if not receiverHealthy then return end
    local ok, err = pcall(fn)
    if not ok then receiverFailed(err) end
end

local function note(action)
    trace[#trace + 1] = {t = hs.timer.secondsSinceEpoch(), action = action}
    if #trace > 100 then table.remove(trace, 1) end
end

clearNavigation = function()
    local mayHaveOpened = mouseShowIssued
    windowNav = nil
    mouseShowIssued = false
    pendingWindowActions = {}
    windowWorkScheduled = false
    windowQueueGeneration = windowQueueGeneration + 1
    if mayHaveOpened then hs.execute('"' .. ALT_TAB .. '" --hide') end
end

local function clearTabSteps()
    pendingTabSteps = {}
    tabWorkScheduled = false
    tabQueueGeneration = tabQueueGeneration + 1
end

-- AltTab's CLI opens the real thumbnails and advances forward. To move back,
-- send its existing Left Arrow navigation action directly to the AltTab app.
-- No keyboard modifier is posted to the session, so a trackpad click cannot
-- become a modified click while the MX button is held.
local function altTabCommand(argument, done, guard)
    -- One short CLI request per timer turn keeps the native helper's heartbeat
    -- running. Because hs.execute finishes before the next callback,
    -- reset/hide cannot overtake a show request already in flight.
    local generation = windowQueueGeneration
    hs.timer.doAfter(0, function()
        if generation ~= windowQueueGeneration then return end
        runSafely(function()
            if guard and not guard() then done(false, ""); return end
            if argument == "--show=0" then mouseShowIssued = true end
            local output, ok, _, code = hs.execute('"' .. ALT_TAB .. '" ' .. argument)
            if not ok then note("alttab-cli-failed:" .. argument .. ":" .. tostring(code)) end
            done(ok == true, output or "")
        end)
    end)
end

local function altTabState(done)
    altTabCommand("--qa-state", function(ok, output)
        if not ok then done(nil); return end
        local decoded, state = pcall(hs.json.decode, output)
        if not decoded or type(state) ~= "table" then
            note("alttab-state-decode-failed")
            done(nil)
            return
        end
        done(state)
    end)
end

local function visibleIndexes(state)
    local indexes = {}
    for _, tile in ipairs(state.tiles or {}) do
        if type(tile.index) == "number" then
            local window = state.windows and state.windows[tile.index + 1]
            if not window or window.index ~= tile.index or window.wid ~= tile.wid then
                return nil
            end
            indexes[#indexes + 1] = tile.index
        end
    end
    return indexes
end

local function positionOf(indexes, value)
    for position, index in ipairs(indexes) do
        if index == value then return position end
    end
    return nil
end

local function settledAltTabState(generation, attempts, done)
    if generation ~= windowQueueGeneration then return end
    altTabState(function(state)
        if generation ~= windowQueueGeneration then return end
        local indexes = state and visibleIndexes(state)
        local selected = state and state.selectedIndex
        if state and state.switcherVisible and type(selected) == "number"
            and indexes and #indexes > 0 and positionOf(indexes, selected) then
            done(state, indexes)
        elseif attempts > 1 then
            hs.timer.doAfter(0.1, function()
                runSafely(function() settledAltTabState(generation, attempts - 1, done) end)
            end)
        else
            note("alttab-state-not-settled")
            done(nil, nil)
        end
    end)
end

local function abortNavigation(generation, reason, done)
    if generation ~= windowQueueGeneration then return end
    note(reason)
    windowNav = nil
    if not mouseShowIssued then done(); return end
    altTabCommand("--hide", function()
        mouseShowIssued = false
        if generation == windowQueueGeneration then done() end
    end)
end

local function originStillFocused(nav)
    local front = hs.application.frontmostApplication()
    local originalApp = nav.originPid and hs.application.get(nav.originPid) or nil
    local win = originalApp and originalApp:focusedWindow() or nil
    local currentPid = front and front:pid() or nil
    local currentWindowId = win and win:id() or nil
    local same = currentPid == nav.originPid and currentWindowId == nav.originWindowId
    if not same then
        note("alttab-focus-change:" .. tostring(nav.originPid) .. ":" ..
             tostring(nav.originWindowId) .. "->" .. tostring(currentPid) .. ":" ..
             tostring(currentWindowId))
    end
    return same
end

local function postAltTabLeft(count, generation, done)
    if generation ~= windowQueueGeneration then return end
    if count <= 0 then done(true); return end
    if not windowNav or not originStillFocused(windowNav) then done(false); return end
    -- The CLI marks its session active before the nonactivating panel becomes
    -- key. A process-directed key sent during that display delay gets lost.
    local delay = (windowNav.readyAt or 0) - hs.timer.secondsSinceEpoch()
    if delay > 0 then
        hs.timer.doAfter(delay, function()
            runSafely(function() postAltTabLeft(count, generation, done) end)
        end)
        return
    end
    local app = hs.application.get(ALT_TAB_BUNDLE)
    if not app then done(false); return end
    event.newKeyEvent({}, "left", true):post(app)
    event.newKeyEvent({}, "left", false):post(app)
    postAltTabLeft(count - 1, generation, done)
end

local function waitForSelection(generation, targetIndex, attempts, done)
    if generation ~= windowQueueGeneration then return end
    altTabState(function(state)
        if generation ~= windowQueueGeneration then return end
        if state and state.switcherVisible and state.selectedIndex == targetIndex then
            done(true)
        elseif attempts > 1 then
            hs.timer.doAfter(0.06, function()
                runSafely(function()
                    waitForSelection(generation, targetIndex, attempts - 1, done)
                end)
            end)
        else
            done(false)
        end
    end)
end

local function reverseWindow(firstStep, generation, done)
    settledAltTabState(generation, 3, function(state, indexes)
        if not state then
            abortNavigation(generation, "alttab-reverse-state-unavailable", done)
            return
        end
        local count = #indexes
        local current = positionOf(indexes, state.selectedIndex)
        if count < 2 or not current then
            abortNavigation(generation, "alttab-reverse-no-selection", done)
            return
        end
        local target
        if firstStep then
            local focused
            for position, index in ipairs(indexes) do
                local window = state.windows[index + 1]
                if window and window.focused then focused = position; break end
            end
            target = focused and ((focused - 2 + count) % count + 1) or count
        else
            target = (current - 2 + count) % count + 1
        end
        local backwards = (current - target + count) % count
        local targetIndex = indexes[target]
        postAltTabLeft(backwards, generation, function(ok)
            if not ok then
                abortNavigation(generation, "alttab-reverse-incomplete", done)
                return
            end
            waitForSelection(generation, targetIndex, 6, function(matched)
                if not matched then
                    abortNavigation(generation, "alttab-reverse-selection-drift", done)
                    return
                end
                done()
            end)
        end)
    end)
end

local function stepWindow(direction, generation, done)
    if generation ~= windowQueueGeneration then return end
    if windowNav then
        if not originStillFocused(windowNav) then
            abortNavigation(generation, "alttab-navigation-cancelled-foreground-changed", done)
            return
        end
        if direction > 0 then
            settledAltTabState(generation, 3, function(before, indexes)
                if not before then
                    abortNavigation(generation, "alttab-forward-state-unavailable", done)
                    return
                end
                local current = positionOf(indexes, before.selectedIndex)
                if not current or #indexes < 2 then
                    abortNavigation(generation, "alttab-forward-no-selection", done)
                    return
                end
                local targetIndex = indexes[current % #indexes + 1]
                altTabCommand("--show=0", function(ok)
                    if generation ~= windowQueueGeneration then return end
                    if not ok then
                        abortNavigation(generation, "alttab-forward-incomplete", done)
                        return
                    end
                    settledAltTabState(generation, 3, function(after)
                        if not after or after.selectedIndex ~= targetIndex then
                            abortNavigation(generation, "alttab-forward-selection-drift", done)
                            return
                        end
                        done()
                    end)
                end, function() return windowNav and originStillFocused(windowNav) end)
            end)
        else
            reverseWindow(false, generation, done)
        end
        return
    end
    altTabState(function(state)
        if generation ~= windowQueueGeneration then return end
        -- Leave a keyboard-owned AltTab session alone.
        if not state or state.switcherVisible then done(); return end
        local originApp = hs.application.frontmostApplication()
        local originWin = originApp and originApp:focusedWindow() or nil
        local originPid = originApp and originApp:pid() or nil
        local originWindowId = originWin and originWin:id() or nil
        local openedAt = hs.timer.secondsSinceEpoch()
        altTabCommand("--show=0", function(ok)
            if generation ~= windowQueueGeneration then return end
            if not ok then
                abortNavigation(generation, "alttab-open-incomplete", done)
                return
            end
            settledAltTabState(generation, 3, function(shown)
                if not shown then
                    altTabCommand("--hide", function()
                        mouseShowIssued = false
                        if generation == windowQueueGeneration then done() end
                    end)
                    return
                end
                if not originStillFocused({originPid = originPid,
                                           originWindowId = originWindowId}) then
                    abortNavigation(generation, "alttab-open-cancelled-foreground-changed", done)
                    return
                end
                windowNav = {
                    originPid = originPid,
                    originWindowId = originWindowId,
                    readyAt = openedAt + 0.15,
                }
                if direction > 0 then done()
                else reverseWindow(true, generation, done) end
            end)
        end, function()
            return originStillFocused({originPid = originPid,
                                       originWindowId = originWindowId})
        end)
    end)
end

local function commitWindow(generation, done)
    if generation ~= windowQueueGeneration then return end
    if not windowNav then done(nil); return end
    local nav = windowNav
    windowNav = nil
    if not originStillFocused(nav) then
        note("alttab-commit-cancelled-foreground-changed")
        altTabCommand("--hide", function()
            mouseShowIssued = false
            if generation == windowQueueGeneration then done(nil) end
        end)
        return
    end
    settledAltTabState(generation, 3, function(state)
        local selected
        if state and state.switcherVisible and type(state.selectedIndex) == "number" then
            selected = state.windows and state.windows[state.selectedIndex + 1]
            if selected and selected.index ~= state.selectedIndex then selected = nil end
        end
        altTabCommand("--hide", function(ok)
            mouseShowIssued = false
            if generation ~= windowQueueGeneration then return end
            if not ok or not selected then done(nil); return end
            if not originStillFocused(nav) then
                note("alttab-commit-cancelled-foreground-changed")
                done(nil)
                return
            end
            local command
            if type(selected.wid) == "number" then
                command = "--focus=" .. tostring(selected.wid)
            end
            if not command then done(nil); return end
            altTabCommand(command, function(focused)
                if generation ~= windowQueueGeneration then return end
                done(focused and selected or nil)
            end, function() return originStillFocused(nav) end)
        end)
    end)
end

local function commitAndClick(key, generation, done)
    if generation ~= windowQueueGeneration then return end
    if not windowNav then
        sendShortcut({"cmd"}, key)
        done()
        return
    end
    commitWindow(generation, function(selected)
        if generation ~= windowQueueGeneration then return end
        if not selected then done(); return end
        local attempts = 0
        local function sendWhenFocused()
            if generation ~= windowQueueGeneration then return end
            attempts = attempts + 1
            local app = hs.application.frontmostApplication()
            local win = hs.window.focusedWindow()
            local correctApp = app and app:pid() == selected.pid
            local correctWindow = not selected.wid or (win and win:id() == selected.wid)
            if correctApp and correctWindow then
                hs.eventtap.keyStroke({"cmd"}, key, KEY_PRESS_USEC)
                done()
            elseif attempts < 10 then
                hs.timer.doAfter(0.05, function() runSafely(sendWhenFocused) end)
            else
                note("alttab-click-skipped-focus-timeout")
                done()
            end
        end
        hs.timer.doAfter(0.05, function() runSafely(sendWhenFocused) end)
    end)
end

-- Helper actions arrive in order. Keep steps, clicks and release in one queue,
-- so a delayed release cannot commit a later F14 hold's new selection.
local flushWindowActions
flushWindowActions = function(generation)
    if generation ~= windowQueueGeneration then return end
    local action = table.remove(pendingWindowActions, 1)
    if not action then
        windowWorkScheduled = false
        return
    end
    local function nextAction()
        if generation ~= windowQueueGeneration then return end
        hs.timer.doAfter(0, function()
            runSafely(function() flushWindowActions(generation) end)
        end)
    end
    if action.kind == "step" then
        stepWindow(action.direction, generation, nextAction)
    elseif action.kind == "click" then
        commitAndClick(action.key, generation, nextAction)
    elseif action.kind == "release" then
        commitWindow(generation, function() nextAction() end)
    end
end

local function queueWindowAction(action)
    pendingWindowActions[#pendingWindowActions + 1] = action
    if windowWorkScheduled then return end
    windowWorkScheduled = true
    local generation = windowQueueGeneration
    hs.timer.doAfter(0, function()
        runSafely(function() flushWindowActions(generation) end)
    end)
end

sendShortcut = function(mods, key)
    -- Run after the tagged F15 callback has returned. This keeps shortcut
    -- events independent from the event tap's original key event.
    hs.timer.doAfter(0, function()
        runSafely(function()
            hs.eventtap.keyStroke(mods, key, KEY_PRESS_USEC)
        end)
    end)
end

local browserShortcuts = {
    ["com.apple.Safari"] = {
        next = {{"ctrl"}, "tab"}, previous = {{"ctrl", "shift"}, "tab"},
    },
    ["com.google.Chrome"] = {
        next = {{"cmd", "alt"}, "right"}, previous = {{"cmd", "alt"}, "left"},
    },
    ["org.mozilla.firefox"] = {
        next = {{"cmd", "alt"}, "right"}, previous = {{"cmd", "alt"}, "left"},
    },
    ["com.brave.Browser"] = {
        next = {{"cmd", "alt"}, "right"}, previous = {{"cmd", "alt"}, "left"},
    },
    ["com.microsoft.edgemac"] = {
        next = {{"cmd"}, "pagedown"}, previous = {{"cmd"}, "pageup"},
    },
}

-- Vivaldi's AppleScript `tabs` includes other workspaces. Its native Tabs
-- accessibility group lists only tabs visible in the current workspace, in
-- display order. Every button's AXDOMIdentifier is `tab-<AppleScript id>`.
-- Read that group only; activate the chosen ID through AppleScript. This also
-- handles duplicate titles and non-contiguous AppleScript tab indices.
local function vivaldiVisibleIDs()
    local win = hs.window.focusedWindow()
    if not win or not win:application()
        or win:application():bundleID() ~= "com.vivaldi.Vivaldi" then
        return nil, "window"
    end
    local root = hs.axuielement.windowElement(win)
    if not root then return nil, "accessibility-window" end
    local tabGroup
    local function findTabs(element, depth)
        if not element or tabGroup or depth > 30 then return end
        if element:attributeValue("AXRole") == "AXTabGroup"
            and element:attributeValue("AXTitle") == "Tabs" then
            tabGroup = element
            return
        end
        for _, child in ipairs(element:attributeValue("AXChildren") or {}) do
            findTabs(child, depth + 1)
            if tabGroup then return end
        end
    end
    findTabs(root, 0)
    if not tabGroup then return nil, "tab-group" end
    local tabs = tabGroup:attributeValue("AXTabs") or {}
    if #tabs < 2 then return nil, "too-few-tabs" end
    local ids, seen, selectedCount = {}, {}, 0
    for _, tab in ipairs(tabs) do
        local domID = tab:attributeValue("AXDOMIdentifier")
        local id = type(domID) == "string" and domID:match("^tab%-(%d+)$")
        if not id or seen[id] then return nil, "ambiguous-tab-id" end
        seen[id] = true
        ids[#ids + 1] = id
        if tab:attributeValue("AXSelected") == true then
            selectedCount = selectedCount + 1
        end
    end
    if selectedCount ~= 1 then return nil, "selected-tab" end
    return ids
end

local function vivaldiTabScript(visibleIDs, direction)
    local quoted = {}
    for i, id in ipairs(visibleIDs) do quoted[i] = '"' .. id .. '"' end
    local delta = direction > 0 and 1 or -1
    return string.format([[
tell application id "com.vivaldi.Vivaldi"
    if not (exists front window) then return "window"
    tell front window
        set visibleIDs to {%s}
        set currentID to ((id of active tab) as text)
        set currentPosition to 0
        repeat with i from 1 to count of visibleIDs
            if (item i of visibleIDs) is currentID then
                set currentPosition to i
                exit repeat
            end if
        end repeat
        if currentPosition is 0 then return "stale-visible-tabs"
        set targetPosition to currentPosition + (%d)
        if targetPosition > (count of visibleIDs) then set targetPosition to 1
        if targetPosition < 1 then set targetPosition to (count of visibleIDs)
        set targetID to item targetPosition of visibleIDs
        set allIDs to id of tabs
        repeat with i from 1 to count of allIDs
            if ((item i of allIDs) as text) is targetID then
                set active tab index to i
                if ((id of active tab) as text) is targetID then return "switched"
                return "activation-failed"
            end if
        end repeat
        return "missing-tab-id"
    end tell
end tell]], table.concat(quoted, ", "), delta)
end

local function sendTabShortcut(bundle, direction)
    local mapping = browserShortcuts[bundle]
        or browserShortcuts["com.apple.Safari"]
    local chord = direction > 0 and mapping.next or mapping.previous
    sendShortcut(chord[1], chord[2])
end

local function flushTabStep(generation)
    if generation ~= tabQueueGeneration then return end
    local step = table.remove(pendingTabSteps, 1)
    if not step then
        tabWorkScheduled = false
        return
    end

    local foreground = hs.application.frontmostApplication()
    if foreground and foreground:bundleID() == step.bundle then
        if step.bundle == "com.vivaldi.Vivaldi" then
            local ids, reason = vivaldiVisibleIDs()
            if not ids then
                note("tab-vivaldi-skip:" .. reason)
            else
                local ok, result = hs.osascript.applescript(
                    vivaldiTabScript(ids, step.direction))
                if ok and result == "switched" then
                    note("tab-vivaldi-switched")
                else
                    note("tab-vivaldi-skip:" .. (ok and tostring(result) or "script-error"))
                end
            end
        else
            sendTabShortcut(step.bundle, step.direction)
        end
    end

    if #pendingTabSteps > 0 then
        hs.timer.doAfter(0, function()
            runSafely(function() flushTabStep(generation) end)
        end)
    else
        tabWorkScheduled = false
    end
end

local function switchTab(nextTab)
    local app = hs.application.frontmostApplication()
    local bundle = app and app:bundleID() or ""
    pendingTabSteps[#pendingTabSteps + 1] = {
        bundle = bundle, direction = nextTab and 1 or -1,
    }
    if tabWorkScheduled then return end
    tabWorkScheduled = true
    local generation = tabQueueGeneration
    hs.timer.doAfter(0, function()
        runSafely(function() flushTabStep(generation) end)
    end)
end

local function clickAction(key)
    if windowNav or windowWorkScheduled or #pendingWindowActions > 0 then
        queueWindowAction({kind = "click", key = key})
    else
        sendShortcut({"cmd"}, key)
    end
end

local function dispatch(action)
    note(action)
    if action == ACTION.thumbWheelUp then
        switchTab(true)
    elseif action == ACTION.thumbWheelDown then
        switchTab(false)
    elseif action == ACTION.thumbLeft then
        sendShortcut({"cmd"}, "w")
    elseif action == ACTION.thumbRight then
        sendShortcut({"cmd"}, "t")
    elseif action == ACTION.thirdWheelUp then
        queueWindowAction({kind = "step", direction = -1})
    elseif action == ACTION.thirdWheelDown then
        queueWindowAction({kind = "step", direction = 1})
    elseif action == ACTION.thirdCopy then
        clickAction("c")
    elseif action == ACTION.thirdPaste then
        clickAction("v")
    elseif action == ACTION.thirdSelectAll then
        clickAction("a")
    elseif action == ACTION.thirdRelease then
        queueWindowAction({kind = "release"})
    end
end

local keyWatcher = hs.eventtap.new({types.keyDown, types.keyUp}, function(e)
    if e:getKeyCode() ~= F15 then return false end
    local marker = e:getProperty(fields.eventSourceUserData) or 0
    local action = marker - TAG_BASE
    if action < 1 or action > 10 then return false end
    lastTaggedSourcePID = e:getProperty(fields.eventSourceUnixProcessID)
    if not helperPID or lastTaggedSourcePID ~= helperPID then return false end
    if e:getType() == types.keyDown and receiverHealthy then
        local ok, err = pcall(dispatch, action)
        if not ok then receiverFailed(err) end
    end
    return true
end)
keyWatcher:start()

mx4 = {
    status = function()
        return {
            accessibility = hs.accessibilityState(),
            secureInput = hs.eventtap.isSecureInputEnabled(),
            receiverEnabled = keyWatcher:isEnabled() and receiverHealthy,
            tapEnabled = keyWatcher:isEnabled(),
            receiverHealthy = receiverHealthy,
            receiverError = receiverError,
            navigating = windowNav ~= nil,
            helperPID = helperPID,
            lastTaggedSourcePID = lastTaggedSourcePID,
        }
    end,
    trace = function() return trace end,
    clearTrace = function() trace = {} end,
    reset = function()
        clearNavigation()
        clearTabSteps()
    end,
    setHelperPID = function(pid)
        if pid == nil then
            helperPID = nil
            return true
        end
        if type(pid) ~= "number" or pid <= 0 or pid % 1 ~= 0 then
            return false
        end
        helperPID = pid
        return true
    end,
}

-- Receiver errors and missing permissions are reported through mx4.status().
