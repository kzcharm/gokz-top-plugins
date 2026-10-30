// Dedicated test server only; private SQLite and synthetic GlobalAPI responses.
#include <sourcemod>
#include <SteamWorks>
#define AskPluginLoad2 RecordsPrecisionUnusedAsk
#define OnPluginStart RecordsPrecisionUnusedStart
#define OnMapStart RecordsPrecisionUnusedMap
#define SteamWorks_GetHTTPResponseBodySize PrecisionBodySize
#define SteamWorks_GetHTTPResponseBodyData PrecisionBodyData
#include "../addons/sourcemod/scripting/gokz-top-records.sp"
#undef OnPluginStart

char sResponse[128];
int sAssertions;

bool PrecisionBodySize(Handle request, int &size)
{
	if (request == null) return false;
	size = strlen(sResponse);
	return true;
}

bool PrecisionBodyData(Handle request, char[] body, int capacity)
{
	if (request == null) return false;
	strcopy(body, capacity + 1, sResponse);
	return true;
}

void Check(bool condition, const char[] label)
{
	if (!condition) SetFailState("record-precision-test: %s", label);
	sAssertions++;
}

void Precision(float time, const char[] expected)
{
	char value[32];
	Capture_FormatGlobalTime(time, value, sizeof(value));
	Check(StrEqual(value, expected), expected);
	// Verify the exact same float serialization used by GlobalAPI's JSON body.
	JSON_Object body = new JSON_Object();
	body.SetFloat("time", time);
	char encoded[128], serialized[32];
	json_encode(body, encoded, sizeof(encoded));
	FloatToString(time, serialized, sizeof(serialized));
	PrintToServer("[record-precision-test] value=%s encoded=%s float=%s", value, encoded, serialized);
	Check(StrContains(encoded, value) >= 0, "GlobalAPI JSON milliseconds agree");
	body.Cleanup(); delete body;
}

public void OnPluginStart()
{
	Precision(268.601989, "268.601");
	Precision(35.288997, "35.288");
	Precision(10.000999, "10.000");
	Precision(0.008, "0.008");
	Precision(1234.56789, "1234.567");
	char error[256];
	gDB = SQLite_UseDatabase("gokz-top-record-precision-tests", error, sizeof(error));
	Check(gDB != null, "private SQLite");
	Queue_SQL("DROP TABLE IF EXISTS jobs");
	Queue_CreateTables();
	Queue_SQL("INSERT INTO jobs(id,environment,server,payload,steam2,canonical,state) VALUES('01900000-0000-7000-8000-000000000001','','','{\"mode\":\"KZT\",\"stage\":0,\"teleports\":0,\"time\":\"35.288\"}','STEAM_1:0:123','01900000-0000-7000-8000-000000000001','done')");
	GlobalAPIRequestData data = new GlobalAPIRequestData();
	data.RequestType = GlobalAPIRequestType_POST;
	data.Status = 200;
	data.Failure = false;
	data.SetString("steam_id", "STEAM_1:0:123");
	data.SetString("mode", "kz_timer");
	data.SetInt("stage", 0); data.SetInt("teleports", 0);
	data.SetFloat("time", 35.288997);
	strcopy(sResponse, sizeof(sResponse), "{\"record_id\":123456}");
	GlobalAPI_OnRequestFinished(view_as<Handle>(123), data);
	DBResultSet rows = SQL_Query(gDB, "SELECT upstream,state FROM jobs");
	Check(rows != null && rows.FetchRow(), "durable job exists");
	Check(rows.FetchInt(0) == 123456, "record_id captured");
	char state[32]; rows.FetchString(1, state, sizeof(state));
	Check(StrEqual(state, "reconcile"), "completed job wakes for identity reconciliation");
	delete rows;
	// Relay jobs must never attach an unrelated upstream record with equal stats.
	Queue_SQL("UPDATE jobs SET upstream=0,state='done',relay=1");
	GlobalAPI_OnRequestFinished(view_as<Handle>(124), data);
	rows = SQL_Query(gDB, "SELECT upstream,state FROM jobs");
	Check(rows != null && rows.FetchRow(), "relay job retained");
	Check(rows.FetchInt(0) == 0, "relay excluded from heuristic upstream matching");
	rows.FetchString(1, state, sizeof(state));
	Check(StrEqual(state, "done"), "relay queue state untouched by upstream response");
	delete rows;
	data.Cleanup(); delete data;
	PrintToServer("[record-precision-test] PASS assertions=%d", sAssertions);
	delete gDB;
}
