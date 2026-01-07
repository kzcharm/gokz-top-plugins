// gokz-top-servers
// Server status plugin for GOKZ Top that pushes server and player data to the API.
//
// Responsibilities:
// - Collect server status (hostname, map, player counts)
// - Collect player data (name, steamid64, timer info, mode, status, teleports)
// - POST data to /api/v1/public-servers/status/ endpoint
// - Fetch and cache server IP address from ipify.org

#include <sourcemod>
#include <autoexecconfig>
#include <cstrike>
#include <SteamWorks>

#undef REQUIRE_PLUGIN
#include <gokz/core>
#include <gokz-top>
#define REQUIRE_PLUGIN

#pragma semicolon 1
#pragma newdecls required

public Plugin myinfo =
{
    name        = "GOKZTop Servers",
    author      = "Cinyan10",
    description = "Push server status to GOKZ Top API",
    version     = "1.0.0"
};

#define MODE_COUNT 3
#define IPIFY_URL "https://api.ipify.org/"
#define IPIFY_TIMEOUT 10
#define API_TIMEOUT 12

// Configuration
ConVar gCV_UpdateInterval = null;
char gC_ServerIP[64];
bool gB_ServerIPReady = false;
bool gB_IPFetchInProgress = false;

// Request tracking
bool gB_RequestInFlight = false;

// Timer
Handle gH_StatusTimer = null;

// Player status tracking
char gC_PlayerStatus[MAXPLAYERS + 1][32];

// =====[ PLUGIN LIFECYCLE ]=====

public void OnPluginStart()
{
    // Create config file for update interval
    AutoExecConfig_SetFile("gokz-top-servers", "sourcemod/gokz-top");
    AutoExecConfig_SetCreateFile(true);
    AutoExecConfig_SetCreateDirectory(true);

    gCV_UpdateInterval = AutoExecConfig_CreateConVar(
        "gokz_top_servers_update_interval",
        "4.0",
        "Update interval in seconds for server status updates (default: 4.0)",
        FCVAR_NONE,
        true,
        0.1,
        true,
        60.0
    );

    AutoExecConfig_ExecuteFile();
    AutoExecConfig_CleanFile();

    // Hook convar changes
    HookConVarChange(gCV_UpdateInterval, OnUpdateIntervalChanged);

    // Initialize player statuses
    for (int i = 1; i <= MaxClients; i++)
    {
        strcopy(gC_PlayerStatus[i], sizeof(gC_PlayerStatus[]), "not_started");
    }

    // Load or fetch server IP
    LoadServerIP();
}

public void OnPluginEnd()
{
    if (gH_StatusTimer != null)
    {
        delete gH_StatusTimer;
        gH_StatusTimer = null;
    }
}

public void OnMapStart()
{
    // Reset all player statuses at the start of each map
    for (int client = 1; client <= MaxClients; client++)
    {
        strcopy(gC_PlayerStatus[client], sizeof(gC_PlayerStatus[]), "not_started");
    }

    // Start status timer if IP is ready
    if (gB_ServerIPReady)
    {
        StartStatusTimer();
    }
}

public void OnClientPutInServer(int client)
{
    if (IsFakeClient(client))
    {
        return;
    }

    strcopy(gC_PlayerStatus[client], sizeof(gC_PlayerStatus[]), "not_started");
}

public void OnClientDisconnect(int client)
{
    if (IsFakeClient(client))
    {
        return;
    }

    // When the last human leaves, force a final update
    CheckEmptyServer();
}

public void OnServerEnterHibernation()
{
    // Ensure the API reflects an empty/hibernating server
    CheckEmptyServer();
}

// =====[ IP ADDRESS MANAGEMENT ]=====

