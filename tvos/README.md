# TabloTV — native tvOS app

SwiftUI app for Apple TV that talks to the tablo-proxy API. It covers the
same ground as the web UI, laid out for the couch:

- **Live TV** — channel list with what's on now, favorites filter (hold
  Select on a channel to star it or open its record menu), REC badges for
  channels the Tablo is capturing, tuner usage.
- **Guide** — 3-hour grid paged with Earlier / Now / Later; each program shows
  the schedule state the way the web UI does (red = will record or is
  recording, amber = series scheduled but Tablo is skipping this airing).
  Select a program to watch the channel or change what gets recorded.
- **Recordings** — the Tablo's recordings merged with the copies archived on
  the proxy host, by date / by show / A–Z, with SAVED / SAVING badges and
  resume positions. A detail page offers play / resume / watch live, stop a
  capture (keeping the partial), save a copy, and delete (Tablo copy, saved
  copy, or both).
- **Player** — the system player (native scrubbing, skip, play/pause on the
  Siri remote). The transport bar's menu adds **Record** (for the channel
  being watched) and **Jump to** (restarts the transcode at a point past what
  has been transcoded so far); **Go Live** jumps to the live edge. Swipe down
  for details and position. Archived recordings play as plain MP4s with
  instant native seek.
- Watching a channel that's being recorded plays the recording seeked to the
  live edge so you can rewind to its start; when the capture ends, playback
  continues live on the channel. Sessions are kept alive while paused and
  reopened at the same position if the proxy reaps them.

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

       TEAM_ID=ABCDE12345            # Xcode > Settings > Accounts > your team's ID
       DEVICE_IDS="<UDID> <UDID>"    # from: xcrun devicectl list devices — one per Apple TV

5. Install the agent:

       cp scripts/com.mwgreen.tablo-tv-refresh.plist ~/Library/LaunchAgents/
       launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/com.mwgreen.tablo-tv-refresh.plist

Several Apple TVs: pair each one with Xcode once (step 2) and list all their
UDIDs in `DEVICE_IDS`. One build covers them all; an Apple TV that's off during
a run is skipped and caught up on a later one.

Log: `~/Library/Application Support/tablo-tv-refresh/refresh.log`. Failures
(usually Apple wanting you to sign in again) pop a macOS notification.
Force a rebuild any time with `FORCE=1 scripts/refresh.sh`.
