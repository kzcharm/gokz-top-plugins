#include <sourcemod>
#include <sdkhooks>
#include <cstrike>

#include <gokz/core>
#include <gokz/profile>

#undef REQUIRE_PLUGIN
#include <gokz/chat>
#include <gokz/top>

#pragma newdecls required
#pragma semicolon 1

#define GOKZ_TOP_PROFILE_VERSION "0.1.0"
#define MAX_STEAM_GROUP_TAG_LENGTH 9
#define GOKZ_TOP_RANK_COUNT 10

public Plugin myinfo =
{
	name = "GOKZ Top Profile",
	author = "Cinyan10",
	description = "Player profiles, ranks, tags, rating, and scoreboard levels backed by gokz-top v2",
	version = GOKZ_TOP_PROFILE_VERSION,
	url = "https://gokz.top"
};

int gI_Rank[MAXPLAYERS + 1][MODE_COUNT];
bool gB_Chat;
bool gB_GokzTop;
bool gB_GokzCore;
bool gB_LegacySurfaceDeferred;
char gC_OriginalSteamGroupTag[MAXPLAYERS + 1][32];

stock char gC_GokzTopRankColor[11][] =
{
	"{grey}",
	"{grey}",
	"{default}",
	"{blue}",
	"{lightgreen}",
	"{green}",
	"{purple}",
	"{orchid}",
	"{lightred}",
	"{red}",
	"{gold}"
};

stock char gC_GokzTopRankName[GOKZ_TOP_RANK_COUNT + 1][] =
{
	"",
	"New",
	"Beginner",
	"Amateur",
	"Casual",
	"Regular",
	"Skilled",
	"Expert",
	"Pro",
	"Master",
	"Legend"
};

#include "gokz-top-profile/api.sp"
#include "gokz-top-profile/legacy_disable.sp"
#include "gokz-top-profile/options.sp"
#include "gokz-top-profile/profile_menu.sp"
#include "gokz-top-profile/tags.sp"
#include "gokz-top-profile/scoreboard.sp"
#include "gokz-top-profile/commands.sp"

public APLRes AskPluginLoad2(Handle myself, bool late, char[] error, int errMax)
{
	if (IsLegacyProfileSurfaceOccupied())
	{
		gB_LegacySurfaceDeferred = true;
	}
	else
	{
		CreateNatives();
		RegPluginLibrary("gokz-profile");
	}

	CreateGlobalForwards();
	return APLRes_Success;
}

public void OnPluginStart()
{
	LoadTranslations("common.phrases");
	LoadTranslations("gokz-common.phrases");
	LoadTranslations("gokz-profile.phrases");

	DisableLegacyProfileBinary();
	if (gB_LegacySurfaceDeferred)
	{
		// The legacy plugin unload is deferred by SourceMod. Reload only after
		// that unload has completed so AskPluginLoad2 sees a clean API surface.
		CreateTimer(0.1, Timer_ReloadAfterLegacyUnload, _, TIMER_FLAG_NO_MAPCHANGE);
		return;
	}

	RegisterCommands();
	OnPluginStart_Scoreboard();
}

public Action Timer_ReloadAfterLegacyUnload(Handle timer)
{
	ServerCommand("sm plugins reload gokz-top-profile");
	return Plugin_Stop;
}

public void OnAllPluginsLoaded()
{
	gB_Chat = LibraryExists("gokz-chat");
	gB_GokzTop = LibraryExists("gokz-top-core");
	gB_GokzCore = LibraryExists("gokz-core");

	for (int client = 1; client <= MaxClients; client++)
	{
		if (IsValidClient(client) && !IsFakeClient(client))
		{
			UpdateRank(client, GetClientDisplayMode(client));
			UpdateSkillLevel(client);
		}
	}

	TopMenu topMenu;
	if (gB_GokzCore && (topMenu = GOKZ_GetOptionsTopMenu()) != null)
	{
		GOKZ_OnOptionsMenuReady(topMenu);
	}
}

public void OnLibraryAdded(const char[] name)
{
	gB_Chat = gB_Chat || StrEqual(name, "gokz-chat");
	gB_GokzTop = gB_GokzTop || StrEqual(name, "gokz-top-core");
	gB_GokzCore = gB_GokzCore || StrEqual(name, "gokz-core");
}

public void OnLibraryRemoved(const char[] name)
{
	gB_Chat = gB_Chat && !StrEqual(name, "gokz-chat");
	gB_GokzTop = gB_GokzTop && !StrEqual(name, "gokz-top-core");
	gB_GokzCore = gB_GokzCore && !StrEqual(name, "gokz-core");
}

public void OnMapStart()
{
	OnMapStart_Scoreboard();
}

