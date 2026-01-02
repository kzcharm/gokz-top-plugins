// gokz-top-core
// Shared core plugin for GOKZ Top SourceMod plugins.
//
// Responsibilities:
// - Provide ConVars:
//   - gokz_top_base_url (in cfg/sourcemod/gokz-top/gokz-top-core.cfg)
//   - gokz_top_apikey   (in cfg/sourcemod/gokz-top/apikey.cfg)
// - Ensure both config files exist (AutoExecConfig)
// - Fetch and cache leaderboard data (rank and rating) per mode
// - Provide forwards and natives for other plugins to access leaderboard data

#include <sourcemod>
#include <autoexecconfig>
#include <sdktools>
#include <sdkhooks>
#include <SteamWorks>
#include <smjansson>

#undef REQUIRE_PLUGIN
#include <gokz/core>
#define REQUIRE_PLUGIN

#include <gokz-top>

#pragma semicolon 1
#pragma newdecls required

public Plugin myinfo =
{
    name        = "GOKZTop Core",
    author      = "Cinyan10",
    description = "Core utilities/config for gokz-top plugins",
    version     = "0.2.0"
};

#define MODE_COUNT 3
#define RETRY_INTERVAL 15

static ConVar gCvarBaseUrl;
static ConVar gCvarApiKey;

// Leaderboard data per player per mode
enum struct LeaderboardData
{
    float fRating;
    int iRank;
    int iRegionalRank;
    bool bHasRegionalRank;
    char szRegionCode[8];
    bool bLoaded;
    int iLastRetryTime;
}

LeaderboardData g_LeaderboardData[MAXPLAYERS + 1][MODE_COUNT];
bool g_bUsesGokz = false;

public APLRes AskPluginLoad2(Handle myself, bool late, char[] error, int err_max)
{
    CreateNatives();
    CreateForwards();
    RegPluginLibrary("gokz-top-core");
    return APLRes_Success;
}

public void OnPluginStart()
{
    g_bUsesGokz = LibraryExists("gokz-core");

    // Set up main config file: cfg/sourcemod/gokz-top/gokz-top-core.cfg
    // Note: AutoExecConfig_SetCreateDirectory will create cfg/sourcemod/gokz-top/
    // since cfg/sourcemod/ should already exist
    AutoExecConfig_SetFile("gokz-top-core", "sourcemod/gokz-top");
    AutoExecConfig_SetCreateFile(true);
    AutoExecConfig_SetCreateDirectory(true);

    gCvarBaseUrl = AutoExecConfig_CreateConVar(
        "gokz_top_base_url",
        "https://api.gokz.top",
        "Base URL for GOKZTop API (no trailing slash recommended)",
        FCVAR_PROTECTED
    );

    // Execute and clean up the main config file
    AutoExecConfig_ExecuteFile();
    AutoExecConfig_CleanFile();

    // Set up API key config file: cfg/sourcemod/gokz-top/apikey.cfg
    AutoExecConfig_SetFile("apikey", "sourcemod/gokz-top");
    AutoExecConfig_SetCreateFile(true);
    AutoExecConfig_SetCreateDirectory(true);

    gCvarApiKey = AutoExecConfig_CreateConVar(
        "gokz_top_apikey",
        "",
        "GOKZTop API key used by server-side plugins. Set in cfg/sourcemod/gokz-top/apikey.cfg",
        FCVAR_PROTECTED
    );

    // Execute and clean up the API key config file
    AutoExecConfig_ExecuteFile();
    AutoExecConfig_CleanFile();

    // Optional: execute both configs explicitly to ensure they apply even if autoexec is disabled.
    ServerCommand("exec sourcemod/gokz-top/gokz-top-core.cfg");
    ServerCommand("exec sourcemod/gokz-top/apikey.cfg");

    // Gentle hint if missing
    CreateTimer(3.0, Timer_AnnounceIfMissing, _, TIMER_FLAG_NO_MAPCHANGE);
}

public void OnAllPluginsLoaded()
{
    g_bUsesGokz = LibraryExists("gokz-core");

    // Fetch leaderboard data for all connected players
    for (int client = 1; client <= MaxClients; client++)
    {
        if (IsClientAuthorized(client) && !IsFakeClient(client))
        {
            int mode = g_bUsesGokz ? GOKZ_GetCoreOption(client, Option_Mode) : 2;
            if (mode < 0 || mode >= MODE_COUNT)
                mode = 2;
            FetchLeaderboardData(client, mode);
        }
    }
}

