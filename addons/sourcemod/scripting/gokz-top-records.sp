// gokz-top-records
// Submit GOKZ records to gokz.top API with global-style validation checks.

#include <sourcemod>
#include <sdktools>
#include <SteamWorks>
#include <smjansson>
#include <autoexecconfig>

#include <gokz>
#include <gokz/core>

#include <gokz-top>

#pragma semicolon 1
#pragma newdecls required

// gokz-top.inc defines MODE_COUNT=3; use MODE_COUNT from gokz/core.inc instead.
#undef MODE_COUNT

// Optional gokz-global natives for globalcheck gating.
native bool GOKZ_GL_GetAPIKeyValid();
native bool GOKZ_GL_GetPluginsValid();
native bool GOKZ_GL_GetSettingsEnforcerValid();
native bool GOKZ_GL_GetMapValid();
native bool GOKZ_GL_GetPlayerValid(int client);

public Plugin myinfo =
{
    name        = "GOKZTop Records",
    author      = "Cinyan10",
    description = "Submit records to gokz.top (GlobalAPI-compatible payload)",
    version     = "1.0.0"
};

#define API_TIMEOUT 12
#define INTEGRITY_INTERVAL 1.0
#define TICKRATE_EPSILON 0.01

// Global-style enforced CVars
enum
{
    EnforcedCVar_Cheats = 0,
    EnforcedCVar_ClampUnsafeVelocities,
    EnforcedCVar_DropKnifeEnable,
    EnforcedCVar_AutoBunnyhopping,
    EnforcedCVar_MinUpdateRate,
    EnforcedCVar_MaxUpdateRate,
    EnforcedCVar_MinCmdRate,
    EnforcedCVar_MaxCmdRate,
    EnforcedCVar_ClientCmdrateDifference,
    EnforcedCVar_Turbophysics,
    ENFORCEDCVAR_COUNT
};

enum
{
    BannedPluginCommand_Funcommands = 0,
    BannedPluginCommand_Playercommands,
    BANNEDPLUGINCOMMAND_COUNT
};

enum
{
    BannedPlugin_Funcommands = 0,
    BannedPlugin_Playercommands,
    BANNEDPLUGIN_COUNT
};

static const char gC_EnforcedCVars[ENFORCEDCVAR_COUNT][] =
{
    "sv_cheats",
    "sv_clamp_unsafe_velocities",
    "mp_drop_knife_enable",
    "sv_autobunnyhopping",
    "sv_minupdaterate",
    "sv_maxupdaterate",
    "sv_mincmdrate",
    "sv_maxcmdrate",
    "sv_client_cmdrate_difference",
    "sv_turbophysics"
};

static const char gC_BannedPluginCommands[BANNEDPLUGINCOMMAND_COUNT][] =
{
    "sm_beacon",
    "sm_slap"
};

static const char gC_BannedPlugins[BANNEDPLUGIN_COUNT][] =
{
    "Fun Commands",
    "Player Commands"
};

static const float gF_EnforcedCVarValues[ENFORCEDCVAR_COUNT] =
{
    0.0,
    0.0,
    0.0,
    0.0,
    128.0,
    128.0,
    128.0,
    128.0,
    0.0,
    0.0
};


// Request types
enum
{
    Req_MapInfo = 1,
    Req_ModesList,
    Req_BanCheck,
    Req_SubmitRecord
};

bool gB_APIKeyCheck = false;
bool gB_ModeCheck[MODE_COUNT];
bool gB_BannedCommandsCheck = false;
bool gB_InValidRun[MAXPLAYERS + 1];
bool gB_GloballyVerified[MAXPLAYERS + 1];
bool gB_EnforcerOnFreshMap = false;
bool gB_JustLateLoaded = false;
bool gB_WaitingForFPSKick[MAXPLAYERS + 1];
bool gB_MapValidated = false;
bool gB_RecordRequestInFlight[MAXPLAYERS + 1];

