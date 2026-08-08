#pragma semicolon 1

#define GOKZ_TOP_GLOBAL_REFRESH_INTERVAL 60
#define GOKZ_TOP_GLOBAL_MODE_COUNT 3

bool gB_GlobalAPIAvailable;
bool gB_GokzGlobalAvailable;
bool gB_GlobalRefreshInFlight;
bool gB_GlobalModeAvailable[GOKZ_TOP_GLOBAL_MODE_COUNT];
int gI_GlobalLastRefresh;
Handle gH_GlobalRefreshTimer;

static int gI_GlobalModeIds[GOKZ_TOP_GLOBAL_MODE_COUNT] = {200, 201, 202};
static int gI_GlobalModes[GOKZ_TOP_GLOBAL_MODE_COUNT] = {Mode_KZTimer, Mode_SimpleKZ, Mode_Vanilla};

void InitializeGlobalStatus()
{
	gI_GlobalLastRefresh = 0;
	gB_GlobalRefreshInFlight = false;
	RefreshGlobalStatusLibraries();
}

void RefreshGlobalStatusLibraries()
{
	gB_GlobalAPIAvailable = LibraryExists("GlobalAPI");
	gB_GokzGlobalAvailable = LibraryExists("gokz-global");
}

void UpdateGlobalStatusLibrary(const char[] name, bool added)
{
	if (StrEqual(name, "GlobalAPI"))
	{
		gB_GlobalAPIAvailable = added;
	}
	else if (StrEqual(name, "gokz-global"))
	{
		gB_GokzGlobalAvailable = added;
	}
	if (!gB_GlobalAPIAvailable || !gB_GokzGlobalAvailable)
	{
		for (int mode = 0; mode < GOKZ_TOP_GLOBAL_MODE_COUNT; mode++)
		{
			gB_GlobalModeAvailable[mode] = false;
		}
	}
	if (added)
	{
		QueueGlobalStatusRefresh();
	}
}

void QueueGlobalStatusRefresh()
{
	delete gH_GlobalRefreshTimer;
	gH_GlobalRefreshTimer = CreateTimer(0.2, Timer_RefreshGlobalStatus);
}

public Action Timer_RefreshGlobalStatus(Handle timer)
{
	gH_GlobalRefreshTimer = null;
	RefreshGlobalStatus();
	return Plugin_Stop;
}

void RefreshGlobalStatus()
{
	if (gB_GlobalRefreshInFlight || !gB_GlobalAPIAvailable || !gB_GokzGlobalAvailable)
	{
		return;
	}
	if (GetTime() - gI_GlobalLastRefresh < GOKZ_TOP_GLOBAL_REFRESH_INTERVAL)
	{
		return;
	}
	if (!GlobalAPI_IsInit() || !GlobalAPI_HasAPIKey())
	{
		for (int mode = 0; mode < GOKZ_TOP_GLOBAL_MODE_COUNT; mode++)
		{
			gB_GlobalModeAvailable[mode] = false;
		}
		gI_GlobalLastRefresh = GetTime();
		return;
	}

	char mapName[PLATFORM_MAX_PATH];
	GetMapDisplayName(gC_CurrentMap, mapName, sizeof(mapName));
	gB_GlobalRefreshInFlight = true;
	if (!GlobalAPI_GetMapByName(GlobalStatus_MapCallback, _, mapName))
	{
		gB_GlobalRefreshInFlight = false;
	}
}

public void GlobalStatus_MapCallback(JSON_Object mapJson, GlobalAPIRequestData request)
{
	if (request.Failure || !mapJson)
	{
		GlobalStatus_FinishRefresh();
		return;
	}

	APIMap map = view_as<APIMap>(mapJson);
	int mapId = map.Id;
	if (mapId <= 0)
	{
		GlobalStatus_FinishRefresh();
		return;
	}

	int mapIds[1];
	mapIds[0] = mapId;
	int stages[1];
	stages[0] = 0;
	int tickRates[1];
	tickRates[0] = 128;
	if (!GlobalAPI_GetRecordFilters(
		GlobalStatus_FiltersCallback,
		_,
		_,
		_,
		mapIds,
		1,
		stages,
		1,
		gI_GlobalModeIds,
		GOKZ_TOP_GLOBAL_MODE_COUNT,
		tickRates,
		1,
		DEFAULT_BOOL,
		false))
	{
		GlobalStatus_FinishRefresh();
	}
}

