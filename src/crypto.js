import { createHmac, createHash } from 'crypto';

const HASH_KEY = '6l8jU5N43cEilqItmT3U2M2PFM3qPziilXqau9ys';
const DEVICE_KEY = 'ljpg6ZkwShVv8aI12E2LP55Ep8vq1uYDPvX0DdTB';

function toRFC1123(date) {
  return date.toUTCString();
}

export function makeDeviceAuth(method, path, body = '') {
  const date = toRFC1123(new Date());
  // Empty body stays as empty string; non-empty body gets MD5 hex hash
  const bodyHash = body !== '' ? createHash('md5').update(body).digest('hex').toLowerCase() : '';
  const message = `${method}\n${path}\n${bodyHash}\n${date}`;
  const signature = createHmac('md5', HASH_KEY).update(message).digest('hex').toLowerCase();

  return {
    Authorization: `tablo:${DEVICE_KEY}:${signature}`,
    Date: date,
  };
}
