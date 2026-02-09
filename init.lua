-- User Configuration
-- Tip: set either target.bundleID or target.appName (or both).
-- You can disable the menu bar item with config.menuBar.enabled = false.
-- Most menu toggles are session-only; setup changes from menu are persisted.
local config = {
    target = {
        bundleID = "", -- Preferred app identifier (bundle ID). Leave empty to use appName only.
        appName = "", -- Optional app display name fallback when bundleID is empty.
    },
    rules = {
        requiredPowerSource = "AC Power", -- Empty string disables power check. Use "AC Power" to require plugged-in.
        requiredWiFi = "", -- Empty string allows any Wi-Fi. Set SSID name to restrict.
        requireEthernetOnly = false, -- When true, only active Ethernet can satisfy network rules.
        allowEthernetFallback = true, -- When true, allow active Ethernet to satisfy network rules.
        requireEthernetDefaultRouteMatch = false, -- When true, Ethernet must also own the default route.
    },
    behavior = {
        automationEnabled = true, -- Master on/off switch for automation logic.
        lockAutomationToggle = false, -- Prevent disabling automation from the menu when true.
        debug = false, -- Enables verbose logging to the Hammerspoon console.
        logToFile = false, -- When true, append debug logs to behavior.logPath.
        logPath = "~/.hammerspoon/app-manager.log", -- File path for optional debug log output.
        logMaxBytes = 524288, -- Rotate log file when it reaches this size (0 disables rotation).
        debounceSeconds = 1, -- Collapse rapid events into a single evaluation.
        wakeDelaySeconds = 2, -- Delay after wake before re-checking conditions.
        enforceIntervalSeconds = 300, -- Periodic safety check interval in seconds (0 disables periodic enforcement).
        networkCacheTTLSeconds = 6, -- Reuse Wi-Fi/Ethernet checks during rapid event bursts.
        minActionGapSeconds = 8, -- Minimum seconds between launch/quit actions.
        gracefulQuitTimeoutSeconds = 8, -- Time to wait before forcing quit.
    },
    menuBar = {
        enabled = true, -- Show or hide the menu bar status item.
        titlePrefix = "ツ", -- Short label prefix for the menu bar title (ASCII recommended).
        showConfigSection = true, -- Show the configuration summary in the menu.
        showAllConfigValues = true, -- When true, show every config key/value in the Configuration submenu.
        showQuickActions = true, -- Show quick action items (re-check, automation on/off).
        showStateText = true, -- Show ON/OFF/WAIT/BLOCK state text in the menu bar title.
    },
}

local state = {
    lastDecision = nil,
    lastReason = nil,
    lastActionAt = 0,
    pendingEvaluation = nil,
    currentWiFi = nil,
    activeEthernet = nil,
    cachedWiFi = nil,
    cachedEthernetActive = nil,
    cachedEthernetInterface = nil,
    cachedNetworkCheckedAt = nil,
    cachedDefaultRouteInterface = nil,
    cachedDefaultRouteCheckedAt = nil,
    powerSourceConfigWarning = nil,
    lastTrigger = "startup",
    lastEvaluationAt = nil,
    lastError = nil,
    appRunning = nil,
    lastKnownTargetPID = nil,
    pendingForcedQuit = nil,
    pendingForcedQuitPID = nil,
    menuBar = nil,
    watchers = {},
    watcherRunning = {},
    timers = {},
    periodicEnforcerRunning = false,
}

local manageApp
local scheduleEvaluation
local updateMenuBar
local refreshRuntimeHooks
local TARGET_SETTINGS_KEY = "autoManagedApp.target"
local RUNTIME_CLEANUP_KEY = "__autoManagedAppRuntimeCleanup"

local previousRuntimeCleanup = rawget(_G, RUNTIME_CLEANUP_KEY)
if type(previousRuntimeCleanup) == "function" then
    pcall(previousRuntimeCleanup)
end

local function trim(value)
    if type(value) ~= "string" then
        return ""
    end
    return value:match("^%s*(.-)%s*$")
end

local SCRIPT_SETUP_DEFAULTS = {
    bundleID = trim(config.target.bundleID),
    appName = trim(config.target.appName),
    requiredWiFi = trim(config.rules.requiredWiFi),
}

local function toNumber(value, fallback, minimum)
    local n = tonumber(value)
    if not n then
        n = fallback
    end
    if minimum ~= nil and n < minimum then
        n = minimum
    end
    return n
end

local KNOWN_POWER_SOURCE_MAP = {
    ["ac power"] = "AC Power",
    ["battery power"] = "Battery Power",
    ["ups power"] = "UPS Power",
}

local function normalizePowerSourceLabel(value)
    local normalized = trim(value)
    if normalized == "" then
        return ""
    end

    local canonical = KNOWN_POWER_SOURCE_MAP[normalized:lower()]
    return canonical or normalized
end

local function isKnownPowerSourceLabel(value)
    if trim(value) == "" then
        return true
    end
    return KNOWN_POWER_SOURCE_MAP[trim(value):lower()] ~= nil
end

local function boolText(value)
    if value == nil then
        return "unknown"
    end
    return value and "yes" or "no"
end

local function appScriptEscape(value)
    return (value or ""):gsub("\\", "\\\\"):gsub('"', '\\"')
end

local function isLikelyBundleID(value)
    local bundleID = trim(value)
    if bundleID == "" then
        return false
    end
    if not bundleID:match("^[%w%._%-]+$") then
        return false
    end
    if not bundleID:match("%.") then
        return false
    end
    return true
end

local function targetBundleID()
    return trim(config.target.bundleID)
end

local function targetAppName()
    local appName = trim(config.target.appName)
    return appName
end

local function targetDisplayName()
    local appName = targetAppName()
    local bundleID = targetBundleID()

    if appName ~= "" then
        return appName
    end
    if bundleID ~= "" then
        return bundleID
    end
    return "Configured App"
end

local function targetIdentityLabel()
    local appName = targetAppName()
    local bundleID = targetBundleID()

    if appName ~= "" and bundleID ~= "" then
        return string.format("%s (%s)", appName, bundleID)
    end
    if appName ~= "" then
        return appName
    end
    if bundleID ~= "" then
        return bundleID
    end
    return "not configured"
end

local function isBundleIDResolvable(bundleID)
    bundleID = trim(bundleID)
    if bundleID == "" or (not isLikelyBundleID(bundleID)) then
        return false
    end

    if hs.application and hs.application.pathForBundleID then
        local ok, appPath = pcall(function()
            return hs.application.pathForBundleID(bundleID)
        end)
        if ok and type(appPath) == "string" and appPath ~= "" then
            return true
        end
    end

    return false
end

local function isAppNameResolvable(appName)
    appName = trim(appName)
    if appName == "" then
        return false, nil
    end

    if hs.osascript and hs.osascript.applescript then
        local script = 'id of application "' .. appScriptEscape(appName) .. '"'
        local ok, result = hs.osascript.applescript(script)
        if ok and type(result) == "string" and result ~= "" then
            return true, result
        end
    end

    return false, nil
