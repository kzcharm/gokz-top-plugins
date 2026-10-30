// Dedicated test server only. Own SQLite/spool; synthetic requests never leave the server.
#include <sourcemod>
#include <SteamWorks>
#include <gokz/top>

#define AskPluginLoad2 RecordsUnusedAsk
#define OnPluginStart RecordsUnusedStart
#define OnMapStart RecordsUnusedMap
#define SteamWorks_CreateHTTPRequest TestCreateRequest
#define GOKZTop_GetHTTPConfig TestHTTPConfig
#define GOKZTop_GetServerSteamID TestServerIdentity
// Keep included production forwards private to this probe; real events must
// never enter synthetic fixtures, even while another test is running.
#define GOKZ_Relay_OnCaptureEvidence ProbeRecordFilters_GOKZ_Relay_OnCaptureEvidence
#define GOKZ_Relay_OnResume ProbeRecordFilters_GOKZ_Relay_OnResume
#define GOKZ_Relay_OnResumeCheck ProbeRecordFilters_GOKZ_Relay_OnResumeCheck
#define GOKZ_Relay_OnCompleted ProbeRecordFilters_GOKZ_Relay_OnCompleted
#define GOKZ_Relay_OnReplaySaved ProbeRecordFilters_GOKZ_Relay_OnReplaySaved
#define GOKZ_OnTimerStart_Post ProbeRecordFilters_GOKZ_OnTimerStart_Post
#define GOKZ_OnTimerEnd_Post ProbeRecordFilters_GOKZ_OnTimerEnd_Post
#define GOKZ_OnTimerStopped ProbeRecordFilters_GOKZ_OnTimerStopped
#define GOKZ_AC_OnPlayerSuspected ProbeRecordFilters_GOKZ_AC_OnPlayerSuspected
#define GOKZ_OnOptionChanged ProbeRecordFilters_GOKZ_OnOptionChanged
#define GOKZ_OnModeUnloaded ProbeRecordFilters_GOKZ_OnModeUnloaded
#define GOKZ_RP_OnReplaySaved ProbeRecordFilters_GOKZ_RP_OnReplaySaved
#define GlobalAPI_OnRequestStarted ProbeRecordFilters_GlobalAPI_OnRequestStarted
#define GlobalAPI_OnRequestFinished ProbeRecordFilters_GlobalAPI_OnRequestFinished
#define OnClientPutInServer ProbeRecordFilters_OnClientPutInServer
#define OnClientDisconnect ProbeRecordFilters_OnClientDisconnect
#define OnLibraryRemoved ProbeRecordFilters_OnLibraryRemoved
#include "../addons/sourcemod/scripting/gokz-top-records.sp"
#undef OnPluginStart

int gAssertions, gGets, gPosts;
char gTestEnvironment[] = "https://records-filters.invalid";
char gTestServer[] = "85568392936085241";

Handle TestCreateRequest(EHTTPMethod method, const char[] url)
{
	if (method == k_EHTTPMethodGET) gGets++;
	else gPosts++;
	if (!url[0]) SetFailState("Missing synthetic request URL");
	return null;
}

void TestHTTPConfig(char[] url, int urlLength, char[] key, int keyLength)
{
	strcopy(url, urlLength, gTestEnvironment); strcopy(key, keyLength, "synthetic-key");
}

bool TestServerIdentity(char[] identity, int capacity)
{
	strcopy(identity, capacity, gTestServer);
	return true;
}

void Check(bool condition, const char[] label)
{
	if (!condition) SetFailState("record-filters-test: %s", label);
	gAssertions++;
}

int Jobs()
{
	DBResultSet rows = SQL_Query(gDB, "SELECT count(*) FROM jobs");
	Check(rows != null && rows.FetchRow(), "queue readable");
	int count = rows.FetchInt(0); delete rows; return count;
}

void CheckState(const char[] id, const char[] expected)
{
	char query[256], state[32];
	Format(query, sizeof(query), "SELECT state FROM jobs WHERE id='%s'", id);
	DBResultSet rows = SQL_Query(gDB, query);
	Check(rows != null && rows.FetchRow(), "job retained");
	rows.FetchString(0, state, sizeof(state)); delete rows;
	Check(StrEqual(state, expected), expected);
}

void InsertFixture(const char[] id, const char[] payload, const char[] state = "record", const char[] canonical = "")
{
	char escaped[8192], query[10240]; gDB.Escape(payload, escaped, sizeof(escaped));
	Format(query, sizeof(query), "INSERT INTO jobs(id,environment,server,payload,state,canonical) VALUES('%s','%s','%s','%s','%s','%s')", id, gTestEnvironment, gTestServer, escaped, state, canonical);
	Check(Queue_SQL(query), "synthetic fixture inserted");
}

