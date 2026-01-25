/**
 * MSAL Configuration for Azure External ID
 *
 * IMPORTANT: Replace the placeholder values with your actual Azure External ID configuration.
 *
 * To get these values:
 * 1. Go to Microsoft Entra admin center (https://entra.microsoft.com)
 * 2. Switch to your External ID tenant
 * 3. Go to Applications > App registrations > Your App
 * 4. Copy Application (client) ID and Directory (tenant) ID from Overview
 */

const msalConfig = {
    auth: {
        // Application (client) ID from Azure app registration
        clientId: "c0a64bb5-cc3e-4528-bb48-452d4634f45a",

        // Authority URL for External ID tenant
        // Format: https://{tenant-name}.ciamlogin.com/
        authority: "https://eoncustomers.ciamlogin.com/",

        // Known authorities for External ID
        knownAuthorities: ["eoncustomers.ciamlogin.com"],

        // Redirect URI - must match what's registered in Azure
        redirectUri: window.location.origin + "/login.html",

        // Where to redirect after logout
        postLogoutRedirectUri: window.location.origin + "/login.html",

        // Navigate to the original request URL after login
        navigateToLoginRequestUrl: true
    },
    cache: {
        // Use sessionStorage for better security (cleared on browser close)
        cacheLocation: "sessionStorage",

        // Set to true for IE11 or Edge Legacy
        storeAuthStateInCookie: false
    },
    system: {
        loggerOptions: {
            loggerCallback: (level, message, containsPii) => {
                if (containsPii) {
                    return;
                }
                switch (level) {
                    case msal.LogLevel.Error:
                        console.error("[MSAL]", message);
                        return;
                    case msal.LogLevel.Info:
                        console.info("[MSAL]", message);
                        return;
                    case msal.LogLevel.Verbose:
                        console.debug("[MSAL]", message);
                        return;
                    case msal.LogLevel.Warning:
                        console.warn("[MSAL]", message);
                        return;
                }
            },
            piiLoggingEnabled: false
        },
        // Timeout for popup windows
        windowHashTimeout: 60000,
        // Timeout for iframe (silent auth)
        iframeHashTimeout: 6000
    }
};

// Scopes to request during login
// prompt: 'select_account' forces account picker per Microsoft Learn docs
// https://learn.microsoft.com/en-us/entra/msal/javascript/browser/prompt-behavior
const loginRequest = {
    scopes: ["openid", "profile", "email", "offline_access"],
    prompt: "select_account"
};

// Export for use in other files
window.msalConfig = msalConfig;
window.loginRequest = loginRequest;
