// Dedicated server only. Synthetic clients/natives; no player or HTTP mutations.
#include <sourcemod>
#include <sdktools>
#include <SteamWorks>
#include <gokz/core>
#include <gokz/top>
#undef REQUIRE_PLUGIN
#include <gokz/relay>

#define AskPluginLoad2 LifecycleUnusedAsk
#define OnPluginStart LifecycleUnusedStart
#define OnMapStart LifecycleUnusedMap
#define LibraryExists TestLibrary
#define GetFeatureStatus TestFeature
#define IsClientInGame TestInGame
#define IsFakeClient TestFake
#define GetClientSerial TestSerial
#define GetClientFromSerial TestFromSerial
#define GetGameTickCount TestTick
#define GetTickInterval TestInterval
#define FindConVar TestConVar
#define QueryClientConVar TestQuery
#define GetCurrentMap TestMap
#define FileSize TestFileSize
#define GetClientAuthId TestAuth
#define GOKZTop_GetHTTPConfig TestConfig
#define GOKZTop_GetServerSteamID TestServer
#define GOKZ_GetCoreOption TestOption
#define GOKZ_GetModeVersion TestModeVersion
#define GOKZ_GetCourse TestCourse
#define GOKZ_GetValidTimer TestValidTimer
#define GOKZ_Relay_IsResumed TestResumed
#define GOKZ_Relay_IsRestoring TestRestoring
#define GOKZ_Relay_IsEligible TestEligible
#define GOKZ_Relay_GetRunID TestRunID
#define GOKZ_Relay_GetAPIVersion TestAPIVersion
#define SteamWorks_CreateHTTPRequest TestCreateRequest
// Keep included production forwards private to this probe; real events must
// never enter synthetic fixtures, even while another test is running.
#define GOKZ_Relay_OnCaptureEvidence ProbeRelayLifecycle_GOKZ_Relay_OnCaptureEvidence
#define GOKZ_Relay_OnResume ProbeRelayLifecycle_GOKZ_Relay_OnResume
#define GOKZ_Relay_OnResumeCheck ProbeRelayLifecycle_GOKZ_Relay_OnResumeCheck
#define GOKZ_Relay_OnCompleted ProbeRelayLifecycle_GOKZ_Relay_OnCompleted
#define GOKZ_Relay_OnReplaySaved ProbeRelayLifecycle_GOKZ_Relay_OnReplaySaved
#define GOKZ_OnTimerStart_Post ProbeRelayLifecycle_GOKZ_OnTimerStart_Post
#define GOKZ_OnTimerEnd_Post ProbeRelayLifecycle_GOKZ_OnTimerEnd_Post
#define GOKZ_OnTimerStopped ProbeRelayLifecycle_GOKZ_OnTimerStopped
#define GOKZ_AC_OnPlayerSuspected ProbeRelayLifecycle_GOKZ_AC_OnPlayerSuspected
#define GOKZ_OnOptionChanged ProbeRelayLifecycle_GOKZ_OnOptionChanged
#define GOKZ_OnModeUnloaded ProbeRelayLifecycle_GOKZ_OnModeUnloaded
#define GOKZ_RP_OnReplaySaved ProbeRelayLifecycle_GOKZ_RP_OnReplaySaved
#define GlobalAPI_OnRequestStarted ProbeRelayLifecycle_GlobalAPI_OnRequestStarted
#define GlobalAPI_OnRequestFinished ProbeRelayLifecycle_GlobalAPI_OnRequestFinished
#define OnClientPutInServer ProbeRelayLifecycle_OnClientPutInServer
#define OnClientDisconnect ProbeRelayLifecycle_OnClientDisconnect
#define OnLibraryRemoved ProbeRelayLifecycle_OnLibraryRemoved
#include "../addons/sourcemod/scripting/gokz-top-records.sp"
#undef OnPluginStart

