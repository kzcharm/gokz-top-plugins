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

#include <gokz-top>

#pragma semicolon 1
#pragma newdecls required

public Plugin myinfo =
{
    name        = "GOKZ.TOP Map Ratings",
    author      = "Cinyan10",
    description = "Rate maps (visuals/overall/gameplay) and leave a review comment via gokz.top API",
    version     = "3.0.0"
};

enum
{
    Req_MapReviewsSummary = 1,
    Req_MyReview,
    Req_SubmitReview,
    Req_FetchComments
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

// Global reusable prefix
static const char GOKZTOP_PREFIX[] = "{gold}GOKZ.TOP {grey}| ";

static bool g_bRateReminderSent[MAXPLAYERS + 1];
static bool g_bRatePromptPending[MAXPLAYERS + 1];
static float g_fRatePromptRequestedAt[MAXPLAYERS + 1];
static int g_iActiveAspectMenu[MAXPLAYERS + 1];
static bool g_bCaptureComment[MAXPLAYERS + 1];
static bool g_bMenuPending[MAXPLAYERS + 1];
static bool g_bSubmitInFlight[MAXPLAYERS + 1];
static int g_iSubmitPendingFlags[MAXPLAYERS + 1];
static bool g_bReopenMenuAfterSubmit[MAXPLAYERS + 1];
static int g_iSummaryPrintAttempts[MAXPLAYERS + 1];

// Cached aggregated ratings (per-map; updated on fetch)
static char g_sCachedMapName[PLATFORM_MAX_PATH];
static float g_fAvgRating[3];
static int g_iAvgCount[3];
static int g_iMapCommentCount = -1;
static bool g_bSummaryFetched = false;
static bool g_bSummaryFetchInFlight = false;

// Per-player last known ratings (0=unknown/unset)
static int g_iMyRating[MAXPLAYERS + 1][3];
static char g_sMyComment[MAXPLAYERS + 1][256];
static bool g_bMyReviewFetched[MAXPLAYERS + 1];
static float g_fLastMyReviewFetchAt[MAXPLAYERS + 1];

// Per-player draft (menu edits). Only dirty fields are submitted.
static int g_iDraftRating[MAXPLAYERS + 1][3];
static bool g_bDraftDirtyRating[MAXPLAYERS + 1][3];
static char g_sDraftComment[MAXPLAYERS + 1][256];
static bool g_bDraftDirtyComment[MAXPLAYERS + 1];

// ──────────────────────────────────────────────────────────────────────────────
// Lifecycle
// ──────────────────────────────────────────────────────────────────────────────
public void OnPluginStart()
{
    LoadTranslations("gokz-top-map-ratings.phrases");

    RegConsoleCmd("sm_rate", Command_Rate, "Usage: !rate [<1-5>|<aspect> <1-5>] [comment]");
    RegConsoleCmd("sm_review", Command_Rate, "Alias for !rate (opens review menu)");
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
        g_bSubmitInFlight[i] = false;
        g_iSubmitPendingFlags[i] = 0;
        g_bReopenMenuAfterSubmit[i] = false;
        g_iSummaryPrintAttempts[i] = 0;
        g_bMyReviewFetched[i] = false;
        g_iMyRating[i][0] = 0;
        g_iMyRating[i][1] = 0;
        g_iMyRating[i][2] = 0;
        g_sMyComment[i][0] = '\0';
        g_fLastMyReviewFetchAt[i] = 0.0;

        for (int a = 0; a < 3; a++)
        {
            g_iDraftRating[i][a] = 0;
            g_bDraftDirtyRating[i][a] = false;
        }
        g_sDraftComment[i][0] = '\0';
        g_bDraftDirtyComment[i] = false;
    }

    g_sCachedMapName[0] = '\0';
    for (int a = 0; a < 3; a++)
    {
        g_fAvgRating[a] = -1.0;
        g_iAvgCount[a] = 0;
    }

    g_iMapCommentCount = -1;
    g_bSummaryFetched = false;
    g_bSummaryFetchInFlight = false;

    // Fetch map review summary once per map.
    FetchMapReviewsSummary();
}

// ──────────────────────────────────────────────────────────────────────────────
// GOKZ events
// ──────────────────────────────────────────────────────────────────────────────
public void GOKZ_OnFirstSpawn(int client)
{
    if (!IsValidClient(client)) return;
    CreateTimer(2.0, Timer_PrintSummary, GetClientUserId(client));
}

