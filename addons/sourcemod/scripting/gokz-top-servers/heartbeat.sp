void CreateHeartbeatTimer()
{
	delete gH_HeartbeatTimer;
	gH_HeartbeatTimer = CreateTimer(gCV_PushInterval.FloatValue, Timer_SendHeartbeat, _, TIMER_REPEAT);
}

void QueueImmediateHeartbeat(float delay = 0.1)
{
	delete gH_QueuedHeartbeatTimer;
	gH_QueuedHeartbeatTimer = CreateTimer(delay, Timer_SendQueuedHeartbeat);
}

public Action Timer_SendHeartbeat(Handle timer)
{
	SendServerHeartbeat();
	return Plugin_Continue;
}

public Action Timer_SendQueuedHeartbeat(Handle timer)
{
	gH_QueuedHeartbeatTimer = null;
	SendServerHeartbeat();
	return Plugin_Stop;
}

void SendServerHeartbeat()
{
	TryRefreshPublicIPIfNeeded();
	if (!HasFreshPublicIP())
	{
		return;
	}

	if (gCV_Hostname == null || gCV_HostPort == null)
	{
		LogError("[gokz-top-servers] Missing hostname or hostport convar");
		return;
	}

	char observedAt[GOKZ_TOP_TIMESTAMP_LENGTH];
	char hostname[GOKZ_TOP_HOSTNAME_LENGTH];
	char encoded[GOKZ_TOP_STATUS_BODY_LENGTH];

	FormatLocalISOTime(observedAt, sizeof(observedAt));
	gCV_Hostname.GetString(hostname, sizeof(hostname));
	if (!BuildServerHeartbeatPayload(
		hostname,
		observedAt,
		encoded,
		sizeof(encoded)))
	{
		LogError("[gokz-top-servers] Server heartbeat payload exceeded %d bytes", sizeof(encoded) - 1);
		return;
	}

	GOKZTop_PostJSON(GOKZ_TOP_STATUS_PATH, encoded);
}

bool BuildServerHeartbeatPayload(
	const char[] hostname,
	const char[] observedAt,
	char[] buffer,
	int maxLength)
{
	char escapedHostname[GOKZ_TOP_HOSTNAME_LENGTH * 2];
	char escapedMap[PLATFORM_MAX_PATH * 2];
	int playerCount = GetHeartbeatPlayerCount();
	int maxPlayers = GetHeartbeatMaxPlayers();
	EscapeJSONString(hostname, escapedHostname, sizeof(escapedHostname));
	EscapeJSONString(gC_CurrentMap, escapedMap, sizeof(escapedMap));

	Format(buffer, maxLength,
		"{\"ip\":\"%s\",\"port\":%d,\"observed_at\":\"%s\",\"hostname\":\"%s\",\"map\":\"%s\",\"player_count\":%d,\"max_players\":%d,\"players\":[",
		gC_PublicIP,
		gCV_HostPort.IntValue,
		observedAt,
		escapedHostname,
		escapedMap,
		playerCount,
		maxPlayers);

	bool first = true;
	for (int client = 1; client <= MaxClients; client++)
	{
		if (!IsClientReadyForHeartbeat(client))
		{
			continue;
		}

		char playerJSON[768];
		if (!BuildPlayerHeartbeatJSON(client, playerJSON, sizeof(playerJSON)))
		{
			return false;
		}

		if (!first && !AppendJSONString(buffer, maxLength, ","))
		{
			return false;
		}
		if (!AppendJSONString(buffer, maxLength, playerJSON))
		{
			return false;
		}

		first = false;
		playerCount++;
	}

	if (!AppendJSONString(buffer, maxLength, "]}"))
	{
		return false;
	}
	return true;
}

