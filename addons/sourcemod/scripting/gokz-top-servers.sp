#include <sourcemod>
#include <sdktools>
#include <SteamWorks>
#include <autoexecconfig>

#include <gokz/core>
#include <gokz/kzplayer>
#include <gokz/top>

#undef REQUIRE_PLUGIN
#include <GlobalAPI>
#include <gokz/global>

#pragma newdecls required
#pragma semicolon 1

#define GOKZ_TOP_SERVERS_VERSION "0.1.0"
#define GOKZ_TOP_CFG_FOLDER "sourcemod/gokz-top"
#define GOKZ_TOP_SERVERS_CACHE_PATH "data/gokz-top/public_ip_cache.json"
#define GOKZ_TOP_SERVERS_CACHE_DIR "data/gokz-top"
#define GOKZ_TOP_PUBLIC_IP_LENGTH 64
#define GOKZ_TOP_HOSTNAME_LENGTH 256
#define GOKZ_TOP_STEAMID64_LENGTH 32
#define GOKZ_TOP_CLAN_TAG_LENGTH 64
#define GOKZ_TOP_TIMESTAMP_LENGTH 32
#define GOKZ_TOP_STATUS_BODY_LENGTH 16384
#define GOKZ_TOP_GLOBAL_STATUS_LENGTH 2048
#define GOKZ_TOP_STATUS_PATH "/v1/servers/status"
#define GOKZ_TOP_PUBLIC_IP_MAX_AGE 86400
#define GOKZ_TOP_PUBLIC_IP_FAILURE_COOLDOWN 60
#define GOKZ_TOP_PUBLIC_IP_TIMEOUT_MS 3000

enum ServerPlayerStatus
{
	ServerPlayerStatus_NotStarted = 0,
	ServerPlayerStatus_InProgress,
	ServerPlayerStatus_Finished,
	ServerPlayerStatus_Aborted
};

enum PublicIPProvider
{
	PublicIPProvider_IPAPI = 1,
	PublicIPProvider_MyIPWTF
};

public Plugin myinfo =
{
	name = "GOKZ Top Servers",
	author = "Cinyan10",
	description = "Live server status heartbeats for gokz-top",
	version = GOKZ_TOP_SERVERS_VERSION,
	url = "https://gokz.top"
};

bool gB_LateLoaded;
bool gB_ClientTracked[MAXPLAYERS + 1];
bool gB_ClientHasStarted[MAXPLAYERS + 1];
ServerPlayerStatus gI_ClientStatus[MAXPLAYERS + 1];
int gI_ClientConnectedAt[MAXPLAYERS + 1];
int gI_ClientLastStage[MAXPLAYERS + 1];
int gI_ClientLastTeleports[MAXPLAYERS + 1];
float gF_ClientLastTimerTime[MAXPLAYERS + 1];
ConVar gCV_PushInterval;
ConVar gCV_Hostname;
ConVar gCV_HostPort;
Handle gH_HeartbeatTimer;
Handle gH_QueuedHeartbeatTimer;
char gC_CurrentMap[PLATFORM_MAX_PATH];
char gC_PublicIP[GOKZ_TOP_PUBLIC_IP_LENGTH];
int gI_PublicIPLastRefresh;
int gI_NextPublicIPRefreshAttemptAt;
bool gB_PublicIPRefreshInFlight;

#include "gokz-top-servers/convars.sp"
#include "gokz-top-servers/cache.sp"
#include "gokz-top-servers/public_ip.sp"
#include "gokz-top-servers/players.sp"
#include "gokz-top-servers/global_status.sp"
#include "gokz-top-servers/heartbeat.sp"

public APLRes AskPluginLoad2(Handle myself, bool late, char[] error, int errMax)
{
	gB_LateLoaded = late;
	return APLRes_Success;
}

public void OnPluginStart()
{
	GetCurrentMap(gC_CurrentMap, sizeof(gC_CurrentMap));
	FindRequiredConVars();
	CreateConVars();
	LoadPublicIPCache();
	CreateHeartbeatTimer();
	InitializeGlobalStatus();
	QueueImmediateHeartbeat();
}

public void OnAllPluginsLoaded()
{
	RefreshGlobalStatusLibraries();
	QueueGlobalStatusRefresh();

	if (!gB_LateLoaded)
	{
		return;
	}

	for (int client = 1; client <= MaxClients; client++)
	{
		if (IsClientReadyForHeartbeat(client))
		{
			TrackClient(client);
		}
	}

	QueueImmediateHeartbeat();
}

public void OnPluginEnd()
{
	delete gH_HeartbeatTimer;
	delete gH_QueuedHeartbeatTimer;
	delete gH_GlobalRefreshTimer;
}

public void OnMapStart()
{
	GetCurrentMap(gC_CurrentMap, sizeof(gC_CurrentMap));

	for (int client = 1; client <= MaxClients; client++)
	{
		if (gB_ClientTracked[client])
		{
			ResetClientRunState(client, true);
			SyncClientRunState(client);
		}
	}

	QueueImmediateHeartbeat();
	QueueGlobalStatusRefresh();
}

public void OnLibraryAdded(const char[] name)
{
	UpdateGlobalStatusLibrary(name, true);
}

public void OnLibraryRemoved(const char[] name)
{
	UpdateGlobalStatusLibrary(name, false);
}

public void OnClientPostAdminCheck(int client)
{
	if (!IsClientReadyForHeartbeat(client))
	{
		return;
	}

	TrackClient(client);
	QueueImmediateHeartbeat();
}

public void OnClientDisconnect(int client)
{
	ClearClientRunState(client);
	QueueImmediateHeartbeat();
}

public void GOKZ_OnTimerStart_Post(int client, int course)
{
	if (!IsClientReadyForHeartbeat(client))
	{
		return;
	}

	TrackClient(client);
	gB_ClientHasStarted[client] = true;
	gI_ClientStatus[client] = ServerPlayerStatus_InProgress;
	gI_ClientLastStage[client] = course;
	gI_ClientLastTeleports[client] = GOKZ_GetTeleportCount(client);
	gF_ClientLastTimerTime[client] = GOKZ_GetTime(client);
	QueueImmediateHeartbeat();
}

public void GOKZ_OnTimerEnd_Post(int client, int course, float time, int teleportsUsed)
{
	if (!IsClientReadyForHeartbeat(client))
	{
		return;
	}

	TrackClient(client);
	gB_ClientHasStarted[client] = true;
	gI_ClientStatus[client] = ServerPlayerStatus_Finished;
	gI_ClientLastStage[client] = course;
	gI_ClientLastTeleports[client] = teleportsUsed;
	gF_ClientLastTimerTime[client] = time;
	QueueImmediateHeartbeat();
}

public void GOKZ_OnTimerStopped(int client)
{
	if (!IsClientReadyForHeartbeat(client))
	{
		return;
	}

	TrackClient(client);
	CaptureLiveRunState(client);
	if (gB_ClientHasStarted[client]
		&& gI_ClientStatus[client] != ServerPlayerStatus_Finished)
	{
		gI_ClientStatus[client] = ServerPlayerStatus_Aborted;
		QueueImmediateHeartbeat();
	}
}

public void GOKZ_OnPause_Post(int client)
{
	if (!IsClientReadyForHeartbeat(client))
	{
		return;
	}

	TrackClient(client);
	CaptureLiveRunState(client);
	QueueImmediateHeartbeat();
}

public void GOKZ_OnResume_Post(int client)
{
	if (!IsClientReadyForHeartbeat(client))
	{
		return;
	}

	TrackClient(client);
	CaptureLiveRunState(client);
	QueueImmediateHeartbeat();
}
