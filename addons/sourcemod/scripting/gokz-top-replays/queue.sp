bool QueueSQL(const char[] query)
{
	if (SQL_FastQuery(gDB, query)) return true;
	char error[256]; SQL_GetError(gDB, error, sizeof(error));
	LogError("[gokz-top-replays] SQLite: %s", error);
	return false;
}

void QueueInit()
{
	char error[256];
	gDB = SQLite_UseDatabase("gokz-top-replays", error, sizeof(error));
	if (gDB == null) SetFailState("Cannot open replay queue: %s", error);
	QueueSQL("PRAGMA busy_timeout=250");
	QueueSQL("PRAGMA synchronous=FULL");
	QueueSQL("CREATE TABLE IF NOT EXISTS settings (name TEXT PRIMARY KEY,value INTEGER NOT NULL)");
	QueueSQL("CREATE TABLE IF NOT EXISTS files (environment TEXT NOT NULL,path TEXT NOT NULL,mtime INTEGER NOT NULL,size INTEGER NOT NULL,revision TEXT NOT NULL DEFAULT '',PRIMARY KEY(environment,path))");
	DBResultSet columns = SQL_Query(gDB, "PRAGMA table_info(files)");
	bool hasRevision;
	while (columns != null && columns.FetchRow())
	{
		char name[64]; columns.FetchString(1, name, sizeof(name));
		if (StrEqual(name, "revision")) hasRevision = true;
	}
	delete columns;
	if (!hasRevision) QueueSQL("ALTER TABLE files ADD COLUMN revision TEXT NOT NULL DEFAULT ''");

	QueueSQL("CREATE TABLE IF NOT EXISTS jobs (id INTEGER PRIMARY KEY AUTOINCREMENT,environment TEXT NOT NULL,signature TEXT NOT NULL,state TEXT NOT NULL DEFAULT 'pending',attempts INTEGER NOT NULL DEFAULT 0,next INTEGER NOT NULL DEFAULT 0,status INTEGER NOT NULL DEFAULT 0,UNIQUE(environment,signature))");
	QueueSQL("CREATE INDEX IF NOT EXISTS jobs_due ON jobs(environment,state,next)");
	char query[256];
	Format(query, sizeof(query), "INSERT OR IGNORE INTO settings VALUES('activation',%d)", GetTime());
	QueueSQL(query);
	DBResultSet rows = SQL_Query(gDB, "SELECT value FROM settings WHERE name='activation'");
	if (rows != null && rows.FetchRow()) gFloor = rows.FetchInt(0);
	else SetFailState("Cannot read replay activation time");
	delete rows;
	char path[PLATFORM_MAX_PATH];
	BuildPath(Path_SM, path, sizeof(path), "data/sqlite/gokz-top-replays.sq3");
	SetFilePermissions(path, 384);
}

void JobPath(int id, char[] path, int length)
{
	Format(path, length, "%s/%d.replay", gSpool, id);
}

bool SetJobState(int id, const char[] state, int next = 0, int status = 0)
{
	char query[256];
	Format(query, sizeof(query), "UPDATE jobs SET state='%s',next=%d,status=%d WHERE id=%d", state, next, status, id);
	return QueueSQL(query);
}

public Action CommandRetry(int client, int args)
{
	QueueSQL("UPDATE jobs SET state='pending',attempts=0,next=0 WHERE state IN ('exhausted','auth')");
	ReplyToCommand(client, "Jump replay retries resumed for the configured API environment.");
	return Plugin_Handled;
}

public Action CommandStatus(int client, int args)
{
	ReplyToCommand(client, "Jump replays: API=%s configured=%d worker=%d busy=%d directories=%d scan_active=%d max_scan_ms=%.3f", gEnvironment, gKey[0] != '\0', gOwnWorker, gBusy, gDirectories.Length, gListing != null, gMaxScanSeconds * 1000.0);
	DBResultSet rows = SQL_Query(gDB, "SELECT state,count(*) FROM jobs GROUP BY state");
	while (rows != null && rows.FetchRow())
	{
		char state[32]; rows.FetchString(0, state, sizeof(state));
		ReplyToCommand(client, "%s: %d", state, rows.FetchInt(1));
	}
	delete rows;
	return Plugin_Handled;
}
