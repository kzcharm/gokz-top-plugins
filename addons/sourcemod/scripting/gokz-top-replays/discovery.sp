bool IsReplayLink(const char[] path)
{
	// Fail closed for links, missing paths, and unsupported file types.
	int type = GOKZTop_ReplayPathType(path);
	return type != 1 && type != 2;
}

bool SafeReplaySource(const char[] source)
{
	char root[PLATFORM_MAX_PATH];
	BuildPath(Path_SM, root, sizeof(root), "%s", RP_DIRECTORY_JUMPS);
	int length = strlen(root);
	if (StrContains(source, root) != 0 || source[length] != '/' || IsReplayLink(root)) return false;
	if (StrContains(source, "/../") != -1 || StrContains(source, "/./") != -1) return false;
	char parent[PLATFORM_MAX_PATH]; strcopy(parent, sizeof(parent), source);
	for (int i = length + 1; parent[i]; i++)
	{
		if (parent[i] != '/') continue;
		parent[i] = '\0';
		bool safe = GOKZTop_ReplayPathType(parent) == 1;
		parent[i] = '/';
		if (!safe) return false;
	}
	return GOKZTop_ReplayPathType(source) == 2;
}

void ScanTick()
{
	float start = GetEngineTime();
	ScanSlice();
	float duration = GetEngineTime() - start;
	if (duration > gMaxScanSeconds) gMaxScanSeconds = duration;
}

void ScanSlice()
{
	if (gListing == null && gDirectories.Length == 0)
	{
		if (GetTime() < gNextScan) return;
		char root[PLATFORM_MAX_PATH];
		BuildPath(Path_SM, root, sizeof(root), "%s", RP_DIRECTORY_JUMPS);
		if (IsReplayLink(root)) { gNextScan = GetTime() + 60; return; }
		gDirectories.PushString(root);
		gPassStart = GetTime();
	}
	float start = GetEngineTime();
	for (int entries = 0; entries < 128 && GetEngineTime() - start < 0.002; entries++)
	{
		if (gListing == null)
		{
			if (gDirectories.Length == 0)
			{
				char query[256];
				Format(query, sizeof(query), "INSERT OR REPLACE INTO settings VALUES('completed_scan',%d)", gPassStart);
				QueueSQL(query);
				gNextScan = GetTime() + 60;
				return;
			}
			int last = gDirectories.Length - 1;
			gDirectories.GetString(last, gDirectory, sizeof(gDirectory));
			gDirectories.Erase(last);
			gListing = OpenDirectory(gDirectory);
			if (gListing == null) continue;
		}
		char name[PLATFORM_MAX_PATH], path[PLATFORM_MAX_PATH];
		FileType type;
		if (!gListing.GetNext(name, sizeof(name), type)) { delete gListing; continue; }
		if (StrEqual(name, ".") || StrEqual(name, "..")) continue;
		if (Format(path, sizeof(path), "%s/%s", gDirectory, name) >= sizeof(path) - 1) continue;
		// DirectoryListing follows links on Linux; explicitly reject them first.
		if (IsReplayLink(path)) continue;
		if (type == FileType_Directory) gDirectories.PushString(path);
		else if (type == FileType_File && EndsWith(name, ".replay")) DiscoverFile(path);
	}
}

void DiscoverFile(const char[] source)
{
	if (!gOwnWorker || !gEnvironment[0] || !SafeReplaySource(source)) return;
	int modified = GetFileTime(source, FileTime_LastChange), size = FileSize(source);
	if (modified < gFloor || modified > GetTime() - 3 || size <= 0) return;
	char revision[192];
	if (!GOKZTop_ReplayRevision(source, revision, sizeof(revision))) return;
	char env[1024], escaped[512], query[2048];
	gDB.Escape(gEnvironment, env, sizeof(env));
	gDB.Escape(source, escaped, sizeof(escaped));
	Format(query, sizeof(query), "SELECT 1 FROM files WHERE environment='%s' AND path='%s' AND revision='%s'", env, escaped, revision);
	DBResultSet rows = SQL_Query(gDB, query);
	bool seen = rows != null && rows.FetchRow(); delete rows;
	if (seen) return;
	JumpReplayUploadHeader header;
	if (!ReadJumpReplayUploadHeader(source, header)) return;
	// Snapshot before any HTTP operation; never upload a mutable legacy filename.
	char partial[PLATFORM_MAX_PATH];
	Format(partial, sizeof(partial), "%s/candidate.part", gSpool);
	DeleteFile(partial);
	int hash;
	if (!GOKZTop_SnapshotReplay(source, partial, hash)) return;
	char after[192];
	if (!GOKZTop_ReplayRevision(source, after, sizeof(after)) || !StrEqual(after, revision))
	{
		DeleteFile(partial); return;
	}

	JumpReplayUploadHeader snapshot;
	if (!ReadJumpReplayUploadHeader(partial, snapshot)) { DeleteFile(partial); return; }
	char signature[256];
	Format(signature, sizeof(signature), "%s:%d:%s:%s:%08x:%d:%08x", snapshot.steamID64, snapshot.timestamp, snapshot.mode, snapshot.jumpType, view_as<int>(snapshot.distance), size, hash);
	Format(query, sizeof(query), "INSERT OR IGNORE INTO jobs(environment,signature) VALUES('%s','%s')", env, signature);
	if (!QueueSQL(query)) { DeleteFile(partial); return; }
	Format(query, sizeof(query), "SELECT id,state FROM jobs WHERE environment='%s' AND signature='%s'", env, signature);
	rows = SQL_Query(gDB, query);
	if (rows == null || !rows.FetchRow()) { delete rows; DeleteFile(partial); return; }
	int id = rows.FetchInt(0); char state[32]; rows.FetchString(1, state, sizeof(state)); delete rows;
	char path[PLATFORM_MAX_PATH]; JobPath(id, path, sizeof(path));
	if (StrEqual(state, "done") || StrEqual(state, "rejected") || FileExists(path)) DeleteFile(partial);
	else if (!RenameFile(path, partial)) { DeleteFile(partial); SetJobState(id, "spooling"); return; }
	if (StrEqual(state, "spooling") && FileExists(path)) SetJobState(id, "pending");
	Format(query, sizeof(query), "INSERT OR REPLACE INTO files(environment,path,mtime,size,revision) VALUES('%s','%s',%d,%d,'%s')", env, escaped, modified, size, revision);
	QueueSQL(query);
}
