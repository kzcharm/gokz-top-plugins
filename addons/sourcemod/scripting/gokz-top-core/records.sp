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
bool gB_TierFallbackCommand[MAXPLAYERS + 1];

#include "gokz-top-core/records/parse.sp"
#include "gokz-top-core/records/format.sp"
#include "gokz-top-core/records/http.sp"



// =====[ LIFECYCLE ]=====

void GOKZTopRecords_OnPluginStart()
{
	gSM_PBTime = new StringMap();
	gSM_PBPoints = new StringMap();
	gSM_PBDate = new StringMap();

	AddCommandListener(Command_Tier, "sm_tier");
	AddCommandListener(Command_ShowPB, "sm_pb");
	AddCommandListener(Command_ShowPB, "sm_gpb");
	RegConsoleCmd("sm_gpb", Command_ShowPBRegistered, "Show your KZCharm personal bests for the current map and mode.");
}

void GOKZTopRecords_OnClientConnected(int client)
{
	ClearClientPBStorage(client);
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
	bool nonBlocking = StrEqual(command, "sm_pb", false);

	if (!IsValidClient(client) || IsFakeClient(client))
	{
		return nonBlocking ? Plugin_Continue : Plugin_Handled;
	}

	int mode = GetClientMode(client);
	if (!IsSupportedRecordsMode(mode))
	{
		return nonBlocking ? Plugin_Continue : Plugin_Handled;
	}

	RequestPB(client, mode, GOKZ_TOP_RECORD_TYPE_NUB, true);
	RequestPB(client, mode, GOKZ_TOP_RECORD_TYPE_PRO, true);
	return nonBlocking ? Plugin_Continue : Plugin_Handled;
}

public Action Command_ShowPBRegistered(int client, int argc)
{
	return Command_ShowPB(client, "sm_gpb", argc);
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

public void GOKZ_LR_OnTimeProcessed(int client, int steamID, int mapID, int course, int mode,
	int style, float runTime, int teleportsUsed, bool firstTime, float pbDiff,
	int rank, int maxRank, bool firstTimePro, float pbDiffPro, int rankPro, int maxRankPro)
{
	if (!IsValidClient(client) || IsFakeClient(client) || course != 0 || !IsSupportedRecordsMode(mode))
	{
		return;
	}

	int recordType = teleportsUsed == 0 ? GOKZ_TOP_RECORD_TYPE_PRO : GOKZ_TOP_RECORD_TYPE_NUB;
	bool pbBroken = recordType == GOKZ_TOP_RECORD_TYPE_PRO
		? (firstTimePro || pbDiffPro < 0.0)
		: (firstTime || pbDiff < 0.0);

	char mapName[GOKZ_TOP_MAP_NAME_LENGTH];
	GetCurrentDisplayMap(mapName, sizeof(mapName));

	float cachedTime;
	int cachedPoints;
	char cachedDate[GOKZ_TOP_DATE_LENGTH];
	bool hasBaseline = GetStoredPB(client, mode, recordType, mapName, cachedTime, cachedPoints, cachedDate, sizeof(cachedDate));

	if (pbBroken)
	{
		RequestPBDiff(client, mode, recordType, runTime, cachedTime, cachedPoints, hasBaseline);
		return;
	}

	if (hasBaseline)
	{
		PrintPBLineWithDiff(client, mode, recordType, mapName, cachedTime, cachedPoints, cachedDate, true, runTime, cachedPoints);
	}
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
