# AppOnlyOpenWithNetAndPower-Hammerspoon
This hammerspoon script for macOS opens an app when both AC power and a network connection are detected, and quits the app when either condition is false.

An example usecase would be for seeding with a torrent client so it doesn't drain battery when not plugged into AC power, and if there is power but no network connection, the app wouldn't need to be open anyways.

Assuming your usecase is likewise an app that is ran in the background, it would be optimal for it to be set to launch minimized if the the option is offered.

## Installation
- Install Hammerspoon from https://www.hammerspoon.org
- Copy the contents of the .rtf file into your hammerspoon config
- Replace `YOUR_APP` with the app you want to be controlled by this automation. Verify the app name matches exactly (case-senstive).
- Replace `YOUR_WIFI` with your local WiFi SSID

## How It Works
The script monitors:
1. Battery status - AC power vs battery
2. WiFi connection - Checks if connected to your specified network
3. Ethernet connection - Detects active Ethernet interfaces
4. System wake events - Re-checks conditions after sleep

Ethernet or WiFi will satisfy the network condition.

When both power and network conditions are satisfied, the chosen app is launched. When either condition fails, the app is automatically closed.

## WiFi Detection Methods
The script uses three fallback methods to detect WiFi:
1. Standard Hammerspoon API (requires Location Services permission)
2. WiFi interface details check
3. airport command-line tool (no permissions needed)

## Debugging
The script logs detailed information to the Hammerspoon console. To view logs:
1. Open Hammerspoon
2. Click the menu bar icon → Console
3. Watch for log messages with timestamps
