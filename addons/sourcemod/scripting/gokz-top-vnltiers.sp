// GOKZTop VNL Tiers
// - Uses gokz.top backend API (gokz-top) for VNL tier information
// - HTTP via SteamWorks extension
// - JSON parsing via SMJansson

#include <sourcemod>
#include <sdktools>
#include <gokz>
#include <gokz/core>
#include <SteamWorks>
#include <smjansson>

#include <gokz-top>

#pragma semicolon 1
#pragma newdecls required

public Plugin myinfo =
{
    name        = "GOKZ.TOP VNL Tiers",
    author      = "Cinyan10",
    description = "Display VNL tier information for maps via gokz.top API",
    version     = "1.0.0"
};

enum
{
    Req_VNLTier = 1
};

static bool g_bVNLTierFetched[MAXPLAYERS + 1];

// Global reusable prefix
static const char GOKZTOP_PREFIX[] = "{gold}GOKZ.TOP {grey}| ";

// ──────────────────────────────────────────────────────────────────────────────
// Helpers
// ──────────────────────────────────────────────────────────────────────────────
static void GetTierColor(int tier, char[] color, int maxlen)
{
    switch (tier)
    {
        case 1: strcopy(color, maxlen, "lime");
        case 2: strcopy(color, maxlen, "green");
        case 3: strcopy(color, maxlen, "yellow");
        case 4: strcopy(color, maxlen, "gold");
        case 5: strcopy(color, maxlen, "lightred");
        case 6: strcopy(color, maxlen, "darkred");
        case 7: strcopy(color, maxlen, "purple");
        case 8: strcopy(color, maxlen, "orchid");
        case 9: strcopy(color, maxlen, "grey2");
        default: strcopy(color, maxlen, "default");
    }
}

// ──────────────────────────────────────────────────────────────────────────────
// Lifecycle
// ──────────────────────────────────────────────────────────────────────────────
public void OnPluginStart()
{
    RegConsoleCmd("sm_vnltier", Command_VNLTier, "Display VNL tier information for current map");
    RegConsoleCmd("sm_vtier", Command_VNLTier, "Display VNL tier information for current map");
}

public void OnMapStart()
{
    for (int i = 1; i <= MaxClients; i++)
    {
        g_bVNLTierFetched[i] = false;
    }
}

// ──────────────────────────────────────────────────────────────────────────────
// GOKZ events
// ──────────────────────────────────────────────────────────────────────────────
public void GOKZ_OnFirstSpawn(int client)
{
    if (client <= 0 || client > MaxClients || !IsClientInGame(client))
        return;
    
    // Check if player is in VNL mode
    if (GOKZ_GetCoreOption(client, Option_Mode) == Mode_Vanilla)
    {
        // Delay slightly to ensure everything is ready
        CreateTimer(2.0, Timer_FetchVNLTier, GetClientUserId(client));
    }
}

public Action Timer_FetchVNLTier(Handle timer, any userid)
{
    int client = GetClientOfUserId(userid);
    if (client <= 0 || client > MaxClients || !IsClientInGame(client))
        return Plugin_Stop;
    
    // Double-check mode in case it changed
    if (GOKZ_GetCoreOption(client, Option_Mode) == Mode_Vanilla)
    {
        FetchVNLTier(client);
    }
    return Plugin_Stop;
}

public void GOKZ_OnOptionChanged(int client, const char[] option, any newValue)
{
    if (client <= 0 || client > MaxClients || !IsClientInGame(client))
        return;
    
    // Check if the mode option changed to Vanilla
    if (StrEqual(option, gC_CoreOptionNames[Option_Mode]) && newValue == Mode_Vanilla)
    {
        FetchVNLTier(client);
    }
}

// ──────────────────────────────────────────────────────────────────────────────
// Commands
// ──────────────────────────────────────────────────────────────────────────────
public Action Command_VNLTier(int client, int args)
{
    if (client <= 0 || client > MaxClients || !IsClientInGame(client))
        return Plugin_Handled;
    
    FetchVNLTier(client);
    return Plugin_Handled;
}

