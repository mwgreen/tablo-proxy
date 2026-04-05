import { cloudHeaders, CLOUD_BASE, getTokens } from './auth.js';
import { makeDeviceAuth } from './crypto.js';

let deviceUrl = null;
let tunerCount = 2;
let channels = [];
let recordings = [];
let guideData = {};
let seriesIndex = {}; // cloudShowId -> { path, title, schedule }

export function getDeviceUrl() { return deviceUrl; }
export function getTunerCount() { return tunerCount; }
export function getChannels() { return channels; }
export function getRecordings() { return recordings; }
export function getGuideData() { return guideData; }

export async function discoverDevice(account) {
  const devices = account.devices || [];
  if (devices.length === 0) {
    throw new Error('No Tablo devices found on account');
  }

  const device = devices[0];
  deviceUrl = device.url;
  console.log(`[tablo] Device found: ${deviceUrl}`);

  // Get server info for tuner count
  try {
    const info = await deviceRequest('GET', '/server/info');
    if (info && info.tuners) {
      tunerCount = info.tuners;
    }
    console.log(`[tablo] Tuners: ${tunerCount}`);
  } catch (e) {
    console.warn(`[tablo] Could not get server info: ${e.message}`);
  }

  return deviceUrl;
}

export async function deviceRequest(method, path, body) {
  if (!deviceUrl) throw new Error('Device not discovered');

  const bodyStr = body ? JSON.stringify(body) : '';
  // Sign the path WITHOUT query string; add ?lh only to the URL
  const authHeaders = makeDeviceAuth(method, path, bodyStr);

  const res = await fetch(`${deviceUrl}${path}?lh`, {
    method,
    headers: {
      ...authHeaders,
      'Content-Type': 'application/json',
      'User-Agent': 'Tablo-FAST/1.7.0 (Mobile; iPhone; iOS 18.4)',
    },
    body: bodyStr || undefined,
  });

  if (!res.ok) {
    const text = await res.text();
    throw new Error(`Device request ${method} ${path} failed: ${res.status} ${text}`);
  }

  return res.json();
}

export async function fetchChannels() {
  // Fetch channel list from local device (more reliable than cloud API)
  const paths = await deviceRequest('GET', '/guide/channels');

  channels = [];
  for (const p of paths) {
    try {
      const ch = await deviceRequest('GET', p);
      const c = ch.channel;
      channels.push({
        id: ch.object_id,
        cloudId: c.channel_identifier || null,
        number: `${c.major}.${c.minor}`,
        name: c.network || c.call_sign || 'Unknown',
        callSign: c.call_sign || '',
        kind: c.source || 'ota',
        raw: ch,
      });
    } catch (e) {
      // skip individual channel failures
    }
  }

  channels.sort((a, b) => {
    const [aMaj, aMin] = a.number.split('.').map(Number);
    const [bMaj, bMin] = b.number.split('.').map(Number);
    return aMaj - bMaj || aMin - bMin;
  });

  console.log(`[tablo] Loaded ${channels.length} OTA channels`);
  return channels;
}

export async function fetchRecordings() {
  // Get series list from device
  let seriesPaths;
  try {
    seriesPaths = await deviceRequest('GET', '/recordings/series');
  } catch (e) {
    console.warn(`[tablo] Could not fetch recording series: ${e.message}`);
    recordings = [];
    return recordings;
  }

  // Fetch details for each series
  const seriesMap = {};
  for (const sp of seriesPaths) {
    try {
      const series = await deviceRequest('GET', sp);
      seriesMap[sp] = series;
    } catch (e) {
      // skip
    }
  }

  // Get all episode paths
  let airingPaths;
  try {
    airingPaths = await deviceRequest('GET', '/recordings/airings');
  } catch (e) {
    console.warn(`[tablo] Could not fetch recording airings: ${e.message}`);
    recordings = [];
    return recordings;
  }

  // Fetch details for each episode
  recordings = [];
  for (const ap of airingPaths) {
    try {
      const ep = await deviceRequest('GET', ap);
      const series = seriesMap[ep.series_path];
      const ch = ep.airing_details?.channel?.channel;
      recordings.push({
        id: ep.object_id,
        path: ep.path,
        title: series?.series?.title || 'Unknown',
        episode: ep.episode?.title || '',
        episodeNumber: ep.episode?.number || null,
        seasonNumber: ep.episode?.season_number || null,
        description: ep.episode?.description || series?.series?.description || '',
        date: ep.airing_details?.datetime || '',
        duration: ep.airing_details?.duration || 0,
        channel: ch ? `${ch.major}.${ch.minor} ${ch.call_sign}` : '',
        imageId: ep.snapshot_image?.image_id || null,
      });
    } catch (e) {
      // skip individual episode failures
    }
  }

  // Sort by date descending (newest first)
  recordings.sort((a, b) => new Date(b.date) - new Date(a.date));

  console.log(`[tablo] Loaded ${recordings.length} recordings`);
  return recordings;
}