public void OnClientConnected(int client)
{
	for (int mode = 0; mode < MODE_COUNT; mode++)
	{
		gI_Rank[client][mode] = 0;
	}

	gC_OriginalSteamGroupTag[client][0] = '\0';
	Profile_OnClientConnected(client);
}

public void OnClientPutInServer(int client)
{
	if (!IsValidClient(client) || IsFakeClient(client))
	{
		return;
	}

	CreateTimer(0.1, Timer_CaptureSteamGroupTag, GetClientUserId(client), TIMER_FLAG_NO_MAPCHANGE);
	UpdateRank(client, GetClientDisplayMode(client));
	UpdateSkillLevel(client);
}

public Action Timer_CaptureSteamGroupTag(Handle timer, int userID)
{
	int client = GetClientOfUserId(userID);
	if (!IsValidClient(client) || IsFakeClient(client) || gC_OriginalSteamGroupTag[client][0] != '\0')
	{
		return Plugin_Stop;
	}

	char tag[32];
	CS_GetClientClanTag(client, tag, sizeof(tag));
	if (tag[0] != '\0' && tag[0] != '[')
	{
		TruncateSteamGroupTag(tag);
		strcopy(gC_OriginalSteamGroupTag[client], sizeof(gC_OriginalSteamGroupTag[]), tag);
	}

	return Plugin_Stop;
}

public void OnClientDisconnect(int client)
{
	Profile_OnClientDisconnect(client);
}

public Action OnClientCommandKeyValues(int client, KeyValues kv)
{
	char cmd[16];
	if (kv.GetSectionName(cmd, sizeof(cmd)) && StrEqual(cmd, "ClanTagChanged", false))
	{
		CaptureSteamGroupTagFromKeyValues(client, kv);
		return Plugin_Handled;
	}

	return Plugin_Continue;
}

public void OnRebuildAdminCache(AdminCachePart part)
{
	for (int client = 1; client <= MaxClients; client++)
	{
		if (IsValidClient(client) && !IsFakeClient(client))
		{
			UpdateRank(client, GetClientDisplayMode(client));
		}
	}
}

public void GOKZ_OnOptionsMenuCreated(TopMenu topMenu)
{
	OnOptionsMenuCreated_OptionsMenu(topMenu);
}

public void GOKZ_OnOptionsMenuReady(TopMenu topMenu)
{
	OnOptionsMenuReady_Options();
	OnOptionsMenuReady_OptionsMenu(topMenu);
}

public void GOKZ_OnOptionsLoaded(int client)
{
	if (IsValidClient(client) && !IsFakeClient(client))
	{
		UpdateRank(client, GetClientDisplayMode(client));
	}
}

public void GOKZ_OnOptionChanged(int client, const char[] option, any newValue)
{
	Option coreOption;
	if (GOKZ_IsCoreOption(option, coreOption) && coreOption == Option_Mode)
	{
		UpdateRank(client, newValue);
		UpdateSkillLevel(client);
	}
	else if (IsProfileOption(option))
	{
		UpdateRank(client, GetClientDisplayMode(client));
	}
}

public void GOKZTop_OnLeaderboardDataFetched(int client, int mode, float rating, int rank, int regionalRank, bool hasRegionalRank, const char[] regionCode)
{
	if (!IsValidClient(client) || IsFakeClient(client))
	{
		return;
	}

	UpdateRank(client, GetClientDisplayMode(client));
	UpdateSkillLevel(client);
	Profile_OnLeaderboardDataFetched(client, mode);
}

int GetClientDisplayMode(int client)
{
	if (gB_GokzCore && IsValidClient(client))
	{
		int mode = GOKZ_GetCoreOption(client, Option_Mode);
		if (mode >= 0 && mode < MODE_COUNT)
		{
			return mode;
		}
	}

	return Mode_KZTimer;
}

int GetDataModeForDisplay(int displayMode)
{
	if (displayMode >= 0 && displayMode < MODE_COUNT)
	{
		return displayMode;
	}

	return Mode_KZTimer;
}

void TruncateSteamGroupTag(char[] tag)
{
	if (strlen(tag) > MAX_STEAM_GROUP_TAG_LENGTH)
	{
		tag[MAX_STEAM_GROUP_TAG_LENGTH] = '\0';
	}
}

void CaptureSteamGroupTagFromKeyValues(int client, KeyValues kv)
{
	if (!IsValidClient(client) || gC_OriginalSteamGroupTag[client][0] != '\0')
	{
		return;
	}

	char tag[32];
	if (kv.GetString("tag", tag, sizeof(tag)) && tag[0] != '\0')
	{
		TruncateSteamGroupTag(tag);
		strcopy(gC_OriginalSteamGroupTag[client], sizeof(gC_OriginalSteamGroupTag[]), tag);
	}
}
