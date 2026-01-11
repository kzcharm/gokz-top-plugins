// gokz-top-players
// Player session tracking plugin for GOKZ Top that posts player connect/disconnect events to the API.
//
// Responsibilities:
// - Post player connect events to /api/v1/player-sessions/connect
// - Post player disconnect events to /api/v1/player-sessions/disconnect
// - Track map_name at connect time (OnClientAuthorized is called on map changes)
// - File-based retry mechanism for failed requests

#include <sourcemod>
#include <SteamWorks>

#undef REQUIRE_PLUGIN
#include <gokz-top>
#define REQUIRE_PLUGIN

#pragma semicolon 1
#pragma newdecls required

public Plugin myinfo =
{
    name        = "GOKZTop Players",
    author      = "Cinyan10",
    description = "Track player sessions and post to GOKZ Top API",
    version     = "1.0.0"
};

#define DATA_PATH "data/gokz-top-players"
#define DATA_FILE "retry_{timestamp}_{gametick}.dat"
#define API_TIMEOUT 12
#define RETRY_INTERVAL 30.0

// Player session tracking
char gC_PlayerSteamID64[MAXPLAYERS + 1][32];
char gC_PlayerMapName[MAXPLAYERS + 1][64];
int gI_PlayerConnectTime[MAXPLAYERS + 1];
bool gB_PlayerConnected[MAXPLAYERS + 1];

// Request tracking
bool gB_ConnectRequestInFlight[MAXPLAYERS + 1];
char gC_LastRequestFile[MAXPLAYERS + 1][PLATFORM_MAX_PATH];

// Retry timer
Handle gH_RetryTimer = null;

// =====[ PLUGIN LIFECYCLE ]=====

public void OnPluginStart()
{
    // Create retry directory
    char path[PLATFORM_MAX_PATH];
    BuildPath(Path_SM, path, sizeof(path), "%s", DATA_PATH);
    
    if (!DirExists(path))
    {
        if (!CreateDirectory(path, 511)) // 511 = 0777 in decimal
        {
            LogError("[gokz-top-players] Failed to create directory %s", path);
        }
    }

    // Initialize player data
    for (int i = 1; i <= MaxClients; i++)
    {
        gC_PlayerSteamID64[i][0] = '\0';
        gC_PlayerMapName[i][0] = '\0';
        gI_PlayerConnectTime[i] = 0;
        gB_PlayerConnected[i] = false;
        gB_ConnectRequestInFlight[i] = false;
        gC_LastRequestFile[i][0] = '\0';
    }

    // Start retry timer
    gH_RetryTimer = CreateTimer(RETRY_INTERVAL, Timer_RetryFailedRequests, _, TIMER_REPEAT);
}

public void OnPluginEnd()
{
    if (gH_RetryTimer != null)
    {
        delete gH_RetryTimer;
        gH_RetryTimer = null;
    }
}

// =====[ PLAYER EVENTS ]=====

public void OnClientAuthorized(int client, const char[] auth)
{
    if (IsFakeClient(client))
    {
        return;
    }

    // Get steamid64
    char steamid64[32];
    if (!GetClientAuthId(client, AuthId_SteamID64, steamid64, sizeof(steamid64), true))
    {
        // SteamID64 not available yet, will retry in OnClientPutInServer
        return;
    }

    // Store player data
    strcopy(gC_PlayerSteamID64[client], sizeof(gC_PlayerSteamID64[]), steamid64);
    
    // Get current map name
    char mapName[64];
    GetCurrentMap(mapName, sizeof(mapName));
    strcopy(gC_PlayerMapName[client], sizeof(gC_PlayerMapName[]), mapName);
    
    // Get connect time
    gI_PlayerConnectTime[client] = GetTime();
    gB_PlayerConnected[client] = true;

    // Post connect event
    PostPlayerConnect(client, steamid64, mapName);
}

