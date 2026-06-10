#include <sourcemod>
#include <sdktools>
#include <SteamWorks>
#include <autoexecconfig>

#include <uuid>

#include <gokz/top>

#pragma newdecls required
#pragma semicolon 1

#define GOKZ_TOP_VERSION "1.0.0"
#define GOKZ_TOP_DEFAULT_API_BASE_URL "https://api.gokz.top"
#define GOKZ_TOP_MAX_URL_LENGTH 512
#define GOKZ_TOP_MAX_BODY_LENGTH 16384
#define GOKZ_TOP_MAX_PATH_LENGTH 512
#define GOKZ_TOP_CFG_FOLDER "sourcemod/gokz-top"
#define GOKZ_TOP_USER_AGENT "gokz-top-core/" ... GOKZ_TOP_VERSION

public Plugin myinfo =
{
	name = "GOKZ Top Core",
	author = "Cinyan10",
	description = "API wrapper and shared HTTP utilities for gokz-top plugins",
	version = GOKZ_TOP_VERSION,
	url = "https://gokz.top"
};

ConVar gCV_APIBaseURL;
ConVar gCV_APIKey;
ConVar gCV_RequestTimeout;
ConVar gCV_RetryCount;
ConVar gCV_RetryDelay;
ConVar gCV_Debug;
char gC_RequestPathBuffer[GOKZ_TOP_MAX_PATH_LENGTH];
char gC_RequestBodyBuffer[GOKZ_TOP_MAX_BODY_LENGTH];
char gC_RequestURLBuffer[GOKZ_TOP_MAX_URL_LENGTH];
GOKZTopLeaderboardDataState gI_LeaderboardState[MAXPLAYERS + 1][GOKZTOP_MODE_COUNT];
float gF_LeaderboardRating[MAXPLAYERS + 1][GOKZTOP_MODE_COUNT];
int gI_LeaderboardRank[MAXPLAYERS + 1][GOKZTOP_MODE_COUNT];
int gI_LeaderboardGlobalRank[MAXPLAYERS + 1][GOKZTOP_MODE_COUNT];
int gI_LeaderboardRegionalRank[MAXPLAYERS + 1][GOKZTOP_MODE_COUNT];
int gI_LeaderboardPoints[MAXPLAYERS + 1][GOKZTOP_MODE_COUNT];
char gC_LeaderboardRegion[MAXPLAYERS + 1][GOKZTOP_MODE_COUNT][8];
GlobalForward gH_OnLeaderboardDataFetched;

#include "gokz-top-core/players.sp"
#include "gokz-top-core/records.sp"



// =====[ PLUGIN EVENTS ]=====

public APLRes AskPluginLoad2(Handle myself, bool late, char[] error, int errMax)
{
	CreateNative("GOKZTop_PostJSON", Native_PostJSON);
	CreateNative("GOKZTop_RefreshLeaderboardData", Native_RefreshLeaderboardData);
	CreateNative("GOKZTop_GetLeaderboardDataState", Native_GetLeaderboardDataState);
	CreateNative("GOKZTop_IsLeaderboardDataLoaded", Native_IsLeaderboardDataLoaded);
	CreateNative("GOKZTop_IsLeaderboardDataPending", Native_IsLeaderboardDataPending);
	CreateNative("GOKZTop_HasLeaderboardDataError", Native_HasLeaderboardDataError);
	CreateNative("GOKZTop_GetRating", Native_GetRating);
	CreateNative("GOKZTop_GetRank", Native_GetRank);
	CreateNative("GOKZTop_GetGlobalRank", Native_GetGlobalRank);
	CreateNative("GOKZTop_HasRegionalRank", Native_HasRegionalRank);
	CreateNative("GOKZTop_GetRegionalRank", Native_GetRegionalRank);
	CreateNative("GOKZTop_GetRegionCode", Native_GetRegionCode);
	CreateNative("GOKZTop_GetPoints", Native_GetPoints);
	RegPluginLibrary("gokz-top-core");

	GOKZTopPlayers_AskPluginLoad2(late);

	return APLRes_Success;
}