bool BuildPlayerHeartbeatJSON(int client, char[] buffer, int maxLength)
{
	TrackClient(client);

	char name[MAX_NAME_LENGTH];
	char steamid64[GOKZ_TOP_STEAMID64_LENGTH];
	char clanTag[GOKZ_TOP_CLAN_TAG_LENGTH];
	char mode[8];
	char status[16];
	char escapedName[MAX_NAME_LENGTH * 2];
	char escapedMode[16];
	char escapedSteamID64[GOKZ_TOP_STEAMID64_LENGTH * 2];
	char escapedClanTag[GOKZ_TOP_CLAN_TAG_LENGTH * 2];
	char tagValue[(GOKZ_TOP_CLAN_TAG_LENGTH * 2) + 4];
	char timerValue[32];
	char stageValue[16];

	GetClientName(client, name, sizeof(name));
	GetClientAuthId(client, AuthId_SteamID64, steamid64, sizeof(steamid64), true);
	GetClientClanTagText(client, clanTag, sizeof(clanTag));
	GetPlayerMode(client, mode, sizeof(mode));
	GetPlayerStatusValue(client, status, sizeof(status));

	EscapeJSONString(name, escapedName, sizeof(escapedName));
	EscapeJSONString(mode, escapedMode, sizeof(escapedMode));
	EscapeJSONString(steamid64, escapedSteamID64, sizeof(escapedSteamID64));
	EscapeJSONString(clanTag, escapedClanTag, sizeof(escapedClanTag));

	if (escapedClanTag[0] == '\0')
	{
		strcopy(tagValue, sizeof(tagValue), "null");
	}
	else
	{
		Format(tagValue, sizeof(tagValue), "\"%s\"", escapedClanTag);
	}

	float timerTime = GetPlayerTimerTime(client);
	if (timerTime >= 0.0)
	{
		Format(timerValue, sizeof(timerValue), "%.3f", timerTime);
	}
	else
	{
		strcopy(timerValue, sizeof(timerValue), "null");
	}

	int stage = GetPlayerStage(client);
	if (stage >= 0)
	{
		Format(stageValue, sizeof(stageValue), "%d", stage);
	}
	else
	{
		strcopy(stageValue, sizeof(stageValue), "null");
	}

	Format(buffer, maxLength,
		"{\"tag\":%s,\"mode\":\"%s\",\"name\":\"%s\",\"score\":%d,\"status\":\"%s\",\"duration_seconds\":%.3f,\"is_paused\":%s,\"steamid64\":\"%s\",\"teleports\":%d,\"timer_time\":%s,\"stage\":%s}",
		tagValue,
		escapedMode,
		escapedName,
		GetClientScore(client),
		status,
		float(GetTime() - gI_ClientConnectedAt[client]),
		GOKZ_GetTimerRunning(client) && GOKZ_GetPaused(client) ? "true" : "false",
		escapedSteamID64,
		GetPlayerTeleports(client),
		timerValue,
		stageValue);

	return strlen(buffer) < maxLength - 1;
}

bool AppendJSONString(char[] buffer, int maxLength, const char[] suffix)
{
	if ((strlen(buffer) + strlen(suffix)) >= maxLength)
	{
		return false;
	}

	StrCat(buffer, maxLength, suffix);
	return true;
}

int GetHeartbeatPlayerCount()
{
	int playerCount = 0;
	for (int client = 1; client <= MaxClients; client++)
	{
		if (IsClientReadyForHeartbeat(client))
		{
			playerCount++;
		}
	}

	return playerCount;
}

int GetHeartbeatMaxPlayers()
{
	int maxPlayers = GetMaxHumanPlayers();
	if (maxPlayers > 0)
	{
		return maxPlayers;
	}

	return MaxClients;
}

void EscapeJSONString(const char[] input, char[] output, int maxLength)
{
	int written = 0;
	for (int i = 0; input[i] != '\0' && written < maxLength - 1; i++)
	{
		if ((input[i] == '"' || input[i] == '\\') && written < maxLength - 2)
		{
			output[written++] = '\\';
			output[written++] = input[i];
			continue;
		}

		output[written++] = input[i];
	}

	output[written] = '\0';
}

void FormatLocalISOTime(char[] buffer, int maxLength)
{
	char raw[GOKZ_TOP_TIMESTAMP_LENGTH];
	FormatTime(raw, sizeof(raw), "%Y-%m-%dT%H:%M:%S%z", GetTime());

	int length = strlen(raw);
	if (length >= 24 && (raw[length - 5] == '+' || raw[length - 5] == '-'))
	{
		char sign = raw[length - 5];
		char hourA = raw[length - 4];
		char hourB = raw[length - 3];
		char minuteA = raw[length - 2];
		char minuteB = raw[length - 1];
		raw[length - 5] = '\0';
		Format(buffer, maxLength, "%s%c%c%c:%c%c",
			raw,
			sign, hourA, hourB, minuteA, minuteB);
		return;
	}

	strcopy(buffer, maxLength, raw);
}
