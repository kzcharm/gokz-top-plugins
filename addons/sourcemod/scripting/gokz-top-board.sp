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
    description = "Playing and spectating rosters with GOKZ settings and player profiles",
    version = "2.0.0"
};

Menu g_Board[MAXPLAYERS + 1];
int g_BoardPage[MAXPLAYERS + 1];
float g_LastFinish[MAXPLAYERS + 1];
int g_FinishCourse[MAXPLAYERS + 1], g_FinishMode[MAXPLAYERS + 1], g_FinishTP[MAXPLAYERS + 1];
char g_OriginalWebsite[256], g_InstalledWebsite[256];
bool g_InMap;
Cookie g_TabInfo;
Handle g_ScoreHud, g_MapHud, g_RunHud;
bool g_ScoreHeld[MAXPLAYERS + 1];
bool g_ReloadHeld[MAXPLAYERS + 1];
float g_NextHudUpdate[MAXPLAYERS + 1];
float g_ScorePressedAt[MAXPLAYERS + 1], g_NativeBoardAt[MAXPLAYERS + 1];
bool g_BoardShortcutUsed[MAXPLAYERS + 1];

#include "gokz-top-board/card.sp"

public void OnPluginStart()
{
    LoadTranslations("kz_ui.phrases");
    g_TabInfo = new Cookie("gokz_top_tabinfo", "Show scoreboard information while holding Tab", CookieAccess_Private);
    RegConsoleCmd("sm_tabinfo", ToggleTabInfo, "Toggle your scoreboard information overlay. Usage: !tabinfo");
    RegConsoleCmd("sm_kzboard", OpenBoard);
    RegConsoleCmd("sm_kzboard_close", CloseBoard);
    RegConsoleCmd("sm_kzplayer", OpenPlayer, "Show current KZ run and GOKZ.TOP profile for a connected player");
    RegConsoleCmd("sm_kzui_nativeboard", NativeBoardShown);
    RegConsoleCmd("sm_kzsettings", OpenSettings);
    RegConsoleCmd("sm_kzui_set", SetHudOption, "Set your KZ timer, PB difference, speed or spectator display");
    RegServerCmd("kz_ui_website", ReportWebsite);
    g_ScoreHud = CreateHudSynchronizer();
    g_MapHud = CreateHudSynchronizer();
    g_RunHud = CreateHudSynchronizer();
}

public void OnMapStart()
{
    g_InMap = true;
    GetCurrentMap(g_Map, sizeof(g_Map));
    GetMapDisplayName(g_Map, g_DisplayMap, sizeof(g_DisplayMap));
    for (int i = 1; i <= MaxClients; i++) ResetCard(i);
    for (int i = 1; i <= MaxClients; i++) g_LastFinish[i] = 0.0;
}

public void OnConfigsExecuted()
{
    RefreshWebsite();
}

public void OnClientPostAdminCheck(int client)
{
    if (!IsFakeClient(client)) RefreshWebsite();
}

public void OnClientPutInServer(int client)
{
    if (!IsFakeClient(client)) RefreshWebsite();
}

public void OnClientDisconnect_Post(int client)
{
    if (g_InMap) RefreshWebsite();
}

public void OnMapEnd()
{
    RefreshWebsite(true);
    g_InMap = false;
    g_OriginalWebsite[0] = '\0';
    g_InstalledWebsite[0] = '\0';
}

public void OnPluginEnd()
{
    RefreshWebsite(true);
}

int WebsiteEntry(int &table, char[] value, int size)
{
    table = FindStringTable("InfoPanel");
    if (table == INVALID_STRING_TABLE) return INVALID_STRING_INDEX;
    int entry = FindStringIndex(table, "motd");
    if (entry == INVALID_STRING_INDEX || GetStringTableDataLength(table, entry) >= size) return INVALID_STRING_INDEX;
    GetStringTableData(table, entry, value, size);
    return entry;
}

