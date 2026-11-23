GlobalForward gH_OnRankUpdated;

void CreateNatives()
{
	CreateNative("GOKZ_PF_GetRank", Native_GetRank);
	CreateNative("GOKZ_PF_SetClanTagSuffix", Native_SetClanTagSuffix);
	CreateNative("GOKZ_PF_SetClanTagStatus", Native_SetClanTagStatus);
}

void CreateGlobalForwards()
{
	gH_OnRankUpdated = new GlobalForward("GOKZ_PF_OnRankUpdated", ET_Ignore, Param_Cell, Param_Cell, Param_Cell);
}

void Call_OnRankUpdated(int client, int mode, int rank)
{
	Call_StartForward(gH_OnRankUpdated);
	Call_PushCell(client);
	Call_PushCell(mode);
	Call_PushCell(rank);
	Call_Finish();
}

public int Native_GetRank(Handle plugin, int numParams)
{
	int client = GetNativeCell(1);
	int mode = GetNativeCell(2);
	if (client <= 0 || client > MaxClients || mode < 0 || mode >= MODE_COUNT)
	{
		return 0;
	}

	return gI_Rank[client][mode];
}

public int Native_SetClanTagSuffix(Handle plugin, int numParams)
{
	return SetNativeSuffix(plugin, 0);
}

public int Native_SetClanTagStatus(Handle plugin, int numParams)
{
	return SetNativeSuffix(plugin, 1);
}

int SetNativeSuffix(Handle plugin, int layer)
{
	int client = GetNativeCell(1);
	if (client < 1 || client > MaxClients || !IsClientInGame(client) || IsFakeClient(client))
	{
		return ThrowNativeError(SP_ERROR_NATIVE, "Expected an in-game human client, got %d", client);
	}

	char suffix[CLAN_TAG_BYTES];
	GetNativeString(2, suffix, sizeof(suffix));
	SetClanTagSuffix(client, plugin, suffix, layer);
	return 0;
}
