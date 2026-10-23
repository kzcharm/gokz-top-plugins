public void GOKZ_OnTimerStart_Post(int client, int course)
{
	if (!IsClientInGame(client) || IsFakeClient(client)) return;
	int mode = GOKZ_GetCoreOption(client, Option_Mode);
	gRun[client] = mode >= 0 && mode <= 3 && GOKZ_GetCoreOption(client, Option_Style) == 0;
	if (!gRun[client]) return;
	// A client actually running mode 3 proves NKZ support; never query index 3 on stock GOKZ.
	gMode[client] = mode;
	gVersion[client] = GOKZ_GetModeVersion(mode);
	gValid[client] = gFreshMap && ServerSettingsValid() && ClientSettingsValid(client);
	char key[256];
	GOKZTop_GetHTTPConfig(gEnvironment[client], sizeof(gEnvironment[]), key, sizeof(key));
	gCV_Server.GetString(gServer[client], sizeof(gServer[]));
	UUID_GenerateV7(gGUID[client], sizeof(gGUID[]));
	if (GetFeatureStatus(FeatureType_Native, "GOKZ_DB_GetRunGUID") == FeatureStatus_Available)
	{
		char guid[37];
		if (GOKZ_DB_GetRunGUID(client, guid) == 36 && IsRecordUUID(guid) && guid[14] == '7') strcopy(gGUID[client], sizeof(gGUID[]), guid);
	}
}

JSON_Object Capture_Check(int client, int course)
{
	char map[PLATFORM_MAX_PATH], bsp[PLATFORM_MAX_PATH], steam[32], server[37];
	GetCurrentMap(map, sizeof(map));
	Format(bsp, sizeof(bsp), "maps/%s.bsp", map);
	if (!Capture_GetSteamID64(client, steam, sizeof(steam))) return null;
	gCV_Server.GetString(server, sizeof(server));
	int mode = GOKZ_GetCoreOption(client, Option_Mode);
	if (mode < 0 || mode > 3) return null;
	JSON_Object body = new JSON_Object();
	body.SetString("server_id", gRun[client] ? gServer[client] : server);
	body.SetString("map_name", map);
	body.SetInt("bsp_size", FileSize(bsp, true));
	body.SetInt("stage", course);
	body.SetString("mode", gModeNames[mode]);
	body.SetInt("mode_version", GOKZ_GetModeVersion(mode));
	body.SetString("steamid64", steam);
	body.SetInt("style", GOKZ_GetCoreOption(client, Option_Style));
	body.SetInt("tickrate", RoundToNearest(1.0 / GetTickInterval()));
	JSON_Object integrity = new JSON_Object();
	integrity.SetBool("fresh_map", gFreshMap);
	integrity.SetBool("server_settings", ServerSettingsValid());
	integrity.SetBool("client_settings", ClientSettingsValid(client));
	integrity.SetBool("required_plugins", LibraryExists("gokz-anticheat") && LibraryExists("movementapi"));
	integrity.SetBool("timer_valid", !gRun[client] || gValid[client]);
	integrity.SetBool("mode_stable", !gRun[client] || (gMode[client] == mode && gVersion[client] == GOKZ_GetModeVersion(mode)));
	integrity.SetBool("anticheat_clear", !gRun[client] || gValid[client]);
	body.SetObject("integrity", integrity);
	return body;
}

// Older Source 1 builds can expose Steam2 while the SteamID64 native fails.
// Add the authenticated account ID as decimal digits to avoid 32-bit overflow.
bool Capture_GetSteamID64(int client, char[] steam, int capacity)
{
	if (GetClientAuthId(client, AuthId_SteamID64, steam, capacity) && strlen(steam) == 17)
	{
		bool numeric = true;
		for (int i = 0; i < 17; i++) if (steam[i] < '0' || steam[i] > '9') numeric = false;
		if (numeric) return true;
	}
	char steam2[32];
	if (!GetClientAuthId(client, AuthId_Steam2, steam2, sizeof(steam2)))
	{
		steam[0] = '\0';
		return false;
	}
	return Capture_Steam2ToSteam64(steam2, steam, capacity);
}

bool Capture_Steam2ToSteam64(const char[] steam2, char[] steam, int capacity)
{
	char parts[3][24];
	steam[0] = '\0';
	int separators;
	for (int i = 0; steam2[i]; i++) if (steam2[i] == ':') separators++;
	if (separators != 2) return false;
	if (capacity < 18 || ExplodeString(steam2, ":", parts, sizeof(parts), sizeof(parts[])) != 3
		|| (!StrEqual(parts[0], "STEAM_0") && !StrEqual(parts[0], "STEAM_1"))
		|| (!StrEqual(parts[1], "0") && !StrEqual(parts[1], "1"))
		|| strlen(parts[2]) == 0 || strlen(parts[2]) > 10) return false;
	for (int i = 0; parts[2][i]; i++) if (parts[2][i] < '0' || parts[2][i] > '9') return false;
	if (strlen(parts[2]) == 10 && strcmp(parts[2], "2147483647") > 0) return false;
	strcopy(steam, capacity, "76561197960265728");
	int carry = StringToInt(parts[1]);
	int accountDigit = strlen(parts[2]) - 1;
	for (int i = 16; i >= 0; i--)
	{
		int sum = steam[i] - '0' + carry;
		if (accountDigit >= 0) sum += 2 * (parts[2][accountDigit--] - '0');
		steam[i] = '0' + sum % 10;
		carry = sum / 10;
	}
	return carry == 0;
}

public void GOKZ_OnTimerEnd_Post(int client, int course, float time, int teleportsUsed)
{
	if (!gRun[client]) return;
	JSON_Object body = Capture_Check(client, course);
	if (body == null) return;
	char timestamp[40], timeString[32], payload[4096], steam2[32];
	GetClientAuthId(client, AuthId_Steam2, steam2, sizeof(steam2));
	FormatTime(timestamp, sizeof(timestamp), "%Y-%m-%dT%H:%M:%S%z", GetTime());
	int timeMS = RoundToNearest(time * 1000.0);
	Format(timeString, sizeof(timeString), "%d.%03d", timeMS / 1000, timeMS % 1000);
	body.SetString("time", timeString);
	body.SetString("finished_at", timestamp);
	body.SetInt("teleports", teleportsUsed);
	body.SetString("record_uuid", gGUID[client]);
	json_encode(body, payload, sizeof(payload));
	body.Cleanup();
	delete body;
	if (!Queue_Insert(gGUID[client], gEnvironment[client], gServer[client], payload, steam2))
	{
		LogError("CRITICAL: cannot persist completed run %s payload=%s", gGUID[client], payload);
	}
	gRun[client] = false;
}
