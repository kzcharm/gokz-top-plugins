#include <sourcemod>
#include <sdktools>
#include <SteamWorks>

#include <gokz/core>

#define REQUIRE_PLUGIN
#include <gokz/top>
#undef REQUIRE_PLUGIN

#include <gokz/jumpstats>
#include <gokz/replays>

#pragma newdecls required
#pragma semicolon 1

#define GOKZ_TOP_REPLAYS_VERSION "0.1.0"
#define GOKZ_TOP_REPLAYS_USER_AGENT "gokz-top-replays/" ... GOKZ_TOP_REPLAYS_VERSION
#define GOKZ_TOP_REPLAYS_MAX_URL_LENGTH 512
#define GOKZ_TOP_REPLAYS_MAX_PATH_LENGTH 512
#define GOKZ_TOP_REPLAYS_MAX_RESPONSE_LENGTH 1024
#define GOKZ_TOP_REPLAYS_SAVE_DELAY 2.3
#define GOKZ_TOP_REPLAY_MAGIC 0x676F6B7A
#define GOKZ_TOP_REPLAY_FORMAT_VERSION 2

enum struct JumpReplayUploadHeader
{
	char steamID64[32];
	char mode[8];
	char jumpType[8];
	int timestamp;
	float distance;
}

public Plugin myinfo =
{
	name = "GOKZ Top Replays",
	author = "Cinyan10",
	description = "Eligible jump replay uploads for gokz-top",
	version = GOKZ_TOP_REPLAYS_VERSION,
	url = "https://gokz.top"
};

ConVar gCV_APIBaseURL;
ConVar gCV_APIKey;
ConVar gCV_RequestTimeout;
ConVar gCV_Debug;

public void OnPluginStart()
{
	gCV_APIBaseURL = FindConVar("gokz_top_api_base_url");
	gCV_APIKey = FindConVar("gokz_top_api_key");
	gCV_RequestTimeout = FindConVar("gokz_top_request_timeout");
	gCV_Debug = FindConVar("gokz_top_debug");

	if (gCV_APIBaseURL == null || gCV_APIKey == null)
	{
		SetFailState("gokz-top-core is required before gokz-top-replays");
	}
}

public void GOKZ_JS_OnLanding(Jump jump)
{
	if (!IsValidUploadClient(jump.jumper) || !IsRetainableJumpType(jump.type))
	{
		return;
	}

	int mode = GOKZ_GetCoreOption(jump.jumper, Option_Mode);
	int style = GOKZ_GetCoreOption(jump.jumper, Option_Style);
	if (mode < 0 || mode >= MODE_COUNT || style < 0 || style >= STYLE_COUNT)
	{
		return;
	}
	DataPack pack = new DataPack();
	pack.WriteCell(GetClientUserId(jump.jumper));
	pack.WriteCell(jump.type);
	pack.WriteCell(jump.block);
	pack.WriteCell(mode);
	pack.WriteCell(style);
	CreateTimer(GOKZ_TOP_REPLAYS_SAVE_DELAY, Timer_CheckSavedJumpReplay, pack);
}

public Action GOKZ_RP_OnReplaySaved(int client, int replayType, const char[] map, int course, int timeType, float time, const char[] filePath, bool tempReplay)
{
	if (replayType == ReplayType_Jump && IsValidUploadClient(client))
	{
		CheckJumpReplayEligibility(filePath, GetClientUserId(client));
	}

	return Plugin_Continue;
}

public Action Timer_CheckSavedJumpReplay(Handle timer, DataPack pack)
{
	pack.Reset();
	int client = GetClientOfUserId(pack.ReadCell());
	int jumpType = pack.ReadCell();
	int block = pack.ReadCell();
	int mode = pack.ReadCell();
	int style = pack.ReadCell();
	delete pack;

	if (!IsValidUploadClient(client))
	{
		return Plugin_Stop;
	}

	char replayPath[PLATFORM_MAX_PATH];
	FormatJumpReplayPath(replayPath, sizeof(replayPath), client, jumpType, block, mode, style);
	CheckJumpReplayEligibility(replayPath, GetClientUserId(client));
	return Plugin_Stop;
}

