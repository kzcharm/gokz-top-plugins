// GOKZTop Level
// - Uses gokz-top-core for player rank and rating data
// - Shows skill level icons on scoreboard
// - Listens to GOKZTop_OnLeaderboardDataFetched forward

#include <sourcemod>
#include <sdktools>
#include <sdkhooks>
#include <gokz>
#include <gokz/core>

#include <gokz-top>

#pragma semicolon 1
#pragma newdecls required

public Plugin myinfo =
{
    name        = "GOKZ.TOP Level",
    author      = "Cinyan10",
    description = "Show KZ skill level icon on scoreboard & allow !rating check via gokz.top API",
    version     = "2.1.0"
};

enum struct PlayerData
{
    int iUserID;
    int iSkillLevel[MODE_COUNT];
}

PlayerData g_Players[MAXPLAYERS + 1];

static const char GOKZTOP_PREFIX[] = "{gold}GOKZ.TOP {grey}| ";
static int m_nPersonaDataPublicLevel;
static bool g_bUsesGokz = false;

// ──────────────────────────────────────────────────────────────────────────────
// Lifecycle
// ──────────────────────────────────────────────────────────────────────────────
public void OnPluginStart()
{
    g_bUsesGokz = LibraryExists("gokz-core");
    m_nPersonaDataPublicLevel = FindSendPropInfo("CCSPlayerResource", "m_nPersonaDataPublicLevel");

    RegConsoleCmd("sm_rating", Command_ShowRating, "Show your current rating and rank");

    for (int i = 1; i <= MaxClients; i++)
    {
        if (IsClientAuthorized(i) && !IsFakeClient(i))
        {
            OnClientPutInServer(i);
        }
    }
}

