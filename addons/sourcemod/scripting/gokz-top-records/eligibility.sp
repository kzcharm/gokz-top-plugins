// Availability belongs to the configured gokz.top environment, not GlobalAPI.
enum RecordFilterDecision
{
	RecordFilters_Unknown,
	RecordFilters_Supported,
	RecordFilters_Unsupported
};

static StringMap sFilterFlags, sFilterNext;
static bool sFilterBusy;

void Eligibility_Init()
{
	delete sFilterFlags;
	delete sFilterNext;
	sFilterFlags = new StringMap();
	sFilterNext = new StringMap();
	Queue_SQL("CREATE TABLE IF NOT EXISTS record_filters (environment TEXT NOT NULL,map TEXT NOT NULL,flags TEXT NOT NULL,PRIMARY KEY(environment,map))");
}

void Eligibility_Key(const char[] environment, const char[] map, char[] key, int capacity)
{
	Format(key, capacity, "%s|%s", environment, map);
}

// Six bits per course: VNL/SKZ/KZT NUB and PRO. NKZ uses KZT's bits.
int Eligibility_Mask(int mode, int teleports)
{
	if (mode == 3) mode = 2;
	if (mode < 0 || mode > 2) return 0;
	return (teleports > 0 ? 1 : 3) << (mode * 2);
}

bool Eligibility_Load(const char[] environment, const char[] map, int flags[256])
{
	char key[1024];
	Eligibility_Key(environment, map, key, sizeof(key));
	if (sFilterFlags.GetArray(key, flags, sizeof(flags))) return true;
	char escapedEnv[1024], escapedMap[1024], query[2304], encoded[513];
	gDB.Escape(environment, escapedEnv, sizeof(escapedEnv));
	gDB.Escape(map, escapedMap, sizeof(escapedMap));
	Format(query, sizeof(query), "SELECT flags FROM record_filters WHERE environment='%s' AND map='%s'", escapedEnv, escapedMap);
	DBResultSet row = SQL_Query(gDB, query);
	bool found = row != null && row.FetchRow();
	if (found) row.FetchString(0, encoded, sizeof(encoded));
	delete row;
	if (!found || strlen(encoded) != 512) return false;
	for (int stage = 0; stage < 256; stage++)
	{
		int high = Eligibility_Hex(encoded[stage * 2]), low = Eligibility_Hex(encoded[stage * 2 + 1]);
		if (high < 0 || low < 0 || high > 3) return false;
		flags[stage] = high * 16 + low;
	}
	sFilterFlags.SetArray(key, flags, sizeof(flags));
	return true;
}

int Eligibility_Hex(int value)
{
	if (value >= '0' && value <= '9') return value - '0';
	if (value >= 'a' && value <= 'f') return value - 'a' + 10;
	return -1;
}

void Eligibility_Store(const char[] environment, const char[] map, const int flags[256])
{
	char key[1024], encoded[513], digits[] = "0123456789abcdef";
	Eligibility_Key(environment, map, key, sizeof(key));
	sFilterFlags.SetArray(key, flags, sizeof(flags));
	sFilterNext.SetValue(key, GetTime() + 60);
	for (int stage = 0; stage < 256; stage++)
	{
		encoded[stage * 2] = digits[(flags[stage] >> 4) & 15];
		encoded[stage * 2 + 1] = digits[flags[stage] & 15];
	}
	encoded[512] = '\0';
	char escapedEnv[1024], escapedMap[1024], query[3072];
	gDB.Escape(environment, escapedEnv, sizeof(escapedEnv));
	gDB.Escape(map, escapedMap, sizeof(escapedMap));
	Format(query, sizeof(query), "INSERT OR REPLACE INTO record_filters(environment,map,flags) VALUES('%s','%s','%s')", escapedEnv, escapedMap, encoded);
	Queue_SQL(query);
}

RecordFilterDecision Eligibility_Check(const char[] environment, const char[] map, int stage, int mode, int teleports)
{
	if (stage < 0 || stage > 255 || mode < 0 || mode > 3 || teleports < 0) return RecordFilters_Unknown;
	int flags[256];
	bool known = Eligibility_Load(environment, map, flags);
	Eligibility_Ensure(environment, map);
	if (!known) return RecordFilters_Unknown;
	return flags[stage] & Eligibility_Mask(mode, teleports) ? RecordFilters_Supported : RecordFilters_Unsupported;
}

RecordFilterDecision Eligibility_Payload(const char[] environment, const char[] payload)
{
	JSON_Object body = json_decode(payload);
	if (body == null) return RecordFilters_Unknown;
	char map[PLATFORM_MAX_PATH], modeName[8];
	body.GetString("map_name", map, sizeof(map));
	body.GetString("mode", modeName, sizeof(modeName));
	int mode = -1;
	for (int index = 0; index < 4; index++) if (StrEqual(modeName, gModeNames[index])) mode = index;
	RecordFilterDecision result = RecordFilters_Unknown;
	if (map[0] && body.HasKey("stage") && body.HasKey("teleports"))
	{
		result = Eligibility_Check(environment, map, body.GetInt("stage"), mode, body.GetInt("teleports"));
	}
	body.Cleanup(); delete body;
	return result;
}

