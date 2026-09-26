-- Pure Lua simulation. It loads the candidate with a mocked Hammerspoon API;
-- no real app, input event, or AltTab CLI command is touched.
local realHs = hs
local source = debug.getinfo(1, "S").source:sub(2)
local candidate = source:gsub("tests/test%-mx4%-alttab%.lua$", "hammerspoon/mx4-safe-init.lua")

local function harness(native)
    local queue, commands, shortcuts = {}, {}, {}
    local now = 1
    local directedKeys = {}
    local model = {visible = false, selected = nil, focused = 0, windows = {
        {index = 0, wid = 101, pid = 201, title = "One"},
        {index = 1, wid = 102, pid = 202, title = "Two"},
        {index = 2, wid = 103, pid = 203, title = "Three"},
    }}
    model.altTabRunning = not native
    local watcher
    local modifiers = {}
    local nativeKeys = {}
    local buttons = {}
    for i, window in ipairs(model.windows) do
        buttons[i] = {attributeValue = function(_, attribute)
            if attribute == "AXTitle" then return window.title end
        end}
    end
    local list = {
        attributeValue = function(_, attribute)
            if attribute == "AXSubrole" then return "AXProcessSwitcherList" end
            if attribute == "AXChildren" then return buttons end
            if attribute == "AXSelectedChildren" then
                return model.nativeVisible and {buttons[model.selected + 1]} or {}
            end
        end,
        isAttributeSettable = function(_, attribute) return attribute == "AXSelectedChildren" end,
        setAttributeValue = function(_, attribute, value)
            assert(attribute == "AXSelectedChildren")
            if model.failNativeSelection then return nil end
            for i, button in ipairs(buttons) do
                if value[1] == button then model.selected = i - 1; return true end
            end
            error("Unknown native selection")
        end,
        performAction = function(_, action)
            if action == "AXConfirm" then
                if model.failNativeConfirm then return nil end
                model.focused = model.selected
                if model.delayNativeConfirm then return true end
            else assert(action == "AXCancel") end
            model.nativeVisible = false
            return true
        end,
    }
    local function enqueue(delay, fn) queue[#queue + 1] = {at = now + delay, fn = fn} end
    local mock = {
        keycodes = {map = {f15 = 113}},
        timer = {
            secondsSinceEpoch = function() return now end,
            doAfter = function(delay, fn)
                enqueue(delay, fn)
                return {stop = function() end}
            end,
        },
        json = realHs.json,
        accessibilityState = function() return true end,
        execute = function(line)
            local command = line:match("'%s*(%-%-[%w%-=]+)%s*$")
            assert(command, "Unexpected shell command " .. tostring(line))
            commands[#commands + 1] = command
            local output = ""
            if command == "--qa-state" then
                local windows, tiles = {}, {}
                for i, w in ipairs(model.windows) do
                    windows[i] = {index = w.index, wid = w.wid, pid = w.pid,
                        focused = i - 1 == model.focused, shown = true}
                    if model.visible then tiles[i] = {index = w.index, wid = w.wid} end
                end
                output = realHs.json.encode({switcherVisible = model.visible,
                    selectedIndex = model.selected, windows = windows, tiles = tiles})
            elseif command == "--show=0" then
                if model.visible then model.selected = (model.selected + 1) % #model.windows
                else model.visible = true; model.selected = 1 end
                if model.failNextShow then
                    model.failNextShow = false
                    return "", nil, "exit", 1
                end
            elseif command == "--hide" then
                model.visible = false
                model.selected = nil
            else
                local wid = tonumber(command:match("^%-%-focus=(%d+)$"))
                assert(wid, "Unexpected command " .. command)
                for i, w in ipairs(model.windows) do
                    if w.wid == wid then model.focused = i - 1 end
                end
            end
            return output, true, "exit", 0
        end,
        eventtap = {
            event = {types = {keyDown = 1, keyUp = 2, scrollWheel = 3,
                             leftMouseDown = 4, rightMouseDown = 5, otherMouseDown = 6},
                     properties = {eventSourceUserData = "marker", eventSourceUnixProcessID = "pid"},
                     newEvent = function()
                         local blank = {}
                         function blank:setType(kind) assert(kind == 0); return self end
                         function blank:setFlags(flags) assert(next(flags) == nil); return self end
                         function blank:post() modifiers = {}; nativeKeys[#nativeKeys + 1] = "null" end
                         return blank
                     end,
                     newKeyEvent = function(mods, key, down)
                         assert(type(mods) == "table", "Must never press a modifier key")
                         return {post = function(_, app)
                             if not app then
                                 assert(key == "tab", "Only native opening may post a global key")
                                 assert(mods[1] == "cmd")
                                 nativeKeys[#nativeKeys + 1] = key
                                 modifiers = {cmd = true}
                                 if down and not model.dropNativeOpen then
                                     model.nativeVisible = true
                                     model.selected = mods[2] == "shift" and #model.windows - 1 or 1
                                 end
                                 return
                             end
                             assert(key == "left")
                             assert(app.alttab)
                             directedKeys[#directedKeys + 1] = {key = key, down = down}
                             if down and not model.dropDirectedKeys and model.visible then
                                 model.selected = (model.selected - 1 + #model.windows) % #model.windows
                             end
                         end}
                     end},
            new = function(types, fn)
                assert(#types == 6 and types[1] == 1 and types[2] == 2)
                watcher = {callback = fn, start = function() end, isEnabled = function() return true end}
                return watcher
            end,
            isSecureInputEnabled = function() return false end,
            checkKeyboardModifiers = function() return model.physicalModifiers or modifiers end,
            keyStroke = function(mods, key)
                shortcuts[#shortcuts + 1] = table.concat(mods, "+") .. "+" .. key
            end,
        },
        application = {
            frontmostApplication = function()
                return {
                    pid = function() return model.windows[model.focused + 1].pid end,
                    bundleID = function() return "test" end,
                    focusedWindow = function()
                        return {id = function() return model.windows[model.focused + 1].wid end}
                    end,
                }
            end,
            get = function(pid)
                if pid == "com.lwouis.alt-tab-macos" then
                    if not model.altTabRunning then return nil end
                    return {alttab = true, path = function() return "/Other Apps/AltTab.app" end}
                end
                if pid == "com.apple.dock" then return {dock = true} end
                for _, w in ipairs(model.windows) do
                    if w.pid == pid then
                        return {focusedWindow = function()
                            return {id = function() return w.wid end}
                        end}
                    end
                end
                return nil
            end,
            runningApplications = function()
                local apps = {}
                for i, w in ipairs(model.windows) do
                    apps[i] = {name = function() return w.title end, pid = function() return w.pid end}
                end
                return apps
            end,
        },
        axuielement = {applicationElement = function(app)
            assert(app.dock)
            return {attributeValue = function(_, attribute)
                assert(attribute == "AXChildren")
                return model.nativeVisible and {list} or {}
            end}
        end},
        window = {
            focusedWindow = function()
                return {id = function() return model.windows[model.focused + 1].wid end}
            end,
        },
    }
    local env = setmetatable({hs = mock, require = function() end}, {__index = _G})
    assert(loadfile(candidate, "t", env))()
    assert(env.mx4.setHelperPID(42))
    local function pump(limit)
        local n = 0
        while #queue > 0 do
            n = n + 1
            assert(n < 1000, "Queue did not drain")
            table.sort(queue, function(a, b) return a.at < b.at end)
            local item = table.remove(queue, 1)
            now = item.at
            item.fn()
            if limit and n >= limit then break end
        end
        local status = env.mx4.status()
        assert(status.receiverHealthy, tostring(status.receiverError))
    end
    local function emit(action, defer)
        local event = {
            getKeyCode = function() return 113 end,
            getType = function() return 1 end,
            getProperty = function(_, field)
                if field == "marker" then return 0x4D5800 + action end
                if field == "pid" then return 42 end
                return nil
            end,
        }
        assert(watcher.callback(event) == true)
        if not defer then pump() end
    end
    local function pointer(kind)
        -- No setter/getKeyCode is provided: this event must be passed through
        -- without inspection of its payload or any replacement/suppression.
        local original = {getType = function() return kind or 3 end}
        assert(watcher.callback(original) == false)
        pump()
    end
    return model, commands, shortcuts, directedKeys, emit, env.mx4, nativeKeys, pump, pointer
end

do
    local model, commands, _, _, emit = harness()
    emit(6)
    assert(model.visible and model.selected == 1)
    emit(10)
    assert(not model.visible and model.focused == 1)
    assert(commands[#commands] == "--focus=102")
end

do
    local model, commands, _, directed, emit = harness()
    emit(5)
    assert(model.visible and model.selected == 2)
    assert(#directed == 4) -- first reverse crosses the initially selected tile
    local shows = 0
    for _, command in ipairs(commands) do
        if command == "--show=0" then shows = shows + 1 end
    end
    assert(shows == 1) -- no forward traversal for a reverse step
    emit(10)
    assert(not model.visible and model.focused == 2)
    assert(commands[#commands] == "--focus=103")
end

do
    local model, _, _, directed, emit = harness()
    emit(6)
    emit(5)
    assert(model.visible and model.selected == 0)
    assert(#directed == 2) -- subsequent reverse is exactly one left arrow
    emit(10)
    assert(model.focused == 0)
end

do
    local model, _, shortcuts, _, emit = harness()
    emit(6)
    emit(7)
    assert(model.focused == 1)
    assert(shortcuts[1] == "cmd+c")
end

do
    local model, commands, _, _, emit = harness()
    model.visible = true -- A physical keyboard opened AltTab first.
    model.selected = 1
    emit(6)
    emit(10)
    assert(model.visible and model.selected == 1)
    assert(#commands == 1 and commands[1] == "--qa-state")
end

do
    local model, commands, _, _, emit = harness()
    emit(6)
    model.focused = 2 -- An unrelated trackpad click focused a different window.
    emit(10)
    assert(not model.visible and model.focused == 2)
    assert(commands[#commands] == "--hide")
end

do
    local model, commands, _, _, emit = harness()
    model.failNextShow = true -- AltTab accepted show, but its CLI reported failure.
    emit(6)
    assert(not model.visible)
    assert(commands[#commands] == "--hide")
end

do
    local model, commands, _, directed, emit = harness()
    model.dropDirectedKeys = true
    emit(5)
    assert(#directed == 4)
    assert(not model.visible and model.focused == 0)
    assert(commands[#commands] == "--hide")
end

do
    local model, commands, _, _, emit, receiver, keys = harness(true)
    emit(6)
    assert(model.nativeVisible and model.selected == 1)
    assert(#commands == 0 and #keys == 3 and keys[3] == "null")
    assert(receiver.status().windowBackend == "macos")
    emit(5)
    assert(model.nativeVisible and model.selected == 0)
    emit(5)
    assert(model.selected == 2 and #keys == 3) -- AX selection, no extra keyboard events
    emit(10)
    assert(not model.nativeVisible and model.focused == 2)
end

do
    local model, _, shortcuts, _, emit = harness(true)
    emit(5)
    assert(model.selected == 2)
    emit(7)
    assert(not model.nativeVisible and model.focused == 2)
    assert(shortcuts[1] == "cmd+c")
end

do
    local model, _, _, _, emit, _, keys = harness(true)
    model.nativeVisible, model.selected = true, 1 -- Keyboard-owned UI
    emit(6)
    emit(10)
    assert(model.nativeVisible and model.selected == 1 and #keys == 0)
end

do
    local model, _, _, _, emit, _, keys = harness(true)
    model.physicalModifiers = {cmd = true}
    emit(6)
    emit(10)
    assert(not model.nativeVisible and #keys == 0)
end

do
    local model, _, _, _, emit = harness(true)
    emit(6)
    model.focused = 2 -- A trackpad click changed foreground
    emit(10)
    assert(not model.nativeVisible and model.focused == 2)
end

do
    local model, _, _, _, emit, receiver = harness(true)
    emit(6)
    receiver.reset()
    assert(not model.nativeVisible and not receiver.status().navigating)
    emit(10)
    assert(model.focused == 0)
end

do
    local model, _, _, _, emit, receiver = harness(true)
    model.dropNativeOpen = true
    emit(6)
    assert(not receiver.status().navigating)
    assert(receiver.status().switcherError == "macos-switcher-unavailable")
end

do
    local model, _, _, _, emit, receiver = harness(true)
    emit(6)
    model.failNativeSelection = true
    emit(5)
    assert(not model.nativeVisible and model.focused == 0)
    assert(receiver.status().switcherError == "macos-selection-failed")
end

do
    local model, _, _, _, emit, receiver = harness(true)
    emit(6)
    model.failNativeConfirm = true
    emit(10)
    assert(not model.nativeVisible and model.focused == 0)
    assert(receiver.status().switcherError == "macos-confirm-failed")
end

do
    local model, _, _, _, emit, receiver = harness(true)
    emit(6)
    emit(10)
    model.altTabRunning = true
    emit(6)
    assert(receiver.status().windowBackend == "alttab" and model.visible)
    emit(10)
    model.altTabRunning = false
    emit(5)
    assert(receiver.status().windowBackend == "macos" and model.nativeVisible)
    emit(10)
end

do
    local model, _, _, _, emit = harness(true)
    model.physicalModifiers = {capslock = true}
    emit(6)
    assert(model.nativeVisible)
    emit(10)
    assert(not model.nativeVisible)
end

do
    local model, _, _, _, emit, receiver, _, pump = harness(true)
    emit(6, true)
    pump(1) -- Opening was posted; Accessibility has not been adopted yet.
    receiver.reset()
    emit(6, true) -- A fresh hold cannot steal the pending opening.
    pump()
    receiver.reset()
    pump()
    assert(not model.nativeVisible)
end

do
    local model, _, _, _, emit, receiver, _, pump = harness(true)
    emit(6)
    model.delayNativeConfirm = true
    emit(10, true)
    pump(1) -- Confirmation is in flight, but its UI is still visible.
    receiver.reset()
    pump()
    assert(not model.nativeVisible)
end

do
    local model, _, _, _, emit, _, keys, _, pointer = harness(true)
    emit(6)
    pointer() -- Trackpad scroll must cancel, not navigate or select.
    assert(not model.nativeVisible and model.focused == 0)
    emit(5) -- Ignore the interrupted hold until release, including momentum.
    assert(not model.nativeVisible and #keys == 3)
    emit(10)
    emit(6)
    assert(model.nativeVisible)
    emit(10)
    assert(model.focused == 1)
end

do
    local model, _, _, _, emit, _, _, _, pointer = harness(true)
    emit(6)
    pointer(4) -- Trackpad/other-device click also passes through.
    assert(not model.nativeVisible and model.focused == 0)
    emit(10)
end

do
    local model, _, _, _, _, _, _, _, pointer = harness(true)
    model.nativeVisible, model.selected = true, 1 -- Keyboard-owned switcher
    pointer()
    assert(model.nativeVisible and model.selected == 1)
end

do
    local model, _, _, _, emit, _, _, _, pointer = harness(false)
    emit(6)
    pointer()
    assert(model.visible and model.selected == 1) -- AltTab retains existing behavior
    emit(10)
end

do
    local model, _, _, _, emit, _, _, _, pointer = harness(true)
    emit(6)
    emit(10, true) -- Physical release arrived, but its commit is still queued.
    pointer()
    assert(not model.nativeVisible and model.focused == 0)
    emit(6) -- The next hold must work without needing a redundant release.
    assert(model.nativeVisible)
    emit(10)
end

return "26 offline MX switcher simulations passed (9 AltTab, 17 native/detection)"
