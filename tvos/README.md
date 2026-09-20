# TabloTV — native tvOS app (starter)

SwiftUI app for Apple TV that talks to the tablo-proxy API: live channel list,
recordings list, and playback of the proxy's HLS streams with the system player.
It's the scaffold for a custom couch UI; the guide grid and record controls
from the web UI are not ported yet.

## Build

Requires Xcode with the tvOS platform installed and [XcodeGen](https://github.com/yonaskolb/XcodeGen):

    brew install xcodegen
    cd tvos && xcodegen generate && open TabloTV.xcodeproj

`project.yml` is the source of truth; the `.xcodeproj` is generated and ignored.
The proxy address defaults to `http://192.168.68.77:9480` and can be changed in
the app's Settings tab.

## Free Apple ID + weekly refresh

A free "Personal Team" signs the app with a profile that expires after 7 days.
`scripts/refresh.sh` rebuilds and reinstalls it from this Mac whenever the last
install is older than 5 days (or the app source changed), and
`scripts/com.mwgreen.tablo-tv-refresh.plist` runs it every 6 hours while the
Mac is awake. Missed runs while asleep/off simply happen at the next wake.

One-time setup:

1. Xcode > Settings > Accounts: sign in with your Apple ID.
2. Pair the Apple TV (TV: Settings > Remotes and Devices > Remote App and
   Devices; then Xcode > Window > Devices and Simulators).
3. Open the project, choose your Personal Team under Signing & Capabilities,
   and Run once on the Apple TV (registers the app ID + device, answers trust).
4. Create `~/.config/tablo-tv/refresh.env`:

       TEAM_ID=ABCDE12345     # Xcode > Settings > Accounts > your team's ID
       DEVICE_ID=<UDID>       # from: xcrun devicectl list devices

5. Install the agent:

       cp scripts/com.mwgreen.tablo-tv-refresh.plist ~/Library/LaunchAgents/
       launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/com.mwgreen.tablo-tv-refresh.plist

Log: `~/Library/Application Support/tablo-tv-refresh/refresh.log`. Failures
(usually Apple wanting you to sign in again) pop a macOS notification.
Force a rebuild any time with `FORCE=1 scripts/refresh.sh`.
