// GOKZTop Map Ratings & Comments
// - Uses gokz.top backend API (gokz-top) for rating + comments
// - HTTP via SteamWorks extension
// - JSON parsing via SMJansson

#include <sourcemod>
#include <sdktools>
#include <gokz>
#include <gokz/core>
#include <SteamWorks>
#include <smjansson>

#include <gokztop>

#pragma semicolon 1
#pragma newdecls required

public Plugin myinfo =
{
    name        = "GOKZ.TOP Map Ratings",
    author      = "Cinyan10",
    description = "Rate maps (visuals/overall/gameplay) and leave a comment via gokz.top API",
    version     = "2.0.0"
};

enum
{
    Req_AggregatedRatings = 1,
    Req_MyRatings,
    Req_SubmitRating,
    Req_SubmitComment,
    Req_FetchComments,
    Req_FetchCommentsCount
};

enum
{
    Aspect_Visuals = 0,
    Aspect_Overall = 1,
    Aspect_Gameplay = 2
};

static const char g_AspectNames[][] =
{
    "visuals",
    "overall",
    "gameplay"
};

static bool g_bRateReminderSent[MAXPLAYERS + 1];
static bool g_bRatePromptPending[MAXPLAYERS + 1];
static float g_fRatePromptRequestedAt[MAXPLAYERS + 1];
static int g_iActiveAspectMenu[MAXPLAYERS + 1];
static bool g_bCaptureComment[MAXPLAYERS + 1];
static bool g_bMenuPending[MAXPLAYERS + 1];
static int g_iCommentsCount[MAXPLAYERS + 1];
static bool g_bCommentsCountFetched[MAXPLAYERS + 1];
static bool g_bAggregatedRatingsFetched[MAXPLAYERS + 1];
static bool g_bMyRatingsFetched[MAXPLAYERS + 1];

// Cached aggregated ratings (per-map; updated on fetch)
static char g_sCachedMapName[PLATFORM_MAX_PATH];
static float g_fAvgRating[3];
static int g_iAvgCount[3];

// Per-player last known ratings (0=unknown/unset)
static int g_iMyRating[MAXPLAYERS + 1][3];
static float g_fLastMyRatingsFetchAt[MAXPLAYERS + 1];

// ──────────────────────────────────────────────────────────────────────────────
// Lifecycle
// ──────────────────────────────────────────────────────────────────────────────
public void OnPluginStart()
{
    LoadTranslations("gokztop-map-ratings.phrases");

    RegConsoleCmd("sm_rate", Command_Rate, "Usage: !rate [<1-5>|<aspect> <1-5>] [comment]");
    RegConsoleCmd("sm_comments", Command_Comments, "Show latest gokz.top comments for this map");

    AddCommandListener(Command_Say, "say");
    AddCommandListener(Command_Say, "say_team");
}

public void OnMapStart()
{
    for (int i = 1; i <= MaxClients; i++)
    {
        g_bRateReminderSent[i] = false;
        g_bRatePromptPending[i] = false;
        g_fRatePromptRequestedAt[i] = 0.0;
        g_bCaptureComment[i] = false;
        g_bMenuPending[i] = false;
        g_iCommentsCount[i] = -1;
        g_bCommentsCountFetched[i] = false;
        g_bAggregatedRatingsFetched[i] = false;
        g_bMyRatingsFetched[i] = false;
        g_iMyRating[i][0] = 0;
        g_iMyRating[i][1] = 0;
        g_iMyRating[i][2] = 0;
        g_fLastMyRatingsFetchAt[i] = 0.0;
    }

    g_sCachedMapName[0] = '\0';
    for (int a = 0; a < 3; a++)
    {
        g_fAvgRating[a] = -1.0;
        g_iAvgCount[a] = 0;
    }
}

// ──────────────────────────────────────────────────────────────────────────────
// GOKZ events
// ──────────────────────────────────────────────────────────────────────────────
public void GOKZ_OnFirstSpawn(int client)
{
    if (!IsValidClient(client)) return;
    CreateTimer(2.0, Timer_FetchAvg, GetClientUserId(client));
}

public Action Timer_FetchAvg(Handle timer, any userid)
{
    int client = GetClientOfUserId(userid);
    if (!IsValidClient(client)) return Plugin_Stop;
    FetchAggregatedRatings(client);
    return Plugin_Stop;
}

public void GOKZ_OnTimerEnd_Post(int client, int course, float time, int teleportsUsed)
{
    if (!IsValidClient(client)) return;
    // Only remind on main stage (course 0) finishes.
    if (course != 0) return;

    // If we already reminded this map, don't do anything.
    if (g_bRateReminderSent[client]) return;

    CreateTimer(3.0, Timer_PromptRateIfNeeded, GetClientUserId(client));
}

public Action Timer_PromptRateIfNeeded(Handle timer, any userid)
{
    int client = GetClientOfUserId(userid);
    if (!IsValidClient(client)) return Plugin_Stop;

    // Only prompt if we can determine the player has not rated this map yet.
    // We do this by fetching their ratings and then deciding in Req_MyRatings.
    if (!GOKZTop_IsConfigured())
    {
        return Plugin_Stop;
    }

    // If we already know they rated something (any aspect), don't remind.
    if (g_iMyRating[client][Aspect_Overall] > 0
        || g_iMyRating[client][Aspect_Gameplay] > 0
        || g_iMyRating[client][Aspect_Visuals] > 0)
    {
        return Plugin_Stop;
    }

    // Mark pending and fetch ratings now (forced), then decide when the response arrives.
    g_bRatePromptPending[client] = true;
    g_fRatePromptRequestedAt[client] = GetGameTime();
    FetchMyRatings(client, true);
    return Plugin_Stop;
}