public Action Timer_PrintSummary(Handle timer, any userid)
{
    int client = GetClientOfUserId(userid);
    if (!IsValidClient(client)) return Plugin_Stop;
    if (!g_bSummaryFetched)
    {
        if (!g_bSummaryFetchInFlight) FetchMapReviewsSummary();
        if (g_iSummaryPrintAttempts[client] < 3)
        {
            g_iSummaryPrintAttempts[client]++;
            CreateTimer(2.0, Timer_PrintSummary, userid);
        }
        return Plugin_Stop;
    }
    PrintMapReviewsSummary(client);
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

    // Only prompt if we can determine the player has not reviewed this map yet.
    // We do this by fetching their existing review and then deciding in Req_MyReview.
    bool hasAny =
        (g_iMyRating[client][Aspect_Overall] > 0
        || g_iMyRating[client][Aspect_Gameplay] > 0
        || g_iMyRating[client][Aspect_Visuals] > 0
        || g_sMyComment[client][0] != '\0');
    if (hasAny) return Plugin_Stop;

    // Mark pending and fetch ratings now (forced), then decide when the response arrives.
    g_bRatePromptPending[client] = true;
    g_fRatePromptRequestedAt[client] = GetGameTime();
    FetchMyReview(client, true);
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
        // Fetch player review (prefill) and ensure summary is available, then show menu when ready
        g_bMenuPending[client] = true;
        g_bMyReviewFetched[client] = false;

        if (!g_bSummaryFetched && !g_bSummaryFetchInFlight)
        {
            FetchMapReviewsSummary();
        }
        FetchMyReview(client, true);
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
            GOKZ_PrintToChat(client, false, "%s%s", GOKZTOP_PREFIX, msg);
            return Plugin_Handled;
        }

        char comment[256];
        ExtractTailComment(args, 1, comment, sizeof(comment));
        ResetDraft(client);
        g_iDraftRating[client][Aspect_Overall] = rating;
        g_bDraftDirtyRating[client][Aspect_Overall] = true;
        if (comment[0] != '\0')
        {
            strcopy(g_sDraftComment[client], sizeof(g_sDraftComment[]), comment);
            g_bDraftDirtyComment[client] = true;
        }
        SubmitDraftReview(client);

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
            GOKZ_PrintToChat(client, false, "%s%s", GOKZTOP_PREFIX, msg);
            return Plugin_Handled;
        }

        char arg2[16];
        GetCmdArg(2, arg2, sizeof(arg2));
        if (!IsNumeric(arg2))
        {
            GOKZ_PlayErrorSound(client);
            char msg[256];
            FormatEx(msg, sizeof(msg), "%T", "GOKZTop_RateAspectUsage", client);
            GOKZ_PrintToChat(client, false, "%s%s", GOKZTOP_PREFIX, msg);
            return Plugin_Handled;
        }

        int rating = StringToInt(arg2);
        if (!IsValidRating(rating))
        {
            GOKZ_PlayErrorSound(client);
            char msg[256];
            FormatEx(msg, sizeof(msg), "%T", "GOKZTop_RatingRangeError", client);
            GOKZ_PrintToChat(client, false, "%s%s", GOKZTOP_PREFIX, msg);
            return Plugin_Handled;
        }

        char comment[256];
        ExtractTailComment(args, 2, comment, sizeof(comment));
        ResetDraft(client);
        g_iDraftRating[client][aspect] = rating;
        g_bDraftDirtyRating[client][aspect] = true;
        if (comment[0] != '\0')
        {
            strcopy(g_sDraftComment[client], sizeof(g_sDraftComment[]), comment);
            g_bDraftDirtyComment[client] = true;
        }
        SubmitDraftReview(client);

        return Plugin_Handled;
    }

    {
        char msg[256];
        FormatEx(msg, sizeof(msg), "%T", "GOKZTop_RateUsage", client);
        GOKZ_PrintToChat(client, false, "%s%s", GOKZTOP_PREFIX, msg);
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

    // Handle cancel commands
    if (StrEqual(msg, "!cancel", false) || StrEqual(msg, "/cancel", false))
    {
        g_bCaptureComment[client] = false;
        char t[256];
        FormatEx(t, sizeof(t), "%T", "GOKZTop_CommentCancelled", client);
        GOKZ_PrintToChat(client, false, "%s%s", GOKZTOP_PREFIX, t);
        ShowRateMenu_Main(client);
        return Plugin_Handled;
    }

    // Filter out commands starting with !, /, . and "rtv" (case-insensitive)
    char firstChar = msg[0];
    if (firstChar == '!' || firstChar == '/' || firstChar == '.')
    {
        // Let the command go through normally
        return Plugin_Continue;
    }
    
    // Check if message starts with "rtv" (case-insensitive)
    if (strlen(msg) >= 3)
    {
        char first = msg[0];
        char second = msg[1];
        char third = msg[2];
        if ((first == 'r' || first == 'R') && 
            (second == 't' || second == 'T') && 
            (third == 'v' || third == 'V'))
        {
            // Let the command go through normally
            return Plugin_Continue;
        }
    }

    g_bCaptureComment[client] = false;

    // Store draft comment and submit review immediately (comment submit path)
    strcopy(g_sDraftComment[client], sizeof(g_sDraftComment[]), msg);
    g_bDraftDirtyComment[client] = true;
    SubmitDraftReview(client);
    if (g_bSubmitInFlight[client])
    {
        g_bReopenMenuAfterSubmit[client] = true;
    }
    else
    {
        // If we didn't submit (e.g. missing API key), reopen menu so the player isn't left hanging.
        ShowRateMenu_Main(client);
    }

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
    if (g_iMapCommentCount >= 0)
    {
        Format(viewCommentsText, sizeof(viewCommentsText), "%s (%d)", viewCommentsText, g_iMapCommentCount);
    }
    
    // Disable view comments if no comments available
    int drawStyle = ITEMDRAW_DEFAULT;
    if (g_iMapCommentCount == 0)
    {
        drawStyle = ITEMDRAW_DISABLED;
    }
    menu.AddItem("view_comments", viewCommentsText, drawStyle);
    
    // Add submit review menu item
    char submitText[128];
    FormatEx(submitText, sizeof(submitText), "%T", "GOKZTop_Menu_SubmitReview", client);
    menu.AddItem("submit_review", submitText);

    menu.Display(client, 0);
}

