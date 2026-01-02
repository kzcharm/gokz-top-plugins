#include <sourcemod>

#include <cstrike>

#include <gokz/core>
#include <gokz/profile>
#include <gokz/global>

#undef REQUIRE_EXTENSIONS
#undef REQUIRE_PLUGIN
#include <gokz/chat>
#include <gokz-top>

#pragma newdecls required
#pragma semicolon 1



public Plugin myinfo = 
{
	name = "GOKZ Profile", 
	author = "zealain", 
	description = "Player profiles and ranks based on local and global data.", 
	version = GOKZ_VERSION, 
	url = GOKZ_SOURCE_URL
};

int gI_Rank[MAXPLAYERS + 1][MODE_COUNT];
bool gB_Localranks;
bool gB_Chat;
bool gB_GokzTop;

// Extended tag types (assuming ProfileTagType enum: Rank=0, VIP=1, Admin=2)
#define ProfileTagType_GlobalRank 3
#define ProfileTagType_RegionalRank 4
#define ProfileTagType_Rating 5

#include "gokz-profile/options.sp"
#include "gokz-profile/profile.sp"



// =====[ PLUGIN EVENTS ]=====

public APLRes AskPluginLoad2(Handle myself, bool late, char[] error, int err_max)
{
	CreateNatives();
	RegPluginLibrary("gokz-profile");
	return APLRes_Success;
}

public void OnPluginStart()
{
	LoadTranslations("common.phrases");
	LoadTranslations("gokz-profile.phrases");
	CreateGlobalForwards();
	RegisterCommands();
}

public void OnAllPluginsLoaded()
{
	gB_Localranks = LibraryExists("gokz-localranks");
	gB_Chat = LibraryExists("gokz-chat");
	gB_GokzTop = LibraryExists("gokz-top-core");

	for (int client = 1; client <= MaxClients; client++)
	{
		if (IsValidClient(client) && !IsFakeClient(client))
		{
			UpdateRank(client, GOKZ_GetCoreOption(client, Option_Mode));
		}
	}

	TopMenu topMenu;
	if (LibraryExists("gokz-core") && ((topMenu = GOKZ_GetOptionsTopMenu()) != null))
	{
		GOKZ_OnOptionsMenuReady(topMenu);
	}
}

public void OnLibraryAdded(const char[] name)
{
	gB_Localranks = gB_Localranks || StrEqual(name, "gokz-localranks");
	gB_Chat = gB_Chat || StrEqual(name, "gokz-chat");
	gB_GokzTop = gB_GokzTop || StrEqual(name, "gokz-top-core");
}

public void OnLibraryRemoved(const char[] name)
{
	gB_Localranks = gB_Localranks && !StrEqual(name, "gokz-localranks");
	gB_Chat = gB_Chat && !StrEqual(name, "gokz-chat");
	gB_GokzTop = gB_GokzTop && !StrEqual(name, "gokz-top-core");
}



// =====[ EVENTS ]=====

public Action OnClientCommandKeyValues(int client, KeyValues kv)
{
	// Block clan tag changes - Credit: GoD-Tony (https://forums.alliedmods.net/showpost.php?p=2337679&postcount=6)
	char cmd[16];
	if (kv.GetSectionName(cmd, sizeof(cmd)) && StrEqual(cmd, "ClanTagChanged", false))
	{
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
			int mode = GOKZ_GetCoreOption(client, Option_Mode);
			UpdateRank(client, mode);
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
		int mode = GOKZ_GetCoreOption(client, Option_Mode);
		UpdateTags(client, gI_Rank[client][mode], mode);
	}
}

public void OnClientConnected(int client)
{
	for (int mode = 0; mode < MODE_COUNT; mode++)
	{
		gI_Rank[client][mode] = 0;
	}
	Profile_OnClientConnected(client);
}

public void OnClientDisconnect(int client)
{
	Profile_OnClientDisconnect(client);
}

public void GOKZ_OnOptionChanged(int client, const char[] option, any newValue)
{
	Option coreOption;
	if (GOKZ_IsCoreOption(option, coreOption) && coreOption == Option_Mode)
	{
		UpdateRank(client, newValue);
	}
	else if (StrEqual(option, gC_ProfileOptionNames[ProfileOption_ShowRankChat], true)
		|| StrEqual(option, gC_ProfileOptionNames[ProfileOption_ShowRankClanTag], true)
		|| StrEqual(option, gC_ProfileOptionNames[ProfileOption_TagType], true))
	{
		UpdateRank(client, GOKZ_GetCoreOption(client, Option_Mode));
	}
}

public void GOKZ_GL_OnPointsUpdated(int client, int mode)
{
	UpdateRank(client, mode);
	Profile_OnPointsUpdated(client, mode);
}

