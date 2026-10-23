// Run on an isolated SourceMod test server. Exercises production PB code with
// synthetic API responses; no players, timers, runs or HTTP writes are created.
#include <sourcemod>
#include <gokz/core>

#define AskPluginLoad2 Unused_AskPluginLoad2
#define OnPluginStart Unused_OnPluginStart
#define OnAllPluginsLoaded Unused_OnAllPluginsLoaded
#define OnPluginEnd Unused_OnPluginEnd
#define OnMapStart Unused_OnMapStart
#define OnMapEnd Unused_OnMapEnd
#define OnClientConnected Unused_OnClientConnected
#define OnClientPostAdminCheck Unused_OnClientPostAdminCheck
#define OnClientPutInServer Unused_OnClientPutInServer
#define OnClientDisconnect Unused_OnClientDisconnect
#define GOKZ_OnFirstSpawn Unused_OnFirstSpawn
#define GOKZ_OnOptionChanged Unused_OnOptionChanged
#define GOKZ_OnTimerEnd_Post Unused_OnTimerEnd_Post
#define GOKZTop_OnRecordAccepted Unused_OnRecordAccepted
#define GOKZ_PrintToChat CaptureChat
#define GetSteamAccountID TestAccountID
#define GetClientLanguage TestLanguage
#include "gokz-top-core.sp"
#undef OnPluginStart

char gChat[1024];
int gAssertions;

int TestAccountID(int client, bool validate = true)
{
	if (!validate) return client;
	return client;
}
int TestLanguage(int client)
{
	return client >= 0 ? GetLanguageByCode("en") : 0;
}
void CaptureChat(int client, bool prefix, const char[] format, any ...)
{
	if (client < 0 || prefix) SetFailState("Unexpected test chat target");
	VFormat(gChat, sizeof(gChat), format, 4);
}

void Check(bool condition, const char[] message)
{
	if (!condition) SetFailState("PB regression: %s; chat=%s", message, gChat);
	gAssertions++;
}

void CheckCache(int client, const char[] map, float expectedTime, int expectedPoints, const char[] expectedDate)
{
	float time;
	int points;
	char date[16];
	Check(GetStoredPB(client, Mode_KZTimer, GOKZ_TOP_RECORD_TYPE_PRO, map, time, points, date, sizeof(date)), "PB cached");
	Check(FloatAbs(time - expectedTime) < 0.0001, "cache holds the API PB time");
	Check(points == expectedPoints, "cache holds matching API points");
	Check(StrEqual(date, expectedDate), "cache holds matching API date");
}

