/**
 * Eon Frontend Configuration
 *
 * Defines API and WebSocket URLs based on environment.
 * For eon-web-claude (microservices rebuild).
 */

const EON_CONFIG = (() => {
  const hostname = window.location.hostname;

  // Local development
  if (hostname === 'localhost' || hostname === '127.0.0.1') {
    return {
      API_URL: `${window.location.protocol}//${window.location.host}`,
      WS_URL: `${window.location.protocol === 'https:' ? 'wss:' : 'ws:'}//${window.location.host}`
    };
  }

  // eon-web-claude (microservices rebuild) - points to new isolated backend
  if (hostname.includes('lively-cliff-043061b0f')) {
    return {
      API_URL: 'https://eon-api-claude.happyground-4989b4a6.eastus2.azurecontainerapps.io',
      WS_URL: 'wss://eon-api-claude.happyground-4989b4a6.eastus2.azurecontainerapps.io'
    };
  }

  // Default: same origin
  return {
    API_URL: `${window.location.protocol}//${window.location.host}`,
    WS_URL: `${window.location.protocol === 'https:' ? 'wss:' : 'ws:'}//${window.location.host}`
  };
})();
