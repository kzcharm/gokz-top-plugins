char gC_Owner[MAXPLAYERS + 1][32];

bool IsMirror(int client)
{
	return client > 0 && client <= MaxClients && gC_Owner[client][0] && IsClientInGame(client) && IsFakeClient(client);
}

public void OnClientDisconnect(int client)
{
	gC_Owner[client][0] = 0;
}

public Action GOKZ_OnTimerStart(int client, int course)
{
	return IsMirror(client) ? Plugin_Handled : Plugin_Continue;
}

public void OnEntityCreated(int entity, const char[] classname)
{
	if (StrContains(classname, "trigger_") == 0) HookTrigger(entity);
}

void HookTrigger(int entity)
{
	SDKHook(entity, SDKHook_StartTouch, OnTouch);
	SDKHook(entity, SDKHook_Touch, OnTouch);
	SDKHook(entity, SDKHook_EndTouch, OnTouch);
}

public Action OnTouch(int entity, int other)
{
	return IsMirror(other) ? Plugin_Handled : Plugin_Continue;
}

void ClearMirrors()
{
	for (int i = 1; i <= MaxClients; i++)
		if (IsMirror(i) && !IsClientInKickQueue(i)) KickClient(i, "Web player disconnected");
}

void ApplyMirrors(JSONArray players)
{
	bool seen[MAXPLAYERS + 1];
	for (int j; j < players.Length; j++)
	{
		JSONObject pose = view_as<JSONObject>(players.Get(j));
		char id[32], name[64];
		pose.GetString("steamid64", id, sizeof(id));
		int bot;
		for (int i = 1; i <= MaxClients; i++)
			if (IsMirror(i) && StrEqual(id, gC_Owner[i]) && !IsClientInKickQueue(i)) bot = i;
		if (!bot && GetClientCount(false) < MaxClients - 1)
		{
			char display[MAX_NAME_LENGTH];
			pose.GetString("name", name, sizeof(name));
			FormatEx(display, sizeof(display), "[Web] %s", name);
			bot = CreateFakeClient(display);
			if (bot)
			{
				strcopy(gC_Owner[bot], sizeof(gC_Owner[]), id);
				ChangeClientTeam(bot, CS_TEAM_CT);
			}
		}
		if (bot)
		{
			seen[bot] = true;
			if (!IsPlayerAlive(bot)) CS_RespawnPlayer(bot);
			SetEntityMoveType(bot, MOVETYPE_NONE);
			SetEntProp(bot, Prop_Send, "m_CollisionGroup", 2);
			JSONArray pos = view_as<JSONArray>(pose.Get("position"));
			JSONArray ang = view_as<JSONArray>(pose.Get("angles"));
			float origin[3], angles[3], zero[3];
			for (int i; i < 3; i++) origin[i] = pos.GetFloat(i);
			for (int i; i < 2; i++) angles[i] = ang.GetFloat(i);
			SetEntProp(bot, Prop_Send, "m_bDucked", pose.GetBool("crouched"));
			TeleportEntity(bot, origin, angles, zero);
			delete pos;
			delete ang;
		}
		delete pose;
	}
	for (int i = 1; i <= MaxClients; i++)
		if (!seen[i] && IsMirror(i) && !IsClientInKickQueue(i)) KickClient(i, "Web player left");
}
