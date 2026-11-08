#include <sourcemod>
#include <sdktools>
#include <sdkhooks>
#include <cstrike>
#include <ripext>
#include <basecomm>
#include <gokz/core>

#pragma newdecls required
#pragma semicolon 1

public Plugin myinfo =
{
	name = "Web GOKZ staging bridge",
	author = "GOKZ.TOP",
	description = "Mirror browser players and share public chat with Web GOKZ Room 1",
	version = "0.2.0"
};

char gC_Key[128], gC_Map[PLATFORM_MAX_PATH], gC_Generation[40];
int gI_Epoch, gI_Cursor = -1;
int gI_LastStatus;
char gC_LastError[256];
bool gB_InFlight;
float gF_NextPoll;
JSONArray gH_Chat;
JSONArray gH_Notices;
JSONArray gH_Samples;
bool gB_Active;
int gI_Captured, gI_WebSamples, gI_Moved;
float gF_WebClock, gF_Started;

#include "gokz-top-web-bridge/bots.sp"

public void OnPluginStart()
{
	char path[PLATFORM_MAX_PATH];
	BuildPath(Path_SM, path, sizeof(path), "configs/web-gokz-staging.key");
	File key = OpenFile(path, "r");
	if (key == null || !key.ReadLine(gC_Key, sizeof(gC_Key)) || TrimString(gC_Key) < 32)
	{
		SetFailState("Set the staging bridge key in configs/web-gokz-staging.key");
	}
	delete key;
	gH_Chat = new JSONArray();
	gH_Notices = new JSONArray();
	gH_Samples = new JSONArray();
	gF_Started = GetEngineTime();
	CreateTimer(0.1, Poll, _, TIMER_REPEAT);
	RegServerCmd("sm_webbridge_status", Status);
	AddCommandListener(OnServerSay, "say");
}

public Action Status(int args)
{
	PrintToServer("[Web GOKZ] map=%s generation=%s cursor=%d http=%d error=%s", gC_Map, gC_Generation, gI_Cursor, gI_LastStatus, gC_LastError);
	PrintToServer("[Web GOKZ] uptime=%.2f tickrate=%d native_samples=%d web_samples=%d bot_moving_ticks=%d", GetEngineTime() - gF_Started, RoundToNearest(1.0 / GetTickInterval()), gI_Captured, gI_WebSamples, gI_Moved);
	for (int i = 1; i <= MaxClients; i++)
	{
		if (!IsMirror(i)) continue;
		float origin[3];
		GetClientAbsOrigin(i, origin);
		PrintToServer("[Web GOKZ] bot=%N origin=%.1f %.1f %.1f", i, origin[0], origin[1], origin[2]);
	}
	return Plugin_Handled;
}

public void OnMapStart()
{
	GetCurrentMap(gC_Map, sizeof(gC_Map));
	gI_Epoch++;
	gI_Cursor = -1;
	gC_Generation[0] = 0;
	gB_InFlight = false;
	gF_NextPoll = 0.0;
	gH_Chat.Clear();
	gH_Notices.Clear();
	gH_Samples.Clear();
	gB_Active = false;
	gF_WebClock = 0.0;
	int entity = -1;
	while ((entity = FindEntityByClassname(entity, "trigger_*")) != -1) HookTrigger(entity);
}

public void OnPluginEnd()
{
	ClearMirrors();
}

public Action OnServerSay(int client, const char[] command, int argc)
{
	if (client != 0 || argc < 1 || !gC_Generation[0] || gH_Notices.Length >= 32) return Plugin_Continue;
	char text[256], notice[288];
	GetCmdArgString(text, sizeof(text));
	StripQuotes(text);
	FormatEx(notice, sizeof(notice), "[CS:GO] Server: %s", text);
	gH_Notices.PushString(notice);
	return Plugin_Continue;
}

public void GOKZ_OnTimerEnd_Post(int client, int course, float runTime, int teleportsUsed)
{
	if (!gC_Generation[0] || IsFakeClient(client) || gH_Notices.Length >= 32) return;
	char notice[256];
	FormatEx(notice, sizeof(notice), "[CS:GO] %N finished %s (course %d) in %.3fs with %d TP.", client, gC_Map, course, runTime, teleportsUsed);
	gH_Notices.PushString(notice);
}

public Action GOKZ_CH_OnMessage(int client, const char[] command, const char[] text)
{
	if (!StrEqual(command, "say") || IsFakeClient(client) || BaseComm_IsClientGagged(client)
		|| gC_Generation[0] == 0 || gH_Chat.Length >= 32) return Plugin_Continue;
	char message[256], id[32], name[MAX_NAME_LENGTH];
	strcopy(message, sizeof(message), text);
	TrimString(message);
	if (!message[0] || message[0] == '!' || message[0] == '/' || message[0] == '@'
		|| IsChatTrigger() || !GetClientAuthId(client, AuthId_SteamID64, id, sizeof(id))) return Plugin_Continue;
	GetClientName(client, name, sizeof(name));
	JSONObject line = new JSONObject();
	line.SetString("steamid64", id);
	line.SetString("name", name);
	line.SetString("text", message);
	gH_Chat.Push(line);
	delete line;
	return Plugin_Continue;
}

