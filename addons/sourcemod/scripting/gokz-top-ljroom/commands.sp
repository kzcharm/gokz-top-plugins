void RegisterCommands()
{
	RegConsoleCmd("sm_lj", Command_LJ, "Teleport to a detected LJ block. Usage: !lj [distance]");
	RegConsoleCmd("sm_ljroom", Command_LJ, "Teleport to a detected LJ block. Usage: !ljroom [distance]");
	RegConsoleCmd("sm_ljdefault", Command_LJDefault, "Set the default LJ block distance. Usage: !ljdefault <distance>");
	RegAdminCmd("sm_ljreload", Command_Reload, ADMFLAG_ROOT, "Reload detected LJ blocks for the current map.");
	RegAdminCmd("sm_reloadlj", Command_Reload, ADMFLAG_ROOT, "Reload detected LJ blocks for the current map.");
}

public Action Command_LJ(int client, int args)
{
	if (!IsUsableClient(client))
	{
		return Plugin_Handled;
	}
	if (!IsPlayerAlive(client))
	{
		GOKZ_PrintToChat(client, true, "%t", "LJ Room - Must Be Alive");
		return Plugin_Handled;
	}
	if (GOKZ_GetCoreOption(client, Option_Safeguard) > Safeguard_Disabled
		&& GOKZ_GetTimerRunning(client) && GOKZ_GetValidTimer(client))
	{
		GOKZ_PrintToChat(client, true, "%t", "LJ Room - Safeguard Blocked");
		GOKZ_PlayErrorSound(client);
		return Plugin_Handled;
	}

	int requestedDistance = GetDefaultDistance(client);
	if (args > 1)
	{
		GOKZ_PrintToChat(client, true, "%t", "LJ Room - Usage");
		return Plugin_Handled;
	}
	if (args == 1)
	{
		char argument[32];
		GetCmdArg(1, argument, sizeof(argument));
		int parsedCharacters = StringToIntEx(argument, requestedDistance);
		if (parsedCharacters != strlen(argument) || requestedDistance <= 0)
		{
			GOKZ_PrintToChat(client, true, "%t", "LJ Room - Usage");
			return Plugin_Handled;
		}
	}

	if (!gB_DataReady)
	{
		GOKZ_PrintToChat(
			client,
			true,
			"%t",
			gB_DataLoading ? "LJ Room - Data Loading" : "LJ Room - Data Unavailable"
		);
		return Plugin_Handled;
	}
	if (gA_Spots.Length == 0)
	{
		GOKZ_PrintToChat(client, true, "%t", "LJ Room - Not Detected");
		return Plugin_Handled;
	}

	int bestIndex = FindBestSpot(requestedDistance);
	int spot[Spot_FieldCount];
	gA_Spots.GetArray(bestIndex, spot, sizeof(spot));

	float origin[3];
	origin[0] = view_as<float>(spot[Spot_OriginX]);
	origin[1] = view_as<float>(spot[Spot_OriginY]);
	origin[2] = view_as<float>(spot[Spot_OriginZ]);
	float angles[3];
	angles[0] = view_as<float>(spot[Spot_Pitch]);
	angles[1] = view_as<float>(spot[Spot_Yaw]);
	angles[2] = 0.0;
	if (GOKZ_GetTimerRunning(client))
	{
		if (!GOKZ_StopTimer(client, true) || GOKZ_GetTimerRunning(client))
		{
			GOKZ_PrintToChat(client, true, "%t", "LJ Room - Timer Stop Failed");
			GOKZ_PlayErrorSound(client);
			return Plugin_Handled;
		}
		GOKZ_PrintToChat(client, true, "%t", "LJ Room - Timer Stopped");
	}
	TeleportPlayer(client, origin, angles);

	int actualDistance = spot[Spot_Distance];
	if (actualDistance == requestedDistance)
	{
		GOKZ_PrintToChat(client, true, "%t", "LJ Room - Exact Teleport", actualDistance);
	}
	else
	{
		GOKZ_PrintToChat(
			client,
			true,
			"%t",
			"LJ Room - Nearest Teleport",
			requestedDistance,
			actualDistance
		);
	}
	return Plugin_Handled;
}