int sAssertions, sSerial = 100, sTick = 20, sQueries, sAPIVersion = 2;
bool sVersionNative = true;
bool sInGame = true, sCoreValid = true, sResumed, sRestoring, sEligible = true, sQueryFails;
ConVar sTestCVars[10];
char sSettingNames[][] = {"sv_cheats", "sv_clamp_unsafe_velocities", "mp_drop_knife_enable", "sv_autobunnyhopping", "sv_minupdaterate", "sv_maxupdaterate", "sv_mincmdrate", "sv_maxcmdrate", "sv_client_cmdrate_difference", "sv_turbophysics"};
float sSettingValues[] = {0.0, 0.0, 0.0, 0.0, 128.0, 128.0, 128.0, 128.0, 0.0, 0.0};
char sID[] = "01900000-0000-7000-8000-000000000001";
char sCurrentID[37];

bool TestLibrary(const char[] name) { return name[0] != 0; }
FeatureStatus TestFeature(FeatureType type, const char[] name) { return type == FeatureType_Native && name[0] && !StrEqual(name, "GOKZ_DB_GetRunGUID") && (sVersionNative || !StrEqual(name, "GOKZ_Relay_GetAPIVersion")) ? FeatureStatus_Available : FeatureStatus_Unavailable; }
bool TestInGame(int client) { return client == 1 && sInGame; }
bool TestFake(int client) { return client != 1; }
int TestSerial(int client) { return client == 1 ? sSerial : 0; }
int TestFromSerial(int serial) { return serial == sSerial ? 1 : 0; }
int TestTick() { return sTick; }
float TestInterval() { return 1.0 / 128.0; }
ConVar TestConVar(const char[] name)
{
	for (int i = 0; i < sizeof(sSettingNames); i++) if (StrEqual(name, sSettingNames[i])) return sTestCVars[i];
	return null;
}
QueryCookie TestQuery(int client, const char[] name, ConVarQueryFinished callback, any value)
{
	if (client != 1 || !name[0] || callback == INVALID_FUNCTION || value != sSerial) SetFailState("Unexpected synthetic query");
	sQueries++;
	return sQueryFails ? QUERYCOOKIE_FAILED : view_as<QueryCookie>(sQueries);
}
void TestMap(char[] map, int capacity) { strcopy(map, capacity, "relay_test"); }
int TestFileSize(const char[] path, bool valveFS = false, const char[] valvePath = "GAME") { return path[0] && valveFS && valvePath[0] ? 12345 : 0; }
bool TestAuth(int client, AuthIdType type, char[] auth, int capacity, bool validate = true)
{
	if (client != 1 || !validate) return false;
	strcopy(auth, capacity, type == AuthId_SteamID64 ? "76561197960265974" : "STEAM_1:0:123");
	return true;
}
void TestConfig(char[] url, int urlCapacity, char[] key, int keyCapacity) { strcopy(url, urlCapacity, "https://relay-test.invalid"); strcopy(key, keyCapacity, "synthetic"); }
bool TestServer(char[] id, int capacity) { strcopy(id, capacity, "85568392936085241"); return true; }
int TestOption(int client, Option option) { return client == 1 && option == Option_Mode ? 2 : 0; }
int TestModeVersion(int mode) { return mode == 2 ? 2172 : 0; }
int TestCourse(int client) { return client == 1 ? 0 : -1; }
bool TestValidTimer(int client) { return client == 1 && sCoreValid; }
int TestAPIVersion() { return sAPIVersion; }
bool TestRestoring(int client) { return client == 1 && sRestoring; }
bool TestResumed(int client) { return client == 1 && sResumed; }
bool TestEligible(int client) { return client == 1 && sEligible; }
bool TestRunID(int client, char[] id, int capacity) { strcopy(id, capacity, sCurrentID); return client == 1; }
Handle TestCreateRequest(EHTTPMethod method, const char[] url)
{
	SetFailState("Unexpected lifecycle HTTP request method=%d URL=%s", method, url);
	return null;
}
int Jobs()
{
	DBResultSet rows = SQL_Query(gDB, "SELECT count(*) FROM jobs");
	if (rows == null || !rows.FetchRow()) SetFailState("Cannot read isolated lifecycle jobs");
	int count = rows.FetchInt(0); delete rows; return count;
}
void Check(bool condition, const char[] label) { if (!condition) SetFailState("relay-lifecycle-test: %s", label); sAssertions++; }
void Replies(ConVarQueryResult result, const char[] fps = "300", const char[] yaw = "0.022")
{
	OnFPSChecked(view_as<QueryCookie>(1), 1, result, "fps_max", fps, sSerial);
	OnYawChecked(view_as<QueryCookie>(2), 1, result, "m_yaw", yaw, sSerial);
}
void Fresh()
{
	Relay_ResetClient(1); OnClientPutInServer(1); Replies(ConVarQuery_Okay);
	gRun[1] = true; gValid[1] = true; gFreshMap = true; gMode[1] = 2; gVersion[1] = 2172;
	strcopy(sCurrentID, sizeof(sCurrentID), sID); strcopy(gGUID[1], sizeof(gGUID[]), sID);
	strcopy(gEnvironment[1], sizeof(gEnvironment[]), "https://relay-test.invalid");
	strcopy(gServer[1], sizeof(gServer[]), "85568392936085241");
	sResumed = false; sRestoring = false; sCoreValid = true; sEligible = true;
}
bool EvidenceValid(const char[] evidence)
{
	JSON_Object body = json_decode(evidence); if (body == null) return false;
	bool valid = Relay_Integrity(body); body.Cleanup(); delete body; return valid;
}
public void OnPluginStart()
{
	char error[256]; gDB = SQLite_UseDatabase("gokz-top-relay-lifecycle-tests", error, sizeof(error));
	Check(gDB != null, "private lifecycle database");
	Queue_SQL("DROP TABLE IF EXISTS jobs"); Queue_SQL("DROP TABLE IF EXISTS record_filters");
	Queue_CreateTables(); Eligibility_Init();
	int flags[256]; flags[0] = 3 << 4; Eligibility_Store("https://relay-test.invalid", "relay_test", flags);
	for (int i = 0; i < sizeof(sSettingNames); i++)
	{
		char name[64], value[32]; Format(name, sizeof(name), "relay_lifecycle_test_setting_%d", i);
		FloatToString(sSettingValues[i], value, sizeof(value)); sTestCVars[i] = CreateConVar(name, value);
	}
	OnClientPutInServer(1);
	Check(GOKZ_Relay_OnResumeCheck(1) == Plugin_Handled && sQueries == 2, "unresolved queries defer resume and start checks");
	Check(GOKZ_Relay_OnResumeCheck(1) == Plugin_Handled && sQueries == 2, "pending queries are not duplicated");
	Replies(ConVarQuery_Okay);
	Check(GOKZ_Relay_OnResumeCheck(1) == Plugin_Continue && ClientSettingsValid(1), "successful queries release readiness");
	QueryClientSettings(1);
	Check(GOKZ_Relay_OnResumeCheck(1) == Plugin_Handled, "in-flight refresh must complete before resume");
	Replies(ConVarQuery_Okay);
	Check(GOKZ_Relay_OnResumeCheck(1) == Plugin_Continue, "completed refresh releases readiness");
	OnClientPutInServer(1); Replies(ConVarQuery_Okay, "30", "1");
	Check(GOKZ_Relay_OnResumeCheck(1) == Plugin_Continue && !ClientSettingsValid(1), "invalid values resolve readiness without eligibility");
	OnClientPutInServer(1); Replies(ConVarQuery_NotFound);
	Check(GOKZ_Relay_OnResumeCheck(1) == Plugin_Handled && !ClientSettingsValid(1), "query failures retain unresolved readiness");
	OnClientPutInServer(1); sQueryFails = true;
	Check(GOKZ_Relay_OnResumeCheck(1) == Plugin_Handled && !ClientSettingsResolved(1), "dispatch failures cannot qualify resume"); sQueryFails = false;
	OnClientPutInServer(1);
	OnFPSChecked(view_as<QueryCookie>(1), 1, ConVarQuery_Okay, "fps_max", "300", sSerial - 1);
	OnYawChecked(view_as<QueryCookie>(2), 1, ConVarQuery_Okay, "m_yaw", "0.022", sSerial - 1);
	Check(!ClientSettingsResolved(1), "stale connection replies ignored");

	char before[GOKZ_RELAY_EVIDENCE_MAX], after[GOKZ_RELAY_EVIDENCE_MAX];
	Fresh(); GOKZ_Relay_OnCaptureEvidence(1, before, sizeof(before));
	Check(EvidenceValid(before), "producer-first stop save captures valid evidence");
	GOKZ_OnTimerStopped(1); GOKZ_Relay_OnCaptureEvidence(1, after, sizeof(after));
	Check(!gRun[1] && StrEqual(before, after), "consumer-first stop save retains identical evidence");
	gValid[1] = false; GOKZ_Relay_OnCaptureEvidence(1, after, sizeof(after));
	Check(after[0] && !EvidenceValid(after) && !gValid[1], "later same-forward integrity failure stays sticky");
	Fresh(); gValid[1] = false; GOKZ_OnTimerStopped(1); GOKZ_Relay_OnCaptureEvidence(1, after, sizeof(after));
	Check(after[0] && !EvidenceValid(after), "invalid run remains invalid through stop handoff");
	Fresh(); GOKZ_Relay_OnCaptureEvidence(1, before, sizeof(before));
	sResumed = true; sCoreValid = true; GOKZ_Relay_OnResume(1, sID, before, true);
	GOKZ_OnTimerStopped(1); GOKZ_Relay_OnCaptureEvidence(1, after, sizeof(after));
	Check(EvidenceValid(after), "owned core-valid resumed stop preserves evidence");
	sCurrentID[35] = '2'; GOKZ_Relay_OnCaptureEvidence(1, after, sizeof(after));
	Check(!after[0], "different logical run cannot consume final evidence");
	strcopy(sCurrentID, sizeof(sCurrentID), sID); sSerial++; GOKZ_Relay_OnCaptureEvidence(1, after, sizeof(after));
	Check(!after[0], "reused client slot cannot consume final evidence");
	Fresh(); GOKZ_OnTimerStopped(1); sTick++; GOKZ_Relay_OnCaptureEvidence(1, after, sizeof(after));
	Check(!after[0], "stopped evidence expires after synchronous stop tick");
	Fresh(); GOKZ_OnTimerStopped(1); Relay_ResetClient(1); GOKZ_Relay_OnCaptureEvidence(1, after, sizeof(after));
	Check(!after[0], "new run or disconnect clears final evidence");
	Fresh(); GOKZ_OnTimerStopped(1); GOKZ_OnTimerStart_Post(1, 0);
	gRun[1] = false; GOKZ_Relay_OnCaptureEvidence(1, after, sizeof(after));
	Check(!after[0], "actual fresh start clears final evidence");
	Fresh(); GOKZ_OnTimerStopped(1); OnClientDisconnect(1); GOKZ_Relay_OnCaptureEvidence(1, after, sizeof(after));
	Check(!after[0], "actual disconnect clears final evidence");
	Fresh(); GOKZ_Relay_OnCaptureEvidence(1, before, sizeof(before));
	gRun[1] = false; sResumed = true; sCoreValid = true;
	GOKZ_Relay_OnResume(1, sID, before, true);
	Check(gRun[1] && gValid[1] && Relay_OwnedSession(1), "resolved reconnect resume restores cumulative eligibility");
	Replies(ConVarQuery_Okay, "30", "1");
	GOKZ_Relay_OnResume(1, sID, before, true);
	Check(gRun[1] && !gValid[1], "known ineligible values cannot regain eligibility on resume");
	Replies(ConVarQuery_Okay);
	Check(ClientSettingsValid(1) && !gValid[1], "later good replies cannot requalify active run");
	GOKZ_Relay_OnResume(1, sID, "", true);
	GOKZ_Relay_OnCaptureEvidence(1, after, sizeof(after));
	Check(!gRun[1] && !gValid[1] && !after[0], "empty evidence never gains eligibility or frozen fallback");
	// Restoration starts cannot replace an archived failure with fresh validity.
	Fresh(); gValid[1] = false; GOKZ_Relay_OnCaptureEvidence(1, before, sizeof(before));
	sRestoring = true; GOKZ_OnTimerStart_Post(1, 0);
	Check(!gRun[1] && !gValid[1] && StrEqual(gGUID[1], sID), "internal start preserves identity and never initializes fresh capture");
	GOKZ_Relay_OnCaptureEvidence(1, after, sizeof(after));
	Check(!after[0], "internal restoring window cannot mint validation evidence");
	GOKZ_OnTimerEnd_Post(1, 0, 12.0, 0);
	Check(Jobs() == 0, "internal restoring window cannot queue an ordinary finish");
	sRestoring = false; sResumed = true; GOKZ_Relay_OnResume(1, sID, before, true);
	Check(gRun[1] && !gValid[1], "archived failed evidence survives real restoration start");
	Fresh(); GOKZ_Relay_OnCaptureEvidence(1, before, sizeof(before));
	sRestoring = true; GOKZ_OnTimerStart_Post(1, 0); sRestoring = false; sResumed = true;
	GOKZ_Relay_OnResume(1, sID, before, true);
	GOKZ_OnTimerEnd_Post(1, 0, 12.0, 0);
	GOKZ_Relay_OnCaptureEvidence(1, after, sizeof(after));
	Check(Jobs() == 0 && gRun[1] && EvidenceValid(after), "ordinary post-end before producer preserves evidence and queues nothing");
	strcopy(before, sizeof(before), after);
	GOKZ_OnTimerEnd_Post(1, 0, 12.0, 0);
	GOKZ_Relay_OnCaptureEvidence(1, after, sizeof(after));
	Check(Jobs() == 0 && StrEqual(before, after), "ordinary post-end after producer cannot duplicate or erase evidence");
	sCoreValid = false; GOKZ_Relay_OnCaptureEvidence(1, after, sizeof(after));
	Check(!gValid[1] && !EvidenceValid(after), "genuine core invalidation poisons owned resumed run");
	GOKZ_OnTimerStopped(1); GOKZ_Relay_OnCaptureEvidence(1, after, sizeof(after));
	Check(after[0] && !EvidenceValid(after), "core invalidation remains failed in stop handoff");
	Fresh(); GOKZ_Relay_OnCaptureEvidence(1, before, sizeof(before)); sResumed = true; sCoreValid = false;
	GOKZ_Relay_OnResume(1, sID, before, true);
	Check(gRun[1] && !gValid[1], "old core-invalid producer cannot qualify a restored session");
	Fresh(); sResumed = true; GOKZ_Relay_OnResume(1, sID, "", true);
	gRun[1] = true; GOKZ_OnTimerEnd_Post(1, 0, 12.0, 0);
	Check(Jobs() == 0, "producer-owned session with no evidence never falls through ordinary upload");
	Fresh(); GOKZ_Relay_OnCaptureEvidence(1, before, sizeof(before)); sResumed = true;
	GOKZ_Relay_OnResume(1, sID, before, true); sCurrentID[35] = '2';
	GOKZ_OnTimerEnd_Post(1, 0, 12.0, 0);
	Check(Jobs() == 0, "mismatched relay identity cannot fall through ordinary upload");
	// Archive schema v1 can migrate only through a fresh core-valid v2 resume.
	Fresh(); GOKZ_Relay_OnCaptureEvidence(1, before, sizeof(before));
	JSON_Object legacy = json_decode(before); legacy.SetInt("evidence_version", 1);
	json_encode(legacy, before, sizeof(before)); legacy.Cleanup(); delete legacy;
	sResumed = true; GOKZ_Relay_OnResume(1, sID, before, true);
	GOKZ_Relay_OnCaptureEvidence(1, after, sizeof(after));
	legacy = json_decode(after);
	Check(gValid[1] && legacy.GetInt("evidence_version") == 2, "valid legacy archive upgrades through core-valid v2 restore");
	legacy.Cleanup(); delete legacy;
	sVersionNative = false; GOKZ_Relay_OnResume(1, sID, before, true);
	GOKZ_Relay_OnCaptureEvidence(1, after, sizeof(after));
	Check(!gValid[1] && !after[0], "missing runtime version native fails closed for live capture");
	sVersionNative = true; sAPIVersion = 1; GOKZ_Relay_OnResume(1, sID, before, true);
	GOKZ_Relay_OnCaptureEvidence(1, after, sizeof(after));
	Check(!gValid[1] && !after[0], "legacy runtime version cannot qualify live resume"); sAPIVersion = 2;
	Fresh(); GOKZ_OnTimerStart_Post(1, 0); GOKZ_OnTimerEnd_Post(1, 0, 12.0, 0);
	Check(Jobs() == 1 && !gRun[1], "genuine fresh start and normal finish still queue once");
	PrintToServer("[relay-lifecycle-test] PASS assertions=%d", sAssertions);
	delete gDB;
}
