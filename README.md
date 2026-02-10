# Hammerspoon AC + Internet App Guard

A Hammerspoon automation script that keeps one target app running **only when allowed conditions are met**.

Primary use case:
- Run app only when on `AC Power`
- Require internet reachability
- Optionally require a specific Wi-Fi SSID or Ethernet rules

## What It Does

The script continuously evaluates whether the target app should run.

If conditions are allowed:
- Launches the app in the background when it is not running.

If conditions are blocked:
- Requests graceful quit.
- Force-kills after a timeout if it is still running.

It also provides:
- Menu bar status + controls
- Persisted setup values (target app + required SSID)
- Event-driven reevaluation (power, Wi-Fi, reachability, app events, wake)
- Optional debug/file logging

## Requirements

- macOS
- [Hammerspoon](https://www.hammerspoon.org/)
- Hammerspoon accessibility permissions

## Install

### Option A: Use as your `init.lua`

1. Copy `init.lua` contents into `~/.hammerspoon/` or paste the contents directly into the hammerspoon config entry UI.
2. Reload Hammerspoon config

### Option B: Keep it as a separate file

Rename `init.lua` to something else like `TMAuto.lua` in `~/.hammerspoon/` and load it from your own `init.lua`:

```lua
dofile(os.getenv("HOME") .. "/.hammerspoon/TMAuto.lua")
```

## Quick Start (AC + Internet Only)

1. Set target app:
- `config.target.bundleID = "com.your.app"` (preferred)
- or `config.target.appName = "Your App"`

2. Keep/default these:
- `config.rules.requiredPowerSource = "AC Power"`
- `config.rules.requiredWiFi = ""` (any Wi-Fi)
- `config.rules.requireEthernetOnly = false`
- `config.rules.allowEthernetFallback = true`

3. Reload config.

4. In menu bar:
- Use `Validate target now`
- Use `Re-check now` to force immediate evaluation

## Configuration

### `config.target`

- `bundleID` (string): Preferred identifier, e.g. `com.apple.Safari`
- `appName` (string): Optional name fallback when bundle ID is empty

### `config.rules`

- `requiredPowerSource` (string): `""`, `"AC Power"`, `"Battery Power"`, `"UPS Power"`
- `requiredWiFi` (string): Required SSID, or empty for any Wi-Fi
- `requireEthernetOnly` (boolean): Only Ethernet may satisfy network requirement
- `allowEthernetFallback` (boolean): Allow Ethernet if Wi-Fi condition is not met
- `requireEthernetDefaultRouteMatch` (boolean): Ethernet interface must own default route

### `config.behavior`

- `automationEnabled` (boolean): Master on/off
- `lockAutomationToggle` (boolean): Lock menu disable action
- `debug` (boolean): Console debug logs
- `logToFile` (boolean): Write logs to file
- `logPath` (string): Log path (default `~/.hammerspoon/app-manager.log`)
- `logMaxBytes` (number): Rotate log file at max size (`0` disables rotation)
- `debounceSeconds` (number): Debounce rapid event bursts
- `wakeDelaySeconds` (number): Delay checks after wake
- `enforceIntervalSeconds` (number): Periodic safety check interval (`0` disables)
- `networkCacheTTLSeconds` (number): Network state cache TTL
- `minActionGapSeconds` (number): Minimum seconds between launch/quit actions
- `gracefulQuitTimeoutSeconds` (number): Wait before forced kill

### `config.menuBar`

- `enabled` (boolean): Show/hide menu item
- `titlePrefix` (string): Prefix shown in menu bar title
- `showConfigSection` (boolean): Show expandable configuration section
- `showAllConfigValues` (boolean): Full vs compact config list inside that section
- `showQuickActions` (boolean): Show quick actions/toggles block
- `showStateText` (boolean): Show ON/OFF/WAIT/BLOCK text in title

## Menu Features

- Live status and reason
- Target setup controls (app name, bundle ID, SSID)
- `Validate target now`
- `Re-check now`
- Session-only toggles for debug, Ethernet fallback, title state text
- Optional expandable configuration section

## Decision Logic (Simplified)

The app is allowed only when all required checks pass:

1. Target is configured
2. Power source matches rule
3. Internet is reachable
4. Network rule is satisfied (trusted Wi-Fi and/or Ethernet fallback rules)

If any required check fails, the app is blocked.

## Persistence

Persisted with `hs.settings` key:
- `autoManagedApp.target`

Persisted fields:
- `bundleID`
- `appName`
- `requiredWiFi`

## Troubleshooting

- `Target not configured`
  - Set bundle ID or app name.

- `Bundle ID unresolved`
  - Use `Validate target now`.
  - Confirm bundle ID format and app availability.

- App keeps running when blocked
  - Check `gracefulQuitTimeoutSeconds` and Hammerspoon permissions.
  - Verify app isn’t respawning from another launcher.

- Unexpected blocked status
  - Check menu reason line for power/network details.

## Notes

- Runtime cleanup is performed on config reload (watchers/timers/menu cleanup).
- `Disable automation` may be locked if `lockAutomationToggle = true`.
- Network checks are cached briefly to reduce churn (`networkCacheTTLSeconds`).