char gC_CurrentMap[64];
int gI_CurrentMapFileSize = -1;
int gI_MapID = -1;
int gI_MapFileSize = -1;

ConVar gCV_gokz_settings_enforcer;
ConVar gCV_gokz_warn_for_non_global_map;
ConVar gCV_EnforcedCVar[ENFORCEDCVAR_COUNT];

Handle gH_IntegrityTimer = null;

// =====[ PLUGIN LIFECYCLE ]=====

public APLRes AskPluginLoad2(Handle myself, bool late, char[] error, int err_max)
{
    gB_JustLateLoaded = late;
    MarkNativeAsOptional("GOKZ_GL_GetAPIKeyValid");
    MarkNativeAsOptional("GOKZ_GL_GetPluginsValid");
    MarkNativeAsOptional("GOKZ_GL_GetSettingsEnforcerValid");
    MarkNativeAsOptional("GOKZ_GL_GetMapValid");
    MarkNativeAsOptional("GOKZ_GL_GetPlayerValid");
    return APLRes_Success;
}

public void OnPluginStart()
{
    // Same global-style environment checks
    if (FloatAbs(1.0 / GetTickInterval() - 128.0) > TICKRATE_EPSILON)
    {
        SetFailState("gokz-top-records currently only supports 128 tickrate servers.");
    }
    if (FindCommandLineParam("-insecure") || FindCommandLineParam("-tools"))
    {
        SetFailState("gokz-top-records currently only supports VAC-secured servers.");
    }

    CreateConVars();
    RegisterCommands();

    for (int i = 0; i < MODE_COUNT; i++)
    {
        gB_ModeCheck[i] = false;
    }

    for (int client = 1; client <= MaxClients; client++)
    {
        gB_InValidRun[client] = false;
        gB_GloballyVerified[client] = false;
        gB_WaitingForFPSKick[client] = false;
        gB_RecordRequestInFlight[client] = false;
    }
}

public void OnAllPluginsLoaded()
{
    for (int client = 1; client <= MaxClients; client++)
    {
        if (IsClientInGame(client))
        {
            OnClientPutInServer(client);
        }
    }
}

public void OnMapStart()
{
    GetCurrentMapDisplayName(gC_CurrentMap, sizeof(gC_CurrentMap));
    gI_CurrentMapFileSize = GetCurrentMapFileSize();

    gB_BannedCommandsCheck = true;

    if (gB_JustLateLoaded)
    {
        gB_JustLateLoaded = false;
    }
    else
    {
        gB_EnforcerOnFreshMap = true;
    }

    SetupAPI();

    if (gH_IntegrityTimer != null && !IsValidHandle(gH_IntegrityTimer))
    {
        gH_IntegrityTimer = null;
    }

    if (gH_IntegrityTimer == null)
    {
        gH_IntegrityTimer = CreateTimer(INTEGRITY_INTERVAL, IntegrityChecks, _, TIMER_FLAG_NO_MAPCHANGE | TIMER_REPEAT);
    }
}

public void OnMapEnd()
{
    gB_MapValidated = false;
    gI_MapID = -1;
    gI_MapFileSize = -1;
}

public void OnPluginEnd()
{
    if (gH_IntegrityTimer != null)
    {
        if (IsValidHandle(gH_IntegrityTimer))
        {
            delete gH_IntegrityTimer;
        }
        gH_IntegrityTimer = null;
    }
}

// =====[ CLIENT EVENTS ]=====

public void OnClientPutInServer(int client)
{
    gB_GloballyVerified[client] = false;
    gB_WaitingForFPSKick[client] = false;
}

public void OnClientPostAdminCheck(int client)
{
    if (!IsFakeClient(client))
    {
        CheckClientGlobalBan(client);
    }
}

public void OnClientDisconnect(int client)
{
    gB_InValidRun[client] = false;
    gB_GloballyVerified[client] = false;
    gB_RecordRequestInFlight[client] = false;
    gB_WaitingForFPSKick[client] = false;
}

