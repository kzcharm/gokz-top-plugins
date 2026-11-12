char gC_Owner[MAXPLAYERS + 1][32];
#include "identity.sp"
#define TRAIL_SIZE 96
enum struct BotPose
{
	float at;
	float origin[3];
	float angles[3];
	bool crouched;
}
BotPose gS_Trail[MAXPLAYERS + 1][TRAIL_SIZE];
int gI_Head[MAXPLAYERS + 1], gI_Count[MAXPLAYERS + 1];

bool IsMirror(int client)
{
	return client > 0 && client <= MaxClients && gC_Owner[client][0] && IsClientInGame(client) && IsFakeClient(client);
}

public void OnClientDisconnect(int client)
{
	gC_Owner[client][0] = 0;
	gI_Count[client] = 0;
	ResetMirrorIdentity(client);
	RequestFrame(RefreshMirrorIdentities);
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

void AppendPose(int bot, const BotPose point)
{
	int head = gI_Head[bot], count = gI_Count[bot];
	if (count && point.at <= gS_Trail[bot][(head + count - 1) % TRAIL_SIZE].at) return;
	gS_Trail[bot][(head + count) % TRAIL_SIZE] = point;
	if (count == TRAIL_SIZE) gI_Head[bot] = (head + 1) % TRAIL_SIZE;
	else gI_Count[bot]++;
}

void PlayMirrors(float at)
{
	for (int bot = 1; bot <= MaxClients; bot++)
	{
		if (!gI_Count[bot] || !IsMirror(bot) || !IsPlayerAlive(bot)) continue;
		int head = gI_Head[bot], next = (head + 1) % TRAIL_SIZE;
		while (gI_Count[bot] > 1 && gS_Trail[bot][next].at <= at)
		{
			gI_Count[bot]--;
			gI_Head[bot] = head = next;
			next = (head + 1) % TRAIL_SIZE;
		}
		BotPose pose;
		pose = gS_Trail[bot][head];
		if (gI_Count[bot] > 1 && at > pose.at &&
			GetVectorDistance(pose.origin, gS_Trail[bot][next].origin) < 96.0 &&
			gS_Trail[bot][next].at - pose.at < 0.15)
		{
			float t = (at - pose.at) / (gS_Trail[bot][next].at - pose.at);
			for (int axis; axis < 3; axis++)
			{
				pose.origin[axis] += t * (gS_Trail[bot][next].origin[axis] - pose.origin[axis]);
				float delta = gS_Trail[bot][next].angles[axis] - pose.angles[axis];
				pose.angles[axis] += t * (delta - 360.0 * RoundToNearest(delta / 360.0));
			}
		}
		float origin[3], zero[3];
		GetClientAbsOrigin(bot, origin);
		if (GetVectorDistance(origin, pose.origin, true) > 0.0001) gI_Moved++;
		SetEntProp(bot, Prop_Send, "m_bDucked", pose.crouched);
		TeleportEntity(bot, pose.origin, pose.angles, zero);
	}
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
			}
		}
		if (bot)
		{
			seen[bot] = true;
			UpdateMirrorIdentity(bot);
			int team = pose.HasKey("spectating") && pose.GetBool("spectating") ? CS_TEAM_SPECTATOR : CS_TEAM_CT;
			if (GetClientTeam(bot) != team)
			{
				gI_Count[bot] = 0;
				ChangeClientTeam(bot, team);
			}
			if (team == CS_TEAM_SPECTATOR)
			{
				gI_Count[bot] = 0;
				delete pose;
				continue;
			}
			if (!IsPlayerAlive(bot)) CS_RespawnPlayer(bot);
			SetEntityMoveType(bot, MOVETYPE_NONE);
			SetEntProp(bot, Prop_Send, "m_CollisionGroup", 2);
			JSONArray trail = view_as<JSONArray>(pose.Get("trail"));
			BotPose point;
			for (int n; n < trail.Length; n++)
			{
				JSONArray row = view_as<JSONArray>(trail.Get(n));
				point.at = float(row.GetInt(0)) / 1000.0;
				for (int i; i < 3; i++) point.origin[i] = row.GetFloat(1 + i);
				for (int i; i < 2; i++) point.angles[i] = row.GetFloat(4 + i);
				point.crouched = row.GetBool(6);
				AppendPose(bot, point);
				gI_WebSamples++;
				delete row;
			}
			delete trail;
		}
		delete pose;
	}
	for (int i = 1; i <= MaxClients; i++)
		if (!seen[i] && IsMirror(i) && !IsClientInKickQueue(i)) KickClient(i, "Web player left");
}