// ──────────────────────────────────────────────────────────────────────────────
// Commands
// ──────────────────────────────────────────────────────────────────────────────
public Action Command_Rate(int client, int args)
{
    if (!IsValidClient(client))
        return Plugin_Handled;

    if (args == 0)
    {
        // Fetch all data needed for menu, then show menu when ready
        g_bMenuPending[client] = true;
        g_bAggregatedRatingsFetched[client] = false;
        g_bMyRatingsFetched[client] = false;
        g_bCommentsCountFetched[client] = false;
        g_iCommentsCount[client] = -1;
        
        FetchAggregatedRatings(client);
        FetchMyRatingsIfNeeded(client);
        FetchCommentsCount(client);
        return Plugin_Handled;
    }

    char arg1[32];
    GetCmdArg(1, arg1, sizeof(arg1));

    // Form: !rate 5 [comment]  -> overall
    if (IsNumeric(arg1))
    {
        int rating = StringToInt(arg1);
        if (!IsValidRating(rating))
        {
            GOKZ_PlayErrorSound(client);
            char msg[256];
            FormatEx(msg, sizeof(msg), "%T", "GOKZTop_RatingRangeError", client);
            GOKZ_PrintToChat(client, true, "%s", msg);
            return Plugin_Handled;
        }

        char comment[256];
        ExtractTailComment(args, 1, comment, sizeof(comment));

        SubmitRating(client, Aspect_Overall, rating);
        if (comment[0] != '\0')
        {
            SubmitComment(client, comment);
        }

        return Plugin_Handled;
    }

    // Form: !rate <aspect> <1-5> [comment]
    if (args >= 2)
    {
        int aspect = ParseAspect(arg1);
        if (aspect < 0)
        {
            GOKZ_PlayErrorSound(client);
            char msg[256];
            FormatEx(msg, sizeof(msg), "%T", "GOKZTop_UnknownAspect", client);
            GOKZ_PrintToChat(client, true, "%s", msg);
            return Plugin_Handled;
        }

        char arg2[16];
        GetCmdArg(2, arg2, sizeof(arg2));
        if (!IsNumeric(arg2))
        {
            GOKZ_PlayErrorSound(client);
            char msg[256];
            FormatEx(msg, sizeof(msg), "%T", "GOKZTop_RateAspectUsage", client);
            GOKZ_PrintToChat(client, true, "%s", msg);
            return Plugin_Handled;
        }

        int rating = StringToInt(arg2);
        if (!IsValidRating(rating))
        {
            GOKZ_PlayErrorSound(client);
            char msg[256];
            FormatEx(msg, sizeof(msg), "%T", "GOKZTop_RatingRangeError", client);
            GOKZ_PrintToChat(client, true, "%s", msg);
            return Plugin_Handled;
        }

        char comment[256];
        ExtractTailComment(args, 2, comment, sizeof(comment));

        SubmitRating(client, aspect, rating);
        if (comment[0] != '\0')
        {
            SubmitComment(client, comment);
        }

        return Plugin_Handled;
    }

    {
        char msg[256];
        FormatEx(msg, sizeof(msg), "%T", "GOKZTop_RateUsage", client);
        GOKZ_PrintToChat(client, true, "%s", msg);
    }
    return Plugin_Handled;
}

public Action Command_Comments(int client, int args)
{
    if (!IsValidClient(client)) return Plugin_Handled;
    FetchComments(client);
    return Plugin_Handled;
}

public Action Command_Say(int client, const char[] command, int argc)
{
    if (!IsValidClient(client)) return Plugin_Continue;
    if (!g_bCaptureComment[client]) return Plugin_Continue;

    char msg[256];
    GetCmdArgString(msg, sizeof(msg));
    StripQuotes(msg);
    TrimString(msg);

    if (msg[0] == '\0')
        return Plugin_Handled;

    if (StrEqual(msg, "!cancel", false) || StrEqual(msg, "/cancel", false))
    {
        g_bCaptureComment[client] = false;
        char t[256];
        FormatEx(t, sizeof(t), "%T", "GOKZTop_CommentCancelled", client);
        GOKZ_PrintToChat(client, true, "%s", t);
        return Plugin_Handled;
    }

    g_bCaptureComment[client] = false;

    SubmitComment(client, msg);
    // Refresh menu data and show menu
    g_bMenuPending[client] = true;
    g_bAggregatedRatingsFetched[client] = false;
    g_bMyRatingsFetched[client] = false;
    g_bCommentsCountFetched[client] = false;
    g_iCommentsCount[client] = -1;
    
    FetchAggregatedRatings(client);
    FetchMyRatingsIfNeeded(client);
    FetchCommentsCount(client);

    return Plugin_Handled;
}

