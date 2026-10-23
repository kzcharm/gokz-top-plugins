// =====[ REQUESTS ]=====

void RequestTier(int client)
{
	char mapName[GOKZ_TOP_MAP_NAME_LENGTH];
	GetCurrentDisplayMap(mapName, sizeof(mapName));

	char encodedMapName[GOKZ_TOP_MAP_NAME_LENGTH * 3];
	URLEncode(mapName, encodedMapName, sizeof(encodedMapName));

	char path[GOKZ_TOP_MAX_PATH_LENGTH];
	Format(path, sizeof(path), "/v1/maps?name=%s&limit=1", encodedMapName);

	DataPack pack = CreateRecordRequestPack(GOKZTopAPIRequest_Tier, GetClientUserId(client), 0, 0, 0, 0.0, 0.0, 0, false, mapName);
	if (!SendRecordGETRequest(path, OnRecordHTTPComplete, pack))
	{
		FallbackTierCommand(client);
	}
}

void RequestNubWR(int client, int mode)
{
	char mapName[GOKZ_TOP_MAP_NAME_LENGTH];
	GetCurrentDisplayMap(mapName, sizeof(mapName));

	char encodedMapName[GOKZ_TOP_MAP_NAME_LENGTH * 3];
	URLEncode(mapName, encodedMapName, sizeof(encodedMapName));

	char scope[8];
	GetRecordsScopeForMode(mode, scope, sizeof(scope));

	char path[GOKZ_TOP_MAX_PATH_LENGTH];
	Format(path, sizeof(path), "/v1/maps/wrs?map_name=%s&scope=%s&type=NUB", encodedMapName, scope);

	DataPack pack = CreateRecordRequestPack(GOKZTopAPIRequest_NubWR, GetClientUserId(client), 0, mode, GOKZ_TOP_RECORD_TYPE_NUB, 0.0, 0.0, 0, false, mapName);
	SendRecordGETRequest(path, OnRecordHTTPComplete, pack);
}

void RequestPB(int client, int mode, int recordType, bool printResult)
{
	char steamID64[GOKZ_TOP_STEAMID64_LENGTH];
	if (!GetClientAuthId(client, AuthId_SteamID64, steamID64, sizeof(steamID64), true))
	{
		return;
	}

	char mapName[GOKZ_TOP_MAP_NAME_LENGTH];
	GetCurrentDisplayMap(mapName, sizeof(mapName));

	char encodedMapName[GOKZ_TOP_MAP_NAME_LENGTH * 3];
	URLEncode(mapName, encodedMapName, sizeof(encodedMapName));

	char scope[8];
	GetRecordsScopeForMode(mode, scope, sizeof(scope));

	char typeName[8];
	GetRecordTypeName(recordType, typeName, sizeof(typeName));

	char path[GOKZ_TOP_MAX_PATH_LENGTH];
	Format(path, sizeof(path),
		"/v1/records/pb?map_name=%s&stage=0&identifier=%s&scope=%s&type=%s&limit=1",
		encodedMapName,
		steamID64,
		scope,
		typeName);

	DataPack pack = CreateRecordRequestPack(GOKZTopAPIRequest_PB, GetClientUserId(client), GetClientUserId(client), mode, recordType, 0.0, 0.0, 0, printResult, mapName);
	SendRecordGETRequest(path, OnRecordHTTPComplete, pack);
}

