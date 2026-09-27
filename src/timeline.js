// Full-timeline HLS for a Tablo recording, transcoded on demand.
//
// The regular recording path runs one ffmpeg from a start offset and serves
// whatever it has produced so far (an EVENT playlist that grows), so a player
// can only move inside the transcoded stretch and restarts need a server seek.
// A timeline session instead publishes the whole recording up front — every
// 4-second segment from the start — and transcodes a segment only when the
// player asks for it. A request far from what the encoder is producing
// restarts the encoder right there. Players get a normal timeline: a finished
// recording is plain VOD (real duration, scrub anywhere), and one that's
// still being captured is an EVENT playlist from its start to the capture
// point, growing as it records.
//
// This works because every encoder run produces interchangeable segments:
// keyframes forced exactly every 4s, `-start_number` for the segment index,
// `-output_ts_offset` + `movflags=+frag_discont` so each fragment carries its
// absolute time and the init header is identical across runs (verified on the
// VAAPI and VideoToolbox encoders — see tvos/README.md, "Full timelines").
import { spawn } from 'child_process';
import { existsSync, readdirSync, rmSync, mkdirSync } from 'fs';
import { join } from 'path';
import { FFMPEG, linuxHwAccel, getHwAccelInputArgs, getVideoEncodeArgs, AUDIO_SYNC_ARGS } from './encode.js';


export const SEG = 4;                 // seconds per output segment
const FPS = 30;
const RESTART_AHEAD = 6;              // segments past the encoder frontier we'll wait for instead of restarting
const SEGMENT_WAIT_MS = 30000;        // how long a segment request may wait for the encoder
const SOURCE_REFRESH_MS = 3000;       // in-progress: how often to re-read the Tablo playlist
const LIVE_EDGE_MARGIN = 2;           // in-progress: seconds kept clear of the capture point

/// Encoder for timeline segments. VAAPI (sanctarus) is verified to cut
/// identical, keyframe-aligned segments across runs. VideoToolbox is not: it
/// ignores forced keyframes and its parameter sets differ per run, so
/// segments from different runs don't decode against one init header.
/// Everywhere else use x264 without B-frames — cheap at SD resolution.
function videoEncodeArgs() {
  if (linuxHwAccel === 'vaapi') return getVideoEncodeArgs();
  return ['-c:v', 'libx264', '-preset', 'veryfast', '-profile:v', 'main', '-level', '4.0',
          '-bf', '0', '-sc_threshold', '0', '-b:v', '4M', '-maxrate', '5M', '-bufsize', '8M'];
}

async function fetchText(url) {
  const res = await fetch(url, { signal: AbortSignal.timeout(10000) });
  if (!res.ok) throw new Error(`fetch ${url} failed: ${res.status}`);
  return res.text();
}