// =====[ COMMANDS ]=====

static void RegisterCommands()
{
    RegConsoleCmd("sm_globalcheck", CommandGlobalCheck, "[KZ] Show whether global records are currently enabled.");
    RegConsoleCmd("sm_gc", CommandGlobalCheck, "[KZ] Show whether global records are currently enabled.");
    RegConsoleCmd("sm_topcheck", CommandGlobalCheck, "[KZ] Show whether global records are currently enabled.");
    RegConsoleCmd("sm_tc", CommandGlobalCheck, "[KZ] Show whether global records are currently enabled.");
}

public Action CommandGlobalCheck(int client, int args)
{
    PrintGlobalCheckToChat(client);
    return Plugin_Handled;
}

static void PrintGlobalCheckToChat(int client)
{
    if (client <= 0 || !IsClientInGame(client))
    {
        return;
    }

    GOKZ_PrintToChat(client, false, "{gold}GOKZ.TOP {grey}| {lightgreen}Records Availability Check");
    GOKZ_PrintToChat(client, false, "{grey}API key: %s  {grey}| Plugins: %s  {grey}| Enforcer: %s  {grey}| Map: %s  {grey}| Player: %s",
        gB_APIKeyCheck ? "{green}✓" : "{darkred}X",
        gB_BannedCommandsCheck ? "{green}✓" : "{darkred}X",
        (gCV_gokz_settings_enforcer.BoolValue && gB_EnforcerOnFreshMap) ? "{green}✓" : "{darkred}X",
        MapCheck() ? "{green}✓" : "{darkred}X",
        gB_GloballyVerified[client] ? "{green}✓" : "{darkred}X");

    char modeCheck[256];
    int modeCount = sizeof(gC_ModeNamesShort);
    bool modeOk = gB_ModeCheck[0] && TopRecordsAllowedByGlobalCheck(client, 0);
    FormatEx(modeCheck, sizeof(modeCheck), "{purple}%s %s", gC_ModeNamesShort[0], modeOk ? "{green}✓" : "{darkred}X");
    for (int i = 1; i < modeCount; i++)
    {
        modeOk = gB_ModeCheck[i] && TopRecordsAllowedByGlobalCheck(client, i);
        FormatEx(modeCheck, sizeof(modeCheck), "%s {grey}| {purple}%s %s", modeCheck, gC_ModeNamesShort[i], modeOk ? "{green}✓" : "{darkred}X");
    }
    GOKZ_PrintToChat(client, false, "%s", modeCheck);
}

// =====[ GOKZ EVENTS ]=====

public Action GOKZ_OnTimerStart(int client, int course)
{
    int mode = GOKZ_GetCoreOption(client, Option_Mode);

    if (gCV_gokz_warn_for_non_global_map.BoolValue
        && gB_APIKeyCheck
        && TopRecordsAllowedByGlobalCheck(client, mode)
        && !GlobalsEnabled(mode)
        && !GOKZ_GetTimerRunning(client))
    {
        GOKZ_PrintToChat(client, true, "{red}Global records not enabled for this run.");
    }

    return Plugin_Continue;
}

public void GOKZ_OnTimerStart_Post(int client, int course)
{
    int mode = GOKZ_GetCoreOption(client, Option_Mode);
    gB_InValidRun[client] = GlobalsEnabled(mode) && TopRecordsAllowedByGlobalCheck(client, mode);
}

public void GOKZ_OnTimerEnd_Post(int client, int course, float time, int teleportsUsed)
{
    int mode = GOKZ_GetCoreOption(client, Option_Mode);
    if (gB_GloballyVerified[client] && gB_InValidRun[client] && TopRecordsAllowedByGlobalCheck(client, mode))
    {
        SubmitRecord(client, course, time, teleportsUsed);
    }
}

public void GOKZ_OnRunInvalidated(int client)
{
    gB_InValidRun[client] = false;
}

// =====[ GLOBAL CHECKS ]=====