export async function fetchGuide(days = 2) {
  guideData = {};

  // Try cloud API first for rich guide data
  try {
    const tokens = getTokens();
    const headers = cloudHeaders();

    const today = new Date();
    for (let i = 0; i < days; i++) {
      const date = new Date(today);
      date.setDate(date.getDate() + i);
      const dateStr = date.toISOString().split('T')[0];

      for (const ch of channels) {
        if (!ch.cloudId) continue;
        try {
          const res = await fetch(
            `${CLOUD_BASE}/account/guide/channels/${ch.cloudId}/airings/${dateStr}/`,
            { headers }
          );
          if (res.ok) {
            const airings = await res.json();
            if (!guideData[ch.id]) guideData[ch.id] = [];
            guideData[ch.id].push(...(airings || []));
          }
        } catch (e) {
          // Skip individual channel failures
        }
      }
    }
  } catch (e) {
    console.warn(`[tablo] Cloud guide fetch failed: ${e.message}`);
  }

  console.log(`[tablo] Guide data loaded for ${Object.keys(guideData).length} channels`);
  return guideData;
}

export function resolveChannelId(channelId) {
  // If it's already a numeric device ID, use it directly
  const num = Number(channelId);
  if (!isNaN(num) && channels.some(c => c.id === num)) return num;
  // Otherwise look up by legacy cloud identifier
  const ch = channels.find(c => c.cloudId === channelId);
  return ch ? ch.id : channelId;
}

export async function getTunerStatus() {
  return nativeDeviceRequest('GET', '/server/tuners');
}

// Normalize datetime for comparison (device uses "T02:59Z", cloud uses "T02:59:00Z")
function normalizeDatetime(dt) {
  return new Date(dt).getTime();
}

// Schedule or unschedule a single airing by finding its device path
export async function scheduleAiring(showId, airingDatetime, schedule = true) {
  const entry = seriesIndex[showId];
  if (!entry) throw new Error(`Unknown show: ${showId}`);

  const targetTime = normalizeDatetime(airingDatetime);

  // Get the device series path number from entry.path (e.g., "/guide/series/4022" -> "4022")
  const seriesNum = entry.path.split('/').pop();
  const episodes = await nativeDeviceRequest('GET', `/guide/series/${seriesNum}/episodes`);

  // Find the episode matching the datetime
  for (const epPath of episodes) {
    const ep = await nativeDeviceRequest('GET', epPath);
    if (normalizeDatetime(ep.airing_details?.datetime) === targetTime) {
      const result = await nativeDeviceRequest('PATCH', epPath, { scheduled: schedule });
      return result;
    }
  }

  // Not found in series episodes — search all airings as fallback (sports, specials)
  const allPaths = await nativeDeviceRequest('GET', '/guide/airings');
  for (const p of allPaths) {
    const a = await nativeDeviceRequest('GET', p);
    if (normalizeDatetime(a.airing_details?.datetime) === targetTime) {
      const chId = a.airing_details?.channel?.channel?.channel_identifier;
      // Match by channel too if the show has multiple airings at same time
      const result = await nativeDeviceRequest('PATCH', p, { scheduled: schedule });
      return result;
    }
  }

  throw new Error('Airing not found on device');
}

export async function deleteRecording(recordingId) {
  const path = `/recordings/series/episodes/${recordingId}`;
  if (!deviceUrl) throw new Error('Device not discovered');

  const authHeaders = makeDeviceAuth('DELETE', path);
  const res = await fetch(`${deviceUrl}${path}`, {
    method: 'DELETE',
    headers: {
      ...authHeaders,
      'Content-Type': 'application/json',
      'User-Agent': 'Tablo-FAST/1.7.0 (Mobile; iPhone; iOS 18.4)',
    },
  });

  if (!res.ok && res.status !== 204) {
    const text = await res.text();
    throw new Error(`Delete recording failed: ${res.status} ${text}`);
  }

  // Remove from local recordings list
  recordings = recordings.filter(r => String(r.id) !== String(recordingId));
  return { ok: true };
}

