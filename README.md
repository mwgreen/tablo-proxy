# tablo-proxy

A web-based proxy for Tablo TV (4th generation) that lets you watch live TV and recordings in a browser. The Tablo outputs MPEG-2 which browsers can't play natively — this proxy transcodes to H.264/HLS on the fly using FFmpeg.

## Features

- **Live TV** — watch any OTA channel via your Tablo
- **Recordings** — play back recorded shows with full seek support
- **TV Guide (EPG)** — browse what's on now and upcoming
- **Channel favorites** — filter the channel list to only the channels you care about
- **Seek bar** — server-side seek for recordings (FFmpeg restarts at the new offset)
- **Live + Recording hybrid** — if a live channel is being recorded, you get full DVR controls (seek back to the start)
- **Fullscreen & theater mode** — `f` for fullscreen, `t` for theater mode
- **Volume control** — mute (`m`) and volume slider
- **Keyboard shortcuts** — space/k (play/pause), j/l or arrows (±10s), and more
- **VLC/mpv support** — MPEG-TS stream endpoints for external players

## Requirements

- [Node.js](https://nodejs.org/) 18+
- [FFmpeg](https://ffmpeg.org/) installed and on your PATH
- A Tablo (4th gen) on your local network
- A Tablo account (email/password)

## Setup

```bash
npm install
cp .env.example .env
# Edit .env with your Tablo credentials
```

## Usage

```bash
node app.js
```

Then open `http://localhost:9480` in your browser.

### External player streams

For VLC or mpv, use the MPEG-TS endpoints directly:

```
http://localhost:9480/stream/channel/<channelId>
http://localhost:9480/stream/recording/<recordingId>
```

## How it works

1. Authenticates with the Tablo cloud API to get device access tokens
2. Discovers the local Tablo device on your network
3. Signs local API requests using HMAC-MD5 (the same auth the official app uses)
4. Starts an FFmpeg transcode from MPEG-2 → H.264 HLS when you select a channel/recording
5. Serves the HLS segments to the browser via hls.js

## Environment variables

| Variable | Default | Description |
|---|---|---|
| `TABLO_EMAIL` | (required) | Your Tablo account email |
| `TABLO_PASSWORD` | (required) | Your Tablo account password |
| `PORT` | `8181` | Server port |
| `GUIDE_DAYS` | `2` | Days of guide data to fetch (1-7) |

## License

MIT
