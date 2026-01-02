#if defined _gokz_top_included_
#endinput
#endif
#define _gokz_top_included_

#include <sourcemod>
#include <SteamWorks>

#define MODE_COUNT 3

/**
 * Shared helper include for GOKZ Top plugins.
 *
 * Depends on ConVars created by gokz-top-core:
 * - gokz_top_base_url
 * - gokz_top_apikey
 */

static ConVar g_GOKZTop_BaseUrlCvar;
static ConVar g_GOKZTop_ApiKeyCvar;

stock bool GOKZTop_GetBaseUrl(char[] buffer, int maxlen)
{
    if (g_GOKZTop_BaseUrlCvar == null)
    {
        g_GOKZTop_BaseUrlCvar = FindConVar("gokz_top_base_url");
    }

    if (g_GOKZTop_BaseUrlCvar == null)
    {
        buffer[0] = '\0';
        return false;
    }

    g_GOKZTop_BaseUrlCvar.GetString(buffer, maxlen);
    TrimString(buffer);
    return buffer[0] != '\0';
}

stock bool GOKZTop_GetApiKey(char[] buffer, int maxlen)
{
    if (g_GOKZTop_ApiKeyCvar == null)
    {
        g_GOKZTop_ApiKeyCvar = FindConVar("gokz_top_apikey");
    }

    if (g_GOKZTop_ApiKeyCvar == null)
    {
        buffer[0] = '\0';
        return false;
    }

    g_GOKZTop_ApiKeyCvar.GetString(buffer, maxlen);
    TrimString(buffer);
    return buffer[0] != '\0';
}

stock bool GOKZTop_IsConfigured()
{
    char apiKey[128];
    return GOKZTop_GetApiKey(apiKey, sizeof(apiKey));
}

stock void GOKZTop_TrimTrailingSlash(char[] s)
{
    int len = strlen(s);
    while (len > 0 && s[len - 1] == '/')
    {
        s[len - 1] = '\0';
        len--;
    }
}

/**
 * Build a URL to the gokz.top backend API (v1).
 *
 * @param out       Output buffer
 * @param maxlen    Output maxlen
 * @param path      Must start with '/', e.g. "/maps/xyz/ratings"
 * @param query     Optional query string WITHOUT '?', e.g. "steamid64=123&limit=10"
 */
stock bool GOKZTop_BuildApiUrl(char[] out, int maxlen, const char[] path, const char[] query = "")
{
    char base[256];
    if (!GOKZTop_GetBaseUrl(base, sizeof(base)))
    {
        out[0] = '\0';
        return false;
    }
    GOKZTop_TrimTrailingSlash(base);

    // Allow base URL to be configured either as:
    // - https://gokz.top              (we append /api/v1)
    // - https://gokz.top/api/v1       (we do NOT append /api/v1 again)
    bool baseHasApiV1 = false;
    if (StrContains(base, "/api/v1", false) != -1)
    {
        // Only treat it as already having the prefix if it ends with /api/v1
        int len = strlen(base);
        if (len >= 7 && StrEqual(base[len - 7], "/api/v1", false))
        {
            baseHasApiV1 = true;
        }
    }

    if (query[0] != '\0')
    {
        if (baseHasApiV1)
        {
            Format(out, maxlen, "%s%s?%s", base, path, query);
        }
        else
        {
            Format(out, maxlen, "%s/api/v1%s?%s", base, path, query);
        }
    }
    else
    {
        if (baseHasApiV1)
        {
            Format(out, maxlen, "%s%s", base, path);
        }
        else
        {
            Format(out, maxlen, "%s/api/v1%s", base, path);
        }
    }
    return true;
}

stock bool GOKZTop_LooksLikeJson(const char[] body)
{
    // skip leading whitespace
    int i = 0;
    while (body[i] == ' ' || body[i] == '\t' || body[i] == '\r' || body[i] == '\n')
    {
        i++;
    }
    return body[i] == '{' || body[i] == '[';
}

/**
 * Percent-encode a string for use in URL path segments (UTF-8 bytes -> %XX).
 * Conservative encoding: alnum and - _ . ~ are left as-is, everything else is encoded.
 */
stock void GOKZTop_UrlEncode(const char[] input, char[] output, int maxlen)
{
    output[0] = '\0';

    int outLen = 0;
    for (int i = 0; input[i] != '\0' && outLen + 1 < maxlen; i++)
    {
        int c = input[i] & 0xFF;

        bool safe =
            (c >= 'a' && c <= 'z') ||
            (c >= 'A' && c <= 'Z') ||
            (c >= '0' && c <= '9') ||
            c == '-' || c == '_' || c == '.' || c == '~';

        if (safe)
        {
            output[outLen++] = view_as<char>(c);
            output[outLen] = '\0';
        }
        else
        {
            if (outLen + 3 >= maxlen) break;
            static const char hex[] = "0123456789ABCDEF";
            output[outLen++] = '%';
            output[outLen++] = hex[(c >> 4) & 0xF];
            output[outLen++] = hex[c & 0xF];
            output[outLen] = '\0';
        }
    }
}