public void OnPluginStart()
{
	AutoExecConfig_SetFile("gokz-top-core", GOKZ_TOP_CFG_FOLDER);
	AutoExecConfig_SetCreateFile(true);
	AutoExecConfig_SetCreateDirectory(true);

	gCV_APIBaseURL = AutoExecConfig_CreateConVar("gokz_top_api_base_url", GOKZ_TOP_DEFAULT_API_BASE_URL,
		"Base URL for the gokz-top API, without a trailing slash.");
	gCV_RequestTimeout = AutoExecConfig_CreateConVar("gokz_top_request_timeout", "10",
		"HTTP request timeout in seconds.", _, true, 1.0, true, 60.0);
	gCV_RetryCount = AutoExecConfig_CreateConVar("gokz_top_retry_count", "2",
		"Number of retry attempts after the initial HTTP request fails.", _, true, 0.0, true, 5.0);
	gCV_RetryDelay = AutoExecConfig_CreateConVar("gokz_top_retry_delay", "5.0",
		"Delay in seconds before retrying a failed HTTP request.", _, true, 1.0, true, 30.0);
	gCV_Debug = AutoExecConfig_CreateConVar("gokz_top_debug", "0",
		"Log gokz-top HTTP request attempts and failures.", _, true, 0.0, true, 1.0);

	AutoExecConfig_ExecuteFile();
	AutoExecConfig_CleanFile();

	CreateAPIKeyConfigIfNotExists();
	gCV_APIKey = CreateConVar("gokz_top_api_key", "",
		"Server group API key sent to authenticated gokz-top endpoints. Set in cfg/sourcemod/gokz-top/apikey.cfg.",
		FCVAR_PROTECTED);
	RegServerCmd("gokz_top_reload_api_key", Command_ReloadAPIKey,
		"Reload the server group API key from cfg/sourcemod/gokz-top/apikey.cfg.");
	LoadAPIKeyConfig();

	GOKZTopPlayers_OnPluginStart();
	GOKZTopRecords_OnPluginStart();

	gH_OnLeaderboardDataFetched = new GlobalForward(
		"GOKZTop_OnLeaderboardDataFetched",
		ET_Ignore,
		Param_Cell,
		Param_Cell,
		Param_Float,
		Param_Cell,
		Param_Cell,
		Param_Cell,
		Param_String);
}

public void OnAllPluginsLoaded()
{
	GOKZTopPlayers_OnAllPluginsLoaded();
}

public void OnPluginEnd()
{
	GOKZTopPlayers_OnPluginEnd();
}

public void OnMapStart()
{
	GOKZTopPlayers_OnMapStart();
}

public void OnMapEnd()
{
	GOKZTopPlayers_OnMapEnd();
}

public void OnClientConnected(int client)
{
	ClearClientLeaderboardCache(client);
	GOKZTopRecords_OnClientConnected(client);
}

public void OnClientPostAdminCheck(int client)
{
	GOKZTopPlayers_OnClientPostAdminCheck(client);
}

public void OnClientPutInServer(int client)
{
	GOKZTopPlayers_OnClientPutInServer(client);
}

public void OnClientDisconnect(int client)
{
	GOKZTopPlayers_OnClientDisconnect(client);
}



// =====[ NATIVES ]=====

public int Native_PostJSON(Handle plugin, int numParams)
{
	GetNativeString(1, gC_RequestPathBuffer, sizeof(gC_RequestPathBuffer));

	int bodyLength;
	GetNativeStringLength(2, bodyLength);
	if (bodyLength >= GOKZ_TOP_MAX_BODY_LENGTH)
	{
		ThrowNativeError(SP_ERROR_NATIVE, "JSON body exceeds %d bytes", GOKZ_TOP_MAX_BODY_LENGTH - 1);
		return false;
	}

	GetNativeString(2, gC_RequestBodyBuffer, sizeof(gC_RequestBodyBuffer));

	return PostJSON(gC_RequestPathBuffer, gC_RequestBodyBuffer);
}

public int Native_RefreshLeaderboardData(Handle plugin, int numParams)
{
	return RefreshLeaderboardData(GetNativeCell(1), GetNativeCell(2));
}

public int Native_GetLeaderboardDataState(Handle plugin, int numParams)
{
	int client = GetNativeCell(1);
	int mode = NormalizeMode(GetNativeCell(2));
	if (!IsValidLeaderboardCacheSlot(client, mode))
	{
		return view_as<int>(GOKZTopLeaderboardData_Error);
	}

	return view_as<int>(gI_LeaderboardState[client][mode]);
}

public int Native_IsLeaderboardDataLoaded(Handle plugin, int numParams)
{
	int client = GetNativeCell(1);
	int mode = NormalizeMode(GetNativeCell(2));
	return IsValidLeaderboardCacheSlot(client, mode)
		&& gI_LeaderboardState[client][mode] == GOKZTopLeaderboardData_Loaded;
}

public int Native_IsLeaderboardDataPending(Handle plugin, int numParams)
{
	int client = GetNativeCell(1);
	int mode = NormalizeMode(GetNativeCell(2));
	return IsValidLeaderboardCacheSlot(client, mode)
		&& gI_LeaderboardState[client][mode] == GOKZTopLeaderboardData_Pending;
}

public int Native_HasLeaderboardDataError(Handle plugin, int numParams)
{
	int client = GetNativeCell(1);
	int mode = NormalizeMode(GetNativeCell(2));
	return IsValidLeaderboardCacheSlot(client, mode)
		&& gI_LeaderboardState[client][mode] == GOKZTopLeaderboardData_Error;
}

public int Native_GetRating(Handle plugin, int numParams)
{
	int client = GetNativeCell(1);
	int mode = NormalizeMode(GetNativeCell(2));
	if (!IsValidLeaderboardCacheSlot(client, mode))
	{
		return view_as<int>(0.0);
	}

	return view_as<int>(gF_LeaderboardRating[client][mode]);
}