bool GlobalsEnabled(int mode)
{
    if (mode < 0 || mode >= MODE_COUNT)
    {
        return false;
    }

    return gB_APIKeyCheck
        && gB_BannedCommandsCheck
        && gCV_gokz_settings_enforcer.BoolValue
        && gB_EnforcerOnFreshMap
        && MapCheck()
        && gB_ModeCheck[mode];
}

bool MapCheck()
{
    return gB_MapValidated
        && gI_MapID > 0
        && gI_MapFileSize == gI_CurrentMapFileSize;
}

static bool GlobalCheckNativesAvailable()
{
    return GetFeatureStatus(FeatureType_Native, "GOKZ_GL_GetAPIKeyValid") == FeatureStatus_Available
        && GetFeatureStatus(FeatureType_Native, "GOKZ_GL_GetPluginsValid") == FeatureStatus_Available
        && GetFeatureStatus(FeatureType_Native, "GOKZ_GL_GetSettingsEnforcerValid") == FeatureStatus_Available
        && GetFeatureStatus(FeatureType_Native, "GOKZ_GL_GetMapValid") == FeatureStatus_Available
        && GetFeatureStatus(FeatureType_Native, "GOKZ_GL_GetPlayerValid") == FeatureStatus_Available;
}

static bool GlobalCheckPassesForClient(int client)
{
    if (client <= 0 || !GlobalCheckNativesAvailable())
    {
        return false;
    }

    return GOKZ_GL_GetAPIKeyValid()
        && GOKZ_GL_GetPluginsValid()
        && GOKZ_GL_GetSettingsEnforcerValid()
        && GOKZ_GL_GetMapValid()
        && GOKZ_GL_GetPlayerValid(client);
}

static bool TopRecordsAllowedByGlobalCheck(int client, int mode)
{
    if (mode == Mode_NoPerfKZ)
    {
        return true;
    }

    return !GlobalCheckPassesForClient(client);
}

// =====[ INTEGRITY CHECKS ]=====

public Action IntegrityChecks(Handle timer)
{
    for (int client = 1; client <= MaxClients; client++)
    {
        if (IsValidClient(client) && !IsFakeClient(client))
        {
            QueryClientConVar(client, "fps_max", FPSCheck, client);
            QueryClientConVar(client, "m_yaw", MYAWCheck, client);
        }
    }

    for (int i = 0; i < BANNEDPLUGINCOMMAND_COUNT; i++)
    {
        if (CommandExists(gC_BannedPluginCommands[i]))
        {
            Handle bannedIterator = GetPluginIterator();
            char pluginName[128];
            bool foundPlugin = false;
            while (MorePlugins(bannedIterator))
            {
                Handle bannedPlugin = ReadPlugin(bannedIterator);
                GetPluginInfo(bannedPlugin, PlInfo_Name, pluginName, sizeof(pluginName));
                if (StrEqual(pluginName, gC_BannedPlugins[i]))
                {
                    char pluginPath[128];
                    GetPluginFilename(bannedPlugin, pluginPath, sizeof(pluginPath));
                    ServerCommand("sm plugins unload %s", pluginPath);
                    char disabledPath[256], enabledPath[256], pluginFile[4][128];
                    int subfolders = ExplodeString(pluginPath, "/", pluginFile, sizeof(pluginFile), sizeof(pluginFile[]));
                    BuildPath(Path_SM, disabledPath, sizeof(disabledPath), "plugins/disabled/%s", pluginFile[subfolders - 1]);
                    BuildPath(Path_SM, enabledPath, sizeof(enabledPath), "plugins/%s", pluginPath);
                    RenameFile(disabledPath, enabledPath);
                    LogError("[gokz-top-records] %s cannot be loaded at the same time. %s has been disabled.", pluginName, pluginName);
                    delete bannedPlugin;
                    foundPlugin = true;
                    break;
                }
                delete bannedPlugin;
            }
            if (!foundPlugin && gB_BannedCommandsCheck)
            {
                gB_BannedCommandsCheck = false;
                LogError("[gokz-top-records] You can't have a plugin which implements the %s command. Please disable it and reload the map.", gC_BannedPluginCommands[i]);
            }
            delete bannedIterator;
        }
    }

    return Plugin_Handled;
}

