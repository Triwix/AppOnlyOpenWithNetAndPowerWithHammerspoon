# Hammerspoon Auto App Manager

A Hammerspoon `init.lua` script that automatically keeps one app running (or closed) based on power and network conditions.

It includes:
- Menu bar status + controls
- Persisted setup values (target app + SSID)
- Event-driven enforcement (Wi-Fi, power, wake, app lifecycle, reachability)
- Graceful quit with forced-kill fallback
- Optional debug logging + file log rotation

## How It Works

The script continuously evaluates whether your target app **should be running**.

It can require:
- A specific power source (for example `AC Power`)
- A specific Wi-Fi SSID
- Ethernet-only mode
- Ethernet default-route matching
- Internet reachability

Then it will:
- Launch the app in the background if it should be running but is closed
- Quit the app if it should be closed but is running

## Requirements

- macOS
- [Hammerspoon](https://www.hammerspoon.org/) installed
- Accessibility permissions granted to Hammerspoon

No external Lua dependencies are required.

## Install

1. Copy this script into your Hammerspoon config as:
   - `~/.hammerspoon/init.lua`
2. Open Hammerspoon and click **Reload Config**.
3. Confirm the menu bar item appears (default prefix is `ツ`).

## Quick Start

1. Set a target app in `config.target`:
   - `bundleID` (preferred), or
   - `appName`
2. Keep `rules.requiredPowerSource = "AC Power"` if you only want automation while plugged in.
3. Optionally set `rules.requiredWiFi` to a trusted SSID.
4. Reload Hammerspoon.
5. Use the menu bar item:
   - `Set app name...` / `Set bundle ID...`
   - `Validate target now`
   - `Re-check now`

If both `bundleID` and `appName` are set, bundle ID logic is used first.

## Configuration

The script is configured via the `config` table near the top of `init.lua`.

### `config.target`

- `bundleID` (`string`): Preferred app identifier, example `com.apple.Safari`
- `appName` (`string`): App name fallback, example `Safari`

### `config.rules`

- `requiredPowerSource` (`string`): `""`, `AC Power`, `Battery Power`, or `UPS Power`
- `requiredWiFi` (`string`): Required SSID; empty means any Wi-Fi
- `requireEthernetOnly` (`boolean`): Only Ethernet can satisfy network rules
- `allowEthernetFallback` (`boolean`): Allow Ethernet when Wi-Fi rule is not met
- `requireEthernetDefaultRouteMatch` (`boolean`): Ethernet must also own default route

### `config.behavior`

- `automationEnabled` (`boolean`): Master enable/disable
- `lockAutomationToggle` (`boolean`): Prevent disabling from menu
- `debug` (`boolean`): Verbose console logging
- `logToFile` (`boolean`): Append logs to `logPath`
- `logPath` (`string`): Default `~/.hammerspoon/app-manager.log`
- `logMaxBytes` (`number`): Rotate when file exceeds size (0 disables rotation)
- `debounceSeconds` (`number`): Delay before handling rapid event bursts
- `wakeDelaySeconds` (`number`): Delay after wake before reevaluation
- `enforceIntervalSeconds` (`number`): Periodic safety check (0 disables)
- `networkCacheTTLSeconds` (`number`): Cache Wi-Fi/Ethernet checks
- `minActionGapSeconds` (`number`): Minimum gap between launch/quit actions
- `gracefulQuitTimeoutSeconds` (`number`): Wait before force-kill fallback

### `config.menuBar`

- `enabled` (`boolean`): Show/hide menu bar item
- `titlePrefix` (`string`): Prefix in title (default `ツ`)
- `showConfigSection` (`boolean`)
- `showAllConfigValues` (`boolean`)
- `showQuickActions` (`boolean`)
- `showStateText` (`boolean`)

## Menu Features

The menu provides:
- Live status (desired state, running state, reason, last trigger/check)
- Setup actions that persist across reloads:
  - Target app name
  - Target bundle ID
  - Desired SSID
- Quick actions:
  - Re-check now
  - Enable/disable automation
- Session-only toggles:
  - Debug logging
  - Ethernet fallback
  - Show state text in menu title

Persisted setup values are stored via `hs.settings` key `autoManagedApp.target`.

## Runtime Signals Watched

Automation reevaluates on:
- Battery/power changes
- Wi-Fi changes
- Internet reachability changes
- Target app launch/termination events
- System wake
- Optional periodic timer

## Troubleshooting

- `Target not configured`:
  - Set `target.bundleID` or `target.appName`.
- `Bundle ID unresolved`:
  - Validate with menu action `Validate target now`.
  - Unresolved IDs may still be valid in some cases.
- App does not close:
  - Script requests graceful quit first, then force-kills after timeout.
- App does not launch:
  - Verify app exists, spelling is exact, and Hammerspoon permissions are granted.
- Unexpected blocked state:
  - Check current power source, SSID, Ethernet status, and reachability.

## Notes

- Setup changes from the menu are persisted.
- Most behavior/config toggles in the menu are session-only.
- Reloading config cleans up prior watchers/timers before re-registering.
