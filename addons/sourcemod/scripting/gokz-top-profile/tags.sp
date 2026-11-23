char gC_ProfileClanTag[MAXPLAYERS + 1][64];
int gI_ClanTagMode[MAXPLAYERS + 1];
char gC_ClanTagSuffix[MAXPLAYERS + 1][2][CLAN_TAG_BYTES];
Handle gH_SuffixOwner[MAXPLAYERS + 1][2];

void ResetClanTagState(int client)
{
	gC_ProfileClanTag[client][0] = '\0';
	gH_SuffixOwner[client][0] = null;
	gH_SuffixOwner[client][1] = null;
}

void SetClanTagSuffix(int client, Handle owner, const char[] suffix, int layer)
{
	if (!suffix[0] && gH_SuffixOwner[client][layer] != owner)
	{
		return;
	}
	gH_SuffixOwner[client][layer] = suffix[0] ? owner : null;
	strcopy(gC_ClanTagSuffix[client][layer], CLAN_TAG_BYTES, suffix);
	RefreshClanTag(client);
}

void RefreshClanTag(int client)
{
	if (!gC_ProfileClanTag[client][0] || !IsClientInGame(client))
	{
		return;
	}

	int mode = gI_ClanTagMode[client];
	char tag[CLAN_TAG_BYTES];
	int layer = gH_SuffixOwner[client][1] != null ? 1 : 0;
	if (gH_SuffixOwner[client][layer] != null)
	{
		char suffix[CLAN_TAG_BYTES];
		strcopy(suffix, sizeof(suffix), gC_ClanTagSuffix[client][layer]);
		int limit = sizeof(tag) - 4 - strlen(gC_ModeNamesShort[mode]); // Brackets, space and terminator.
		if (strlen(suffix) > limit)
		{
			while (limit > 0 && (suffix[limit] & 0xC0) == 0x80)
			{
				limit--;
			}
			suffix[limit] = '\0';
		}
		FormatEx(tag, sizeof(tag), "[%s %s]", gC_ModeNamesShort[mode], suffix);
	}
	else
	{
		CS_SetClientClanTag(client, gC_ProfileClanTag[client]);
		return;
	}
	CS_SetClientClanTag(client, tag);
}

void UpdateRank(int client, int mode)
{
	if (!IsValidClient(client) || IsFakeClient(client))
	{
		return;
	}

	mode = GetDataModeForDisplay(mode);
	int dataMode = GetDataModeForDisplay(mode);
	int tagType = GetAvailableTagTypeOrDefault(client);

	if (tagType != ProfileTagType_Rank)
	{
		UpdateSpecialTags(client, mode, dataMode, tagType);
		return;
	}

	if (!gB_GokzTop || !GOKZTop_IsLeaderboardDataLoaded(client, dataMode))
	{
		if (gB_GokzTop)
		{
			GOKZTop_RefreshLeaderboardData(client, dataMode);
		}
		UpdateTags(client, -1, mode);
		SetCachedRank(client, mode, 0);
		return;
	}

	int rank = GetRankForRating(GOKZTop_GetRating(client, dataMode));
	UpdateTags(client, rank, mode);
	SetCachedRank(client, mode, rank);
}

