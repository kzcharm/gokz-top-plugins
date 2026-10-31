// Dedicated test server only. Own SQLite/spool; synthetic requests never leave the server.
#include <sourcemod>
#include <SteamWorks>
#include <gokz/top>

#define AskPluginLoad2 RecordsUnusedAsk
#define OnPluginStart RecordsUnusedStart
#define OnMapStart RecordsUnusedMap
// Keep included production forwards private to this probe; real events must
// never enter synthetic fixtures, even while another test is running.
#define GOKZ_Relay_OnCaptureEvidence ProbeRecordRetries_GOKZ_Relay_OnCaptureEvidence
#define GOKZ_Relay_OnResume ProbeRecordRetries_GOKZ_Relay_OnResume
#define GOKZ_Relay_OnResumeCheck ProbeRecordRetries_GOKZ_Relay_OnResumeCheck
#define GOKZ_Relay_OnCompleted ProbeRecordRetries_GOKZ_Relay_OnCompleted
#define GOKZ_Relay_OnReplaySaved ProbeRecordRetries_GOKZ_Relay_OnReplaySaved
#define GOKZ_OnTimerStart_Post ProbeRecordRetries_GOKZ_OnTimerStart_Post
#define GOKZ_OnTimerEnd_Post ProbeRecordRetries_GOKZ_OnTimerEnd_Post
#define GOKZ_OnTimerStopped ProbeRecordRetries_GOKZ_OnTimerStopped
#define GOKZ_AC_OnPlayerSuspected ProbeRecordRetries_GOKZ_AC_OnPlayerSuspected
#define GOKZ_OnOptionChanged ProbeRecordRetries_GOKZ_OnOptionChanged
#define GOKZ_OnModeUnloaded ProbeRecordRetries_GOKZ_OnModeUnloaded
#define GOKZ_RP_OnReplaySaved ProbeRecordRetries_GOKZ_RP_OnReplaySaved
#define GlobalAPI_OnRequestStarted ProbeRecordRetries_GlobalAPI_OnRequestStarted
#define GlobalAPI_OnRequestFinished ProbeRecordRetries_GlobalAPI_OnRequestFinished
#define OnClientPutInServer ProbeRecordRetries_OnClientPutInServer
#define OnClientDisconnect ProbeRecordRetries_OnClientDisconnect
#define OnLibraryRemoved ProbeRecordRetries_OnLibraryRemoved
#define SteamWorks_GetHTTPResponseBodySize TestBodySize
#define SteamWorks_GetHTTPResponseHeaderValue TestHeader
#include "../addons/sourcemod/scripting/gokz-top-records.sp"
#undef OnPluginStart

int sAssertions;
char sID[] = "01900000-0000-7000-8000-000000000098";
bool TestBodySize(Handle request, int &size) { size = 0; return request != null && false; }
bool TestHeader(Handle request, const char[] header, char[] value, int capacity)
{
 if (request == null || !StrEqual(header, "Retry-After")) return false;
 strcopy(value, capacity, "120"); return true;
}
void Check(bool condition, const char[] label) { if (!condition) SetFailState("record-retries-test: %s", label); sAssertions++; }
void Response(const char[] state, int status, const char[] expected)
{
 char sql[512];
 Format(sql, sizeof(sql), "UPDATE jobs SET state='%s',attempts=0,next=0,error=''", state); Queue_SQL(sql);
 DataPack context = new DataPack(); context.WriteString(sID); context.WriteString(state); context.WriteCell(0);
 Handle request = new DataPack(); int before = GetTime();
 OnRecordHTTPComplete(request, status == 0, status != 0, view_as<EHTTPStatusCode>(status), context);
 DBResultSet row = SQL_Query(gDB, "SELECT state,attempts,next,canonical,replay FROM jobs");
 Check(row != null && row.FetchRow(), "job retained");
 char actual[64]; row.FetchString(0, actual, sizeof(actual)); Check(StrEqual(actual, expected), "correct retry state");
 bool retry = StrEqual(state, expected);
 Check(row.FetchInt(1) == (retry ? 1 : 0), "attempt accounting");
 Check(!retry || row.FetchInt(2) >= before + 120, "Retry-After respected");
 row.FetchString(3, actual, sizeof(actual)); Check(StrEqual(actual, sID), "canonical UUID preserved");
 row.FetchString(4, actual, sizeof(actual)); Check(StrEqual(actual, "private.replay"), "spool reference preserved");
 delete row;
}
public void OnPluginStart()
{
 char error[256], sql[512]; gDB = SQLite_UseDatabase("gokz-top-record-retry-tests", error, sizeof(error));
 Check(gDB != null, "private SQLite"); Queue_SQL("DROP TABLE IF EXISTS jobs"); Queue_CreateTables();
 Format(sql, sizeof(sql), "INSERT INTO jobs(id,environment,server,payload,canonical,replay) VALUES('%s','https://fixture.invalid','test','{}','%s','private.replay')", sID, sID); Queue_SQL(sql);
 Response("record",404,"record"); Response("replay",404,"replay"); Response("reconcile",404,"reconcile");
 Response("record",408,"record"); Response("replay",429,"replay"); Response("replay",503,"replay"); Response("replay",0,"replay");
 Response("record",401,"auth"); Response("record",403,"auth"); Response("replay",409,"rejected"); Response("record",422,"rejected");
 PrintToServer("[record-retries-test] PASS assertions=%d",sAssertions); delete gDB;
}