void CheckJumpReplayEligibility(const char[] replayPath, int userID)
{
	if (!HasAPIKey() || !FileExists(replayPath))
	{
		return;
	}

	int client = GetClientOfUserId(userID);
	if (!IsValidUploadClient(client))
	{
		return;
	}

	JumpReplayUploadHeader header;
	if (!ReadJumpReplayUploadHeader(replayPath, client, header))
	{
		return;
	}

	char path[GOKZ_TOP_REPLAYS_MAX_PATH_LENGTH];
	Format(path, sizeof(path),
		"/v1/jumpstats/replay-eligibility?player_steamid64=%s&mode=%s&type=%s&distance=%.4f&jumped_at_unix=%d",
		header.steamID64,
		header.mode,
		header.jumpType,
		header.distance,
		header.timestamp);

	char url[GOKZ_TOP_REPLAYS_MAX_URL_LENGTH];
	if (!BuildAPIURL(path, url, sizeof(url)))
	{
		return;
	}

	Handle request = SteamWorks_CreateHTTPRequest(k_EHTTPMethodGET, url);
	if (request == null)
	{
		LogError("[gokz-top-replays] Failed to create eligibility request path=%s", path);
		return;
	}

	DataPack pack = new DataPack();
	pack.WriteCell(userID);
	pack.WriteString(replayPath);
	pack.WriteString(path);

	SteamWorks_SetHTTPRequestContextValue(request, pack);
	SteamWorks_SetHTTPCallbacks(request, OnEligibilityHTTPComplete);
	ApplyCommonHeaders(request, "application/json");
	SteamWorks_SetHTTPRequestAbsoluteTimeoutMS(request, GetRequestTimeoutMS());

	if (gCV_Debug != null && gCV_Debug.BoolValue)
	{
		LogMessage("[gokz-top-replays] GET %s", path);
	}

	if (!SteamWorks_SendHTTPRequest(request))
	{
		LogError("[gokz-top-replays] Failed to send eligibility request path=%s", path);
		delete pack;
		delete request;
	}
}

public void OnEligibilityHTTPComplete(Handle request, bool failure, bool requestSuccessful, EHTTPStatusCode statusCode, DataPack pack)
{
	pack.Reset();
	int userID = pack.ReadCell();
	char replayPath[PLATFORM_MAX_PATH];
	char path[GOKZ_TOP_REPLAYS_MAX_PATH_LENGTH];
	pack.ReadString(replayPath, sizeof(replayPath));
	pack.ReadString(path, sizeof(path));

	if (!IsHTTPResponseOK(failure, requestSuccessful, statusCode))
	{
		LogHTTPFailure(request, "eligibility", path, failure, requestSuccessful, statusCode);
		delete pack;
		delete request;
		return;
	}

	char response[GOKZ_TOP_REPLAYS_MAX_RESPONSE_LENGTH];
	if (!ReadHTTPResponseBody(request, response, sizeof(response)) || !ResponseIsEligible(response))
	{
		if (gCV_Debug != null && gCV_Debug.BoolValue)
		{
			LogMessage("[gokz-top-replays] Replay not eligible path=%s", replayPath);
		}
		delete pack;
		delete request;
		return;
	}

	UploadJumpReplay(replayPath, userID);
	delete pack;
	delete request;
}

void UploadJumpReplay(const char[] replayPath, int userID)
{
	if (!FileExists(replayPath))
	{
		return;
	}

	char url[GOKZ_TOP_REPLAYS_MAX_URL_LENGTH];
	if (!BuildAPIURL("/v1/jumpstats/replay", url, sizeof(url)))
	{
		return;
	}

	Handle request = SteamWorks_CreateHTTPRequest(k_EHTTPMethodPOST, url);
	if (request == null)
	{
		LogError("[gokz-top-replays] Failed to create upload request path=%s", replayPath);
		return;
	}

	DataPack pack = new DataPack();
	pack.WriteCell(userID);
	pack.WriteString(replayPath);

	SteamWorks_SetHTTPRequestContextValue(request, pack);
	SteamWorks_SetHTTPCallbacks(request, OnUploadHTTPComplete);
	ApplyCommonHeaders(request, "application/json");
	ApplyAuthHeader(request);
	SteamWorks_SetHTTPRequestHeaderValue(request, "Content-Type", "application/octet-stream");
	SteamWorks_SetHTTPRequestAbsoluteTimeoutMS(request, GetRequestTimeoutMS());

	if (!SteamWorks_SetHTTPRequestRawPostBodyFromFile(request, "application/octet-stream", replayPath))
	{
		LogError("[gokz-top-replays] Failed to attach replay file path=%s", replayPath);
		delete pack;
		delete request;
		return;
	}

	if (gCV_Debug != null && gCV_Debug.BoolValue)
	{
		LogMessage("[gokz-top-replays] POST /v1/jumpstats/replay path=%s", replayPath);
	}

	if (!SteamWorks_SendHTTPRequest(request))
	{
		LogError("[gokz-top-replays] Failed to send upload request path=%s", replayPath);
		delete pack;
		delete request;
	}
}