void BuildGameConfigPath(char[] buffer, int maxlen, const char[] file)
{
    // Get SourceMod directory (addons/sourcemod/)
    char smPath[PLATFORM_MAX_PATH];
    BuildPath(Path_SM, smPath, sizeof(smPath), "");
    
    // Remove trailing slash if present
    int len = strlen(smPath);
    if (len > 0 && (smPath[len - 1] == '/' || smPath[len - 1] == '\\'))
    {
        smPath[len - 1] = '\0';
    }
    
    // Find "addons/sourcemod" or "addons\sourcemod" and get everything before it
    char gamePath[PLATFORM_MAX_PATH];
    int pos = StrContains(smPath, "/addons/sourcemod");
    if (pos == -1)
    {
        pos = StrContains(smPath, "\\addons\\sourcemod");
    }
    
    if (pos != -1)
    {
        // Extract game directory (everything before addons/sourcemod)
        strcopy(gamePath, sizeof(gamePath), smPath);
        gamePath[pos] = '\0';
    }
    else
    {
        // Fallback: go up two directories
        Format(gamePath, sizeof(gamePath), "%s/../..", smPath);
    }
    
    // Build final path: game_dir/cfg/sourcemod/gokz-top/file
    if (strlen(file) > 0)
    {
        Format(buffer, maxlen, "%s/cfg/sourcemod/gokz-top/%s", gamePath, file);
    }
    else
    {
        Format(buffer, maxlen, "%s/cfg/sourcemod/gokz-top", gamePath);
    }
}

void LoadServerIP()
{
    char configPath[PLATFORM_MAX_PATH];
    BuildGameConfigPath(configPath, sizeof(configPath), "server_ip.cfg");

    // Check if file exists
    if (FileExists(configPath))
    {
        File file = OpenFile(configPath, "r");
        if (file != null)
        {
            // Read IP from file (plain text, single line)
            if (file.ReadLine(gC_ServerIP, sizeof(gC_ServerIP)))
            {
                TrimString(gC_ServerIP);
                if (strlen(gC_ServerIP) > 0)
                {
                    gB_ServerIPReady = true;
                    LogMessage("[gokz-top-servers] Loaded server IP from config: %s", gC_ServerIP);
                    delete file;
                    StartStatusTimer();
                    return;
                }
            }
            delete file;
        }
    }

    // File doesn't exist or IP is empty, fetch from ipify.org
    FetchServerIP();
}

void FetchServerIP()
{
    if (gB_IPFetchInProgress)
    {
        return; // Already fetching
    }

    gB_IPFetchInProgress = true;

    Handle req = SteamWorks_CreateHTTPRequest(k_EHTTPMethodGET, IPIFY_URL);
    if (req == INVALID_HANDLE)
    {
        LogError("[gokz-top-servers] Failed to create HTTP request for IP fetch");
        gB_IPFetchInProgress = false;
        return;
    }

    SteamWorks_SetHTTPRequestAbsoluteTimeoutMS(req, IPIFY_TIMEOUT * 1000);
    SteamWorks_SetHTTPCallbacks(req, OnIPFetchCompleted);
    SteamWorks_SendHTTPRequest(req);
}

public void OnIPFetchCompleted(Handle hRequest, bool bFailure, bool bRequestSuccessful, EHTTPStatusCode eStatusCode, any data1, any data2)
{
    gB_IPFetchInProgress = false;

    if (bFailure || !bRequestSuccessful)
    {
        LogError("[gokz-top-servers] Failed to fetch server IP from ipify.org (network error)");
        if (hRequest != INVALID_HANDLE)
        {
            delete hRequest;
        }
        return;
    }

    int status = view_as<int>(eStatusCode);
    if (status < 200 || status >= 300)
    {
        LogError("[gokz-top-servers] Failed to fetch server IP from ipify.org (HTTP %d)", status);
        if (hRequest != INVALID_HANDLE)
        {
            delete hRequest;
        }
        return;
    }

    // Read IP from response (plain text)
    char ip[64];
    if (!GOKZTop_ReadResponseBody(hRequest, ip, sizeof(ip)))
    {
        LogError("[gokz-top-servers] Failed to read IP from ipify.org response");
        if (hRequest != INVALID_HANDLE)
        {
            delete hRequest;
        }
        return;
    }

    if (hRequest != INVALID_HANDLE)
    {
        delete hRequest;
    }

    TrimString(ip);
    if (strlen(ip) == 0)
    {
        LogError("[gokz-top-servers] Empty IP received from ipify.org");
        return;
    }

    // Save IP to config file
    SaveServerIP(ip);
}