// ──────────────────────────────────────────────────────────────────────────────
// Menus
// ──────────────────────────────────────────────────────────────────────────────
static void ShowRateMenu_Main(int client)
{
    char mapName[PLATFORM_MAX_PATH];
    GetCurrentMapDisplayName(mapName, sizeof(mapName));

    Menu menu = new Menu(MenuHandler_RateMain);
    char title[256];
    Format(title, sizeof(title), "【%s】Rate (gokz.top)", mapName);

    // Show cached averages in the title (best-effort; may be empty if not fetched yet)
    if (StrEqual(g_sCachedMapName, mapName, false))
    {
        char oStars[16], gStars[16], vStars[16];
        BuildStarsFloat(g_fAvgRating[Aspect_Overall], oStars, sizeof(oStars));
        BuildStarsFloat(g_fAvgRating[Aspect_Gameplay], gStars, sizeof(gStars));
        BuildStarsFloat(g_fAvgRating[Aspect_Visuals], vStars, sizeof(vStars));

        char avgOverall[32], avgGameplay[32], avgVisuals[32];
        FormatEx(avgOverall, sizeof(avgOverall), "%T", "GOKZTop_Menu_AvgOverall", client);
        FormatEx(avgGameplay, sizeof(avgGameplay), "%T", "GOKZTop_Menu_AvgGameplay", client);
        FormatEx(avgVisuals, sizeof(avgVisuals), "%T", "GOKZTop_Menu_AvgVisuals", client);

        Format(
            title,
            sizeof(title),
            "【%s】Rate (gokz.top)\n%s: %.2f %s (%d)\n%s: %.2f %s (%d)\n%s: %.2f %s (%d)",
            mapName,
            avgOverall, g_fAvgRating[Aspect_Overall], oStars, g_iAvgCount[Aspect_Overall],
            avgGameplay, g_fAvgRating[Aspect_Gameplay], gStars, g_iAvgCount[Aspect_Gameplay],
            avgVisuals, g_fAvgRating[Aspect_Visuals], vStars, g_iAvgCount[Aspect_Visuals]
        );
    }

    menu.SetTitle(title);
    menu.ExitButton = true;
    menu.ExitBackButton = false;
    menu.Pagination = 6;

    // Order requested:
    // 1. overall
    // 2. gameplay
    // 3. visuals
    // 4. comment
    // 5. view comments
    char line[128];
    char lbl[32];
    GetAspectLabel(client, Aspect_Overall, lbl, sizeof(lbl));
    BuildAspectLine(client, Aspect_Overall, lbl, line, sizeof(line));
    menu.AddItem("aspect_overall", line);
    GetAspectLabel(client, Aspect_Gameplay, lbl, sizeof(lbl));
    BuildAspectLine(client, Aspect_Gameplay, lbl, line, sizeof(line));
    menu.AddItem("aspect_gameplay", line);
    GetAspectLabel(client, Aspect_Visuals, lbl, sizeof(lbl));
    BuildAspectLine(client, Aspect_Visuals, lbl, line, sizeof(line));
    menu.AddItem("aspect_visuals", line);
    char t[128];
    FormatEx(t, sizeof(t), "%T", "GOKZTop_Menu_RateComment", client);
    menu.AddItem("comment", t);
    
    // Format view comments with count
    char viewCommentsText[128];
    FormatEx(viewCommentsText, sizeof(viewCommentsText), "%T", "GOKZTop_Menu_ViewComments", client);
    if (g_iCommentsCount[client] >= 0)
    {
        Format(viewCommentsText, sizeof(viewCommentsText), "%s (%d)", viewCommentsText, g_iCommentsCount[client]);
    }
    
    // Disable view comments if no comments available
    int drawStyle = ITEMDRAW_DEFAULT;
    if (g_iCommentsCount[client] <= 0)
    {
        drawStyle = ITEMDRAW_DISABLED;
    }
    menu.AddItem("view_comments", viewCommentsText, drawStyle);

    menu.Display(client, 0);
}

public int MenuHandler_RateMain(Menu menu, MenuAction action, int client, int item)
{
    if (action == MenuAction_End)
    {
        delete menu;
        return 0;
    }

    if (action != MenuAction_Select) return 0;

    char info[32];
    menu.GetItem(item, info, sizeof(info));

    if (StrEqual(info, "aspect_overall"))
    {
        g_iActiveAspectMenu[client] = Aspect_Overall;
        ShowRateMenu_Aspect(client, Aspect_Overall);
    }
    else if (StrEqual(info, "aspect_gameplay"))
    {
        g_iActiveAspectMenu[client] = Aspect_Gameplay;
        ShowRateMenu_Aspect(client, Aspect_Gameplay);
    }
    else if (StrEqual(info, "aspect_visuals"))
    {
        g_iActiveAspectMenu[client] = Aspect_Visuals;
        ShowRateMenu_Aspect(client, Aspect_Visuals);
    }
    else if (StrEqual(info, "comment"))
    {
        g_bCaptureComment[client] = true;
        char msg[256];
        FormatEx(msg, sizeof(msg), "%T", "GOKZTop_CommentPrompt", client);
        GOKZ_PrintToChat(client, true, "%s", msg);
    }
    else if (StrEqual(info, "view_comments"))
    {
        FetchComments(client);
    }

    return 0;
}

static void ShowRateMenu_Aspect(int client, int aspectIndex)
{
    Menu menu = new Menu(MenuHandler_RateAspect);
    menu.ExitButton = true;
    menu.ExitBackButton = true;

    char label[32];
    if (aspectIndex == Aspect_Overall)
        FormatEx(label, sizeof(label), "%T", "GOKZTop_Menu_LabelOverall", client);
    else if (aspectIndex == Aspect_Gameplay)
        FormatEx(label, sizeof(label), "%T", "GOKZTop_Menu_LabelGameplay", client);
    else
        FormatEx(label, sizeof(label), "%T", "GOKZTop_Menu_LabelVisuals", client);

    char title[96];
    FormatEx(title, sizeof(title), "%T", "GOKZTop_Menu_SubRateTitle", client, label);
    menu.SetTitle(title);

    for (int i = 1; i <= 5; i++)
    {
        char stars[16];
        BuildStarsInt(i, stars, sizeof(stars));

        char info[8];
        IntToString(i, info, sizeof(info));
        menu.AddItem(info, stars);
    }

    menu.Display(client, 0);
}

public int MenuHandler_RateAspect(Menu menu, MenuAction action, int client, int item)
{
    if (action == MenuAction_End)
    {
        delete menu;
        return 0;
    }

    if (action == MenuAction_Cancel)
    {
        // Back button
        if (item == MenuCancel_ExitBack)
        {
            ShowRateMenu_Main(client);
        }
        return 0;
    }

    if (action != MenuAction_Select) return 0;

    char info[8];
    menu.GetItem(item, info, sizeof(info));
    int rating = StringToInt(info);

    int idx = g_iActiveAspectMenu[client];
    if (idx < 0 || idx > 2) idx = 0;

    SubmitRating(client, idx, rating);
    // Refresh menu data and show menu when ready
    g_bMenuPending[client] = true;
    g_bAggregatedRatingsFetched[client] = false;
    g_bMyRatingsFetched[client] = false;
    g_bCommentsCountFetched[client] = false;
    g_iCommentsCount[client] = -1;
    
    FetchAggregatedRatings(client);
    FetchMyRatingsIfNeeded(client);
    FetchCommentsCount(client);
    return 0;
}