// ──────────────────────────────────────────────────────────────────────────────
// API
// ──────────────────────────────────────────────────────────────────────────────
static void FetchVNLTier(int client)
{
    if (!GOKZTop_IsConfigured())
    {
        GOKZ_PrintToChat(client, false, "%s{red}GOKZTop API not configured (gokz-top-core missing?)", GOKZTOP_PREFIX);
        return;
    }

    char mapName[PLATFORM_MAX_PATH];
    GetCurrentMapDisplayName(mapName, sizeof(mapName));

    char mapEnc[PLATFORM_MAX_PATH * 3];
    GOKZTop_UrlEncode(mapName, mapEnc, sizeof(mapEnc));

    char path[512];
    Format(path, sizeof(path), "/vnltiers/%s", mapEnc);

    char url[768];
    if (!GOKZTop_BuildApiUrl(url, sizeof(url), path))
    {
        GOKZ_PrintToChat(client, false, "%s{red}GOKZTop base URL not configured (gokz-top-core missing?)", GOKZTOP_PREFIX);
        return;
    }

    Handle req = GOKZTop_CreateSteamWorksRequest(k_EHTTPMethodGET, url, false, 15);
    if (req == INVALID_HANDLE)
    {
        GOKZ_PrintToChat(client, false, "%s{red}Failed to create HTTP request", GOKZTOP_PREFIX);
        return;
    }

    SteamWorks_SetHTTPRequestContextValue(req, GetClientUserId(client), Req_VNLTier);
    SteamWorks_SetHTTPCallbacks(req, OnHTTPCompleted);
    SteamWorks_SendHTTPRequest(req);
}

public void OnHTTPCompleted(Handle hRequest, bool bFailure, bool bRequestSuccessful, EHTTPStatusCode eStatusCode, any data1, any data2)
{
    int userid = data1;
    int reqType = (data2 & 0xFF);
    int client = GetClientOfUserId(userid);

    int status = view_as<int>(eStatusCode);

    char body[2048];
    GOKZTop_ReadResponseBody(hRequest, body, sizeof(body));

    if (hRequest != INVALID_HANDLE)
    {
        delete hRequest;
    }

    if (!client || client <= 0 || client > MaxClients || !IsClientInGame(client))
    {
        return;
    }

    if (bFailure || !bRequestSuccessful || status < 200 || status >= 300)
    {
        if (status == 404)
        {
            GOKZ_PrintToChat(client, false, "%s{yellow}VNL tier information not available for this map", GOKZTOP_PREFIX);
        }
        else
        {
            char detail[256] = "";
            if (GOKZTop_LooksLikeJson(body))
            {
                Handle json = json_load(body);
                if (json != INVALID_HANDLE)
                {
                    json_object_get_string(json, "detail", detail, sizeof(detail));
                    delete json;
                }
            }
            
            if (detail[0] != '\0')
            {
                GOKZ_PrintToChat(client, false, "%s{red}%s", GOKZTOP_PREFIX, detail);
            }
            else
            {
                GOKZ_PrintToChat(client, false, "%s{red}Failed to fetch VNL tier information (HTTP %d)", GOKZTOP_PREFIX, status);
            }
        }
        return;
    }

    if (reqType == Req_VNLTier)
    {
        if (!GOKZTop_LooksLikeJson(body))
        {
            GOKZ_PrintToChat(client, false, "%s{red}Invalid response from server", GOKZTOP_PREFIX);
            LogMessage("[gokz-top-vnltiers] Expected JSON, got: %.64s", body);
            return;
        }

        Handle json = json_load(body);
        if (json == INVALID_HANDLE || !json_is_object(json))
        {
            if (json != INVALID_HANDLE) delete json;
            GOKZ_PrintToChat(client, false, "%s{red}Invalid JSON response", GOKZTOP_PREFIX);
            return;
        }

        int tp_tier = json_object_get_int(json, "tp_tier");
        int pro_tier = json_object_get_int(json, "pro_tier");
        char notes[512];
        json_object_get_string(json, "notes", notes, sizeof(notes));

        delete json;

        char mapName[PLATFORM_MAX_PATH];
        GetCurrentMapDisplayName(mapName, sizeof(mapName));

        // Get colors for tiers
        char tp_color[32], pro_color[32];
        GetTierColor(tp_tier, tp_color, sizeof(tp_color));
        GetTierColor(pro_tier, pro_color, sizeof(pro_color));

        // Display tier information
        GOKZ_PrintToChat(client, false, "%s{lime}%s{grey} VNL Tiers:  {yellow}TP: {%s}T%d{default}  {blue}PRO: {%s}T%d{default}", GOKZTOP_PREFIX, mapName, tp_color, tp_tier, pro_color, pro_tier);
        
        if (notes[0] != '\0')
        {
            // Notes may contain escaped quotes, so we need to handle that
            // The JSON decoder should handle this automatically
            GOKZ_PrintToChat(client, false, "%s  {gold}Notes:{bluegrey} %s", GOKZTOP_PREFIX, notes);
        }
    }
}

