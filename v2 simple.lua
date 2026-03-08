local config = {
    appName = "qBittorrent",  -- or bundleID
    requireAC = true,
    requireNetwork = true,  -- any network
    logging = true,
}

local state = {
    lastShouldRun = nil,
    lastRunning = nil,
}

local function log(message)
    if not config.logging then
        return
    end
    print(string.format("[%s] [v2-simple] %s", os.date("%H:%M:%S"), tostring(message)))
end

local function shouldRun()
    if config.requireAC and hs.battery.powerSource() ~= "AC Power" then
        return false, "Requires AC power"
    end

    if config.requireNetwork then
        local reachable = hs.network.reachability.internet()
        local flags = hs.network.reachability.flags or {}
        local reachableFlag = flags.reachable
        if (not reachable) or type(reachableFlag) ~= "number" then
            return false, "Internet reachability unavailable"
        end

        local status = reachable:status()
        if (status & reachableFlag) == 0 then
            return false, "No internet reachability"
        end
    end

    return true, "All conditions satisfied"
end

local function manageApp(trigger)
    trigger = trigger or "manual"

    local app = hs.application.get(config.appName)
    local running = app ~= nil
    local should, reason = shouldRun()

    if should ~= state.lastShouldRun or running ~= state.lastRunning then
        log(string.format(
            "trigger=%s shouldRun=%s running=%s reason=%s",
            trigger,
            tostring(should),
            tostring(running),
            tostring(reason)
        ))
    end

    if should and not running then
        log("Launching " .. config.appName)
        hs.application.launchOrFocus(config.appName)
    elseif not should and running then
        log("Stopping " .. config.appName)
        app:kill()
    end

    state.lastShouldRun = should
    state.lastRunning = running
end

hs.battery.watcher.new(function()
    manageApp("battery")
end):start()

local reachabilityWatcher = hs.network.reachability.internet()
if reachabilityWatcher and reachabilityWatcher.setCallback then
    reachabilityWatcher:setCallback(function()
        manageApp("reachability")
    end):start()
else
    log("Network reachability watcher unavailable; relying on timer + battery watcher")
end

hs.timer.doEvery(60, function()  -- safety check
    manageApp("timer")
end)

manageApp("startup")  -- initial check