bool RequestPBDiff(int client, int mode, int recordType, float runTime, float oldTime, int oldPoints, bool hadBaseline, int serial)
{
	char steamID64[GOKZ_TOP_STEAMID64_LENGTH];
	if (!GetClientAuthId(client, AuthId_SteamID64, steamID64, sizeof(steamID64), true))
	{
		return false;
	}

	char mapName[GOKZ_TOP_MAP_NAME_LENGTH];
	GetCurrentDisplayMap(mapName, sizeof(mapName));

	char encodedMapName[GOKZ_TOP_MAP_NAME_LENGTH * 3];
	URLEncode(mapName, encodedMapName, sizeof(encodedMapName));

	char scope[8];
	GetRecordsScopeForMode(mode, scope, sizeof(scope));

	char typeName[8];
	GetRecordTypeName(recordType, typeName, sizeof(typeName));

	char path[GOKZ_TOP_MAX_PATH_LENGTH];
	Format(path, sizeof(path),
		"/v1/records/pb?map_name=%s&stage=0&identifier=%s&scope=%s&type=%s&limit=1",
		encodedMapName,
		steamID64,
		scope,
		typeName);

	DataPack pack = CreateRecordRequestPack(GOKZTopAPIRequest_PBDiff, GetClientUserId(client), GetClientUserId(client), mode, recordType, runTime, oldTime, oldPoints, hadBaseline, mapName, serial);
	return SendRecordGETRequest(path, OnRecordHTTPComplete, pack);
}



// =====[ HTTP FLOW ]=====

DataPack CreateRecordRequestPack(GOKZTopAPIRequestType requestType, int userID, int targetUserID, int mode, int recordType,
	float runTime, float oldTime, int oldPoints, bool flag, const char[] mapName, int serial = 0)
{
	CheckRecordsEnvironment();
	DataPack pack = new DataPack();
	pack.WriteCell(view_as<int>(requestType));
	pack.WriteCell(userID);
	pack.WriteCell(targetUserID);
	pack.WriteCell(mode);
	pack.WriteCell(recordType);
	pack.WriteFloat(runTime);
	pack.WriteFloat(oldTime);
	pack.WriteCell(oldPoints);
	pack.WriteCell(flag ? 1 : 0);
	pack.WriteString(mapName);
	pack.WriteCell(serial);
	pack.WriteString(gC_RecordsEnvironment);
	int target = GetClientOfUserId(targetUserID);
	pack.WriteCell(target != 0 ? GetPBRevision(target, mode, recordType, mapName) : 0);
	return pack;
}

void ReadRecordRequestPack(DataPack pack, GOKZTopAPIRequestType &requestType, int &userID, int &targetUserID, int &mode,
	int &recordType, float &runTime, float &oldTime, int &oldPoints, bool &flag, char[] mapName, int mapNameLength)
{
	pack.Reset();
	requestType = view_as<GOKZTopAPIRequestType>(pack.ReadCell());
	userID = pack.ReadCell();
	targetUserID = pack.ReadCell();
	mode = pack.ReadCell();
	recordType = pack.ReadCell();
	runTime = pack.ReadFloat();
	oldTime = pack.ReadFloat();
	oldPoints = pack.ReadCell();
	flag = pack.ReadCell() != 0;
	pack.ReadString(mapName, mapNameLength);
}

bool SendRecordGETRequest(const char[] path, SteamWorksHTTPRequestCompleted callback, DataPack pack)
{
	if (!BuildAPIURL(path, gC_RequestURLBuffer, sizeof(gC_RequestURLBuffer)))
	{
		delete pack;
		return false;
	}

	Handle request = SteamWorks_CreateHTTPRequest(k_EHTTPMethodGET, gC_RequestURLBuffer);
	if (request == null)
	{
		LogError("[gokz-top-core] Failed to create GET request for %s", path);
		delete pack;
		return false;
	}

	SteamWorks_SetHTTPRequestContextValue(request, pack);
	SteamWorks_SetHTTPCallbacks(request, callback);
	SteamWorks_SetHTTPRequestHeaderValue(request, "Accept", "application/json");
	SteamWorks_SetHTTPRequestHeaderValue(request, "X-Request-Origin", "gokz-top-core/" ... GOKZ_TOP_VERSION);
	SteamWorks_SetHTTPRequestHeaderValue(request, "User-Agent", GOKZ_TOP_USER_AGENT);
	SteamWorks_SetHTTPRequestUserAgentInfo(request, GOKZ_TOP_USER_AGENT);
	SteamWorks_SetHTTPRequestAbsoluteTimeoutMS(request, gCV_RequestTimeout.IntValue * 1000);
	ApplyAuthHeaders(request);

	if (gCV_Debug.BoolValue)
	{
		LogMessage("[gokz-top-core] GET %s", path);
	}

	if (!SteamWorks_SendHTTPRequest(request))
	{
		LogError("[gokz-top-core] Failed to send GET request for %s", path);
		delete pack;
		delete request;
		return false;
	}

	return true;
}

