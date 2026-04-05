import express from 'express';
import { spawn, execSync } from 'child_process';
import { fileURLToPath } from 'url';
import { dirname, join } from 'path';
import { mkdirSync, rmSync, existsSync, readFileSync, writeFileSync } from 'fs';
import {
  getChannels, getRecordings, getGuideData,
  startWatch, startRecordingWatch, fetchChannels, fetchRecordings,
  resolveChannelId, getSeriesIndex, scheduleSeries, unscheduleSeries, getScheduledSeries,
  getTunerStatus, scheduleAiring, deleteRecording,
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
    return ['-c:v', 'h264_vaapi', '-b:v', '4M'];
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
app.use(express.static(join(__dirname, '..', 'public')));

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
    const { showId, datetime, schedule } = req.body;
    if (!showId || !datetime) return res.status(400).json({ error: 'showId and datetime required' });
    const data = await scheduleAiring(showId, datetime, schedule !== false);
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
  startTranscodeWithId(sid, dir, sourceUrl, offset, live);

  // Wait for first segment before returning
  const seg0Path = join(dir, 'seg0.m4s');
  for (let i = 0; i < 300; i++) {
    if (existsSync(seg0Path)) break;
    await new Promise(r => setTimeout(r, 100));
  }

  console.log(`[transcode] Session ${sid} seeked to ${offset}s`);
  res.json({ url: `/hls/${sid}/stream.m3u8`, startOffset: offset });
});

async function startTranscode(sourceUrl, offset = 0, live = false) {
  // Kill all existing sessions — only one stream at a time
  for (const [id] of sessions) {
    cleanupSession(id);
  }

  const sessionId = Math.random().toString(36).slice(2, 10);
  const dir = join(TRANSCODE_DIR, sessionId);
  mkdirSync(dir, { recursive: true });
  startTranscodeWithId(sessionId, dir, sourceUrl, offset, live);

  // Wait for 2 segments (~8s buffer) before returning URL to client
  const seg1Path = join(dir, 'seg1.m4s');
  for (let i = 0; i < 300; i++) {
    if (existsSync(seg1Path)) break;
    await new Promise(r => setTimeout(r, 100));
  }

  touchSession(sessionId);
  return sessionId;
}

function startTranscodeWithId(sessionId, dir, sourceUrl, offset, live = false) {
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
    const args = [];
    if (offset > 0) args.push('-ss', String(offset));
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
      '-hls_list_size', '0',
      '-hls_flags', 'independent_segments',
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
  res.setHeader('Cache-Control', 'no-cache');
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