end

local function persistSetupConfig()
    if not hs.settings or not hs.settings.set then
        return
    end

    hs.settings.set(TARGET_SETTINGS_KEY, {
        bundleID = targetBundleID(),
        appName = targetAppName(),
        requiredWiFi = trim(config.rules.requiredWiFi),
    })
end

local function loadPersistedSetupConfig()
    if not hs.settings or not hs.settings.get then
        return
    end

    local saved = hs.settings.get(TARGET_SETTINGS_KEY)
    if type(saved) ~= "table" then
        return
    end

    if type(saved.bundleID) == "string" then
        config.target.bundleID = trim(saved.bundleID)
    end
    if type(saved.appName) == "string" then
        config.target.appName = trim(saved.appName)
    end
    if type(saved.requiredWiFi) == "string" then
        config.rules.requiredWiFi = trim(saved.requiredWiFi)
    end
end

local function hasSavedSetupOverrides()
    if not hs.settings or not hs.settings.get then
        return false
    end

    local saved = hs.settings.get(TARGET_SETTINGS_KEY)
    if type(saved) ~= "table" then
        return false
    end

    local savedBundleID = type(saved.bundleID) == "string" and trim(saved.bundleID) or SCRIPT_SETUP_DEFAULTS.bundleID
    local savedAppName = type(saved.appName) == "string" and trim(saved.appName) or SCRIPT_SETUP_DEFAULTS.appName
    local savedRequiredWiFi = type(saved.requiredWiFi) == "string" and trim(saved.requiredWiFi) or SCRIPT_SETUP_DEFAULTS.requiredWiFi

    return savedBundleID ~= SCRIPT_SETUP_DEFAULTS.bundleID
        or savedAppName ~= SCRIPT_SETUP_DEFAULTS.appName
        or savedRequiredWiFi ~= SCRIPT_SETUP_DEFAULTS.requiredWiFi
end

local function ensureParentDirectory(path)
    if type(path) ~= "string" or path == "" then
        return false, "empty log path"
    end

    local dir = path:match("^(.*)/[^/]+$")
    if not dir or dir == "" then
        return true, nil
    end

    if hs.fs and hs.fs.attributes then
        local existing = hs.fs.attributes(dir)
        if existing and existing.mode == "directory" then
            return true, nil
        end
    end

    if hs.fs and hs.fs.mkdir and hs.fs.attributes then
        -- Newer builds may support recursive mkdir via second argument.
        local okRecursive = pcall(function()
            return hs.fs.mkdir(dir, true)
        end)
        if okRecursive then
            local recursiveAttrs = hs.fs.attributes(dir)
            if recursiveAttrs and recursiveAttrs.mode == "directory" then
                return true, nil
            end
        end
    end

    if hs.fs and hs.fs.mkdir and hs.fs.attributes then
        local prefix = (dir:sub(1, 1) == "/") and "/" or ""
        local current = prefix
        for segment in dir:gmatch("[^/]+") do
            if current == "" then
                current = segment
            elseif current == "/" then
                current = "/" .. segment
            else
                current = current .. "/" .. segment
            end

            local attrs = hs.fs.attributes(current)
            if not attrs then
                local ok, err = hs.fs.mkdir(current)
                if not ok then
                    return false, string.format("mkdir failed for %s: %s", current, tostring(err))
                end
            elseif attrs.mode ~= "directory" then
                return false, string.format("path exists but is not a directory: %s", current)
            end
        end

        local finalAttrs = hs.fs.attributes(dir)
        if finalAttrs and finalAttrs.mode == "directory" then
            return true, nil
        end
    end

    local ok, _, code = os.execute(string.format("mkdir -p %q", dir))
    if ok == true or code == 0 then
        return true, nil
    end

    return false, "unable to create log directory: " .. tostring(dir)
end

local function log(msg)
    local formatted = string.format("[%s] %s", os.date("%H:%M:%S"), tostring(msg))

    if config.behavior.debug then
        print(formatted)
    end

    if not config.behavior.logToFile then
        return
    end

    local path = trim(config.behavior.logPath or "")
    if path == "" then
        path = "~/.hammerspoon/app-manager.log"
    end

    if path:sub(1, 1) == "~" then
        local home = os.getenv("HOME")
        if home and home ~= "" then
            if path == "~" then
                path = home
            elseif path:sub(2, 2) == "/" then
                path = home .. path:sub(2)
            end
        end
    end

    local ready, readyErr = ensureParentDirectory(path)
    if not ready then
        print(string.format("[%s] Log file path setup failed: %s", os.date("%H:%M:%S"), tostring(readyErr)))
        return
    end

    local maxBytes = toNumber(config.behavior.logMaxBytes, 524288, 0)
    if maxBytes > 0 then
        local existing = io.open(path, "rb")
        if existing then
            local size = existing:seek("end") or 0
            existing:close()
            if size >= maxBytes then
                local backup = path .. ".1"
                os.remove(backup)
                if not os.rename(path, backup) then
                    local truncate = io.open(path, "w")
                    if truncate then
                        truncate:close()
                    end
                end
            end
        end
    end

    local handle, err = io.open(path, "a")
    if not handle then
        print(string.format("[%s] Log file write failed: %s", os.date("%H:%M:%S"), tostring(err)))
        return
    end

    handle:write(formatted .. "\n")
    handle:close()
end

local function notify(msg)
    print(string.format("[%s] %s", os.date("%H:%M:%S"), tostring(msg)))
end

local function showValidationAlert(message)
    local text = tostring(message)
    if hs.dialog and hs.dialog.blockAlert then
        local ok, err = pcall(function()
            hs.dialog.blockAlert("Target Validation", text, "OK", "")
        end)
        if ok then
            return
        end
        notify("Target Validation dialog failed: " .. tostring(err))
    end

    notify("Target Validation: " .. text)
end