public int MenuHandler_RateMain(Menu menu, MenuAction action, int client, int item)
{
    if (action == MenuAction_End)
    {
        delete menu;
        return 0;
    }

    if (action == MenuAction_Cancel)
    {
        // Exit button: submit draft review if player changed anything in this menu session.
        if (item == MenuCancel_Exit)
        {
            SubmitDraftReview(client);
        }
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
        GOKZ_PrintToChat(client, false, "%s%s", GOKZTOP_PREFIX, msg);
        char cancelMsg[256];
        FormatEx(cancelMsg, sizeof(cancelMsg), "%T", "GOKZTop_CommentCancelHint", client);
        GOKZ_PrintToChat(client, false, "%s%s", GOKZTOP_PREFIX, cancelMsg);
    }
    else if (StrEqual(info, "view_comments"))
    {
        FetchComments(client);
    }
    else if (StrEqual(info, "submit_review"))
    {
        SubmitDraftReview(client);
        ShowRateMenu_Main(client);
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
        else if (item == MenuCancel_Exit)
        {
            // Exiting from a sub-menu still counts as quitting the menu flow.
            SubmitDraftReview(client);
        }
        return 0;
    }

    if (action != MenuAction_Select) return 0;

    char info[8];
    menu.GetItem(item, info, sizeof(info));
    int rating = StringToInt(info);

    int idx = g_iActiveAspectMenu[client];
    if (idx < 0 || idx > 2) idx = 0;

    g_iDraftRating[client][idx] = rating;
    g_bDraftDirtyRating[client][idx] = true;
    ShowRateMenu_Main(client);
    return 0;
}

// ──────────────────────────────────────────────────────────────────────────────
// API calls
// ──────────────────────────────────────────────────────────────────────────────
static void ResetDraft(int client)
{
    if (client <= 0 || client > MaxClients) return;
    for (int a = 0; a < 3; a++)
    {
        g_iDraftRating[client][a] = 0;
        g_bDraftDirtyRating[client][a] = false;
    }
    g_sDraftComment[client][0] = '\0';
    g_bDraftDirtyComment[client] = false;
}

static void InitDraftFromMyReview(int client)
{
    if (client <= 0 || client > MaxClients) return;
    for (int a = 0; a < 3; a++)
    {
        g_iDraftRating[client][a] = g_iMyRating[client][a];
        g_bDraftDirtyRating[client][a] = false;
    }
    strcopy(g_sDraftComment[client], sizeof(g_sDraftComment[]), g_sMyComment[client]);
    g_bDraftDirtyComment[client] = false;
}