public void FPSCheck(QueryCookie cookie, int client, ConVarQueryResult result, const char[] cvarName, const char[] cvarValue, any value)
{
    if (IsValidClient(client) && !IsFakeClient(client))
    {
        int fpsMax = StringToInt(cvarValue);
        if (fpsMax > 0 && fpsMax < 120)
        {
            if (!gB_WaitingForFPSKick[client])
            {
                gB_WaitingForFPSKick[client] = true;
                CreateTimer(10.0, FPSKickPlayer, GetClientUserId(client), TIMER_FLAG_NO_MAPCHANGE);
                GOKZ_PrintToChat(client, true, "{red}Your fps_max must be >= 120 for global records.");
                if (GOKZ_GetTimerRunning(client))
                {
                    GOKZ_StopTimer(client, true);
                }
            }
        }
        else
        {
            gB_WaitingForFPSKick[client] = false;
        }
    }
}

public void MYAWCheck(QueryCookie cookie, int client, ConVarQueryResult result, const char[] cvarName, const char[] cvarValue, any value)
{
    if (IsValidClient(client) && !IsFakeClient(client) && StringToFloat(cvarValue) > 0.3)
    {
        KickClient(client, "m_yaw too high for global records.");
    }
}

public Action FPSKickPlayer(Handle timer, int userid)
{
    int client = GetClientOfUserId(userid);
    if (IsValidClient(client) && !IsFakeClient(client) && gB_WaitingForFPSKick[client])
    {
        KickClient(client, "fps_max too low for global records.");
    }
    return Plugin_Handled;
}

// =====[ CONVARS ]=====

static void CreateConVars()
{
    AutoExecConfig_SetFile("gokz-top-records", "sourcemod/gokz-top");
    AutoExecConfig_SetCreateFile(true);
    AutoExecConfig_SetCreateDirectory(true);

    gCV_gokz_settings_enforcer = AutoExecConfig_CreateConVar("gokz_settings_enforcer", "1", "Whether GOKZ enforces convars required for global records.", _, true, 0.0, true, 1.0);
    gCV_gokz_warn_for_non_global_map = AutoExecConfig_CreateConVar("gokz_warn_for_non_global_map", "1", "Warn players if the global check does not pass.", _, true, 0.0, true, 1.0);
    gCV_gokz_settings_enforcer.AddChangeHook(OnConVarChanged);

    AutoExecConfig_ExecuteFile();
    AutoExecConfig_CleanFile();

    for (int i = 0; i < ENFORCEDCVAR_COUNT; i++)
    {
        gCV_EnforcedCVar[i] = FindConVar(gC_EnforcedCVars[i]);
        if (gCV_EnforcedCVar[i] != null)
        {
            gCV_EnforcedCVar[i].FloatValue = gF_EnforcedCVarValues[i];
            gCV_EnforcedCVar[i].AddChangeHook(OnEnforcedConVarChanged);
        }
    }
}

public void OnConVarChanged(ConVar convar, const char[] oldValue, const char[] newValue)
{
    if (convar == gCV_gokz_settings_enforcer)
    {
        if (gCV_gokz_settings_enforcer.BoolValue)
        {
            for (int i = 0; i < ENFORCEDCVAR_COUNT; i++)
            {
                if (gCV_EnforcedCVar[i] != null)
                {
                    gCV_EnforcedCVar[i].FloatValue = gF_EnforcedCVarValues[i];
                }
            }
        }
        else
        {
            for (int client = 1; client <= MaxClients; client++)
            {
                gB_InValidRun[client] = false;
            }
            gB_EnforcerOnFreshMap = false;
        }
    }
}