void RefreshWebsite(bool restore = false)
{
    // The scoreboard footer is shared. Only a solo session has an unambiguous profile.
    char current[256], next[256];
    int table, entry = WebsiteEntry(table, current, sizeof(current));
    if (entry == INVALID_STRING_INDEX) return;
    if (g_InstalledWebsite[0] && !StrEqual(current, g_InstalledWebsite)) return;
    if (restore || !FindCommandLineParam("-insecure"))
    {
        if (g_InstalledWebsite[0]) SetStringTableData(table, entry, g_OriginalWebsite, strlen(g_OriginalWebsite) + 1);
        g_InstalledWebsite[0] = '\0';
        return;
    }
    if (!g_InstalledWebsite[0])
    {
        char plain[256];
        strcopy(plain, sizeof(plain), current);
        TrimString(plain);
        if (!StrEqual(plain, "http://blog.counter-strike.net/motd/motd.php") &&
            !StrEqual(plain, "https://blog.counter-strike.net/motd/motd.php")) return;
        strcopy(g_OriginalWebsite, sizeof(g_OriginalWebsite), current);
    }
    strcopy(next, sizeof(next), "https://gokz.top/leaderboards/players");
    int solo;
    for (int i = 1; i <= MaxClients; i++)
    {
        if (!IsHuman(i)) continue;
        if (solo) { solo = 0; break; }
        solo = i;
    }
    char steam[32];
    if (solo && GetClientAuthId(solo, AuthId_SteamID64, steam, sizeof(steam)))
        FormatEx(next, sizeof(next), "https://gokz.top/profile/%s", steam);
    // The fragment stays client-side. Panorama can distinguish real KZ values
    // from combat stats without guessing from a server or map name.
    StrCat(next, sizeof(next), "#kzui-v1");
    if (LibraryExists("scoreboardtimer")) StrCat(next, sizeof(next), "-time");
    if (GetFeatureStatus(FeatureType_Native, "GOKZ_PG_GetProgress") == FeatureStatus_Available)
        StrCat(next, sizeof(next), "-route");
    if (!StrEqual(current, next)) SetStringTableData(table, entry, next, strlen(next) + 1);
    strcopy(g_InstalledWebsite, sizeof(g_InstalledWebsite), next);
}

public void OnLibraryAdded(const char[] name)
{
    if (g_InMap && (StrEqual(name, "scoreboardtimer") || StrEqual(name, "gokz-progress"))) RefreshWebsite();
}

public void OnLibraryRemoved(const char[] name)
{
    if (g_InMap && (StrEqual(name, "scoreboardtimer") || StrEqual(name, "gokz-progress"))) RefreshWebsite();
}

public Action ReportWebsite(int args)
{
    char value[256];
    int table;
    if (WebsiteEntry(table, value, sizeof(value)) != INVALID_STRING_INDEX && g_InstalledWebsite[0] && StrEqual(value, g_InstalledWebsite))
        PrintToServer("KZ scoreboard website %s", value);
    else PrintToServer("KZ scoreboard website uses the server default");
    return Plugin_Handled;
}

public void GOKZ_OnTimerEnd_Post(int client, int course, float time, int teleportsUsed)
{
    g_LastFinish[client] = time;
    g_FinishCourse[client] = course;
    g_FinishMode[client] = GOKZ_GetCoreOption(client, Option_Mode);
    g_FinishTP[client] = teleportsUsed;
}

public void OnClientDisconnect(int client)
{
    g_ReplaySteam[client][0] = 0;
    ResetCard(client);
    g_Board[client] = null;
    g_LastFinish[client] = 0.0;
    g_ScoreHeld[client] = false;
    g_ReloadHeld[client] = false;
    g_NextHudUpdate[client] = 0.0;
    g_NativeBoardAt[client] = 0.0;
    g_BoardShortcutUsed[client] = false;
}

bool IsHuman(int client)
{
    return client > 0 && IsClientInGame(client) && !IsFakeClient(client);
}

enum RosterRole
{
    Role_Playing,
    Role_Spectating,
    Role_Unlisted
};

