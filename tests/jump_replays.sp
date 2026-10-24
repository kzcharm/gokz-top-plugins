// Exercises the production modules without starting their worker or making HTTP requests.
#define OnPluginStart UploaderStart
#define OnPluginEnd UploaderEnd
#define OnAllPluginsLoaded UploaderLoaded
#include "../addons/sourcemod/scripting/gokz-top-replays.sp"
#undef OnPluginStart
#undef OnPluginEnd
#undef OnAllPluginsLoaded

int gAssertions;
void Check(bool condition, const char[] label)
{
	gAssertions++;
	if (!condition) SetFailState("jump-replays-test: %s", label);
}

void ExpectState(const char[] expected)
{
	DBResultSet rows = SQL_Query(gDB, "SELECT state FROM jobs WHERE id=1");
	Check(rows != null && rows.FetchRow(), "job exists");
	char state[32]; rows.FetchString(0, state, sizeof(state)); delete rows;
	Check(StrEqual(state, expected), expected);
}

public void OnPluginStart()
{
	char error[256]; gDB = SQLite_UseDatabase("gokz-top-replays-tests", error, sizeof(error));
	Check(gDB != null, "test database");
	QueueSQL("DROP TABLE IF EXISTS jobs");
	QueueSQL("CREATE TABLE jobs(id INTEGER PRIMARY KEY,environment TEXT,signature TEXT,state TEXT DEFAULT 'pending',attempts INTEGER DEFAULT 0,next INTEGER DEFAULT 0,status INTEGER DEFAULT 0)");
	QueueSQL("INSERT INTO jobs(id) VALUES(1)");
	BuildPath(Path_SM, gSpool, sizeof(gSpool), "data/gokz-top-replays-tests");
	CreateDirectory(gSpool, 448);
	gActiveID = 1; gAttempts = 1;
	FinishJob(500); ExpectState("pending");
	DBResultSet rows = SQL_Query(gDB, "SELECT next FROM jobs WHERE id=1");
	Check(rows != null && rows.FetchRow() && rows.FetchInt(0) >= GetTime() + 4, "first retry delay"); delete rows;
	gAttempts = 8; FinishJob(429); ExpectState("exhausted");
	FinishJob(401); ExpectState("auth");
	FinishJob(403); ExpectState("auth");
	FinishJob(409); ExpectState("rejected");
	FinishJob(422); ExpectState("rejected");
	FinishJob(201); ExpectState("done");
	char steam[32];
	AccountToSteam64(12345, steam, sizeof(steam)); Check(StrEqual(steam, "76561197960278073"), "small account");
	AccountToSteam64(1102660270, steam, sizeof(steam)); Check(StrEqual(steam, "76561199062925998"), "large account");
	AccountToSteam64(2147483647, steam, sizeof(steam)); Check(StrEqual(steam, "76561200107749375"), "maximum signed account");
	JumpReplayUploadHeader header;
	char path[PLATFORM_MAX_PATH];
	BuildPath(Path_SM, path, sizeof(path), "%s/totally-arbitrary.replay", RP_DIRECTORY_JUMPS);
	Check(ReadJumpReplayUploadHeader(path, header), "arbitrary filename header without player");
	Check(StrEqual(header.steamID64, "76561197960278073"), "identity from header");
	Check(StrEqual(header.mode, "KZT") && StrEqual(header.jumpType, "LJ"), "mode and type");
	Check(FloatAbs(header.distance - 281.8030) < 0.0001, "distance");
	Check(!IsReplayLink(path), "ordinary file");
	Check(SafeReplaySource(path), "safe source path");
	char revision[192], after[192], copy[PLATFORM_MAX_PATH];
	Check(GOKZTop_ReplayRevision(path, revision, sizeof(revision)), "subsecond revision");
	Format(copy, sizeof(copy), "%s/test-snapshot.replay", gSpool); DeleteFile(copy);
	int checksum;
	Check(GOKZTop_SnapshotReplay(path, copy, checksum), "immutable snapshot");
	Check(FileSize(path) == FileSize(copy), "snapshot size");
	Check(!GOKZTop_SnapshotReplay(path, copy, checksum), "never overwrite snapshot");
	File fixture = OpenFile(path, "r+b");
	fixture.Seek(-1, SEEK_END); fixture.WriteInt8(123); delete fixture;
	Check(GOKZTop_ReplayRevision(path, after, sizeof(after)) && !StrEqual(after, revision), "same-size overwrite changes revision");
	File snapshot = OpenFile(copy, "rb"); int last;
	snapshot.Seek(-1, SEEK_END); snapshot.ReadInt8(last); delete snapshot;
	Check(last != 123, "snapshot unaffected by overwrite"); DeleteFile(copy);

	BuildPath(Path_SM, path, sizeof(path), "%s/compat-link.replay", RP_DIRECTORY_JUMPS);
	Check(IsReplayLink(path), "symlink");
	Check(!SafeReplaySource(path), "symlink excluded from discovery");
	Check(!GOKZTop_SnapshotReplay(path, copy, checksum), "symlink cannot be copied");
	Check(!SafeReplaySource("addons/sourcemod/data/gokz-replays/_jumps/../outside.replay"), "parent traversal rejected");

	BuildPath(Path_SM, path, sizeof(path), "%s/unsupported.replay", RP_DIRECTORY_JUMPS);
	Check(!ReadJumpReplayUploadHeader(path, header), "reject non-normal style");
	strcopy(gActiveEnvironment, sizeof(gActiveEnvironment), "https://example.test/api/v1");
	char url[512]; JobURL("/v1/jumpstats/replay", url, sizeof(url));
	Check(StrEqual(url, "https://example.test/api/v1/jumpstats/replay"), "version suffix");
	JSON_Object body = json_decode("{\"eligible\":\n true}");
	Check(body != null && body.GetKeyType("eligible") == Type_Bool && body.GetBool("eligible"), "JSON whitespace");
	body.Cleanup(); delete body;
	body = json_decode("{\"eligible\":\"true\"}");
	Check(body != null && body.GetKeyType("eligible") != Type_Bool, "reject non-boolean eligibility");
	body.Cleanup(); delete body;
	char rounded[32];
	Check(GOKZTop_FormatJumpDistance(278.53125, rounded, sizeof(rounded)) && StrEqual(rounded, "278.5313"), "backend half-up distance rounding");
	LogMessage("[jump-replays-test] PASS assertions=%d", gAssertions);
}

public void OnPluginEnd()
{
	delete gDB;
}