// ──────────────────────────────────────────────────────────────────────────────
// API calls
// ──────────────────────────────────────────────────────────────────────────────
static void FetchAggregatedRatings(int client)
{
    char mapName[PLATFORM_MAX_PATH];
    GetCurrentMapDisplayName(mapName, sizeof(mapName));

    char mapEnc[PLATFORM_MAX_PATH * 3];
    GOKZTop_UrlEncode(mapName, mapEnc, sizeof(mapEnc));

    char path[512];
    Format(path, sizeof(path), "/maps/%s/ratings/aggregated", mapEnc);

    char url[768];
    if (!GOKZTop_BuildApiUrl(url, sizeof(url), path))
    {
        // keep this one hardcoded for now (core missing is not translation-dependent)
        GOKZ_PrintToChat(client, true, "{red}GOKZTop base URL not configured (gokztop-core missing?)");
        // If menu is pending, mark as fetched anyway
        if (g_bMenuPending[client])
        {
            g_bAggregatedRatingsFetched[client] = true;
            TryShowMenuWhenReady(client);
        }
        return;
    }

    Handle req = GOKZTop_CreateSteamWorksRequest(k_EHTTPMethodGET, url, false, 15);
    if (req == INVALID_HANDLE)
    {
        char msg[256];
        FormatEx(msg, sizeof(msg), "%T", "GOKZTop_FailedCreateRequest", client);
        GOKZ_PrintToChat(client, true, "%s", msg);
        // If menu is pending, mark as fetched anyway
        if (g_bMenuPending[client])
        {
            g_bAggregatedRatingsFetched[client] = true;
            TryShowMenuWhenReady(client);
        }
        return;
    }

    SteamWorks_SetHTTPRequestContextValue(req, GetClientUserId(client), Req_AggregatedRatings);
    SteamWorks_SetHTTPCallbacks(req, OnHTTPCompleted);
    SteamWorks_SendHTTPRequest(req);
}

static void SubmitRating(int client, int aspect, int rating)
{
    if (!GOKZTop_IsConfigured())
    {
        char msg[256];
        FormatEx(msg, sizeof(msg), "%T", "GOKZTop_MissingApiKey", client);
        GOKZ_PrintToChat(client, true, "%s", msg);
        return;
    }

    char steamid64[32];
    if (!GetClientAuthId(client, AuthId_SteamID64, steamid64, sizeof(steamid64), true))
    {
        GOKZ_PlayErrorSound(client);
        char msg[256];
        FormatEx(msg, sizeof(msg), "%T", "GOKZTop_SteamIdNotReady", client);
        GOKZ_PrintToChat(client, true, "%s", msg);
        return;
    }

    char mapName[PLATFORM_MAX_PATH];
    GetCurrentMapDisplayName(mapName, sizeof(mapName));

    char mapEnc[PLATFORM_MAX_PATH * 3];
    GOKZTop_UrlEncode(mapName, mapEnc, sizeof(mapEnc));

    char path[512];
    Format(path, sizeof(path), "/maps/%s/ratings", mapEnc);

    char query[128];
    Format(query, sizeof(query), "steamid64=%s", steamid64);

    char url[768];
    if (!GOKZTop_BuildApiUrl(url, sizeof(url), path, query))
    {
        GOKZ_PrintToChat(client, true, "{red}GOKZTop base URL not configured (gokztop-core missing?)");
        return;
    }

    if (aspect < 0 || aspect > 2)
    {
        aspect = Aspect_Overall;
    }

    char body[128];
    Format(body, sizeof(body), "{\"aspect\":\"%s\",\"rating\":%d}", g_AspectNames[aspect], rating);

    Handle req = GOKZTop_CreateSteamWorksRequest(k_EHTTPMethodPOST, url, true, 15);
    if (req == INVALID_HANDLE)
    {
        char msg[256];
        FormatEx(msg, sizeof(msg), "%T", "GOKZTop_FailedCreateRequest", client);
        GOKZ_PrintToChat(client, true, "%s", msg);
        return;
    }

    GOKZTop_SetJsonBody(req, body);

    int ctx2 = (Req_SubmitRating & 0xFF) | ((aspect & 0xFF) << 8) | ((rating & 0xFF) << 16);
    SteamWorks_SetHTTPRequestContextValue(req, GetClientUserId(client), ctx2);
    SteamWorks_SetHTTPCallbacks(req, OnHTTPCompleted);
    SteamWorks_SendHTTPRequest(req);
}

static void SubmitComment(int client, const char[] comment)
{
    if (!GOKZTop_IsConfigured())
    {
        char msg[256];
        FormatEx(msg, sizeof(msg), "%T", "GOKZTop_MissingApiKey", client);
        GOKZ_PrintToChat(client, true, "%s", msg);
        return;
    }

    char steamid64[32];
    if (!GetClientAuthId(client, AuthId_SteamID64, steamid64, sizeof(steamid64), true))
    {
        GOKZ_PlayErrorSound(client);
        char msg[256];
        FormatEx(msg, sizeof(msg), "%T", "GOKZTop_SteamIdNotReady", client);
        GOKZ_PrintToChat(client, true, "%s", msg);
        return;
    }

    char mapName[PLATFORM_MAX_PATH];
    GetCurrentMapDisplayName(mapName, sizeof(mapName));

    char mapEnc[PLATFORM_MAX_PATH * 3];
    GOKZTop_UrlEncode(mapName, mapEnc, sizeof(mapEnc));

    char path[512];
    Format(path, sizeof(path), "/maps/%s/comments", mapEnc);

    char query[128];
    Format(query, sizeof(query), "steamid64=%s", steamid64);

    char url[768];
    if (!GOKZTop_BuildApiUrl(url, sizeof(url), path, query))
    {
        GOKZ_PrintToChat(client, true, "{red}GOKZTop base URL not configured (gokztop-core missing?)");
        return;
    }

    char esc[512];
    GOKZTop_JsonEscapeString(comment, esc, sizeof(esc));

    char body[768];
    Format(body, sizeof(body), "{\"comment\":\"%s\"}", esc);

    Handle req = GOKZTop_CreateSteamWorksRequest(k_EHTTPMethodPOST, url, true, 15);
    if (req == INVALID_HANDLE)
    {
        char msg[256];
        FormatEx(msg, sizeof(msg), "%T", "GOKZTop_FailedCreateRequest", client);
        GOKZ_PrintToChat(client, true, "%s", msg);
        return;
    }

    GOKZTop_SetJsonBody(req, body);

    SteamWorks_SetHTTPRequestContextValue(req, GetClientUserId(client), Req_SubmitComment);
    SteamWorks_SetHTTPCallbacks(req, OnHTTPCompleted);
    SteamWorks_SendHTTPRequest(req);
}