public int Native_GetRank(Handle plugin, int numParams)
{
	int client = GetNativeCell(1);
	int mode = NormalizeMode(GetNativeCell(2));
	return IsValidLeaderboardCacheSlot(client, mode) ? gI_LeaderboardRank[client][mode] : 0;
}

public int Native_GetGlobalRank(Handle plugin, int numParams)
{
	int client = GetNativeCell(1);
	int mode = NormalizeMode(GetNativeCell(2));
	return IsValidLeaderboardCacheSlot(client, mode) ? gI_LeaderboardGlobalRank[client][mode] : 0;
}

public int Native_HasRegionalRank(Handle plugin, int numParams)
{
	int client = GetNativeCell(1);
	int mode = NormalizeMode(GetNativeCell(2));
	return IsValidLeaderboardCacheSlot(client, mode) && gI_LeaderboardRegionalRank[client][mode] > 0;
}

public int Native_GetRegionalRank(Handle plugin, int numParams)
{
	int client = GetNativeCell(1);
	int mode = NormalizeMode(GetNativeCell(2));
	return IsValidLeaderboardCacheSlot(client, mode) ? gI_LeaderboardRegionalRank[client][mode] : 0;
}

public int Native_GetRegionCode(Handle plugin, int numParams)
{
	int client = GetNativeCell(1);
	int mode = NormalizeMode(GetNativeCell(2));
	int maxLength = GetNativeCell(4);

	if (!IsValidLeaderboardCacheSlot(client, mode))
	{
		SetNativeString(3, "", maxLength);
		return 0;
	}

	SetNativeString(3, gC_LeaderboardRegion[client][mode], maxLength);
	return 0;
}

public int Native_GetPoints(Handle plugin, int numParams)
{
	int client = GetNativeCell(1);
	int mode = NormalizeMode(GetNativeCell(2));
	return IsValidLeaderboardCacheSlot(client, mode) ? gI_LeaderboardPoints[client][mode] : 0;
}



// =====[ API WRAPPER ]=====

bool PostSessionEvent(const char[] event, const char[] body)
{
	if (!IsValidSessionEvent(event))
	{
		LogError("[gokz-top-core] Invalid player-session event: %s", event);
		return false;
	}

	if (!HasAPIKey())
	{
		LogError("[gokz-top-core] Cannot post player-session event '%s': gokz_top_api_key is empty", event);
		return false;
	}

	char path[GOKZ_TOP_MAX_PATH_LENGTH];
	Format(path, sizeof(path), "/v1/player-sessions/%s", event);

	return PostJSON(path, body);
}

bool PostJSON(const char[] path, const char[] body)
{
	if (path[0] != '/')
	{
		LogError("[gokz-top-core] API path must begin with '/': %s", path);
		return false;
	}

	DataPack pack = CreateRequestPack(path, body, gCV_RetryCount.IntValue);
	return SendRequestFromPack(pack);
}

bool IsValidSessionEvent(const char[] event)
{
	return StrEqual(event, "connect")
		|| StrEqual(event, "heartbeat")
		|| StrEqual(event, "disconnect");
}

bool HasAPIKey()
{
	char apiKey[4];
	gCV_APIKey.GetString(apiKey, sizeof(apiKey));
	return apiKey[0] != '\0';
}

public Action Command_ReloadAPIKey(int args)
{
	LoadAPIKeyConfig();
	return Plugin_Handled;
}

void LoadAPIKeyConfig()
{
	char configPath[PLATFORM_MAX_PATH];
	Format(configPath, sizeof(configPath), "cfg/%s/apikey.cfg", GOKZ_TOP_CFG_FOLDER);

	File file = OpenFile(configPath, "r");
	if (file == null)
	{
		LogError("[gokz-top-core] Failed to read cfg/%s/apikey.cfg", GOKZ_TOP_CFG_FOLDER);
		return;
	}

	gCV_APIKey.SetString("");

	char line[256];
	while (!file.EndOfFile() && file.ReadLine(line, sizeof(line)))
	{
		TrimString(line);
		if (line[0] == '\0' || StrContains(line, "//", false) == 0)
		{
			continue;
		}

		if (!IsAPIKeyConVarCommand(line))
		{
			gCV_APIKey.SetString(line);
		}
		else
		{
			SetAPIKeyFromConVarCommand(line);
		}

		break;
	}

	delete file;
}

bool IsAPIKeyConVarCommand(const char[] line)
{
	char command[] = "gokz_top_api_key";
	int commandLength = strlen(command);
	if (StrContains(line, command, false) != 0)
	{
		return false;
	}

	return line[commandLength] == '\0'
		|| line[commandLength] == ' '
		|| line[commandLength] == '\t';
}

void SetAPIKeyFromConVarCommand(const char[] line)
{
	char command[] = "gokz_top_api_key";
	char apiKey[256];
	strcopy(apiKey, sizeof(apiKey), line[strlen(command)]);
	TrimString(apiKey);
	StripAPIKeyQuotes(apiKey);
	gCV_APIKey.SetString(apiKey);
}

