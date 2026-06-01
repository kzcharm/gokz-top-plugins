bool IsClientReadyForHeartbeat(int client)
{
	return client > 0
		&& client <= MaxClients
		&& IsClientInGame(client)
		&& !IsFakeClient(client)
		&& IsClientAuthorized(client);
}

void TrackClient(int client)
{
	if (!gB_ClientTracked[client])
	{
		ResetClientRunState(client, false);
		gB_ClientTracked[client] = true;
		gI_ClientConnectedAt[client] = GetTime();
	}

	SyncClientRunState(client);
}

void SyncClientRunState(int client)
{
	if (!gB_ClientTracked[client])
	{
		return;
	}

	if (GOKZ_GetTimerRunning(client))
	{
		CaptureLiveRunState(client);
		gB_ClientHasStarted[client] = true;
		gI_ClientStatus[client] = ServerPlayerStatus_InProgress;
		return;
	}

	if (!gB_ClientHasStarted[client])
	{
		gI_ClientStatus[client] = ServerPlayerStatus_NotStarted;
	}
}

void CaptureLiveRunState(int client)
{
	gI_ClientLastStage[client] = GOKZ_GetCourse(client);
	gI_ClientLastTeleports[client] = GOKZ_GetTeleportCount(client);
	gF_ClientLastTimerTime[client] = GOKZ_GetTime(client);
}

void ResetClientRunState(int client, bool preserveConnection)
{
	gB_ClientTracked[client] = preserveConnection ? gB_ClientTracked[client] : false;
	gB_ClientHasStarted[client] = false;
	gI_ClientStatus[client] = ServerPlayerStatus_NotStarted;
	gI_ClientLastStage[client] = -1;
	gI_ClientLastTeleports[client] = 0;
	gF_ClientLastTimerTime[client] = 0.0;
	if (!preserveConnection)
	{
		gI_ClientConnectedAt[client] = 0;
	}
}

void ClearClientRunState(int client)
{
	ResetClientRunState(client, false);
}

void GetPlayerMode(int client, char[] buffer, int maxLength)
{
	int mode = GOKZ_GetCoreOption(client, Option_Mode);
	if (mode < 0 || mode >= MODE_COUNT)
	{
		strcopy(buffer, maxLength, "");
		return;
	}

	strcopy(buffer, maxLength, gC_ModeNamesShort[mode]);
}

void GetClientClanTagText(int client, char[] buffer, int maxLength)
{
	buffer[0] = '\0';
	CS_GetClientClanTag(client, buffer, maxLength);
}

int GetClientScore(int client)
{
	return CS_GetClientContributionScore(client);
}

void GetPlayerStatusValue(int client, char[] buffer, int maxLength)
{
	if (GOKZ_GetTimerRunning(client))
	{
		strcopy(buffer, maxLength, "in_progress");
		return;
	}

	switch (gI_ClientStatus[client])
	{
		case ServerPlayerStatus_Finished:
		{
			strcopy(buffer, maxLength, "finished");
			return;
		}
		case ServerPlayerStatus_Aborted:
		{
			strcopy(buffer, maxLength, "aborted");
			return;
		}
		default:
		{
			strcopy(buffer, maxLength, "not_started");
			return;
		}
	}
}

int GetPlayerTeleports(int client)
{
	if (GOKZ_GetTimerRunning(client))
	{
		return GOKZ_GetTeleportCount(client);
	}

	return gI_ClientLastTeleports[client];
}

float GetPlayerTimerTime(int client)
{
	if (GOKZ_GetTimerRunning(client))
	{
		return GOKZ_GetTime(client);
	}

	if (!gB_ClientHasStarted[client])
	{
		return -1.0;
	}

	return gF_ClientLastTimerTime[client];
}

int GetPlayerStage(int client)
{
	if (GOKZ_GetTimerRunning(client))
	{
		return GOKZ_GetCourse(client);
	}

	if (!gB_ClientHasStarted[client])
	{
		return -1;
	}

	return gI_ClientLastStage[client];
}
