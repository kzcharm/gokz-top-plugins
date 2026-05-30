#include <sourcemod>
#include <sdktools>

#include <gokz>
#include <gokz/core>
#include <gokz/top>

#include <SteamWorks>

#pragma newdecls required
#pragma semicolon 1

public Plugin myinfo =
{
	name = "GOKZ Top Reviews",
	author = "Cinyan10",
	description = "Rate maps and browse map comments through the gokz-top v2 API",
	version = GOKZ_VERSION,
	url = GOKZ_SOURCE_URL
};

#define ReviewRequestType_MapInfo 1
#define ReviewRequestType_MyReview 2
#define ReviewRequestType_SubmitReview 3
#define ReviewRequestType_Comments 4
#define REVIEW_ASPECT_COUNT 3
#define ReviewAspect_Visuals 0
#define ReviewAspect_Overall 1
#define ReviewAspect_Gameplay 2

ConVar gCV_APIBaseURL;
ConVar gCV_APIKey;
ConVar gCV_RequestTimeout;

bool gB_RateReminderSent[MAXPLAYERS + 1];
bool gB_RatePromptPending[MAXPLAYERS + 1];
float gF_RatePromptRequestedAt[MAXPLAYERS + 1];
int gI_ActiveAspectMenu[MAXPLAYERS + 1];
bool gB_CaptureComment[MAXPLAYERS + 1];
bool gB_MenuPending[MAXPLAYERS + 1];
bool gB_SubmitInFlight[MAXPLAYERS + 1];
int gI_SubmitPendingFlags[MAXPLAYERS + 1];
bool gB_ReopenMenuAfterSubmit[MAXPLAYERS + 1];
int gI_SummaryPrintAttempts[MAXPLAYERS + 1];
bool gB_SubmitPendingAfterMapInfo[MAXPLAYERS + 1];

int gI_MyRating[MAXPLAYERS + 1][3];
char gC_MyComment[MAXPLAYERS + 1][256];
bool gB_MyReviewFetched[MAXPLAYERS + 1];
float gF_LastMyReviewFetchAt[MAXPLAYERS + 1];

int gI_DraftRating[MAXPLAYERS + 1][3];
bool gB_DraftDirtyRating[MAXPLAYERS + 1][3];
char gC_DraftComment[MAXPLAYERS + 1][256];
bool gB_DraftDirtyComment[MAXPLAYERS + 1];

char gC_CurrentMapName[PLATFORM_MAX_PATH];
int gI_CurrentMapID;
bool gB_CurrentMapInfoFetched;
bool gB_CurrentMapInfoInFlight;
float gF_CurrentMapOverallAvg;
float gF_CurrentMapGameplayAvg;
float gF_CurrentMapVisualsAvg;
int gI_CurrentMapReviewsCount;
int gI_CurrentMapGameplayCount;
int gI_CurrentMapVisualsCount;
int gI_CurrentMapCommentsCount;

#include "gokz-top-reviews/state.sp"
#include "gokz-top-reviews/http.sp"
#include "gokz-top-reviews/reviews.sp"
#include "gokz-top-reviews/summary.sp"
#include "gokz-top-reviews/menus.sp"
#include "gokz-top-reviews/commands.sp"

public void OnPluginStart()
{
	LoadTranslations("common.phrases");
	LoadTranslations("gokz-common.phrases");
	LoadTranslations("gokz-top-reviews.phrases");

	FindSharedConVars();
	RegisterCommands();
	AddCommandListener(Command_Say, "say");
	AddCommandListener(Command_Say, "say_team");
}

public void OnMapStart()
{
	GetCurrentMap(gC_CurrentMapName, sizeof(gC_CurrentMapName));
	ResetMapReviewState();
	FetchCurrentMapInfo();
}

public void OnClientDisconnect(int client)
{
	if (client <= 0 || client > MaxClients)
	{
		return;
	}

	ResetClientReviewState(client);
}

public void GOKZ_OnFirstSpawn(int client)
{
	if (!IsValidClient(client))
	{
		return;
	}

	CreateTimer(2.0, Timer_PrintSummary, GetClientUserId(client));
}

public void GOKZ_OnTimerEnd_Post(int client, int course, float time, int teleportsUsed)
{
	if (!IsValidClient(client) || course != 0 || gB_RateReminderSent[client])
	{
		return;
	}

	CreateTimer(3.0, Timer_PromptRateIfNeeded, GetClientUserId(client));
}
