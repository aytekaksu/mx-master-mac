-- Pure Lua simulation. It loads the candidate with a mocked Hammerspoon API;
-- no real app, input event, or AltTab CLI command is touched.
local realHs = hs
local source = debug.getinfo(1, "S").source:sub(2)
local candidate = source:gsub("tests/test%-mx4%-alttab%.lua$", "hammerspoon/mx4-safe-init.lua")

local function harness()
    local queue, commands, shortcuts = {}, {}, {}
    local now = 1
    local directedKeys = {}
    local model = {visible = false, selected = nil, focused = 0, windows = {
        {index = 0, wid = 101, pid = 201, title = "One"},
        {index = 1, wid = 102, pid = 202, title = "Two"},
        {index = 2, wid = 103, pid = 203, title = "Three"},
    }}
    local watcher
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
            local command = line:match('"%s*(%-%-[%w%-=]+)%s*$')
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
            event = {types = {keyDown = 1, keyUp = 2},
                     properties = {eventSourceUserData = "marker", eventSourceUnixProcessID = "pid"},
                     newKeyEvent = function(_, key, down)
                         assert(key == "left")
                         return {post = function(_, app)
                             assert(app.alttab)
                             directedKeys[#directedKeys + 1] = {key = key, down = down}
                             if down and not model.dropDirectedKeys and model.visible then
                                 model.selected = (model.selected - 1 + #model.windows) % #model.windows
                             end
                         end}
                     end},
            new = function(types, fn)
                assert(#types == 2 and types[1] == 1 and types[2] == 2)
                watcher = {callback = fn, start = function() end, isEnabled = function() return true end}
                return watcher
            end,
            isSecureInputEnabled = function() return false end,
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
                if pid == "com.lwouis.alt-tab-macos" then return {alttab = true} end
                for _, w in ipairs(model.windows) do
                    if w.pid == pid then
                        return {focusedWindow = function()
                            return {id = function() return w.wid end}
                        end}
                    end
                end
                return nil
            end,
        },
        window = {
            focusedWindow = function()
                return {id = function() return model.windows[model.focused + 1].wid end}
            end,
        },
    }
    local env = setmetatable({hs = mock, require = function() end}, {__index = _G})
    assert(loadfile(candidate, "t", env))()
    assert(env.mx4.setHelperPID(42))
    local function pump()
        local n = 0
        while #queue > 0 do
            n = n + 1
            assert(n < 1000, "Queue did not drain")
            table.sort(queue, function(a, b) return a.at < b.at end)
            local item = table.remove(queue, 1)
            now = item.at
            item.fn()
        end
        local status = env.mx4.status()
        assert(status.receiverHealthy, tostring(status.receiverError))
    end
    local function emit(action)
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
        pump()
    end
    return model, commands, shortcuts, directedKeys, emit
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

return "eight offline MX to AltTab simulations passed"
