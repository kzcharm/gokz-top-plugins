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

// Menu system
int g_iMenuMode[MAXPLAYERS + 1]; // Current mode being viewed in menu
bool g_bMenuDataPending[MAXPLAYERS + 1]; // Whether menu data fetch is pending

// GOKZ Options Menu integration
TopMenu gTM_Options;
TopMenuObject gTMO_KZTop;

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

    AutoExecConfig_CreateConVar(
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

    // Register commands
    RegConsoleCmd("sm_kztop", Command_KZTop);
    RegConsoleCmd("sm_gokztop", Command_KZTop);
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

    // Set up GOKZ options menu integration
    if (g_bUsesGokz)
    {
        TopMenu topMenu = GOKZ_GetOptionsTopMenu();
        if (topMenu != null)
        {
            GOKZ_OnOptionsMenuReady(topMenu);
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

// ──────────────────────────────────────────────────────────────────────────────
// GOKZ Options Menu Integration
// ──────────────────────────────────────────────────────────────────────────────
public void GOKZ_OnOptionsMenuCreated(TopMenu topMenu)
{
    if (gTM_Options == topMenu && gTMO_KZTop != INVALID_TOPMENUOBJECT)
    {
        return;
    }

    gTMO_KZTop = topMenu.AddCategory("kztop", TopMenuHandler_KZTop);
}

public void GOKZ_OnOptionsMenuReady(TopMenu topMenu)
{
    if (gTMO_KZTop == INVALID_TOPMENUOBJECT)
    {
        GOKZ_OnOptionsMenuCreated(topMenu);
    }

    if (gTM_Options == topMenu)
    {
        return;
    }

    gTM_Options = topMenu;
    gTM_Options.AddItem("kztop_menu", TopMenuHandler_KZTopMenu, gTMO_KZTop);
}

public void TopMenuHandler_KZTop(TopMenu topmenu, TopMenuAction action, TopMenuObject topobj_id, int param, char[] buffer, int maxlength)
{
    if (action == TopMenuAction_DisplayOption)
    {
        Format(buffer, maxlength, "GOKZ.TOP");
    }

    if (action == TopMenuAction_DisplayTitle)
    {
        Format(buffer, maxlength, "GOKZ.TOP (!gokztop)");
    }
}

public void TopMenuHandler_KZTopMenu(TopMenu topmenu, TopMenuAction action, TopMenuObject topobj_id, int param, char[] buffer, int maxlength)
{
    if (action == TopMenuAction_DisplayOption)
    {
        Format(buffer, maxlength, "Open GOKZ.TOP Menu");
    }

    if (action == TopMenuAction_SelectOption)
    {
        FakeClientCommand(param, "sm_kztop");
    }
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

    // Reset menu state
    g_iMenuMode[client] = -1;
    g_bMenuDataPending[client] = false;

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

// ──────────────────────────────────────────────────────────────────────────────
// Menu Commands
// ──────────────────────────────────────────────────────────────────────────────
public Action Command_KZTop(int client, int args)
{
    if (client <= 0 || client > MaxClients || !IsClientInGame(client) || IsFakeClient(client))
        return Plugin_Handled;

    char steamid64[32];
    if (!GetClientAuthId(client, AuthId_SteamID64, steamid64, sizeof(steamid64), true))
    {
        PrintToChat(client, " \x01[\x04GOKZ.TOP\x01] Unable to get your SteamID64.");
        return Plugin_Handled;
    }

    // Always default to current player mode first
    g_iMenuMode[client] = g_bUsesGokz ? GOKZ_GetCoreOption(client, Option_Mode) : 2;
    if (g_iMenuMode[client] < 0 || g_iMenuMode[client] >= MODE_COUNT)
        g_iMenuMode[client] = 2;

    FetchMenuData(client, steamid64, g_iMenuMode[client]);
    return Plugin_Handled;
}

static void FetchMenuData(int client, const char[] steamid64, int mode)
{
    if (client <= 0 || client > MaxClients || !IsClientInGame(client) || IsFakeClient(client))
        return;

    if (mode < 0 || mode >= MODE_COUNT)
        return;

    char modeStr[8];
    if (!GOKZTop_GetModeString(mode, modeStr, sizeof(modeStr)))
        return;

    char path[128];
    Format(path, sizeof(path), "/leaderboards/%s", steamid64);

    char query[32];
    Format(query, sizeof(query), "mode=%s", modeStr);

    char url[1024];
    if (!GOKZTop_BuildApiUrl(url, sizeof(url), path, query))
    {
        PrintToChat(client, " \x01[\x04GOKZ.TOP\x01] Failed to build API URL.");
        return;
    }

    Handle req = GOKZTop_CreateSteamWorksRequest(k_EHTTPMethodGET, url, false, 15);
    if (req == INVALID_HANDLE)
    {
        PrintToChat(client, " \x01[\x04GOKZ.TOP\x01] Failed to create HTTP request.");
        return;
    }

    // Store context: lower 16 bits = userid, upper 16 bits = mode, bit 31 = menu flag
    int userid = GetClientUserId(client);
    int contextValue = userid | (mode << 16) | (1 << 31); // Bit 31 indicates menu request
    SteamWorks_SetHTTPRequestContextValue(req, contextValue, 0);
    SteamWorks_SetHTTPCallbacks(req, OnMenuHTTPCompleted);
    SteamWorks_SendHTTPRequest(req);

    g_bMenuDataPending[client] = true;
}

public void OnMenuHTTPCompleted(Handle hRequest, bool bFailure, bool bRequestSuccessful, EHTTPStatusCode eStatusCode, any data1, any data2)
{
    int contextValue = data1;
    bool isMenuRequest = (contextValue & (1 << 31)) != 0;
    
    if (!isMenuRequest)
        return; // Not a menu request, ignore

    int userID = contextValue & 0xFFFF;
    int mode = (contextValue >> 16) & 0x7FFF; // Mask out menu flag bit
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
        g_bMenuDataPending[client] = false;
        return;
    }

    int status = view_as<int>(eStatusCode);
    g_bMenuDataPending[client] = false;

    if (bFailure || !bRequestSuccessful || status < 200 || status >= 300)
    {
        if (status == 404)
        {
            PrintToChat(client, " \x01[\x04GOKZ.TOP\x01] Player not found in leaderboards.");
        }
        else
        {
            PrintToChat(client, " \x01[\x04GOKZ.TOP\x01] Failed to fetch data (HTTP %d).", status);
        }
        if (hRequest != INVALID_HANDLE)
        {
            delete hRequest;
        }
        return;
    }

    char body[4096];
    if (!GOKZTop_ReadResponseBody(hRequest, body, sizeof(body)))
    {
        if (hRequest != INVALID_HANDLE)
        {
            delete hRequest;
        }
        PrintToChat(client, " \x01[\x04GOKZ.TOP\x01] Failed to read response body.");
        return;
    }

    if (hRequest != INVALID_HANDLE)
    {
        delete hRequest;
    }

    if (!GOKZTop_LooksLikeJson(body))
    {
        PrintToChat(client, " \x01[\x04GOKZ.TOP\x01] Invalid response format.");
        return;
    }

    Handle json = json_load(body);
    if (json == INVALID_HANDLE || !json_is_object(json))
    {
        if (json != INVALID_HANDLE)
            delete json;
        PrintToChat(client, " \x01[\x04GOKZ.TOP\x01] Failed to parse JSON response.");
        return;
    }

    // Parse all the data we need
    float rating = json_object_get_float(json, "rating");
    float ratingEasy = json_object_get_float(json, "maps_easy_rating");
    float ratingHard = json_object_get_float(json, "maps_hard_rating");
    int rank = json_object_get_int(json, "rank");
    int regionalRank = json_object_get_int(json, "regional_rank");
    int totalPointsV2 = json_object_get_int(json, "total_points_v2");
    
    char regionCode[8] = "";
    Handle regionCodeObj = json_object_get(json, "region_code");
    if (regionCodeObj != INVALID_HANDLE)
    {
        if (!json_is_null(regionCodeObj) && json_is_string(regionCodeObj))
        {
            json_string_value(regionCodeObj, regionCode, sizeof(regionCode));
        }
        delete regionCodeObj;
    }

    delete json;

    // Show the menu
    ShowKZTopMenu(client, mode, rating, ratingEasy, ratingHard, rank, regionalRank, regionCode, totalPointsV2);
}

static void ShowKZTopMenu(int client, int mode, float rating, float ratingEasy, float ratingHard, int rank, int regionalRank, const char[] regionCode, int totalPointsV2)
{
    Menu menu = new Menu(MenuHandler_KZTop);
    
    char modeStr[8];
    GOKZTop_GetModeString(mode, modeStr, sizeof(modeStr));
    
    // Format rating values
    char ratingStr[32], ratingEasyStr[32], ratingHardStr[32];
    Format(ratingStr, sizeof(ratingStr), "%.3f", rating);
    Format(ratingEasyStr, sizeof(ratingEasyStr), "%.3f", ratingEasy);
    Format(ratingHardStr, sizeof(ratingHardStr), "%.3f", ratingHard);

    // Build title with rating, global rank, and regional rank on separate lines
    char title[256];
    Format(title, sizeof(title), "GOKZ.TOP - %s Mode\nRating: %s\nGlobal Rank: #%d", 
           modeStr, ratingStr, rank > 0 ? rank : 0);
    
    // Add regional rank to title if available
    if (regionalRank > 0 && strlen(regionCode) > 0)
    {
        char titleWithRegion[256];
        Format(titleWithRegion, sizeof(titleWithRegion), "%s\n%s Rank: #%d", 
               title, regionCode, regionalRank);
        menu.SetTitle(titleWithRegion);
    }
    else
    {
        menu.SetTitle(title);
    }

    // Format points with commas
    char pointsStr[32];
    FormatNumberWithCommas(totalPointsV2, pointsStr, sizeof(pointsStr));

    // Add menu items
    char display[128];
    
    // Show Rating.E and Rating.H directly
    Format(display, sizeof(display), "Rating.E: %s", ratingEasyStr);
    menu.AddItem("", display, ITEMDRAW_DISABLED);
    
    Format(display, sizeof(display), "Rating.H: %s", ratingHardStr);
    menu.AddItem("", display, ITEMDRAW_DISABLED);
    
    Format(display, sizeof(display), "V2 Points: %s", pointsStr);
    menu.AddItem("", display, ITEMDRAW_DISABLED);
    
    // Add separator
    menu.AddItem("", "", ITEMDRAW_SPACER);
    
    // Add mode switcher (now on first page)
    char nextModeStr[8];
    int nextMode = (mode + 1) % MODE_COUNT;
    GOKZTop_GetModeString(nextMode, nextModeStr, sizeof(nextModeStr));
    Format(display, sizeof(display), "Switch to %s Mode", nextModeStr);
    menu.AddItem("switch_mode", display);

    menu.Display(client, MENU_TIME_FOREVER);
}

public int MenuHandler_KZTop(Menu menu, MenuAction action, int param1, int param2)
{
    if (action == MenuAction_End)
    {
        delete menu;
        return 0;
    }

    if (action == MenuAction_Select)
    {
        char info[32];
        menu.GetItem(param2, info, sizeof(info));

        if (StrEqual(info, "switch_mode"))
        {
            // Cycle to next mode
            g_iMenuMode[param1] = (g_iMenuMode[param1] + 1) % MODE_COUNT;
            
            char steamid64[32];
            if (GetClientAuthId(param1, AuthId_SteamID64, steamid64, sizeof(steamid64), true))
            {
                FetchMenuData(param1, steamid64, g_iMenuMode[param1]);
            }
        }
    }

    return 0;
}

static void FormatNumberWithCommas(int value, char[] buffer, int maxlen)
{
    char temp[32];
    IntToString(value, temp, sizeof(temp));
    
    int len = strlen(temp);
    int pos = 0;
    int digitCount = 0;
    
    // Build reversed string with commas
    for (int i = len - 1; i >= 0; i--)
    {
        // Insert comma every 3 digits (but not before the first digit)
        if (digitCount > 0 && digitCount % 3 == 0)
        {
            if (pos < maxlen - 1)
            {
                buffer[pos++] = ',';
            }
        }
        if (pos < maxlen - 1)
        {
            buffer[pos++] = temp[i];
            digitCount++;
        }
        else
        {
            break;
        }
    }
    
    buffer[pos] = '\0';
    
    // Reverse the string
    int start = 0;
    int end = pos - 1;
    while (start < end)
    {
        char swap = buffer[start];
        buffer[start] = buffer[end];
        buffer[end] = swap;
        start++;
        end--;
    }
}