static void FetchCommentsCount(int client)
{
    char mapName[PLATFORM_MAX_PATH];
    GetCurrentMapDisplayName(mapName, sizeof(mapName));

    char mapEnc[PLATFORM_MAX_PATH * 3];
    GOKZTop_UrlEncode(mapName, mapEnc, sizeof(mapEnc));

    char path[512];
    Format(path, sizeof(path), "/maps/%s/comments", mapEnc);

    char url[768];
    if (!GOKZTop_BuildApiUrl(url, sizeof(url), path))
    {
        // If base URL not configured, mark as fetched with 0 count
        g_bCommentsCountFetched[client] = true;
        g_iCommentsCount[client] = 0;
        TryShowMenuWhenReady(client);
        return;
    }

    Handle req = GOKZTop_CreateSteamWorksRequest(k_EHTTPMethodGET, url, false, 15);
    if (req == INVALID_HANDLE)
    {
        g_bCommentsCountFetched[client] = true;
        g_iCommentsCount[client] = 0;
        TryShowMenuWhenReady(client);
        return;
    }

    SteamWorks_SetHTTPRequestContextValue(req, GetClientUserId(client), Req_FetchCommentsCount);
    SteamWorks_SetHTTPCallbacks(req, OnHTTPCompleted);
    SteamWorks_SendHTTPRequest(req);
}

static void FetchComments(int client)
{
    char mapName[PLATFORM_MAX_PATH];
    GetCurrentMapDisplayName(mapName, sizeof(mapName));

    char mapEnc[PLATFORM_MAX_PATH * 3];
    GOKZTop_UrlEncode(mapName, mapEnc, sizeof(mapEnc));

    char path[512];
    Format(path, sizeof(path), "/maps/%s/comments", mapEnc);

    char url[768];
    if (!GOKZTop_BuildApiUrl(url, sizeof(url), path))
    {
        GOKZ_PrintToChat(client, true, "{red}GOKZTop base URL not configured (gokztop-core missing?)");
        return;
    }

    Handle req = GOKZTop_CreateSteamWorksRequest(k_EHTTPMethodGET, url, false, 15);
    if (req == INVALID_HANDLE)
    {
        GOKZ_PrintToChat(client, true, "{red}Failed to create HTTP request");
        return;
    }

    SteamWorks_SetHTTPRequestContextValue(req, GetClientUserId(client), Req_FetchComments);
    SteamWorks_SetHTTPCallbacks(req, OnHTTPCompleted);
    SteamWorks_SendHTTPRequest(req);
}

static void FetchMyRatingsIfNeeded(int client)
{
        // If menu is pending, we need to ensure ratings are fetched
        // So we'll mark as fetched if the fetch is skipped due to caching
        if (g_bMenuPending[client])
        {
            float now = GetGameTime();
            if (now - g_fLastMyRatingsFetchAt[client] < 10.0)
            {
                // Already cached, mark as fetched
                g_bMyRatingsFetched[client] = true;
                TryShowMenuWhenReady(client);
            }
        }
    FetchMyRatings(client, false);
}

