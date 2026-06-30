import express from 'express';
import { spawn, execSync } from 'child_process';
import { fileURLToPath } from 'url';
import { dirname, join } from 'path';
import { mkdirSync, rmSync, existsSync, readFileSync, writeFileSync } from 'fs';
import {
  getChannels, getRecordings, getGuideData,
  startWatch, startRecordingWatch, fetchChannels, fetchRecordings, fetchGuide, fetchSeriesIndex,
  resolveChannelId, getSeriesIndex, scheduleSeries, unscheduleSeries, getScheduledSeries,
  getTunerStatus, scheduleAiring, deleteRecording, stopRecording,
} from './tablo.js';

const __dirname = dirname(fileURLToPath(import.meta.url));
const IS_LINUX = process.platform === 'linux';
const FFMPEG = process.env.FFMPEG_PATH || (IS_LINUX ? 'ffmpeg' : '/opt/homebrew/bin/ffmpeg');
const HLS_TRANSCODE = join(__dirname, '..', 'bin', 'hls-transcode');
// Swift GPU transcoder is macOS-only; on Linux always use FFmpeg with hardware accel
const USE_GPU = process.env.ENCODER === 'gpu' && !IS_LINUX;
const app = express();
const DATA_DIR = join(__dirname, '..', 'data');
const TRANSCODE_DIR = join(DATA_DIR, 'hls');
const FAVORITES_FILE = join(DATA_DIR, 'favorites.json');

// Detect Linux hardware accel: prefer VAAPI, fall back to QSV, then software
let linuxHwAccel = null;
if (IS_LINUX) {
  try {
    // Check for VAAPI device
    execSync('test -e /dev/dri/renderD128', { stdio: 'ignore' });
    linuxHwAccel = 'vaapi';
  } catch {
    try {
      execSync(`${FFMPEG} -hide_banner -init_hw_device qsv=hw -filter_hw_device hw -f lavfi -i nullsrc -frames:v 1 -c:v h264_qsv -f null - 2>/dev/null`, { stdio: 'ignore' });
      linuxHwAccel = 'qsv';
    } catch {
      // No hardware accel available
    }
  }
}

function getHwAccelInputArgs() {
  if (!IS_LINUX || !linuxHwAccel) return [];
  if (linuxHwAccel === 'vaapi') {
    return ['-hwaccel', 'vaapi', '-hwaccel_device', '/dev/dri/renderD128', '-hwaccel_output_format', 'vaapi'];
  }
  if (linuxHwAccel === 'qsv') {
    return ['-hwaccel', 'qsv', '-hwaccel_output_format', 'qsv'];
  }
  return [];
}

function getVideoEncodeArgs() {
  if (IS_LINUX && linuxHwAccel === 'vaapi') {
    return [
      '-c:v', 'h264_vaapi',
      '-rc_mode', 'CQP', '-qp', '24',
      '-profile:v', 'main', '-level', '4.0',
      '-bf', '0',
      // Suppress SEI insertion. The h264_vaapi AU header buffer is hardcoded
      // at 8192 bytes; broadcast OTA sources can produce SEI payloads that
      // exceed it (a53_cc + timing + recovery_point), causing
      // "Access unit too large" encode failures. We can't pass CCs through
      // an all-GPU pipeline anyway (see CC notes), so dropping SEI is free.
      '-sei', '0',
    ];
  }
  if (IS_LINUX && linuxHwAccel === 'qsv') {
    return ['-c:v', 'h264_qsv', '-b:v', '4M', '-profile:v', 'main', '-level', '40'];
  }
  if (IS_LINUX) {
    // Software fallback
    return ['-c:v', 'libx264', '-b:v', '4M', '-profile:v', 'main', '-level', '4.0', '-preset', 'fast'];
  }
  return ['-c:v', 'h264_videotoolbox', '-b:v', '4M', '-profile:v', 'main', '-level', '4.0'];
}