void StripAPIKeyQuotes(char[] value)
{
	int length = strlen(value);
	if (length < 2 || value[0] != '"' || value[length - 1] != '"')
	{
		return;
	}

	value[length - 1] = '\0';
	for (int index = 1; index < length - 1; index++)
	{
		value[index - 1] = value[index];
	}
	value[length - 2] = '\0';
}

void CreateAPIKeyConfigIfNotExists()
{
	char configPath[PLATFORM_MAX_PATH];
	Format(configPath, sizeof(configPath), "cfg/%s/apikey.cfg", GOKZ_TOP_CFG_FOLDER);
	if (FileExists(configPath))
	{
		return;
	}

	char dirPath[PLATFORM_MAX_PATH];
	Format(dirPath, sizeof(dirPath), "cfg/%s", GOKZ_TOP_CFG_FOLDER);
	if (!DirExists(dirPath))
	{
		CreateDirectory(dirPath, 511);
	}

	File file = OpenFile(configPath, "w");
	if (file == null)
	{
		LogError("[gokz-top-core] Failed to create cfg/%s/apikey.cfg", GOKZ_TOP_CFG_FOLDER);
		return;
	}

	file.WriteLine("// This file was auto-generated by GOKZ Top Core.");
	file.WriteLine("// Server group API key used by server-side gokz-top plugins.");
	file.WriteLine("// Paste the API key from your gokz.top server group on the next non-comment line.");
	file.WriteLine("// Example: paste-your-server-group-api-key-here");
	file.WriteLine("// The old format, gokz_top_api_key \"your-key\", is still supported.");
	file.WriteLine("");
	file.WriteLine("");
	file.WriteLine("");
	delete file;
}



// =====[ LEADERBOARD PROFILE CACHE ]=====

bool RefreshLeaderboardData(int client, int mode)
{
	mode = NormalizeMode(mode);
	if (!IsValidLeaderboardCacheSlot(client, mode)
		|| !IsClientInGame(client)
		|| IsFakeClient(client))
	{
		return false;
	}

	if (gI_LeaderboardState[client][mode] == GOKZTopLeaderboardData_Pending)
	{
		return true;
	}

	char steamID64[32];
	if (!GetClientAuthId(client, AuthId_SteamID64, steamID64, sizeof(steamID64), true))
	{
		gI_LeaderboardState[client][mode] = GOKZTopLeaderboardData_Error;
		return false;
	}

	gI_LeaderboardState[client][mode] = GOKZTopLeaderboardData_Pending;

	DataPack pack = CreateLeaderboardRequestPack(GetClientUserId(client), mode, gCV_RetryCount.IntValue);
	return SendLeaderboardRequestFromPack(pack);
}

DataPack CreateLeaderboardRequestPack(int userID, int mode, int retriesRemaining)
{
	DataPack pack = new DataPack();
	pack.WriteCell(userID);
	pack.WriteCell(mode);
	pack.WriteCell(retriesRemaining);
	return pack;
}

bool SendLeaderboardRequestFromPack(DataPack pack)
{
	int userID;
	int mode;
	int retriesRemaining;
	ReadLeaderboardRequestPack(pack, userID, mode, retriesRemaining);

	int client = GetClientOfUserId(userID);
	if (!IsValidLeaderboardCacheSlot(client, mode)
		|| !IsClientInGame(client)
		|| IsFakeClient(client))
	{
		delete pack;
		return false;
	}

	char steamID64[32];
	if (!GetClientAuthId(client, AuthId_SteamID64, steamID64, sizeof(steamID64), true))
	{
		gI_LeaderboardState[client][mode] = GOKZTopLeaderboardData_Error;
		delete pack;
		return false;
	}

	char scope[8];
	GetLeaderboardScopeForMode(mode, scope, sizeof(scope));

	char path[160];
	Format(path, sizeof(path), "/v1/leaderboards/players/%s?scope=%s", steamID64, scope);
	if (!BuildAPIURL(path, gC_RequestURLBuffer, sizeof(gC_RequestURLBuffer)))
	{
		gI_LeaderboardState[client][mode] = GOKZTopLeaderboardData_Error;
		delete pack;
		return false;
	}

	Handle request = SteamWorks_CreateHTTPRequest(k_EHTTPMethodGET, gC_RequestURLBuffer);
	if (request == null)
	{
		LogError("[gokz-top-core] Failed to create leaderboard request for client=%d mode=%d", client, mode);
		RetryLeaderboardOrDelete(userID, mode, retriesRemaining, "create-request");
		delete pack;
		return false;
	}

	SteamWorks_SetHTTPRequestContextValue(request, pack);
	SteamWorks_SetHTTPCallbacks(request, OnLeaderboardHTTPComplete);
	SteamWorks_SetHTTPRequestHeaderValue(request, "Accept", "application/json");
	SteamWorks_SetHTTPRequestHeaderValue(request, "X-Request-Origin", "gokz-top-core/" ... GOKZ_TOP_VERSION);
	SteamWorks_SetHTTPRequestHeaderValue(request, "User-Agent", GOKZ_TOP_USER_AGENT);
	SteamWorks_SetHTTPRequestUserAgentInfo(request, GOKZ_TOP_USER_AGENT);
	SteamWorks_SetHTTPRequestAbsoluteTimeoutMS(request, gCV_RequestTimeout.IntValue * 1000);

	if (gCV_Debug.BoolValue)
	{
		LogMessage("[gokz-top-core] GET %s retries_remaining=%d", path, retriesRemaining);
	}

	if (!SteamWorks_SendHTTPRequest(request))
	{
		LogError("[gokz-top-core] Failed to send leaderboard request client=%d mode=%d", client, mode);
		RetryLeaderboardOrDelete(userID, mode, retriesRemaining, "send-request");
		delete pack;
		delete request;
		return false;
	}

	return true;
}

