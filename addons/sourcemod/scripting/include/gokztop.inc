#if defined _gokztop_included_
#endinput
#endif
#define _gokztop_included_

#include <sourcemod>
#include <SteamWorks>

/**
 * Shared helper include for GOKZ Top plugins.
 *
 * Depends on ConVars created by gokztop-core:
 * - gokztop_base_url
 * - gokztop_apikey
 */

static ConVar g_GOKZTop_BaseUrlCvar;
static ConVar g_GOKZTop_ApiKeyCvar;

stock bool GOKZTop_GetBaseUrl(char[] buffer, int maxlen)
{
    if (g_GOKZTop_BaseUrlCvar == null)
    {
        g_GOKZTop_BaseUrlCvar = FindConVar("gokztop_base_url");
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
        g_GOKZTop_ApiKeyCvar = FindConVar("gokztop_apikey");
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