function loadFavorites() {
  try {
    const favs = JSON.parse(readFileSync(FAVORITES_FILE, 'utf8'));
    // Migrate legacy cloud IDs (strings like "S20370_002_01") to numeric device IDs
    const channels = getChannels();
    const migrated = favs.map(id => {
      if (typeof id === 'string' && channels.length > 0) {
        const ch = channels.find(c => c.cloudId === id);
        if (ch) return ch.id;
      }
      return id;
    });
    if (JSON.stringify(migrated) !== JSON.stringify(favs)) {
      saveFavorites(migrated);
    }
    return migrated;
  } catch { return []; }
}

function saveFavorites(ids) {
  writeFileSync(FAVORITES_FILE, JSON.stringify(ids));
}

// Active transcode sessions: sessionId -> { ffmpeg, dir, sourceUrl, startOffset, cleanupTimer }
const sessions = new Map();
const SESSION_INACTIVITY_TIMEOUT = 5 * 60 * 1000; // 5 minutes of no segment/playlist requests

function touchSession(sessionId) {
  const session = sessions.get(sessionId);
  if (!session) return;
  if (session.cleanupTimer) clearTimeout(session.cleanupTimer);
  session.cleanupTimer = setTimeout(() => cleanupSession(sessionId), SESSION_INACTIVITY_TIMEOUT);
}

// Serve static files
app.use(express.static(join(__dirname, '..', 'public'), {
  // Don't let browsers cache the SPA shell — frontend JS changes ship as
  // updates to index.html, and a stale cached copy will silently disable any
  // client-side fixes. no-store (not just no-cache) because iOS Safari can
  // serve a cached page without revalidating; no-store forbids storing it.
  etag: false,
  lastModified: false,
  setHeaders: (res) => {
    res.setHeader('Cache-Control', 'no-store, no-cache, must-revalidate, max-age=0');
    res.setHeader('Pragma', 'no-cache');
    res.setHeader('Expires', '0');
  },
}));

// API routes
app.get('/api/channels', (req, res) => res.json(getChannels()));
app.get('/api/recordings', (req, res) => res.json(getRecordings()));
app.get('/api/guide', (req, res) => res.json(getGuideData()));

app.get('/api/tuners', async (req, res) => {
  try {
    res.json(await getTunerStatus());
  } catch (e) {
    res.status(500).json({ error: e.message });
  }
});

app.get('/api/favorites', (req, res) => res.json(loadFavorites()));

// Recording schedule
app.get('/api/series', (req, res) => res.json(getSeriesIndex()));
app.get('/api/scheduled', (req, res) => res.json(getScheduledSeries()));

app.post('/api/record/:showId', express.json(), async (req, res) => {
  try {
    const rule = req.body?.rule || 'new';
    const data = await scheduleSeries(req.params.showId, rule);
    res.json({ ok: true, schedule: data.schedule });
  } catch (e) {
    res.status(400).json({ error: e.message });
  }
});

app.post('/api/record-airing', express.json(), async (req, res) => {
  try {
    const { showId, datetime, schedule, channelIdentifier } = req.body;
    if (!showId || !datetime) return res.status(400).json({ error: 'showId and datetime required' });
    const data = await scheduleAiring(showId, datetime, schedule !== false, channelIdentifier || null);
    res.json({ ok: true, schedule: data.schedule });
  } catch (e) {
    res.status(400).json({ error: e.message });
  }
});

app.delete('/api/record/:showId', async (req, res) => {
  try {
    const data = await unscheduleSeries(req.params.showId);
    res.json({ ok: true, schedule: data.schedule });
  } catch (e) {
    res.status(400).json({ error: e.message });
  }
});

app.delete('/api/recording/:recordingId', async (req, res) => {
  try {
    await deleteRecording(req.params.recordingId);
    res.json({ ok: true });
  } catch (e) {
    res.status(400).json({ error: e.message });
  }
});

app.post('/api/recording/:recordingId/stop', async (req, res) => {
  try {
    await stopRecording(req.params.recordingId);
    res.json({ ok: true });
  } catch (e) {
    res.status(400).json({ error: e.message });
  }
});