RosterRole GetRosterRole(int client)
{
    if (!IsHuman(client)) return Role_Unlisted;
    switch (GetClientTeam(client))
    {
        case CS_TEAM_T, CS_TEAM_CT: return Role_Playing;
        case CS_TEAM_SPECTATOR: return Role_Spectating;
    }
    return Role_Unlisted;
}

int ObservedRunner(int spectator, bool includeReplay = false)
{
    int mode = GetEntProp(spectator, Prop_Send, "m_iObserverMode");
    if (mode != 4 && mode != 5) return 0;
    int target = GetEntPropEnt(spectator, Prop_Send, "m_hObserverTarget");
    if (target <= 0 || target > MaxClients || !IsClientInGame(target)) return 0;
    if (includeReplay && IsFakeClient(target) && g_ReplaySteam[target][0]) return target;
    return GetRosterRole(target) == Role_Playing ? target : 0;
}

void RunnerSummary(int viewer, int player, char[] buffer, int length)
{
    int mode = GOKZ_GetCoreOption(player, Option_Mode);
    char state[64];
    if (GOKZ_GetTimerRunning(player))
    {
        char clock[20];
        strcopy(clock, sizeof(clock), GOKZ_FormatTime(GOKZ_GetTime(player),
            GOKZ_HUD_GetOption(viewer, HUDOption_TimerStyle) == TimerStyle_Precise));
        if (GOKZ_GetPaused(player))
            FormatEx(state, sizeof(state), "%T %s", "Paused", viewer, clock);
        else if (!GOKZ_GetValidTimer(player))
            FormatEx(state, sizeof(state), "%T %s", "Practice", viewer, clock);
        else
            strcopy(state, sizeof(state), clock);
        int course = GOKZ_GetCourse(player);
        if (course > 0) Format(state, sizeof(state), "B%d  %s", course, state);
    }
    else
        FormatEx(state, sizeof(state), "%T", "Idle", viewer);

    FormatEx(buffer, length, "%s  %s  |  %d TP", gC_ModeNamesShort[mode], state, GOKZ_GetTeleportCount(player));
    if (GetFeatureStatus(FeatureType_Native, "GOKZ_PG_IsEnabled") == FeatureStatus_Available && GOKZ_PG_IsEnabled(player))
    {
        char route[24];
        FormatEx(route, sizeof(route), "  |  %.1f%%", GOKZ_PG_GetProgress(player) * 100.0);
        StrCat(buffer, length, route);
    }
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

public Action NativeBoardShown(int client, int args)
{
    if (IsHuman(client))
    {
        g_NativeBoardAt[client] = GetTickedTime();
        if (g_ScoreHeld[client]) ClearScoreCard(client);
    }
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
        if (!g_BoardShortcutUsed[client] && g_NativeBoardAt[client] == 0.0 &&
            now - g_ScorePressedAt[client] <= 0.30 && !IsVoteInProgress())
        {
            if (g_Board[client] != null) CloseBoard(client, 0);
            else if (GetClientMenu(client) == MenuSource_None) OpenBoard(client, 0);
        }
        g_NativeBoardAt[client] = 0.0;
        return;
    }
    bool first = !g_ScoreHeld[client];
    if (first)
    {
        g_ScorePressedAt[client] = now;
        g_BoardShortcutUsed[client] = false;
        // The engine can also open its scoreboard at the end of a match.
        if (now - g_NativeBoardAt[client] > 0.5) g_NativeBoardAt[client] = 0.0;
        g_ScoreHeld[client] = true;
    }
    if (g_NativeBoardAt[client] != 0.0) return;
    bool reload = (buttons & IN_RELOAD) != 0;
    if (!first && reload && !g_ReloadHeld[client] && !IsVoteInProgress())
    {
        OpenBoard(client, 0);
        g_BoardShortcutUsed[client] = true;
    }
    g_ReloadHeld[client] = reload;
    if (!first && now < g_NextHudUpdate[client]) return;
    g_NextHudUpdate[client] = now + 0.5;
    if (AreClientCookiesCached(client) && TabInfoEnabled(client)) ShowScoreCard(client);
}