/**
 * Escape a string for embedding as a JSON string value.
 */
stock void GOKZTop_JsonEscapeString(const char[] input, char[] output, int maxlen)
{
    output[0] = '\0';
    int outLen = 0;

    for (int i = 0; input[i] != '\0' && outLen + 1 < maxlen; i++)
    {
        int c = input[i] & 0xFF;

        if (c == '\\' || c == '"')
        {
            if (outLen + 2 >= maxlen) break;
            output[outLen++] = '\\';
            output[outLen++] = view_as<char>(c);
            output[outLen] = '\0';
        }
        else if (c == '\n')
        {
            if (outLen + 2 >= maxlen) break;
            output[outLen++] = '\\';
            output[outLen++] = 'n';
            output[outLen] = '\0';
        }
        else if (c == '\r')
        {
            if (outLen + 2 >= maxlen) break;
            output[outLen++] = '\\';
            output[outLen++] = 'r';
            output[outLen] = '\0';
        }
        else if (c == '\t')
        {
            if (outLen + 2 >= maxlen) break;
            output[outLen++] = '\\';
            output[outLen++] = 't';
            output[outLen] = '\0';
        }
        else if (c < 0x20)
        {
            // Drop other control chars (keep it simple)
            continue;
        }
        else
        {
            output[outLen++] = view_as<char>(c);
            output[outLen] = '\0';
        }
    }
}

/**
 * Create and configure a SteamWorks HTTP request with common headers.
 *
 * @param method        SteamWorks EHTTPMethod
 * @param url           Full URL
 * @param wantAuth      Whether to attach Authorization: Bearer <apikey>
 * @param timeoutSec    Absolute timeout in seconds (0 to skip)
 * @return              Request handle or INVALID_HANDLE on failure
 */
stock Handle GOKZTop_CreateSteamWorksRequest(EHTTPMethod method, const char[] url, bool wantAuth = true, int timeoutSec = 15)
{
    Handle req = SteamWorks_CreateHTTPRequest(method, url);
    if (req == INVALID_HANDLE)
    {
        return INVALID_HANDLE;
    }

    SteamWorks_SetHTTPRequestHeaderValue(req, "Accept", "application/json");

    if (timeoutSec > 0)
    {
        SteamWorks_SetHTTPRequestAbsoluteTimeoutMS(req, timeoutSec * 1000);
    }

    if (wantAuth)
    {
        char apiKey[128];
        if (!GOKZTop_GetApiKey(apiKey, sizeof(apiKey)))
        {
            delete req;
            return INVALID_HANDLE;
        }

        char auth[256];
        Format(auth, sizeof(auth), "Bearer %s", apiKey);
        SteamWorks_SetHTTPRequestHeaderValue(req, "Authorization", auth);
    }

    return req;
}

stock bool GOKZTop_SetJsonBody(Handle req, const char[] jsonBody)
{
    if (req == INVALID_HANDLE) return false;
    SteamWorks_SetHTTPRequestHeaderValue(req, "Content-Type", "application/json");
    return SteamWorks_SetHTTPRequestRawPostBody(req, "application/json", jsonBody, strlen(jsonBody));
}

stock bool GOKZTop_ReadResponseBody(Handle req, char[] out, int maxlen)
{
    out[0] = '\0';
    if (req == INVALID_HANDLE) return false;

    int size = 0;
    if (!SteamWorks_GetHTTPResponseBodySize(req, size) || size <= 0)
    {
        return false;
    }

    if (size >= maxlen)
    {
        size = maxlen - 1;
    }

    bool ok = SteamWorks_GetHTTPResponseBodyData(req, out, size);
    out[size] = '\0';
    return ok;
}

/**
 * Get mode string for API (KZT, SKZ, VNL).
 * 
 * @param mode      GOKZ mode (0=Vanilla/VNL, 1=Simple/SKZ, 2=Timer/KZT)
 * @param out       Output buffer
 * @param maxlen    Output buffer size
 * @return          True if mode is valid, false otherwise
 */
stock bool GOKZTop_GetModeString(int mode, char[] out, int maxlen)
{
    switch (mode)
    {
        case 0: // Vanilla/VNL
        {
            strcopy(out, maxlen, "VNL");
            return true;
        }
        case 1: // Simple/SKZ
        {
            strcopy(out, maxlen, "SKZ");
            return true;
        }
        case 2: // Timer/KZT
        {
            strcopy(out, maxlen, "KZT");
            return true;
        }
        default:
        {
            out[0] = '\0';
            return false;
        }
    }
}

