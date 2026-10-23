#include <sourcemod>
#include <sdktools>
#include <SteamWorks>
#include <json>
#include "include/uuid.inc"
#include <gokz/core>
#undef REQUIRE_PLUGIN
#include <gokz/replays>
#include <gokz/anticheat>
#include <GlobalAPI>
#define REQUIRE_PLUGIN
#include <gokz/top>

#pragma newdecls required
#pragma semicolon 1

native int GOKZ_DB_GetRunGUID(int client, char guid[37]);

public Plugin myinfo =
{
	name = "GOKZ Top Records",
	author = "KZCharm",
	description = "Durable direct records and replay uploads to gokz.top",
	version = "1.0.0",
	url = "https://gokz.top"
};

Database gDB;
ConVar gCV_Server, gCV_Spool;
bool gFreshMap, gLateMap, gBusy, gRun[MAXPLAYERS + 1], gValid[MAXPLAYERS + 1];
int gMode[MAXPLAYERS + 1], gVersion[MAXPLAYERS + 1];
char gGUID[MAXPLAYERS + 1][37], gEnvironment[MAXPLAYERS + 1][512], gServer[MAXPLAYERS + 1][37];
char gSpool[PLATFORM_MAX_PATH], gLastStatus[256], gAuthKey[256];
char gModeNames[][] = {"VNL", "SKZ", "KZT", "NKZ"};

#include "gokz-top-records/validation.sp"
#include "gokz-top-records/queue.sp"
#include "gokz-top-records/capture.sp"
#include "gokz-top-records/http.sp"
#include "gokz-top-records/replays.sp"
#include "gokz-top-records/reconciliation.sp"
#include "gokz-top-records/commands.sp"

public APLRes AskPluginLoad2(Handle myself, bool late, char[] error, int errMax)
{
	MarkNativeAsOptional("GOKZ_DB_GetRunGUID");
	gFreshMap = !late;
	gLateMap = late;
	return APLRes_Success;
}

public void OnPluginStart()
{
	gCV_Server = CreateConVar("gokz_top_records_server_id", "", "Deprecated: previous server UUID, used only to drain legacy queued jobs. New runs use the authenticated server SteamID.");
	gCV_Spool = CreateConVar("gokz_top_records_spool_gib", "10", "Maximum private replay spool size in GiB.", _, true, 0.0);
	AutoExecConfig(true, "gokz-top-records", "sourcemod/gokz-top");
	BuildPath(Path_SM, gSpool, sizeof(gSpool), "data/gokz-top-records");
	CreateDirectory(gSpool, 448);
	Queue_Init();
	Validation_Init();
	RegConsoleCmd("sm_topcheck", Command_Check);
	RegConsoleCmd("sm_tc", Command_Check);
	RegAdminCmd("sm_toprecords_queue", Command_Queue, ADMFLAG_ROOT);
	RegAdminCmd("sm_toprecords_retry", Command_Retry, ADMFLAG_ROOT);
	CreateTimer(1.0, Timer_Worker, _, TIMER_REPEAT);
}

public void OnMapStart()
{
	if (gLateMap)
	{
		gLateMap = false;
		return;
	}
	gFreshMap = true;
	for (int client = 1; client <= MaxClients; client++)
	{
		gRun[client] = false;
	}
}

public void OnClientDisconnect(int client)
{
	gRun[client] = false;
}

public void OnLibraryRemoved(const char[] name)
{
	if (StrEqual(name, "gokz-anticheat") || StrEqual(name, "gokz-core") || StrEqual(name, "movementapi"))
	{
		gFreshMap = false;
		InvalidateAll();
	}
}
