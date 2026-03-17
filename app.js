import 'dotenv/config';
import { login, getAccount, selectAccount } from './src/auth.js';
import { discoverDevice, fetchChannels, fetchRecordings, fetchGuide } from './src/tablo.js';
import { startServer } from './src/server.js';

const PORT = process.env.PORT || 8181;
const GUIDE_DAYS = parseInt(process.env.GUIDE_DAYS || '2', 10);

async function main() {
  const email = process.env.TABLO_EMAIL;
  const password = process.env.TABLO_PASSWORD;

  if (!email || !password) {
    console.error('Set TABLO_EMAIL and TABLO_PASSWORD in .env');
    process.exit(1);
  }

  console.log('[app] Logging in to Tablo...');
  await login(email, password);

  console.log('[app] Getting account info...');
  const account = await getAccount();

  const device = account.devices[0];
  if (!device) {
    console.error('No Tablo devices found on account');
    process.exit(1);
  }
  console.log(`[app] Found device: ${device.name} (${device.serverId})`);

  const profile = account.profiles[0];
  console.log(`[app] Selecting account (profile: ${profile.name})...`);
  await selectAccount(device.serverId, profile.identifier);

  console.log('[app] Discovering device...');
  await discoverDevice(account);

  console.log('[app] Fetching channels...');
  await fetchChannels();

  console.log('[app] Fetching recordings...');
  await fetchRecordings();

  console.log('[app] Fetching guide data...');
  await fetchGuide(GUIDE_DAYS);

  console.log('[app] Encoder: h264_videotoolbox (GPU) via FFmpeg');
  await startServer(PORT);
}

main().catch((err) => {
  console.error('[app] Fatal error:', err);
  process.exit(1);
});