public void OnLibraryAdded(const char[] name)
{
    g_bUsesGokz = g_bUsesGokz || StrEqual(name, "gokz-core");
}

public void OnLibraryRemoved(const char[] name)
{
    g_bUsesGokz = g_bUsesGokz && !StrEqual(name, "gokz-core");
}

public void OnClientPutInServer(int client)
{
    if (IsFakeClient(client))
        return;

    // Reset all mode data for this client
    for (int mode = 0; mode < MODE_COUNT; mode++)
    {
        g_LeaderboardData[client][mode].fRating = 0.0;
        g_LeaderboardData[client][mode].iRank = 0;
        g_LeaderboardData[client][mode].iRegionalRank = 0;
        g_LeaderboardData[client][mode].bHasRegionalRank = false;
        g_LeaderboardData[client][mode].szRegionCode[0] = '\0';
        g_LeaderboardData[client][mode].bLoaded = false;
        g_LeaderboardData[client][mode].iLastRetryTime = 0;
    }

    // Fetch for current mode
    int mode = g_bUsesGokz ? GOKZ_GetCoreOption(client, Option_Mode) : 2;
    if (mode < 0 || mode >= MODE_COUNT)
        mode = 2;
    FetchLeaderboardData(client, mode);
}

public void OnMapStart()
{
    // Set up retry mechanism via think hook
    int ent = GetPlayerResourceEntity();
    if (ent != -1)
    {
        SDKHook(ent, SDKHook_ThinkPost, Hook_OnThinkPost);
    }
}

public void GOKZ_OnOptionChanged(int client, const char[] option, any newValue)
{
    if (!g_bUsesGokz)
        return;

    Option coreOption;
    if (GOKZ_IsCoreOption(option, coreOption) && coreOption == Option_Mode)
    {
        int mode = newValue;
        if (mode < 0 || mode >= MODE_COUNT)
            mode = 2;

        // Fetch leaderboard data for the new mode
        FetchLeaderboardData(client, mode);
    }
}

public Action Timer_AnnounceIfMissing(Handle timer)
{
    if (gCvarApiKey != null)
    {
        char apiKey[128];
        gCvarApiKey.GetString(apiKey, sizeof(apiKey));
        TrimString(apiKey);
        if (apiKey[0] == '\0')
        {
            LogMessage("[gokz-top-core] API key not set. Edit cfg/sourcemod/gokz-top/apikey.cfg and set gokz_top_apikey.");
        }
    }
    return Plugin_Stop;
}

// ──────────────────────────────────────────────────────────────────────────────
// Leaderboard fetching
// ──────────────────────────────────────────────────────────────────────────────
static void FetchLeaderboardData(int client, int mode)
{
    if (client <= 0 || client > MaxClients || !IsClientInGame(client) || IsFakeClient(client))
        return;

    if (mode < 0 || mode >= MODE_COUNT)
        return;

    char steamid64[32];
    if (!GetClientAuthId(client, AuthId_SteamID64, steamid64, sizeof(steamid64), true))
        return;

    Handle req = GOKZTop_FetchLeaderboardData(steamid64, mode, GetClientUserId(client), 20);
    if (req == INVALID_HANDLE)
        return;

    SteamWorks_SetHTTPCallbacks(req, OnHTTPCompleted);
    SteamWorks_SendHTTPRequest(req);

    g_LeaderboardData[client][mode].iLastRetryTime = GetTime();
}