public void OnEnforcedConVarChanged(ConVar convar, const char[] oldValue, const char[] newValue)
{
    if (gCV_gokz_settings_enforcer.BoolValue)
    {
        for (int i = 0; i < ENFORCEDCVAR_COUNT; i++)
        {
            if (convar == gCV_EnforcedCVar[i])
            {
                gCV_EnforcedCVar[i].FloatValue = gF_EnforcedCVarValues[i];
                return;
            }
        }
    }
}

// =====[ API SETUP ]=====

static void SetupAPI()
{
    gB_APIKeyCheck = GOKZTop_IsConfigured();
    if (!gB_APIKeyCheck)
    {
        LogMessage("[gokz-top-records] API key missing. Set gokz_top_apikey in cfg/sourcemod/gokz-top/apikey.cfg");
    }

    FetchMapInfo();
    FetchModesList();

    for (int client = 1; client <= MaxClients; client++)
    {
        if (IsValidClient(client) && !IsFakeClient(client))
        {
            CheckClientGlobalBan(client);
        }
    }
}

static void FetchMapInfo()
{
    char mapEnc[128];
    GOKZTop_UrlEncode(gC_CurrentMap, mapEnc, sizeof(mapEnc));

    char path[256];
    Format(path, sizeof(path), "/maps/name/%s", mapEnc);

    char url[1024];
    if (!GOKZTop_BuildApiUrl(url, sizeof(url), path, "include_wr_cache=false"))
    {
        LogError("[gokz-top-records] Failed to build map info URL");
        return;
    }

    Handle req = GOKZTop_CreateSteamWorksRequest(k_EHTTPMethodGET, url, false, API_TIMEOUT);
    if (req == INVALID_HANDLE)
    {
        LogError("[gokz-top-records] Failed to create map info request");
        return;
    }

    SteamWorks_SetHTTPRequestContextValue(req, 0, Req_MapInfo);
    SteamWorks_SetHTTPCallbacks(req, OnHTTPCompleted);
    SteamWorks_SendHTTPRequest(req);
}

static int FindModeIndexByShort(const char[] shortName)
{
    for (int i = 0; i < MODE_COUNT; i++)
    {
        if (StrEqual(shortName, gC_ModeNamesShort[i], false))
        {
            return i;
        }
    }
    return -1;
}

static int FindModeIndexByName(const char[] name)
{
    for (int i = 0; i < MODE_COUNT; i++)
    {
        if (StrEqual(name, gC_ModeNames[i], false))
        {
            return i;
        }
    }
    return -1;
}

static void FetchModesList()
{
    char url[1024];
    if (!GOKZTop_BuildApiUrl(url, sizeof(url), "/modes", "offset=0&limit=100"))
    {
        LogError("[gokz-top-records] Failed to build modes list URL");
        return;
    }

    Handle req = GOKZTop_CreateSteamWorksRequest(k_EHTTPMethodGET, url, false, API_TIMEOUT);
    if (req == INVALID_HANDLE)
    {
        LogError("[gokz-top-records] Failed to create modes list request");
        return;
    }

    SteamWorks_SetHTTPRequestContextValue(req, 0, Req_ModesList);
    SteamWorks_SetHTTPCallbacks(req, OnHTTPCompleted);
    SteamWorks_SendHTTPRequest(req);
}

static void CheckClientGlobalBan(int client)
{
    char steamid64[32];
    if (!GetClientAuthId(client, AuthId_SteamID64, steamid64, sizeof(steamid64), true))
    {
        return;
    }

    char query[128];
    Format(query, sizeof(query), "steamid64=%s&is_expired=false&limit=1", steamid64);

    char url[1024];
    if (!GOKZTop_BuildApiUrl(url, sizeof(url), "/bans", query))
    {
        LogError("[gokz-top-records] Failed to build bans URL");
        return;
    }

    Handle req = GOKZTop_CreateSteamWorksRequest(k_EHTTPMethodGET, url, false, API_TIMEOUT);
    if (req == INVALID_HANDLE)
    {
        LogError("[gokz-top-records] Failed to create bans request");
        return;
    }

    SteamWorks_SetHTTPRequestContextValue(req, GetClientUserId(client), Req_BanCheck);
    SteamWorks_SetHTTPCallbacks(req, OnHTTPCompleted);
    SteamWorks_SendHTTPRequest(req);
}