public void OnRecordHTTPComplete(Handle request, bool failure, bool requestSuccessful, EHTTPStatusCode statusCode, DataPack pack)
{
	GOKZTopAPIRequestType requestType;
	int userID;
	int targetUserID;
	int mode;
	int recordType;
	float runTime;
	float oldTime;
	int oldPoints;
	bool flag;
	char mapName[GOKZ_TOP_MAP_NAME_LENGTH];
	ReadRecordRequestPack(pack, requestType, userID, targetUserID, mode, recordType, runTime, oldTime, oldPoints, flag, mapName, sizeof(mapName));

	int serial = pack.ReadCell();
	char environment[512];
	pack.ReadString(environment, sizeof(environment));
	int revision = pack.ReadCell();
	CheckRecordsEnvironment();
	int client = GetClientOfUserId(userID);
	char currentMap[GOKZ_TOP_MAP_NAME_LENGTH];
	GetCurrentDisplayMap(currentMap, sizeof(currentMap));
	bool diffRequest = requestType == GOKZTopAPIRequest_PBDiff;
	if (client == 0 || !IsClientInGame(client) || !StrEqual(mapName, currentMap) || !StrEqual(environment, gC_RecordsEnvironment)
		|| (diffRequest && !IsCurrentPBFinish(client, mode, recordType, serial)))
	{
		delete pack;
		delete request;
		return;
	}

	if (diffRequest) gPBFinish[client][mode * 2 + recordType].busy = false;

	if (!IsHTTPResponseOK(failure, requestSuccessful, statusCode))
	{
		if (requestType == GOKZTopAPIRequest_Tier)
		{
			FallbackTierCommand(client);
		}
		else if (gCV_Debug.BoolValue)
		{
			LogMessage("[gokz-top-core] Record request failed type=%d status=%d", requestType, statusCode);
		}

		delete pack;
		delete request;
		return;
	}

	char body[GOKZ_TOP_MAX_BODY_LENGTH];
	if (!ReadHTTPResponseBody(request, body, sizeof(body)))
	{
		if (requestType == GOKZTopAPIRequest_Tier)
		{
			FallbackTierCommand(client);
		}

		delete pack;
		delete request;
		return;
	}

	switch (requestType)
	{
		case GOKZTopAPIRequest_Tier:
		{
			HandleTierResponse(client, mapName, body);
		}
		case GOKZTopAPIRequest_NubWR:
		{
			HandleNubWRResponse(client, mode, mapName, body);
		}
		case GOKZTopAPIRequest_PB:
		{
			HandlePBResponse(client, targetUserID, mode, recordType, mapName, flag, body, revision);
		}
		case GOKZTopAPIRequest_PBDiff:
		{
			HandlePBDiffResponse(client, mode, recordType, mapName, runTime, oldTime, oldPoints, flag, body, revision);
		}
	}

	delete pack;
	delete request;
}



// =====[ RESPONSE HANDLERS ]=====