void SaveServerIP(const char[] ip)
{
    char configPath[PLATFORM_MAX_PATH];
    BuildGameConfigPath(configPath, sizeof(configPath), "server_ip.cfg");

    // Create directory if it doesn't exist
    char dirPath[PLATFORM_MAX_PATH];
    BuildGameConfigPath(dirPath, sizeof(dirPath), ""); // Empty file = directory path
    if (!DirExists(dirPath))
    {
        CreateDirectory(dirPath, 511); // 511 = 0777 in decimal
    }

    // Write IP to file (plain text, single line)
    File file = OpenFile(configPath, "w");
    if (file != null)
    {
        file.WriteLine(ip);
        delete file;
        strcopy(gC_ServerIP, sizeof(gC_ServerIP), ip);
        gB_ServerIPReady = true;
        LogMessage("[gokz-top-servers] Fetched and saved server IP: %s", ip);
        StartStatusTimer();
    }
    else
    {
        LogError("[gokz-top-servers] Failed to write server IP to config file");
    }
}

// =====[ TIMER MANAGEMENT ]=====

void StartStatusTimer()
{
    // Kill existing timer if it exists
    if (gH_StatusTimer != null)
    {
        delete gH_StatusTimer;
        gH_StatusTimer = null;
    }

    if (!gB_ServerIPReady)
    {
        return; // Can't start timer without IP
    }

    // Get update interval from convar
    float interval = 4.0;
    if (gCV_UpdateInterval != null)
    {
        interval = gCV_UpdateInterval.FloatValue;
        if (interval < 0.1)
        {
            interval = 0.1;
        }
    }

    gH_StatusTimer = CreateTimer(
        interval,
        Timer_UpdateServerStatus,
        INVALID_HANDLE,
        TIMER_REPEAT
    );
}

public void OnUpdateIntervalChanged(ConVar convar, const char[] oldValue, const char[] newValue)
{
    // Restart the timer with the new interval if IP is ready
    if (gB_ServerIPReady)
    {
        StartStatusTimer();
    }
}

public Action Timer_UpdateServerStatus(Handle timer, any data)
{
    // Don't make a new request if one is already in flight
    if (gB_RequestInFlight)
    {
        return Plugin_Continue;
    }

    if (!gB_ServerIPReady || strlen(gC_ServerIP) == 0)
    {
        return Plugin_Continue;
    }

    // Collect and POST server status
    PostServerStatus();

    return Plugin_Continue;
}

void CheckEmptyServer()
{
    // Check if any human players are still connected
    for (int i = 1; i <= MaxClients; i++)
    {
        if (IsClientInGame(i) && !IsFakeClient(i))
        {
            return; // Still active humans, nothing to do
        }
    }

    // No human players left: post empty server status
    if (!gB_RequestInFlight && gB_ServerIPReady)
    {
        PostServerStatus();
    }
}

// =====[ SERVER STATUS COLLECTION ]=====