static void FetchMapReviewsSummary()
{
    if (g_bSummaryFetchInFlight) return;
    g_bSummaryFetchInFlight = true;

    char mapName[PLATFORM_MAX_PATH];
    GetCurrentMapDisplayName(mapName, sizeof(mapName));

    char mapEnc[PLATFORM_MAX_PATH * 3];
    GOKZTop_UrlEncode(mapName, mapEnc, sizeof(mapEnc));

    char path[128];
    strcopy(path, sizeof(path), "/maps/reviews/summary");

    char query[768];
    Format(query, sizeof(query), "map_name=%s&limit=1&offset=0", mapEnc);

    char url[1024];
    if (!GOKZTop_BuildApiUrl(url, sizeof(url), path, query))
    {
        g_bSummaryFetchInFlight = false;
        return;
    }

    Handle req = GOKZTop_CreateSteamWorksRequest(k_EHTTPMethodGET, url, false, 15);
    if (req == INVALID_HANDLE)
    {
        g_bSummaryFetchInFlight = false;
        return;
    }

    SteamWorks_SetHTTPRequestContextValue(req, 0, Req_MapReviewsSummary);
    SteamWorks_SetHTTPCallbacks(req, OnHTTPCompleted);
    SteamWorks_SendHTTPRequest(req);
}

static void PrintMapReviewsSummary(int client)
{
    if (!IsValidClient(client)) return;

    if (!g_bSummaryFetched)
    {
        if (!g_bSummaryFetchInFlight) FetchMapReviewsSummary();
        return;
    }

    char mapName[PLATFORM_MAX_PATH];
    GetCurrentMapDisplayName(mapName, sizeof(mapName));

    // Print three lines, one for each aspect, in order: overall, gameplay, visuals
    char header[160];
    Format(header, sizeof(header), "{lime}%s{default} reviews summary:", mapName);
    GOKZ_PrintToChat(client, false, "%s%s", GOKZTOP_PREFIX, header);

    bool bAny = false;
    int order[3] = {Aspect_Overall, Aspect_Gameplay, Aspect_Visuals};
    for (int i = 0; i < 3; i++)
    {
        int idx = order[i];
        if (g_iAvgCount[idx] <= 0 || g_fAvgRating[idx] < 0.0) continue;
        bAny = true;
        char stars[16];
        BuildStarsFloat(g_fAvgRating[idx], stars, sizeof(stars));
        char line[256];
        Format(line, sizeof(line), "  {gold}%s{default} %.2f %s ({gold}%d{default})", g_AspectNames[idx], g_fAvgRating[idx], stars, g_iAvgCount[idx]);
        GOKZ_PrintToChat(client, false, "%s%s", GOKZTOP_PREFIX, line);
    }
    if (!bAny)
    {
        char msg[256];
        FormatEx(msg, sizeof(msg), "%T", "GOKZTop_NoRatingsYet", client, mapName);
        GOKZ_PrintToChat(client, false, "%s%s", GOKZTOP_PREFIX, msg);
    }
    else if (g_iMapCommentCount >= 0)
    {
        char cLine[128];
        Format(cLine, sizeof(cLine), "  {gold}comments{default}: {gold}%d{default}", g_iMapCommentCount);
        GOKZ_PrintToChat(client, false, "%s%s", GOKZTOP_PREFIX, cLine);
    }
}

static void FetchMyReview(int client, bool force)
{
    float now = GetGameTime();
    if (!force && (now - g_fLastMyReviewFetchAt[client] < 10.0))
    {
        if (g_bMenuPending[client])
        {
            g_bMyReviewFetched[client] = true;
            TryShowMenuWhenReady(client);
        }
        return;
    }
    g_fLastMyReviewFetchAt[client] = now;

    char steamid64[32];
    if (!GetClientAuthId(client, AuthId_SteamID64, steamid64, sizeof(steamid64), true))
    {
        if (g_bMenuPending[client])
        {
            g_bMyReviewFetched[client] = true;
            TryShowMenuWhenReady(client);
        }
        return;
    }

    char mapName[PLATFORM_MAX_PATH];
    GetCurrentMapDisplayName(mapName, sizeof(mapName));

    char mapEnc[PLATFORM_MAX_PATH * 3];
    GOKZTop_UrlEncode(mapName, mapEnc, sizeof(mapEnc));

    char path[128];
    strcopy(path, sizeof(path), "/maps/reviews");

    char query[256];
    Format(query, sizeof(query), "map_name=%s&steamid64=%s&limit=1&offset=0", mapEnc, steamid64);

    char url[1024];
    if (!GOKZTop_BuildApiUrl(url, sizeof(url), path, query))
    {
        if (g_bMenuPending[client])
        {
            g_bMyReviewFetched[client] = true;
            TryShowMenuWhenReady(client);
        }
        return;
    }

    Handle req = GOKZTop_CreateSteamWorksRequest(k_EHTTPMethodGET, url, false, 15);
    if (req == INVALID_HANDLE)
    {
        if (g_bMenuPending[client])
        {
            g_bMyReviewFetched[client] = true;
            TryShowMenuWhenReady(client);
        }
        return;
    }

    SteamWorks_SetHTTPRequestContextValue(req, GetClientUserId(client), Req_MyReview);
    SteamWorks_SetHTTPCallbacks(req, OnHTTPCompleted);
    SteamWorks_SendHTTPRequest(req);
}