local function validateAndNormalizeConfig()
    if type(config.target.bundleID) ~= "string" then
        config.target.bundleID = ""
    end
    if type(config.target.appName) ~= "string" then
        config.target.appName = ""
    end

    config.behavior.debounceSeconds = toNumber(config.behavior.debounceSeconds, 1, 0)
    config.behavior.wakeDelaySeconds = toNumber(config.behavior.wakeDelaySeconds, 2, 0)
    config.behavior.enforceIntervalSeconds = toNumber(config.behavior.enforceIntervalSeconds, 120, 0)
    config.behavior.networkCacheTTLSeconds = toNumber(config.behavior.networkCacheTTLSeconds, 6, 0)
    config.behavior.minActionGapSeconds = toNumber(config.behavior.minActionGapSeconds, 8, 0)
    config.behavior.gracefulQuitTimeoutSeconds = toNumber(config.behavior.gracefulQuitTimeoutSeconds, 8, 1)

    if type(config.behavior.automationEnabled) ~= "boolean" then
        config.behavior.automationEnabled = true
    end
    if type(config.behavior.lockAutomationToggle) ~= "boolean" then
        config.behavior.lockAutomationToggle = true
    end
    if type(config.behavior.debug) ~= "boolean" then
        config.behavior.debug = false
    end
    if type(config.behavior.logToFile) ~= "boolean" then
        config.behavior.logToFile = false
    end
    if type(config.behavior.logPath) ~= "string" or trim(config.behavior.logPath) == "" then
        config.behavior.logPath = "~/.hammerspoon/app-manager.log"
    end
    config.behavior.logMaxBytes = toNumber(config.behavior.logMaxBytes, 524288, 0)
    if type(config.rules.allowEthernetFallback) ~= "boolean" then
        config.rules.allowEthernetFallback = true
    end
    if type(config.rules.requireEthernetOnly) ~= "boolean" then
        config.rules.requireEthernetOnly = false
    end
    if type(config.rules.requireEthernetDefaultRouteMatch) ~= "boolean" then
        config.rules.requireEthernetDefaultRouteMatch = false
    end
    if type(config.rules.requiredPowerSource) ~= "string" then
        config.rules.requiredPowerSource = ""
    end
    config.rules.requiredPowerSource = normalizePowerSourceLabel(config.rules.requiredPowerSource)
    if (config.rules.requiredPowerSource ~= "") and (not isKnownPowerSourceLabel(config.rules.requiredPowerSource)) then
        state.powerSourceConfigWarning = string.format(
            "rules.requiredPowerSource '%s' is non-standard; expected AC Power, Battery Power, or UPS Power",
            tostring(config.rules.requiredPowerSource)
        )
        print(state.powerSourceConfigWarning)
    else
        state.powerSourceConfigWarning = nil
    end
    if type(config.rules.requiredWiFi) ~= "string" then
        config.rules.requiredWiFi = ""
    end

    if type(config.menuBar.enabled) ~= "boolean" then
        config.menuBar.enabled = true
    end
    if type(config.menuBar.showConfigSection) ~= "boolean" then
        config.menuBar.showConfigSection = true
    end
    if type(config.menuBar.showAllConfigValues) ~= "boolean" then
        config.menuBar.showAllConfigValues = true
    end
    if type(config.menuBar.showQuickActions) ~= "boolean" then
        config.menuBar.showQuickActions = true
    end
    if type(config.menuBar.showStateText) ~= "boolean" then
        config.menuBar.showStateText = true
    end
    if trim(config.menuBar.titlePrefix) == "" then
        config.menuBar.titlePrefix = "APP"
    end
end

local function safeRun(context, fn)
    local ok, err = xpcall(fn, debug.traceback)
    if ok then
        return true
    end

    state.lastError = string.format("%s failed: %s", context, tostring(err))
    print(state.lastError)
    notify("Automation error: " .. context)
    if updateMenuBar then
        updateMenuBar()
    end
    return false
end

local function applicationPID(app)
    if not app or not app.pid then
        return nil
    end

    local ok, pid = pcall(function()
        return app:pid()
    end)
    if ok and type(pid) == "number" then
        return pid
    end

    return nil
end

local function cancelPendingForcedQuit()
    if state.pendingForcedQuit then
        state.pendingForcedQuit:stop()
        state.pendingForcedQuit = nil
    end
    state.pendingForcedQuitPID = nil
end

local function cancelPendingEvaluation()
    if state.pendingEvaluation then
        state.pendingEvaluation:stop()
        state.pendingEvaluation = nil
    end
end

local function invalidateNetworkCaches()
    state.cachedWiFi = nil
    state.cachedEthernetActive = nil
    state.cachedEthernetInterface = nil
    state.cachedNetworkCheckedAt = nil
    state.cachedDefaultRouteInterface = nil
    state.cachedDefaultRouteCheckedAt = nil
end

local function isTargetConfigured()
    return targetBundleID() ~= "" or targetAppName() ~= ""
end

local function getWiFiNetwork()
    local network = hs.wifi.currentNetwork()
    if network and network ~= "" then
        return network
    end

    local interfaces = hs.wifi.interfaces() or {}
    for _, interface in ipairs(interfaces) do
        local details = hs.wifi.interfaceDetails(interface)
        local ssid = details and (details.ssid or details.SSID)
        if ssid and ssid ~= "" then
            return ssid
        end
    end

    return nil
end

local function getIPv4Address(details)
    local ipv4 = details and details.IPv4
    if type(ipv4) ~= "table" then
        return nil
    end

    if type(ipv4.Addresses) == "table" and #ipv4.Addresses > 0 then
        return ipv4.Addresses[1]
    end
    if type(ipv4.Address) == "string" then
        return ipv4.Address
    end
    if type(ipv4.address) == "string" then
        return ipv4.address
    end

    return nil
end

local function hasActiveIPAddress(details)
    local ipv4Address = getIPv4Address(details)
    local hasUsableIPv4 = type(ipv4Address) == "string"
        and ipv4Address ~= ""
        and ipv4Address ~= "0.0.0.0"
        and not ipv4Address:match("^169%.254%.")
    return hasUsableIPv4, ipv4Address
end

local function hasActiveEthernet()
    local interfaces = hs.network.interfaces() or {}

    for _, interface in ipairs(interfaces) do
        if interface:match("^en%d+$") then
            local details = hs.network.interfaceDetails(interface)
            if details then
                local hasIPv4 = (details.IPv4 ~= nil)
                local isAirPort = (details.AirPort ~= nil)
                local hasUsableIP, ipv4Address = hasActiveIPAddress(details)

                log(string.format(
                    "Ethernet %s: IPv4=%s AirPort=%s IPv4Address=%s",
                    interface,
                    tostring(hasIPv4),
                    tostring(isAirPort),
                    tostring(ipv4Address)
                ))

                if hasUsableIP and not isAirPort then
                    return true, interface
                end
            end
        end
    end

    return false, nil
end

local function getDefaultRouteInterface(forceRefresh)
    local ttl = config.behavior.networkCacheTTLSeconds
    local now = os.time()
    local checkedAt = state.cachedDefaultRouteCheckedAt

    if (not forceRefresh) and checkedAt and ttl > 0 and (now - checkedAt) < ttl then
        return state.cachedDefaultRouteInterface
    end

    state.cachedDefaultRouteCheckedAt = now
    state.cachedDefaultRouteInterface = nil

    local output, ok = hs.execute("/usr/sbin/route -n get default 2>/dev/null", false)
    if not ok or not output then
        return nil
    end

    for line in output:gmatch("([^\r\n]+)") do
        local iface = trim(line:match("^%s*interface:%s*(%S+)"))
        if iface ~= "" then
            state.cachedDefaultRouteInterface = iface
            return iface
        end
    end

    return nil
end