void HandleTierResponse(int client, const char[] mapName, const char[] body)
{
	int kztTier;
	int skzTier;
	int vnlTier;
	if (!ParseMapTiersResponse(body, kztTier, skzTier, vnlTier))
	{
		FallbackTierCommand(client);
		return;
	}

	char kztTierDisplay[32];
	char skzTierDisplay[32];
	char vnlTierDisplay[32];
	FormatTierDisplay(kztTier, kztTierDisplay, sizeof(kztTierDisplay));
	FormatTierDisplay(skzTier, skzTierDisplay, sizeof(skzTierDisplay));
	FormatTierDisplay(vnlTier, vnlTierDisplay, sizeof(vnlTierDisplay));

	GOKZ_PrintToChat(client, false, "%s{purple}%s{default} - {bluegrey}KZT{default} %s - {bluegrey}SKZ{default} %s - {bluegrey}VNL{default} %s",
		GOKZ_TOP_CHAT_PREFIX,
		mapName,
		kztTierDisplay,
		skzTierDisplay,
		vnlTierDisplay);
}

void HandleNubWRResponse(int client, int mode, const char[] mapName, const char[] body)
{
	float wrTime;
	if (!ParseWRResponse(body, wrTime) || wrTime <= 0.0)
	{
		return;
	}

	char time[32];
	FormatDuration(time, sizeof(time), wrTime);
	GOKZ_PrintToChat(client, false, "%s{purple}%s{default} - {bluegrey}%s{default} - {gold}NUB{default} WR [ {lightgreen}%s{default} ]",
		GOKZ_TOP_CHAT_PREFIX,
		mapName,
		gC_RecordModeNames[mode],
		time);
}

void HandlePBResponse(int client, int targetUserID, int mode, int recordType, const char[] mapName, bool printResult, const char[] body, int revision = -1)
{
	float pbTime;
	int pbPoints;
	char createdOn[64];
	if (!ParsePBResponse(body, pbTime, pbPoints, createdOn, sizeof(createdOn)) || pbTime <= 0.0)
	{
		return;
	}

	char dateOnly[GOKZ_TOP_DATE_LENGTH];
	ISODateOnly(createdOn, dateOnly, sizeof(dateOnly));

	int target = GetClientOfUserId(targetUserID);
	if (target != 0)
	{
		if (!StorePB(target, mode, recordType, mapName, pbTime, pbPoints, dateOnly, revision)) return;
	}

	if (printResult)
	{
		PrintPBLine(client, mode, recordType, mapName, pbTime, pbPoints, dateOnly);
	}
}

void HandlePBDiffResponse(int client, int mode, int recordType, const char[] mapName, float runTime, float oldTime, int oldPoints, bool hadBaseline, const char[] body, int revision = -1)
{
	float fetchedTime;
	int fetchedPoints;
	char createdOn[64];
	if (!ParsePBResponse(body, fetchedTime, fetchedPoints, createdOn, sizeof(createdOn)) || fetchedTime <= 0.0)
	{
		return;
	}

	// Ingestion may still be queued or in flight. Never label old metadata as a new PB.
	if (fetchedTime > runTime)
	{
		int bucket = mode * 2 + recordType;
		if (!hadBaseline && !gPBFinish[client][bucket].hasBaseline)
		{
			gPBFinish[client][bucket].hasBaseline = true;
			gPBFinish[client][bucket].oldTime = fetchedTime;
			gPBFinish[client][bucket].oldPoints = fetchedPoints;
		}
		return;
	}

	char dateOnly[GOKZ_TOP_DATE_LENGTH];
	ISODateOnly(createdOn, dateOnly, sizeof(dateOnly));
	if (!StorePB(client, mode, recordType, mapName, fetchedTime, fetchedPoints, dateOnly, revision)) return;
	bool improved = hadBaseline && runTime < oldTime && fetchedTime == runTime;
	PrintPBLineWithDiff(client, mode, recordType, mapName, fetchedTime, runTime, fetchedPoints, dateOnly,
		improved || fetchedTime < runTime || hadBaseline, improved ? oldTime : fetchedTime, improved ? oldPoints : fetchedPoints);
	gPBFinish[client][mode * 2 + recordType].active = false;
}