public Action OpenBoard(int client, int args)
{
    if (!IsHuman(client)) return Plugin_Handled;
    g_BoardPage[client] = 0;
    ShowBoard(client);
    return Plugin_Handled;
}

void ShowBoard(int client)
{
    Menu menu = new Menu(BoardAction);
    char map[PLATFORM_MAX_PATH], label[192], key[16], summary[96];
    GetCurrentMap(map, sizeof(map));
    menu.SetTitle("GOKZ.TOP  |  %s", map);
    for (RosterRole group = Role_Playing; group <= Role_Spectating; group++)
    {
        int count = 0;
        for (int i = 1; i <= MaxClients; i++)
            if (GetRosterRole(i) == group) count++;
        FormatEx(label, sizeof(label), "%T (%d)", group == Role_Playing ? "Playing" : "Spectating", client, count);
        menu.AddItem("", label, ITEMDRAW_DISABLED);
        for (int i = 1; i <= MaxClients; i++)
        {
            if (GetRosterRole(i) != group) continue;
            IntToString(GetClientUserId(i), key, sizeof(key));
            if (group == Role_Playing)
            {
                RunnerSummary(client, i, summary, sizeof(summary));
                FormatEx(label, sizeof(label), "%N  |  %s", i, summary);
            }
            else
            {
                int target = ObservedRunner(i);
                if (target) FormatEx(label, sizeof(label), "%N  ->  %N", i, target);
                else GetClientName(i, label, sizeof(label));
            }
            menu.AddItem(key, label);
        }
    }
    FormatEx(label, sizeof(label), "%T", "Settings", client);
    menu.AddItem("settings", label);
    FormatEx(label, sizeof(label), "%T", "Refresh", client);
    menu.AddItem("refresh", label);
    int first = g_BoardPage[client];
    if (first >= menu.ItemCount)
        first = ((menu.ItemCount - 1) / menu.Pagination) * menu.Pagination;
    if (menu.DisplayAt(client, first, MENU_TIME_FOREVER)) g_Board[client] = menu;
}

public Action CloseBoard(int client, int args)
{
    if (IsHuman(client) && g_Board[client] != null)
        CancelClientMenu(client);
    return Plugin_Handled;
}

public int BoardAction(Menu menu, MenuAction action, int client, int item)
{
    if (action == MenuAction_End)
    {
        for (int i = 1; i <= MaxClients; i++)
            if (g_Board[i] == menu) g_Board[i] = null;
        delete menu;
    }
    else if (action == MenuAction_Select)
    {
        g_Board[client] = null;
        g_BoardPage[client] = GetMenuSelectionPosition();
        char key[16];
        menu.GetItem(item, key, sizeof(key));
        if (StrEqual(key, "settings")) ShowSettings(client);
        else if (StrEqual(key, "refresh")) ShowBoard(client);
        else ShowPlayer(client, GetClientOfUserId(StringToInt(key)));
    }
    return 0;
}

public Action OpenPlayer(int client, int args)
{
    if (!IsHuman(client)) return Plugin_Handled;
    g_BoardPage[client] = 0;
    if (!args)
    {
        ShowPlayer(client, client);
        return Plugin_Handled;
    }
    char selected[MAX_NAME_LENGTH + 4];
    if (GetCmdArgString(selected, sizeof(selected)) >= sizeof(selected) - 1)
    {
        ShowPlayer(client, 0);
        return Plugin_Handled;
    }
    TrimString(selected);
    StripQuotes(selected);
    bool steamId = strlen(selected) == 17;
    for (int i = 0; steamId && i < 17; i++) steamId = IsCharNumeric(selected[i]);
    if (steamId)
    {
        char steam[32];
        for (int player = 1; player <= MaxClients; player++)
        {
            if (IsHuman(player) && GetClientAuthId(player, AuthId_SteamID64, steam, sizeof(steam))
                && StrEqual(steam, selected))
            {
                ShowPlayer(client, player);
                return Plugin_Handled;
            }
        }
    }
    else if (selected[0])
    {
        int matches[1];
        char targetName[MAX_TARGET_LENGTH];
        bool isPhrase;
        int count = ProcessTargetString(selected, client, matches, sizeof(matches),
            COMMAND_FILTER_NO_MULTI | COMMAND_FILTER_NO_BOTS | COMMAND_FILTER_NO_IMMUNITY,
            targetName, sizeof(targetName), isPhrase);
        if (count == 1)
        {
            ShowPlayer(client, matches[0]);
            return Plugin_Handled;
        }
    }
    ShowPlayer(client, 0);
    return Plugin_Handled;
}