static bool BuildDraftReviewBody(int client, char[] out, int maxlen, int &flags)
{
    flags = 0;
    const int FLAG_OVERALL = (1 << 0);
    const int FLAG_GAMEPLAY = (1 << 1);
    const int FLAG_VISUALS = (1 << 2);
    const int FLAG_COMMENT = (1 << 3);

    bool first = true;
    out[0] = '{';
    out[1] = '\0';

    if (g_bDraftDirtyRating[client][Aspect_Overall])
    {
        int rating = g_iDraftRating[client][Aspect_Overall];
        if (IsValidRating(rating))
        {
            Format(out, maxlen, "%s\"overall\":%d", out, rating);
            first = false;
            flags |= FLAG_OVERALL;
        }
    }
    if (g_bDraftDirtyRating[client][Aspect_Gameplay])
    {
        int rating = g_iDraftRating[client][Aspect_Gameplay];
        if (IsValidRating(rating))
        {
            Format(out, maxlen, "%s%s\"gameplay\":%d", out, first ? "" : ",", rating);
            first = false;
            flags |= FLAG_GAMEPLAY;
        }
    }
    if (g_bDraftDirtyRating[client][Aspect_Visuals])
    {
        int rating = g_iDraftRating[client][Aspect_Visuals];
        if (IsValidRating(rating))
        {
            Format(out, maxlen, "%s%s\"visuals\":%d", out, first ? "" : ",", rating);
            first = false;
            flags |= FLAG_VISUALS;
        }
    }
    if (g_bDraftDirtyComment[client] && g_sDraftComment[client][0] != '\0')
    {
        char esc[512];
        GOKZTop_JsonEscapeString(g_sDraftComment[client], esc, sizeof(esc));
        Format(out, maxlen, "%s%s\"comment\":\"%s\"", out, first ? "" : ",", esc);
        first = false;
        flags |= FLAG_COMMENT;
    }

    StrCat(out, maxlen, "}");
    return flags != 0;
}

static void SubmitDraftReview(int client)
{
    if (!IsValidClient(client)) return;
    if (g_bSubmitInFlight[client]) return;

    if (!GOKZTop_IsConfigured())
    {
        char msg[256];
        FormatEx(msg, sizeof(msg), "%T", "GOKZTop_MissingApiKey", client);
        GOKZ_PrintToChat(client, false, "%s%s", GOKZTOP_PREFIX, msg);
        return;
    }

    int flags = 0;
    char body[1024];
    if (!BuildDraftReviewBody(client, body, sizeof(body), flags))
    {
        return;
    }

    char steamid64[32];
    if (!GetClientAuthId(client, AuthId_SteamID64, steamid64, sizeof(steamid64), true))
    {
        GOKZ_PlayErrorSound(client);
        char msg[256];
        FormatEx(msg, sizeof(msg), "%T", "GOKZTop_SteamIdNotReady", client);
        GOKZ_PrintToChat(client, false, "%s%s", GOKZTOP_PREFIX, msg);
        return;
    }

    char mapName[PLATFORM_MAX_PATH];
    GetCurrentMapDisplayName(mapName, sizeof(mapName));

    char mapEnc[PLATFORM_MAX_PATH * 3];
    GOKZTop_UrlEncode(mapName, mapEnc, sizeof(mapEnc));

    char path[128];
    strcopy(path, sizeof(path), "/maps/reviews");

    char query[256];
    Format(query, sizeof(query), "map_name=%s&steamid64=%s", mapEnc, steamid64);

    char url[1024];
    if (!GOKZTop_BuildApiUrl(url, sizeof(url), path, query))
    {
        GOKZ_PrintToChat(client, false, "%s{red}GOKZTop base URL not configured (gokz-top-core missing?)", GOKZTOP_PREFIX);
        return;
    }

    Handle req = GOKZTop_CreateSteamWorksRequest(k_EHTTPMethodPUT, url, true, 15);
    if (req == INVALID_HANDLE)
    {
        char msg[256];
        FormatEx(msg, sizeof(msg), "%T", "GOKZTop_FailedCreateRequest", client);
        GOKZ_PrintToChat(client, false, "%s%s", GOKZTOP_PREFIX, msg);
        return;
    }
    GOKZTop_SetJsonBody(req, body);

    g_bSubmitInFlight[client] = true;
    g_iSubmitPendingFlags[client] = flags;

    int ctx2 = (Req_SubmitReview & 0xFF) | ((flags & 0xFF) << 8);
    SteamWorks_SetHTTPRequestContextValue(req, GetClientUserId(client), ctx2);
    SteamWorks_SetHTTPCallbacks(req, OnHTTPCompleted);
    SteamWorks_SendHTTPRequest(req);
}

