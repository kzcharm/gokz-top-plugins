void Queue_Init()
{
	char error[256];
	gDB = SQLite_UseDatabase("gokz-top-records", error, sizeof(error));
	if (gDB == null) SetFailState("Cannot open durable records queue: %s", error);
	char databasePath[PLATFORM_MAX_PATH];
	BuildPath(Path_SM, databasePath, sizeof(databasePath), "data/sqlite/gokz-top-records.sq3");
	SetFilePermissions(databasePath, 384);
	Queue_CreateTables();
}

void Queue_CreateTables()
{
	Queue_SQL("PRAGMA synchronous=FULL");
	Queue_SQL("CREATE TABLE IF NOT EXISTS jobs (id TEXT PRIMARY KEY, environment TEXT NOT NULL, steam2 TEXT NOT NULL DEFAULT '', server TEXT NOT NULL, payload TEXT NOT NULL, state TEXT NOT NULL DEFAULT 'record', attempts INTEGER NOT NULL DEFAULT 0, next INTEGER NOT NULL DEFAULT 0, canonical TEXT NOT NULL DEFAULT '', replay TEXT NOT NULL DEFAULT '', upstream INTEGER NOT NULL DEFAULT 0, eligible INTEGER NOT NULL DEFAULT 0, replay_done INTEGER NOT NULL DEFAULT 0, error TEXT NOT NULL DEFAULT '')");
	DBResultSet columns = SQL_Query(gDB, "PRAGMA table_info(jobs)");
	bool hasReplayDone, hasRelay;
	char column[64];
	while (columns != null && columns.FetchRow())
	{
		columns.FetchString(1, column, sizeof(column));
		if (StrEqual(column, "replay_done")) hasReplayDone = true;
		if (StrEqual(column, "relay")) hasRelay = true;
	}
	delete columns;
	if (!hasReplayDone) Queue_SQL("ALTER TABLE jobs ADD COLUMN replay_done INTEGER NOT NULL DEFAULT 0");
	if (!hasRelay) Queue_SQL("ALTER TABLE jobs ADD COLUMN relay INTEGER NOT NULL DEFAULT 0");
	Queue_SQL("CREATE INDEX IF NOT EXISTS jobs_due ON jobs(state,next)");
}

bool Queue_SQL(const char[] query)
{
	if (SQL_FastQuery(gDB, query)) return true;
	char error[256];
	SQL_GetError(gDB, error, sizeof(error));
	LogError("Records queue write failed: %s", error);
	return false;
}

bool Queue_Insert(const char[] id, const char[] environment, const char[] server, const char[] payload, const char[] steam2, bool relay = false)
{
	if (!IsRecordUUID(id)) return false;
	char lookup[256];
	Format(lookup, sizeof(lookup), "SELECT environment,server,payload,steam2,relay FROM jobs WHERE id='%s'", id);
	DBResultSet existing = SQL_Query(gDB, lookup);
	if (existing == null) return false;
	if (existing.FetchRow())
	{
		char savedEnvironment[512], savedServer[37], savedPayload[4096], savedSteam[32];
		existing.FetchString(0, savedEnvironment, sizeof(savedEnvironment));
		existing.FetchString(1, savedServer, sizeof(savedServer));
		existing.FetchString(2, savedPayload, sizeof(savedPayload));
		existing.FetchString(3, savedSteam, sizeof(savedSteam));
		bool matches = StrEqual(environment, savedEnvironment) && StrEqual(server, savedServer)
			&& StrEqual(payload, savedPayload) && StrEqual(steam2, savedSteam) && relay == (existing.FetchInt(4) != 0);
		delete existing;
		if (!matches) LogError("Conflicting completion for existing run %s; original job retained", id);
		return matches;
	}
	delete existing;
	RecordFilterDecision decision = Eligibility_Payload(environment, payload);
	if (decision == RecordFilters_Unsupported)
	{
		Format(gLastStatus, sizeof(gLastStatus), "Skipped unsupported map/mode record %s", id);
		return true;
	}
	char escaped[8192], escapedEnv[1024], escapedServer[75], escapedSteam[65], query[10240];
	gDB.Escape(payload, escaped, sizeof(escaped));
	gDB.Escape(environment, escapedEnv, sizeof(escapedEnv));
	gDB.Escape(server, escapedServer, sizeof(escapedServer));
	gDB.Escape(steam2, escapedSteam, sizeof(escapedSteam));
	Format(query, sizeof(query), "INSERT INTO jobs(id,environment,server,payload,steam2,state,relay) VALUES('%s','%s','%s','%s','%s','%s',%d)", id, escapedEnv, escapedServer, escaped, escapedSteam, decision == RecordFilters_Unknown ? "filters" : "record", relay ? 1 : 0);
	return Queue_SQL(query);
}

void Queue_State(const char[] id, const char[] state, int next, const char[] error = "")
{
	char escaped[1024], query[2048];
	gDB.Escape(error, escaped, sizeof(escaped));
	Format(query, sizeof(query), "UPDATE jobs SET state='%s',next=%d,error='%s' WHERE id='%s'", state, next, escaped, id);
	Queue_SQL(query);
}

public Action Timer_Worker(Handle timer)
{
	Eligibility_PrefetchCurrent();
	for (int client = 1; client <= MaxClients; client++)
	{
		if (!IsClientInGame(client) || IsFakeClient(client)) continue;
		QueryClientSettings(client);
		if (gRun[client] && (!GOKZ_GetValidTimer(client) || !ServerSettingsValid())) gValid[client] = false;
	}
	DiscoverReplays();
	if (!gBusy) HTTP_Next();
	return Plugin_Continue;
}

bool IsRecordUUID(const char[] value)
{
	if (strlen(value) != 36) return false;
	for (int i = 0; i < 36; i++)
	{
		if (i == 8 || i == 13 || i == 18 || i == 23)
		{
			if (value[i] != '-') return false;
		}
		else if (!((value[i] >= '0' && value[i] <= '9') || (value[i] >= 'a' && value[i] <= 'f') || (value[i] >= 'A' && value[i] <= 'F'))) return false;
	}
	return true;
}