public Action Command_LJDefault(int client, int args)
{
	if (!IsUsableClient(client))
	{
		return Plugin_Handled;
	}
	if (args > 1)
	{
		GOKZ_PrintToChat(client, true, "%t", "LJ Room - Default Usage");
		return Plugin_Handled;
	}
	if (!AreClientCookiesCached(client))
	{
		GOKZ_PrintToChat(client, true, "%t", "LJ Room - Preferences Loading");
		return Plugin_Handled;
	}
	if (args == 0)
	{
		GOKZ_PrintToChat(client, true, "%t", "LJ Room - Default Current", GetDefaultDistance(client));
		return Plugin_Handled;
	}

	char argument[32];
	GetCmdArg(1, argument, sizeof(argument));
	int distance;
	int parsedCharacters = StringToIntEx(argument, distance);
	if (parsedCharacters != strlen(argument) || distance <= 0)
	{
		GOKZ_PrintToChat(client, true, "%t", "LJ Room - Default Usage");
		return Plugin_Handled;
	}

	gC_DefaultDistance.Set(client, argument);
	GOKZ_PrintToChat(client, true, "%t", "LJ Room - Default Set", distance);
	return Plugin_Handled;
}

public Action Command_Reload(int client, int args)
{
	BeginMapLoad();
	ReplyToCommand(client, "[LJ] Reloading detected LJ blocks for the current map.");
	return Plugin_Handled;
}

int GetDefaultDistance(int client)
{
	if (!AreClientCookiesCached(client))
	{
		return LJROOM_DEFAULT_DISTANCE;
	}

	char value[32];
	gC_DefaultDistance.Get(client, value, sizeof(value));
	int distance;
	int parsedCharacters = StringToIntEx(value, distance);
	return parsedCharacters == strlen(value) && distance > 0 ? distance : LJROOM_DEFAULT_DISTANCE;
}

int FindBestSpot(int requestedDistance)
{
	int bestIndex;
	int bestDifference = 2147483647;
	int bestRoomRank = 2147483647;
	int bestDistance = 2147483647;
	float bestX;
	float bestY;
	float bestZ;

	int spot[Spot_FieldCount];
	for (int index = 0; index < gA_Spots.Length; index++)
	{
		gA_Spots.GetArray(index, spot, sizeof(spot));
		int difference = spot[Spot_Distance] - requestedDistance;
		if (difference < 0)
		{
			difference = -difference;
		}
		float x = view_as<float>(spot[Spot_OriginX]);
		float y = view_as<float>(spot[Spot_OriginY]);
		float z = view_as<float>(spot[Spot_OriginZ]);
		if (difference < bestDifference
			|| (difference == bestDifference && spot[Spot_RoomRank] < bestRoomRank)
			|| (difference == bestDifference && spot[Spot_RoomRank] == bestRoomRank && spot[Spot_Distance] < bestDistance)
			|| (difference == bestDifference && spot[Spot_RoomRank] == bestRoomRank && spot[Spot_Distance] == bestDistance && CoordinatesBefore(x, y, z, bestX, bestY, bestZ)))
		{
			bestIndex = index;
			bestDifference = difference;
			bestRoomRank = spot[Spot_RoomRank];
			bestDistance = spot[Spot_Distance];
			bestX = x;
			bestY = y;
			bestZ = z;
		}
	}
	return bestIndex;
}

bool CoordinatesBefore(float x, float y, float z, float otherX, float otherY, float otherZ)
{
	if (x != otherX)
	{
		return x < otherX;
	}
	if (y != otherY)
	{
		return y < otherY;
	}
	return z < otherZ;
}

bool IsUsableClient(int client)
{
	return client >= 1 && client <= MaxClients && IsClientInGame(client) && !IsFakeClient(client);
}