public void GOKZTop_OnLeaderboardDataFetched(int client, int mode, float rating, int rank, int regionalRank, bool hasRegionalRank, const char[] regionCode)
{
	// Update tags when leaderboard data is fetched
	if (IsValidClient(client) && !IsFakeClient(client))
	{
		int currentMode = GOKZ_GetCoreOption(client, Option_Mode);
		if (mode == currentMode)
		{
			UpdateRank(client, mode);
		}
	}
}

public void UpdateRank(int client, int mode)
{
	if (!IsValidClient(client) || IsFakeClient(client))
	{
		return;
	}

	int tagType = GetAvailableTagTypeOrDefault(client);

	if (tagType != ProfileTagType_Rank)
	{
		char clanTag[64], chatTag[32], color[64];

		if (tagType == ProfileTagType_Admin)
		{
			FormatEx(clanTag, sizeof(clanTag), "[%s %T]", gC_ModeNamesShort[mode], "Tag - Admin", client);
			FormatEx(chatTag, sizeof(chatTag), "%T", "Tag - Admin", client);
			color = TAG_COLOR_ADMIN;
		}
		else if (tagType == ProfileTagType_VIP)
		{
			FormatEx(clanTag, sizeof(clanTag), "[%s %T]", gC_ModeNamesShort[mode], "Tag - VIP", client);
			FormatEx(chatTag, sizeof(chatTag), "%T", "Tag - VIP", client);
			color = TAG_COLOR_VIP;
		}
		else if (tagType == ProfileTagType_GlobalRank && gB_GokzTop)
		{
			// Check if player is in leaderboards
			if (GOKZTop_IsLeaderboardDataLoaded(client, mode))
			{
				int rank = GOKZTop_GetRank(client, mode);
				if (rank > 0)
				{
					FormatEx(clanTag, sizeof(clanTag), "[%s GL#%d]", gC_ModeNamesShort[mode], rank);
					FormatEx(chatTag, sizeof(chatTag), "GL#%d", rank);
					color = "{lightblue}";
				}
				else
				{
					// Not in leaderboards, fall back to mode only
					FormatEx(clanTag, sizeof(clanTag), "[%s]", gC_ModeNamesShort[mode]);
					FormatEx(chatTag, sizeof(chatTag), "");
					color = "{default}";
				}
			}
			else
			{
				// Data not loaded yet, show mode only
				FormatEx(clanTag, sizeof(clanTag), "[%s]", gC_ModeNamesShort[mode]);
				FormatEx(chatTag, sizeof(chatTag), "");
				color = "{default}";
			}
		}
		else if (tagType == ProfileTagType_RegionalRank && gB_GokzTop)
		{
			// Check if player is in leaderboards and has regional rank
			if (GOKZTop_IsLeaderboardDataLoaded(client, mode) && GOKZTop_HasRegionalRank(client, mode))
			{
				int regionalRank = GOKZTop_GetRegionalRank(client, mode);
				if (regionalRank > 0)
				{
					char regionCode[8];
					GOKZTop_GetRegionCode(client, mode, regionCode, sizeof(regionCode));
					
					// Format with region code (e.g., "EU#149" or "NA#123")
					if (regionCode[0] != '\0')
					{
						FormatEx(clanTag, sizeof(clanTag), "[%s %s#%d]", gC_ModeNamesShort[mode], regionCode, regionalRank);
						FormatEx(chatTag, sizeof(chatTag), "%s#%d", regionCode, regionalRank);
					}
					else
					{
						// Fallback if region code not available
						FormatEx(clanTag, sizeof(clanTag), "[%s REG#%d]", gC_ModeNamesShort[mode], regionalRank);
						FormatEx(chatTag, sizeof(chatTag), "REG#%d", regionalRank);
					}
					color = "{lightgreen}";
				}
				else
				{
					// Regional rank is 0, fall back to global rank if available
					if (GOKZTop_IsLeaderboardDataLoaded(client, mode))
					{
						int rank = GOKZTop_GetRank(client, mode);
						if (rank > 0)
						{
							FormatEx(clanTag, sizeof(clanTag), "[%s GL#%d]", gC_ModeNamesShort[mode], rank);
							FormatEx(chatTag, sizeof(chatTag), "GL#%d", rank);
							color = "{lightblue}";
						}
						else
						{
							// Not in leaderboards, fall back to mode only
							FormatEx(clanTag, sizeof(clanTag), "[%s]", gC_ModeNamesShort[mode]);
							FormatEx(chatTag, sizeof(chatTag), "");
							color = "{default}";
						}
					}
					else
					{
						// Data not loaded, show mode only
						FormatEx(clanTag, sizeof(clanTag), "[%s]", gC_ModeNamesShort[mode]);
						FormatEx(chatTag, sizeof(chatTag), "");
						color = "{default}";
					}
				}
			}
			else
			{
				// Data not loaded or no regional rank, fall back to global rank if available
				if (GOKZTop_IsLeaderboardDataLoaded(client, mode))
				{
					int rank = GOKZTop_GetRank(client, mode);
					if (rank > 0)
					{
						FormatEx(clanTag, sizeof(clanTag), "[%s GL#%d]", gC_ModeNamesShort[mode], rank);
						FormatEx(chatTag, sizeof(chatTag), "GL#%d", rank);
						color = "{lightblue}";
					}
					else
					{
						// Not in leaderboards, show mode only
						FormatEx(clanTag, sizeof(clanTag), "[%s]", gC_ModeNamesShort[mode]);
						FormatEx(chatTag, sizeof(chatTag), "");
						color = "{default}";
					}
				}
				else
				{
					// Data not loaded, show mode only
					FormatEx(clanTag, sizeof(clanTag), "[%s]", gC_ModeNamesShort[mode]);
					FormatEx(chatTag, sizeof(chatTag), "");
					color = "{default}";
				}
			}
		}
		else if (tagType == ProfileTagType_Rating && gB_GokzTop)
		{
			// Check if player is in leaderboards
			if (GOKZTop_IsLeaderboardDataLoaded(client, mode))
			{
				float rating = GOKZTop_GetRating(client, mode);
				if (rating > 0.0)
				{
					int floorRating = RoundToFloor(rating);
					FormatEx(clanTag, sizeof(clanTag), "[%s Lv.%d]", gC_ModeNamesShort[mode], floorRating);
					FormatEx(chatTag, sizeof(chatTag), "Lv.%d", floorRating);
					color = "{yellow}";
				}
				else
				{
					// Not in leaderboards, fall back to mode only
					FormatEx(clanTag, sizeof(clanTag), "[%s]", gC_ModeNamesShort[mode]);
					FormatEx(chatTag, sizeof(chatTag), "");
					color = "{default}";
				}
			}
			else
			{
				// Data not loaded yet, show mode only
				FormatEx(clanTag, sizeof(clanTag), "[%s]", gC_ModeNamesShort[mode]);
				FormatEx(chatTag, sizeof(chatTag), "");
				color = "{default}";
			}
		}

		if (GOKZ_GetOption(client, gC_ProfileOptionNames[ProfileOption_ShowRankClanTag]) != ProfileOptionBool_Enabled)
		{
			FormatEx(clanTag, sizeof(clanTag), "[%s]", gC_ModeNamesShort[mode]);
		}
		CS_SetClientClanTag(client, clanTag);

		if (gB_Chat)
		{
			if (GOKZ_GetOption(client, gC_ProfileOptionNames[ProfileOption_ShowRankChat]) == ProfileOptionBool_Enabled)
			{
				GOKZ_CH_SetChatTag(client, chatTag, color);
			}
			else
			{
				GOKZ_CH_SetChatTag(client, "", "{default}");
			}
		}
		return;
	}

	int points = GOKZ_GL_GetRankPoints(client, mode);
	int rank;
	for (rank = 1; rank < RANK_COUNT; rank++)
	{
		if (points < gI_rankThreshold[mode][rank])
		{
			break;
		}
	}
	rank--;

	if (GOKZ_GetCoreOption(client, Option_Mode) == mode)
	{
		if (points == -1)
		{
			UpdateTags(client, -1, mode);
		}
		else
		{
			UpdateTags(client, rank, mode);
		}
	}

	if (gI_Rank[client][mode] != rank)
	{
		gI_Rank[client][mode] = rank;
		Call_OnRankUpdated(client, mode, rank);
	}
}

