import { cloudHeaders, CLOUD_BASE, getTokens } from './auth.js';
import { makeDeviceAuth } from './crypto.js';

let deviceUrl = null;
let tunerCount = 2;
let channels = [];
let recordings = [];
let guideData = {};

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
  const tokens = getTokens();
  const res = await fetch(`${CLOUD_BASE}/account/${tokens.lighthouse}/guide/channels/`, {
    headers: cloudHeaders(),
  });

  if (!res.ok) {
    throw new Error(`Fetch channels failed: ${res.status} ${await res.text()}`);
  }

  const data = await res.json();
  channels = (data || []).filter(ch => ch.kind === 'ota').map(ch => ({
    id: ch.identifier,
    number: ch.ota ? `${ch.ota.major}.${ch.ota.minor}` : ch.identifier,
    name: ch.ota?.network || ch.ota?.callSign || 'Unknown',
    callSign: ch.ota?.callSign || '',
    kind: ch.kind,
    raw: ch,
  }));

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
  const tokens = getTokens();
  const headers = cloudHeaders();
  guideData = {};

  const today = new Date();
  for (let i = 0; i < days; i++) {
    const date = new Date(today);
    date.setDate(date.getDate() + i);
    const dateStr = date.toISOString().split('T')[0];

    for (const ch of channels) {
      try {
        const res = await fetch(
          `${CLOUD_BASE}/account/guide/channels/${ch.id}/airings/${dateStr}/`,
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

  console.log(`[tablo] Guide data loaded for ${Object.keys(guideData).length} channels`);
  return guideData;
}

export async function startWatch(channelId) {
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

  const data = await deviceRequest('POST', `/guide/channels/${channelId}/watch`, body);
  return data.playlist_url;
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