public void OnAllPluginsLoaded()
{
    g_bUsesGokz = LibraryExists("gokz-core");
    
    // Update skill levels for all connected players
    for (int client = 1; client <= MaxClients; client++)
    {
        if (IsClientInGame(client) && !IsFakeClient(client))
        {
            UpdateSkillLevel(client);
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

public void OnMapStart()
{
    char path[PLATFORM_MAX_PATH];
    for (int i = 0; i < 10; i++)
    {
        Format(path, sizeof(path), "materials/panorama/images/icons/xp/level%i.png", 5001 + i);
        AddFileToDownloadsTable(path);
    }

    int ent = GetPlayerResourceEntity();
    if (ent != -1)
    {
        SDKHook(ent, SDKHook_ThinkPost, Hook_OnThinkPost);
    }
}

public void OnClientPutInServer(int client)
{
    if (IsFakeClient(client))
        return;

    int userID = GetClientUserId(client);
    if (g_Players[client].iUserID != userID)
    {
        g_Players[client].iUserID = userID;
        for (int mode = 0; mode < MODE_COUNT; mode++)
        {
            g_Players[client].iSkillLevel[mode] = 0;
        }
    }

    // Update skill level for current mode
    UpdateSkillLevel(client);
}

public void GOKZ_OnOptionChanged(int client, const char[] option, any newValue)
{
    if (!g_bUsesGokz)
        return;

    Option coreOption;
    if (GOKZ_IsCoreOption(option, coreOption) && coreOption == Option_Mode)
    {
        // Update skill level icon when mode changes
        UpdateSkillLevel(client);
    }
}

// ──────────────────────────────────────────────────────────────────────────────
// Commands
// ──────────────────────────────────────────────────────────────────────────────
public Action Command_ShowRating(int client, int args)
{
    if (!IsClientInGame(client) || IsFakeClient(client))
        return Plugin_Handled;

    int mode = g_bUsesGokz ? GOKZ_GetCoreOption(client, Option_Mode) : 2;
    if (mode < 0 || mode >= MODE_COUNT)
        mode = 2;

    if (!LibraryExists("gokz-top-core"))
    {
        GOKZ_PrintToChat(client, false, "%s{default}Leaderboard system not available.", GOKZTOP_PREFIX);
        return Plugin_Handled;
    }

    if (GOKZTop_IsLeaderboardDataLoaded(client, mode))
    {
        float rating = GOKZTop_GetRating(client, mode);
        int rank = GOKZTop_GetRank(client, mode);
        int skillLevel = g_Players[client].iSkillLevel[mode];

        if (rank > 0)
        {
            GOKZ_PrintToChat(client, false, "%s{default}Your Rating: {green}%.2f{default} {grey}| Rank: {green}#%d{default} {grey}| Level {green}%d",
                GOKZTOP_PREFIX, rating, rank, skillLevel);
        }
        else
        {
            GOKZ_PrintToChat(client, false, "%s{default}Your Rating: {green}%.2f{default} {grey}| Level {green}%d{default} {grey}(Not ranked)",
                GOKZTOP_PREFIX, rating, skillLevel);
        }
    }
    else
    {
        GOKZ_PrintToChat(client, false, "%s{default}Your skill level data is not loaded yet, please wait...", GOKZTOP_PREFIX);
        // Trigger refresh
        GOKZTop_RefreshLeaderboardData(client, mode);
    }

    return Plugin_Handled;
}

// ──────────────────────────────────────────────────────────────────────────────
// Forward handlers
// ──────────────────────────────────────────────────────────────────────────────
public void GOKZTop_OnLeaderboardDataFetched(int client, int mode, float rating, int rank)
{
    if (client <= 0 || client > MaxClients || !IsClientInGame(client) || IsFakeClient(client))
        return;

    if (mode < 0 || mode >= MODE_COUNT)
        return;

    // Convert rating (1-11 range) to level (1-10)
    // Rating 1.0-2.0 = Level 1, 2.0-3.0 = Level 2, ..., 10.0-11.0 = Level 10
    int level = RoundToFloor(rating);
    if (level > 10)
        level = 10;
    else if (level < 1)
        level = 0;

    g_Players[client].iSkillLevel[mode] = level;

    // Update scoreboard icon if this is the current mode
    int currentMode = g_bUsesGokz ? GOKZ_GetCoreOption(client, Option_Mode) : 2;
    if (currentMode < 0 || currentMode >= MODE_COUNT)
        currentMode = 2;

    if (mode == currentMode)
    {
        UpdateScoreboardIcon(client);
    }
}

// ──────────────────────────────────────────────────────────────────────────────
// Helper functions
// ──────────────────────────────────────────────────────────────────────────────
static void UpdateSkillLevel(int client)
{
    if (client <= 0 || client > MaxClients || !IsClientInGame(client) || IsFakeClient(client))
        return;

    if (!LibraryExists("gokz-top-core"))
        return;

    int mode = g_bUsesGokz ? GOKZ_GetCoreOption(client, Option_Mode) : 2;
    if (mode < 0 || mode >= MODE_COUNT)
        mode = 2;

    if (GOKZTop_IsLeaderboardDataLoaded(client, mode))
    {
        float rating = GOKZTop_GetRating(client, mode);
        int level = RoundToFloor(rating);
        if (level > 10)
            level = 10;
        else if (level < 1)
            level = 0;
        g_Players[client].iSkillLevel[mode] = level;
    }
    else
    {
        g_Players[client].iSkillLevel[mode] = 0;
    }

    UpdateScoreboardIcon(client);
}

static void UpdateScoreboardIcon(int client)
{
    int ent = GetPlayerResourceEntity();
    if (ent == -1)
        return;

    int mode = g_bUsesGokz ? GOKZ_GetCoreOption(client, Option_Mode) : 2;
    if (mode < 0 || mode >= MODE_COUNT)
        mode = 2;

    int level = g_Players[client].iSkillLevel[mode];
    if (level <= 0)
        level = 1; // Default level before data is loaded

    SetEntData(ent, m_nPersonaDataPublicLevel + client * 4, 5000 + level, 4, true);
}

// ──────────────────────────────────────────────────────────────────────────────
// Scoreboard hook
// ──────────────────────────────────────────────────────────────────────────────
void Hook_OnThinkPost(int ent)
{
    for (int i = 1; i <= MaxClients; i++)
    {
        if (!IsClientInGame(i) || IsFakeClient(i))
            continue;

        UpdateScoreboardIcon(i);
    }
}