public void OnLeaderboardHTTPComplete(Handle request, bool failure, bool requestSuccessful, EHTTPStatusCode statusCode, DataPack pack)
{
	int userID;
	int mode;
	int retriesRemaining;
	ReadLeaderboardRequestPack(pack, userID, mode, retriesRemaining);

	int client = GetClientOfUserId(userID);
	if (!IsValidLeaderboardCacheSlot(client, mode)
		|| !IsClientInGame(client)
		|| IsFakeClient(client))
	{
		delete pack;
		delete request;
		return;
	}

	if (!IsHTTPResponseOK(failure, requestSuccessful, statusCode))
	{
		if (ShouldRetryHTTPFailure(failure, requestSuccessful, statusCode))
		{
			RetryLeaderboardOrDelete(userID, mode, retriesRemaining, "http-complete");
		}
		else
		{
			gI_LeaderboardState[client][mode] = GOKZTopLeaderboardData_Error;
			LogError("[gokz-top-core] Leaderboard request failed client=%d mode=%d status=%d", client, mode, statusCode);
		}

		delete pack;
		delete request;
		return;
	}

	char body[GOKZ_TOP_MAX_BODY_LENGTH];
	if (!ReadHTTPResponseBody(request, body, sizeof(body)) || !ParseLeaderboardResponse(client, mode, body))
	{
		gI_LeaderboardState[client][mode] = GOKZTopLeaderboardData_Error;
		LogError("[gokz-top-core] Failed to parse leaderboard response client=%d mode=%d", client, mode);
		delete pack;
		delete request;
		return;
	}

	gI_LeaderboardState[client][mode] = GOKZTopLeaderboardData_Loaded;
	Call_OnLeaderboardDataFetched(client, mode);

	delete pack;
	delete request;
}

public Action Timer_RetryLeaderboardRequest(Handle timer, DataPack pack)
{
	SendLeaderboardRequestFromPack(pack);
	return Plugin_Stop;
}

void ReadLeaderboardRequestPack(DataPack pack, int &userID, int &mode, int &retriesRemaining)
{
	pack.Reset();
	userID = pack.ReadCell();
	mode = pack.ReadCell();
	retriesRemaining = pack.ReadCell();
}

void RetryLeaderboardOrDelete(int userID, int mode, int retriesRemaining, const char[] reason)
{
	int client = GetClientOfUserId(userID);
	if (retriesRemaining <= 0)
	{
		if (IsValidLeaderboardCacheSlot(client, mode))
		{
			gI_LeaderboardState[client][mode] = GOKZTopLeaderboardData_Error;
		}
		LogError("[gokz-top-core] Dropping leaderboard request userid=%d mode=%d reason=%s", userID, mode, reason);
		return;
	}

	DataPack retryPack = CreateLeaderboardRequestPack(userID, mode, retriesRemaining - 1);
	CreateTimer(gCV_RetryDelay.FloatValue, Timer_RetryLeaderboardRequest, retryPack);

	if (gCV_Debug.BoolValue)
	{
		LogMessage("[gokz-top-core] Queued leaderboard retry userid=%d mode=%d retries_remaining=%d reason=%s",
			userID, mode, retriesRemaining - 1, reason);
	}
}

bool ParseLeaderboardResponse(int client, int mode, const char[] body)
{
	float rating;
	int rank;
	int globalRank;
	int regionalRank;
	int points;
	char region[8];

	ExtractJsonFloat(body, "rating", rating);
	ExtractJsonInt(body, "rank", rank);
	ExtractJsonInt(body, "global_rank", globalRank);
	ExtractJsonInt(body, "rank_regional", regionalRank);
	ExtractJsonInt(body, "points", points);
	ExtractJsonString(body, "region", region, sizeof(region));

	gF_LeaderboardRating[client][mode] = rating;
	gI_LeaderboardRank[client][mode] = rank;
	gI_LeaderboardGlobalRank[client][mode] = globalRank;
	gI_LeaderboardRegionalRank[client][mode] = regionalRank;
	gI_LeaderboardPoints[client][mode] = points;
	strcopy(gC_LeaderboardRegion[client][mode], sizeof(gC_LeaderboardRegion[][]), region);
	return true;
}

