/**
 * Eon Frontend Configuration
 *
 * Fetches API/WebSocket URLs from backend config endpoint.
 * Works with SWA linked backend - frontend calls /api/config which proxies to Container App.
 */

let EON_CONFIG = null;
let configPromise = null;

async function loadConfig() {
  const hostname = window.location.hostname;

  // Local development - use same origin
  if (hostname === 'localhost' || hostname === '127.0.0.1') {
    return {
      API_URL: `${window.location.protocol}//${window.location.host}`,
      WS_URL: `${window.location.protocol === 'https:' ? 'wss:' : 'ws:'}//${window.location.host}`
    };
  }

  // Production - fetch config from backend via SWA linked backend
  try {
    const response = await fetch('/api/config');
    if (response.ok) {
      const config = await response.json();
      return {
        API_URL: config.apiUrl,
        WS_URL: config.wsUrl.replace('/ws/voice', '')  // Base URL without path
      };
    }
  } catch (e) {
    console.error('Failed to fetch config from /api/config:', e);
  }

  // Fallback - try direct Container App URL (for debugging)
  console.warn('Using fallback config - /api/config failed');
  return {
    API_URL: `${window.location.protocol}//${window.location.host}`,
    WS_URL: `${window.location.protocol === 'https:' ? 'wss:' : 'ws:'}//${window.location.host}`
  };
}

/**
 * Get config - returns a promise that resolves when config is loaded.
 * Can be called multiple times; returns cached promise.
 */
function getConfig() {
  if (!configPromise) {
    configPromise = loadConfig().then(config => {
      EON_CONFIG = config;
      console.log('Eon config loaded:', EON_CONFIG);
      return config;
    });
  }
  return configPromise;
}

// Start loading config immediately
getConfig();
