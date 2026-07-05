import { spawn, execFile } from 'child_process';
import { mkdirSync, readFileSync, writeFileSync, renameSync, rmSync, existsSync, statSync, readdirSync } from 'fs';
import { join, dirname } from 'path';
import { FFMPEG, FFPROBE, getHwAccelInputArgs, getVideoEncodeArgs, linuxHwAccel } from './encode.js';
import { getRecordings, fetchRecordings, startRecordingWatch, deleteRecording, fetchDeviceImage } from './tablo.js';

// Local recording archive. The Tablo is a capture buffer: once a recording is
// finished we pull its HLS stream, transcode ONCE (hardware) to a plain MP4 on
// the big disk, and keep our own metadata — after that, playback is static
// file serving with native seek, and the Tablo copy is disposable.
const LIBRARY_DIR = process.env.LIBRARY_DIR || '/mnt/storage/tablo';
const INDEX_FILE = join(LIBRARY_DIR, 'library.json');
const THUMBS_DIR = join(LIBRARY_DIR, '.thumbs');
const AUTO_ARCHIVE = process.env.AUTO_ARCHIVE !== '0';
const AUTO_DELETE_FROM_TABLO = process.env.AUTO_DELETE_FROM_TABLO === '1';
const POLL_MINUTES = parseInt(process.env.ARCHIVE_POLL_MINUTES || '10', 10);
// Auto-archive gives up on a recording after this many failed attempts so a
// corrupt capture doesn't burn the GPU every poll. A manual archive resets it.
const MAX_AUTO_RETRIES = 2;

let index = [];            // persisted entries (completed archives only)
let queue = [];            // recording ids waiting
const jobs = new Map();    // id -> { id, title, episode, status, progress, error }
const failCounts = new Map();
let working = false;
let initialized = false;

export function getLibrary() { return index; }
export function getArchiveJobs() { return [...jobs.values()]; }
export function getLibraryEntry(id) { return index.find(e => String(e.id) === String(id)); }
export function libraryFilePath(entry) { return join(LIBRARY_DIR, entry.file); }
export function libraryThumbPath(entry) { return entry.thumb ? join(LIBRARY_DIR, entry.thumb) : null; }

function loadIndex() {
  try {
    const entries = JSON.parse(readFileSync(INDEX_FILE, 'utf8'));
    // Drop entries whose file vanished (user deleted from disk directly)
    index = entries.filter(e => {
      const ok = existsSync(join(LIBRARY_DIR, e.file));
      if (!ok) console.warn(`[library] Missing file for "${e.title}" (${e.file}); dropping entry`);
      return ok;
    });
    if (index.length !== entries.length) saveIndex();
  } catch { index = []; }
}

function saveIndex() {
  writeFileSync(INDEX_FILE, JSON.stringify(index, null, 2));
}