local function isInternetReachable()
    if not hs.network or not hs.network.reachability or not hs.network.reachability.internet then
        return nil
    end

    local reachability = hs.network.reachability.internet()
    if not reachability or not reachability.status then
        return nil
    end

    local okStatus, status = pcall(function()
        return reachability:status()
    end)
    if not okStatus or type(status) ~= "number" then
        return nil
    end

    local flags = hs.network.reachability.flags or {}
    local reachableFlag = flags.reachable
    if type(reachableFlag) ~= "number" then
        return nil
    end

    local connectionRequiredFlag = flags.connectionRequired
    local reachable = ((status & reachableFlag) ~= 0)
    if not reachable then
        return false
    end

    if type(connectionRequiredFlag) == "number" and ((status & connectionRequiredFlag) ~= 0) then
        return false
    end

    return true
end

local function ethernetConditionSatisfied(interface, forceRefresh)
    if config.rules.requireEthernetDefaultRouteMatch then
        local defaultRouteInterface = getDefaultRouteInterface(forceRefresh)
        if not defaultRouteInterface or defaultRouteInterface == "" then
            return false, string.format(
                "Ethernet link active (%s) but default route interface is unavailable",
                tostring(interface)
            )
        end
        if defaultRouteInterface ~= interface then
            return false, string.format(
                "Ethernet link active (%s) but default route is %s",
                tostring(interface),
                tostring(defaultRouteInterface)
            )
        end
    end

    local internetReachable = isInternetReachable()
    if internetReachable == true then
        return true, nil
    end
    if internetReachable == false then
        return false, string.format("Ethernet link active (%s) but internet is unreachable", tostring(interface))
    end
    return false, string.format("Ethernet link active (%s) but internet reachability is unavailable", tostring(interface))
end

local function getNetworkState(forceRefresh)
    local ttl = config.behavior.networkCacheTTLSeconds
    local now = os.time()

    if (not forceRefresh)
        and state.cachedNetworkCheckedAt
        and ttl > 0
        and (now - state.cachedNetworkCheckedAt) < ttl
    then
        return state.cachedWiFi, state.cachedEthernetActive, state.cachedEthernetInterface
    end

    local wifi = getWiFiNetwork()
    local ethernetActive, ethernetInterface = hasActiveEthernet()
    state.cachedWiFi = wifi
    state.cachedEthernetActive = ethernetActive
    state.cachedEthernetInterface = ethernetInterface
    state.cachedNetworkCheckedAt = now

    return wifi, ethernetActive, ethernetInterface
end

local function findRunningTargetApp()
    local bundleID = targetBundleID()
    if bundleID ~= "" then
        if hs.application.applicationsForBundleID then
            local ok, apps = pcall(function()
                return hs.application.applicationsForBundleID(bundleID)
            end)
            if ok and type(apps) == "table" and #apps > 0 then
                return apps[1]
            end
        end

        return nil
    end

    local appName = targetAppName()
    if appName ~= "" then
        return hs.appfinder.appFromName(appName)
    end

    return nil
end

local function appMatchesTarget(name, app, event)
    local bundleID = targetBundleID()
    local terminatedEvent = (event == hs.application.watcher.terminated)

    if bundleID ~= "" then
        if app and app.bundleID then
            local okBundle, appBundleID = pcall(function()
                return app:bundleID()
            end)
            if okBundle and appBundleID == bundleID then
                return true
            end
        end

        if terminatedEvent and app then
            local appPID = applicationPID(app)
            if appPID and state.lastKnownTargetPID and appPID == state.lastKnownTargetPID then
                return true
            end
        end

        return false
    end

    local appName = targetAppName()
    if appName == "" then
        return false
    end

    if type(name) == "string" and name == appName then
        return true
    end

    if app and app.name then
        local okName, runningName = pcall(function()
            return app:name()
        end)
        if okName and runningName == appName then
            return true
        end
    end

    if terminatedEvent and app then
        local appPID = applicationPID(app)
        if appPID and state.lastKnownTargetPID and appPID == state.lastKnownTargetPID then
            return true
        end
    end

    return false
end

local function appObjectMatchesConfiguredTarget(app)
    if not app then
        return false
    end

    local bundleID = targetBundleID()
    if bundleID ~= "" then
        local okBundle, appBundleID = pcall(function()
            return app:bundleID()
        end)
        return okBundle and appBundleID == bundleID
    end

    local appName = targetAppName()
    if appName == "" or not app.name then
        return false
    end

    local okName, runningName = pcall(function()
        return app:name()
    end)
    return okName and runningName == appName
end

local function computeDesiredState(forceFreshNetwork)
    if not isTargetConfigured() then
        state.currentWiFi = nil
        state.activeEthernet = nil
        return false, "Target app is not configured"
    end

    local requiredPower = normalizePowerSourceLabel(config.rules.requiredPowerSource)
    local currentPower = normalizePowerSourceLabel(hs.battery.powerSource() or "Unknown")
    if requiredPower ~= "" and currentPower ~= requiredPower then
        state.currentWiFi = nil
        state.activeEthernet = nil
        return false, string.format("Power is %s (requires %s)", tostring(currentPower), requiredPower)
    end

    local internetReachable = isInternetReachable()
    if internetReachable ~= true then
        local currentWiFi = getNetworkState(forceFreshNetwork)
        state.currentWiFi = currentWiFi
        state.activeEthernet = nil
        if internetReachable == false then
            return false, string.format("%s, internet is unreachable", tostring(currentPower))
        end
        return false, string.format("%s, internet reachability is unavailable", tostring(currentPower))
    end

    local requiredWiFi = trim(config.rules.requiredWiFi)
    local currentWiFi, ethernetActive, ethernetInterface = getNetworkState(forceFreshNetwork)
    state.currentWiFi = currentWiFi
    local requireEthernetOnly = config.rules.requireEthernetOnly
    local ethernetBlockedReason = nil

    if requireEthernetOnly then
        state.activeEthernet = ethernetInterface
        if ethernetActive then
            local ethernetOK, ethernetReason = ethernetConditionSatisfied(ethernetInterface, forceFreshNetwork)
            if ethernetOK then
                return true, string.format("%s + Ethernet-only mode (%s)", tostring(currentPower), ethernetInterface)
            end
            return false, string.format("%s, %s", tostring(currentPower), ethernetReason)
        end
        return false, string.format("%s, Ethernet required but inactive", tostring(currentPower))
    end

    if requiredWiFi ~= "" then
        if currentWiFi == requiredWiFi then
            state.activeEthernet = nil
            return true, string.format("%s + trusted Wi-Fi (%s)", tostring(currentPower), currentWiFi)
        end
    else
        if currentWiFi and currentWiFi ~= "" then
            state.activeEthernet = nil
            return true, string.format("%s + Wi-Fi (%s)", tostring(currentPower), currentWiFi)
        end
    end

    if config.rules.allowEthernetFallback then
        state.activeEthernet = ethernetInterface
        if ethernetActive then
            local ethernetOK, ethernetReason = ethernetConditionSatisfied(ethernetInterface, forceFreshNetwork)
            if ethernetOK then
                return true, string.format("%s + active Ethernet (%s)", tostring(currentPower), ethernetInterface)
            end
            ethernetBlockedReason = ethernetReason
        end
    else
        state.activeEthernet = nil
    end

    if ethernetBlockedReason then
        return false, string.format("%s, %s", tostring(currentPower), ethernetBlockedReason)
    end

    if requiredWiFi ~= "" then
        return false, string.format(
            "%s, network not trusted (Wi-Fi: %s, Ethernet: %s)",
            tostring(currentPower),
            tostring(currentWiFi),
            config.rules.allowEthernetFallback and "inactive" or "disabled"
        )
    end

    return false, string.format(
        "%s, no active network connection",
        tostring(currentPower)
    )