void UpdateSpecialTags(int client, int displayMode, int dataMode, int tagType)
{
	char clanTag[64];
	char chatTag[32];
	char color[32];
	strcopy(color, sizeof(color), "{default}");

	if (tagType == ProfileTagType_Admin)
	{
		FormatEx(clanTag, sizeof(clanTag), "[%s %T]", gC_ModeNamesShort[displayMode], "Tag - Admin", client);
		FormatEx(chatTag, sizeof(chatTag), "%T", "Tag - Admin", client);
		strcopy(color, sizeof(color), TAG_COLOR_ADMIN);
	}
	else if (tagType == ProfileTagType_VIP)
	{
		FormatEx(clanTag, sizeof(clanTag), "[%s %T]", gC_ModeNamesShort[displayMode], "Tag - VIP", client);
		FormatEx(chatTag, sizeof(chatTag), "%T", "Tag - VIP", client);
		strcopy(color, sizeof(color), TAG_COLOR_VIP);
	}
	else if (tagType == ProfileTagType_GlobalRank && gB_GokzTop && GOKZTop_IsLeaderboardDataLoaded(client, dataMode))
	{
		int rank = GOKZTop_GetGlobalRank(client, dataMode);
		FormatEx(clanTag, sizeof(clanTag), rank > 0 ? "[%s GL#%d]" : "[%s]", gC_ModeNamesShort[displayMode], rank);
		FormatEx(chatTag, sizeof(chatTag), rank > 0 ? "GL#%d" : "", rank);
		GetGokzTopRankColorFromRating(GOKZTop_GetRating(client, dataMode), color, sizeof(color));
	}
	else if (tagType == ProfileTagType_RegionalRank && gB_GokzTop && GOKZTop_IsLeaderboardDataLoaded(client, dataMode))
	{
		int regionalRank = GOKZTop_GetRegionalRank(client, dataMode);
		char region[8];
		GOKZTop_GetRegionCode(client, dataMode, region, sizeof(region));
		if (regionalRank > 0 && region[0] != '\0')
		{
			FormatEx(clanTag, sizeof(clanTag), "[%s %s#%d]", gC_ModeNamesShort[displayMode], region, regionalRank);
			FormatEx(chatTag, sizeof(chatTag), "%s#%d", region, regionalRank);
			GetGokzTopRankColorFromRating(GOKZTop_GetRating(client, dataMode), color, sizeof(color));
		}
		else
		{
			FormatEx(clanTag, sizeof(clanTag), "[%s]", gC_ModeNamesShort[displayMode]);
			chatTag[0] = '\0';
		}
	}
	else if (tagType == ProfileTagType_Rating && gB_GokzTop && GOKZTop_IsLeaderboardDataLoaded(client, dataMode))
	{
		float rating = GOKZTop_GetRating(client, dataMode);
		if (rating > 0.0)
		{
			FormatEx(clanTag, sizeof(clanTag), "[%s Rt %.2f]", gC_ModeNamesShort[displayMode], rating);
			FormatEx(chatTag, sizeof(chatTag), "Rt %.2f", rating);
			GetGokzTopRankColorFromRating(rating, color, sizeof(color));
		}
		else
		{
			FormatEx(clanTag, sizeof(clanTag), "[%s]", gC_ModeNamesShort[displayMode]);
			chatTag[0] = '\0';
		}
	}
	else if (tagType == ProfileTagType_SteamGroup)
	{
		if (gC_OriginalSteamGroupTag[client][0] != '\0')
		{
			FormatEx(clanTag, sizeof(clanTag), "[%s %s]", gC_ModeNamesShort[displayMode], gC_OriginalSteamGroupTag[client]);
			strcopy(chatTag, sizeof(chatTag), gC_OriginalSteamGroupTag[client]);
		}
		else
		{
			FormatEx(clanTag, sizeof(clanTag), "[%s]", gC_ModeNamesShort[displayMode]);
			chatTag[0] = '\0';
		}
	}
	else
	{
		FormatEx(clanTag, sizeof(clanTag), "[%s]", gC_ModeNamesShort[displayMode]);
		chatTag[0] = '\0';
		if (gB_GokzTop)
		{
			GOKZTop_RefreshLeaderboardData(client, dataMode);
		}
	}

	ApplyTags(client, displayMode, clanTag, chatTag, color);
}

void UpdateTags(int client, int rank, int mode)
{
	char clanTag[64];
	char chatTag[32];
	char color[32];
	if (rank > 0 && rank <= GOKZ_TOP_RANK_COUNT)
	{
		FormatEx(clanTag, sizeof(clanTag), "[%s %s]", gC_ModeNamesShort[mode], gC_GokzTopRankName[rank]);
		strcopy(chatTag, sizeof(chatTag), gC_GokzTopRankName[rank]);
		strcopy(color, sizeof(color), gC_GokzTopRankColor[rank]);
	}
	else
	{
		FormatEx(clanTag, sizeof(clanTag), "[%s]", gC_ModeNamesShort[mode]);
		chatTag[0] = '\0';
		strcopy(color, sizeof(color), "{default}");
	}

	ApplyTags(client, mode, clanTag, chatTag, color);
}

