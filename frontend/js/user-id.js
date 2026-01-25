/**
 * User ID management for Eon voice assistant.
 * Simplified version - always anonymous (no auth required).
 */

const EON_USER_ID_KEY = 'eon_user_id';

/**
 * Generate a UUID
 * @returns {string} A UUID string
 */
function generateUUID() {
    if (typeof crypto !== 'undefined' && typeof crypto.randomUUID === 'function') {
        return crypto.randomUUID();
    }
    if (typeof crypto !== 'undefined' && typeof crypto.getRandomValues === 'function') {
        return ([1e7]+-1e3+-4e3+-8e3+-1e11).replace(/[018]/g, c =>
            (c ^ crypto.getRandomValues(new Uint8Array(1))[0] & 15 >> c / 4).toString(16)
        );
    }
    return 'xxxxxxxx-xxxx-4xxx-yxxx-xxxxxxxxxxxx'.replace(/[xy]/g, function(c) {
        const r = Math.random() * 16 | 0;
        const v = c === 'x' ? r : (r & 0x3 | 0x8);
        return v.toString(16);
    });
}

/**
 * Get or create a persistent anonymous user ID
 * @returns {string} The user's ID
 */
function getOrCreateUserId() {
    let userId = localStorage.getItem(EON_USER_ID_KEY);
    if (!userId) {
        userId = 'anon_' + generateUUID();
        localStorage.setItem(EON_USER_ID_KEY, userId);
    }
    return userId;
}

/**
 * Check if user is authenticated - always returns false (no auth)
 * @returns {boolean} Always false
 */
function isAuthenticated() {
    return false;
}

/**
 * Get the access token - always returns null (no auth)
 * @returns {null} Always null
 */
function getAccessToken() {
    return null;
}

/**
 * Clear authentication data - no-op
 */
function clearAuth() {
    // No-op - no auth to clear
}

/**
 * Get the current user ID
 * @returns {string} The user's ID
 */
function getUserId() {
    return getOrCreateUserId();
}

/**
 * Get the last 4 characters of the user ID for display
 * @returns {string} Last 4 characters of user ID
 */
function getUserIdSuffix() {
    const userId = getUserId();
    return userId.slice(-4);
}

/**
 * Build a WebSocket URL with user_id parameter
 * @param {string} baseUrl - Base WebSocket URL
 * @returns {string} WebSocket URL with user_id
 */
function buildWebSocketUrl(baseUrl) {
    const separator = baseUrl.includes('?') ? '&' : '?';
    const userId = getUserId();
    return `${baseUrl}${separator}user_id=${encodeURIComponent(userId)}`;
}

/**
 * Get the user's display name
 * @returns {string} User ID suffix
 */
function getUserDisplayName() {
    return getUserIdSuffix();
}

/**
 * Update a UI element to display the user ID suffix
 * @param {string} elementId - ID of the element to update
 */
function displayUserIdInElement(elementId) {
    const element = document.getElementById(elementId);
    if (element) {
        element.textContent = getUserIdSuffix();
    }
}

/**
 * Clear the stored user ID
 */
function clearUserId() {
    localStorage.removeItem(EON_USER_ID_KEY);
}