public void OnClientPutInServer(int client)
{
    if (IsFakeClient(client))
    {
        return;
    }

    // ONLY post if we haven't already connected this player
    // This is a fallback for when SteamID wasn't available in OnClientAuthorized
    if (gC_PlayerSteamID64[client][0] == '\0' && !gB_PlayerConnected[client])
    {
        char steamid64[32];
        if (GetClientAuthId(client, AuthId_SteamID64, steamid64, sizeof(steamid64), true))
        {
            // Store player data
            strcopy(gC_PlayerSteamID64[client], sizeof(gC_PlayerSteamID64[]), steamid64);
            
            // Get current map name
            char mapName[64];
            GetCurrentMap(mapName, sizeof(mapName));
            strcopy(gC_PlayerMapName[client], sizeof(gC_PlayerMapName[]), mapName);
            
            // Get connect time
            gI_PlayerConnectTime[client] = GetTime();
            gB_PlayerConnected[client] = true;

            // Post connect event
            PostPlayerConnect(client, steamid64, mapName);
        }
    }
}

public void OnClientDisconnect(int client)
{
    if (IsFakeClient(client))
    {
        return;
    }

    // Try to get steamid64 - first from stored data, then directly from client
    char steamid64[32];
    bool hasSteamID64 = false;
    
    if (gC_PlayerSteamID64[client][0] != '\0')
    {
        strcopy(steamid64, sizeof(steamid64), gC_PlayerSteamID64[client]);
        hasSteamID64 = true;
    }
    else
    {
        // Try to get it directly from client (might still be valid)
        if (GetClientAuthId(client, AuthId_SteamID64, steamid64, sizeof(steamid64), false))
        {
            hasSteamID64 = true;
        }
    }

    // Post disconnect if we have steamid64 and player was connected
    if (hasSteamID64)
    {
        if (gB_PlayerConnected[client])
        {
            PostPlayerDisconnect(client, steamid64);
        }
        else
        {
            // Player disconnected but was never marked as connected
            // This can happen if connect POST failed or player disconnected before connect completed
            // Still post disconnect to ensure session is closed on server side
            LogMessage("[gokz-top-players] Player %s disconnected but was not marked as connected, posting disconnect anyway", steamid64);
            PostPlayerDisconnect(client, steamid64);
        }
    }
    else
    {
        LogError("[gokz-top-players] Cannot post disconnect for client %d: no steamid64 available", client);
    }

    // Reset player data (filename will be cleared when disconnect request completes)
    gC_PlayerSteamID64[client][0] = '\0';
    gC_PlayerMapName[client][0] = '\0';
    gI_PlayerConnectTime[client] = 0;
    gB_PlayerConnected[client] = false;
    gB_ConnectRequestInFlight[client] = false;
    // Note: gC_LastRequestFile is NOT cleared here - it will be cleared when disconnect request completes
    // This allows us to delete the saved file if disconnect succeeds
}

// =====[ UTC TIMESTAMP FORMATTING ]=====

/**
 * Converts a Unix timestamp to ISO 8601 UTC format string.
 * This manually calculates UTC time components since FormatTime() uses server timezone.
 * Algorithm based on standard Unix timestamp to UTC conversion.
 * 
 * @param timestamp    Unix timestamp (seconds since 1970-01-01 00:00:00 UTC)
 * @param buffer       Buffer to store the formatted string
 * @param maxlen       Maximum length of the buffer
 */
void FormatUTCTime(int timestamp, char[] buffer, int maxlen)
{
    // Unix epoch: 1970-01-01 00:00:00 UTC
    // Calculate days since epoch (Jan 1, 1970)
    int days = timestamp / 86400;
    int seconds = timestamp % 86400;
    
    // Calculate year, month, day
    int year = 1970;
    int month = 1;
    int day = 1;
    
    // Days to add from epoch
    int daysToAdd = days;
    
    // Calculate year
    while (daysToAdd > 0)
    {
        int daysInYear = IsLeapYear(year) ? 366 : 365;
        if (daysToAdd >= daysInYear)
        {
            daysToAdd -= daysInYear;
            year++;
        }
        else
        {
            break;
        }
    }
    
    // Calculate month and day
    int daysInMonth[12] = {31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31};
    if (IsLeapYear(year))
    {
        daysInMonth[1] = 29;
    }
    
    // Find the correct month
    for (int m = 0; m < 12 && daysToAdd > 0; m++)
    {
        if (daysToAdd >= daysInMonth[m])
        {
            daysToAdd -= daysInMonth[m];
            month++;
        }
        else
        {
            day += daysToAdd;
            daysToAdd = 0;
        }
    }
    
    // Calculate time components (hour, minute, second)
    int hour = seconds / 3600;
    int minute = (seconds % 3600) / 60;
    int second = seconds % 60;
    
    // Format as ISO 8601 UTC: YYYY-MM-DDTHH:MM:SSZ
    Format(buffer, maxlen, "%04d-%02d-%02dT%02d:%02d:%02dZ", year, month, day, hour, minute, second);
}