// Resolve a master playlist to its media playlist (Tablo serves one variant).
async function resolveMedia(masterUrl) {
  const text = await fetchText(masterUrl);
  if (/#EXTINF/.test(text)) return { url: masterUrl, text };
  const rel = text.split(/\r?\n/).find(l => l && !l.startsWith('#'));
  if (!rel) throw new Error('master playlist has no media playlist');
  const url = new URL(rel, masterUrl).toString();
  return { url, text: await fetchText(url) };
}

function parseMedia(text) {
  const starts = [];
  let t = 0;
  for (const m of text.matchAll(/^#EXTINF:([0-9.]+)/gm)) {
    starts.push(t);
    t += parseFloat(m[1]);
  }
  return { starts, total: t, finished: /^#EXT-X-ENDLIST/m.test(text) };
}

export class Timeline {
  constructor({ id, dir, masterUrl, log = console.log }) {
    this.id = id;
    this.dir = dir;
    this.masterUrl = masterUrl;
    this.log = log;
    this.mediaUrl = null;
    this.starts = [];
    this.total = 0;
    this.finished = false;
    this.refreshedAt = 0;
    this.refreshing = null;
    this.enc = null;          // { proc, start, frontier, gen, exited }
    this.gen = 0;
    this.reqSeq = 0;
    this.waiting = new Set(); // seqs of segment requests still waiting; the newest may restart the encoder
    this.stopped = false;
    mkdirSync(dir, { recursive: true });
  }

  async init() {
    await this.refreshSource(true);
  }

  async refreshSource(force = false) {
    if (this.finished && !force) return;
    if (!force && Date.now() - this.refreshedAt < SOURCE_REFRESH_MS) return;
    if (this.refreshing) return this.refreshing;
    this.refreshing = (async () => {
      try {
        const { url, text } = await resolveMedia(this.mediaUrl || this.masterUrl);
        this.mediaUrl = url;
        const p = parseMedia(text);
        this.starts = p.starts;
        this.total = p.total;
        this.finished = p.finished;
        this.refreshedAt = Date.now();
      } finally {
        this.refreshing = null;
      }
    })();
    return this.refreshing;
  }

  /// Number of whole segments that are safe to publish. A finished recording
  /// drops a partial tail (and half a second of slack for EXTINF rounding);
  /// one still recording stays clear of the capture point.
  get segmentCount() {
    const usable = this.finished ? this.total - 0.5 : this.total - LIVE_EDGE_MARGIN;
    return Math.max(0, Math.floor(usable / SEG));
  }

  get duration() { return this.segmentCount * SEG; }

  async playlist() {
    await this.refreshSource().catch(e => this.log(`[timeline:${this.id}] source refresh failed: ${e.message}`));
    const n = this.segmentCount;
    const lines = [
      '#EXTM3U',
      '#EXT-X-VERSION:7',
      `#EXT-X-TARGETDURATION:${SEG}`,
      '#EXT-X-MEDIA-SEQUENCE:0',
      `#EXT-X-PLAYLIST-TYPE:${this.finished ? 'VOD' : 'EVENT'}`,
      '#EXT-X-INDEPENDENT-SEGMENTS',
      '#EXT-X-MAP:URI="init.mp4"',
    ];
    for (let i = 0; i < n; i++) {
      lines.push(`#EXTINF:${SEG.toFixed(6)},`, `seg${i}.m4s`);
    }
    if (this.finished) lines.push('#EXT-X-ENDLIST');
    return lines.join('\n') + '\n';
  }

  segPath(k) { return join(this.dir, `seg${k}.m4s`); }

  /// Any encoder run's init header will do: they're byte-identical.
  initPath() {
    const f = readdirSync(this.dir).find(n => /^init-\d+\.mp4$/.test(n));
    return f ? join(this.dir, f) : null;
  }

  /// Highest contiguous segment the current encoder has written.
  frontier(enc) {
    let f = enc.frontier;
    while (existsSync(this.segPath(f + 1))) f++;
    enc.frontier = f;
    return f;
  }

  /// Start (or restart) the encoder so its first segment is k.
  startEncoder(k) {
    if (this.stopped) return;
    this.stopEncoder();
    const gen = ++this.gen;
    const target = k * SEG;
    let posIn = [];
    let posOut = [];
    if (this.finished) {
      // VOD source: ffmpeg's input seek is exact and fast. Always pass it,
      // even for 0, so every run's timestamps start exactly on the grid.
      posIn = ['-ss', String(target)];
    } else {
      // Still recording: the source is a live playlist, where input seeking
      // doesn't apply. Start at the source segment containing the target
      // and trim the remainder with an (exact) output seek. ffmpeg then keeps
      // following the playlist as the recording grows.
      let i = 0;
      while (i + 1 < this.starts.length && this.starts[i + 1] <= target) i++;
      posIn = ['-live_start_index', String(i)];
      const trim = target - (this.starts[i] || 0);
      if (trim > 0.001) posOut = ['-ss', trim.toFixed(6)];
    }
    const args = [
      '-hide_banner', '-v', 'warning', '-y',
      ...posIn,
      ...(linuxHwAccel === 'vaapi' ? getHwAccelInputArgs() : []),
      '-i', this.mediaUrl || this.masterUrl,
      ...posOut,
      ...videoEncodeArgs(),
      // Segment boundaries every 4s exactly, so every run cuts identically.
      '-g', String(SEG * FPS),
      '-force_key_frames', `expr:gte(t,n_forced*${SEG})`,
      '-r', String(FPS),
      ...(linuxHwAccel === 'vaapi' ? [] : ['-pix_fmt', 'yuv420p']),
      ...AUDIO_SYNC_ARGS,
      '-c:a', 'aac', '-b:a', '128k', '-ac', '2',
      '-output_ts_offset', String(target),
      '-f', 'hls',
      '-hls_time', String(SEG),
      '-hls_list_size', '0',
      '-hls_segment_type', 'fmp4',
      '-hls_fmp4_init_filename', `init-${gen}.mp4`,
      '-start_number', String(k),
      // temp_file: a segment only appears under its final name once complete.
      '-hls_flags', 'independent_segments+temp_file',
      // Absolute time in every fragment; keeps init headers identical.
      '-hls_segment_options', 'movflags=+frag_discont',
      '-hls_segment_filename', join(this.dir, 'seg%d.m4s'),
      join(this.dir, `enc-${gen}.m3u8`),
    ];
    const proc = spawn(FFMPEG, args);
    const enc = { proc, start: k, frontier: k - 1, gen, exited: false };
    proc.stderr.on('data', d => this.log(`[timeline:${this.id}#${gen}] ${d.toString().trim()}`));
    proc.on('close', code => {
      enc.exited = true;
      if (this.enc === enc) this.log(`[timeline:${this.id}#${gen}] encoder exited (${code}) at segment ${this.frontier(enc)}`);
    });
    this.enc = enc;
    this.log(`[timeline:${this.id}] encoder #${gen} from segment ${k} (${target}s, ${this.finished ? 'finished' : 'recording'})`);
  }

  stopEncoder() {
    if (this.enc && !this.enc.exited) {
      try { this.enc.proc.kill('SIGKILL'); } catch {}
    }
    this.enc = null;
  }

  /// Resolve with the path of segment k once it exists, starting or
  /// restarting the encoder as needed. Rejects when k can't be produced, or
  /// when `signal` aborts (the client went away — e.g. a player abandoning
  /// its read-ahead after a seek; that request must not restart anything).
  async segment(k, signal) {
    const path = this.segPath(k);
    if (existsSync(path)) return path;
    const mySeq = ++this.reqSeq;
    this.waiting.add(mySeq);
    try {
      return await this.waitFor(k, path, mySeq, signal);
    } finally {
      this.waiting.delete(mySeq);
    }
  }

  async waitFor(k, path, mySeq, signal) {
    if (k < 0 || (this.finished && k >= this.segmentCount)) throw new Error('out of range');
    if (!this.finished && k >= this.segmentCount) await this.refreshSource(true).catch(() => {});

    const covers = (e) => e && !e.exited && k >= e.start && k <= this.frontier(e) + RESTART_AHEAD;
    let restarts = 0;
    let lastRestart = 0;
    if (!covers(this.enc)) {
      this.startEncoder(k);
      restarts = 1;
      lastRestart = Date.now();
    }

    const deadline = Date.now() + SEGMENT_WAIT_MS;
    while (Date.now() < deadline && !this.stopped) {
      if (existsSync(path)) return path;
      if (signal?.aborted) throw new Error('client went away');
      // The encoder we were waiting on died, or a newer request moved it
      // (a seek). Only the newest request may pull the encoder back — an
      // older one waiting on read-ahead would otherwise fight the seek.
      // Spaced out and capped, so a failing source can't respawn in a loop.
      const newest = mySeq === Math.max(...this.waiting);
      const alive = this.enc && !this.enc.exited;
      if (!covers(this.enc) && newest && Date.now() - lastRestart > (alive ? 300 : 1500)) {
        if (restarts >= 3) break;
        this.startEncoder(k);
        restarts++;
        lastRestart = Date.now();
      }
      await new Promise(r => setTimeout(r, 100));
    }
    if (existsSync(path)) return path;
    throw new Error(`segment ${k} not produced in time`);
  }

  async init_mp4() {
    const deadline = Date.now() + SEGMENT_WAIT_MS;
    if (!this.enc) this.startEncoder(0);
    while (Date.now() < deadline && !this.stopped) {
      const p = this.initPath();
      if (p) return p;
      await new Promise(r => setTimeout(r, 100));
    }
    throw new Error('init segment not produced in time');
  }

  stop() {
    this.stopped = true;
    this.stopEncoder();
  }

  kill() { this.stop(); }

  /// Remove any leftover files (the caller owns the directory's lifetime).
  cleanup() {
    this.stop();
    try { rmSync(this.dir, { recursive: true, force: true }); } catch {}
  }
}