void UpdateTags(int client, int rank, int mode)
{
	char str[64];
	if (rank != -1 &&
		GOKZ_GetOption(client, gC_ProfileOptionNames[ProfileOption_ShowRankClanTag]) == ProfileOptionBool_Enabled)
	{
		FormatEx(str, sizeof(str), "[%s %s]", gC_ModeNamesShort[mode], gC_rankName[rank]);
		CS_SetClientClanTag(client, str);
	}
	else
	{
		FormatEx(str, sizeof(str), "[%s]", gC_ModeNamesShort[mode]);
		CS_SetClientClanTag(client, str);
	}

	if (gB_Chat)
	{
		if (rank != -1 &&
			GOKZ_GetOption(client, gC_ProfileOptionNames[ProfileOption_ShowRankChat]) == ProfileOptionBool_Enabled)
		{
			GOKZ_CH_SetChatTag(client, gC_rankName[rank], gC_rankColor[rank]);
		}
		else
		{
			GOKZ_CH_SetChatTag(client, "", "{default}");
		}
	}
}

bool CanUseTagType(int client, int tagType)
{
	switch (tagType)
	{
		case ProfileTagType_Rank: return true;
		case ProfileTagType_VIP: return CheckCommandAccess(client, "gokz_flag_vip", ADMFLAG_CUSTOM1);
		case ProfileTagType_Admin: return CheckCommandAccess(client, "gokz_flag_admin", ADMFLAG_GENERIC);
		case ProfileTagType_GlobalRank, ProfileTagType_Rating:
		{
			// Only allow if gokz-top-core is loaded and player is in leaderboards
			if (!gB_GokzTop)
			{
				return false;
			}
			int mode = GOKZ_GetCoreOption(client, Option_Mode);
			if (!GOKZTop_IsLeaderboardDataLoaded(client, mode))
			{
				return false;
			}
			// Check if player has a valid rank/rating
			if (tagType == ProfileTagType_Rating)
			{
				float rating = GOKZTop_GetRating(client, mode);
				return rating > 0.0;
			}
			else // ProfileTagType_GlobalRank
			{
				int rank = GOKZTop_GetRank(client, mode);
				return rank > 0;
			}
		}
		case ProfileTagType_RegionalRank:
		{
			// Only allow if gokz-top-core is loaded and player has regional rank
			if (!gB_GokzTop)
			{
				return false;
			}
			int mode = GOKZ_GetCoreOption(client, Option_Mode);
			if (!GOKZTop_IsLeaderboardDataLoaded(client, mode))
			{
				return false;
			}
			// Check if player has regional rank available
			return GOKZTop_HasRegionalRank(client, mode) && GOKZTop_GetRegionalRank(client, mode) > 0;
		}
		default: return false;
	}
}