/**
 * Create an HTTP request to fetch leaderboard data (rank and rating) for a player.
 * The caller must set the HTTP callbacks using SteamWorks_SetHTTPCallbacks before sending.
 * 
 * @param steamid64     Player's SteamID64
 * @param mode          GOKZ mode (0=VNL, 1=SKZ, 2=KZT)
 * @param userid        User ID to store in context (retrieved via data1 & 0xFFFF)
 * @param timeoutSec    Request timeout in seconds (default: 15)
 * @return              Request handle or INVALID_HANDLE on failure
 */
stock Handle GOKZTop_FetchLeaderboardData(const char[] steamid64, int mode, int userid = 0, int timeoutSec = 15)
{
    char modeStr[8];
    if (!GOKZTop_GetModeString(mode, modeStr, sizeof(modeStr)))
    {
        return INVALID_HANDLE;
    }

    char path[128];
    Format(path, sizeof(path), "/leaderboards/%s", steamid64);

    char query[32];
    Format(query, sizeof(query), "mode=%s", modeStr);

    char url[1024];
    if (!GOKZTop_BuildApiUrl(url, sizeof(url), path, query))
    {
        return INVALID_HANDLE;
    }

    Handle req = GOKZTop_CreateSteamWorksRequest(k_EHTTPMethodGET, url, false, timeoutSec);
    if (req == INVALID_HANDLE)
    {
        return INVALID_HANDLE;
    }

    // Store mode in context value (lower 16 bits = userid, upper 16 bits = mode)
    int contextValue = userid | (mode << 16);
    SteamWorks_SetHTTPRequestContextValue(req, contextValue, 0);

    return req;
}

/**
 * Get player's rating for a specific mode.
 * Requires gokz-top-core plugin.
 * 
 * @param client    Client index
 * @param mode      GOKZ mode (0=VNL, 1=SKZ, 2=KZT)
 * @return          Rating value (0.0 if not loaded or invalid)
 */
native float GOKZTop_GetRating(int client, int mode);

/**
 * Get player's rank for a specific mode.
 * Requires gokz-top-core plugin.
 * 
 * @param client    Client index
 * @param mode      GOKZ mode (0=VNL, 1=SKZ, 2=KZT)
 * @return          Rank value (0 if not ranked or not loaded)
 */
native int GOKZTop_GetRank(int client, int mode);

/**
 * Get player's regional rank for a specific mode.
 * Requires gokz-top-core plugin.
 * 
 * @param client    Client index
 * @param mode      GOKZ mode (0=VNL, 1=SKZ, 2=KZT)
 * @return          Regional rank value (0 if not available or not loaded)
 */
native int GOKZTop_GetRegionalRank(int client, int mode);

/**
 * Check if player has regional rank data for a specific mode.
 * Requires gokz-top-core plugin.
 * 
 * @param client    Client index
 * @param mode      GOKZ mode (0=VNL, 1=SKZ, 2=KZT)
 * @return          True if regional rank is available, false otherwise
 */
native bool GOKZTop_HasRegionalRank(int client, int mode);

/**
 * Get player's region code for a specific mode.
 * Requires gokz-top-core plugin.
 * 
 * @param client    Client index
 * @param mode      GOKZ mode (0=VNL, 1=SKZ, 2=KZT)
 * @param buffer    Output buffer for region code
 * @param maxlen    Maximum length of buffer
 * @return          Number of bytes written
 */
native int GOKZTop_GetRegionCode(int client, int mode, char[] buffer, int maxlen);

/**
 * Check if leaderboard data is loaded for a player and mode.
 * Requires gokz-top-core plugin.
 * 
 * @param client    Client index
 * @param mode      GOKZ mode (0=VNL, 1=SKZ, 2=KZT)
 * @return          True if data is loaded, false otherwise
 */
native bool GOKZTop_IsLeaderboardDataLoaded(int client, int mode);

/**
 * Refresh leaderboard data for a player and mode.
 * Requires gokz-top-core plugin.
 * 
 * @param client    Client index
 * @param mode      GOKZ mode (0=VNL, 1=SKZ, 2=KZT)
 * @return          True on success, false on failure
 */
native bool GOKZTop_RefreshLeaderboardData(int client, int mode);

/**
 * Forward called when leaderboard data is fetched for a player.
 * 
 * @param client        Client index
 * @param mode          GOKZ mode (0=VNL, 1=SKZ, 2=KZT)
 * @param rating        Player's rating
 * @param rank          Player's rank (0 if not ranked)
 * @param regionalRank  Player's regional rank (0 if not available)
 * @param hasRegionalRank True if regional rank is available
 * @param regionCode    Region code (e.g., "EU", "NA", empty if not available)
 */
forward void GOKZTop_OnLeaderboardDataFetched(int client, int mode, float rating, int rank, int regionalRank, bool hasRegionalRank, const char[] regionCode);