void Call_OnLeaderboardDataFetched(int client, int mode)
{
	Call_StartForward(gH_OnLeaderboardDataFetched);
	Call_PushCell(client);
	Call_PushCell(mode);
	Call_PushFloat(gF_LeaderboardRating[client][mode]);
	Call_PushCell(gI_LeaderboardRank[client][mode]);
	Call_PushCell(gI_LeaderboardRegionalRank[client][mode]);
	Call_PushCell(gI_LeaderboardRegionalRank[client][mode] > 0);
	Call_PushString(gC_LeaderboardRegion[client][mode]);
	Call_Finish();
}

void ClearClientLeaderboardCache(int client)
{
	if (client <= 0 || client > MaxClients)
	{
		return;
	}

	for (int mode = 0; mode < GOKZTOP_MODE_COUNT; mode++)
	{
		gI_LeaderboardState[client][mode] = GOKZTopLeaderboardData_NotLoaded;
		gF_LeaderboardRating[client][mode] = 0.0;
		gI_LeaderboardRank[client][mode] = 0;
		gI_LeaderboardGlobalRank[client][mode] = 0;
		gI_LeaderboardRegionalRank[client][mode] = 0;
		gI_LeaderboardPoints[client][mode] = 0;
		gC_LeaderboardRegion[client][mode][0] = '\0';
	}
}

bool IsValidLeaderboardCacheSlot(int client, int mode)
{
	return client > 0 && client <= MaxClients && mode >= 0 && mode < GOKZTOP_MODE_COUNT;
}

int NormalizeMode(int mode)
{
	if (mode >= 0 && mode < GOKZTOP_MODE_COUNT)
	{
		return mode;
	}

	return -1;
}

void GetLeaderboardScopeForMode(int mode, char[] scope, int maxLength)
{
	switch (mode)
	{
		case GOKZTOP_MODE_VNL:
		{
			strcopy(scope, maxLength, "VNL");
		}
		case GOKZTOP_MODE_SKZ:
		{
			strcopy(scope, maxLength, "SKZ");
		}
		case GOKZTOP_MODE_OVR:
		{
			strcopy(scope, maxLength, "OVR");
		}
		default:
		{
			strcopy(scope, maxLength, "KZT");
		}
	}
}



// =====[ HTTP ]=====

DataPack CreateRequestPack(const char[] path, const char[] body, int retriesRemaining)
{
	DataPack pack = new DataPack();
	pack.WriteString(path);
	pack.WriteString(body);
	pack.WriteCell(retriesRemaining);
	return pack;
}

bool SendRequestFromPack(DataPack pack)
{
	int retriesRemaining;
	ReadRequestPack(pack,
		gC_RequestPathBuffer,
		sizeof(gC_RequestPathBuffer),
		gC_RequestBodyBuffer,
		sizeof(gC_RequestBodyBuffer),
		retriesRemaining);

	if (!BuildAPIURL(gC_RequestPathBuffer, gC_RequestURLBuffer, sizeof(gC_RequestURLBuffer)))
	{
		delete pack;
		return false;
	}

	EHTTPMethod method = GetHTTPMethodForPath(gC_RequestPathBuffer);
	Handle request = SteamWorks_CreateHTTPRequest(method, gC_RequestURLBuffer);
	if (request == null)
	{
		LogError("[gokz-top-core] Failed to create HTTP request for %s", gC_RequestPathBuffer);
		RetryOrDelete(gC_RequestPathBuffer, gC_RequestBodyBuffer, retriesRemaining, "create-request");
		delete pack;
		return false;
	}

	SteamWorks_SetHTTPRequestContextValue(request, pack);
	SteamWorks_SetHTTPCallbacks(request, OnHTTPComplete);
	SteamWorks_SetHTTPRequestHeaderValue(request, "Accept", "application/json");
	SteamWorks_SetHTTPRequestHeaderValue(request, "Content-Type", "application/json");
	SteamWorks_SetHTTPRequestHeaderValue(request, "X-Request-Origin", "gokz-top-core/" ... GOKZ_TOP_VERSION);
	SteamWorks_SetHTTPRequestHeaderValue(request, "User-Agent", GOKZ_TOP_USER_AGENT);
	SteamWorks_SetHTTPRequestUserAgentInfo(request, GOKZ_TOP_USER_AGENT);
	SteamWorks_SetHTTPRequestRawPostBody(
		request,
		"application/json",
		gC_RequestBodyBuffer,
		strlen(gC_RequestBodyBuffer));
	SteamWorks_SetHTTPRequestAbsoluteTimeoutMS(request, gCV_RequestTimeout.IntValue * 1000);
	ApplyAuthHeaders(request);

	if (gCV_Debug.BoolValue)
	{
		LogMessage("[gokz-top-core] POST %s retries_remaining=%d", gC_RequestPathBuffer, retriesRemaining);
	}

	if (!SteamWorks_SendHTTPRequest(request))
	{
		LogError("[gokz-top-core] Failed to send HTTP request for %s", gC_RequestPathBuffer);
		RetryOrDelete(gC_RequestPathBuffer, gC_RequestBodyBuffer, retriesRemaining, "send-request");
		delete pack;
		delete request;
		return false;
	}

	return true;
}