export async function startWatch(channelId) {
  const deviceId = resolveChannelId(channelId);
  const body = {
    bandwidth: null,
    extra: {
      limitedAdTracking: 1,
      deviceOSVersion: '16.6',
      deviceModel: 'iPhone',
    },
    device_id: 'tablo-proxy-' + Date.now(),
    platform: 'ios',
  };

  try {
    const data = await deviceRequest('POST', `/guide/channels/${deviceId}/watch`, body);
    return data.playlist_url;
  } catch (e) {
    // Check if it's a tuner availability issue
    if (e.message.includes('failed: 4')) {
      const tuners = await getTunerStatus().catch(() => []);
      const busy = tuners.filter(t => t.in_use);
      const recording = busy.filter(t => t.recording);
      if (busy.length > 0 && busy.length === tuners.length) {
        const details = busy.map(t => {
          const chPath = t.channel || '';
          const chId = chPath.split('/').pop();
          const ch = channels.find(c => c.id === Number(chId));
          const name = ch ? `${ch.number} ${ch.name}` : chPath;
          return t.recording ? `${name} (recording)` : `${name} (watching)`;
        }).join(', ');
        throw new Error(`All tuners busy: ${details}`);
      }
    }
    throw e;
  }
}

// Native device request (without ?lh) — needed for scheduling
async function nativeDeviceRequest(method, path, body) {
  if (!deviceUrl) throw new Error('Device not discovered');

  const bodyStr = body ? JSON.stringify(body) : '';
  const authHeaders = makeDeviceAuth(method, path, bodyStr);

  const res = await fetch(`${deviceUrl}${path}`, {
    method,
    headers: {
      ...authHeaders,
      'Content-Type': 'application/json',
      'User-Agent': 'Tablo-FAST/1.7.0 (Mobile; iPhone; iOS 18.4)',
    },
    body: bodyStr || undefined,
  });

  if (!res.ok) {
    const text = await res.text();
    throw new Error(`Native device request ${method} ${path} failed: ${res.status} ${text}`);
  }

  return res.json();
}

// Build index of series that appear in the guide (cloud show ID -> device series path)
export async function fetchSeriesIndex() {
  seriesIndex = {};

  // Collect unique show IDs from guide data
  const showIds = new Set();
  for (const airings of Object.values(guideData)) {
    for (const a of airings) {
      if (a.show?.identifier) showIds.add(a.show.identifier);
    }
  }

  if (showIds.size === 0) {
    console.log('[tablo] Series index: 0 shows (no guide data)');
    return seriesIndex;
  }

  // Get all series paths from device
  const paths = await nativeDeviceRequest('GET', '/guide/series');

  // Fetch in batches of 10, stop early once all guide shows are found
  for (let i = 0; i < paths.length && showIds.size > Object.keys(seriesIndex).length; i += 10) {
    const batch = paths.slice(i, i + 10);
    const results = await Promise.allSettled(
      batch.map(p => nativeDeviceRequest('GET', p))
    );
    for (const r of results) {
      if (r.status === 'fulfilled') {
        const s = r.value;
        if (showIds.has(s.identifier)) {
          seriesIndex[s.identifier] = {
            path: s.path,
            title: s.series?.title || '',
            schedule: s.schedule?.rule || 'none',
          };
        }
      }
    }
  }

  console.log(`[tablo] Series index: ${Object.keys(seriesIndex).length} shows (of ${showIds.size} in guide)`);
  return seriesIndex;
}

export function getSeriesIndex() { return seriesIndex; }

// Schedule a series for recording
export async function scheduleSeries(showId, rule = 'new') {
  const entry = seriesIndex[showId];
  if (!entry) throw new Error(`Unknown show: ${showId}`);

  const data = await nativeDeviceRequest('PATCH', entry.path, { schedule: { rule } });
  entry.schedule = data.schedule?.rule || rule;
  return data;
}

// Unschedule a series
export async function unscheduleSeries(showId) {
  return scheduleSeries(showId, 'none');
}

// Get scheduled series list
export function getScheduledSeries() {
  return Object.entries(seriesIndex)
    .filter(([, v]) => v.schedule !== 'none')
    .map(([id, v]) => ({ showId: id, ...v }));
}

export async function startRecordingWatch(recordingId) {
  const body = {
    bandwidth: null,
    extra: {
      limitedAdTracking: 1,
      deviceOSVersion: '16.6',
      deviceModel: 'iPhone',
    },
    device_id: 'tablo-proxy-' + Date.now(),
    platform: 'ios',
  };

  const data = await deviceRequest('POST', `/recordings/series/episodes/${recordingId}/watch`, body);
  return data.playlist_url;
}