static void FetchMyRatings(int client, bool force)
{
    float now = GetGameTime();
    if (!force)
    {
        if (now - g_fLastMyRatingsFetchAt[client] < 10.0)
        {
            // If menu is pending and we're using cached data, mark as fetched
            if (g_bMenuPending[client])
            {
                g_bMyRatingsFetched[client] = true;
                TryShowMenuWhenReady(client);
            }
            return;
        }
    }
    g_fLastMyRatingsFetchAt[client] = now;

    if (!GOKZTop_IsConfigured())
    {
        // If menu is pending but API not configured, mark as fetched anyway
        if (g_bMenuPending[client])
        {
            g_bMyRatingsFetched[client] = true;
            TryShowMenuWhenReady(client);
        }
        return;
    }

    char steamid64[32];
    if (!GetClientAuthId(client, AuthId_SteamID64, steamid64, sizeof(steamid64), true))
    {
        // If menu is pending but SteamID not ready, mark as fetched anyway
        if (g_bMenuPending[client])
        {
            g_bMyRatingsFetched[client] = true;
            TryShowMenuWhenReady(client);
        }
        return;
    }

    char mapName[PLATFORM_MAX_PATH];
    GetCurrentMapDisplayName(mapName, sizeof(mapName));

    char mapEnc[PLATFORM_MAX_PATH * 3];
    GOKZTop_UrlEncode(mapName, mapEnc, sizeof(mapEnc));

    char path[512];
    Format(path, sizeof(path), "/maps/%s/ratings", mapEnc);

    char query[128];
    Format(query, sizeof(query), "steamid64=%s", steamid64);

    char url[768];
    if (!GOKZTop_BuildApiUrl(url, sizeof(url), path, query))
    {
        // If menu is pending but URL build failed, mark as fetched anyway
        if (g_bMenuPending[client])
        {
            g_bMyRatingsFetched[client] = true;
            TryShowMenuWhenReady(client);
        }
        return;
    }

    Handle req = GOKZTop_CreateSteamWorksRequest(k_EHTTPMethodGET, url, true, 15);
    if (req == INVALID_HANDLE)
    {
        // If menu is pending but request creation failed, mark as fetched anyway
        if (g_bMenuPending[client])
        {
            g_bMyRatingsFetched[client] = true;
            TryShowMenuWhenReady(client);
        }
        return;
    }

    SteamWorks_SetHTTPRequestContextValue(req, GetClientUserId(client), Req_MyRatings);
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

    if (!client || !IsValidClient(client))
    {
        return;
    }

    if (bFailure || !bRequestSuccessful || status < 200 || status >= 300)
    {
        if (reqType == Req_MyRatings && client && IsValidClient(client) && g_bRatePromptPending[client])
        {
            g_bRatePromptPending[client] = false;
            g_fRatePromptRequestedAt[client] = 0.0;
        }

        char detail[256] = "";
        ExtractErrorDetail(body, detail, sizeof(detail));
        if (detail[0] != '\0')
        {
            GOKZ_PrintToChat(client, true, "{red}%s", detail);
        }
        else
        {
            // If we got HTML, this is almost always wrong gokztop_base_url (or double /api/v1).
            if (body[0] != '\0' && !GOKZTop_LooksLikeJson(body))
            {
                char msg[256];
                FormatEx(msg, sizeof(msg), "%T", "GOKZTop_NonJsonResponse", client, status);
                GOKZ_PrintToChat(client, true, "%s", msg);
                LogMessage("[gokztop] Non-JSON response (status %d). Body starts with: %.64s", status, body);
            }
            else
            {
                char msg[256];
                FormatEx(msg, sizeof(msg), "%T", "GOKZTop_HttpErrorGeneric", client, status);
                GOKZ_PrintToChat(client, true, "%s", msg);
            }
        }
        return;
    }

    switch (reqType)
    {
        case Req_AggregatedRatings:
        {
            if (!GOKZTop_LooksLikeJson(body))
            {
                LogMessage("[gokztop] Expected JSON for aggregated ratings, got: %.64s", body);
                g_bAggregatedRatingsFetched[client] = true;
                TryShowMenuWhenReady(client);
                return;
            }
            Handle json = json_load(body);
            if (json == INVALID_HANDLE || !json_is_array(json))
            {
                if (json != INVALID_HANDLE) delete json;
                g_bAggregatedRatingsFetched[client] = true;
                TryShowMenuWhenReady(client);
                return;
            }

            float ratings[3];
            int counts[3];
            for (int i = 0; i < 3; i++) { ratings[i] = -1.0; counts[i] = 0; }

            int n = json_array_size(json);
            for (int i = 0; i < n; i++)
            {
                Handle row = json_array_get(json, i);
                if (row == INVALID_HANDLE || !json_is_object(row)) continue;

                char aspect[16];
                if (!json_object_get_string(row, "aspect", aspect, sizeof(aspect))) continue;
                float rating = json_object_get_float(row, "rating");
                int count = json_object_get_int(row, "rating_count");

                int idx = ParseAspect(aspect);
                if (idx >= 0 && idx <= 2)
                {
                    ratings[idx] = rating;
                    counts[idx] = count;
                }
            }

            delete json;

            char mapName[PLATFORM_MAX_PATH];
            GetCurrentMapDisplayName(mapName, sizeof(mapName));

            // Cache for menu display (only if still on same map)
            strcopy(g_sCachedMapName, sizeof(g_sCachedMapName), mapName);
            for (int a = 0; a < 3; a++)
            {
                g_fAvgRating[a] = ratings[a];
                g_iAvgCount[a] = counts[a];
            }

            // Mark aggregated ratings as fetched
            g_bAggregatedRatingsFetched[client] = true;
            TryShowMenuWhenReady(client);

            // Only print ratings in chat if NOT fetching for menu (i.e., when player spawns)
            if (!g_bMenuPending[client])
            {
                // Print three lines, one for each aspect, in order: overall, gameplay, visuals
                char header[128];
                Format(header, sizeof(header), "{lime}%s{default} ratings:", mapName);
                GOKZ_PrintToChat(client, true, "%s", header);
                
                bool bAny = false;
                // Order: overall (1), gameplay (2), visuals (0)
                int order[3] = {Aspect_Overall, Aspect_Gameplay, Aspect_Visuals};
                for (int i = 0; i < 3; i++)
                {
                    int idx = order[i];
                    if (counts[idx] <= 0 || ratings[idx] < 0.0) continue;
                    bAny = true;
                    char stars[16];
                    BuildStarsFloat(ratings[idx], stars, sizeof(stars));
                    char line[256];
                    Format(line, sizeof(line), "  {gold}%s{default} %.2f %s ({gold}%d{default})", g_AspectNames[idx], ratings[idx], stars, counts[idx]);
                    GOKZ_PrintToChat(client, true, "%s", line);
                }
                if (!bAny)
                {
                    char msg[256];
                    FormatEx(msg, sizeof(msg), "%T", "GOKZTop_NoRatingsYet", client, mapName);
                    GOKZ_PrintToChat(client, true, "%s", msg);
                }
            }
        }

        case Req_MyRatings:
        {
            if (!GOKZTop_LooksLikeJson(body))
            {
                g_bMyRatingsFetched[client] = true;
                TryShowMenuWhenReady(client);
                return;
            }

            Handle json = json_load(body);
            if (json == INVALID_HANDLE || !json_is_array(json))
            {
                if (json != INVALID_HANDLE) delete json;
                g_bMyRatingsFetched[client] = true;
                TryShowMenuWhenReady(client);
                return;
            }

            // Reset then fill.
            g_iMyRating[client][Aspect_Overall] = 0;
            g_iMyRating[client][Aspect_Gameplay] = 0;
            g_iMyRating[client][Aspect_Visuals] = 0;

            int n = json_array_size(json);
            for (int i = 0; i < n; i++)
            {
                Handle row = json_array_get(json, i);
                if (row == INVALID_HANDLE || !json_is_object(row)) continue;

                char aspect[16];
                if (!json_object_get_string(row, "aspect", aspect, sizeof(aspect))) continue;
                int idx = ParseAspect(aspect);
                if (idx < 0 || idx > 2) continue;

                int rating = json_object_get_int(row, "rating");
                if (rating >= 1 && rating <= 5)
                {
                    g_iMyRating[client][idx] = rating;
                }
            }

            delete json;

            // Mark my ratings as fetched
            g_bMyRatingsFetched[client] = true;
            TryShowMenuWhenReady(client);

            // If we were waiting to decide whether to prompt, do it now.
            if (g_bRatePromptPending[client] && !g_bRateReminderSent[client])
            {
                // Don't let an old pending request prompt much later (e.g. reconnect delays).
                if (GetGameTime() - g_fRatePromptRequestedAt[client] <= 30.0)
                {
                    bool hasAnyRating =
                        (g_iMyRating[client][Aspect_Overall] > 0
                        || g_iMyRating[client][Aspect_Gameplay] > 0
                        || g_iMyRating[client][Aspect_Visuals] > 0);

                    if (!hasAnyRating)
                    {
                        g_bRateReminderSent[client] = true;
                        char msg[256];
                        FormatEx(msg, sizeof(msg), "%T", "GOKZTop_RatePrompt", client);
                        GOKZ_PrintToChat(client, true, "%s", msg);
                    }
                }
                g_bRatePromptPending[client] = false;
                g_fRatePromptRequestedAt[client] = 0.0;
            }
        }

        case Req_SubmitRating:
        {
            // Decode packed aspect/rating from data2.
            int aspect = (data2 >> 8) & 0xFF;
            int rating = (data2 >> 16) & 0xFF;
            if (aspect >= 0 && aspect <= 2 && rating >= 1 && rating <= 5)
            {
                g_iMyRating[client][aspect] = rating;
            }
            char msg[128];
            FormatEx(msg, sizeof(msg), "%T", "GOKZTop_RatingSaved", client);
            GOKZ_PrintToChat(client, true, "%s", msg);
        }

        case Req_SubmitComment:
        {
            char msg[128];
            FormatEx(msg, sizeof(msg), "%T", "GOKZTop_CommentSaved", client);
            GOKZ_PrintToChat(client, true, "%s", msg);
        }

        case Req_FetchCommentsCount:
        {
            if (!GOKZTop_LooksLikeJson(body))
            {
                g_bCommentsCountFetched[client] = true;
                g_iCommentsCount[client] = 0;
                TryShowMenuWhenReady(client);
                return;
            }
            
            Handle root = json_load(body);
            if (root == INVALID_HANDLE || !json_is_object(root))
            {
                if (root != INVALID_HANDLE) delete root;
                g_bCommentsCountFetched[client] = true;
                g_iCommentsCount[client] = 0;
                TryShowMenuWhenReady(client);
                return;
            }

            // Parse new format: { "data": [...], "count": 2 }
            int count = json_object_get_int(root, "count");
            g_iCommentsCount[client] = count;
            g_bCommentsCountFetched[client] = true;
            
            delete root;
            TryShowMenuWhenReady(client);
        }

        case Req_FetchComments:
        {
            if (!GOKZTop_LooksLikeJson(body))
            {
                GOKZ_PrintToChat(client, true, "{red}Comments response was not JSON. Check {gold}gokztop_base_url{red}.");
                LogMessage("[gokztop] Expected JSON for comments, got: %.64s", body);
                return;
            }
            ShowCommentsMenuFromJson(client, body);
        }
    }
}

