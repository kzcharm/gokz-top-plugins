#include <sourcemod>
#include <sdktools>
#include <clientprefs>
#include <SteamWorks>
#include <json>

#include <gokz/core>
#include <gokz/top>

#pragma newdecls required
#pragma semicolon 1
#pragma dynamic 524288

#define LJROOM_DEFAULT_DISTANCE 260
#define LJROOM_MAX_RESPONSE_LENGTH 65536
#define LJROOM_USER_AGENT "gokz-top-ljroom/" ... GOKZ_VERSION

enum SpotField
{
	Spot_Distance = 0,
	Spot_RoomRank,
	Spot_OriginX,
	Spot_OriginY,
	Spot_OriginZ,
	Spot_Pitch,
	Spot_Yaw,
	Spot_FieldCount
};

public Plugin myinfo =
{
	name = "GOKZ Top LJ Room",
	author = "Evan, Cinyan10, OpenAI",
	description = "Teleports players to detected LJ blocks loaded from GOKZ.TOP",
	version = GOKZ_VERSION,
	url = GOKZ_SOURCE_URL
};

ConVar gCV_APIBaseURL;
ConVar gCV_RequestTimeout;
ArrayList gA_Spots;
Cookie gC_DefaultDistance;
bool gB_DataReady;
bool gB_DataLoading;
bool gB_LateLoad;
int gI_LoadGeneration;
char gC_CurrentMap[PLATFORM_MAX_PATH];
char gC_ResponseBuffer[LJROOM_MAX_RESPONSE_LENGTH];

#include "gokz-top-ljroom/parse.sp"
#include "gokz-top-ljroom/http.sp"
#include "gokz-top-ljroom/commands.sp"

public APLRes AskPluginLoad2(Handle myself, bool late, char[] error, int errMax)
{
	gB_LateLoad = late;
	return APLRes_Success;
}

public void OnPluginStart()
{
	LoadTranslations("gokz-common.phrases");
	LoadTranslations("gokz-top-ljroom.phrases");

	gA_Spots = new ArrayList(view_as<int>(Spot_FieldCount));
	gC_DefaultDistance = new Cookie(
		"gokz_ljroom_default_distance",
		"Preferred LJ block distance used by !lj",
		CookieAccess_Private
	);
	gCV_APIBaseURL = FindConVar("gokz_top_api_base_url");
	gCV_RequestTimeout = FindConVar("gokz_top_request_timeout");
	if (gCV_APIBaseURL == null || gCV_RequestTimeout == null)
	{
		SetFailState("gokz-top-core shared HTTP ConVars are unavailable");
		return;
	}

	RegisterCommands();
	if (gB_LateLoad)
	{
		BeginMapLoad();
	}
}

public void OnPluginEnd()
{
	delete gA_Spots;
	delete gC_DefaultDistance;
}

public void OnMapStart()
{
	BeginMapLoad();
}