EHTTPMethod GetHTTPMethodForPath(const char[] path)
{
	if (StrEqual(path, "/v1/servers/status"))
	{
		return k_EHTTPMethodPUT;
	}

	return k_EHTTPMethodPOST;
}

public void OnHTTPComplete(Handle request, bool failure, bool requestSuccessful, EHTTPStatusCode statusCode, DataPack pack)
{
	int retriesRemaining;
	ReadRequestPack(pack,
		gC_RequestPathBuffer,
		sizeof(gC_RequestPathBuffer),
		gC_RequestBodyBuffer,
		sizeof(gC_RequestBodyBuffer),
		retriesRemaining);

	if (IsHTTPResponseOK(failure, requestSuccessful, statusCode))
	{
		Call_OnSessionEventPostedIfNeeded(request, gC_RequestPathBuffer);

		if (gCV_Debug.BoolValue)
		{
			LogMessage("[gokz-top-core] %s %s completed status=%d",
				StrEqual(gC_RequestPathBuffer, "/v1/servers/status") ? "PUT" : "POST",
				gC_RequestPathBuffer,
				statusCode);
		}

		delete pack;
		delete request;
		return;
	}

	LogHTTPFailure(request, gC_RequestPathBuffer, failure, requestSuccessful, statusCode, retriesRemaining);
	if (ShouldRetryHTTPFailure(failure, requestSuccessful, statusCode))
	{
		RetryOrDelete(gC_RequestPathBuffer, gC_RequestBodyBuffer, retriesRemaining, "http-complete");
	}
	else
	{
		LogError("[gokz-top-core] Dropping non-retryable request path=%s status=%d", gC_RequestPathBuffer, statusCode);
	}

	delete pack;
	delete request;
}

void Call_OnSessionEventPostedIfNeeded(Handle request, const char[] path)
{
	char event[16];
	if (!GetSessionEventFromPath(path, event, sizeof(event)))
	{
		return;
	}

	char body[GOKZ_TOP_MAX_BODY_LENGTH];
	if (!ReadHTTPResponseBody(request, body, sizeof(body)))
	{
		body[0] = '\0';
	}

	GOKZTopPlayers_OnSessionEventPosted(event, body);
}

bool GetSessionEventFromPath(const char[] path, char[] event, int maxLength)
{
	char prefix[] = "/v1/player-sessions/";
	if (StrContains(path, prefix, false) != 0)
	{
		return false;
	}

	strcopy(event, maxLength, path[strlen(prefix)]);
	return IsValidSessionEvent(event);
}

public Action Timer_RetryRequest(Handle timer, DataPack pack)
{
	SendRequestFromPack(pack);
	return Plugin_Stop;
}

void ReadRequestPack(DataPack pack, char[] path, int pathMaxLength, char[] body, int bodyMaxLength, int &retriesRemaining)
{
	pack.Reset();
	pack.ReadString(path, pathMaxLength);
	pack.ReadString(body, bodyMaxLength);
	retriesRemaining = pack.ReadCell();
}

void RetryOrDelete(const char[] path, const char[] body, int retriesRemaining, const char[] reason)
{
	if (retriesRemaining <= 0)
	{
		LogError("[gokz-top-core] Dropping request path=%s reason=%s", path, reason);
		return;
	}

	DataPack retryPack = CreateRequestPack(path, body, retriesRemaining - 1);
	CreateTimer(gCV_RetryDelay.FloatValue, Timer_RetryRequest, retryPack);

	if (gCV_Debug.BoolValue)
	{
		LogMessage("[gokz-top-core] Queued retry path=%s retries_remaining=%d reason=%s",
			path, retriesRemaining - 1, reason);
	}
}

bool IsHTTPResponseOK(bool failure, bool requestSuccessful, EHTTPStatusCode statusCode)
{
	return !failure
		&& requestSuccessful
		&& statusCode >= k_EHTTPStatusCode200OK
		&& statusCode < k_EHTTPStatusCode300MultipleChoices;
}

bool ShouldRetryHTTPFailure(bool failure, bool requestSuccessful, EHTTPStatusCode statusCode)
{
	return failure
		|| !requestSuccessful
		|| statusCode == k_EHTTPStatusCodeInvalid
		|| statusCode == k_EHTTPStatusCode408RequestTimeout
		|| statusCode == k_EHTTPStatusCode429TooManyRequests
		|| statusCode >= k_EHTTPStatusCode500InternalServerError;
}

void LogHTTPFailure(Handle request, const char[] path, bool failure, bool requestSuccessful, EHTTPStatusCode statusCode, int retriesRemaining)
{
	char response[512];
	response[0] = '\0';
	int responseSize;
	if (SteamWorks_GetHTTPResponseBodySize(request, responseSize) && responseSize > 0)
	{
		int responseLength = responseSize;
		if (responseLength >= sizeof(response))
		{
			responseLength = sizeof(response) - 1;
		}

		if (SteamWorks_GetHTTPResponseBodyData(request, response, responseLength))
		{
			response[responseLength] = '\0';
		}
		else
		{
			response[0] = '\0';
		}
	}

	LogError("[gokz-top-core] %s %s failed failure=%d request_successful=%d status=%d retries_remaining=%d response=%s",
		StrEqual(path, "/v1/servers/status") ? "PUT" : "POST",
		path,
		failure,
		requestSuccessful,
		statusCode,
		retriesRemaining,
		response);
}

