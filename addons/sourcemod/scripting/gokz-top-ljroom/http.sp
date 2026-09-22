void BeginMapLoad()
{
	gI_LoadGeneration++;
	gB_DataReady = false;
	gB_DataLoading = true;
	gA_Spots.Clear();

	GetCurrentMap(gC_CurrentMap, sizeof(gC_CurrentMap));
	NormalizeMapName(gC_CurrentMap, sizeof(gC_CurrentMap));
	if (!RequestLJRooms(gI_LoadGeneration, gC_CurrentMap))
	{
		gB_DataLoading = false;
		LogError("[gokz-top-ljroom] event=request_start_failed map=%s", gC_CurrentMap);
	}
}

bool RequestLJRooms(int generation, const char[] mapName)
{
	char encodedMapName[PLATFORM_MAX_PATH * 3];
	URLEncode(mapName, encodedMapName, sizeof(encodedMapName));

	char path[PLATFORM_MAX_PATH * 4];
	FormatEx(path, sizeof(path), "/v1/maps/lj-rooms?map_name=%s", encodedMapName);

	char url[512];
	if (!BuildAPIURL(path, url, sizeof(url)))
	{
		return false;
	}

	Handle request = SteamWorks_CreateHTTPRequest(k_EHTTPMethodGET, url);
	if (request == null)
	{
		return false;
	}

	DataPack pack = new DataPack();
	pack.WriteCell(generation);
	pack.WriteString(mapName);
	SteamWorks_SetHTTPRequestContextValue(request, pack);
	SteamWorks_SetHTTPCallbacks(request, OnLJRoomsHTTPComplete);
	SteamWorks_SetHTTPRequestHeaderValue(request, "Accept", "application/json");
	SteamWorks_SetHTTPRequestHeaderValue(request, "User-Agent", LJROOM_USER_AGENT);
	SteamWorks_SetHTTPRequestHeaderValue(request, "X-Request-Origin", LJROOM_USER_AGENT);
	SteamWorks_SetHTTPRequestUserAgentInfo(request, LJROOM_USER_AGENT);
	SteamWorks_SetHTTPRequestAbsoluteTimeoutMS(request, gCV_RequestTimeout.IntValue * 1000);

	if (!SteamWorks_SendHTTPRequest(request))
	{
		delete pack;
		delete request;
		return false;
	}

	LogMessage("[gokz-top-ljroom] event=request_started map=%s generation=%d", mapName, generation);
	return true;
}

public void OnLJRoomsHTTPComplete(
	Handle request,
	bool failure,
	bool requestSuccessful,
	EHTTPStatusCode statusCode,
	DataPack pack
)
{
	pack.Reset();
	int generation = pack.ReadCell();
	char mapName[PLATFORM_MAX_PATH];
	pack.ReadString(mapName, sizeof(mapName));
	delete pack;

	if (generation != gI_LoadGeneration || !StrEqual(mapName, gC_CurrentMap))
	{
		delete request;
		return;
	}

	gB_DataLoading = false;
	if (failure || !requestSuccessful || statusCode != k_EHTTPStatusCode200OK)
	{
		LogError(
			"[gokz-top-ljroom] event=request_failed map=%s failure=%d request_successful=%d status=%d",
			mapName,
			failure,
			requestSuccessful,
			statusCode
		);
		delete request;
		return;
	}

	int responseLength;
	if (!SteamWorks_GetHTTPResponseBodySize(request, responseLength)
		|| responseLength <= 0
		|| responseLength >= sizeof(gC_ResponseBuffer))
	{
		LogError(
			"[gokz-top-ljroom] event=response_size_invalid map=%s bytes=%d limit=%d",
			mapName,
			responseLength,
			sizeof(gC_ResponseBuffer) - 1
		);
		delete request;
		return;
	}

	if (!SteamWorks_GetHTTPResponseBodyData(request, gC_ResponseBuffer, responseLength))
	{
		LogError("[gokz-top-ljroom] event=response_read_failed map=%s", mapName);
		delete request;
		return;
	}
	gC_ResponseBuffer[responseLength] = '\0';
	delete request;

	int spotCount;
	if (!ParseLJRoomsResponse(gC_ResponseBuffer, mapName, spotCount))
	{
		LogError("[gokz-top-ljroom] event=response_parse_failed map=%s", mapName);
		return;
	}

	gB_DataReady = true;
	LogMessage(
		"[gokz-top-ljroom] event=rooms_loaded map=%s spots=%d generation=%d",
		mapName,
		spotCount,
		generation
	);
}

bool BuildAPIURL(const char[] path, char[] url, int maxLength)
{
	char baseURL[256];
	gCV_APIBaseURL.GetString(baseURL, sizeof(baseURL));
	TrimString(baseURL);
	if (baseURL[0] == '\0')
	{
		return false;
	}

	int length = strlen(baseURL);
	if (baseURL[length - 1] == '/')
	{
		baseURL[length - 1] = '\0';
	}

	char suffix[PLATFORM_MAX_PATH * 4];
	strcopy(suffix, sizeof(suffix), path);
	if (StrContains(path, "/v1/", false) == 0
		&& (EndsWith(baseURL, "/v1") || EndsWith(baseURL, "/api/v1")))
	{
		strcopy(suffix, sizeof(suffix), path[3]);
	}

	FormatEx(url, maxLength, "%s%s", baseURL, suffix);
	return true;
}

bool EndsWith(const char[] value, const char[] suffix)
{
	int valueLength = strlen(value);
	int suffixLength = strlen(suffix);
	return suffixLength <= valueLength
		&& StrEqual(value[valueLength - suffixLength], suffix, false);
}

void URLEncode(const char[] input, char[] output, int maxLength)
{
	static const char hex[] = "0123456789ABCDEF";
	int outputLength;
	for (int index = 0; input[index] != '\0' && outputLength < maxLength - 1; index++)
	{
		int character = input[index] & 0xFF;
		if ((character >= 'a' && character <= 'z')
			|| (character >= 'A' && character <= 'Z')
			|| (character >= '0' && character <= '9')
			|| character == '-'
			|| character == '_'
			|| character == '.'
			|| character == '~')
		{
			output[outputLength++] = character;
		}
		else if (outputLength + 3 < maxLength)
		{
			output[outputLength++] = '%';
			output[outputLength++] = hex[(character >> 4) & 0x0F];
			output[outputLength++] = hex[character & 0x0F];
		}
	}
	output[outputLength] = '\0';
}

void NormalizeMapName(char[] mapName, int maxLength)
{
	ReplaceString(mapName, maxLength, "\\", "/");
	int slash = FindCharInString(mapName, '/', true);
	if (slash != -1)
	{
		char displayName[PLATFORM_MAX_PATH];
		strcopy(displayName, sizeof(displayName), mapName[slash + 1]);
		strcopy(mapName, maxLength, displayName);
	}
	int extension = StrContains(mapName, ".bsp", false);
	if (extension != -1)
	{
		mapName[extension] = '\0';
	}
}