end

local function launchTargetInBackground()
    local bundleID = targetBundleID()
    if bundleID ~= "" then
        local _, openByBundleOK = hs.execute(string.format("/usr/bin/open -g -b %q", bundleID), false)
        if openByBundleOK then
            return true
        end

        if hs.application.launchOrFocusByBundleID then
            local launched = hs.application.launchOrFocusByBundleID(bundleID)
            if launched then
                return true
            end
        end

        -- When bundle ID is configured, do not fall back to app-name launching.
        return false
    end

    local appName = targetAppName()
    if appName ~= "" then
        local _, openByNameOK = hs.execute(string.format("/usr/bin/open -g -a %q", appName), false)
        if openByNameOK then
            return true
        end
        return hs.application.launchOrFocus(appName)
    end

    return false
end

local function quitAppGracefully(app)
    local bundleID = targetBundleID()
    local appName = targetAppName()
    local expectedPID = applicationPID(app)
    local script = nil

    if bundleID ~= "" and isLikelyBundleID(bundleID) then
        script = 'tell application id "' .. appScriptEscape(bundleID) .. '" to quit'
    elseif appName ~= "" then
        script = 'tell application "' .. appScriptEscape(appName) .. '" to quit'
    end

    if script then
        local ok = select(1, hs.osascript.applescript(script))
        if ok then
            cancelPendingForcedQuit()
            state.pendingForcedQuitPID = expectedPID
            state.pendingForcedQuit = hs.timer.doAfter(config.behavior.gracefulQuitTimeoutSeconds, function()
                local originalPID = state.pendingForcedQuitPID
                state.pendingForcedQuit = nil
                state.pendingForcedQuitPID = nil

                safeRun("forced-quit-timeout", function()
                    if not config.behavior.automationEnabled then
                        log("Graceful quit timeout skipped; automation is disabled")
                        return
                    end

                    local shouldRunNow = select(1, computeDesiredState(true))
                    if shouldRunNow then
                        log("Graceful quit timeout skipped; app is now allowed to run")
                        return
                    end

                    local stillRunning = findRunningTargetApp()
                    if stillRunning then
                        if not appObjectMatchesConfiguredTarget(stillRunning) then
                            log("Graceful quit timeout skipped; running app no longer matches target")
                            return
                        end

                        local runningPID = applicationPID(stillRunning)
                        if originalPID and runningPID and runningPID ~= originalPID then
                            log(string.format(
                                "Graceful quit timeout skipped; PID changed (expected=%s current=%s)",
                                tostring(originalPID),
                                tostring(runningPID)
                            ))
                            return
                        end

                        if not originalPID then
                            log("Graceful quit timeout fallback kill; original PID unavailable")
                        elseif not runningPID then
                            log("Graceful quit timeout fallback kill; current PID unavailable")
                        end

                        stillRunning:kill()
                        log("Graceful quit timeout reached; forced app kill")
                    end
                end)
            end)
            return true
        end
    end

    if app then
        cancelPendingForcedQuit()
        return app:kill()
    end

    return false
end

local function setAutomationEnabled(enabled, trigger)
    local desiredValue = enabled and true or false

    if (not desiredValue) and config.behavior.lockAutomationToggle then
        state.lastReason = "Automation toggle is locked"
        notify("Automation toggle is locked; disable request ignored")
        updateMenuBar()
        return
    end

    config.behavior.automationEnabled = desiredValue

    if desiredValue then
        state.lastReason = "Automation enabled from menu"
    else
        state.lastReason = "Automation disabled from menu"
        cancelPendingEvaluation()
        cancelPendingForcedQuit()
    end

    if refreshRuntimeHooks then
        refreshRuntimeHooks()
    end

    updateMenuBar()

    if desiredValue then
        scheduleEvaluation(trigger or "menu-enable-automation", 0)
    end
end

local function setTargetAppNameFromMenu()
    if not hs.dialog or not hs.dialog.textPrompt then
        notify("Unable to prompt for app name (hs.dialog unavailable)")
        return
    end

    local defaultText = targetAppName()
    local button, text = hs.dialog.textPrompt(
        "Set Target App Name",
        "Enter the app name exactly as shown in Finder (for example: Safari).",
        defaultText ~= "" and defaultText or "",
        "Save",
        "Cancel"
    )

    if button ~= "Save" then
        return
    end

    local newName = trim(text)
    if newName == "" then
        notify("No app name entered. Target unchanged.")
        return
    end

    config.target.appName = newName
    persistSetupConfig()
    if refreshRuntimeHooks then
        refreshRuntimeHooks()
    end
    notify("Target app name set to " .. newName)
    scheduleEvaluation("menu-set-app-name", 0)
    updateMenuBar()
end

local function setTargetBundleIDFromMenu()
    if not hs.dialog or not hs.dialog.textPrompt then
        notify("Unable to prompt for bundle ID (hs.dialog unavailable)")
        return
    end

    local defaultText = targetBundleID()
    local button, text = hs.dialog.textPrompt(
        "Set Target Bundle ID",
        "Enter the app bundle ID (for example: com.apple.Safari).",
        defaultText ~= "" and defaultText or "",
        "Save",
        "Cancel"
    )

    if button ~= "Save" then
        return
    end

    local newBundleID = trim(text)
    if newBundleID == "" then
        notify("No bundle ID entered. Target unchanged.")
        return
    end
    if not isLikelyBundleID(newBundleID) then
        notify("Bundle ID format looks invalid. Example: com.apple.Safari")
        return
    end

    config.target.bundleID = newBundleID
    persistSetupConfig()
    if refreshRuntimeHooks then
        refreshRuntimeHooks()
    end
    notify("Target bundle ID set to " .. newBundleID)
    scheduleEvaluation("menu-set-bundle-id", 0)
    updateMenuBar()
end

