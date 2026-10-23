#include <gokz/core>

#define GOKZ_TOP_STEAMID64_LENGTH 32
#define GOKZ_TOP_MAP_NAME_LENGTH 256
#define GOKZ_TOP_DATE_LENGTH 16
#define GOKZ_TOP_RECORD_TYPE_NUB 0
#define GOKZ_TOP_RECORD_TYPE_PRO 1
enum GOKZTopAPIRequestType
{
	GOKZTopAPIRequest_Tier = 0,
	GOKZTopAPIRequest_NubWR,
	GOKZTopAPIRequest_PB,
	GOKZTopAPIRequest_PBDiff
};

StringMap gSM_PBTime;
StringMap gSM_PBPoints;
StringMap gSM_PBDate;
StringMap gSM_PBRevision;
bool gB_TierFallbackCommand[MAXPLAYERS + 1];
char gC_RecordModeNames[][] = {"VNL", "SKZ", "KZT", "NKZ"};

enum struct PendingPBFinish
{
	bool active;
	bool busy;
	bool hasBaseline;
	int serial;
	int attempts;
	float nextAttempt;
	float runTime;
	float oldTime;
	int oldPoints;
}
PendingPBFinish gPBFinish[MAXPLAYERS + 1][8];
int gI_PBFinishSerial;
char gC_RecordsEnvironment[512];

#include "gokz-top-core/records/parse.sp"
#include "gokz-top-core/records/format.sp"
#include "gokz-top-core/records/http.sp"
#include "gokz-top-core/records/finishes.sp"



// =====[ LIFECYCLE ]=====

void GOKZTopRecords_OnPluginStart()
{
	gSM_PBTime = new StringMap();
	gSM_PBPoints = new StringMap();
	gSM_PBDate = new StringMap();
	gSM_PBRevision = new StringMap();
	CreateTimer(1.0, Timer_RefreshFinishedPBs, _, TIMER_REPEAT);

	AddCommandListener(Command_Tier, "sm_tier");
	AddCommandListener(Command_ShowPB, "sm_pb");
	AddCommandListener(Command_ShowPB, "sm_gpb");
}

void GOKZTopRecords_OnClientConnected(int client)
{
	ClearClientPBStorage(client);
	ClearPendingPBFinishes(client);
}



// =====[ COMMANDS AND GOKZ EVENTS ]=====

public Action Command_Tier(int client, const char[] command, int argc)
{
	if (!IsValidClient(client))
	{
		return Plugin_Handled;
	}

	if (gB_TierFallbackCommand[client])
	{
		gB_TierFallbackCommand[client] = false;
		return Plugin_Continue;
	}

	RequestTier(client);
	return Plugin_Handled;
}

public Action Command_ShowPB(int client, const char[] command, int argc)
{
	if (!IsValidClient(client) || IsFakeClient(client))
	{
		return Plugin_Continue;
	}

	int mode = GetClientMode(client);
	if (!IsSupportedRecordsMode(mode))
	{
		return Plugin_Continue;
	}

	RequestPB(client, mode, GOKZ_TOP_RECORD_TYPE_NUB, true);
	RequestPB(client, mode, GOKZ_TOP_RECORD_TYPE_PRO, true);
	return Plugin_Continue;
}

public void GOKZ_OnFirstSpawn(int client)
{
	PrintSpawnModeRecords(client);
}

public void GOKZ_OnOptionChanged(int client, const char[] option, any newValue)
{
	Option coreOption;
	if (GOKZ_IsCoreOption(option, coreOption) && coreOption == Option_Mode)
	{
		PrintSpawnModeRecords(client);
	}
}

public void GOKZ_OnTimerEnd_Post(int client, int course, float runTime, int teleportsUsed)
{
	if (!IsValidClient(client) || IsFakeClient(client) || course != 0 || GOKZ_GetCoreOption(client, Option_Style) != 0) return;
	int mode = GetClientMode(client);
	if (!IsSupportedRecordsMode(mode)) return;
	// Capture the gokz.top baseline before asynchronous LocalDB/upload callbacks.
	TrackFinishedPB(client, mode, teleportsUsed == 0 ? GOKZ_TOP_RECORD_TYPE_PRO : GOKZ_TOP_RECORD_TYPE_NUB, runTime);
}

void PrintSpawnModeRecords(int client)
{
	if (!IsValidClient(client) || IsFakeClient(client))
	{
		return;
	}

	int mode = GetClientMode(client);
	if (!IsSupportedRecordsMode(mode))
	{
		return;
	}

	RequestNubWR(client, mode);
	RequestPB(client, mode, GOKZ_TOP_RECORD_TYPE_NUB, true);
	RequestPB(client, mode, GOKZ_TOP_RECORD_TYPE_PRO, true);
}
