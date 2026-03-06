const CLOUD_BASE = 'https://lighthousetv.ewscloud.com/api/v2';
const USER_AGENT = 'Tablo-FAST/2.0.0 (Mobile; iPhone; iOS 16.6)';

let tokens = null;

export async function login(email, password) {
  const res = await fetch(`${CLOUD_BASE}/login/`, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json', 'User-Agent': USER_AGENT },
    body: JSON.stringify({ email, password }),
  });

  if (!res.ok) {
    throw new Error(`Login failed: ${res.status} ${await res.text()}`);
  }

  const data = await res.json();
  tokens = {
    tokenType: data.token_type,
    accessToken: data.access_token,
  };

  return tokens;
}

export async function getAccount() {
  if (!tokens) throw new Error('Not logged in');

  const res = await fetch(`${CLOUD_BASE}/account/`, {
    headers: {
      Authorization: `${tokens.tokenType} ${tokens.accessToken}`,
      'User-Agent': USER_AGENT,
    },
  });

  if (!res.ok) {
    throw new Error(`Get account failed: ${res.status} ${await res.text()}`);
  }

  return res.json();
}

export async function selectAccount(serverId, profileId) {
  if (!tokens) throw new Error('Not logged in');

  const res = await fetch(`${CLOUD_BASE}/account/select/`, {
    method: 'POST',
    headers: {
      Authorization: `${tokens.tokenType} ${tokens.accessToken}`,
      'User-Agent': USER_AGENT,
      'Content-Type': 'application/json',
    },
    body: JSON.stringify({ sid: serverId, pid: profileId }),
  });

  if (!res.ok) {
    throw new Error(`Select account failed: ${res.status} ${await res.text()}`);
  }

  const data = await res.json();
  tokens.lighthouse = data.token;
  return tokens;
}

export function cloudHeaders() {
  if (!tokens) throw new Error('Not logged in');
  return {
    Authorization: `${tokens.tokenType} ${tokens.accessToken}`,
    Lighthouse: tokens.lighthouse,
    'User-Agent': USER_AGENT,
  };
}

export function getTokens() {
  return tokens;
}

export { CLOUD_BASE };
