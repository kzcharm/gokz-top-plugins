#include <sourcemod>
#include <sdktools>
#include <SteamWorks>
#include <json>

#include <gokz/core>

#define REQUIRE_PLUGIN
#include <gokz/top>
#undef REQUIRE_PLUGIN

#include <gokz/jumpstats>
#include <gokz/replays>
#include <gokz/top-replay-filesystem>

#pragma newdecls required
#pragma semicolon 1

#define GOKZ_TOP_REPLAYS_VERSION "0.2.2"
#define GOKZ_TOP_REPLAYS_USER_AGENT "gokz-top-replays/" ... GOKZ_TOP_REPLAYS_VERSION
#define GOKZ_TOP_REPLAYS_MAX_URL_LENGTH 512
#define GOKZ_TOP_REPLAYS_MAX_PATH_LENGTH 512
#define GOKZ_TOP_REPLAYS_MAX_RESPONSE_LENGTH 1024
#define GOKZ_TOP_REPLAYS_SAVE_DELAY 2.3
#define GOKZ_TOP_REPLAY_MAGIC 0x676F6B7A
#define GOKZ_TOP_REPLAY_FORMAT_VERSION 2

enum struct JumpReplayUploadHeader
{
	char steamID64[32];
	char mode[8];
	char jumpType[8];
	char distanceText[32];
	int timestamp;
	float distance;
}

public Plugin myinfo =
{
	name = "GOKZ Top Replays",
	author = "Cinyan10",
	description = "Eligible jump replay uploads for gokz-top",
	version = GOKZ_TOP_REPLAYS_VERSION,
	url = "https://gokz.top"
};

Database gDB;
ConVar gCV_RequestTimeout;
char gSpool[PLATFORM_MAX_PATH], gEnvironment[512], gKey[256], gActiveEnvironment[512];
int gActiveID, gAttempts, gFloor, gPassStart, gNextScan;
bool gBusy, gOwnWorker, gHibernating;
Handle gActiveRequest;
float gMaxScanSeconds;
ArrayList gDirectories;
DirectoryListing gListing;
char gDirectory[PLATFORM_MAX_PATH];

#include "gokz-top-replays/header.sp"
#include "gokz-top-replays/helpers.sp"
#include "gokz-top-replays/queue.sp"
#include "gokz-top-replays/discovery.sp"
#include "gokz-top-replays/http.sp"

public void OnPluginStart()
{
	BuildPath(Path_SM, gSpool, sizeof(gSpool), "data/gokz-top-replays");
	CreateDirectory(gSpool, 448);
	QueueInit();
	ConVar hibernate = FindConVar("sv_hibernate_when_empty");
	gHibernating = hibernate != null && hibernate.BoolValue && GetClientCount(true) == 0;
	gDirectories = new ArrayList(ByteCountToCells(PLATFORM_MAX_PATH));
	RegAdminCmd("sm_topreplays_retry", CommandRetry, ADMFLAG_ROOT);
	RegAdminCmd("sm_topreplays_status", CommandStatus, ADMFLAG_ROOT);
	CreateTimer(0.1, TimerWorker, _, TIMER_REPEAT);
	LogMessage("[gokz-top-replays] version=%s discovery=legacy-and-uuid", GOKZ_TOP_REPLAYS_VERSION);
}

public void OnAllPluginsLoaded()
{
	gCV_RequestTimeout = FindConVar("gokz_top_request_timeout");
}

public void OnPluginEnd()
{
	ReleaseWorker();
	delete gListing;
	delete gDirectories;
	delete gDB;
}

public Action TimerWorker(Handle timer)
{
	if (gHibernating) return Plugin_Continue;
	GOKZTop_GetHTTPConfig(gEnvironment, sizeof(gEnvironment), gKey, sizeof(gKey));
	TrimString(gEnvironment);
	int length = strlen(gEnvironment);
	if (length && gEnvironment[length - 1] == '/') gEnvironment[length - 1] = '\0';
	if (!gEnvironment[0] || !gKey[0]) return Plugin_Continue;
	if (!gOwnWorker)
	{
		char lock[PLATFORM_MAX_PATH]; Format(lock, sizeof(lock), "%s/.worker.lock", gSpool);
		gOwnWorker = GOKZTop_ReplayWorkerLock(lock);
		if (!gOwnWorker) return Plugin_Continue;
	}
	ScanTick();
	if (!gBusy) HTTPNext();
	return Plugin_Continue;
}

public void GOKZ_JS_OnLanding(Jump jump)
{
	if (!IsValidUploadClient(jump.jumper) || !IsRetainableJumpType(jump.type)) return;
	int mode = GOKZ_GetCoreOption(jump.jumper, Option_Mode);
	int style = GOKZ_GetCoreOption(jump.jumper, Option_Style);
	if (mode < 0 || mode >= MODE_COUNT || style < 0 || style >= STYLE_COUNT) return;
	char path[PLATFORM_MAX_PATH];
	FormatJumpReplayPath(path, sizeof(path), jump.jumper, jump.type, jump.block, mode, style);
	DataPack pack = new DataPack();
	pack.WriteString(path);
	CreateTimer(GOKZ_TOP_REPLAYS_SAVE_DELAY + 1.0, TimerDiscover, pack);
}

public Action TimerDiscover(Handle timer, DataPack pack)
{
	char path[PLATFORM_MAX_PATH];
	pack.Reset(); pack.ReadString(path, sizeof(path)); delete pack;
	DiscoverFile(path);
	return Plugin_Stop;
}

public Action GOKZ_RP_OnReplaySaved(int client, int replayType, const char[] map, int course, int timeType, float time, const char[] filePath, bool tempReplay)
{
	// Scanner retries young files after the writer has closed them.
	if (replayType == ReplayType_Jump) DiscoverFile(filePath);
	return Plugin_Continue;
}

void ReleaseWorker()
{
	if (gBusy && gDB != null)
	{
		// A cancelled POST may still finish at the API. Leave time for it to
		// settle before another instance retries the same immutable snapshot.
		char query[256];
		int timeout = gCV_RequestTimeout == null ? 10 : gCV_RequestTimeout.IntValue;
		Format(query, sizeof(query), "UPDATE jobs SET next=%d WHERE id=%d AND state='pending'", GetTime() + timeout + 5, gActiveID);
		QueueSQL(query);
	}
	delete gActiveRequest;
	gBusy = false;
	delete gListing;
	if (gDirectories != null) gDirectories.Clear();
	gNextScan = 0;
	if (gOwnWorker) GOKZTop_ReplayReleaseWorker();
	gOwnWorker = false;
}

public void OnServerEnterHibernation()
{
	gHibernating = true;
	ReleaseWorker();
}

public void OnServerExitHibernation()
{
	gHibernating = false;
}
