// Dedicated test server only; isolated SQLite/spool and no outgoing HTTP.
#include <sourcemod>
#include <SteamWorks>
#include <gokz/top>
#undef REQUIRE_PLUGIN
#include <gokz/relay>
#define AskPluginLoad2 RelayTestUnusedAsk
#define OnPluginStart RelayTestUnusedStart
#define OnMapStart RelayTestUnusedMap
#define LibraryExists TestLibraryExists
#define GetFeatureStatus TestFeatureStatus
#define GOKZ_Relay_AcknowledgeCompletion TestAcknowledge
#define SteamWorks_CreateHTTPRequest TestCreateRequest
#define GOKZTop_GetHTTPConfig TestHTTPConfig
// Keep included production forwards private to this probe; real events must
// never enter synthetic fixtures, even while another test is running.
#define GOKZ_Relay_OnCaptureEvidence ProbeRelayRecords_GOKZ_Relay_OnCaptureEvidence
#define GOKZ_Relay_OnResume ProbeRelayRecords_GOKZ_Relay_OnResume
#define GOKZ_Relay_OnResumeCheck ProbeRelayRecords_GOKZ_Relay_OnResumeCheck
#define GOKZ_Relay_OnCompleted ProbeRelayRecords_GOKZ_Relay_OnCompleted
#define GOKZ_Relay_OnReplaySaved ProbeRelayRecords_GOKZ_Relay_OnReplaySaved
#define GOKZ_OnTimerStart_Post ProbeRelayRecords_GOKZ_OnTimerStart_Post
#define GOKZ_OnTimerEnd_Post ProbeRelayRecords_GOKZ_OnTimerEnd_Post
#define GOKZ_OnTimerStopped ProbeRelayRecords_GOKZ_OnTimerStopped
#define GOKZ_AC_OnPlayerSuspected ProbeRelayRecords_GOKZ_AC_OnPlayerSuspected
#define GOKZ_OnOptionChanged ProbeRelayRecords_GOKZ_OnOptionChanged
#define GOKZ_OnModeUnloaded ProbeRelayRecords_GOKZ_OnModeUnloaded
#define GOKZ_RP_OnReplaySaved ProbeRelayRecords_GOKZ_RP_OnReplaySaved
#define GlobalAPI_OnRequestStarted ProbeRelayRecords_GlobalAPI_OnRequestStarted
#define GlobalAPI_OnRequestFinished ProbeRelayRecords_GlobalAPI_OnRequestFinished
#define OnClientPutInServer ProbeRelayRecords_OnClientPutInServer
#define OnClientDisconnect ProbeRelayRecords_OnClientDisconnect
#define OnLibraryRemoved ProbeRelayRecords_OnLibraryRemoved
#include "../addons/sourcemod/scripting/gokz-top-records.sp"
#undef OnPluginStart

int sAssertions, sAcks, sRequests;
bool sAvailable = true;
char sID[] = "01900000-0000-7000-8000-000000000001";
char sEnvironment[] = "https://relay-records.invalid";
char sCompletion[] = "{\"version\":2,\"run_id\":\"01900000-0000-7000-8000-000000000001\",\"steamid64\":\"76561197960265974\",\"map_name\":\"relay_test\",\"course\":0,\"mode\":2,\"style\":0,\"time_ms\":123456,\"teleports\":1,\"finished_at\":1793384000,\"eligible\":true}";
char sEvidence[] = "{\"evidence_version\":2,\"run_id\":\"01900000-0000-7000-8000-000000000001\",\"steamid64\":\"76561197960265974\",\"steam2\":\"STEAM_1:0:123\",\"server_id\":\"85568392936085241\",\"environment\":\"https://relay-records.invalid\",\"map_name\":\"relay_test\",\"bsp_size\":12345,\"stage\":0,\"mode\":\"KZT\",\"style\":0,\"mode_version\":2172,\"tickrate\":128,\"integrity\":{\"fresh_map\":true,\"server_settings\":true,\"client_settings\":true,\"required_plugins\":true,\"timer_valid\":true,\"mode_stable\":true,\"anticheat_clear\":true}}";

