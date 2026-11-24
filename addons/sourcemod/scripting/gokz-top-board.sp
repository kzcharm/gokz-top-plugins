#include <sourcemod>
#include <sdktools>
#include <cstrike>
#include <clientprefs>
#include <SteamWorks>
#include <json>
#include <gokz/core>
#include <gokz/hud>
#undef REQUIRE_PLUGIN
#include <gokz/progress>
#include <gokz/localdb>
#include <gokz/jumpstats>
#include <gokz/replays>
#define REQUIRE_PLUGIN
#include <gokz/top>

#pragma newdecls required
#pragma semicolon 1
#pragma dynamic 131072

public Plugin myinfo =
{
    name = "KZ Player Board",
    author = "AXE",
    description = "Player and course statistics while holding the scoreboard",
    version = "2.0.0"
};

Cookie g_TabInfo;
Handle g_ScoreHud, g_MapHud, g_RunHud;
bool g_ScoreHeld[MAXPLAYERS + 1];
float g_NextHudUpdate[MAXPLAYERS + 1];

#include "gokz-top-board/card.sp"

public void OnPluginStart()
{
    LoadTranslations("kz_ui.phrases");
    g_TabInfo = new Cookie("gokz_top_tabinfo", "Show scoreboard information while holding Tab", CookieAccess_Private);
    RegConsoleCmd("sm_tabinfo", ToggleTabInfo, "Toggle your scoreboard information overlay. Usage: !tabinfo");
    g_ScoreHud = CreateHudSynchronizer();
    g_MapHud = CreateHudSynchronizer();
    g_RunHud = CreateHudSynchronizer();
}

public void OnMapStart()
{
    GetCurrentMap(g_Map, sizeof(g_Map));
    GetMapDisplayName(g_Map, g_DisplayMap, sizeof(g_DisplayMap));
    for (int i = 1; i <= MaxClients; i++) ResetCard(i);
}

public void OnClientDisconnect(int client)
{
    g_ReplaySteam[client][0] = 0;
    ResetCard(client);
    g_ScoreHeld[client] = false;
    g_NextHudUpdate[client] = 0.0;
}

bool IsHuman(int client)
{
    return client > 0 && IsClientInGame(client) && !IsFakeClient(client);
}

int ObservedRunner(int spectator)
{
    int mode = GetEntProp(spectator, Prop_Send, "m_iObserverMode");
    if (mode != 4 && mode != 5) return 0;
    int target = GetEntPropEnt(spectator, Prop_Send, "m_hObserverTarget");
    if (target <= 0 || target > MaxClients || !IsClientInGame(target)) return 0;
    if (IsFakeClient(target)) return g_ReplaySteam[target][0] ? target : 0;
    int team = GetClientTeam(target);
    return team == CS_TEAM_T || team == CS_TEAM_CT ? target : 0;
}

void ClearScoreCard(int client)
{
    ClearSyncHud(client, g_ScoreHud);
    ClearSyncHud(client, g_MapHud);
    ClearSyncHud(client, g_RunHud);
}

bool TabInfoEnabled(int client)
{
    char value[4];
    g_TabInfo.Get(client, value, sizeof(value));
    return !StrEqual(value, "0");
}

public Action ToggleTabInfo(int client, int args)
{
    if (!IsHuman(client)) return Plugin_Handled;
    if (!AreClientCookiesCached(client))
    {
        GOKZ_PrintToChat(client, true, "%T", "Settings loading", client);
        return Plugin_Handled;
    }
    bool enabled = !TabInfoEnabled(client);
    g_TabInfo.Set(client, enabled ? "1" : "0");
    if (!enabled) ClearScoreCard(client);
    GOKZ_PrintToChat(client, true, "%T", enabled ? "Tab info enabled" : "Tab info disabled", client);
    return Plugin_Handled;
}

public void OnPlayerRunCmdPost(int client, int buttons, int impulse, const float vel[3], const float angles[3],
    int weapon, int subtype, int cmdnum, int tickcount, int seed, const int mouse[2])
{
    bool held = (buttons & IN_SCORE) != 0;
    if (!held && !g_ScoreHeld[client]) return;
    if (!IsHuman(client) || g_ScoreHud == null) return;
    float now = GetTickedTime();
    if (!held)
    {
        ClearScoreCard(client);
        g_ScoreHeld[client] = false;
        return;
    }
    if (g_ScoreHeld[client] && now < g_NextHudUpdate[client]) return;
    g_ScoreHeld[client] = true;
    g_NextHudUpdate[client] = now + 0.5;
    if (AreClientCookiesCached(client) && TabInfoEnabled(client)) ShowScoreCard(client);
}
