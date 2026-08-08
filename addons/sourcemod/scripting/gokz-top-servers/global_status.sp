#pragma semicolon 1

#define GOKZ_TOP_GLOBAL_REFRESH_INTERVAL 60
#define GOKZ_TOP_GLOBAL_MODE_COUNT 3

bool gB_GlobalAPIAvailable;
bool gB_GokzGlobalAvailable;
bool gB_GlobalRefreshInFlight;
bool gB_GlobalModeAvailable[GOKZ_TOP_GLOBAL_MODE_COUNT];
int gI_GlobalLastRefresh;
Handle gH_GlobalRefreshTimer;

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
	if (!GlobalAPI_IsInit())
	{
		for (int mode = 0; mode < GOKZ_TOP_GLOBAL_MODE_COUNT; mode++)
		{
			gB_GlobalModeAvailable[mode] = false;
		}
		gI_GlobalLastRefresh = GetTime();
		return;
	}

	for (int mode = 0; mode < GOKZ_TOP_GLOBAL_MODE_COUNT; mode++)
	{
		gB_GlobalModeAvailable[mode] = false;
	}
	gB_GlobalRefreshInFlight = true;
	if (!GlobalAPI_GetModes(GlobalStatus_ModesCallback))
	{
		gB_GlobalRefreshInFlight = false;
	}
}

public void GlobalStatus_ModesCallback(JSON_Object modesJson, GlobalAPIRequestData request)
{
	if (request.Failure || !modesJson || !modesJson.IsArray)
	{
		GlobalStatus_FinishRefresh();
		return;
	}

	for (int index = 0; index < modesJson.Length; index++)
	{
		APIMode mode = view_as<APIMode>(modesJson.GetObjectIndexed(index));
		int localMode = GOKZ_GL_FromGlobalMode(view_as<GlobalMode>(mode.Id));
		if (localMode >= Mode_Vanilla && localMode <= Mode_KZTimer
			&& mode.LatestVersion <= GOKZ_GetModeVersion(localMode))
		{
			gB_GlobalModeAvailable[localMode] = true;
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
