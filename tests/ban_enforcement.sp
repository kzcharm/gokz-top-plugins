// csgotest only: production parser and ban handler with synthetic clients.
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
#define GOKZ_OnFirstSpawn Unused_GOKZ_OnFirstSpawn
#define GOKZ_OnOptionChanged Unused_GOKZ_OnOptionChanged
#define GOKZ_OnTimerEnd_Post Unused_GOKZ_OnTimerEnd_Post
#define GOKZTop_OnRecordAccepted Unused_GOKZTop_OnRecordAccepted
#define IsClientInGame TestClientInGame
#define KickClient CaptureKick
#include "gokz-top-core.sp"
#undef OnPluginStart

int gAssertions;
int gKicks;
bool gInGame = true;
char gKickMessage[512];

bool TestClientInGame(int client)
{
	return client == 1 && gInGame;
}

void CaptureKick(int client, const char[] format, any ...)
{
	Check(client == 1, "only the matching synthetic client is kicked");
	VFormat(gKickMessage, sizeof(gKickMessage), format, 3);
	gKicks++;
}

void Check(bool condition, const char[] message)
{
	if (!condition) SetFailState("Ban enforcement regression: %s", message);
	gAssertions++;
}

void ResetSession()
{
	gB_SessionActive[1] = true;
	strcopy(gC_SessionID[1], sizeof(gC_SessionID[]), "01a1e287-091c-76ed-8901-fb2d70956e39");
}

public void OnPluginStart()
{
	char uuid[37];
	Check(ExtractJsonString("{\"id\":\"01a1e287-091c-76ed-8901-fb2d70956e39\"}", "id", uuid, sizeof(uuid)), "36-character UUID fits a 37-byte buffer");
	Check(StrEqual(uuid, "01a1e287-091c-76ed-8901-fb2d70956e39"), "UUID is preserved");
	char small[4];
	Check(ExtractJsonString("{\"v\":\"ab\"}", "v", small, sizeof(small)), "short string accepted");
	Check(ExtractJsonString("{\"v\":\"abc\"}", "v", small, sizeof(small)), "exact-fit string accepted");
	Check(StrEqual(small, "abc"), "exact-fit string is terminated");
	Check(!ExtractJsonString("{\"v\":\"abcd\"}", "v", small, sizeof(small)), "oversized string rejected");
	Check(StrEqual(small, "abc"), "oversized output remains terminated");
	Check(!ExtractJsonString("{\"v\":\"abc", "v", small, sizeof(small)), "missing closing quote rejected");
	Check(!ExtractJsonString("{\"v\":null}", "v", small, sizeof(small)), "non-string rejected");
	Check(!ExtractJsonString("{}", "v", small, sizeof(small)), "missing key rejected");
	Check(ExtractJsonString("{\"v\":\"a\\\"b\"}", "v", small, sizeof(small)), "escaped exact-fit string accepted");
	Check(StrEqual(small, "a\"b"), "escaped quote preserved");
	char empty[1];
	Check(ExtractJsonString("{\"v\":\"\"}", "v", empty, sizeof(empty)), "empty string fits one byte");
	Check(!ExtractJsonString("{\"v\":\"a\"}", "v", empty, sizeof(empty)), "one-byte buffer rejects nonempty string");

	char response[] = "{\"id\":\"01a1e287-091c-76ed-8901-fb2d70956e39\",\"ban_enforcement\":{\"required\":true,\"ban\":{\"ban_type\":\"ban_evasion\"},\"kick_message\":\"Permanent ban\"}}";
	ResetSession();
	HandleConnectResponse(response);
	Check(gKicks == 1, "active ban reaches the kick");
	Check(StrEqual(gKickMessage, "Permanent ban"), "API kick message preserved");
	Check(!gB_SessionActive[1], "kicked session cleared");
	HandleConnectResponse(response);
	Check(gKicks == 1, "stale response cannot kick twice");
	ResetSession();
	HandleConnectResponse("{\"id\":\"01a1e287-091c-76ed-8901-fb2d70956e39\",\"ban_enforcement\":null}");
	Check(gKicks == 1 && gB_SessionActive[1], "unbanned player is retained");
	HandleConnectResponse("{\"id\":\"01a1e287-091c-76ed-8901-fb2d70956e39\",\"required\":false}");
	Check(gKicks == 1, "explicit no-kick response respected");
	gInGame = false;
	HandleConnectResponse(response);
	Check(gKicks == 1, "disconnected client is not kicked");
	ClearSession(1);
	PrintToServer("[ban-enforcement-test] PASS assertions=%d", gAssertions);
}