bool IsLeapYear(int year)
{
    return (year % 4 == 0 && year % 100 != 0) || (year % 400 == 0);
}

// =====[ API POSTING ]=====

void PostPlayerConnect(int client, const char[] steamid64, const char[] mapName)
{
    if (!GOKZTop_IsConfigured())
    {
        // API key not configured, silently skip
        return;
    }

    // Don't post if request already in flight (prevents duplicates)
    if (gB_ConnectRequestInFlight[client])
    {
        LogMessage("[gokz-top-players] Skipping duplicate connect post for client %d (request in flight)", client);
        return;
    }

    // Get IP address
    char ip[64];
    if (!GetClientIP(client, ip, sizeof(ip), true))
    {
        LogError("[gokz-top-players] Failed to get IP address for client %d", client);
        return;
    }

    // Format ISO 8601 UTC timestamp
    // GetTime() returns UTC Unix timestamp, convert to UTC ISO 8601 format
    char connectedTime[32];
    FormatUTCTime(gI_PlayerConnectTime[client], connectedTime, sizeof(connectedTime));

    // Build JSON body
    char jsonBody[512];
    char steamid64Esc[64];
    char ipEsc[128];
    char mapNameEsc[128];
    char connectedTimeEsc[64];
    
    GOKZTop_JsonEscapeString(steamid64, steamid64Esc, sizeof(steamid64Esc));
    GOKZTop_JsonEscapeString(ip, ipEsc, sizeof(ipEsc));
    GOKZTop_JsonEscapeString(mapName, mapNameEsc, sizeof(mapNameEsc));
    GOKZTop_JsonEscapeString(connectedTime, connectedTimeEsc, sizeof(connectedTimeEsc));

    Format(jsonBody, sizeof(jsonBody),
        "{\"steamid64\":\"%s\",\"ip_address\":\"%s\",\"connected_time\":\"%s\",\"map_name\":\"%s\"}",
        steamid64Esc, ipEsc, connectedTimeEsc, mapNameEsc);

    // Build API URL
    char path[128];
    strcopy(path, sizeof(path), "/player-sessions/connect");

    char url[1024];
    if (!GOKZTop_BuildApiUrl(url, sizeof(url), path))
    {
        LogError("[gokz-top-players] Failed to build API URL");
        return;
    }

    // Create HTTP request
    Handle req = GOKZTop_CreateSteamWorksRequest(k_EHTTPMethodPOST, url, true, API_TIMEOUT);
    if (req == INVALID_HANDLE)
    {
        LogError("[gokz-top-players] Failed to create HTTP request (API key missing?)");
        return;
    }

    // Set JSON body
    if (!GOKZTop_SetJsonBody(req, jsonBody))
    {
        LogError("[gokz-top-players] Failed to set JSON body");
        delete req;
        return;
    }

    // Save request data for retry before sending
    SaveRequestBeforeSend(url, jsonBody, true, client);

    // Mark request as in flight
    gB_ConnectRequestInFlight[client] = true;

    // Store context: userid in lower 16 bits, bit 16 = connect flag
    int userid = GetClientUserId(client);
    int contextValue = userid | (1 << 16); // Bit 16 indicates connect request
    SteamWorks_SetHTTPRequestContextValue(req, contextValue, 0);

    // Send request
    SteamWorks_SetHTTPCallbacks(req, OnPlayerRequestCompleted);
    SteamWorks_SendHTTPRequest(req);
}

