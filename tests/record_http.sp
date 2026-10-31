// Dedicated test server only. Own SQLite/spool; synthetic requests never leave the server.
#include <sourcemod>
#include <SteamWorks>
#include <gokz/top>

#define AskPluginLoad2 RecordsUnusedAsk
#define OnPluginStart RecordsUnusedStart
#define OnMapStart RecordsUnusedMap
#define GOKZTop_GetHTTPConfig TestHTTPConfig
#define GOKZTop_GetServerSteamID TestServerIdentity
// Keep included production forwards private to this probe; real events must
// never enter synthetic fixtures, even while another test is running.
#define GOKZ_Relay_OnCaptureEvidence ProbeRecordHTTP_GOKZ_Relay_OnCaptureEvidence
#define GOKZ_Relay_OnResume ProbeRecordHTTP_GOKZ_Relay_OnResume
#define GOKZ_Relay_OnResumeCheck ProbeRecordHTTP_GOKZ_Relay_OnResumeCheck
#define GOKZ_Relay_OnCompleted ProbeRecordHTTP_GOKZ_Relay_OnCompleted
#define GOKZ_Relay_OnReplaySaved ProbeRecordHTTP_GOKZ_Relay_OnReplaySaved
#define GOKZ_OnTimerStart_Post ProbeRecordHTTP_GOKZ_OnTimerStart_Post
#define GOKZ_OnTimerEnd_Post ProbeRecordHTTP_GOKZ_OnTimerEnd_Post
#define GOKZ_OnTimerStopped ProbeRecordHTTP_GOKZ_OnTimerStopped
#define GOKZ_AC_OnPlayerSuspected ProbeRecordHTTP_GOKZ_AC_OnPlayerSuspected
#define GOKZ_OnOptionChanged ProbeRecordHTTP_GOKZ_OnOptionChanged
#define GOKZ_OnModeUnloaded ProbeRecordHTTP_GOKZ_OnModeUnloaded
#define GOKZ_RP_OnReplaySaved ProbeRecordHTTP_GOKZ_RP_OnReplaySaved
#define GlobalAPI_OnRequestStarted ProbeRecordHTTP_GlobalAPI_OnRequestStarted
#define GlobalAPI_OnRequestFinished ProbeRecordHTTP_GlobalAPI_OnRequestFinished
#define OnClientPutInServer ProbeRecordHTTP_OnClientPutInServer
#define OnClientDisconnect ProbeRecordHTTP_OnClientDisconnect
#define OnLibraryRemoved ProbeRecordHTTP_OnLibraryRemoved
#include "../addons/sourcemod/scripting/gokz-top-records.sp"
#undef OnPluginStart

// Real SteamWorks requests, dedicated localhost fixture only. No game runs/API writes.
char sID[] = "01900000-0000-7000-8000-000000000099";
char sPath[PLATFORM_MAX_PATH];
int sPhase, sAssertions;
float sStarted;
void TestHTTPConfig(char[] url, int urlLength, char[] key, int keyLength)
{
 strcopy(url, urlLength, "http://127.0.0.1:18092"); strcopy(key, keyLength, "fixture-only");
}
void TestServerIdentity(char[] server, int capacity) { strcopy(server, capacity, "85568392936085241"); }
void Check(bool condition, const char[] label)
{
 if (!condition) SetFailState("record-http-test: %s", label);
 sAssertions++;
}
public void OnPluginStart()
{
 char error[256];
 gDB = SQLite_UseDatabase("gokz-top-record-http-tests", error, sizeof(error));
 Check(gDB != null, "private SQLite");
 Queue_SQL("DROP TABLE IF EXISTS jobs"); Queue_CreateTables();
 Eligibility_Init();
 gCV_Server = CreateConVar("gokz_top_records_http_test_server", "");
 gCV_ReplayTimeout = CreateConVar("gokz_top_records_http_test_timeout", "900");
 BuildPath(Path_SM, sPath, sizeof(sPath), "data/record-http-fixture.replay");
 File file = OpenFile(sPath, "wb"); for (int i = 0; i < 1024; i++) file.WriteInt8(42); delete file;
 char query[2048];
 Format(query, sizeof(query), "INSERT INTO jobs(id,environment,server,payload,state,canonical,replay,eligible) VALUES('%s','http://127.0.0.1:18092','85568392936085241','{}','replay','%s','%s',1)", sID, sID, sPath);
 Check(Queue_SQL(query), "fixture job");
 // Reproduce the previous hard-coded60second absolute deadline before retesting900.
 gCV_ReplayTimeout.IntValue = 60; sStarted = GetEngineTime(); HTTP_Next();
 CreateTimer(0.5, CheckHTTP, _, TIMER_REPEAT);
 PrintToServer("[record-http-test] started deadline=60 response_delay=65");
}
public Action CheckHTTP(Handle timer)
{
 if (gBusy) return Plugin_Continue;
 DBResultSet row = SQL_Query(gDB, "SELECT state,attempts,replay_done,next FROM jobs");
 Check(row != null && row.FetchRow(), "durable job retained");
 char state[32]; row.FetchString(0, state, sizeof(state));
 if (sPhase == 0)
 {
  Check(StrEqual(state, "replay") && row.FetchInt(1) == 1 && row.FetchInt(2) == 0, "60second transfer is queued for retry");
  Check(GetEngineTime() - sStarted >= 59.0 && FileExists(sPath), "deadline reproduced and spool retained");
  delete row;
  PrintToServer("[record-http-test] reproduced deadline=60; retrying deadline=900");
  gCV_ReplayTimeout.IntValue = 900;
  Queue_SQL("UPDATE jobs SET next=0,attempts=0"); sPhase = 1; sStarted = GetEngineTime(); HTTP_Next();
  return Plugin_Continue;
 }
 Check(StrEqual(state, "done") && row.FetchInt(2) == 1, "65second upload acknowledged and persisted");
 Check(GetEngineTime() - sStarted >= 64.0 && FileExists(sPath), "transfer exceeded old deadline");
 delete row;
 PrintToServer("[record-http-test] PASS assertions=%d elapsed=%.1f", sAssertions, GetEngineTime() - sStarted);
 DeleteFile(sPath); delete gDB;
 return Plugin_Stop;
}
