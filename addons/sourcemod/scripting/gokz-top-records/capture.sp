// GlobalAPI's JSON encoder uses FloatToString (six decimals). Its records API
// truncates that serialized value to milliseconds. Formatting the float directly
// with %.3f can cross a millisecond boundary before it reaches the API.
void Capture_FormatGlobalTime(float time, char[] output, int capacity)
{
	GOKZTop_FormatRecordTime(time, output, capacity);
}

public void GOKZ_OnTimerStart_Post(int client, int course)
{
	if (!IsClientInGame(client) || IsFakeClient(client)) return;
	Relay_ResetClient(client);
	int mode = GOKZ_GetCoreOption(client, Option_Mode);
	gRun[client] = mode >= 0 && mode <= 3 && GOKZ_GetCoreOption(client, Option_Style) == 0;
	if (!gRun[client]) return;
	// A client actually running mode 3 proves NKZ support; never query index 3 on stock GOKZ.
	gMode[client] = mode;
	gVersion[client] = GOKZ_GetModeVersion(mode);
	gValid[client] = gFreshMap && ServerSettingsValid() && ClientSettingsValid(client);
	char key[256];
	GOKZTop_GetHTTPConfig(gEnvironment[client], sizeof(gEnvironment[]), key, sizeof(key));
	GOKZTop_GetServerSteamID(gServer[client], sizeof(gServer[]));
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
	GetClientAuthId(client, AuthId_SteamID64, steam, sizeof(steam));
	if (!GOKZTop_GetServerSteamID(server, sizeof(server))) return null;
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

public void GOKZ_OnTimerEnd_Post(int client, int course, float time, int teleportsUsed)
{
	if (!gRun[client] || Relay_CoreInvalidityExpected(client)) return;
	JSON_Object body = Capture_Check(client, course);
	if (body == null) return;
	char timestamp[40], timeString[32], payload[4096], steam2[32];
	GetClientAuthId(client, AuthId_Steam2, steam2, sizeof(steam2));
	FormatTime(timestamp, sizeof(timestamp), "%Y-%m-%dT%H:%M:%S%z", GetTime());
	Capture_FormatGlobalTime(time, timeString, sizeof(timeString));
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