void ShowPlayer(int viewer, int player)
{
    RosterRole role = GetRosterRole(player);
    if (role == Role_Unlisted)
    {
        GOKZ_PrintToChat(viewer, true, "%T", "Choose current player", viewer);
        ShowBoard(viewer);
        return;
    }
    Menu menu = new Menu(PlayerAction);
    char key[16], text[192], summary[96];
    IntToString(GetClientUserId(player), key, sizeof(key));
    if (role == Role_Playing)
        RunnerSummary(viewer, player, summary, sizeof(summary));
    else
        FormatEx(summary, sizeof(summary), "%T", "Spectating", viewer);
    menu.SetTitle("GOKZ.TOP  |  %N\n%s", player, summary);
    if (role == Role_Playing && g_LastFinish[player] > 0.0)
    {
        char clock[20];
        strcopy(clock, sizeof(clock), GOKZ_FormatTime(g_LastFinish[player]));
        FormatEx(text, sizeof(text), "%T  %s  |  %s  |  %d TP", "Last finish", viewer, clock,
            gC_ModeNamesShort[g_FinishMode[player]], g_FinishTP[player]);
        if (g_FinishCourse[player] > 0) Format(text, sizeof(text), "%s  |  B%d", text, g_FinishCourse[player]);
        menu.SetTitle("GOKZ.TOP  |  %N\n%s\n%s", player, summary, text);
    }
    if (role == Role_Playing && GetFeatureStatus(FeatureType_Native, "GOKZ_PG_HasTimeDiff") == FeatureStatus_Available
        && GOKZ_PG_HasTimeDiff(player) && GetCommandFlags("sm_timediff") != INVALID_FCVAR_FLAGS && GOKZ_GetOption(viewer, "GOKZ HUD - Time Diff"))
    {
        char delta[32];
        GOKZ_PG_GetTimeDiffFormatted(player, delta, sizeof(delta));
        if (delta[0])
        {
            menu.GetTitle(text, sizeof(text));
            menu.SetTitle("%s\n%T  %s", text, "PB difference", viewer, delta);
        }
    }
    int mode = GOKZ_GetCoreOption(player, Option_Mode);
    int scope = mode == Mode_NoPerfKZ ? GOKZTOP_MODE_OVR : mode;
    if (GetFeatureStatus(FeatureType_Native, "GOKZTop_IsLeaderboardDataLoaded") == FeatureStatus_Available &&
        GOKZTop_IsLeaderboardDataLoaded(player, scope))
    {
        char rating[80];
        FormatEx(rating, sizeof(rating), "%s %T  %.2f", scope == GOKZTOP_MODE_OVR ? "OVR" : gC_ModeNamesShort[mode],
            "Rating", viewer, GOKZTop_GetRating(player, scope));
        int rank = GOKZTop_GetGlobalRank(player, scope);
        if (rank > 0) Format(rating, sizeof(rating), "%s  |  #%d", rating, rank);
        menu.GetTitle(text, sizeof(text));
        menu.SetTitle("%s\n%s", text, rating);
    }
    FormatEx(text, sizeof(text), "%T", "Player profile", viewer);
    menu.AddItem(key, text, GetCommandFlags("sm_profile") == INVALID_FCVAR_FLAGS ? ITEMDRAW_DISABLED : ITEMDRAW_DEFAULT);
    char steam[32];
    if (GetClientAuthId(player, AuthId_SteamID64, steam, sizeof(steam)))
    {
        FormatEx(text, sizeof(text), "%T", "Website link", viewer);
        FormatEx(key, sizeof(key), "url%d", GetClientUserId(player));
        menu.AddItem(key, text);
        FormatEx(text, sizeof(text), "%T", "Card link", viewer);
        FormatEx(key, sizeof(key), "card%d", GetClientUserId(player));
        menu.AddItem(key, text);
    }
    menu.ExitBackButton = true;
    menu.Display(viewer, MENU_TIME_FOREVER);
}