local function validateTargetFromMenu()
    local bundleID = targetBundleID()
    local appName = targetAppName()

    if bundleID == "" and appName == "" then
        showValidationAlert("No target configured")
        return
    end

    local messages = {}
    if bundleID ~= "" then
        if isBundleIDResolvable(bundleID) then
            table.insert(messages, "Bundle ID found: " .. bundleID)
        else
            table.insert(messages, "Bundle ID unresolved (may still be valid): " .. bundleID)
        end
    end

    if appName ~= "" then
        local appNameFound, resolvedBundle = isAppNameResolvable(appName)
        if appNameFound then
            table.insert(messages, "App name found: " .. appName)
            if resolvedBundle and resolvedBundle ~= "" then
                table.insert(messages, "Resolved bundle: " .. resolvedBundle)
            end
        else
            table.insert(messages, "App name not found: " .. appName)
        end
    end

    table.insert(messages, "Target running now: " .. boolText(findRunningTargetApp() ~= nil))
    showValidationAlert(table.concat(messages, "\n"))
    scheduleEvaluation("menu-validate-target", 0)
    updateMenuBar()
end

local function clearDesiredSSIDFromMenu()
    config.rules.requiredWiFi = ""
    persistSetupConfig()
    invalidateNetworkCaches()
    notify("SSID restriction cleared (any Wi-Fi allowed)")
    scheduleEvaluation("menu-clear-ssid", 0)
    updateMenuBar()
end

local function setDesiredSSIDFromMenu()
    if not hs.dialog or not hs.dialog.textPrompt then
        notify("Unable to prompt for SSID (hs.dialog unavailable)")
        return
    end

    local currentSSID = trim(config.rules.requiredWiFi)
    local button, text = hs.dialog.textPrompt(
        "Set Desired SSID",
        "Enter the Wi-Fi SSID to require. Leave blank to allow any Wi-Fi.",
        currentSSID ~= "" and currentSSID or "",
        "Save",
        "Cancel"
    )

    if button ~= "Save" then
        return
    end

    local newSSID = trim(text)
    if newSSID == "" then
        clearDesiredSSIDFromMenu()
        return
    end

    config.rules.requiredWiFi = newSSID
    persistSetupConfig()
    invalidateNetworkCaches()
    notify("Desired SSID set to " .. newSSID)
    scheduleEvaluation("menu-set-ssid", 0)
    updateMenuBar()
end

local function clearTargetFromMenu()
    cancelPendingEvaluation()
    cancelPendingForcedQuit()
    state.lastKnownTargetPID = nil
    config.target.bundleID = ""
    config.target.appName = ""
    persistSetupConfig()
    if refreshRuntimeHooks then
        refreshRuntimeHooks()
    end
    notify("Target app cleared")
    scheduleEvaluation("menu-clear-target", 0)
    updateMenuBar()
end

local function resetSavedSetupToScriptDefaults()
    if hs.settings and hs.settings.clear then
        hs.settings.clear(TARGET_SETTINGS_KEY)
    elseif hs.settings and hs.settings.set then
        hs.settings.set(TARGET_SETTINGS_KEY, nil)
    end

    cancelPendingEvaluation()
    cancelPendingForcedQuit()
    state.lastKnownTargetPID = nil
    config.target.bundleID = SCRIPT_SETUP_DEFAULTS.bundleID
    config.target.appName = SCRIPT_SETUP_DEFAULTS.appName
    config.rules.requiredWiFi = SCRIPT_SETUP_DEFAULTS.requiredWiFi
    invalidateNetworkCaches()
    if refreshRuntimeHooks then
        refreshRuntimeHooks()
    end

    notify("Saved setup reset to script defaults")
    scheduleEvaluation("menu-reset-setup-defaults", 0)
    updateMenuBar()
end

local function menuStatus()
    local appRunning = state.appRunning
    local prefix = trim(config.menuBar.titlePrefix)
    if prefix == "" then
        prefix = "APP"
    end
    local showState = config.menuBar.showStateText

    if not config.behavior.automationEnabled then
        return "Disabled in config", showState and (prefix .. " DIS") or prefix
    end

    if not isTargetConfigured() then
        return "Target not configured", showState and (prefix .. " CFG") or prefix
    end

    if state.lastDecision == nil then
        return "Initializing", showState and (prefix .. " ...") or prefix
    end

    if state.lastDecision and appRunning then
        return "Running (allowed)", showState and (prefix .. " ON") or prefix
    end
    if state.lastDecision and (not appRunning) then
        return "Should run (not open)", showState and (prefix .. " WAIT") or prefix
    end
    if (not state.lastDecision) and appRunning then
        return "Running (blocked)", showState and (prefix .. " BLOCK") or prefix
    end

    return "Stopped (blocked)", showState and (prefix .. " OFF") or prefix
end

local function formatTime(epoch)
    if not epoch then
        return "n/a"
    end
    return os.date("%Y-%m-%d %H:%M:%S", epoch)
end

local function makeToggleMenuItem(getter, setter, titleOn, titleOff, afterToggle)
    return {
        title = getter() and titleOn or titleOff,
        fn = function()
            setter(not getter())
            if afterToggle then
                afterToggle()
            end
            updateMenuBar()
        end,
    }
end

local function notifyActionResult(desiredRunning, reason)
    hs.timer.doAfter(2, function()
        safeRun("action-verify", function()
            local running = (findRunningTargetApp() ~= nil)
            state.appRunning = running

            if desiredRunning == running then
                local verb = desiredRunning and " opened" or " closed"
                notify(targetDisplayName() .. verb .. " (" .. reason .. ")")
            else
                notify("Action may have failed for " .. targetDisplayName())
            end
            updateMenuBar()
        end)
    end)
end

local function shouldThrottle(now)
    local minGap = config.behavior.minActionGapSeconds
    return (now - state.lastActionAt) < minGap
end

local CONFIG_SUMMARY_PATHS = {
    "target.bundleID",
    "target.appName",
    "rules.requiredPowerSource",
    "rules.requiredWiFi",
    "rules.requireEthernetOnly",
    "rules.allowEthernetFallback",
    "behavior.automationEnabled",
    "behavior.lockAutomationToggle",
    "behavior.debug",
    "behavior.enforceIntervalSeconds",
    "behavior.networkCacheTTLSeconds",
    "menuBar.enabled",
    "menuBar.showConfigSection",
    "menuBar.showAllConfigValues",
    "menuBar.showQuickActions",
    "menuBar.showStateText",
}

local function readConfigValueByPath(path)
    local cursor = config
    for token in tostring(path):gmatch("[^%.]+") do
        if type(cursor) ~= "table" then
            return nil
        end
        cursor = cursor[token]
    end
    return cursor
end

local function addFlattenedConfigMenuEntries(entries, prefix, value)
    if type(value) == "table" then
        local keys = {}
        for key in pairs(value) do
            table.insert(keys, key)
        end
        table.sort(keys, function(a, b)
            return tostring(a) < tostring(b)
        end)

        for _, key in ipairs(keys) do
            local childPrefix = prefix ~= "" and (prefix .. "." .. tostring(key)) or tostring(key)
            addFlattenedConfigMenuEntries(entries, childPrefix, value[key])
        end
        return
    end

    table.insert(entries, { title = prefix .. ": " .. tostring(value), disabled = true })
end