bool TestLibraryExists(const char[] name) { return sAvailable && name[0] != '\0'; }
FeatureStatus TestFeatureStatus(FeatureType type, const char[] name) { return type == FeatureType_Native && name[0] ? FeatureStatus_Available : FeatureStatus_Unavailable; }
bool TestAcknowledge(const char[] id, const char[] consumer)
{
	if (!StrEqual(id, sID) || !StrEqual(consumer, "gokz.top")) SetFailState("Unexpected relay acknowledgement");
	sAcks++;
	return true;
}
Handle TestCreateRequest(EHTTPMethod method, const char[] url)
{
	if (!url[0] || method != k_EHTTPMethodGET) SetFailState("Unexpected request");
	sRequests++;
	return null;
}
void TestHTTPConfig(char[] url, int urlLength, char[] key, int keyLength)
{
	strcopy(url, urlLength, sEnvironment); strcopy(key, keyLength, "synthetic-key");
}
void Check(bool condition, const char[] label)
{
	if (!condition) SetFailState("relay-records-test: %s", label);
	sAssertions++;
}
int Count(const char[] table)
{
	char query[128]; Format(query, sizeof(query), "SELECT count(*) FROM %s", table);
	DBResultSet rows = SQL_Query(gDB, query);
	Check(rows != null && rows.FetchRow(), "isolated table readable");
	int count = rows.FetchInt(0); delete rows; return count;
}
void Reset()
{
	Queue_SQL("DELETE FROM jobs"); Queue_SQL("DELETE FROM relay_receipts"); sAcks = 0;
}
void RejectMutation(const char[] key, int value)
{
	JSON_Object completion = json_decode(sCompletion), saved = json_decode(sEvidence);
	completion.SetInt(key, value);
	JSON_Object body = Relay_Record(completion, saved);
	Check(body == null, key);
	completion.Cleanup(); delete completion; saved.Cleanup(); delete saved;
}
public void OnPluginStart()
{
	char error[256]; gDB = SQLite_UseDatabase("gokz-top-relay-records-tests", error, sizeof(error));
	Check(gDB != null, "private database");
	Queue_SQL("DROP TABLE IF EXISTS jobs"); Queue_SQL("DROP TABLE IF EXISTS relay_receipts"); Queue_SQL("DROP TABLE IF EXISTS record_filters");
	Queue_CreateTables(); Eligibility_Init(); Relay_Init();
	int flags[256]; flags[0] = 1 << 4; // KZT NUB only; resumed finishes have teleports.
	Eligibility_Store(sEnvironment, "relay_test", flags);
	Check(!Relay_OwnedSession(1), "ordinary session never bypasses core invalidity");
	Check(Relay_UUID(sID) && !Relay_UUID("01900000-0000-4000-8000-000000000001"), "UUIDv7 required");
	Check(!Relay_UUID("01900000-0000-7000-0000-000000000001"), "UUID variant required");
	JSON_Object completion = json_decode(sCompletion), saved = json_decode(sEvidence);
	JSON_Object body = Relay_Record(completion, saved);
	Check(body != null, "trusted resumed completion builds ordinary payload");
	char time[32]; body.GetString("time", time, sizeof(time));
	Check(StrEqual(time, "123.456") && body.GetInt("teleports") == 1, "exact milliseconds and TP count");
	Check(!body.HasKey("evidence_version") && !body.HasKey("environment") && !body.HasKey("run_id"), "private evidence excluded from record API");
	body.Cleanup(); delete body;
	RejectMutation("version", 1); RejectMutation("course", 1); RejectMutation("mode", 1); RejectMutation("style", 1);
	RejectMutation("time_ms", 0); RejectMutation("teleports", -1); RejectMutation("finished_at", 0);
	JSON_Object integrity = saved.GetObject("integrity"); integrity.SetBool("anticheat_clear", false);
	body = Relay_Record(completion, saved); Check(body == null, "earlier anticheat failure cannot regain eligibility");
	integrity.SetBool("anticheat_clear", true); saved.Remove("stage");
	body = Relay_Record(completion, saved); Check(body == null, "incomplete evidence rejected");
	completion.Cleanup(); delete completion; saved.Cleanup(); delete saved;
	completion = json_decode(sCompletion); saved = json_decode(sEvidence);
	saved.SetInt("evidence_version", 1);
	body = Relay_Record(completion, saved); Check(body == null, "legacy evidence cannot claim v2 completion semantics");
	completion.SetInt("version", 1);
	body = Relay_Record(completion, saved);
	Check(body != null, "legitimate pending v1 completion remains processable"); body.Cleanup(); delete body;
	char legacyCompletion[4096], legacyEvidence[4096];
	json_encode(completion, legacyCompletion, sizeof(legacyCompletion)); json_encode(saved, legacyEvidence, sizeof(legacyEvidence));
	GOKZ_Relay_OnCompleted(legacyCompletion, legacyEvidence);
	Check(sAcks == 1 && Count("jobs") == 1, "pending legacy completion durably queued without live client or v2 runtime"); Reset();
	completion.Cleanup(); delete completion; saved.Cleanup(); delete saved;

	completion = json_decode(sCompletion); saved = json_decode(sEvidence);
	completion.SetInt("teleports", 0);
	body = Relay_Record(completion, saved);
	Check(body != null && body.GetInt("teleports") == 0, "validated safe-position resume preserves zero teleports");
	body.Cleanup(); delete body;
	flags[0] = 2 << 4; // Only PRO available: zero TP still qualifies normally.
	Eligibility_Store(sEnvironment, "relay_test", flags);
	Check(Eligibility_Check(sEnvironment, "relay_test", 0, 2, 0) == RecordFilters_Supported, "zero-TP relay uses normal PRO filter");
	Check(Eligibility_Check(sEnvironment, "relay_test", 0, 2, 1) == RecordFilters_Unsupported, "checkpoint TP cannot use PRO-only filter");
	char zeroCompletion[4096]; json_encode(completion, zeroCompletion, sizeof(zeroCompletion));
	GOKZ_Relay_OnCompleted(zeroCompletion, sEvidence);
	Check(sAcks == 1 && Count("jobs") == 1, "zero-TP relay durably queued through PRO-only filter");
	completion.Cleanup(); delete completion; saved.Cleanup(); delete saved;
	Reset(); flags[0] = 1 << 4; Eligibility_Store(sEnvironment, "relay_test", flags);

	sAvailable = false;
	GOKZ_Relay_OnCompleted(sCompletion, sEvidence);
	Check(sAcks == 0 && Count("jobs") == 0, "relay absent is harmless"); sAvailable = true;
	GOKZ_Relay_OnCompleted(sCompletion, sEvidence);
	Check(sAcks == 1 && Count("jobs") == 1 && Count("relay_receipts") == 1, "completion persisted before ack without client");
	DBResultSet rows = SQL_Query(gDB, "SELECT relay,payload FROM jobs");
	Check(rows != null && rows.FetchRow() && rows.FetchInt(0) == 1, "durable relay job marked");
	char payload[4096]; rows.FetchString(1, payload, sizeof(payload)); delete rows;
	Check(StrContains(payload, "steam2") < 0, "Steam2 correlation excluded from API contract");
	gCV_Spool = CreateConVar("relay_records_test_spool_gib", "1");
	BuildPath(Path_SM, gSpool, sizeof(gSpool), "data/gokz-top-relay-records-tests");
	CreateDirectory(gSpool, 448);
	char source[PLATFORM_MAX_PATH], replay[PLATFORM_MAX_PATH];
	Format(source, sizeof(source), "%s/synthetic.replay", gSpool);
	Format(replay, sizeof(replay), "%s/%s.replay", gSpool, sID);
	DeleteFile(replay);
	File file = OpenFile(source, "wb"); Check(file != null, "synthetic replay fixture"); file.WriteInt8(42); delete file;
	GOKZ_Relay_OnReplaySaved("01900000-0000-7000-8000-000000000002", source);
	Check(!FileExists(replay), "unrelated replay UUID never attaches");
	GOKZ_Relay_OnReplaySaved(sID, source);
	Check(FileExists(replay) && FileExists(source), "UUID replay privately copied without deleting recorder file");
	file = OpenFile(source, "wb"); file.WriteInt8(99); delete file;
	GOKZ_Relay_OnReplaySaved(sID, source);
	file = OpenFile(replay, "rb"); int byte; file.ReadInt8(byte); delete file;
	Check(byte == 42, "duplicate replay delivery retains immutable private copy");
	DeleteFile(source); DeleteFile(replay);
	Queue_SQL("UPDATE jobs SET state='accepted',attempts=4,next=123,canonical=id,eligible=1,replay_done=1");
	GOKZ_Relay_OnCompleted(sCompletion, sEvidence);
	Check(sAcks == 2 && Count("jobs") == 1, "repeat delivery is idempotent");
	rows = SQL_Query(gDB, "SELECT attempts,next,replay_done FROM jobs");
	Check(rows != null && rows.FetchRow() && rows.FetchInt(0) == 4 && rows.FetchInt(1) == 123 && rows.FetchInt(2) == 1, "retry and acknowledgements retained"); delete rows;
	delete gDB; gDB = SQLite_UseDatabase("gokz-top-relay-records-tests", error, sizeof(error));
	Relay_Init(); Queue_CreateTables();
	GOKZ_Relay_OnCompleted(sCompletion, sEvidence);
	Check(sAcks == 3 && Count("jobs") == 1, "receipt survives database reopen and migrations");
	completion = json_decode(sCompletion); completion.SetInt("teleports", 2);
	char changed[4096]; json_encode(completion, changed, sizeof(changed));
	GOKZ_Relay_OnCompleted(changed, sEvidence); Check(sAcks == 3, "conflicting delivery never acknowledged");
	Reset();
	GOKZ_Relay_OnCompleted(sCompletion, "");
	Check(sAcks == 1 && Count("jobs") == 0 && Count("relay_receipts") == 1, "legacy evidence durably rejected");
	GOKZ_Relay_OnCompleted(sCompletion, ""); Check(sAcks == 2, "rejection redelivery acknowledged");
	Reset(); completion.SetBool("eligible", false); json_encode(completion, changed, sizeof(changed));
	GOKZ_Relay_OnCompleted(changed, sEvidence);
	Check(sAcks == 1 && Count("jobs") == 0, "relay independently ineligible completion rejected");
	Reset(); Queue_SQL("DROP TABLE relay_receipts");
	GOKZ_Relay_OnCompleted(sCompletion, sEvidence); Check(sAcks == 0, "database failure never acknowledged");
	Relay_Init(); Queue_SQL("DROP TABLE jobs");
	GOKZ_Relay_OnCompleted(sCompletion, sEvidence); Check(sAcks == 0 && Count("relay_receipts") == 0, "queue failure never acknowledged");
	Queue_CreateTables();
	completion.Cleanup(); delete completion;
	Check(sRequests == 0, "no HTTP requests issued");
	PrintToServer("[relay-records-test] PASS assertions=%d", sAssertions);
	delete gDB;
}