app.post('/api/favorites', express.json(), (req, res) => {
  if (!Array.isArray(req.body)) return res.status(400).json({ error: 'Expected array of channel IDs' });
  saveFavorites(req.body);
  res.json({ ok: true });
});

app.get('/api/guide/:channelId', (req, res) => {
  res.json(getGuideData()[req.params.channelId] || []);
});

app.post('/api/refresh', async (req, res) => {
  try {
    await fetchChannels();
    await fetchRecordings();
    if (req.query.guide === '1') {
      const days = parseInt(process.env.GUIDE_DAYS || '2', 10);
      await fetchGuide(days);
      await fetchSeriesIndex();
    }
    res.json({ ok: true });
  } catch (e) {
    res.status(500).json({ error: e.message });
  }
});

// Start transcoded HLS session for a channel
app.get('/stream/hls/channel/:channelId', async (req, res) => {
  try {
    // Check tuner availability before attempting watch
    try {
      const tuners = await getTunerStatus();
      const free = tuners.filter(t => !t.in_use);
      if (free.length === 0) {
        const channels = getChannels();
        const details = tuners.filter(t => t.in_use).map(t => {
          const chId = t.channel?.split('/').pop();
          const ch = channels.find(c => c.id === Number(chId));
          const name = ch ? `${ch.number} ${ch.name}` : t.channel;
          return t.recording ? `${name} (recording)` : `${name} (watching)`;
        }).join(', ');
        return res.status(409).json({ error: `All tuners busy: ${details}` });
      }
    } catch (e) {
      // tuner check failed, try anyway
    }
    const playlistUrl = await startWatch(req.params.channelId);
    const sessionId = await startTranscode(playlistUrl, 0, true);
    res.json({ url: `/hls/${sessionId}/stream.m3u8`, sessionId });
  } catch (e) {
    res.status(500).json({ error: e.message });
  }
});

// Start transcoded HLS session for a recording
app.get('/stream/hls/recording/:recordingId', async (req, res) => {
  try {
    const offset = parseFloat(req.query.offset) || 0;
    const playlistUrl = await startRecordingWatch(req.params.recordingId);
    const sessionId = await startTranscode(playlistUrl, offset);
    res.json({ url: `/hls/${sessionId}/stream.m3u8`, sessionId });
  } catch (e) {
    res.status(500).json({ error: e.message });
  }
});

// Seek: restart transcode from a given offset
app.post('/api/seek/:sessionId', express.json(), async (req, res) => {
  const session = sessions.get(req.params.sessionId);
  if (!session) {
    return res.status(404).json({ error: 'Session not found' });
  }

  const offset = parseFloat(req.body.offset) || 0;
  const sourceUrl = session.sourceUrl;
  const sid = req.params.sessionId;
  const live = session.live;

  cleanupSession(sid);

  // Restart transcode reusing same session ID
  const dir = join(TRANSCODE_DIR, sid);
  mkdirSync(dir, { recursive: true });
  await startTranscodeWithId(sid, dir, sourceUrl, offset, live);

  // Wait for first segment before returning
  const seg0Path = join(dir, 'seg0.m4s');
  for (let i = 0; i < 300; i++) {
    if (existsSync(seg0Path)) break;
    await new Promise(r => setTimeout(r, 100));
  }

  console.log(`[transcode] Session ${sid} seeked to ${offset}s`);
  // Cache-bust the playlist URL so hls.js's internal fragment cache treats
  // the post-seek stream as a fresh source. Without this, hls.js may reuse
  // already-loaded seg0/seg1/etc. (same URL, different content) and replay
  // the pre-seek position.
  res.json({ url: `/hls/${sid}/stream.m3u8?t=${Date.now()}`, startOffset: offset });
});

