/**
 * Eon Login Page Logic
 * Handles Azure External ID authentication using MSAL.js
 */

// Initialize MSAL instance
let msalInstance = null;

// Initialize on page load
document.addEventListener('DOMContentLoaded', async () => {
    try {
        // Create MSAL instance
        msalInstance = new msal.PublicClientApplication(msalConfig);

        // Handle redirect response (if coming back from Azure login/logout)
        await handleRedirectResponse();

        // Check if logout action requested (from app.js handleLogout)
        const urlParams = new URLSearchParams(window.location.search);
        if (urlParams.get('action') === 'logout') {
            // Clear URL params first
            window.history.replaceState({}, document.title, '/login.html');
            // Perform MSAL logout with redirect
            await performLogout();
            return;
        }

        // Check if already authenticated
        checkExistingAuth();

        // Update UI to show ready state
        updateStatus('ready', 'Click to sign in');

    } catch (error) {
        console.error("MSAL initialization error:", error);
        updateStatus('error', 'Authentication system error');
    }
});

/**
 * Perform MSAL logout with redirect
 */
async function performLogout() {
    try {
        updateStatus('connecting', 'Signing out...');

        // Clear all session storage first
        sessionStorage.clear();

        // Clear localStorage MSAL entries
        Object.keys(localStorage).forEach(key => {
            if (key.startsWith('msal.') || key.includes('login.windows.net')) {
                localStorage.removeItem(key);
            }
        });

        // Get current account if any
        const accounts = msalInstance.getAllAccounts();

        if (accounts.length > 0) {
            // Logout via MSAL redirect (clears server session too)
            await msalInstance.logoutRedirect({
                account: accounts[0],
                postLogoutRedirectUri: '/login.html'
            });
        } else {
            // No account, just show login ready
            updateStatus('ready', 'Click to sign in');
        }
    } catch (error) {
        console.error("Logout error:", error);
        // Even on error, show login ready
        updateStatus('ready', 'Click to sign in');
    }
}

/**
 * Handle the redirect response from Azure External ID
 */
async function handleRedirectResponse() {
    try {
        const response = await msalInstance.handleRedirectPromise();

        if (response) {
            console.log("Login successful via redirect");
            handleLoginSuccess(response);
        }
    } catch (error) {
        console.error("Redirect handling error:", error);
        updateStatus('error', 'Login failed: ' + error.message);
    }
}

/**
 * Check if user is already authenticated
 */
function checkExistingAuth() {
    const accounts = msalInstance.getAllAccounts();

    if (accounts.length > 0) {
        // User is already signed in
        console.log("Found existing account:", accounts[0].username);

        // Try to get a token silently
        acquireTokenSilent(accounts[0]);
    }
}

/**
 * Acquire token silently for existing session
 */
async function acquireTokenSilent(account) {
    try {
        updateStatus('connecting', 'Restoring session...');

        const request = {
            ...loginRequest,
            account: account
        };

        const response = await msalInstance.acquireTokenSilent(request);
        handleLoginSuccess(response);

    } catch (error) {
        console.log("Silent token acquisition failed, user needs to sign in");
        updateStatus('ready', 'Click to sign in');
    }
}

/**
 * Sign in with redirect (recommended for SPAs per Microsoft Learn)
 * https://learn.microsoft.com/en-us/entra/msal/javascript/browser/initialization#redirect-apis
 */
async function signIn() {
    if (!msalInstance) {
        updateStatus('error', 'Authentication not initialized');
        return;
    }

    try {
        updateStatus('connecting', 'Redirecting to sign-in...');

        // Use loginRedirect instead of loginPopup for reliability
        // Popup can fail with "Request was blocked inside a popup" errors
        await msalInstance.loginRedirect(loginRequest);

    } catch (error) {
        console.error("Login error:", error);
        updateStatus('error', 'Login failed: ' + (error.errorMessage || error.message));
    }
}

/**
 * Sign up with redirect - goes directly to registration flow
 */
async function signUp() {
    if (!msalInstance) {
        updateStatus('error', 'Authentication not initialized');
        return;
    }

    try {
        updateStatus('connecting', 'Redirecting to sign-up...');

        const signUpRequest = {
            ...loginRequest,
            prompt: 'create'  // Forces the sign-up experience
        };

        // Use loginRedirect for reliability
        await msalInstance.loginRedirect(signUpRequest);

    } catch (error) {
        console.error("Sign-up error:", error);
        updateStatus('error', 'Sign-up failed: ' + (error.errorMessage || error.message));
    }
}

/**
 * Handle successful login
 */
function handleLoginSuccess(response) {
    if (!response || !response.account) {
        updateStatus('error', 'Invalid login response');
        return;
    }

    console.log("Login successful:", response.account.username);

    // Store authentication data in sessionStorage
    sessionStorage.setItem('eon_access_token', response.accessToken || '');
    sessionStorage.setItem('eon_id_token', response.idToken || '');
    sessionStorage.setItem('eon_user_id', response.account.localAccountId || response.account.homeAccountId);
    sessionStorage.setItem('eon_user_name', response.account.name || response.account.username || '');
    sessionStorage.setItem('eon_user_email', response.account.username || '');

    // Store token expiration
    if (response.expiresOn) {
        sessionStorage.setItem('eon_token_expires', response.expiresOn.toISOString());
    }

    updateStatus('success', 'Authenticated! Redirecting...');

    // Redirect to main app after short delay
    setTimeout(() => {
        window.location.href = '/index.html';
    }, 1000);
}

/**
 * Sign out
 */
async function signOut() {
    // Clear session storage
    sessionStorage.removeItem('eon_access_token');
    sessionStorage.removeItem('eon_id_token');
    sessionStorage.removeItem('eon_user_id');
    sessionStorage.removeItem('eon_user_name');
    sessionStorage.removeItem('eon_user_email');
    sessionStorage.removeItem('eon_token_expires');

    // Sign out from MSAL using redirect (not popup) per Microsoft Learn
    // https://learn.microsoft.com/en-us/entra/msal/javascript/browser/logout
    if (msalInstance) {
        try {
            await msalInstance.logoutRedirect({
                postLogoutRedirectUri: '/login.html'
            });
        } catch (error) {
            console.error("Logout error:", error);
            // Force redirect to login page
            window.location.href = '/login.html';
        }
    }
}

/**
 * Update status display
 */
function updateStatus(state, message) {
    const statusElement = document.getElementById('login-status');
    const statusIndicator = document.getElementById('status-indicator');
    const loginButton = document.getElementById('login-button');
    const signupButton = document.getElementById('signup-button');

    if (statusElement) {
        statusElement.textContent = message;
        statusElement.className = 'login-status ' + state;
    }

    if (statusIndicator) {
        statusIndicator.className = 'status-indicator ' + state;
    }

    const isConnecting = (state === 'connecting');

    if (loginButton) {
        loginButton.disabled = isConnecting;
        if (isConnecting) {
            loginButton.classList.add('loading');
        } else {
            loginButton.classList.remove('loading');
        }
    }

    if (signupButton) {
        signupButton.disabled = isConnecting;
        if (isConnecting) {
            signupButton.classList.add('loading');
        } else {
            signupButton.classList.remove('loading');
        }
    }
}

// Expose functions globally
window.signIn = signIn;
window.signUp = signUp;
window.signOut = signOut;