static void FetchComments(int client)
{
    char mapName[PLATFORM_MAX_PATH];
    GetCurrentMapDisplayName(mapName, sizeof(mapName));

    char mapEnc[PLATFORM_MAX_PATH * 3];
    GOKZTop_UrlEncode(mapName, mapEnc, sizeof(mapEnc));

    char path[128];
    strcopy(path, sizeof(path), "/maps/reviews");

    char query[256];
    Format(query, sizeof(query), "map_name=%s&comments_only=true&limit=10&offset=0&sort=latest", mapEnc);

    char url[1024];
    if (!GOKZTop_BuildApiUrl(url, sizeof(url), path, query))
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

    SteamWorks_SetHTTPRequestContextValue(req, GetClientUserId(client), Req_FetchComments);
    SteamWorks_SetHTTPCallbacks(req, OnHTTPCompleted);
    SteamWorks_SendHTTPRequest(req);
}

public void OnHTTPCompleted(Handle hRequest, bool bFailure, bool bRequestSuccessful, EHTTPStatusCode eStatusCode, any data1, any data2)
{
    int userid = data1;
    int reqType = (data2 & 0xFF);
    int reqFlags = (data2 >> 8) & 0xFF;
    int client = GetClientOfUserId(userid);

    int status = view_as<int>(eStatusCode);

    char body[2048];
    GOKZTop_ReadResponseBody(hRequest, body, sizeof(body));

    if (hRequest != INVALID_HANDLE)
    {
        delete hRequest;
    }

    if (bFailure || !bRequestSuccessful || status < 200 || status >= 300)
    {
        // Map-level summary fetch has no client
        if (reqType == Req_MapReviewsSummary)
        {
            g_bSummaryFetchInFlight = false;
            return;
        }

        if (!client || !IsValidClient(client))
        {
            return;
        }

        if (reqType == Req_MyReview && g_bRatePromptPending[client])
        {
            g_bRatePromptPending[client] = false;
            g_fRatePromptRequestedAt[client] = 0.0;
        }
        if (reqType == Req_SubmitReview)
        {
            g_bSubmitInFlight[client] = false;
        }

        char detail[256] = "";
        ExtractErrorDetail(body, detail, sizeof(detail));
        if (detail[0] != '\0')
        {
            GOKZ_PrintToChat(client, false, "%s{red}%s", GOKZTOP_PREFIX, detail);
        }
        else
        {
            // If we got HTML, this is almost always wrong gokz_top_base_url (or double /api/v1).
            if (body[0] != '\0' && !GOKZTop_LooksLikeJson(body))
            {
                char msg[256];
                FormatEx(msg, sizeof(msg), "%T", "GOKZTop_NonJsonResponse", client, status);
                GOKZ_PrintToChat(client, false, "%s%s", GOKZTOP_PREFIX, msg);
                LogMessage("[gokz-top] Non-JSON response (status %d). Body starts with: %.64s", status, body);
            }
            else
            {
                char msg[256];
                FormatEx(msg, sizeof(msg), "%T", "GOKZTop_HttpErrorGeneric", client, status);
                GOKZ_PrintToChat(client, false, "%s%s", GOKZTOP_PREFIX, msg);
            }
        }
        return;
    }

    // Success: map summary has no client, everything else needs a live client
    if (reqType != Req_MapReviewsSummary && (!client || !IsValidClient(client)))
    {
        return;
    }

    switch (reqType)
    {
        case Req_MapReviewsSummary:
        {
            g_bSummaryFetchInFlight = false;
            if (!GOKZTop_LooksLikeJson(body))
            {
                LogMessage("[gokz-top] Expected JSON for reviews summary, got: %.64s", body);
                return;
            }

            Handle root = json_load(body);
            if (root == INVALID_HANDLE || !json_is_object(root))
            {
                if (root != INVALID_HANDLE) delete root;
                return;
            }

            Handle data = json_object_get(root, "data");
            if (data == INVALID_HANDLE || !json_is_array(data) || json_array_size(data) <= 0)
            {
                // No reviews yet for this map
                delete root;
                g_bSummaryFetched = true;
                g_iMapCommentCount = 0;
                for (int a = 0; a < 3; a++)
                {
                    g_fAvgRating[a] = -1.0;
                    g_iAvgCount[a] = 0;
                }
                return;
            }

            Handle row = json_array_get(data, 0);
            if (row == INVALID_HANDLE || !json_is_object(row))
            {
                delete root;
                return;
            }

            Handle stars = json_object_get(row, "stars");
            if (stars != INVALID_HANDLE && json_is_object(stars))
            {
                g_fAvgRating[Aspect_Overall] = json_object_get_float(stars, "overall_avg_stars");
                g_iAvgCount[Aspect_Overall] = json_object_get_int(stars, "overall_count");
                g_fAvgRating[Aspect_Gameplay] = json_object_get_float(stars, "gameplay_avg_stars");
                g_iAvgCount[Aspect_Gameplay] = json_object_get_int(stars, "gameplay_count");
                g_fAvgRating[Aspect_Visuals] = json_object_get_float(stars, "visuals_avg_stars");
                g_iAvgCount[Aspect_Visuals] = json_object_get_int(stars, "visuals_count");
            }
            g_iMapCommentCount = json_object_get_int(row, "comment_count");

            char mapName[PLATFORM_MAX_PATH];
            GetCurrentMapDisplayName(mapName, sizeof(mapName));
            strcopy(g_sCachedMapName, sizeof(g_sCachedMapName), mapName);
            g_bSummaryFetched = true;

            delete root;
        }

        case Req_MyReview:
        {
            if (!GOKZTop_LooksLikeJson(body))
            {
                g_bMyReviewFetched[client] = true;
                TryShowMenuWhenReady(client);
                return;
            }

            Handle root = json_load(body);
            if (root == INVALID_HANDLE || !json_is_object(root))
            {
                if (root != INVALID_HANDLE) delete root;
                g_bMyReviewFetched[client] = true;
                TryShowMenuWhenReady(client);
                return;
            }

            Handle data = json_object_get(root, "data");
            // Reset then fill (0 / empty means unset)
            g_iMyRating[client][Aspect_Overall] = 0;
            g_iMyRating[client][Aspect_Gameplay] = 0;
            g_iMyRating[client][Aspect_Visuals] = 0;
            g_sMyComment[client][0] = '\0';

            if (data != INVALID_HANDLE && json_is_array(data) && json_array_size(data) > 0)
            {
                Handle row = json_array_get(data, 0);
                if (row != INVALID_HANDLE && json_is_object(row))
                {
                    Handle content = json_object_get(row, "content");
                    if (content != INVALID_HANDLE && json_is_object(content))
                    {
                        g_iMyRating[client][Aspect_Overall] = JsonGetOptionalInt(content, "overall");
                        g_iMyRating[client][Aspect_Gameplay] = JsonGetOptionalInt(content, "gameplay");
                        g_iMyRating[client][Aspect_Visuals] = JsonGetOptionalInt(content, "visuals");
                        JsonGetOptionalString(content, "comment", g_sMyComment[client], sizeof(g_sMyComment[]));
                    }
                }
            }

            delete root;

            // Mark my review as fetched
            g_bMyReviewFetched[client] = true;
            TryShowMenuWhenReady(client);

            // If we were waiting to decide whether to prompt, do it now.
            if (g_bRatePromptPending[client] && !g_bRateReminderSent[client])
            {
                // Don't let an old pending request prompt much later (e.g. reconnect delays).
                if (GetGameTime() - g_fRatePromptRequestedAt[client] <= 30.0)
                {
                    bool hasAny =
                        (g_iMyRating[client][Aspect_Overall] > 0
                        || g_iMyRating[client][Aspect_Gameplay] > 0
                        || g_iMyRating[client][Aspect_Visuals] > 0
                        || g_sMyComment[client][0] != '\0');

                    if (!hasAny)
                    {
                        g_bRateReminderSent[client] = true;
                        char msg[256];
                        FormatEx(msg, sizeof(msg), "%T", "GOKZTop_RatePrompt", client);
                        GOKZ_PrintToChat(client, false, "%s%s", GOKZTOP_PREFIX, msg);
                    }
                }
                g_bRatePromptPending[client] = false;
                g_fRatePromptRequestedAt[client] = 0.0;
            }
        }

        case Req_SubmitReview:
        {
            g_bSubmitInFlight[client] = false;

            const int FLAG_OVERALL = (1 << 0);
            const int FLAG_GAMEPLAY = (1 << 1);
            const int FLAG_VISUALS = (1 << 2);
            const int FLAG_COMMENT = (1 << 3);

            if (reqFlags & FLAG_OVERALL)
            {
                g_iMyRating[client][Aspect_Overall] = g_iDraftRating[client][Aspect_Overall];
                g_bDraftDirtyRating[client][Aspect_Overall] = false;
            }
            if (reqFlags & FLAG_GAMEPLAY)
            {
                g_iMyRating[client][Aspect_Gameplay] = g_iDraftRating[client][Aspect_Gameplay];
                g_bDraftDirtyRating[client][Aspect_Gameplay] = false;
            }
            if (reqFlags & FLAG_VISUALS)
            {
                g_iMyRating[client][Aspect_Visuals] = g_iDraftRating[client][Aspect_Visuals];
                g_bDraftDirtyRating[client][Aspect_Visuals] = false;
            }
            if (reqFlags & FLAG_COMMENT)
            {
                strcopy(g_sMyComment[client], sizeof(g_sMyComment[]), g_sDraftComment[client]);
                g_bDraftDirtyComment[client] = false;
            }

            if ((reqFlags & (FLAG_OVERALL | FLAG_GAMEPLAY | FLAG_VISUALS)) != 0)
            {
                char msg[128];
                FormatEx(msg, sizeof(msg), "%T", "GOKZTop_RatingSaved", client);
                GOKZ_PrintToChat(client, false, "%s%s", GOKZTOP_PREFIX, msg);
            }
            if (reqFlags & FLAG_COMMENT)
            {
                char msg[128];
                FormatEx(msg, sizeof(msg), "%T", "GOKZTop_CommentSaved", client);
                GOKZ_PrintToChat(client, false, "%s%s", GOKZTOP_PREFIX, msg);
            }

            // Refresh map summary counts/avgs after review updates.
            if (!g_bSummaryFetchInFlight) FetchMapReviewsSummary();

            if (g_bReopenMenuAfterSubmit[client])
            {
                g_bReopenMenuAfterSubmit[client] = false;
                g_bMenuPending[client] = true;
                g_bMyReviewFetched[client] = false;
                FetchMyReview(client, true);
            }
        }

        case Req_FetchComments:
        {
            if (!GOKZTop_LooksLikeJson(body))
            {
                GOKZ_PrintToChat(client, false, "%s{red}Comments response was not JSON. Check {gold}gokz_top_base_url{red}.", GOKZTOP_PREFIX);
                LogMessage("[gokz-top] Expected JSON for comments, got: %.64s", body);
                return;
            }
            ShowCommentsMenuFromJson(client, body);
        }
    }
}