public void OnUploadHTTPComplete(Handle request, bool failure, bool requestSuccessful, EHTTPStatusCode statusCode, DataPack pack)
{
	pack.Reset();
	int userID = pack.ReadCell();
	char replayPath[PLATFORM_MAX_PATH];
	pack.ReadString(replayPath, sizeof(replayPath));

	if (!IsHTTPResponseOK(failure, requestSuccessful, statusCode))
	{
		LogHTTPFailure(request, "upload", replayPath, failure, requestSuccessful, statusCode);
	}
	else if (gCV_Debug != null && gCV_Debug.BoolValue)
	{
		int client = GetClientOfUserId(userID);
		LogMessage("[gokz-top-replays] Uploaded jump replay client=%d path=%s", client, replayPath);
	}

	delete pack;
	delete request;
}

bool ReadJumpReplayUploadHeader(const char[] replayPath, int client, JumpReplayUploadHeader header)
{
	File file = OpenFile(replayPath, "rb");
	if (file == null)
	{
		return false;
	}

	int magic;
	int version;
	int replayType;
	if (!file.ReadInt32(magic)
		|| !file.ReadInt8(version)
		|| !file.ReadInt8(replayType)
		|| magic != GOKZ_TOP_REPLAY_MAGIC
		|| version != GOKZ_TOP_REPLAY_FORMAT_VERSION
		|| replayType != ReplayType_Jump)
	{
		delete file;
		return false;
	}

	if (!SkipReplayString(file) || !SkipReplayString(file))
	{
		delete file;
		return false;
	}

	int ignored;
	int timestamp;
	int modeIndex;
	int styleIndex;
	if (!file.ReadInt32(ignored)
		|| !file.ReadInt32(ignored)
		|| !file.ReadInt32(timestamp)
		|| !SkipReplayString(file)
		|| !file.ReadInt32(ignored)
		|| !file.ReadInt8(modeIndex)
		|| !file.ReadInt8(styleIndex))
	{
		delete file;
		return false;
	}

	if (styleIndex != 0 || !GetModeName(modeIndex, header.mode, sizeof(JumpReplayUploadHeader::mode)))
	{
		delete file;
		return false;
	}

	for (int i = 0; i < 6; i++)
	{
		if (!file.ReadInt32(ignored))
		{
			delete file;
			return false;
		}
	}

	int jumpTypeIndex;
	int distanceRaw;
	if (!file.ReadInt8(jumpTypeIndex)
		|| !file.ReadInt32(distanceRaw)
		|| !GetJumpTypeName(jumpTypeIndex, header.jumpType, sizeof(JumpReplayUploadHeader::jumpType)))
	{
		delete file;
		return false;
	}

	if (!GetClientAuthId(client, AuthId_SteamID64, header.steamID64, sizeof(JumpReplayUploadHeader::steamID64), true))
	{
		delete file;
		return false;
	}

	header.timestamp = timestamp;
	header.distance = view_as<float>(distanceRaw);
	delete file;
	return true;
}

bool SkipReplayString(File file)
{
	int length;
	if (!file.ReadInt8(length))
	{
		return false;
	}

	char buffer[256];
	if (length >= sizeof(buffer))
	{
		return false;
	}

	return file.ReadString(buffer, sizeof(buffer), length) == length;
}

bool GetModeName(int modeIndex, char[] buffer, int maxLength)
{
	switch (modeIndex)
	{
		case 0: strcopy(buffer, maxLength, "VNL");
		case 1: strcopy(buffer, maxLength, "SKZ");
		case 2: strcopy(buffer, maxLength, "KZT");
		case 3: strcopy(buffer, maxLength, "NKZ");
		default: return false;
	}
	return true;
}

bool GetJumpTypeName(int jumpTypeIndex, char[] buffer, int maxLength)
{
	switch (jumpTypeIndex)
	{
		case JumpType_LongJump: strcopy(buffer, maxLength, "LJ");
		case JumpType_Bhop: strcopy(buffer, maxLength, "BH");
		case JumpType_MultiBhop: strcopy(buffer, maxLength, "MBH");
		case JumpType_WeirdJump: strcopy(buffer, maxLength, "WJ");
		case JumpType_LadderJump: strcopy(buffer, maxLength, "LAJ");
		case JumpType_Ladderhop: strcopy(buffer, maxLength, "LAH");
		case JumpType_Jumpbug: strcopy(buffer, maxLength, "JB");
		case JumpType_LowpreBhop: strcopy(buffer, maxLength, "LBH");
		case JumpType_LowpreWeirdJump: strcopy(buffer, maxLength, "LWJ");
		default: return false;
	}
	return true;
}