async function startTranscode(sourceUrl, offset = 0, live = false) {
  const sessionId = Math.random().toString(36).slice(2, 10);
  const dir = join(TRANSCODE_DIR, sessionId);
  mkdirSync(dir, { recursive: true });
  await startTranscodeWithId(sessionId, dir, sourceUrl, offset, live);

  // Wait for 2 segments (~8s buffer) before returning URL to client
  const seg1Path = join(dir, 'seg1.m4s');
  for (let i = 0; i < 300; i++) {
    if (existsSync(seg1Path)) break;
    await new Promise(r => setTimeout(r, 100));
  }

  touchSession(sessionId);
  return sessionId;
}

// Resolve a master HLS playlist to its sub-playlist URL.
async function resolveSubPlaylist(masterUrl) {
  const text = await (await fetch(masterUrl)).text();
  const lines = text.split(/\r?\n/);
  const subRel = lines.find(l => l && !l.startsWith('#'));
  if (!subRel) throw new Error('master playlist has no sub-playlist URI');
  return new URL(subRel, masterUrl).toString();
}

// Pre-fetch the source sub-playlist and decide how to position ffmpeg's HLS
// demuxer for a given target offset (seconds). Tablo's HLS demuxer can't
// reliably honor `-ss` against a live (no-ENDLIST) source — for those we
// compute the segment index whose start matches the target and pass
// `-live_start_index N`. For VOD (with ENDLIST) `-ss` works fine.
// Segments behind the live edge to begin a live channel (ffmpeg's native
// negative live_start_index counts from the end of the source playlist).
// Tablo's source segments are ~1s, so this is a ~8s startup cushion.
const LIVE_EDGE_SEGMENTS_BACK = 8;

// DVR depth for live channels: number of 4s segments retained in the sliding
// window. 90 * 4s = 6 minutes of in-player rewind.
const LIVE_DVR_SEGMENTS = 90;