static void TryShowMenuWhenReady(int client)
{
    if (!g_bMenuPending[client]) return;
    
    // Wait for player review to be fetched (summary is best-effort)
    if (!g_bMyReviewFetched[client])
    {
        return;
    }
    
    // All data fetched, show menu
    g_bMenuPending[client] = false;
    InitDraftFromMyReview(client);
    ShowRateMenu_Main(client);
}

static void ShowCommentsMenuFromJson(int client, const char[] body)
{
    if (!GOKZTop_LooksLikeJson(body))
    {
        GOKZ_PrintToChat(client, false, "%s{red}Comments response was not JSON. Check {gold}gokz_top_base_url{red}.", GOKZTOP_PREFIX);
        return;
    }
    Handle root = json_load(body);
    if (root == INVALID_HANDLE || !json_is_object(root))
    {
        if (root != INVALID_HANDLE) delete root;
        GOKZ_PrintToChat(client, false, "%s{red}Failed to parse comments response", GOKZTOP_PREFIX);
        return;
    }

    // Parse new format: { "data": [...], "count": 2 }
    Handle data = json_object_get(root, "data");
    if (data == INVALID_HANDLE || !json_is_array(data))
    {
        delete root;
        GOKZ_PrintToChat(client, false, "%s{red}No comments found", GOKZTOP_PREFIX);
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

        int overall = 0;
        char comment[128] = "";
        Handle content = json_object_get(row, "content");
        if (content != INVALID_HANDLE && json_is_object(content))
        {
            overall = JsonGetOptionalInt(content, "overall");
            JsonGetOptionalString(content, "comment", comment, sizeof(comment));
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
        r = g_iDraftRating[client][aspect];
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

static int JsonGetOptionalInt(Handle obj, const char[] key)
{
    if (obj == INVALID_HANDLE) return 0;
    Handle v = json_object_get(obj, key);
    if (v == INVALID_HANDLE || json_is_null(v)) return 0;
    int n = json_object_get_int(obj, key);
    if (n >= 1 && n <= 5) return n;
    return 0;
}

static void JsonGetOptionalString(Handle obj, const char[] key, char[] out, int maxlen)
{
    out[0] = '\0';
    if (obj == INVALID_HANDLE) return;
    Handle v = json_object_get(obj, key);
    if (v == INVALID_HANDLE || json_is_null(v)) return;
    json_object_get_string(obj, key, out, maxlen);
    TrimString(out);
}