static void TryShowMenuWhenReady(int client)
{
    if (!g_bMenuPending[client]) return;
    
    // Wait for aggregated ratings, my ratings, and comments count to be fetched
    if (!g_bAggregatedRatingsFetched[client] || !g_bMyRatingsFetched[client] || !g_bCommentsCountFetched[client])
    {
        return;
    }
    
    // All data fetched, show menu
    g_bMenuPending[client] = false;
    ShowRateMenu_Main(client);
}

static void ShowCommentsMenuFromJson(int client, const char[] body)
{
    if (!GOKZTop_LooksLikeJson(body))
    {
        GOKZ_PrintToChat(client, true, "{red}Comments response was not JSON. Check {gold}gokztop_base_url{red}.");
        return;
    }
    Handle root = json_load(body);
    if (root == INVALID_HANDLE || !json_is_object(root))
    {
        if (root != INVALID_HANDLE) delete root;
        GOKZ_PrintToChat(client, true, "{red}Failed to parse comments response");
        return;
    }

    // Parse new format: { "data": [...], "count": 2 }
    Handle data = json_object_get(root, "data");
    if (data == INVALID_HANDLE || !json_is_array(data))
    {
        delete root;
        GOKZ_PrintToChat(client, true, "{red}No comments found");
        return;
    }

    char mapName[PLATFORM_MAX_PATH];
    GetCurrentMapDisplayName(mapName, sizeof(mapName));

    Menu menu = new Menu(MenuHandler_Comments);
    char title[160];
    FormatEx(title, sizeof(title), "%T", "GOKZTop_Menu_CommentsTitle", client, mapName);
    menu.SetTitle(title);
    menu.ExitButton = true;
    menu.ExitBackButton = false;
    menu.Pagination = 6;

    int n = json_array_size(data);
    if (n <= 0)
    {
        char t[64];
        FormatEx(t, sizeof(t), "%T", "GOKZTop_NoCommentsYet", client);
        menu.AddItem("", t, ITEMDRAW_DISABLED);
        menu.Display(client, 0);
        delete root;
        return;
    }

    for (int i = 0; i < n; i++)
    {
        Handle row = json_array_get(data, i);
        if (row == INVALID_HANDLE || !json_is_object(row)) continue;

        char name[64];
        if (!json_object_get_string(row, "player_name", name, sizeof(name)) || name[0] == '\0')
        {
            json_object_get_string(row, "steamid64", name, sizeof(name));
        }

        char comment[128] = "";
        json_object_get_string(row, "comment", comment, sizeof(comment));

        int overall = 0;
        Handle ratings = json_object_get(row, "ratings");
        if (ratings != INVALID_HANDLE && json_is_array(ratings))
        {
            int rn = json_array_size(ratings);
            for (int r = 0; r < rn; r++)
            {
                Handle rr = json_array_get(ratings, r);
                if (rr == INVALID_HANDLE || !json_is_object(rr)) continue;

                char aspect[16];
                if (!json_object_get_string(rr, "aspect", aspect, sizeof(aspect))) continue;
                if (StrEqual(aspect, "overall", false))
                {
                    overall = json_object_get_int(rr, "rating");
                    break;
                }
            }
        }

        char stars[16];
        BuildStarsInt(overall, stars, sizeof(stars));

        char line[192];
        if (comment[0] != '\0')
        {
            Format(line, sizeof(line), "%s  %s  |  %s", stars, name, comment);
        }
        else
        {
            Format(line, sizeof(line), "%s  %s", stars, name);
        }

        menu.AddItem("row", line, ITEMDRAW_DISABLED);
    }

    menu.Display(client, 0);
    delete root;
    if (data != INVALID_HANDLE) delete data;
}