public void OnPluginStart()
{
	char error[256];
	gDB = SQLite_UseDatabase("gokz-top-record-filters-tests", error, sizeof(error));
	Check(gDB != null, "isolated database");
	Queue_SQL("DROP TABLE IF EXISTS jobs"); Queue_SQL("DROP TABLE IF EXISTS record_filters");
	Queue_CreateTables(); Eligibility_Init();
	gCV_Server = CreateConVar("record_filters_test_legacy", "");
	BuildPath(Path_SM, gSpool, sizeof(gSpool), "data/gokz-top-record-filters-tests");
	CreateDirectory(gSpool, 448);
	int flags[256];
	Check(Eligibility_ParseFilters("[{\"map_id\":841,\"stage\":0,\"mode_id\":202,\"tickrate\":128,\"has_teleports\":true},{\"map_id\":841,\"stage\":0,\"mode_id\":201,\"tickrate\":128,\"has_teleports\":false},{\"map_id\":841,\"stage\":2,\"mode_id\":200,\"tickrate\":128,\"has_teleports\":true},{\"map_id\":-1,\"stage\":0,\"mode_id\":200,\"tickrate\":128,\"has_teleports\":true},{\"map_id\":841,\"stage\":0,\"mode_id\":200,\"tickrate\":64,\"has_teleports\":true},{\"map_id\":999,\"stage\":0,\"mode_id\":200,\"tickrate\":128,\"has_teleports\":true},{\"map_id\":841,\"stage\":0,\"mode_id\":203,\"tickrate\":128,\"has_teleports\":true}]", 841, flags), "valid filter response");
	Eligibility_Store(gTestEnvironment, "vnl_test", flags);
	Check(Eligibility_Check(gTestEnvironment, "vnl_test", 0, 0, 1) == RecordFilters_Supported, "VNL NUB");
	Check(Eligibility_Check(gTestEnvironment, "vnl_test", 0, 0, 0) == RecordFilters_Supported, "zero TP fits NUB");
	Check(Eligibility_Check(gTestEnvironment, "vnl_test", 0, 1, 0) == RecordFilters_Supported, "SKZ PRO");
	Check(Eligibility_Check(gTestEnvironment, "vnl_test", 0, 1, 1) == RecordFilters_Unsupported, "PRO cannot grant NUB");
	Check(Eligibility_Check(gTestEnvironment, "vnl_test", 0, 2, 0) == RecordFilters_Unsupported, "no wildcard, wrong map, or 64-tick fallback");
	Check(Eligibility_Check(gTestEnvironment, "vnl_test", 0, 3, 0) == RecordFilters_Unsupported, "NKZ filter cannot bypass missing KZT");
	Check(Eligibility_Check(gTestEnvironment, "vnl_test", 2, 2, 1) == RecordFilters_Supported, "KZT bonus");
	Check(Eligibility_Check(gTestEnvironment, "vnl_test", 2, 3, 1) == RecordFilters_Supported, "NKZ shares KZT bonus");
	Check(Eligibility_Check(gTestEnvironment, "vnl_test", 1, 0, 0) == RecordFilters_Unsupported, "exact stage required");
	Check(Eligibility_Check(gTestEnvironment, "vnl_test", 256, 0, 0) == RecordFilters_Unknown, "invalid stage cannot corrupt cache");
	Eligibility_Init();
	Check(Eligibility_Load(gTestEnvironment, "vnl_test", flags) && (flags[2] & Eligibility_Mask(3, 1)) != 0, "cache survives memory reset");
	Eligibility_Store(gTestEnvironment, "vnl_test", flags);
	Check(Eligibility_ParseFilters("[]", 841, flags), "empty filters are authoritative");
	Eligibility_Store(gTestEnvironment, "unsupported", flags);
	Check(Eligibility_Check(gTestEnvironment, "unsupported", 0, 0, 0) == RecordFilters_Unsupported, "empty catalog blocks VNL too");
	Check(!Eligibility_ParseFilters("{\"detail\":\"unavailable\"}", 841, flags), "error object is not empty filter data");
	Check(!Eligibility_ParseFilters("[{\"map_id\":841}]", 841, flags), "incomplete response remains unknown");
	Check(!Eligibility_ParseFilters("broken", 841, flags), "invalid JSON remains unknown");

	char id1[] = "01900000-0000-7000-8000-000000000001";
	char id2[] = "01900000-0000-7000-8000-000000000002";
	char id3[] = "01900000-0000-7000-8000-000000000003";
	char id4[] = "01900000-0000-7000-8000-000000000004";
	char unsupported[] = "{\"map_name\":\"vnl_test\",\"mode\":\"NKZ\",\"stage\":0,\"teleports\":0}";
	char supported[] = "{\"map_name\":\"vnl_test\",\"mode\":\"NKZ\",\"stage\":2,\"teleports\":1}";
	Check(Queue_Insert(id1, gTestEnvironment, gTestServer, unsupported, ""), "unsupported finish handled without persistence error");
	Check(Jobs() == 0, "unsupported finish is never queued");
	Check(Queue_Insert(id2, gTestEnvironment, gTestServer, supported, ""), "supported finish queued");
	CheckState(id2, "record");
	Queue_SQL("UPDATE jobs SET state='accepted',attempts=3,next=123,canonical=id,eligible=1,replay_done=1");
	Check(Queue_Insert(id2, gTestEnvironment, gTestServer, supported, ""), "identical completion redelivery acknowledged");
	CheckState(id2, "accepted");
	DBResultSet duplicate = SQL_Query(gDB, "SELECT attempts,next,eligible,replay_done FROM jobs");
	Check(duplicate != null && duplicate.FetchRow(), "duplicate job readable");
	Check(duplicate.FetchInt(0) == 3 && duplicate.FetchInt(1) == 123 && duplicate.FetchInt(2) == 1 && duplicate.FetchInt(3) == 1, "duplicate retains retry and replay acknowledgements");
	delete duplicate;
	Check(!Queue_Insert(id2, "https://wrong.invalid", gTestServer, supported, ""), "UUID cannot move API environments");
	Check(!Queue_Insert(id2, gTestEnvironment, gTestServer, unsupported, ""), "UUID cannot replace completion stats");
	Check(!Queue_Insert(id2, gTestEnvironment, gTestServer, supported, "", true), "UUID cannot change origin");
	Queue_CreateTables();
	CheckState(id2, "accepted");
	Queue_SQL("DELETE FROM jobs");
	Check(Queue_Insert(id3, "https://other-environment.invalid", gTestServer, unsupported, ""), "unknown environment retains finish");
	CheckState(id3, "filters");
	Check(gGets == 1 && gPosts == 0, "unknown catalog requests metadata only");
	Eligibility_PruneQueue(gTestEnvironment, gTestServer, "");
	Check(Jobs() == 1, "another environment's waiting job is not pruned");
	Queue_SQL("DELETE FROM jobs");
	InsertFixture(id1, unsupported, "rejected"); InsertFixture(id2, supported); InsertFixture(id3, unsupported, "accepted", id3);
	char privatePath[PLATFORM_MAX_PATH], externalPath[PLATFORM_MAX_PATH];
	Format(privatePath, sizeof(privatePath), "%s/%s.replay", gSpool, id1);
	Format(externalPath, sizeof(externalPath), "%s/upstream.replay", gSpool);
	File file = OpenFile(privatePath, "wb"); file.WriteInt8(1); delete file;
	file = OpenFile(externalPath, "wb"); file.WriteInt8(2); delete file;
	char query[1024]; Format(query, sizeof(query), "UPDATE jobs SET replay='%s' WHERE id='%s'", externalPath, id1); Queue_SQL(query);
	Eligibility_PruneQueue(gTestEnvironment, gTestServer, "");
	Check(Jobs() == 2, "old unsupported rejection removed, supported and accepted retained");
	Check(!FileExists(privatePath) && FileExists(externalPath), "only private derived spool is removed");
	Eligibility_Discard(id3); Check(Jobs() == 2, "accepted identity cannot be discarded");
	gPosts = 0;
	HTTP_Next(); Check(gPosts == 1, "supported queued job reaches the POST path");
	CheckState(id2, "record");
	Queue_SQL("DELETE FROM jobs");
	InsertFixture(id1, unsupported);
	gGets = 0; gPosts = 0;
	HTTP_Next(); Check(Jobs() == 0 && gPosts == 0, "unsupported queued job never reaches upload request");
	InsertFixture(id4, "{\"map_name\":\"unknown\",\"mode\":\"VNL\",\"stage\":0,\"teleports\":0}");
	HTTP_Next(); CheckState(id4, "filters"); Check(gPosts == 0, "unknown queued job waits without upload");
	Queue_SQL("DELETE FROM jobs");
	Check(Eligibility_IsFilterRejection("{\"detail\":{\"checks\":{\"filter\":false}}}"), "recognize authoritative filter rejection");
	Check(!Eligibility_IsFilterRejection("{\"detail\":{\"checks\":{\"filter\":true,\"integrity\":false}}}"), "other rejections retained");
	Check(!Eligibility_IsFilterRejection("{\"detail\":\"invalid\"}"), "generic rejection is not filter evidence");
	Check(!Eligibility_IsFilterRejection("{}"), "missing filter evidence is not negative");
	flags[0] = 3 << 4;
	Eligibility_Store(gTestEnvironment, "changed", flags);
	InsertFixture(id1, "{\"map_name\":\"changed\",\"mode\":\"NKZ\",\"stage\":0,\"teleports\":1}");
	Eligibility_RejectQueued(id1);
	Check(Jobs() == 0, "authoritative filter rejection is discarded");
	Check(Eligibility_Check(gTestEnvironment, "changed", 0, 2, 1) == RecordFilters_Unsupported, "stale positive NUB cache revoked");
	Check(Eligibility_Check(gTestEnvironment, "changed", 0, 3, 0) == RecordFilters_Supported, "PRO remains available through shared KZT cache");
	InsertFixture(id1, "{\"map_name\":\"changed\",\"mode\":\"NKZ\",\"stage\":0,\"teleports\":0}");
	Eligibility_RejectQueued(id1);
	Check(Jobs() == 0, "zero-TP filter rejection is also discarded");
	Check(Eligibility_Check(gTestEnvironment, "changed", 0, 2, 0) == RecordFilters_Unsupported, "zero-TP rejection revokes both filter categories");
	DeleteFile(externalPath);
	LogMessage("[record-filters-test] PASS assertions=%d", gAssertions);
}