void Eligibility_PrefetchCurrent()
{
	char environment[512], key[256], map[PLATFORM_MAX_PATH];
	GOKZTop_GetHTTPConfig(environment, sizeof(environment), key, sizeof(key));
	GetCurrentMap(map, sizeof(map));
	Eligibility_Ensure(environment, map);
}

void Eligibility_Ensure(const char[] environment, const char[] map)
{
	char key[1024];
	Eligibility_Key(environment, map, key, sizeof(key));
	int next;
	if (sFilterBusy || (sFilterNext.GetValue(key, next) && next > GetTime())) return;
	sFilterNext.SetValue(key, GetTime() + 15);
	Eligibility_Request(environment, map, 0);
}

void Eligibility_Request(const char[] environment, const char[] map, int mapID)
{
	char path[1024], url[1600];
	if (mapID > 0) Format(path, sizeof(path), "/v0/record_filters?map_ids=%d&tickrates=128&limit=10000", mapID);
	else
	{
		char encoded[PLATFORM_MAX_PATH * 3];
		int written;
		for (int index = 0; map[index] && written + 3 < sizeof(encoded); index++)
		{
			int value = map[index] & 255;
			if ((value >= 'a' && value <= 'z') || (value >= 'A' && value <= 'Z') || (value >= '0' && value <= '9') || value == '_' || value == '-' || value == '.') encoded[written++] = value;
			else written += Format(encoded[written], sizeof(encoded) - written, "%%%02X", value);
		}
		encoded[written] = '\0';
		Format(path, sizeof(path), "/v0/maps/name/%s", encoded);
	}
	Format(url, sizeof(url), "%s%s", environment, path);
	Handle request = SteamWorks_CreateHTTPRequest(k_EHTTPMethodGET, url);
	if (request == null) return;
	DataPack context = new DataPack();
	context.WriteString(environment); context.WriteString(map); context.WriteCell(mapID);
	SteamWorks_SetHTTPRequestContextValue(request, context);
	SteamWorks_SetHTTPCallbacks(request, OnRecordFiltersComplete);
	SteamWorks_SetHTTPRequestAbsoluteTimeoutMS(request, 10000);
	sFilterBusy = true;
	if (!SteamWorks_SendHTTPRequest(request))
	{
		sFilterBusy = false;
		delete context; delete request;
	}
}

bool Eligibility_ParseFilters(const char[] response, int mapID, int flags[256])
{
	JSON_Object rows = json_decode(response);
	if (rows == null) return false;
	for (int stage = 0; stage < 256; stage++) flags[stage] = 0;
	int length = rows.IsArray ? rows.Length : -1;
	bool valid = length >= 0 && length < 10000;
	for (int index = 0; valid && index < length; index++)
	{
		JSON_Object row = rows.GetObjectIndexed(index);
		if (row == null || !row.HasKey("map_id") || !row.HasKey("stage") || !row.HasKey("mode_id") || !row.HasKey("tickrate") || !row.HasKey("has_teleports")) { valid = false; break; }
		int stage = row.GetInt("stage"), modeID = row.GetInt("mode_id");
		int mode = modeID == 202 ? 0 : (modeID == 201 ? 1 : (modeID == 200 ? 2 : -1));
		if (row.GetInt("map_id") != mapID || row.GetInt("tickrate") != 128 || stage < 0 || stage > 255 || mode < 0) continue;
		flags[stage] |= 1 << (mode * 2 + (row.GetBool("has_teleports") ? 0 : 1));
	}
	rows.Cleanup(); delete rows;
	return valid;
}

public void OnRecordFiltersComplete(Handle request, bool failure, bool successful, EHTTPStatusCode statusCode, DataPack context)
{
	context.Reset();
	char environment[512], map[PLATFORM_MAX_PATH];
	context.ReadString(environment, sizeof(environment)); context.ReadString(map, sizeof(map));
	int mapID = context.ReadCell();
	delete context;
	sFilterBusy = false;
	int flags[256];
	if (!failure && successful && statusCode == k_EHTTPStatusCode404NotFound && mapID == 0) Eligibility_Store(environment, map, flags);
	else if (!failure && successful && statusCode == k_EHTTPStatusCode200OK)
	{
		int length;
		if (SteamWorks_GetHTTPResponseBodySize(request, length) && length > 0 && length < 1048576)
		{
			char[] response = new char[length + 1];
			if (HTTP_ReadBody(request, response, length + 1))
			{
				if (mapID > 0)
				{
					if (Eligibility_ParseFilters(response, mapID, flags)) Eligibility_Store(environment, map, flags);
				}
				else
				{
					JSON_Object body = json_decode(response);
					if (body != null)
					{
						char returned[PLATFORM_MAX_PATH]; body.GetString("name", returned, sizeof(returned));
						if (StrEqual(returned, map) && body.HasKey("validated") && body.GetInt("id") > 0)
						{
							if (body.GetBool("validated")) Eligibility_Request(environment, map, body.GetInt("id"));
							else Eligibility_Store(environment, map, flags);
						}
						body.Cleanup(); delete body;
					}
				}
			}
		}
	}
	delete request;
}