public int MenuHandler_Comments(Menu menu, MenuAction action, int param1, int param2)
{
    if (action == MenuAction_End) delete menu;
    return 0;
}

// ──────────────────────────────────────────────────────────────────────────────
// Helpers
// ──────────────────────────────────────────────────────────────────────────────
static bool IsNumeric(const char[] s)
{
    if (s[0] == '\0') return false;
    for (int i = 0; s[i] != '\0'; i++)
    {
        if (s[i] < '0' || s[i] > '9') return false;
    }
    return true;
}

static bool IsValidRating(int rating)
{
    return rating >= 1 && rating <= 5;
}

static int ParseAspect(const char[] s)
{
    if (StrEqual(s, "visuals", false)) return Aspect_Visuals;
    if (StrEqual(s, "overall", false)) return Aspect_Overall;
    if (StrEqual(s, "gameplay", false)) return Aspect_Gameplay;
    return -1;
}

static void ExtractTailComment(int argc, int skipArgs, char[] out, int maxlen)
{
    out[0] = '\0';
    if (argc <= skipArgs) return;

    char full[512];
    GetCmdArgString(full, sizeof(full));
    TrimString(full);

    // Strip first N tokens
    int tokensToSkip = skipArgs;
    int pos = 0;
    bool inToken = false;
    while (full[pos] != '\0' && tokensToSkip > 0)
    {
        if (full[pos] != ' ' && !inToken)
        {
            inToken = true;
        }
        else if (full[pos] == ' ' && inToken)
        {
            inToken = false;
            tokensToSkip--;
        }
        pos++;
    }

    while (full[pos] == ' ') pos++;
    strcopy(out, maxlen, full[pos]);
    TrimString(out);
}

static void BuildStarsInt(int rating, char[] buffer, int maxlen)
{
    buffer[0] = '\0';
    if (rating < 0) rating = 0;
    if (rating > 5) rating = 5;

    char FILLED[] = "★";
    char EMPTY[] = "☆";

    for (int i = 0; i < rating; i++) StrCat(buffer, maxlen, FILLED);
    for (int i = rating; i < 5; i++) StrCat(buffer, maxlen, EMPTY);
}

static void BuildStarsFloat(float rating, char[] buffer, int maxlen)
{
    int r = RoundToNearest(rating);
    BuildStarsInt(r, buffer, maxlen);
}

static void BuildAspectLine(int client, int aspect, const char[] label, char[] out, int maxlen)
{
    int r = 0;
    if (client > 0 && client <= MaxClients && aspect >= 0 && aspect <= 2)
    {
        r = g_iMyRating[client][aspect];
    }

    char stars[16];
    BuildStarsInt(r, stars, sizeof(stars));

    // Pad label so stars align.
    // We want:
    // Overall   ★★★★★
    // Gameplay  ★★★★★
    // Visuals   ★★★★★
    const int PAD = 8; // longest in English is "Gameplay" (8); translations may vary

    char padded[32];
    strcopy(padded, sizeof(padded), label);
    int len = strlen(padded);
    while (len < PAD && len + 1 < sizeof(padded))
    {
        padded[len++] = ' ';
        padded[len] = '\0';
    }

    Format(out, maxlen, "%s  %s", padded, stars);
}

static void GetAspectLabel(int client, int aspect, char[] out, int maxlen)
{
    if (aspect == Aspect_Overall)
        FormatEx(out, maxlen, "%T", "GOKZTop_Menu_LabelOverall", client);
    else if (aspect == Aspect_Gameplay)
        FormatEx(out, maxlen, "%T", "GOKZTop_Menu_LabelGameplay", client);
    else
        FormatEx(out, maxlen, "%T", "GOKZTop_Menu_LabelVisuals", client);
}

static void ExtractErrorDetail(const char[] body, char[] out, int maxlen)
{
    out[0] = '\0';
    if (body[0] == '\0') return;

    if (!GOKZTop_LooksLikeJson(body))
    {
        // Avoid SMJSON error spam when server returns HTML (e.g. 404 page, Cloudflare, etc.)
        return;
    }

    Handle root = json_load(body);
    if (root == INVALID_HANDLE || !json_is_object(root))
    {
        if (root != INVALID_HANDLE) delete root;
        return;
    }

    json_object_get_string(root, "detail", out, maxlen);
    delete root;
    TrimString(out);
}