// Windows-and-SMB-safe filenames; also guards against path traversal.
function sanitize(name) {
  return String(name).replace(/[\/\\:*?"<>|]/g, '-').replace(/\s+/g, ' ').trim().slice(0, 120) || 'Unknown';
}

// Plex/Jellyfin-style layout: tv/<Show>/Season NN/<Show> - SnnEnn - <Episode>.mp4
// so the archive is directly usable by other media servers later. Recordings
// without episode numbering get a date-stamped name (repeat captures of the
// same episode must not collide).
function buildRelPath(rec) {
  const show = sanitize(rec.title);
  let base;
  let dir;
  if (rec.seasonNumber && rec.episodeNumber) {
    const s = String(rec.seasonNumber).padStart(2, '0');
    const e = String(rec.episodeNumber).padStart(2, '0');
    dir = join('tv', show, `Season ${s}`);
    base = `${show} - S${s}E${e}${rec.episode ? ' - ' + sanitize(rec.episode) : ''}`;
  } else {
    const d = rec.date ? new Date(rec.date) : new Date(0);
    const stamp = isNaN(d) ? 'unknown-date'
      : `${d.getFullYear()}-${String(d.getMonth() + 1).padStart(2, '0')}-${String(d.getDate()).padStart(2, '0')} ${String(d.getHours()).padStart(2, '0')}${String(d.getMinutes()).padStart(2, '0')}`;
    dir = join('tv', show);
    base = `${show}${rec.episode ? ' - ' + sanitize(rec.episode) : ''} - ${stamp}`;
  }
  let rel = join(dir, `${base}.mp4`);
  for (let n = 2; existsSync(join(LIBRARY_DIR, rel)) || index.some(e => e.file === rel); n++) {
    rel = join(dir, `${base} (${n}).mp4`);
  }
  return rel;
}

function ffprobeDuration(file) {
  return new Promise((resolve) => {
    execFile(FFPROBE, ['-v', 'error', '-show_entries', 'format=duration', '-of', 'csv=p=0', file],
      (err, stdout) => resolve(err ? 0 : parseFloat(stdout) || 0));
  });
}

export function enqueueArchive(recordingId, { manual = false } = {}) {
  const id = String(recordingId);
  const rec = getRecordings().find(r => String(r.id) === id);
  if (!rec) throw new Error('Recording not found');
  if (rec.state === 'recording') throw new Error('Recording is still in progress');
  if (getLibraryEntry(id)) throw new Error('Already archived');
  const existing = jobs.get(id);
  if (existing && (existing.status === 'queued' || existing.status === 'transcoding' || existing.status === 'verifying')) {
    return existing;
  }
  if (manual) failCounts.delete(id);
  const job = { id, title: rec.title, episode: rec.episode, status: 'queued', progress: 0, error: null };
  jobs.set(id, job);
  queue.push(id);
  processQueue();
  return job;
}

// One transcode at a time: the GPU also serves live viewing sessions, and a
// serialized queue can never starve them.
async function processQueue() {
  if (working) return;
  working = true;
  try {
    while (queue.length > 0) {
      const id = queue.shift();
      const job = jobs.get(id);
      if (!job || job.status !== 'queued') continue;
      try {
        await archiveOne(id, job);
        failCounts.delete(id);
      } catch (e) {
        job.status = 'failed';
        job.error = e.message;
        failCounts.set(id, (failCounts.get(id) || 0) + 1);
        console.error(`[library] Archive failed for ${job.title} (${id}): ${e.message}`);
      }
    }
  } finally {
    working = false;
  }
}

async function archiveOne(id, job) {
  const rec = getRecordings().find(r => String(r.id) === String(id));
  if (!rec) throw new Error('Recording disappeared from Tablo');

  console.log(`[library] Archiving "${rec.title}${rec.episode ? ' - ' + rec.episode : ''}" (${id})`);
  const playlistUrl = await startRecordingWatch(id);

  const relPath = buildRelPath(rec);
  const outFile = join(LIBRARY_DIR, relPath);
  const partFile = outFile + '.part';
  mkdirSync(dirname(outFile), { recursive: true });

  const expected = rec.recordedDuration || rec.duration || 0;
  job.status = 'transcoding';

  await new Promise((resolve, reject) => {
    const args = [
      '-y',
      ...getHwAccelInputArgs(),
      '-i', playlistUrl,
      ...getVideoEncodeArgs(),
      '-r', '30',
      ...(linuxHwAccel === 'vaapi' ? [] : ['-pix_fmt', 'yuv420p']),
      '-c:a', 'aac', '-b:a', '128k', '-ac', '2',
      '-movflags', '+faststart',
      '-f', 'mp4',
      '-progress', 'pipe:1',
      '-v', 'warning',
      partFile,
    ];
    const proc = spawn(FFMPEG, args);
    let stderrTail = '';
    proc.stdout.on('data', (d) => {
      const m = String(d).match(/out_time_us=(\d+)/g);
      if (m && expected > 0) {
        const us = parseInt(m[m.length - 1].split('=')[1], 10);
        job.progress = Math.min(0.99, (us / 1e6) / expected);
      }
    });
    proc.stderr.on('data', (d) => {
      stderrTail = (stderrTail + d.toString()).slice(-2000);
      console.log(`[library:${id}] ${d.toString().trim()}`);
    });
    proc.on('error', reject);
    proc.on('close', (code) => {
      if (code === 0) resolve();
      else reject(new Error(`ffmpeg exited ${code}: ${stderrTail.split('\n').slice(-3).join(' ')}`));
    });
  });

  // Verify before trusting it (and long before anything deletes the Tablo
  // copy): the output must cover the recorded duration, minus slack for
  // segment rounding at the tail.
  job.status = 'verifying';
  const measured = await ffprobeDuration(partFile);
  const tolerance = Math.max(30, expected * 0.03);
  if (expected > 0 && measured < expected - tolerance) {
    try { rmSync(partFile, { force: true }); } catch {}
    throw new Error(`Output too short: ${Math.round(measured)}s of expected ${Math.round(expected)}s`);
  }
  renameSync(partFile, outFile);

  // Thumbnail — best-effort, the Tablo deletes its copy with the recording
  let thumbRel = null;
  if (rec.imageId) {
    const img = await fetchDeviceImage(rec.imageId);
    if (img) {
      mkdirSync(THUMBS_DIR, { recursive: true });
      thumbRel = join('.thumbs', `${id}.jpg`);
      writeFileSync(join(LIBRARY_DIR, thumbRel), img);
    }
  }

  const entry = {
    id: rec.id,
    title: rec.title,
    episode: rec.episode,
    seasonNumber: rec.seasonNumber,
    episodeNumber: rec.episodeNumber,
    description: rec.description,
    date: rec.date,
    duration: measured || expected,
    channel: rec.channel,
    file: relPath,
    thumb: thumbRel,
    size: statSync(outFile).size,
    archivedAt: new Date().toISOString(),
  };
  index = index.filter(e => String(e.id) !== String(id));
  index.push(entry);
  saveIndex();
  job.status = 'done';
  job.progress = 1;
  console.log(`[library] Archived "${entry.title}" → ${relPath} (${Math.round(entry.size / 1e6)} MB, ${Math.round(entry.duration / 60)} min)`);

  if (AUTO_DELETE_FROM_TABLO) {
    try {
      await deleteRecording(id);
      console.log(`[library] Deleted "${entry.title}" from Tablo after archive`);
    } catch (e) {
      console.warn(`[library] Post-archive Tablo delete failed: ${e.message}`);
    }
  }
}

export function deleteLibraryEntry(id) {
  const entry = getLibraryEntry(id);
  if (!entry) throw new Error('Not in library');
  rmSync(libraryFilePath(entry), { force: true });
  const thumb = libraryThumbPath(entry);
  if (thumb) { try { rmSync(thumb, { force: true }); } catch {} }
  // Prune now-empty show/season dirs so the tree doesn't accumulate husks
  let dir = dirname(libraryFilePath(entry));
  while (dir.startsWith(LIBRARY_DIR) && dir !== LIBRARY_DIR) {
    try {
      if (readdirSync(dir).length > 0) break;
      rmSync(dir, { recursive: true });
    } catch { break; }
    dir = dirname(dir);
  }
  index = index.filter(e => String(e.id) !== String(id));
  saveIndex();
  jobs.delete(String(id));
}

// Enqueue every finished Tablo recording that isn't archived yet. Runs on a
// timer; also invoked once at startup.
async function autoArchiveSweep() {
  try {
    await fetchRecordings();
  } catch (e) {
    console.warn(`[library] Auto-archive sweep: recordings fetch failed: ${e.message}`);
    return;
  }
  for (const rec of getRecordings()) {
    const id = String(rec.id);
    if (rec.state !== 'finished') continue;
    if (getLibraryEntry(id)) continue;
    if ((failCounts.get(id) || 0) >= MAX_AUTO_RETRIES) continue;
    const job = jobs.get(id);
    if (job && job.status !== 'failed') continue;
    try { enqueueArchive(id); } catch {}
  }
}

export function initLibrary() {
  if (initialized) return;
  initialized = true;
  mkdirSync(LIBRARY_DIR, { recursive: true });
  loadIndex();

  // A .part file is a transcode that died mid-flight (crash, power loss)
  const cleanParts = (dir) => {
    for (const name of readdirSync(dir, { withFileTypes: true })) {
      const p = join(dir, name.name);
      if (name.isDirectory()) cleanParts(p);
      else if (name.name.endsWith('.part')) { try { rmSync(p, { force: true }); } catch {} }
    }
  };
  try { cleanParts(LIBRARY_DIR); } catch {}

  console.log(`[library] ${index.length} archived recordings at ${LIBRARY_DIR} (auto-archive ${AUTO_ARCHIVE ? 'on' : 'off'}, auto-delete-from-tablo ${AUTO_DELETE_FROM_TABLO ? 'on' : 'off'})`);

  if (AUTO_ARCHIVE) {
    setTimeout(autoArchiveSweep, 30 * 1000);   // let startup settle first
    setInterval(autoArchiveSweep, POLL_MINUTES * 60 * 1000);
  }
}