bool IsRetainableJumpType(int jumpType)
{
	char buffer[8];
	return GetJumpTypeName(jumpType, buffer, sizeof(buffer));
}

void FormatJumpReplayPath(char[] buffer, int maxLength, int client, int jumpType, int block, int mode, int style)
{
	if (block > 0)
	{
		BuildPath(Path_SM, buffer, maxLength,
			"%s/%d/%s/%d_%d_%s_%s.%s",
			RP_DIRECTORY_JUMPS,
			GetSteamAccountID(client),
			RP_DIRECTORY_BLOCKJUMPS,
			jumpType,
			block,
			gC_ModeNamesShort[mode],
			gC_StyleNamesShort[style],
			RP_FILE_EXTENSION);
		return;
	}

	BuildPath(Path_SM, buffer, maxLength,
		"%s/%d/%d_%s_%s.%s",
		RP_DIRECTORY_JUMPS,
		GetSteamAccountID(client),
		jumpType,
		gC_ModeNamesShort[mode],
		gC_StyleNamesShort[style],
		RP_FILE_EXTENSION);
}

bool IsValidUploadClient(int client)
{
	return 0 < client <= MaxClients
		&& IsClientInGame(client)
		&& !IsFakeClient(client)
		&& GetSteamAccountID(client) > 0;
}

bool HasAPIKey()
{
	if (gCV_APIKey == null)
	{
		return false;
	}

	char apiKey[4];
	gCV_APIKey.GetString(apiKey, sizeof(apiKey));
	return apiKey[0] != '\0';
}

int GetRequestTimeoutMS()
{
	if (gCV_RequestTimeout == null)
	{
		return 10000;
	}

	return gCV_RequestTimeout.IntValue * 1000;
}

bool BuildAPIURL(const char[] path, char[] url, int maxLength)
{
	if (gCV_APIBaseURL == null)
	{
		return false;
	}

	char baseURL[256];
	gCV_APIBaseURL.GetString(baseURL, sizeof(baseURL));
	TrimString(baseURL);
	if (baseURL[0] == '\0')
	{
		LogError("[gokz-top-replays] gokz_top_api_base_url is empty");
		return false;
	}

	int length = strlen(baseURL);
	if (length > 0 && baseURL[length - 1] == '/')
	{
		baseURL[length - 1] = '\0';
	}

	char suffix[GOKZ_TOP_REPLAYS_MAX_PATH_LENGTH];
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

void ApplyCommonHeaders(Handle request, const char[] accept)
{
	SteamWorks_SetHTTPRequestHeaderValue(request, "Accept", accept);
	SteamWorks_SetHTTPRequestHeaderValue(request, "X-Request-Origin", GOKZ_TOP_REPLAYS_USER_AGENT);
	SteamWorks_SetHTTPRequestHeaderValue(request, "User-Agent", GOKZ_TOP_REPLAYS_USER_AGENT);
	SteamWorks_SetHTTPRequestUserAgentInfo(request, GOKZ_TOP_REPLAYS_USER_AGENT);
}

void ApplyAuthHeader(Handle request)
{
	char apiKey[256];
	gCV_APIKey.GetString(apiKey, sizeof(apiKey));
	TrimString(apiKey);
	if (apiKey[0] != '\0')
	{
		SteamWorks_SetHTTPRequestHeaderValue(request, "X-Server-Group-Key", apiKey);
	}
}

bool IsHTTPResponseOK(bool failure, bool requestSuccessful, EHTTPStatusCode statusCode)
{
	return !failure
		&& requestSuccessful
		&& statusCode >= k_EHTTPStatusCode200OK
		&& statusCode < k_EHTTPStatusCode300MultipleChoices;
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

bool ResponseIsEligible(const char[] response)
{
	return StrContains(response, "\"eligible\":true", false) != -1
		|| StrContains(response, "\"eligible\": true", false) != -1;
}

void LogHTTPFailure(Handle request, const char[] operation, const char[] label, bool failure, bool requestSuccessful, EHTTPStatusCode statusCode)
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
	}

	LogError("[gokz-top-replays] %s failed label=%s failure=%d request_successful=%d status=%d response=%s",
		operation,
		label,
		failure,
		requestSuccessful,
		statusCode,
		response);
}
