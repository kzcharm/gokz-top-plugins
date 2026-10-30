void SpoolReplay(const char[] id, const char[] source)
{
	char existing[PLATFORM_MAX_PATH];
	Format(existing, sizeof(existing), "%s/%s.replay", gSpool, id);
	// Recover a copy committed before a crash interrupted the SQLite update.
	if (FileExists(existing)) { RegisterSpoolReplay(id, existing); return; }
	if (!FileExists(source)) return;
	float used = 0.0;
	DirectoryListing directory = OpenDirectory(gSpool);
	char name[PLATFORM_MAX_PATH], path[PLATFORM_MAX_PATH];
	FileType type;
	while (directory != null && directory.GetNext(name, sizeof(name), type))
	{
		if (type != FileType_File) continue;
		Format(path, sizeof(path), "%s/%s", gSpool, name);
		used += float(FileSize(path));
	}
	delete directory;
	Format(path, sizeof(path), "%s/%s.replay", gSpool, id);
	if (used + float(FileSize(source)) > gCV_Spool.FloatValue * 1073741824.0)
	{
		LogError("Replay spool full for record %s; record submission continues", id);
		return;
	}
	char partial[PLATFORM_MAX_PATH];
	Format(partial, sizeof(partial), "%s.part", path);
	File input = OpenFile(source, "rb"), output = OpenFile(partial, "wb");
	if (input == null || output == null) { delete input; delete output; return; }
	int buffer[4096], count;
	bool success = true;
	while ((count = input.Read(buffer, sizeof(buffer), 1)) > 0)
	{
		if (!output.Write(buffer, count, 1)) { success = false; break; }
	}
	delete input; delete output;
	if (!success || !RenameFile(path, partial)) { DeleteFile(partial); return; }
	RegisterSpoolReplay(id, path);
}

void RegisterSpoolReplay(const char[] id, const char[] path)
{
	char escaped[1024], query[2048];
	gDB.Escape(path, escaped, sizeof(escaped));
	Format(query, sizeof(query), "UPDATE jobs SET replay='%s' WHERE id='%s'", escaped, id);
	Queue_SQL(query);
}

public Action GOKZ_RP_OnReplaySaved(int client, int replayType, const char[] map, int course, int timeType, float time, const char[] filePath, bool tempReplay)
{
	if (replayType != ReplayType_Run) return Plugin_Continue;
	// Read the immutable file header: the player may already have started another
	// run or disconnected by the time the replay writer finishes its breather.
	File file = OpenFile(filePath, "rb");
	if (file == null) return Plugin_Continue;
	int value, account, mode;
	file.Seek(6, SEEK_SET);
	file.ReadInt8(value); file.Seek(value, SEEK_CUR); // GOKZ version
	file.ReadInt8(value); file.Seek(value + 12, SEEK_CUR); // map + BSP/IP/timestamp
	file.ReadInt8(value); file.Seek(value, SEEK_CUR); // player alias
	bool valid = file.ReadInt32(account) && file.ReadInt8(mode);
	delete file;
	if (!valid || mode < 0 || mode > 3 || account <= 0) return Plugin_Continue;
	char steam[32];
	Format(steam, sizeof(steam), "STEAM_1:%d:%d", account & 1, account / 2);
	DBResultSet rows = SQL_Query(gDB, "SELECT id,payload,steam2 FROM jobs WHERE replay='' AND relay=0 AND state NOT IN ('done','rejected') ORDER BY id");
	if (rows == null) return Plugin_Continue;
	int matches;
	char match[37];
	while (rows.FetchRow())
	{
		char id[37], payload[4096], auth[32], runMap[PLATFORM_MAX_PATH], runMode[16], runTime[32];
		rows.FetchString(0, id, sizeof(id)); rows.FetchString(1, payload, sizeof(payload)); rows.FetchString(2, auth, sizeof(auth));
		if (!StrEqual(auth[8], steam[8])) continue;
		JSON_Object body = json_decode(payload);
		if (body == null) continue;
		body.GetString("map_name", runMap, sizeof(runMap)); body.GetString("mode", runMode, sizeof(runMode)); body.GetString("time", runTime, sizeof(runTime));
		if (StrEqual(runMap, map) && StrEqual(runMode, gModeNames[mode]) && body.GetInt("stage") == course && FloatAbs(StringToFloat(runTime) - time) < 0.0005)
		{
			matches++; strcopy(match, sizeof(match), id);
		}
		body.Cleanup(); delete body;
	}
	delete rows;
	if (matches == 1) SpoolReplay(match, filePath);
	else if (matches > 1) LogError("Replay matches multiple captured finishes; preserved metadata requires operator review");
	return Plugin_Continue;
}

void DiscoverReplays()
{
	static char cursor[37];
	char query[512];
	Format(query, sizeof(query), "SELECT id,payload FROM jobs WHERE replay='' AND state NOT IN ('done','rejected') AND id>'%s' ORDER BY id LIMIT 100", cursor);
	DBResultSet rows = SQL_Query(gDB, query);
	if (rows == null) return;
	bool found;
	while (rows.FetchRow())
	{
		char id[37], payload[4096], map[PLATFORM_MAX_PATH], path[PLATFORM_MAX_PATH];
		rows.FetchString(0, id, sizeof(id)); rows.FetchString(1, payload, sizeof(payload));
		strcopy(cursor, sizeof(cursor), id);
		found = true;
		JSON_Object body = json_decode(payload);
		if (body == null) continue;
		body.GetString("map_name", map, sizeof(map));
		body.Cleanup(); delete body;
		BuildPath(Path_SM, path, sizeof(path), "data/gokz-replays/_runs/%s/%s.replay", map, id);
		SpoolReplay(id, path);
	}
	delete rows;
	if (!found) cursor[0] = '\0';
}
