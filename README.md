# Hammerspoon App Guard (v2 variants)

These scripts automate one rule: keep a target app running only when allowed by your power/network conditions.  
When conditions fail, the script stops the app.

## Requirements

- macOS
- [Hammerspoon](https://www.hammerspoon.org/)
- Hammerspoon accessibility permissions

## Files

- `v2 simple.lua`: minimal AC + internet guard, low complexity.
- `v2.lua`: full-featured version for daily use.
- `v2-debug.lua`: `v2.lua` plus built-in performance profiling.

## Quick Setup

1. Load exactly one variant from `~/.hammerspoon/init.lua`.
2. Set your target app in that file (`appName` and/or `bundleID`, depending on variant).
3. Reload Hammerspoon config.

## Key Differences

| Area | `v2 simple.lua` | `v2.lua` | `v2-debug.lua` |
|---|---|---|---|
| Scope | Minimal | Full feature set | Full + instrumentation |
| Target ID | `appName` only | `bundleID` + `appName` fallback | Same as `v2.lua` |
| Rules | AC on/off + internet reachable | Configurable power source, internet, SSID, Ethernet options | Same as `v2.lua` |
| Launch behavior | `launchOrFocus` | Background launch (`open -g`) with fallback | Same as `v2.lua` |
| Stop behavior | Immediate `app:kill()` | Graceful quit, then forced kill timeout | Same as `v2.lua` |
| UI | None | Menu bar status + setup/actions | Same + profiler actions |
| Persistence | None | Saves app/SSID setup via `hs.settings` | Same as `v2.lua` |
| Triggers | Battery, reachability, 60s timer | Battery, Wi-Fi, reachability, app, sleep/wake, periodic enforcer | Same as `v2.lua` (profiled) |
| Logging | Basic console toggle | Debug + optional file logging/rotation | Same + profile summaries |
| Profiling | No | No | Yes (`profileEnabled`, summary/reset menu actions, global helpers) |

## Which One To Use

- Use `v2 simple.lua` if you want the smallest script and only need AC + internet checks.
- Use `v2.lua` for normal use with menu controls, persistence, and safer app shutdown.
- Use `v2-debug.lua` when diagnosing timing/performance behavior.

## Load One From `init.lua`

```lua
-- choose exactly one:
-- dofile(os.getenv("HOME") .. "/.hammerspoon/v2 simple.lua")
dofile(os.getenv("HOME") .. "/.hammerspoon/v2.lua")
-- dofile(os.getenv("HOME") .. "/.hammerspoon/v2-debug.lua")
```