void PostServerStatus()
{
    if (!GOKZTop_IsConfigured())
    {
        // API key not configured, silently skip (will be logged elsewhere)
        return;
    }

    // Collect server information
    char hostname[256];
    ConVar cvHostname = FindConVar("hostname");
    if (cvHostname != null)
    {
        cvHostname.GetString(hostname, sizeof(hostname));
    }
    else
    {
        strcopy(hostname, sizeof(hostname), "Unknown");
    }

    char mapName[64];
    GetCurrentMap(mapName, sizeof(mapName));

    int playerCount = 0;
    for (int i = 1; i <= MaxClients; i++)
    {
        if (IsClientInGame(i) && !IsFakeClient(i))
        {
            playerCount++;
        }
    }

    int maxPlayers = GetMaxHumanPlayers();

    // Get port
    int port = 27015; // Default
    ConVar cvPort = FindConVar("hostport");
    if (cvPort != null)
    {
        port = cvPort.IntValue;
    }
    if (port <= 0)
    {
        port = 27015;
    }

    // Build JSON body
    char jsonBody[8192];
    if (!BuildServerStatusJson(jsonBody, sizeof(jsonBody), gC_ServerIP, port, hostname, mapName, playerCount, maxPlayers))
    {
        LogError("[gokz-top-servers] Failed to build JSON body");
        return;
    }

    // Build API URL
    char path[128];
    strcopy(path, sizeof(path), "/public-servers/status/");

    char url[1024];
    if (!GOKZTop_BuildApiUrl(url, sizeof(url), path))
    {
        LogError("[gokz-top-servers] Failed to build API URL");
        return;
    }

    // Create HTTP request
    Handle req = GOKZTop_CreateSteamWorksRequest(k_EHTTPMethodPOST, url, true, API_TIMEOUT);
    if (req == INVALID_HANDLE)
    {
        LogError("[gokz-top-servers] Failed to create HTTP request (API key missing?)");
        return;
    }

    // Set JSON body
    if (!GOKZTop_SetJsonBody(req, jsonBody))
    {
        LogError("[gokz-top-servers] Failed to set JSON body");
        delete req;
        return;
    }

    // Mark request as in flight
    gB_RequestInFlight = true;

    // Send request
    SteamWorks_SetHTTPCallbacks(req, OnServerStatusPosted);
    SteamWorks_SendHTTPRequest(req);
}

bool BuildServerStatusJson(char[] buffer, int maxlen, const char[] ip, int port, const char[] hostname, const char[] mapName, int playerCount, int maxPlayers)
{
    // Escape strings for JSON
    char ipEsc[128];
    char hostnameEsc[512];
    char mapEsc[128];
    GOKZTop_JsonEscapeString(ip, ipEsc, sizeof(ipEsc));
    GOKZTop_JsonEscapeString(hostname, hostnameEsc, sizeof(hostnameEsc));
    GOKZTop_JsonEscapeString(mapName, mapEsc, sizeof(mapEsc));

    // Start JSON object
    int len = Format(buffer, maxlen, "{\"ip\":\"%s\",\"port\":%d,\"hostname\":\"%s\",\"map_name\":\"%s\",\"player_count\":%d,\"max_player\":%d,\"players\":[", ipEsc, port, hostnameEsc, mapEsc, playerCount, maxPlayers);

    // Add player data
    bool firstPlayer = true;
    for (int client = 1; client <= MaxClients; client++)
    {
        if (!IsClientInGame(client) || IsFakeClient(client))
        {
            continue;
        }

        // Get player name
        char name[MAX_NAME_LENGTH];
        if (!GetClientName(client, name, sizeof(name)))
        {
            strcopy(name, sizeof(name), "Unknown");
        }

        // Get SteamID64
        char steamid64[32];
        if (!GetClientAuthId(client, AuthId_SteamID64, steamid64, sizeof(steamid64)))
        {
            continue; // Skip players without SteamID64
        }

        // Get timer time from GOKZ
        float timerTime = 0.0;
        if (LibraryExists("gokz-core"))
        {
            timerTime = GOKZ_GetTime(client);
        }

        // Get mode from GOKZ
        char mode[8] = "";
        if (LibraryExists("gokz-core"))
        {
            int modeIndex = GOKZ_GetCoreOption(client, Option_Mode);
            if (modeIndex >= 0 && modeIndex < MODE_COUNT)
            {
                GOKZTop_GetModeString(modeIndex, mode, sizeof(mode));
            }
        }
        if (strlen(mode) == 0)
        {
            strcopy(mode, sizeof(mode), "KZT"); // Default
        }

        // Get pause status from GOKZ
        bool isPaused = false;
        if (LibraryExists("gokz-core"))
        {
            isPaused = GOKZ_GetPaused(client);
        }

        // Get player status
        char status[32];
        if (gC_PlayerStatus[client][0] == '\0')
        {
            strcopy(status, sizeof(status), "not_started");
        }
        else
        {
            strcopy(status, sizeof(status), gC_PlayerStatus[client]);
        }

        // Get teleports from GOKZ
        int teleports = 0;
        if (LibraryExists("gokz-core"))
        {
            teleports = GOKZ_GetTeleportCount(client);
        }

        // Get score and duration
        int score = CS_GetClientContributionScore(client);
        float duration = GetClientTime(client);

        // Escape strings for JSON
        char nameEsc[MAX_NAME_LENGTH * 2 + 1];
        char statusEsc[64];
        GOKZTop_JsonEscapeString(name, nameEsc, sizeof(nameEsc));
        GOKZTop_JsonEscapeString(status, statusEsc, sizeof(statusEsc));

        // Add comma if not first player
        if (!firstPlayer)
        {
            len += Format(buffer[len], maxlen - len, ",");
        }
        firstPlayer = false;

        // Add player object
        len += Format(buffer[len], maxlen - len,
            "{\"name\":\"%s\",\"steamid64\":\"%s\",\"score\":%d,\"duration\":%.3f,\"timer_time\":%.3f,\"mode\":\"%s\",\"is_paused\":%s,\"status\":\"%s\",\"teleports\":%d}",
            nameEsc, steamid64, score, duration, timerTime, mode, isPaused ? "true" : "false", statusEsc, teleports);

        if (len >= maxlen - 100)
        {
            // Buffer getting full, truncate player list
            break;
        }
    }

    // Close JSON array and object
    Format(buffer[len], maxlen - len, "]}");

    return true;
}