void PostPlayerDisconnect(int client, const char[] steamid64)
{
    if (!GOKZTop_IsConfigured())
    {
        // API key not configured, silently skip
        return;
    }

    // Validate steamid64
    if (steamid64[0] == '\0' || strlen(steamid64) == 0)
    {
        LogError("[gokz-top-players] Cannot post disconnect: empty steamid64 for client %d", client);
        return;
    }

    // Get map_name from stored data (the map they connected on)
    char mapName[64];
    if (gC_PlayerMapName[client][0] != '\0')
    {
        strcopy(mapName, sizeof(mapName), gC_PlayerMapName[client]);
    }
    else
    {
        // Fallback: get current map if stored map name is empty
        GetCurrentMap(mapName, sizeof(mapName));
    }

    // Format ISO 8601 UTC timestamp
    // GetTime() returns UTC Unix timestamp, convert to UTC ISO 8601 format
    int disconnectTime = GetTime();
    char disconnectTimeStr[32];
    FormatUTCTime(disconnectTime, disconnectTimeStr, sizeof(disconnectTimeStr));

    // Build JSON body
    char jsonBody[512];
    char steamid64Esc[64];
    char disconnectTimeEsc[64];
    char mapNameEsc[128];
    
    GOKZTop_JsonEscapeString(steamid64, steamid64Esc, sizeof(steamid64Esc));
    GOKZTop_JsonEscapeString(disconnectTimeStr, disconnectTimeEsc, sizeof(disconnectTimeEsc));
    GOKZTop_JsonEscapeString(mapName, mapNameEsc, sizeof(mapNameEsc));

    Format(jsonBody, sizeof(jsonBody),
        "{\"steamid64\":\"%s\",\"disconnect_time\":\"%s\",\"map_name\":\"%s\"}",
        steamid64Esc, disconnectTimeEsc, mapNameEsc);

    // Build API URL
    char path[128];
    strcopy(path, sizeof(path), "/player-sessions/disconnect");

    char url[1024];
    if (!GOKZTop_BuildApiUrl(url, sizeof(url), path))
    {
        LogError("[gokz-top-players] Failed to build API URL");
        return;
    }

    // Create HTTP request
    Handle req = GOKZTop_CreateSteamWorksRequest(k_EHTTPMethodPOST, url, true, API_TIMEOUT);
    if (req == INVALID_HANDLE)
    {
        LogError("[gokz-top-players] Failed to create HTTP request (API key missing?)");
        return;
    }

    // Set JSON body
    if (!GOKZTop_SetJsonBody(req, jsonBody))
    {
        LogError("[gokz-top-players] Failed to set JSON body");
        delete req;
        return;
    }

    // Save request data for retry before sending
    SaveRequestBeforeSend(url, jsonBody, false, client);

    // Store context: userid in lower 16 bits, bit 17 = disconnect flag
    int userid = GetClientUserId(client);
    int contextValue = userid | (1 << 17); // Bit 17 indicates disconnect request
    SteamWorks_SetHTTPRequestContextValue(req, contextValue, 0);

    // Send request
    SteamWorks_SetHTTPCallbacks(req, OnPlayerRequestCompleted);
    SteamWorks_SendHTTPRequest(req);
}

public void OnPlayerRequestCompleted(Handle hRequest, bool bFailure, bool bRequestSuccessful, EHTTPStatusCode eStatusCode, any data1, any data2)
{
    int contextValue = data1;
    int userID = contextValue & 0xFFFF;
    int client = GetClientOfUserId(userID);
    bool isConnect = (contextValue & (1 << 16)) != 0;
    bool isDisconnect = (contextValue & (1 << 17)) != 0;

    // Handle connect request completion
    if (isConnect && client > 0 && client <= MaxClients)
    {
        gB_ConnectRequestInFlight[client] = false;
    }

    // Static counters for throttling error logs
    static int failureCount = 0;
    static int errorCount = 0;

    // Handle timeout or failure
    if (bFailure || !bRequestSuccessful)
    {
        failureCount++;
        if (failureCount % 10 == 1) // Log every 10th failure
        {
            LogError("[gokz-top-players] Failed to post player %s (network error or timeout)", isConnect ? "connect" : "disconnect");
        }

        // Request data already saved before sending, no need to save again

        if (hRequest != INVALID_HANDLE)
        {
            delete hRequest;
        }
        return;
    }

    int status = view_as<int>(eStatusCode);

    // Handle HTTP errors
    if (status < 200 || status >= 300)
    {
        errorCount++;
        if (errorCount % 10 == 1) // Log every 10th error
        {
            char body[512];
            if (hRequest != INVALID_HANDLE && GOKZTop_ReadResponseBody(hRequest, body, sizeof(body)))
            {
                LogError("[gokz-top-players] Failed to post player %s (HTTP %d): %s", isConnect ? "connect" : "disconnect", status, body);
            }
            else
            {
                LogError("[gokz-top-players] Failed to post player %s (HTTP %d)", isConnect ? "connect" : "disconnect", status);
            }
        }

        // Request data already saved before sending, no need to save again

        if (hRequest != INVALID_HANDLE)
        {
            delete hRequest;
        }
        return;
    }

    // Success - reset failure counters and delete saved request file
    failureCount = 0;
    errorCount = 0;

    // Delete the saved request file since it succeeded
    if (client > 0 && client <= MaxClients && gC_LastRequestFile[client][0] != '\0')
    {
        if (FileExists(gC_LastRequestFile[client]))
        {
            DeleteFile(gC_LastRequestFile[client]);
        }
        gC_LastRequestFile[client][0] = '\0';
    }
    else if (isDisconnect)
    {
        // For disconnect, client might be invalid, try to find and delete the file
        // by checking recent files (this is a best-effort cleanup)
        // The retry mechanism will handle any remaining files
    }

    if (hRequest != INVALID_HANDLE)
    {
        delete hRequest;
    }
}