public int PlayerAction(Menu menu, MenuAction action, int client, int item)
{
    if (action == MenuAction_End) delete menu;
    else if (action == MenuAction_Cancel && item == MenuCancel_ExitBack) ShowBoard(client);
    else if (action == MenuAction_Select)
    {
        char key[16], steam[32];
        menu.GetItem(item, key, sizeof(key));
        bool card = StrContains(key, "card") == 0;
        bool profileLink = StrContains(key, "url") == 0;
        int userid = card ? StringToInt(key[4]) : (profileLink ? StringToInt(key[3]) : StringToInt(key));
        int player = GetClientOfUserId(userid);
        if (!IsHuman(player)) ShowPlayer(client, 0);
        else if (!card && !profileLink) FakeClientCommand(client, "sm_profile #%d", userid);
        else if (GetClientAuthId(player, AuthId_SteamID64, steam, sizeof(steam)))
        {
            char url[144];
            if (card)
            {
                char code[16];
                int language = GetClientLanguage(client);
                if (language >= 0) GetLanguageInfo(language, code, sizeof(code));
                int mode = GOKZ_GetCoreOption(player, Option_Mode);
                FormatEx(url, sizeof(url), "https://gokz.top/cards/player/%s?scope=%s&lang=%s", steam,
                    mode == Mode_NoPerfKZ ? "OVR" : gC_ModeNamesShort[mode],
                    StrEqual(code, "chi") ? "zh-CN" : (StrEqual(code, "ru") ? "ru" : "en"));
            }
            else FormatEx(url, sizeof(url), "https://gokz.top/profile/%s", steam);
            GOKZ_PrintToChat(client, true, "{grey}GOKZ.TOP {default}%s", url);
            PrintToConsole(client, "%s", url);
            ShowPlayer(client, player);
        }
    }
    return 0;
}

public Action OpenSettings(int client, int args)
{
    if (!IsHuman(client)) return Plugin_Handled;
    g_BoardPage[client] = 0;
    ShowSettings(client);
    return Plugin_Handled;
}

void ShowSettings(int client)
{
    Menu menu = new Menu(SettingsAction);
    char label[128], value[64];
    menu.SetTitle("%T", "Settings", client);
    FormatEx(value, sizeof(value), "%T", GOKZ_HUD_GetOption(client, HUDOption_TimerStyle) == TimerStyle_Standard ? "Standard" : "Precise", client);
    FormatEx(label, sizeof(label), "%T  |  %s", "Timer precision", client, value);
    menu.AddItem("sm_timerstyle", label);
    if (GetCommandFlags("sm_timediff") != INVALID_FCVAR_FLAGS)
    {
        FormatEx(value, sizeof(value), "%T", GOKZ_GetOption(client, "GOKZ HUD - Time Diff") ? "On" : "Off", client);
        FormatEx(label, sizeof(label), "%T  |  %s", "PB difference", client, value);
        menu.AddItem("sm_timediff", label);
    }
    int speed = GOKZ_HUD_GetOption(client, HUDOption_SpeedText);
    char phrase[24] = "Off";
    if (speed == SpeedText_InfoPanel) strcopy(phrase, sizeof(phrase), "Info panel");
    if (speed == SpeedText_Bottom) strcopy(phrase, sizeof(phrase), "Bottom");
    FormatEx(value, sizeof(value), "%T", phrase, client);
    FormatEx(label, sizeof(label), "%T  |  %s", "Speed display", client, value);
    menu.AddItem("sm_speed", label);
    int spectators = GOKZ_HUD_GetOption(client, HUDOption_ShowSpectators);
    FormatEx(value, sizeof(value), "%T", spectators == ShowSpecs_Number ? "Count" :
        (spectators == ShowSpecs_Full ? "Count and names" : "Off"), client);
    FormatEx(label, sizeof(label), "%T  |  %s", "Spectator list", client, value);
    menu.AddItem("spectators", label);
    FormatEx(label, sizeof(label), "%T", "All options", client);
    menu.AddItem("sm_options", label);
    menu.ExitBackButton = true;
    menu.Display(client, MENU_TIME_FOREVER);
}

