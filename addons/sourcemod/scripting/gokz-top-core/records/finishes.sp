// Finish refreshes wait for ingestion. Each bucket owns its immutable baseline.
void CheckRecordsEnvironment()
{
	char environment[512];
	gCV_APIBaseURL.GetString(environment, sizeof(environment));
	if (StrEqual(environment, gC_RecordsEnvironment)) return;
	strcopy(gC_RecordsEnvironment, sizeof(gC_RecordsEnvironment), environment);
	gSM_PBTime.Clear();
	gSM_PBPoints.Clear();
	gSM_PBDate.Clear();
	gSM_PBRevision.Clear();
	for (int client = 1; client <= MaxClients; client++) ClearPendingPBFinishes(client);
}
void ClearPendingPBFinishes(int client)
{
	for (int bucket = 0; bucket < 8; bucket++)
	{
		gPBFinish[client][bucket].active = false;
		gPBFinish[client][bucket].busy = false;
	}
}

void TrackFinishedPB(int client, int mode, int recordType, float runTime)
{
	CheckRecordsEnvironment();
	int bucket = mode * 2 + recordType;
	char map[GOKZ_TOP_MAP_NAME_LENGTH], date[GOKZ_TOP_DATE_LENGTH];
	GetCurrentDisplayMap(map, sizeof(map));
	float oldTime;
	int oldPoints;
	gPBFinish[client][bucket].hasBaseline = GetStoredPB(client, mode, recordType, map, oldTime, oldPoints, date, sizeof(date));
	gPBFinish[client][bucket].oldTime = oldTime;
	gPBFinish[client][bucket].oldPoints = oldPoints;
	// Match the submission writer's millisecond serialization before comparisons.
	char serializedTime[32];
	Format(serializedTime, sizeof(serializedTime), "%.3f", runTime);
	gPBFinish[client][bucket].runTime = StringToFloat(serializedTime);
	gPBFinish[client][bucket].serial = ++gI_PBFinishSerial;
	gPBFinish[client][bucket].active = true;
	gPBFinish[client][bucket].busy = false;
	gPBFinish[client][bucket].attempts = 0;
	gPBFinish[client][bucket].nextAttempt = 0.0;
}

bool IsCurrentPBFinish(int client, int mode, int recordType, int serial)
{
	return IsSupportedRecordsMode(mode) && recordType >= 0 && recordType <= 1
		&& gPBFinish[client][mode * 2 + recordType].active
		&& gPBFinish[client][mode * 2 + recordType].serial == serial;
}

bool WakePendingPBFinish(int client, int mode, int recordType, float runTime)
{
	int bucket = mode * 2 + recordType;
	if (!gPBFinish[client][bucket].active || gPBFinish[client][bucket].runTime != runTime) return false;
	gPBFinish[client][bucket].attempts = 0;
	gPBFinish[client][bucket].nextAttempt = 0.0;
	return true;
}

public Action Timer_RefreshFinishedPBs(Handle timer)
{
	CheckRecordsEnvironment();
	for (int client = 1; client <= MaxClients; client++)
	{
		if (!IsClientInGame(client) || IsFakeClient(client)) continue;
		for (int bucket = 0; bucket < 8; bucket++)
		{
			if (!gPBFinish[client][bucket].active || gPBFinish[client][bucket].busy
				|| gPBFinish[client][bucket].attempts >= 12
				|| gPBFinish[client][bucket].nextAttempt > GetEngineTime()) continue;
			gPBFinish[client][bucket].attempts++;
			gPBFinish[client][bucket].nextAttempt = GetEngineTime() + 5.0;
			gPBFinish[client][bucket].busy = RequestPBDiff(client, bucket / 2, bucket % 2,
				gPBFinish[client][bucket].runTime, gPBFinish[client][bucket].oldTime,
				gPBFinish[client][bucket].oldPoints, gPBFinish[client][bucket].hasBaseline,
				gPBFinish[client][bucket].serial);
		}
	}
	return Plugin_Continue;
}

public void GOKZTop_OnRecordAccepted(const char[] apiBaseURL, const char[] steamID64, const char[] mapName,
	int course, int mode, float runTime, int teleports, const char[] recordUUID)
{
	if (course != 0 || !IsSupportedRecordsMode(mode)) return;
	char environment[512], currentMap[GOKZ_TOP_MAP_NAME_LENGTH];
	gCV_APIBaseURL.GetString(environment, sizeof(environment));
	GetCurrentDisplayMap(currentMap, sizeof(currentMap));
	char displayMap[GOKZ_TOP_MAP_NAME_LENGTH];
	GetMapDisplayName(mapName, displayMap, sizeof(displayMap));
	if (!StrEqual(apiBaseURL, environment) || !StrEqual(displayMap, currentMap)) return;
	for (int client = 1; client <= MaxClients; client++)
	{
		if (!IsClientInGame(client) || IsFakeClient(client)) continue;
		char steam[32];
		if (!GetClientAuthId(client, AuthId_SteamID64, steam, sizeof(steam)) || !StrEqual(steam, steamID64)) continue;
		for (int recordType = 0; recordType <= (teleports == 0 ? 1 : 0); recordType++)
		{
			// Wake a pending finish after arbitrarily long upload outages. A later finish owns its own comparison.
			if (!WakePendingPBFinish(client, mode, recordType, runTime)) RequestPB(client, mode, recordType, false);
		}
	}
}