// =====[ RECORD SUBMISSION ]=====

static void SubmitRecord(int client, int course, float time, int teleportsUsed)
{
    if (gB_RecordRequestInFlight[client])
    {
        return;
    }

    if (!gB_APIKeyCheck || !GOKZTop_IsConfigured())
    {
        return;
    }

    if (gI_MapID <= 0)
    {
        LogError("[gokz-top-records] Map ID not available; skipping record submit.");
        return;
    }

    char steamid64[32];
    if (!GetClientAuthId(client, AuthId_SteamID64, steamid64, sizeof(steamid64), true))
    {
        return;
    }

    int mode = GOKZ_GetCoreOption(client, Option_Mode);
    if (mode < 0 || mode >= MODE_COUNT)
    {
        return;
    }

    char jsonBody[512];
    if (!BuildRecordJson(jsonBody, sizeof(jsonBody), steamid64, gI_MapID, gC_ModeNamesShort[mode], course, 128, teleportsUsed, time))
    {
        LogError("[gokz-top-records] Failed to build record JSON");
        return;
    }

    char url[1024];
    if (!GOKZTop_BuildApiUrl(url, sizeof(url), "/records"))
    {
        LogError("[gokz-top-records] Failed to build record URL");
        return;
    }

    Handle req = GOKZTop_CreateSteamWorksRequest(k_EHTTPMethodPOST, url, true, API_TIMEOUT);
    if (req == INVALID_HANDLE)
    {
        LogError("[gokz-top-records] Failed to create record request (API key missing?)");
        return;
    }

    if (!GOKZTop_SetJsonBody(req, jsonBody))
    {
        LogError("[gokz-top-records] Failed to set record JSON body");
        delete req;
        return;
    }

    gB_RecordRequestInFlight[client] = true;

    SteamWorks_SetHTTPRequestContextValue(req, GetClientUserId(client), Req_SubmitRecord);
    SteamWorks_SetHTTPCallbacks(req, OnHTTPCompleted);
    SteamWorks_SendHTTPRequest(req);
}

static bool BuildRecordJson(char[] buffer, int maxlen, const char[] steamid64, int mapId, const char[] mode, int stage, int tickrate, int teleports, float time)
{
    char steamEsc[64];
    char modeEsc[32];
    GOKZTop_JsonEscapeString(steamid64, steamEsc, sizeof(steamEsc));
    GOKZTop_JsonEscapeString(mode, modeEsc, sizeof(modeEsc));

    int len = Format(buffer, maxlen,
        "{\"steam_id\":\"%s\",\"map_id\":%d,\"mode\":\"%s\",\"stage\":%d,\"tickrate\":%d,\"teleports\":%d,\"time\":%.6f}",
        steamEsc, mapId, modeEsc, stage, tickrate, teleports, time);

    return len > 0 && len < maxlen;
}

// =====[ HTTP CALLBACK ]=====

