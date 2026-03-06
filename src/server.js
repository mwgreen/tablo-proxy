import express from 'express';
import { spawn } from 'child_process';
import { fileURLToPath } from 'url';
import { dirname, join } from 'path';
import { mkdirSync, rmSync, existsSync, readFileSync, writeFileSync } from 'fs';
import {
  getChannels, getRecordings, getGuideData,
  startWatch, startRecordingWatch, fetchChannels, fetchRecordings,
} from './tablo.js';

const __dirname = dirname(fileURLToPath(import.meta.url));
const app = express();
const DATA_DIR = join(__dirname, '..', 'data');
const TRANSCODE_DIR = join(DATA_DIR, 'hls');
const FAVORITES_FILE = join(DATA_DIR, 'favorites.json');

function loadFavorites() {
  try {
    return JSON.parse(readFileSync(FAVORITES_FILE, 'utf8'));
  } catch { return []; }
}

function saveFavorites(ids) {
  writeFileSync(FAVORITES_FILE, JSON.stringify(ids));
}

// Active transcode sessions: sessionId -> { ffmpeg, dir, sourceUrl, startOffset }
const sessions = new Map();

// Serve static files
app.use(express.static(join(__dirname, '..', 'public')));

// API routes
app.get('/api/channels', (req, res) => res.json(getChannels()));
app.get('/api/recordings', (req, res) => res.json(getRecordings()));
app.get('/api/guide', (req, res) => res.json(getGuideData()));

app.get('/api/favorites', (req, res) => res.json(loadFavorites()));

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
    const playlistUrl = await startWatch(req.params.channelId);
    const sessionId = startTranscode(playlistUrl, 0);
    res.json({ url: `/hls/${sessionId}/stream.m3u8`, sessionId });
  } catch (e) {
    res.status(500).json({ error: e.message });
  }
});

// Start transcoded HLS session for a recording
app.get('/stream/hls/recording/:recordingId', async (req, res) => {
  try {
    const playlistUrl = await startRecordingWatch(req.params.recordingId);
    const sessionId = startTranscode(playlistUrl, 0);
    res.json({ url: `/hls/${sessionId}/stream.m3u8`, sessionId });
  } catch (e) {
    res.status(500).json({ error: e.message });
  }
});

// Seek: restart transcode from a given offset
app.post('/api/seek/:sessionId', express.json(), (req, res) => {
  const session = sessions.get(req.params.sessionId);
  if (!session) {
    return res.status(404).json({ error: 'Session not found' });
  }

  const offset = parseFloat(req.body.offset) || 0;
  const sourceUrl = session.sourceUrl;

  // Kill old ffmpeg and clean up files
  session.ffmpeg.kill('SIGINT');
  try { rmSync(session.dir, { recursive: true, force: true }); } catch {}

  // Restart transcode from new offset, reusing same session ID
  const dir = session.dir;
  mkdirSync(dir, { recursive: true });
  const outputPath = join(dir, 'stream.m3u8');

  const args = [];
  if (offset > 0) {
    args.push('-ss', String(offset));
  }
  args.push(
    '-i', sourceUrl,
    '-c:v', 'libx264',
    '-preset', 'ultrafast',
    '-tune', 'zerolatency',
    '-profile:v', 'main',
    '-level', '4.0',
    '-crf', '23',
    '-vf', 'yadif',
    '-c:a', 'aac',
    '-b:a', '128k',
    '-ac', '2',
    '-f', 'hls',
    '-hls_time', '4',
    '-hls_list_size', '0',
    '-hls_flags', 'independent_segments',
    '-hls_segment_type', 'mpegts',
    '-hls_segment_filename', join(dir, 'seg%d.ts'),
    '-v', 'warning',
    outputPath,
  );

  const ffmpeg = spawn('ffmpeg', args);
  ffmpeg.stderr.on('data', (data) => {
    console.log(`[ffmpeg:${req.params.sessionId}] ${data.toString().trim()}`);
  });
  ffmpeg.on('close', (code) => {
    console.log(`[ffmpeg:${req.params.sessionId}] Exited with code ${code}`);
  });

  session.ffmpeg = ffmpeg;
  session.startOffset = offset;
  console.log(`[transcode] Session ${req.params.sessionId} seeked to ${offset}s`);

  res.json({ url: `/hls/${req.params.sessionId}/stream.m3u8`, startOffset: offset });
});

function startTranscode(sourceUrl, offset = 0) {
  const sessionId = Math.random().toString(36).slice(2, 10);
  const dir = join(TRANSCODE_DIR, sessionId);
  mkdirSync(dir, { recursive: true });

  const outputPath = join(dir, 'stream.m3u8');

  const args = [];
  if (offset > 0) {
    args.push('-ss', String(offset));
  }
  args.push(
    '-i', sourceUrl,
    '-c:v', 'libx264',
    '-preset', 'ultrafast',
    '-tune', 'zerolatency',
    '-profile:v', 'main',
    '-level', '4.0',
    '-crf', '23',
    '-vf', 'yadif',
    '-c:a', 'aac',
    '-b:a', '128k',
    '-ac', '2',
    '-f', 'hls',
    '-hls_time', '4',
    '-hls_list_size', '0',
    '-hls_flags', 'independent_segments',
    '-hls_segment_type', 'mpegts',
    '-hls_segment_filename', join(dir, 'seg%d.ts'),
    '-v', 'warning',
    outputPath,
  );

  const ffmpeg = spawn('ffmpeg', args);

  ffmpeg.stderr.on('data', (data) => {
    console.log(`[ffmpeg:${sessionId}] ${data.toString().trim()}`);
  });

  ffmpeg.on('close', (code) => {
    console.log(`[ffmpeg:${sessionId}] Exited with code ${code}`);
  });

  sessions.set(sessionId, { ffmpeg, dir, sourceUrl, startOffset: offset });
  console.log(`[transcode] Session ${sessionId} started → ${sourceUrl}`);

  // Auto-cleanup after 6 hours
  setTimeout(() => cleanupSession(sessionId), 6 * 60 * 60 * 1000);

  return sessionId;
}

function cleanupSession(sessionId) {
  const session = sessions.get(sessionId);
  if (!session) return;
  session.ffmpeg.kill('SIGINT');
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

  const ffmpeg = spawn('ffmpeg', [
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

  return new Promise((resolve) => {
    const server = app.listen(port, () => {
      console.log(`[server] tablo-proxy running at http://localhost:${port}`);
      resolve(server);
    });
  });
}
