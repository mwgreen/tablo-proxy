# TabloTV — native tvOS app

SwiftUI app for Apple TV that talks to the tablo-proxy API. It covers the
same ground as the web UI, laid out for the couch:

- **Live TV** — channel list with what's on now, favorites filter (hold
  Select on a channel to star it or open its record menu), REC badges for
  channels the Tablo is capturing, tuner usage.
- **Guide** — 3-hour grid paged with Now / Later (and Earlier, back to the
  current half-hour: the guide never shows the past, and the window slides
  forward on its own as time passes, including after a night asleep); each
  program shows
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

### Verifying a change

The app was written and reviewed without a Swift toolchain (the sessions that
produce it run in Linux containers), so the first build on a Mac is the
compile check. A simulator build needs no signing:

    cd tvos && xcodegen generate
    xcodebuild -project TabloTV.xcodeproj -scheme TabloTV \
      -destination 'generic/platform=tvOS Simulator' \
      CODE_SIGNING_ALLOWED=NO build 2>&1 | grep -E 'error:|warning: .*Sources|BUILD'

Paste any `error:` lines back into the session that made the change. Then run
it and walk through the checks below. The tvOS simulator on a Mac on the same
LAN reaches the proxy over plain http and plays live and recorded streams, so
most of this works there (install with `xcrun simctl install booted
DerivedData/Build/Products/Debug-appletvsimulator/TabloTV.app`; point it at a
proxy with `xcrun simctl spawn booted defaults write com.mwgreen.tablotv
baseURL http://HOST:9480`). The arrow keys drive focus; AVKit's transport-bar
popup menus don't respond to them reliably, so check "Jump to" on the Apple TV.

1. Live TV: pick a channel; the stream starts within ~10 s. Menu returns to
   the list and the proxy log shows the session stopped.
2. Live TV: hold Select on a channel — favorite toggle and record options.
3. Guide: Earlier / Now / Later page the window; red/amber dots match the
   web UI for the same airings; selecting a program offers Watch + record.
4. Recordings: the three views; a recording plays, pauses, and skips with the
   Siri remote; after ~5 s the row shows a resume position.
5. Player: transport bar menu shows Record (channels) and Jump to
   (recordings); Jump to a point past the transcoded range restarts the
   stream there. Swipe down shows the info panel. Go Live appears on live
   streams.
6. Watch a channel that is currently recording: playback opens near the live
   edge and can rewind; when the capture ends the player continues live.
7. Pause a recording for 6 minutes: playback resumes without a dead player
   (the keepalive kept the proxy session alive).

### How it maps to the web UI

`public/index.html` is the reference implementation for behaviour: the record
menu order and red/amber rules (`toggleRecordShow`, `renderGuide`), the merged
recordings model (`mergedRecordings`, `renderRecItem`), the live-recording
hybrid (`playChannel`, `endLiveWatch`) and session keepalive/recovery. The
tvOS counterparts are `AppStore.recordActions` / `recordMark`,
`AppStore.mergedRecordings`, and `PlaybackController` in `PlayerView.swift`.
Every route the app calls is in `src/server.js`; the app adds no server
changes.

## Picture in picture (two streams)

A second stream can play in a corner of the full-screen player: two live
channels, two recordings, or one of each (a game being recorded plus a live
one, for example). The corner stream is muted; the main one has the audio.

Starting it, with something already playing:

- **Live TV**: hold Select on a channel → *Watch in Picture in Picture*.
- **Guide**: select a program → *Watch … in Picture in Picture*.
- **Recordings**: a recording's page → *Play in Picture in Picture* (a
  capture in progress joins at its live edge, anything else where it was left).
- **In the player**: transport bar menu → *Picture in Picture* → *Open a
  channel in the corner*.

The *Picture in Picture* menu in the player also swaps the two (nothing is
re-tuned: the two players keep going, only their roles and the audio change),
pauses/resumes, retries or closes the corner stream, and picks its corner and
size. Asking to watch what's already in the corner swaps instead of tuning a
second copy; asking for what's already the main stream does nothing.

Leaving the player (Menu) keeps both streams running; the mini player on the
browse screens shows the main one, with a small PiP mark when a corner stream
is also playing. Play/Pause while browsing controls the main stream. Coming
back to the player shows both again. Leaving the app saves and stops both,
and coming back restores both. Closing the main stream (the error screen's
Close) promotes the corner stream to main.

Limits to expect:

- **Tuners.** Each live channel needs a Tablo tuner; a recording in progress
  holds one too. Watching a channel that is being recorded reuses that
  recording (no extra tuner). On a two-tuner Tablo, recording one game and
  watching two other live channels is one tuner short: the corner stream shows
  the proxy's "All tuners busy" message with Retry / Close in the menu.