// =====[ RETRY MECHANISM ]=====

public Action Timer_RetryFailedRequests(Handle timer)
{
    char path[PLATFORM_MAX_PATH];
    BuildPath(Path_SM, path, sizeof(path), DATA_PATH);

    DirectoryListing dataFiles = OpenDirectory(path);
    if (dataFiles == null)
    {
        return Plugin_Continue;
    }

    char dataFile[PLATFORM_MAX_PATH];
    FileType fileType;
    
    while (dataFiles.GetNext(dataFile, sizeof(dataFile), fileType))
    {
        if (fileType == FileType_File && StrContains(dataFile, "retry_") == 0 && StrContains(dataFile, ".dat") != -1)
        {
            char fullPath[PLATFORM_MAX_PATH];
            Format(fullPath, sizeof(fullPath), "%s/%s", path, dataFile);
            
            File binaryFile = OpenFile(fullPath, "r");
            if (binaryFile == null)
            {
                continue;
            }

            // Read stored request data
            int urlLength;
            binaryFile.ReadInt16(urlLength);
            if (urlLength <= 0 || urlLength > 1024)
            {
                delete binaryFile;
                DeleteFile(fullPath);
                continue;
            }

            char[] url = new char[urlLength + 1];
            binaryFile.ReadString(url, urlLength, urlLength);
            url[urlLength] = '\0';

            int bodyLength;
            binaryFile.ReadInt32(bodyLength);
            if (bodyLength <= 0 || bodyLength > 4096)
            {
                delete binaryFile;
                DeleteFile(fullPath);
                continue;
            }

            char[] jsonBody = new char[bodyLength + 1];
            binaryFile.ReadString(jsonBody, bodyLength, bodyLength);
            jsonBody[bodyLength] = '\0';

            // Read request type (0 = connect, 1 = disconnect) but we don't need it for retry
            int requestTypeRaw;
            binaryFile.ReadInt8(requestTypeRaw);

            bool keyRequired;
            binaryFile.ReadInt8(keyRequired);

            int timestamp;
            binaryFile.ReadInt32(timestamp);

            delete binaryFile;

            // Retry the request
            RetryRequest(url, jsonBody, keyRequired);

            // Delete the file after attempting retry (success or failure)
            DeleteFile(fullPath);
        }
    }

    delete dataFiles;
    return Plugin_Continue;
}

void RetryRequest(const char[] url, const char[] jsonBody, bool keyRequired)
{
    if (!GOKZTop_IsConfigured() && keyRequired)
    {
        // API key not configured, skip retry
        return;
    }

    // Create HTTP request
    Handle req = GOKZTop_CreateSteamWorksRequest(k_EHTTPMethodPOST, url, keyRequired, API_TIMEOUT);
    if (req == INVALID_HANDLE)
    {
        return;
    }

    // Set JSON body
    if (!GOKZTop_SetJsonBody(req, jsonBody))
    {
        delete req;
        return;
    }

    // Store context: bit 18 = retry flag
    int contextValue = (1 << 18); // Bit 18 indicates retry request
    SteamWorks_SetHTTPRequestContextValue(req, contextValue, 0);

    // Send request
    SteamWorks_SetHTTPCallbacks(req, OnRetryRequestCompleted);
    SteamWorks_SendHTTPRequest(req);
}