local function buildConfigurationDetailsMenu()
    local entries = {
        {
            title = config.menuBar.showAllConfigValues and "Show compact config list" or "Show full config list",
            fn = function()
                config.menuBar.showAllConfigValues = not config.menuBar.showAllConfigValues
                updateMenuBar()
            end,
        },
        { title = "-" },
    }
    if config.menuBar.showAllConfigValues then
        addFlattenedConfigMenuEntries(entries, "", config)
        return entries
    end

    for _, path in ipairs(CONFIG_SUMMARY_PATHS) do
        table.insert(entries, {
            title = path .. ": " .. tostring(readConfigValueByPath(path)),
            disabled = true,
        })
    end
    return entries
end

local function buildMenu()
    local appRunning = state.appRunning
    local statusText = select(1, menuStatus())
    local requiredWiFi = trim(config.rules.requiredWiFi)
    local displayWiFi = requiredWiFi ~= "" and requiredWiFi or "any"
    local displayAppName = targetAppName() ~= "" and targetAppName() or "none"
    local displayBundleID = targetBundleID() ~= "" and targetBundleID() or "none"
    local usingSavedOverrides = hasSavedSetupOverrides()
    local targetConfigured = isTargetConfigured()
    local targetBundle = targetBundleID()
    local bundleResolvable = isBundleIDResolvable(targetBundle)
    local displayCurrentWiFi = targetConfigured and tostring(state.currentWiFi or "none") or "n/a"
    local displayActiveEthernet = targetConfigured and tostring(state.activeEthernet or "none") or "n/a"

    local menu = {
        { title = "Status: " .. statusText, disabled = true },
        { title = "Target: " .. targetIdentityLabel(), disabled = true },
        { title = "Automation Enabled: " .. boolText(config.behavior.automationEnabled), disabled = true },
        { title = "Desired Running: " .. boolText(state.lastDecision), disabled = true },
        { title = "App Running: " .. boolText(appRunning), disabled = true },
        { title = "Reason: " .. tostring(state.lastReason or "n/a"), disabled = true },
        { title = "Last Trigger: " .. tostring(state.lastTrigger or "n/a"), disabled = true },
        { title = "Last Check: " .. formatTime(state.lastEvaluationAt), disabled = true },
        { title = "Current Wi-Fi: " .. displayCurrentWiFi, disabled = true },
        { title = "Active Ethernet: " .. displayActiveEthernet, disabled = true },
    }

    if state.lastError then
        table.insert(menu, { title = "Last Error: " .. state.lastError, disabled = true })
    end
    if state.powerSourceConfigWarning then
        table.insert(menu, { title = "Power Warning: " .. state.powerSourceConfigWarning, disabled = true })
    end

    if targetBundle ~= "" and not bundleResolvable then
        table.insert(menu, { title = "Warning: Bundle ID unresolved (may still be valid): " .. targetBundle, disabled = true })
    end

    if config.menuBar.showQuickActions then
        table.insert(menu, {
            title = "Re-check now",
            fn = function()
                scheduleEvaluation("menu-manual", 0)
            end,
        })

        if config.behavior.automationEnabled then
            if config.behavior.lockAutomationToggle then
                table.insert(menu, {
                    title = "Disable automation (locked)",
                    disabled = true,
                })
            else
                table.insert(menu, {
                    title = "Disable automation",
                    fn = function()
                        setAutomationEnabled(false, "menu-disable-automation")
                    end,
                })
            end
        else
            table.insert(menu, {
                title = "Enable automation",
                fn = function()
                    setAutomationEnabled(true, "menu-enable-automation")
                end,
            })
        end

    end

    table.insert(menu, { title = "-" })
    table.insert(menu, { title = "Setup (changes are saved)", disabled = true })
    table.insert(menu, { title = "App Name: " .. displayAppName, disabled = true })
    table.insert(menu, { title = "Bundle ID: " .. displayBundleID, disabled = true })
    table.insert(menu, { title = "Desired SSID: " .. displayWiFi, disabled = true })
    table.insert(menu, {
        title = "Set app name...",
        fn = function()
            setTargetAppNameFromMenu()
        end,
    })
    table.insert(menu, {
        title = "Set bundle ID...",
        fn = function()
            setTargetBundleIDFromMenu()
        end,
    })
    table.insert(menu, {
        title = "Validate target now",
        fn = function()
            validateTargetFromMenu()
        end,
    })
    table.insert(menu, {
        title = "Clear target app",
        fn = function()
            clearTargetFromMenu()
        end,
    })
    table.insert(menu, {
        title = "Set desired SSID...",
        fn = function()
            setDesiredSSIDFromMenu()
        end,
    })
    table.insert(menu, {
        title = "Allow any SSID",
        fn = function()
            clearDesiredSSIDFromMenu()
        end,
    })
    table.insert(menu, {
        title = usingSavedOverrides and "Using: Saved Overrides" or "Using: Script Values",
        disabled = true,
    })
    table.insert(menu, {
        title = "Reset saved setup to script defaults",
        disabled = not usingSavedOverrides,
        fn = function()
            resetSavedSetupToScriptDefaults()
        end,
    })

    if config.menuBar.showQuickActions then
        table.insert(menu, { title = "-" })
        table.insert(menu, { title = "Configuration Toggles (session only)", disabled = true })
        table.insert(menu, makeToggleMenuItem(
            function()
                return config.behavior.debug
            end,
            function(value)
                config.behavior.debug = value
            end,
            "Disable debug logging",
            "Enable debug logging"
        ))
        table.insert(menu, makeToggleMenuItem(
            function()
                return config.rules.allowEthernetFallback
            end,
            function(value)
                config.rules.allowEthernetFallback = value
            end,
            "Disable Ethernet fallback",
            "Enable Ethernet fallback",
            function()
                scheduleEvaluation("menu-toggle-ethernet", 0)
            end
        ))
        table.insert(menu, makeToggleMenuItem(
            function()
                return config.menuBar.showStateText
            end,
            function(value)
                config.menuBar.showStateText = value
            end,
            "Hide state text in title",
            "Show state text in title"
        ))
    end

    return menu
end

updateMenuBar = function()
    if not config.menuBar.enabled then
        if state.menuBar then
            state.menuBar:delete()
            state.menuBar = nil
        end
        return
    end

    if not state.menuBar then
        state.menuBar = hs.menubar.new()
        if not state.menuBar then
            print("Unable to create menu bar item")
            return
        end
        state.menuBar:setMenu(buildMenu)
    end

    local statusText, titleText = menuStatus()
    state.menuBar:setTitle(titleText)
    state.menuBar:setTooltip(
        "Status: " .. statusText ..
        "\nReason: " .. tostring(state.lastReason or "n/a")
    )
end

scheduleEvaluation = function(trigger, delaySeconds)
    local delay = delaySeconds
    if delay == nil then
        delay = config.behavior.debounceSeconds
    end
    delay = toNumber(delay, config.behavior.debounceSeconds, 0)

    cancelPendingEvaluation()

    state.pendingEvaluation = hs.timer.doAfter(delay, function()
        state.pendingEvaluation = nil
        safeRun("manageApp:" .. tostring(trigger), function()
            manageApp(trigger)
        end)
    end)