void ApplyAuthHeaders(Handle request)
{
	char apiKey[256];
	gCV_APIKey.GetString(apiKey, sizeof(apiKey));
	TrimString(apiKey);
	if (apiKey[0] != '\0')
	{
		SteamWorks_SetHTTPRequestHeaderValue(request, "X-Server-Group-Key", apiKey);
	}
}

bool BuildAPIURL(const char[] path, char[] url, int maxLength)
{
	char baseURL[256];
	gCV_APIBaseURL.GetString(baseURL, sizeof(baseURL));

	if (baseURL[0] == '\0')
	{
		LogError("[gokz-top-core] gokz_top_api_base_url is empty");
		return false;
	}

	int length = strlen(baseURL);
	if (length > 0 && baseURL[length - 1] == '/')
	{
		baseURL[length - 1] = '\0';
		length--;
	}

	char suffix[GOKZ_TOP_MAX_PATH_LENGTH];
	strcopy(suffix, sizeof(suffix), path);
	if (StrContains(path, "/v1/", false) == 0
		&& (EndsWith(baseURL, "/v1") || EndsWith(baseURL, "/api/v1")))
	{
		strcopy(suffix, sizeof(suffix), path[3]);
	}

	Format(url, maxLength, "%s%s", baseURL, suffix);
	return true;
}

bool EndsWith(const char[] value, const char[] suffix)
{
	int valueLength = strlen(value);
	int suffixLength = strlen(suffix);
	if (suffixLength > valueLength)
	{
		return false;
	}

	return StrEqual(value[valueLength - suffixLength], suffix, false);
}

bool ReadHTTPResponseBody(Handle request, char[] out, int maxLength)
{
	out[0] = '\0';

	int size;
	if (!SteamWorks_GetHTTPResponseBodySize(request, size) || size <= 0)
	{
		return false;
	}

	if (size >= maxLength)
	{
		size = maxLength - 1;
	}

	bool ok = SteamWorks_GetHTTPResponseBodyData(request, out, size);
	out[size] = '\0';
	return ok;
}

bool FindJsonValueStart(const char[] json, const char[] key, int &pos)
{
	char pattern[64];
	Format(pattern, sizeof(pattern), "\"%s\"", key);

	int keyPos = StrContains(json, pattern, false);
	if (keyPos == -1)
	{
		return false;
	}

	pos = keyPos + strlen(pattern);
	while (json[pos] != '\0' && json[pos] != ':')
	{
		pos++;
	}

	if (json[pos] != ':')
	{
		return false;
	}

	pos++;
	while (json[pos] == ' ' || json[pos] == '\t' || json[pos] == '\r' || json[pos] == '\n')
	{
		pos++;
	}

	return json[pos] != '\0';
}

bool ExtractJsonInt(const char[] json, const char[] key, int &value)
{
	value = 0;

	int pos;
	if (!FindJsonValueStart(json, key, pos)
		|| StrContains(json[pos], "null", false) == 0)
	{
		return false;
	}

	char buffer[32];
	int outPos;
	while (json[pos] != '\0' && outPos < sizeof(buffer) - 1)
	{
		char c = json[pos];
		if ((c < '0' || c > '9') && c != '-')
		{
			break;
		}
		buffer[outPos++] = c;
		pos++;
	}
	buffer[outPos] = '\0';

	if (outPos == 0)
	{
		return false;
	}

	value = StringToInt(buffer);
	return true;
}

bool ExtractJsonFloat(const char[] json, const char[] key, float &value)
{
	value = 0.0;

	int pos;
	if (!FindJsonValueStart(json, key, pos)
		|| StrContains(json[pos], "null", false) == 0)
	{
		return false;
	}

	char buffer[32];
	int outPos;
	while (json[pos] != '\0' && outPos < sizeof(buffer) - 1)
	{
		char c = json[pos];
		if ((c < '0' || c > '9') && c != '-' && c != '.')
		{
			break;
		}
		buffer[outPos++] = c;
		pos++;
	}
	buffer[outPos] = '\0';

	if (outPos == 0)
	{
		return false;
	}

	value = StringToFloat(buffer);
	return true;
}

bool ExtractJsonString(const char[] json, const char[] key, char[] out, int maxLength)
{
	out[0] = '\0';

	int pos;
	if (!FindJsonValueStart(json, key, pos)
		|| json[pos] != '"')
	{
		return false;
	}

	pos++;
	int outPos;
	while (json[pos] != '\0' && outPos < maxLength - 1)
	{
		char c = json[pos++];
		if (c == '"')
		{
			out[outPos] = '\0';
			return true;
		}

		if (c == '\\' && json[pos] != '\0')
		{
			c = json[pos++];
		}

		out[outPos++] = c;
	}

	out[outPos] = '\0';
	return false;
}