public void OnRetryRequestCompleted(Handle hRequest, bool bFailure, bool bRequestSuccessful, EHTTPStatusCode eStatusCode, any data1, any data2)
{
    int contextValue = data1;
    bool isRetry = (contextValue & (1 << 18)) != 0;

    if (!isRetry)
    {
        if (hRequest != INVALID_HANDLE)
        {
            delete hRequest;
        }
        return;
    }

    // Static counters for throttling error logs
    static int retryFailureCount = 0;
    static int retryErrorCount = 0;

    // Handle timeout or failure
    if (bFailure || !bRequestSuccessful)
    {
        retryFailureCount++;
        if (retryFailureCount % 10 == 1)
        {
            LogError("[gokz-top-players] Retry failed (network error or timeout)");
        }

        // Retry failures are not saved again - file was already deleted
        if (hRequest != INVALID_HANDLE)
        {
            delete hRequest;
        }
        return;
    }

    int status = view_as<int>(eStatusCode);

    // Handle HTTP errors
    if (status < 200 || status >= 300)
    {
        retryErrorCount++;
        if (retryErrorCount % 10 == 1)
        {
            char body[512];
            if (hRequest != INVALID_HANDLE && GOKZTop_ReadResponseBody(hRequest, body, sizeof(body)))
            {
                LogError("[gokz-top-players] Retry failed (HTTP %d): %s", status, body);
            }
            else
            {
                LogError("[gokz-top-players] Retry failed (HTTP %d)", status);
            }
        }

        // Retry failures are not saved again - file was already deleted
        if (hRequest != INVALID_HANDLE)
        {
            delete hRequest;
        }
        return;
    }

    // Success - reset failure counters
    retryFailureCount = 0;
    retryErrorCount = 0;

    if (hRequest != INVALID_HANDLE)
    {
        delete hRequest;
    }
}

// Helper function to save failed request before sending
void SaveRequestBeforeSend(const char[] url, const char[] jsonBody, bool isConnect, int client)
{
    char szTimestamp[32];
    IntToString(GetTime(), szTimestamp, sizeof(szTimestamp));

    char szGameTime[32];
    FloatToString(GetEngineTime(), szGameTime, sizeof(szGameTime));

    char dataFile[PLATFORM_MAX_PATH] = DATA_FILE;
    ReplaceString(dataFile, sizeof(dataFile), "{gametick}", szGameTime);
    ReplaceString(dataFile, sizeof(dataFile), "{timestamp}", szTimestamp);

    char path[PLATFORM_MAX_PATH];
    BuildPath(Path_SM, path, sizeof(path), "%s/%s", DATA_PATH, dataFile);

    // Store filename for this client
    if (client > 0 && client <= MaxClients)
    {
        strcopy(gC_LastRequestFile[client], sizeof(gC_LastRequestFile[]), path);
    }

    File binaryFile = OpenFile(path, "wb");
    if (binaryFile == null)
    {
        LogError("[gokz-top-players] Could not create binary file %s", path);
        if (client > 0 && client <= MaxClients)
        {
            gC_LastRequestFile[client][0] = '\0';
        }
        return;
    }

    // Write URL length and URL
    int urlLen = strlen(url);
    binaryFile.WriteInt16(urlLen);
    binaryFile.WriteString(url, false);

    // Write JSON body length and body
    int bodyLen = strlen(jsonBody);
    binaryFile.WriteInt32(bodyLen);
    binaryFile.WriteString(jsonBody, false);

    // Write request type (0 = connect, 1 = disconnect)
    binaryFile.WriteInt8(isConnect ? 0 : 1);

    // Write key required flag (always true for our API)
    binaryFile.WriteInt8(1);

    // Write timestamp
    binaryFile.WriteInt32(StringToInt(szTimestamp));

    delete binaryFile;
}
