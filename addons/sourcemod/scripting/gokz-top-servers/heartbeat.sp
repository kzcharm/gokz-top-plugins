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
	char globalStatus[GOKZ_TOP_GLOBAL_STATUS_LENGTH];

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
	BuildGlobalStatusJSON(globalStatus, sizeof(globalStatus));
	if (!AppendJSONString(encoded, sizeof(encoded) - 1, ",\"global_status\":"))
	{
		LogError("[gokz-top-servers] Failed to append global status payload");
		return;
	}
	if (!AppendJSONString(encoded, sizeof(encoded) - 1, globalStatus)
		|| !AppendJSONString(encoded, sizeof(encoded) - 1, "}"))
	{
		LogError("[gokz-top-servers] Global status payload exceeded heartbeat buffer");
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
	char escapedHostname[GOKZ_TOP_HOSTNAME_LENGTH * 6];
	char escapedMap[PLATFORM_MAX_PATH * 6];
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

	if (!AppendJSONString(buffer, maxLength, "]"))
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
	char escapedName[MAX_NAME_LENGTH * 6];
	char escapedMode[16];
	char escapedSteamID64[GOKZ_TOP_STEAMID64_LENGTH * 6];
	char escapedClanTag[GOKZ_TOP_CLAN_TAG_LENGTH * 6];
	char tagValue[(GOKZ_TOP_CLAN_TAG_LENGTH * 6) + 4];
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
	char hexDigits[] = "0123456789abcdef";
	int written = 0;
	for (int i = 0; input[i] != '\0' && written < maxLength - 1; i++)
	{
		if ((input[i] == '"' || input[i] == '\\') && written < maxLength - 2)
		{
			output[written++] = '\\';
			output[written++] = input[i];
			continue;
		}

		int value = input[i];
		if (value < 0)
		{
			value += 256;
		}

		if (value < 0x20)
		{
			if (written >= maxLength - 6)
			{
				break;
			}

			output[written++] = '\\';
			output[written++] = 'u';
			output[written++] = '0';
			output[written++] = '0';
			output[written++] = hexDigits[(value >> 4) & 0x0f];
			output[written++] = hexDigits[value & 0x0f];
			continue;
		}

		if (value >= 0x80)
		{
			int sequenceLength = GetUTF8SequenceLength(value);
			if (IsValidUTF8Sequence(input, i, sequenceLength))
			{
				if (written >= maxLength - sequenceLength)
				{
					break;
				}

				for (int offset = 0; offset < sequenceLength; offset++)
				{
					output[written++] = input[i + offset];
				}
				i += sequenceLength - 1;
				continue;
			}

			if (written >= maxLength - 6)
			{
				break;
			}

			output[written++] = '\\';
			output[written++] = 'u';
			output[written++] = '0';
			output[written++] = '0';
			output[written++] = hexDigits[(value >> 4) & 0x0f];
			output[written++] = hexDigits[value & 0x0f];
			continue;
		}

		output[written++] = input[i];
	}

	output[written] = '\0';
}

int NormalizeStringByte(int value)
{
	if (value < 0)
	{
		return value + 256;
	}

	return value;
}

int GetUTF8SequenceLength(int value)
{
	if (value >= 0xc2 && value <= 0xdf)
	{
		return 2;
	}
	if (value >= 0xe0 && value <= 0xef)
	{
		return 3;
	}
	if (value >= 0xf0 && value <= 0xf4)
	{
		return 4;
	}

	return 0;
}

bool IsUTF8ContinuationByte(int value)
{
	return (value & 0xc0) == 0x80;
}

bool IsValidUTF8Sequence(const char[] input, int index, int sequenceLength)
{
	if (sequenceLength <= 1)
	{
		return false;
	}

	for (int offset = 1; offset < sequenceLength; offset++)
	{
		if (input[index + offset] == '\0')
		{
			return false;
		}

		if (!IsUTF8ContinuationByte(NormalizeStringByte(input[index + offset])))
		{
			return false;
		}
	}

	int first = NormalizeStringByte(input[index]);
	int second = NormalizeStringByte(input[index + 1]);
	if (sequenceLength == 3)
	{
		return (first != 0xe0 || second >= 0xa0)
			&& (first != 0xed || second <= 0x9f);
	}
	if (sequenceLength == 4)
	{
		return (first != 0xf0 || second >= 0x90)
			&& (first != 0xf4 || second <= 0x8f);
	}

	return true;
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