public void OnHTTPCompleted(Handle hRequest, bool bFailure, bool bRequestSuccessful, EHTTPStatusCode eStatusCode, any data1, any data2)
{
    int contextValue = data1;
    int userID = contextValue & 0xFFFF;
    int mode = (contextValue >> 16) & 0xFFFF;
    int client = GetClientOfUserId(userID);

    if (!client || client <= 0 || client > MaxClients || !IsClientInGame(client) || IsFakeClient(client))
    {
        if (hRequest != INVALID_HANDLE)
        {
            delete hRequest;
        }
        return;
    }

    if (mode < 0 || mode >= MODE_COUNT)
    {
        if (hRequest != INVALID_HANDLE)
        {
            delete hRequest;
        }
        return;
    }

    // Check if mode changed while request was in flight
    if (g_bUsesGokz && GOKZ_GetCoreOption(client, Option_Mode) != mode)
    {
        if (hRequest != INVALID_HANDLE)
        {
            delete hRequest;
        }
        return;
    }

    int status = view_as<int>(eStatusCode);

    // Handle 404 - player not in leaderboards
    if (status == 404)
    {
        g_LeaderboardData[client][mode].fRating = 0.0;
        g_LeaderboardData[client][mode].iRank = 0;
        g_LeaderboardData[client][mode].iRegionalRank = 0;
        g_LeaderboardData[client][mode].bHasRegionalRank = false;
        g_LeaderboardData[client][mode].szRegionCode[0] = '\0';
        g_LeaderboardData[client][mode].bLoaded = true;
        if (hRequest != INVALID_HANDLE)
        {
            delete hRequest;
        }
        Call_OnLeaderboardDataFetched(client, mode, 0.0, 0, 0, false, "");
        return;
    }

    if (bFailure || !bRequestSuccessful || status < 200 || status >= 300)
    {
        // Will retry on next think hook if enough time has passed
        if (hRequest != INVALID_HANDLE)
        {
            delete hRequest;
        }
        return;
    }

    char body[2048];
    if (!GOKZTop_ReadResponseBody(hRequest, body, sizeof(body)))
    {
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

    if (!GOKZTop_LooksLikeJson(body))
        return;

    Handle json = json_load(body);
    if (json == INVALID_HANDLE || !json_is_object(json))
    {
        if (json != INVALID_HANDLE)
            delete json;
        return;
    }

    // Parse response
    float rating = json_object_get_float(json, "rating");
    int rank = json_object_get_int(json, "rank");
    
    // Parse regional rank and region code if available
    int regionalRank = 0;
    bool hasRegionalRank = false;
    char regionCode[8] = "";
    Handle regionalRankObj = json_object_get(json, "regional_rank");
    if (regionalRankObj != INVALID_HANDLE)
    {
        if (!json_is_null(regionalRankObj) && json_is_number(regionalRankObj))
        {
            regionalRank = json_integer_value(regionalRankObj);
            hasRegionalRank = (regionalRank > 0);
        }
        delete regionalRankObj;
    }
    
    // Parse region code
    Handle regionCodeObj = json_object_get(json, "region_code");
    if (regionCodeObj != INVALID_HANDLE)
    {
        if (!json_is_null(regionCodeObj) && json_is_string(regionCodeObj))
        {
            json_string_value(regionCodeObj, regionCode, sizeof(regionCode));
        }
        delete regionCodeObj;
    }

    g_LeaderboardData[client][mode].fRating = rating;
    g_LeaderboardData[client][mode].iRank = rank;
    g_LeaderboardData[client][mode].iRegionalRank = regionalRank;
    g_LeaderboardData[client][mode].bHasRegionalRank = hasRegionalRank;
    strcopy(g_LeaderboardData[client][mode].szRegionCode, 8, regionCode);
    g_LeaderboardData[client][mode].bLoaded = true;

    delete json;

    // Call forward to notify other plugins
    Call_OnLeaderboardDataFetched(client, mode, rating, rank, regionalRank, hasRegionalRank, regionCode);
}

// ──────────────────────────────────────────────────────────────────────────────
// Forwards
// ──────────────────────────────────────────────────────────────────────────────
static GlobalForward H_OnLeaderboardDataFetched;

static void CreateForwards()
{
    H_OnLeaderboardDataFetched = new GlobalForward("GOKZTop_OnLeaderboardDataFetched", ET_Ignore, Param_Cell, Param_Cell, Param_Float, Param_Cell, Param_Cell, Param_Cell, Param_String);
}

static void Call_OnLeaderboardDataFetched(int client, int mode, float rating, int rank, int regionalRank, bool hasRegionalRank, const char[] regionCode)
{
    Call_StartForward(H_OnLeaderboardDataFetched);
    Call_PushCell(client);
    Call_PushCell(mode);
    Call_PushFloat(rating);
    Call_PushCell(rank);
    Call_PushCell(regionalRank);
    Call_PushCell(hasRegionalRank);
    Call_PushString(regionCode);
    Call_Finish();
}

// ──────────────────────────────────────────────────────────────────────────────
// Natives
// ──────────────────────────────────────────────────────────────────────────────
static void CreateNatives()
{
    CreateNative("GOKZTop_GetRating", Native_GetRating);
    CreateNative("GOKZTop_GetRank", Native_GetRank);
    CreateNative("GOKZTop_GetRegionalRank", Native_GetRegionalRank);
    CreateNative("GOKZTop_HasRegionalRank", Native_HasRegionalRank);
    CreateNative("GOKZTop_GetRegionCode", Native_GetRegionCode);
    CreateNative("GOKZTop_IsLeaderboardDataLoaded", Native_IsLeaderboardDataLoaded);
    CreateNative("GOKZTop_RefreshLeaderboardData", Native_RefreshLeaderboardData);
}

public int Native_GetRating(Handle plugin, int numParams)
{
    int client = GetNativeCell(1);
    int mode = GetNativeCell(2);

    if (client <= 0 || client > MaxClients || mode < 0 || mode >= MODE_COUNT)
        return view_as<int>(0.0);

    return view_as<int>(g_LeaderboardData[client][mode].fRating);
}

public int Native_GetRank(Handle plugin, int numParams)
{
    int client = GetNativeCell(1);
    int mode = GetNativeCell(2);

    if (client <= 0 || client > MaxClients || mode < 0 || mode >= MODE_COUNT)
        return 0;

    return g_LeaderboardData[client][mode].iRank;
}

public int Native_GetRegionalRank(Handle plugin, int numParams)
{
    int client = GetNativeCell(1);
    int mode = GetNativeCell(2);

    if (client <= 0 || client > MaxClients || mode < 0 || mode >= MODE_COUNT)
        return 0;

    return g_LeaderboardData[client][mode].iRegionalRank;
}

public int Native_HasRegionalRank(Handle plugin, int numParams)
{
    int client = GetNativeCell(1);
    int mode = GetNativeCell(2);

    if (client <= 0 || client > MaxClients || mode < 0 || mode >= MODE_COUNT)
        return false;

    return g_LeaderboardData[client][mode].bHasRegionalRank;
}

public int Native_GetRegionCode(Handle plugin, int numParams)
{
    int client = GetNativeCell(1);
    int mode = GetNativeCell(2);
    int maxlen = GetNativeCell(4);

    if (client <= 0 || client > MaxClients || mode < 0 || mode >= MODE_COUNT)
    {
        SetNativeString(3, "", maxlen);
        return 0;
    }

    SetNativeString(3, g_LeaderboardData[client][mode].szRegionCode, maxlen);
    return 0;
}

public int Native_IsLeaderboardDataLoaded(Handle plugin, int numParams)
{
    int client = GetNativeCell(1);
    int mode = GetNativeCell(2);

    if (client <= 0 || client > MaxClients || mode < 0 || mode >= MODE_COUNT)
        return false;

    return g_LeaderboardData[client][mode].bLoaded;
}

public int Native_RefreshLeaderboardData(Handle plugin, int numParams)
{
    int client = GetNativeCell(1);
    int mode = GetNativeCell(2);

    if (client <= 0 || client > MaxClients || mode < 0 || mode >= MODE_COUNT)
        return 0;

    // Reset loaded state to force refresh
    g_LeaderboardData[client][mode].bLoaded = false;
    FetchLeaderboardData(client, mode);
    return 1;
}

// ──────────────────────────────────────────────────────────────────────────────
// Retry mechanism
// ──────────────────────────────────────────────────────────────────────────────
void Hook_OnThinkPost(int ent)
{
    int now = GetTime();

    for (int client = 1; client <= MaxClients; client++)
    {
        if (!IsClientInGame(client) || IsFakeClient(client))
            continue;

        int mode = g_bUsesGokz ? GOKZ_GetCoreOption(client, Option_Mode) : 2;
        if (mode < 0 || mode >= MODE_COUNT)
            mode = 2;

        // Retry if data not loaded and enough time has passed
        if (!g_LeaderboardData[client][mode].bLoaded && 
            (now - g_LeaderboardData[client][mode].iLastRetryTime) >= RETRY_INTERVAL)
        {
            FetchLeaderboardData(client, mode);
        }
    }
}