void SetVector(JSONObject obj, const char[] field, const float values[3], int count)
{
	JSONArray array = new JSONArray();
	for (int i; i < count; i++) array.PushFloat(values[i]);
	obj.Set(field, array);
	delete array;
}

JSONArray CapturePlayers()
{
	JSONArray players = new JSONArray();
	for (int i = 1; i <= MaxClients; i++)
	{
		char id[32], name[MAX_NAME_LENGTH];
		if (!IsClientInGame(i) || IsFakeClient(i) || !IsPlayerAlive(i)
			|| !GetClientAuthId(i, AuthId_SteamID64, id, sizeof(id))) continue;
		GetClientName(i, name, sizeof(name));
		JSONObject player = new JSONObject();
		player.SetString("steamid64", id);
		player.SetString("name", name);
		int mode = GOKZ_GetCoreOption(i, Option_Mode);
		player.SetString("mode", (mode >= 0 && mode < MODE_COUNT) ? gC_ModeNamesShort[mode] : "VNL");
		float vec[3];
		GetClientAbsOrigin(i, vec);
		SetVector(player, "position", vec, 3);
		GetClientEyeAngles(i, vec);
		SetVector(player, "angles", vec, 2);
		player.SetBool("crouched", (GetEntityFlags(i) & FL_DUCKING) != 0);
		players.Push(player);
		delete player;
	}
	return players;
}

public void OnGameFrame()
{
	if (!gB_Active) return;
	float now = GetEngineTime();
	PlayMirrors(now - gF_WebClock - 0.20);
	JSONArray players = CapturePlayers();
	if (players.Length || gH_Samples.Length)
	{
		JSONObject sample = new JSONObject();
		sample.SetInt("tick", GetGameTickCount());
		sample.Set("players", players);
		if (gH_Samples.Length >= 64) gH_Samples.Remove(0);
		gH_Samples.Push(sample);
		delete sample;
		gI_Captured++;
	}
	delete players;
}

public Action Poll(Handle timer)
{
	if (gB_InFlight || GetEngineTime() < gF_NextPoll) return Plugin_Continue;
	JSONObject body = new JSONObject();
	JSONArray players = CapturePlayers();
	body.SetInt("tickrate", RoundToNearest(1.0 / GetTickInterval()));
	body.Set("samples", gH_Samples);
	body.SetString("map_name", gC_Map);
	body.SetString("generation", gC_Generation);
	body.SetInt("cursor", gI_Cursor);
	body.Set("players", players);
	body.Set("chat", gH_Chat);
	body.Set("notices", gH_Notices);
	delete players;
	HTTPRequest req = new HTTPRequest("https://staging-api.gokz.top/v1/web-gokz/native/exchange");
	req.SetHeader("X-Bridge-Key", "%s", gC_Key);
	req.MaxRedirects = 0;
	req.Timeout = 3;
	gB_InFlight = true;
	req.Post(body, OnFrame, gI_Epoch);
	delete body;
	gH_Chat.Clear();
	gH_Notices.Clear();
	gH_Samples.Clear();
	return Plugin_Continue;
}

public void OnFrame(HTTPResponse response, int epoch, const char[] error)
{
	if (epoch != gI_Epoch) return;
	gB_InFlight = false;
	gI_LastStatus = view_as<int>(response.Status);
	strcopy(gC_LastError, sizeof(gC_LastError), error);
	if (response.Status != HTTPStatus_OK)
	{
		if (gC_Generation[0]) LogError("Lost staging bridge (HTTP %d)", response.Status);
		ClearMirrors();
		gB_Active = false;
		gH_Samples.Clear();
		gC_Generation[0] = 0;
		gI_Cursor = -1;
		gF_NextPoll = GetEngineTime() + 2.0;
		return;
	}
	JSONObject frame = view_as<JSONObject>(response.Data);
	char generation[sizeof(gC_Generation)];
	frame.GetString("generation", generation, sizeof(generation));
	if (!StrEqual(generation, gC_Generation))
	{
		for (int i = 1; i <= MaxClients; i++) gI_Count[i] = 0;
		gB_Active = false;
	}
	float offset = GetEngineTime() - float(frame.GetInt("clock_ms")) / 1000.0;
	if (!gB_Active || FloatAbs(offset - gF_WebClock) > 0.10)
		gF_WebClock = offset;
	gB_Active = frame.GetBool("active");
	strcopy(gC_Generation, sizeof(gC_Generation), generation);
	gI_Cursor = frame.GetInt("cursor");
	if (!frame.GetBool("active")) gF_NextPoll = GetEngineTime() + 0.8;
	JSONArray players = view_as<JSONArray>(frame.Get("players"));
	ApplyMirrors(players);
	delete players;
	JSONArray chat = view_as<JSONArray>(frame.Get("chat"));
	for (int i; i < chat.Length; i++)
	{
		char line[512];
		chat.GetString(i, line, sizeof(line));
		PrintToChatAll("%s", line);
	}
	delete chat;
}