void ApplyTags(int client, int mode, char[] clanTag, const char[] chatTag, const char[] color)
{
	if (GOKZ_GetOption(client, gC_ProfileOptionNames[ProfileOption_ShowRankClanTag]) != ProfileOptionBool_Enabled)
	{
		FormatEx(clanTag, 64, "[%s]", gC_ModeNamesShort[mode]);
	}
	gI_ClanTagMode[client] = mode;
	strcopy(gC_ProfileClanTag[client], sizeof(gC_ProfileClanTag[]), clanTag);
	RefreshClanTag(client);

	if (!gB_Chat)
	{
		return;
	}

	if (GOKZ_GetOption(client, gC_ProfileOptionNames[ProfileOption_ShowRankChat]) == ProfileOptionBool_Enabled)
	{
		GOKZ_CH_SetChatTag(client, chatTag, color);
	}
	else
	{
		GOKZ_CH_SetChatTag(client, "", "{default}");
	}
}

void SetCachedRank(int client, int mode, int rank)
{
	if (gI_Rank[client][mode] == rank)
	{
		return;
	}

	gI_Rank[client][mode] = rank;
	Call_OnRankUpdated(client, mode, rank);
}

int GetRankForRating(float rating)
{
	int rank = GetSkillLevelFromRating(rating);
	if (rank < 1)
	{
		return 1;
	}

	if (rank > GOKZ_TOP_RANK_COUNT)
	{
		return GOKZ_TOP_RANK_COUNT;
	}

	return rank;
}

void GetGokzTopRankColorFromRating(float rating, char[] color, int maxLength)
{
	strcopy(color, maxLength, gC_GokzTopRankColor[GetRankForRating(rating)]);
}

bool CanUseTagType(int client, int tagType)
{
	switch (tagType)
	{
		case ProfileTagType_Rank:
		{
			return true;
		}
		case ProfileTagType_VIP:
		{
			return CheckCommandAccess(client, "gokz_flag_vip", ADMFLAG_CUSTOM1);
		}
		case ProfileTagType_Admin:
		{
			return CheckCommandAccess(client, "gokz_flag_admin", ADMFLAG_GENERIC);
		}
		case ProfileTagType_SteamGroup:
		{
			return true;
		}
		case ProfileTagType_GlobalRank:
		{
			int dataMode = GetDataModeForDisplay(GetClientDisplayMode(client));
			return gB_GokzTop && GOKZTop_IsLeaderboardDataLoaded(client, dataMode) && GOKZTop_GetGlobalRank(client, dataMode) > 0;
		}
		case ProfileTagType_RegionalRank:
		{
			int dataMode = GetDataModeForDisplay(GetClientDisplayMode(client));
			return gB_GokzTop && GOKZTop_IsLeaderboardDataLoaded(client, dataMode) && GOKZTop_HasRegionalRank(client, dataMode);
		}
		case ProfileTagType_Rating:
		{
			int dataMode = GetDataModeForDisplay(GetClientDisplayMode(client));
			return gB_GokzTop && GOKZTop_IsLeaderboardDataLoaded(client, dataMode) && GOKZTop_GetRating(client, dataMode) > 0.0;
		}
	}

	return false;
}

int GetAvailableTagTypeOrDefault(int client)
{
	int tagType = GOKZ_GetOption(client, gC_ProfileOptionNames[ProfileOption_TagType]);
	return CanUseTagType(client, tagType) ? tagType : ProfileTagType_Rank;
}

int GetNextAvailableTagType(int client)
{
	int tagType = GOKZ_GetOption(client, gC_ProfileOptionNames[ProfileOption_TagType]);
	for (int attempt = 0; attempt < PROFILETAGTYPE_COUNT; attempt++)
	{
		tagType++;
		if (tagType >= PROFILETAGTYPE_COUNT)
		{
			tagType = 0;
		}

		if (CanUseTagType(client, tagType))
		{
			return tagType;
		}
	}

	return ProfileTagType_Rank;
}