int GetAvailableTagTypeOrDefault(int client)
{
	int tagType = GOKZ_GetOption(client, gC_ProfileOptionNames[ProfileOption_TagType]);
	if (!CanUseTagType(client, tagType))
	{
		return ProfileTagType_Rank;
	}

	return tagType;
}

// =====[ COMMANDS ]=====

void RegisterCommands()
{
	RegConsoleCmd("sm_profile", CommandProfile, "[KZ] Show the profile of a player. Usage: !profile <player>");
	RegConsoleCmd("sm_p", CommandProfile, "[KZ] Show the profile of a player. Usage: !p <player>");
	RegConsoleCmd("sm_profileoptions", CommandProfileOptions, "[KZ] Show the profile options.");
	RegConsoleCmd("sm_pfo", CommandProfileOptions, "[KZ] Show the profile options.");
	RegConsoleCmd("sm_ranks", CommandRanks, "[KZ] Show all the available ranks.");
}

public Action CommandProfile(int client, int args)
{
	if (args == 0)
	{
		ShowProfile(client, client);
	}
	else
	{
		char playerName[64];
		GetCmdArgString(playerName, sizeof(playerName));
		int player = FindTarget(client, playerName, true, false);
		if (player != -1)
		{
			ShowProfile(client, player);
		}
	}
	return Plugin_Handled;
}

public Action CommandProfileOptions(int client, int args)
{
	DisplayProfileOptionsMenu(client);
	return Plugin_Handled;
}

public Action CommandRanks(int client, int args)
{
	char rankBuffer[256];
	char buffer[256];
	int mode = GOKZ_GetCoreOption(client, Option_Mode);

	Format(buffer, sizeof(buffer), "%s: ", gC_ModeNamesShort[mode]);

	for (int i = 0; i < RANK_COUNT; i++) {
		Format(rankBuffer, sizeof(rankBuffer), "%s%s (%d) ", gC_rankColor[i], gC_rankName[i], gI_rankThreshold[mode][i]);
		StrCat(buffer, sizeof(buffer), rankBuffer);

		if (i > 0 && i % 3 == 0) {
			GOKZ_PrintToChat(client, true, buffer);
			Format(buffer, sizeof(buffer), "%s: ", gC_ModeNamesShort[mode]);
		}
	}

	GOKZ_PrintToChat(client, true, buffer);

	return Plugin_Handled;
}


// =====[ FORWARDS ]=====

static GlobalForward H_OnRankUpdated;


void CreateGlobalForwards()
{
	H_OnRankUpdated = new GlobalForward("GOKZ_PF_OnRankUpdated", ET_Ignore, Param_Cell, Param_Cell, Param_Cell);
}

void Call_OnRankUpdated(int client, int mode, int rank)
{
	Call_StartForward(H_OnRankUpdated);
	Call_PushCell(client);
	Call_PushCell(mode);
	Call_PushCell(rank);
	Call_Finish();
}



// =====[ NATIVES ]=====

void CreateNatives()
{
	CreateNative("GOKZ_PF_GetRank", Native_GetRank);
}

public int Native_GetRank(Handle plugin, int numParams)
{
	return gI_Rank[GetNativeCell(1)][GetNativeCell(2)];
}