public Action SetHudOption(int client, int args)
{
    if (!IsHuman(client)) return Plugin_Handled;
    if (!AreClientCookiesCached(client))
    {
        GOKZ_PrintToChat(client, true, "%T", "Settings loading", client);
        return Plugin_Handled;
    }
    char name[24], value[24];
    GetCmdArg(1, name, sizeof(name));
    GetCmdArg(2, value, sizeof(value));
    HUDOption option = HUDOption_TimerStyle;
    int requested = -1;
    if (StrEqual(name, "timer"))
    {
        if (StrEqual(value, "standard")) requested = TimerStyle_Standard;
        if (StrEqual(value, "precise")) requested = TimerStyle_Precise;
    }
    else if (StrEqual(name, "difference"))
    {
        if (args == 2 && GetCommandFlags("sm_timediff") != INVALID_FCVAR_FLAGS && (StrEqual(value, "off") || StrEqual(value, "on")))
        {
            GOKZ_SetOption(client, "GOKZ HUD - Time Diff", StrEqual(value, "on"));
            return Plugin_Handled;
        }
    }
    else if (StrEqual(name, "speed"))
    {
        option = HUDOption_SpeedText;
        if (StrEqual(value, "off")) requested = SpeedText_Disabled;
        if (StrEqual(value, "panel")) requested = SpeedText_InfoPanel;
        if (StrEqual(value, "bottom")) requested = SpeedText_Bottom;
    }
    else if (StrEqual(name, "spectators"))
    {
        option = HUDOption_ShowSpectators;
        if (StrEqual(value, "off")) requested = ShowSpecs_Disabled;
        if (StrEqual(value, "count")) requested = ShowSpecs_Number;
        if (StrEqual(value, "names")) requested = ShowSpecs_Full;
    }
    if (args != 2 || requested < 0)
    {
        GOKZ_PrintToChat(client, true, "%T", "Invalid setting", client);
        return Plugin_Handled;
    }
    if (option == HUDOption_SpeedText && requested == SpeedText_InfoPanel &&
        GOKZ_HUD_GetOption(client, HUDOption_InfoPanel) == InfoPanel_Disabled)
    {
        GOKZ_PrintToChat(client, true, "%T", "Panel disabled", client);
        return Plugin_Handled;
    }
    if (GOKZ_HUD_GetOption(client, option) != requested)
        GOKZ_HUD_SetOption(client, option, requested);
    if (GOKZ_HUD_GetOption(client, option) == requested)
        PrintToConsole(client, "GOKZ HUD %s %s", name, value);
    else
        GOKZ_PrintToChat(client, true, "%T", "Option unavailable", client);
    return Plugin_Handled;
}

public int SettingsAction(Menu menu, MenuAction action, int client, int item)
{
    if (action == MenuAction_End) delete menu;
    else if (action == MenuAction_Cancel && item == MenuCancel_ExitBack) ShowBoard(client);
    else if (action == MenuAction_Select)
    {
        char command[32];
        menu.GetItem(item, command, sizeof(command));
        if (StrEqual(command, "spectators"))
        {
            int current = GOKZ_HUD_GetOption(client, HUDOption_ShowSpectators);
            FakeClientCommand(client, "sm_kzui_set spectators %s", current == ShowSpecs_Disabled ? "count" :
                (current == ShowSpecs_Number ? "names" : "off"));
        }
        else FakeClientCommand(client, "%s", command);
        if (!StrEqual(command, "sm_options")) ShowSettings(client);
    }
    return 0;
}