public void OnServerStatusPosted(Handle hRequest, bool bFailure, bool bRequestSuccessful, EHTTPStatusCode eStatusCode, any data1, any data2)
{
    // Always clear the in-flight flag
    gB_RequestInFlight = false;

    // Static counters for throttling error logs
    static int failureCount = 0;
    static int errorCount = 0;

    // Handle timeout or failure
    if (bFailure || !bRequestSuccessful)
    {
        // Log timeout/failure (but don't spam - only log occasionally)
        failureCount++;
        if (failureCount % 10 == 1) // Log every 10th failure
        {
            LogError("[gokz-top-servers] Failed to post server status (network error or timeout)");
        }
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
                LogError("[gokz-top-servers] Failed to post server status (HTTP %d): %s", status, body);
            }
            else
            {
                LogError("[gokz-top-servers] Failed to post server status (HTTP %d)", status);
            }
        }
        if (hRequest != INVALID_HANDLE)
        {
            delete hRequest;
        }
        return;
    }

    // Success - reset failure counters
    failureCount = 0;
    errorCount = 0;

    if (hRequest != INVALID_HANDLE)
    {
        delete hRequest;
    }
}

// =====[ GOKZ TIMER EVENTS ]=====

public void GOKZ_OnTimerStart_Post(int client, int course)
{
    if (!IsClientInGame(client) || IsFakeClient(client))
    {
        return;
    }

    strcopy(gC_PlayerStatus[client], sizeof(gC_PlayerStatus[]), "in_progress");
}

public void GOKZ_OnTimerStopped(int client)
{
    if (!IsClientInGame(client) || IsFakeClient(client))
    {
        return;
    }

    // Only mark as aborted if the player previously had a run in progress
    if (StrEqual(gC_PlayerStatus[client], "in_progress", false))
    {
        strcopy(gC_PlayerStatus[client], sizeof(gC_PlayerStatus[]), "aborted");
    }
}

public void GOKZ_OnTimerEnd_Post(int client, int course, float time, int teleportsUsed)
{
    if (!IsClientInGame(client) || IsFakeClient(client))
    {
        return;
    }

    strcopy(gC_PlayerStatus[client], sizeof(gC_PlayerStatus[]), "finished");
}