end

manageApp = function(trigger)
    trigger = trigger or "manual"
    state.lastTrigger = trigger
    state.lastEvaluationAt = os.time()
    state.lastError = nil

    if refreshRuntimeHooks then
        refreshRuntimeHooks()
    end

    if not config.behavior.automationEnabled then
        cancelPendingForcedQuit()
        state.lastDecision = nil
        state.lastReason = "Automation disabled in config"
        state.appRunning = nil
        state.lastKnownTargetPID = nil
        updateMenuBar()
        return
    end

    if not isTargetConfigured() then
        cancelPendingForcedQuit()
        state.lastDecision = false
        state.lastReason = "Target app is not configured"
        state.appRunning = false
        state.lastKnownTargetPID = nil
        state.currentWiFi = nil
        state.activeEthernet = nil
        updateMenuBar()
        return
    end

    local app = findRunningTargetApp()
    local appRunning = (app ~= nil)
    local shouldRun, reason = computeDesiredState(appRunning)

    if shouldRun and (not appRunning) then
        shouldRun, reason = computeDesiredState(true)
    end

    state.appRunning = appRunning
    state.lastKnownTargetPID = appRunning and applicationPID(app) or nil

    state.lastDecision = shouldRun
    state.lastReason = reason

    log(string.format(
        "Trigger=%s Desired=%s Running=%s Reason=%s",
        trigger,
        tostring(shouldRun),
        tostring(appRunning),
        reason
    ))

    if shouldRun then
        cancelPendingForcedQuit()
    end

    local inDesiredState = (shouldRun and appRunning) or ((not shouldRun) and (not appRunning))
    if inDesiredState then
        updateMenuBar()
        return
    end

    local now = os.time()
    if shouldThrottle(now) then
        local waitTime = config.behavior.minActionGapSeconds - (now - state.lastActionAt) + 1
        scheduleEvaluation("throttle-retry", waitTime)
        updateMenuBar()
        return
    end

    if shouldRun and not appRunning then
        local launched = launchTargetInBackground()
        state.lastActionAt = os.time()
        if not launched then
            log("Launch request failed for " .. targetDisplayName())
        end
        notifyActionResult(true, reason)
    elseif (not shouldRun) and appRunning then
        local closed = quitAppGracefully(app)
        state.lastActionAt = os.time()
        if not closed then
            log("Quit request failed for " .. targetDisplayName())
        end
        notifyActionResult(false, reason)
    end

    updateMenuBar()
end

local function registerWatcher(name, watcher)
    if not watcher then
        log("Watcher unavailable: " .. name)
        return
    end
    state.watchers[name] = watcher
    state.watcherRunning[name] = false
end

local function setWatcherRunning(name, shouldRun)
    local watcher = state.watchers[name]
    if not watcher then
        return
    end

    local isRunning = state.watcherRunning[name] == true
    if shouldRun == isRunning then
        return
    end

    local ok, err = pcall(function()
        if shouldRun then
            watcher:start()
        else
            watcher:stop()
        end
    end)

    if ok then
        state.watcherRunning[name] = shouldRun
    else
        log(string.format(
            "Watcher %s failed to %s: %s",
            name,
            shouldRun and "start" or "stop",
            tostring(err)
        ))
    end
end

local function setPeriodicEnforcerRunning(shouldRun)
    local timer = state.timers.periodicEnforcer
    if not timer then
        return
    end

    if shouldRun and not state.periodicEnforcerRunning then
        timer:start()
        state.periodicEnforcerRunning = true
    elseif (not shouldRun) and state.periodicEnforcerRunning then
        timer:stop()
        state.periodicEnforcerRunning = false
    end
end

refreshRuntimeHooks = function()
    local shouldRun = config.behavior.automationEnabled and isTargetConfigured()

    for name, _ in pairs(state.watchers) do
        setWatcherRunning(name, shouldRun)
    end

    setPeriodicEnforcerRunning(shouldRun)
end

local function setupWatchers()
    registerWatcher("battery", hs.battery.watcher.new(function()
        scheduleEvaluation("battery")
    end))

    registerWatcher("wifi", hs.wifi.watcher.new(function()
        invalidateNetworkCaches()
        scheduleEvaluation("wifi")
    end))

    local reachability = hs.network.reachability.internet()
    if reachability and reachability.setCallback then
        reachability:setCallback(function()
            invalidateNetworkCaches()
            scheduleEvaluation("reachability")
        end)
        registerWatcher("reachability", reachability)
    end

    registerWatcher("app", hs.application.watcher.new(function(name, event, app)
        if event == hs.application.watcher.terminated then
            if appMatchesTarget(name, app, event) then
                state.appRunning = false
                state.lastKnownTargetPID = nil
                scheduleEvaluation("app-watcher-terminated")
                return
            end

            -- Hammerspoon can report terminated apps with nil names; schedule a safe re-check in this case.
            if isTargetConfigured() and name == nil then
                scheduleEvaluation("app-watcher-terminated-unknown")
            end
            return
        end

        if event == hs.application.watcher.launched and appMatchesTarget(name, app, event) then
            state.appRunning = true
            state.lastKnownTargetPID = applicationPID(app) or state.lastKnownTargetPID
            scheduleEvaluation("app-watcher-launched")
        end
    end))

    registerWatcher("wake", hs.caffeinate.watcher.new(function(event)
        if event == hs.caffeinate.watcher.systemDidWake then
            invalidateNetworkCaches()
            scheduleEvaluation("wake", config.behavior.wakeDelaySeconds)
        end
    end))
end

local function setupTimers()
    if config.behavior.enforceIntervalSeconds > 0 then
        state.timers.periodicEnforcer = hs.timer.new(config.behavior.enforceIntervalSeconds, function()
            scheduleEvaluation("periodic", 0)
        end)
    else
        state.timers.periodicEnforcer = nil
    end

    state.periodicEnforcerRunning = false
end

local function cleanupRuntime()
    cancelPendingEvaluation()
    cancelPendingForcedQuit()

    for _, watcher in pairs(state.watchers or {}) do
        pcall(function()
            watcher:stop()
        end)
    end

    for _, timer in pairs(state.timers or {}) do
        pcall(function()
            timer:stop()
        end)
    end

    if state.menuBar then
        pcall(function()
            state.menuBar:delete()
        end)
        state.menuBar = nil
    end

    state.watchers = {}
    state.watcherRunning = {}
    state.timers = {}
    state.periodicEnforcerRunning = false
end

_G[RUNTIME_CLEANUP_KEY] = cleanupRuntime

loadPersistedSetupConfig()
validateAndNormalizeConfig()
setupWatchers()
setupTimers()
refreshRuntimeHooks()
updateMenuBar()
scheduleEvaluation("startup", 0)