public void OnHTTPCompleted(Handle hRequest, bool bFailure, bool bRequestSuccessful, EHTTPStatusCode eStatusCode, any data1, any data2)
{
    int reqType = data2 & 0xFF;
    int userid = data1;
    int client = userid ? GetClientOfUserId(userid) : 0;
    int status = view_as<int>(eStatusCode);

    char body[2048];
    GOKZTop_ReadResponseBody(hRequest, body, sizeof(body));

    if (hRequest != INVALID_HANDLE)
    {
        delete hRequest;
    }

    if (bFailure || !bRequestSuccessful || status < 200 || status >= 300)
    {
        if (reqType == Req_SubmitRecord && client > 0)
        {
            gB_RecordRequestInFlight[client] = false;
            if (status == 401 || status == 403)
            {
                gB_APIKeyCheck = false;
                LogError("[gokz-top-records] API key invalid (HTTP %d).", status);
            }
        }
        else if (reqType == Req_BanCheck && client > 0)
        {
            gB_GloballyVerified[client] = false;
        }
        else if (reqType == Req_ModesList)
        {
            for (int i = 0; i < MODE_COUNT; i++)
            {
                gB_ModeCheck[i] = false;
            }
        }
        else if (reqType == Req_MapInfo)
        {
            gB_MapValidated = false;
            gI_MapID = -1;
            gI_MapFileSize = -1;
        }

        LogError("[gokz-top-records] HTTP %d for request type %d. Body: %.128s", status, reqType, body);
        return;
    }

    if (reqType == Req_SubmitRecord && client > 0)
    {
        gB_RecordRequestInFlight[client] = false;
        return;
    }

    if (!GOKZTop_LooksLikeJson(body))
    {
        LogError("[gokz-top-records] Expected JSON, got: %.64s", body);
        return;
    }

    Handle json = json_load(body);
    if (json == INVALID_HANDLE || (!json_is_object(json) && !json_is_array(json)))
    {
        if (json != INVALID_HANDLE) delete json;
        LogError("[gokz-top-records] Failed to parse JSON response.");
        return;
    }

    switch (reqType)
    {
        case Req_MapInfo:
        {
            gB_MapValidated = json_object_get_bool(json, "validated");
            gI_MapID = json_object_get_int(json, "id");
            gI_MapFileSize = json_object_get_int(json, "filesize");
        }
        case Req_ModesList:
        {
            if (!json_is_array(json))
            {
                LogError("[gokz-top-records] Modes list response is not an array.");
            }
            else
            {
                for (int i = 0; i < MODE_COUNT; i++)
                {
                    gB_ModeCheck[i] = false;
                }

                int count = json_array_size(json);
                for (int i = 0; i < count; i++)
                {
                    Handle modeObj = json_array_get(json, i);
                    if (modeObj == INVALID_HANDLE || !json_is_object(modeObj))
                    {
                        if (modeObj != INVALID_HANDLE) delete modeObj;
                        continue;
                    }

                    char shortName[32] = "";
                    char fullName[64] = "";
                    json_object_get_string(modeObj, "name_short", shortName, sizeof(shortName));
                    json_object_get_string(modeObj, "name", fullName, sizeof(fullName));

                    int modeIndex = -1;
                    if (shortName[0] != '\0')
                    {
                        modeIndex = FindModeIndexByShort(shortName);
                    }
                    if (modeIndex == -1 && fullName[0] != '\0')
                    {
                        modeIndex = FindModeIndexByName(fullName);
                    }

                    if (modeIndex != -1)
                    {
                        int latestVersion = json_object_get_int(modeObj, "latest_version");
                        int localVersion = GOKZ_GetModeVersion(modeIndex);
                        if (latestVersion <= localVersion)
                        {
                            gB_ModeCheck[modeIndex] = true;
                        }
                        else
                        {
                            gB_ModeCheck[modeIndex] = false;
                            LogError("[gokz-top-records] Mode %s requires version %d (you have %d).", gC_ModeNamesShort[modeIndex], latestVersion, localVersion);
                        }
                    }

                    delete modeObj;
                }
            }
        }
        case Req_BanCheck:
        {
            if (client > 0 && IsValidClient(client))
            {
                Handle data = json_object_get(json, "data");
                int count = json_object_get_int(json, "count");
                bool banned = (count > 0);
                if (data != INVALID_HANDLE && json_is_array(data) && json_array_size(data) > 0)
                {
                    banned = true;
                }
                gB_GloballyVerified[client] = !banned;
            }
        }
    }

    delete json;
}