public void OnPluginStart()
{
	gCV_APIBaseURL = FindConVar("gokz_top_api_base_url");
	gSM_PBTime = new StringMap();
	gSM_PBPoints = new StringMap();
	gSM_PBDate = new StringMap();
	gSM_PBRevision = new StringMap();
	CheckRecordsEnvironment();
	char map[256];
	GetCurrentDisplayMap(map, sizeof(map));
	StorePB(1, Mode_KZTimer, 1, map, 11.13, 857, "2025-08-08");
	TrackFinishedPB(1, Mode_KZTimer, 1, 16.91);
	HandlePBDiffResponse(1, Mode_KZTimer, 1, map, 16.91, 11.13, 857, true,
		"[{\"time\":11.130,\"points\":857,\"created_on\":\"2025-08-08T00:00:00Z\"}]");
	Check(StrContains(gChat, "{red}+05.78") != -1, "slower screenshot run has a positive red gap");
	CheckCache(1, map, 11.13, 857, "2025-08-08");
	Check(!gPBFinish[1][5].active, "non-PB completes once");

	TrackFinishedPB(1, Mode_KZTimer, 1, 10.0);
	gChat[0] = '\0';
	HandlePBDiffResponse(1, Mode_KZTimer, 1, map, 10.0, 11.13, 857, true,
		"[{\"time\":11.130,\"points\":857,\"created_on\":\"2025-08-08T00:00:00Z\"}]");
	Check(gChat[0] == '\0', "stale response is not announced as a new PB");
	Check(gPBFinish[1][5].active, "pending upload keeps its refresh");
	CheckCache(1, map, 11.13, 857, "2025-08-08");
	gPBFinish[1][5].attempts = 12;
	gPBFinish[1][5].nextAttempt = GetEngineTime() + 900.0;
	Check(!WakePendingPBFinish(1, Mode_KZTimer, 1, 12.0), "unrelated acceptance cannot wake this run");
	Check(WakePendingPBFinish(1, Mode_KZTimer, 1, 10.0), "late upload acknowledgement wakes the finished run");
	Check(gPBFinish[1][5].attempts == 0 && gPBFinish[1][5].nextAttempt == 0.0, "late acknowledgement resets exhausted refresh attempts");
	int staleRevision = GetPBRevision(1, Mode_KZTimer, 1, map);
	HandlePBDiffResponse(1, Mode_KZTimer, 1, map, 10.0, 11.13, 857, true,
		"[{\"time\":10.000,\"points\":900,\"created_on\":\"2026-10-24T00:00:00Z\"}]");
	Check(StrContains(gChat, "{green}-01.13") != -1, "new PB shows its improvement");
	Check(StrContains(gChat, "{yellow}900") != -1 && StrContains(gChat, "{green}+43") != -1, "new PB shows fresh points and gain");
	CheckCache(1, map, 10.0, 900, "2026-10-24");
	Check(!StorePB(1, Mode_KZTimer, 1, map, 11.13, 857, "2025-08-08", staleRevision), "out-of-order response is rejected");
	CheckCache(1, map, 10.0, 900, "2026-10-24");

	TrackFinishedPB(2, Mode_KZTimer, 1, 8.0);
	gChat[0] = '\0';
	HandlePBDiffResponse(2, Mode_KZTimer, 1, map, 8.0, 0.0, 0, false, "[]");
	Check(gChat[0] == '\0' && gPBFinish[2][5].active, "first PB waits for real metadata");
	HandlePBDiffResponse(2, Mode_KZTimer, 1, map, 8.0, 0.0, 0, false,
		"[{\"time\":8.000,\"points\":1000,\"created_on\":\"2026-10-24T00:00:00Z\"}]");
	CheckCache(2, map, 8.0, 1000, "2026-10-24");
	Check(StrContains(gChat, "{green}+") == -1, "first PB does not invent a point gain");

	TrackFinishedPB(2, Mode_KZTimer, 1, 8.0);
	HandlePBDiffResponse(2, Mode_KZTimer, 1, map, 8.0, 8.0, 1000, true,
		"[{\"time\":8.000,\"points\":1000,\"created_on\":\"2026-10-24T00:00:00Z\"}]");
	Check(StrContains(gChat, "+00.00") != -1 && StrContains(gChat, "{green}+") == -1, "tie has no improvement or point gain");

	TrackFinishedPB(1, Mode_KZTimer, 1, 9.0);
	int serial = gPBFinish[1][5].serial;
	TrackFinishedPB(1, Mode_KZTimer, 1, 8.5);
	Check(!IsCurrentPBFinish(1, Mode_KZTimer, 1, serial), "superseded response cannot finish a newer run");
	ClearPendingPBFinishes(1);
	Check(!IsCurrentPBFinish(1, Mode_KZTimer, 1, gPBFinish[1][5].serial), "disconnect/map clear invalidates requests");
	char scope[8];
	GetRecordsScopeForMode(3, scope, sizeof(scope));
	Check(StrEqual(scope, "KZT"), "NKZ uses KZT scope, not OVR numeric ID 3");
	TrackFinishedPB(1, Mode_KZTimer, 1, 9.999);
	gChat[0] = '\0';
	HandlePBDiffResponse(1, Mode_KZTimer, 1, map, 9.999, 10.0, 900, true,
		"[{\"time\":10.000,\"points\":900,\"created_on\":\"2026-10-24T00:00:00Z\"}]");
	Check(gChat[0] == '\0' && gPBFinish[1][5].active, "one-millisecond PB must not reuse old metadata");
	// A later authoritative fallback (for example after moderation) is allowed;
	// only responses older than a cache write are rejected.
	int currentRevision = GetPBRevision(1, Mode_KZTimer, 1, map);
	Check(StorePB(1, Mode_KZTimer, 1, map, 12.0, 800, "2026-10-24", currentRevision), "fresh API fallback can replace an invalidated PB");
	for (int mode = 0; mode < 4; mode++)
	{
		for (int type = 0; type < 2; type++)
		{
			StorePB(3, mode, type, map, 20.0, 500, "2025-08-08");
			TrackFinishedPB(3, mode, type, 21.0);
			HandlePBDiffResponse(3, mode, type, map, 21.0, 20.0, 500, true,
				"[{\"time\":20.0,\"points\":500,\"created_on\":\"2025-08-08T00:00:00Z\"}]");
			Check(StrContains(gChat, gC_RecordModeNames[mode]) != -1, "all four run modes retain their chat labels");
			Check(StrContains(gChat, "{red}+01.00") != -1, "NUB and PRO use the same positive-gap rule");
		}
	}
	// Simulate detecting a changed API without modifying the real server convar.
	strcopy(gC_RecordsEnvironment, sizeof(gC_RecordsEnvironment), "https://old-environment.invalid");
	CheckRecordsEnvironment();
	Check(!gPBFinish[1][5].active && gSM_PBTime.Size == 0, "environment switch clears pending comparisons and cached PBs");
	PrintToServer("[pb-announcements-test] PASS assertions=%d", gAssertions);
}