public void GlobalStatus_FiltersCallback(JSON_Object filtersJson, GlobalAPIRequestData request)
{
	for (int mode = 0; mode < GOKZ_TOP_GLOBAL_MODE_COUNT; mode++)
	{
		gB_GlobalModeAvailable[mode] = false;
	}
	if (!request.Failure && filtersJson && filtersJson.IsArray)
	{
		for (int index = 0; index < filtersJson.Length; index++)
		{
			APIIterable filters = view_as<APIIterable>(filtersJson);
			APIRecordFilter filter = view_as<APIRecordFilter>(filters.GetById(index));
			for (int mode = 0; mode < GOKZ_TOP_GLOBAL_MODE_COUNT; mode++)
			{
				if (filter.ModeId == gI_GlobalModeIds[mode] && GOKZ_GetModeLoaded(gI_GlobalModes[mode]))
				{
					gB_GlobalModeAvailable[mode] = true;
				}
			}
		}
	}
	GlobalStatus_FinishRefresh();
}

void GlobalStatus_FinishRefresh()
{
	gB_GlobalRefreshInFlight = false;
	gI_GlobalLastRefresh = GetTime();
	QueueImmediateHeartbeat();
}

void BuildGlobalStatusJSON(char[] buffer, int maxLength)
{
	char checkedAt[GOKZ_TOP_TIMESTAMP_LENGTH];
	FormatGlobalStatusTime(checkedAt, sizeof(checkedAt), gI_GlobalLastRefresh > 0 ? gI_GlobalLastRefresh : GetTime());
	bool apiKeyValid = gB_GokzGlobalAvailable && GOKZ_GL_GetAPIKeyValid();
	bool pluginsValid = gB_GokzGlobalAvailable && GOKZ_GL_GetPluginsValid();
	bool settingsValid = gB_GokzGlobalAvailable && GOKZ_GL_GetSettingsEnforcerValid();
	bool mapValid = gB_GokzGlobalAvailable && GOKZ_GL_GetMapValid();
	Format(buffer, maxLength,
		"{\"api_key_valid\":%s,\"plugins_valid\":%s,\"settings_enforcer_valid\":%s,\"map_valid\":%s,\"modes\":{\"KZT\":%s,\"SKZ\":%s,\"VNL\":%s},\"checked_at\":\"%s\"}",
		apiKeyValid ? "true" : "false",
		pluginsValid ? "true" : "false",
		settingsValid ? "true" : "false",
		mapValid ? "true" : "false",
		gB_GlobalModeAvailable[0] ? "true" : "false",
		gB_GlobalModeAvailable[1] ? "true" : "false",
		gB_GlobalModeAvailable[2] ? "true" : "false",
		checkedAt);
}

void FormatGlobalStatusTime(char[] buffer, int maxLength, int timestamp)
{
	char raw[GOKZ_TOP_TIMESTAMP_LENGTH];
	FormatTime(raw, sizeof(raw), "%Y-%m-%dT%H:%M:%S%z", timestamp);
	int length = strlen(raw);
	if (length >= 24 && (raw[length - 5] == '+' || raw[length - 5] == '-'))
	{
		char sign = raw[length - 5];
		char hourA = raw[length - 4];
		char hourB = raw[length - 3];
		char minuteA = raw[length - 2];
		char minuteB = raw[length - 1];
		raw[length - 5] = '\0';
		Format(buffer, maxLength, "%s%c%c%c:%c%c", raw, sign, hourA, hourB, minuteA, minuteB);
		return;
	}
	strcopy(buffer, maxLength, raw);
}