async function computeSeekArgs(sourceUrl, offset, live = false) {
  if (offset <= 0) {
    // Live channel "watch live": start near the live edge. Tablo serves a long
    // rolling buffer (tens of minutes); a positive index 0 would begin far in
    // the past and transcode forward at 1x, never reaching real live. ffmpeg's
    // negative live_start_index counts segments from the END of the source
    // playlist — deterministic and free of the race where the source playlist
    // is still short right after a watch session starts.
    if (live) return ['-live_start_index', String(-LIVE_EDGE_SEGMENTS_BACK)];
    // Recording / VOD: begin at the start.
    return ['-live_start_index', '0'];
  }
  // offset > 0: index into the source playlist to find the target segment.
  try {
    const subUrl = await resolveSubPlaylist(sourceUrl);
    const text = await (await fetch(subUrl)).text();
    const isVod = /^#EXT-X-ENDLIST/m.test(text);
    const durs = [];
    for (const line of text.split(/\r?\n/)) {
      const m = line.match(/^#EXTINF:([0-9.]+)/);
      if (m) durs.push(parseFloat(m[1]));
    }

    if (isVod) {
      return ['-ss', String(offset)];
    }
    // Live with explicit offset: walk EXTINF durations to find the segment
    // whose start <= offset < end.
    let segIndex = 0;   // 0-based index from start of playlist
    let elapsed = 0;
    for (const dur of durs) {
      if (elapsed + dur > offset) break;
      elapsed += dur;
      segIndex++;
    }
    return ['-live_start_index', String(segIndex)];
  } catch (e) {
    console.log(`[seek] computeSeekArgs failed (${e.message}); falling back`);
    return offset > 0 ? ['-ss', String(offset)] : ['-live_start_index', '0'];
  }
}

async function startTranscodeWithId(sessionId, dir, sourceUrl, offset, live = false) {
  const outputPath = join(dir, 'stream.m3u8');

  if (USE_GPU) {
    // All-Swift: TS demux + MPEG-2 decode (VTDecompressionSession) + H.264 encode (VideoToolbox) + fMP4 HLS
    const args = [sourceUrl, dir, '4000000', '4', String(offset)];
    if (live) args.push('--live');
    const proc = spawn(HLS_TRANSCODE, args);
    proc.stderr.on('data', (d) => console.log(`[gpu:${sessionId}] ${d.toString().trim()}`));
    proc.on('close', (code) => console.log(`[gpu:${sessionId}] Exited with code ${code}`));
    sessions.set(sessionId, { ffmpeg: proc, dir, sourceUrl, startOffset: offset, live });
  } else {
    // FFmpeg with hardware-accelerated encode (+ decode on Linux)
    const hwInputArgs = getHwAccelInputArgs();
    const videoEncArgs = getVideoEncodeArgs();
    const seekArgs = await computeSeekArgs(sourceUrl, offset, live);
    console.log(`[seek] session ${sessionId}: live=${live} offset=${offset} -> ${seekArgs.join(' ')}`);
    const args = [...seekArgs];
    args.push(
      ...hwInputArgs,
      '-i', sourceUrl,
      ...videoEncArgs,
      '-r', '30',  // Clean 30fps — eliminates AirPlay 29.97/30Hz cadence mismatch
      // VAAPI keeps frames in GPU memory — no pix_fmt conversion needed
      ...(linuxHwAccel === 'vaapi' ? [] : ['-pix_fmt', 'yuv420p']),
      '-c:a', 'aac', '-b:a', '128k', '-ac', '2',
      '-f', 'hls',
      '-hls_time', '4',
      ...(live
        // Live channel: a sliding-window LIVE playlist (finite list, segments
        // deleted as they age out, no EXT-X-PLAYLIST-TYPE). Players — including
        // iOS native HLS — open at the live edge and track it automatically,
        // and can rewind within the DVR window. This is the standard live-TV
        // primitive; an EVENT playlist would make iOS start at the beginning.
        ? [
            '-hls_list_size', String(LIVE_DVR_SEGMENTS),
            '-hls_flags', 'independent_segments+delete_segments+program_date_time',
          ]
        // Recording (VOD or in-progress): append-only EVENT playlist with the
        // full timeline seekable from the start.
        : [
            '-hls_list_size', '0',
            '-hls_playlist_type', 'event',
            '-hls_flags', 'independent_segments',
          ]),
      '-hls_segment_type', 'fmp4',
      '-hls_fmp4_init_filename', 'init.mp4',
      '-hls_segment_filename', join(dir, 'seg%d.m4s'),
      '-v', 'warning',
      outputPath,
    );

    const ffmpeg = spawn(FFMPEG, args);
    ffmpeg.stderr.on('data', (d) => console.log(`[ffmpeg:${sessionId}] ${d.toString().trim()}`));
    ffmpeg.on('close', (code) => console.log(`[ffmpeg:${sessionId}] Exited with code ${code}`));
    sessions.set(sessionId, { ffmpeg, dir, sourceUrl, startOffset: offset, live });
  }

  const encoderLabel = USE_GPU ? 'GPU/Swift' : IS_LINUX ? `FFmpeg/${linuxHwAccel || 'software'}` : 'FFmpeg/VideoToolbox';
  console.log(`[transcode] Session ${sessionId} started (${encoderLabel}) → ${sourceUrl}`);
}

function cleanupSession(sessionId) {
  const session = sessions.get(sessionId);
  if (!session) return;
  if (session.cleanupTimer) clearTimeout(session.cleanupTimer);
  session.ffmpeg.kill('SIGKILL');
  try { rmSync(session.dir, { recursive: true, force: true }); } catch {}
  sessions.delete(sessionId);
  console.log(`[transcode] Session ${sessionId} cleaned up`);
}

// Serve transcoded HLS files
app.get('/hls/:sessionId/{*path}', (req, res) => {
  const session = sessions.get(req.params.sessionId);
  if (!session) {
    return res.status(404).send('Session expired');
  }
  touchSession(req.params.sessionId);

  const pathParam = Array.isArray(req.params.path) ? req.params.path.join('/') : req.params.path;
  const filePath = join(session.dir, pathParam);
  if (!filePath.startsWith(session.dir) || !existsSync(filePath)) {
    return res.status(404).send('Not found');
  }

  const ext = filePath.split('.').pop();
  if (ext === 'm3u8') {
    res.setHeader('Content-Type', 'application/vnd.apple.mpegurl');
  } else if (ext === 'ts') {
    res.setHeader('Content-Type', 'video/mp2t');
  } else if (ext === 'm4s' || ext === 'mp4') {
    res.setHeader('Content-Type', 'video/mp4');
  }
  res.setHeader('Access-Control-Allow-Origin', '*');
  // no-store + Pragma + Expires belt-and-braces. Segment filenames are
  // reused across sessions/seeks (seg0.m4s always restarts at the new
  // offset), so any caching here makes the browser show pre-seek content.
  res.setHeader('Cache-Control', 'no-store, no-cache, must-revalidate, max-age=0');
  res.setHeader('Pragma', 'no-cache');
  res.setHeader('Expires', '0');

  if (ext === 'm3u8') {
    let body = readFileSync(filePath, 'utf8');
    // For a live channel, tell the player to OPEN near the live edge rather
    // than at the start of the DVR window. iOS native HLS otherwise begins at
    // the oldest segment and can only move forward through buffered data, so
    // the Live button can never reach an unbuffered live edge. EXT-X-START with
    // a negative TIME-OFFSET is the HLS-standard way to set the entry point.
    if (session.live && !body.includes('#EXT-X-START')) {
      body = body.replace(
        /(#EXT-X-TARGETDURATION:[^\n]*\n)/,
        `$1#EXT-X-START:TIME-OFFSET=-12,PRECISE=YES\n`,
      );
    }
    return res.send(body);
  }
  res.send(readFileSync(filePath));
});

// Stop a session
app.post('/api/stop/:sessionId', (req, res) => {
  cleanupSession(req.params.sessionId);
  res.json({ ok: true });
});

// MPEG-TS stream for VLC/mpv
app.get('/stream/channel/:channelId', async (req, res) => {
  try {
    const playlistUrl = await startWatch(req.params.channelId);
    proxyHlsAsStream(playlistUrl, req, res);
  } catch (e) {
    res.status(500).json({ error: e.message });
  }
});

app.get('/stream/recording/:recordingId', async (req, res) => {
  try {
    const playlistUrl = await startRecordingWatch(req.params.recordingId);
    proxyHlsAsStream(playlistUrl, req, res);
  } catch (e) {
    res.status(500).json({ error: e.message });
  }
});

function proxyHlsAsStream(playlistUrl, req, res) {
  res.setHeader('Content-Type', 'video/mp2t');
  res.setHeader('Transfer-Encoding', 'chunked');

  const ffmpeg = spawn(FFMPEG, [
    '-i', playlistUrl,
    '-c', 'copy',
    '-f', 'mpegts',
    '-v', 'warning',
    'pipe:1',
  ]);

  ffmpeg.stdout.pipe(res);
  ffmpeg.stderr.on('data', (d) => console.log(`[ffmpeg] ${d.toString().trim()}`));

  const cleanup = () => ffmpeg.kill('SIGINT');
  req.on('close', cleanup);
  req.on('error', cleanup);
}

export function startServer(port) {
  mkdirSync(TRANSCODE_DIR, { recursive: true });

  // Clean up any stale transcode processes from previous runs
  try { execSync('pkill -f hls-transcode 2>/dev/null || true'); } catch {}

  // Clean up child processes on exit
  process.on('exit', () => {
    for (const [id, session] of sessions) {
      try { session.ffmpeg?.kill('SIGKILL'); } catch {}
      try { session.decoder?.kill('SIGKILL'); } catch {}
    }
    try { execSync('pkill -9 -f hls-transcode 2>/dev/null || true'); } catch {}
  });
  process.on('SIGINT', () => process.exit());
  process.on('SIGTERM', () => process.exit());

  return new Promise((resolve) => {
    const server = app.listen(port, () => {
      console.log(`[server] tablo-proxy running at http://localhost:${port}`);
      resolve(server);
    });
  });
}