- **Encoding.** Two streams are two transcodes on the proxy host at once.
- The tile is drawn under the system controls, so the transport bar and the
  swipe-down panel cover it while they're up; top corners keep it clear of
  the transport bar.

## Full timelines (how recordings and live TV play)

The app asks the proxy for two stream shapes the web UI doesn't use:

- **Recordings** (`/stream/hls/recording/:id?vod=1`, `src/timeline.js`): the
  proxy publishes every 4-second segment of the whole recording up front and
  transcodes a segment only when the player asks for it, restarting ffmpeg
  wherever the player jumps. A finished recording is a plain VOD playlist
  (real duration, scrub anywhere, "From Beginning" works); one still being
  captured is an EVENT playlist from its start to the capture point, opened
  at live. A channel that's being recorded plays this way too, so you can
  swipe back to where the recording began.
- **Live TV** (`/stream/hls/channel/:id?dvr=1`): an append-only playlist from
  the moment you tune in, instead of a 6-minute rolling window. It behaves
  like a recording whose start is when you tuned in and whose end is live.

Segments from different encoder runs are interchangeable because keyframes
are forced every 4 s (`-g 120 -force_key_frames`), `-start_number` sets the
index, and `-output_ts_offset` + `-hls_segment_options movflags=+frag_discont`
put absolute time in every fragment with a byte-identical init header.
Verified with VAAPI (sanctarus) and x264 (VideoToolbox is not used for
timelines: it ignores forced keyframes and its headers differ per run).

tvOS 18.1+ won't pause a live stream while its rewind window is short
(Apple forums thread 772697; on device: refused at 48 s, allowed at 112 s),
so the player also handles Play/Pause and clickpad pause itself when the
system player doesn't react (`TabloPlayerViewController`).

## App icon

`icon/make_icon.swift` draws the layered home-screen icon (background glow /
TV / antennas + glare + record dot, so it gets the tvOS focus parallax), the
App Store icon, and the Top Shelf banners with Core Graphics into
`Sources/Assets.xcassets`. Edit and re-run from `tvos/`:

    swift icon/make_icon.swift

## Install on the Apple TV from the terminal

With Xcode signed in (Settings → Accounts) and the Apple TV paired (Window →
Devices and Simulators), this builds, signs, installs and launches without the
Xcode UI. It is also a manual way to renew the free-team install:

```sh
tvos/install-appletv.sh                    # default device: "Entertainment Room"
tvos/install-appletv.sh "Living Room"      # another paired Apple TV
```

The team id and bundle id live in `project.yml`, so regenerating the project
keeps them. The first signing on a Mac asks for keychain access to the Apple
Development key; choose Always Allow so unattended renewals don't hang.

## Keeping it installed: atvloadly on sanctarus

A free Apple ID signs apps with a profile that expires after 7 days. Signing and
reinstalling run on **sanctarus**, which is always on, through
[atvloadly](https://github.com/bitxeno/atvloadly) (Docker, `~/atvloadly/docker-compose.yml`,
data in `/etc/atvloadly`). It re-signs every installed app nightly (03:00–06:30)
and installs it on the Apple TV over Wi-Fi. A Mac isn't involved.

New code reaches the TV like this: a push to main that touches `tvos/` runs
`.github/workflows/tvos-ipa.yml`, which builds an unsigned IPA on a GitHub macOS
runner (`tvos/scripts/build-ipa.sh`) and publishes it as a `tvos-N` release,
keeping the newest 3. atvloadly checks the release every 6 hours and installs a
new build automatically.

- **Web UI:** it has no login and holds the Apple ID, so it listens on
  localhost only: `ssh -L 5533:localhost:5533 mwgreen@192.168.68.77`, then
  http://localhost:5533.
- **Bundle ID:** atvloadly installs the app as `<bundle id>.<TEAM_ID>`. A copy
  from `install-appletv.sh` is a separate app, so don't mix the two.
- **After a tvOS update,** re-pair the Apple TV in atvloadly (TV: Settings >
  Remotes and Devices > Remote App and Devices).
- **Limit:** a free Apple ID keeps at most 3 apps active at once. TabloTV and
  StreamingFinder (tomato-streams) use two.


### Fallback: refresh from the Mac (retired)

`scripts/refresh.sh` with the launchd agent `scripts/com.mwgreen.tablo-tv-refresh.plist`
rebuilt and reinstalled the app from the Mac with Xcode signing. It's turned off
(the plist is parked in `~/Library/LaunchAgents/disabled/`) so it doesn't use
up the Apple ID's app and certificate slots alongside atvloadly. Its setup notes
are in the header of `scripts/refresh.sh`.