bool Eligibility_IsFilterRejection(const char[] response)
{
	JSON_Object body = json_decode(response);
	if (body == null) return false;
	JSON_Object detail = body.GetObject("detail");
	JSON_Object checks = detail != null ? detail.GetObject("checks") : null;
	bool unsupported = checks != null && checks.HasKey("filter") && !checks.GetBool("filter");
	body.Cleanup(); delete body;
	return unsupported;
}

void Eligibility_RejectQueued(const char[] id)
{
	char query[256];
	Format(query, sizeof(query), "SELECT environment,payload FROM jobs WHERE id='%s' AND canonical=''", id);
	DBResultSet row = SQL_Query(gDB, query);
	if (row == null || !row.FetchRow()) { delete row; return; }
	char environment[512], payload[4096];
	row.FetchString(0, environment, sizeof(environment)); row.FetchString(1, payload, sizeof(payload));
	delete row;
	JSON_Object body = json_decode(payload);
	if (body != null)
	{
		char map[PLATFORM_MAX_PATH], modeName[8], key[1024];
		body.GetString("map_name", map, sizeof(map)); body.GetString("mode", modeName, sizeof(modeName));
		int mode = -1, stage = body.GetInt("stage"), flags[256];
		for (int index = 0; index < 4; index++) if (StrEqual(modeName, gModeNames[index])) mode = index;
		if (stage >= 0 && stage < 256 && mode >= 0 && Eligibility_Load(environment, map, flags))
		{
			flags[stage] &= ~Eligibility_Mask(mode, body.GetInt("teleports"));
			Eligibility_Store(environment, map, flags);
		}
		Eligibility_Key(environment, map, key, sizeof(key));
		sFilterNext.SetValue(key, 0);
		body.Cleanup(); delete body;
	}
	Eligibility_Discard(id);
}

void Eligibility_Discard(const char[] id)
{
	if (!IsRecordUUID(id)) return;
	char query[256];
	Format(query, sizeof(query), "DELETE FROM jobs WHERE id='%s' AND canonical=''", id);
	if (!Queue_SQL(query) || SQL_GetAffectedRows(gDB) == 0) return;
	// Only remove our own derived spool filenames, never upstream replay files.
	char path[PLATFORM_MAX_PATH];
	Format(path, sizeof(path), "%s/%s.replay", gSpool, id);
	if (FileExists(path)) DeleteFile(path);
	Format(path, sizeof(path), "%s/%s.part", gSpool, id);
	if (FileExists(path)) DeleteFile(path);
	Format(gLastStatus, sizeof(gLastStatus), "Skipped unsupported map/mode record %s", id);
	LogMessage("event=skip_unsupported record=%s", id);
}

void Eligibility_PruneQueue(const char[] environment, const char[] server, const char[] legacy)
{
	static char cursor[37], previousEnv[512], previousServer[37], previousLegacy[37];
	if (!StrEqual(previousEnv, environment) || !StrEqual(previousServer, server) || !StrEqual(previousLegacy, legacy)) cursor[0] = '\0';
	strcopy(previousEnv, sizeof(previousEnv), environment); strcopy(previousServer, sizeof(previousServer), server); strcopy(previousLegacy, sizeof(previousLegacy), legacy);
	char escaped[1024], query[2048];
	gDB.Escape(environment, escaped, sizeof(escaped));
	Format(query, sizeof(query), "SELECT id,payload FROM jobs WHERE environment='%s' AND server IN ('%s','%s') AND canonical='' AND state IN ('record','filters','auth','rejected') AND id>'%s' ORDER BY id LIMIT 32", escaped, server, legacy, cursor);
	DBResultSet rows = SQL_Query(gDB, query);
	bool found;
	while (rows != null && rows.FetchRow())
	{
		char id[37], payload[4096]; rows.FetchString(0, id, sizeof(id)); rows.FetchString(1, payload, sizeof(payload));
		strcopy(cursor, sizeof(cursor), id); found = true;
		if (Eligibility_Payload(environment, payload) == RecordFilters_Unsupported) Eligibility_Discard(id);
	}
	delete rows;
	if (!found) cursor[0] = '\0';
}
