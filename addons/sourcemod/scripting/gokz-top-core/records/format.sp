// =====[ CHAT OUTPUT ]=====

void PrintPBLine(int client, int mode, int recordType, const char[] mapName, float pbTime, int pbPoints, const char[] dateOnly)
{
	char time[32];
	FormatDuration(time, sizeof(time), pbTime);

	char dateShort[32];
	FormatDateForClient(client, dateOnly, dateShort, sizeof(dateShort));

	char prefix[16];
	GetRecordTypeDisplay(recordType, prefix, sizeof(prefix));

	GOKZ_PrintToChat(client, false,
		"%s{purple}%s{default} - {bluegrey}%s{default} - %s{default} PB [ {lightgreen}%s{default} | {yellow}%d{default}{grey} Pts{default} | {bluegrey}%s{default} ]",
		GOKZ_TOP_CHAT_PREFIX,
		mapName,
		gC_RecordModeNames[mode],
		prefix,
		time,
		pbPoints,
		dateShort);
}

void PrintPBLineWithDiff(int client, int mode, int recordType, const char[] mapName, float pbTime, float runTime, int pbPoints, const char[] dateOnly,
	bool hasStored, float oldTime, int oldPoints)
{
	char time[32];
	FormatDuration(time, sizeof(time), pbTime);

	char dateShort[32];
	FormatDateForClient(client, dateOnly, dateShort, sizeof(dateShort));

	char diffInline[48];
	diffInline[0] = '\0';
	int pointDiff = 0;

	if (hasStored)
	{
		// Compare the finish with the baseline, while displaying the API's actual PB.
		float diff = runTime - oldTime;
		float diffAbs = FloatAbs(diff);

		char diffTime[24];
		FormatDurationDiff(diffTime, sizeof(diffTime), diffAbs);

		if (diff < 0.0)
		{
			Format(diffInline, sizeof(diffInline), " ({green}-%s{default})", diffTime);
			pointDiff = pbPoints - oldPoints;
			if (pointDiff < 0)
			{
				pointDiff = 0;
			}
		}
		else if (diff > 0.0)
		{
			Format(diffInline, sizeof(diffInline), " ({red}+%s{default})", diffTime);
		}
		else
		{
			Format(diffInline, sizeof(diffInline), " (+00.00)");
		}
	}

	char pointsText[64];
	if (pointDiff > 0)
	{
		Format(pointsText, sizeof(pointsText), "{yellow}%d{default} ({green}+%d{default}){grey} Pts{default}", pbPoints, pointDiff);
	}
	else
	{
		Format(pointsText, sizeof(pointsText), "{yellow}%d{default}{grey} Pts{default}", pbPoints);
	}

	char prefix[16];
	GetRecordTypeDisplay(recordType, prefix, sizeof(prefix));

	GOKZ_PrintToChat(client, false,
		"%s{purple}%s{default} - {bluegrey}%s{default} - %s{default} PB [ {lightgreen}%s{default}%s | %s | {bluegrey}%s{default} ]",
		GOKZ_TOP_CHAT_PREFIX,
		mapName,
		gC_RecordModeNames[mode],
		prefix,
		time,
		diffInline,
		pointsText,
		dateShort);
}



// =====[ PB CACHE ]=====

bool StorePB(int client, int mode, int recordType, const char[] mapName, float time, int points, const char[] dateOnly, int expectedRevision = -1)
{
	if (time <= 0.0)
	{
		return false;
	}

	char key[256];
	BuildPBKey(client, mode, recordType, mapName, key, sizeof(key));
	int revision = GetPBRevision(client, mode, recordType, mapName);
	// A response predating a newer cache write must not replace its metadata.
	if (expectedRevision != -1 && expectedRevision != revision) return false;
	gSM_PBRevision.SetValue(key, revision + 1);
	gSM_PBTime.SetValue(key, view_as<any>(time));
	gSM_PBPoints.SetValue(key, points);
	gSM_PBDate.SetString(key, dateOnly);
	return true;
}

int GetPBRevision(int client, int mode, int recordType, const char[] mapName)
{
	char key[256];
	BuildPBKey(client, mode, recordType, mapName, key, sizeof(key));
	int revision;
	gSM_PBRevision.GetValue(key, revision);
	return revision;
}

bool GetStoredPB(int client, int mode, int recordType, const char[] mapName, float &time, int &points, char[] dateOnly, int dateLength)
{
	char key[256];
	BuildPBKey(client, mode, recordType, mapName, key, sizeof(key));

	any value;
	if (!gSM_PBTime.GetValue(key, value))
	{
		return false;
	}

	time = view_as<float>(value);
	if (!gSM_PBPoints.GetValue(key, value))
	{
		points = 0;
	}
	else
	{
		points = value;
	}

	if (!gSM_PBDate.GetString(key, dateOnly, dateLength))
	{
		dateOnly[0] = '\0';
	}

	return true;
}

void ClearClientPBStorage(int client)
{
	// PB keys include Steam account ID, so stale entries cannot leak across clients.
	if (client <= 0)
	{
		return;
	}
}

void BuildPBKey(int client, int mode, int recordType, const char[] mapName, char[] key, int keyLength)
{
	Format(key, keyLength, "%d|%d|%d|%s", GetSteamAccountID(client), mode, recordType, mapName);
}



// =====[ FORMAT HELPERS ]=====

void FallbackTierCommand(int client)
{
	if (!IsValidClient(client))
	{
		return;
	}

	gB_TierFallbackCommand[client] = true;
	FakeClientCommand(client, "sm_tier");
}

int GetClientMode(int client)
{
	int mode = GOKZ_GetCoreOption(client, Option_Mode);
	if (IsSupportedRecordsMode(mode))
	{
		return mode;
	}

	return Mode_KZTimer;
}

bool IsSupportedRecordsMode(int mode)
{
	return (mode >= Mode_Vanilla && mode <= Mode_KZTimer)
		|| (mode == 3 && FindPluginByFile("gokz-mode-noperfkz.smx") != null);
}

void GetCurrentDisplayMap(char[] mapName, int maxLength)
{
	GetCurrentMap(mapName, maxLength);
	GetMapDisplayName(mapName, mapName, maxLength);
}

void GetRecordTypeName(int recordType, char[] buffer, int maxLength)
{
	if (recordType == GOKZ_TOP_RECORD_TYPE_PRO)
	{
		strcopy(buffer, maxLength, "PRO");
	}
	else
	{
		strcopy(buffer, maxLength, "NUB");
	}
}

void GetRecordTypeDisplay(int recordType, char[] buffer, int maxLength)
{
	if (recordType == GOKZ_TOP_RECORD_TYPE_PRO)
	{
		strcopy(buffer, maxLength, "{blue}PRO");
	}
	else
	{
		strcopy(buffer, maxLength, "{gold}NUB");
	}
}

void FormatTierDisplay(int tier, char[] buffer, int maxLength)
{
	char color[32];
	GetTierColor(tier, color, sizeof(color));
	Format(buffer, maxLength, "%sT%d{default}", color, tier);
}

void GetTierColor(int tier, char[] buffer, int maxLength)
{
	switch (tier)
	{
		case 1: strcopy(buffer, maxLength, "{lightgreen}");
		case 2: strcopy(buffer, maxLength, "{green}");
		case 3: strcopy(buffer, maxLength, "{yellow}");
		case 4: strcopy(buffer, maxLength, "{gold}");
		case 5: strcopy(buffer, maxLength, "{lightred}");
		case 6: strcopy(buffer, maxLength, "{red}");
		case 7: strcopy(buffer, maxLength, "{purple}");
		case 8: strcopy(buffer, maxLength, "{orchid}");
		default: strcopy(buffer, maxLength, "{grey}");
	}
}

void ISODateOnly(const char[] value, char[] out, int maxLength)
{
	strcopy(out, maxLength, value);
	int tpos = FindCharInString(out, 'T');
	if (tpos > 0)
	{
		out[tpos] = '\0';
	}
}

void FormatDateShort(const char[] ymd, char[] out, int maxLength)
{
	if (strlen(ymd) < 10)
	{
		strcopy(out, maxLength, ymd);
		return;
	}

	char parts[3][5];
	int count = ExplodeString(ymd, "-", parts, 3, sizeof(parts[]));
	if (count != 3)
	{
		strcopy(out, maxLength, ymd);
		return;
	}

	int month = StringToInt(parts[1]);
	char monthName[4];
	switch (month)
	{
		case 1: strcopy(monthName, sizeof(monthName), "Jan");
		case 2: strcopy(monthName, sizeof(monthName), "Feb");
		case 3: strcopy(monthName, sizeof(monthName), "Mar");
		case 4: strcopy(monthName, sizeof(monthName), "Apr");
		case 5: strcopy(monthName, sizeof(monthName), "May");
		case 6: strcopy(monthName, sizeof(monthName), "Jun");
		case 7: strcopy(monthName, sizeof(monthName), "Jul");
		case 8: strcopy(monthName, sizeof(monthName), "Aug");
		case 9: strcopy(monthName, sizeof(monthName), "Sep");
		case 10: strcopy(monthName, sizeof(monthName), "Oct");
		case 11: strcopy(monthName, sizeof(monthName), "Nov");
		case 12: strcopy(monthName, sizeof(monthName), "Dec");
		default: strcopy(monthName, sizeof(monthName), parts[1]);
	}

	Format(out, maxLength, "%s. %s %s", parts[2], monthName, parts[0]);
}

void FormatDateForClient(int client, const char[] ymd, char[] out, int maxLength)
{
	if (IsClientLanguageChinese(client))
	{
		strcopy(out, maxLength, ymd);
		return;
	}

	FormatDateShort(ymd, out, maxLength);
}

bool IsClientLanguageChinese(int client)
{
	char language[32];
	GetNormalizedClientLanguage(client, language, sizeof(language));
	return StrEqual(language, "chi", false);
}

void GetNormalizedClientLanguage(int client, char[] buffer, int maxLength)
{
	int language = GetClientLanguage(client);
	if (language < 0)
	{
		strcopy(buffer, maxLength, "en");
		return;
	}

	GetLanguageInfo(language, buffer, maxLength);
	NormalizeRecordClientLanguage(buffer, buffer, maxLength);
	if (buffer[0] == '\0')
	{
		strcopy(buffer, maxLength, "en");
	}
}

void NormalizeRecordClientLanguage(const char[] input, char[] buffer, int maxLength)
{
	if (StrEqual(input, "chi", false)
		|| StrEqual(input, "zh", false)
		|| StrEqual(input, "zho", false)
		|| StrEqual(input, "schinese", false)
		|| StrEqual(input, "tchinese", false)
		|| StrEqual(input, "chinese", false))
	{
		strcopy(buffer, maxLength, "chi");
		return;
	}

	strcopy(buffer, maxLength, input);
}

int FormatDuration(char[] buffer, int maxLength, float duration)
{
	int hours = RoundToFloor(duration / 3600.0);
	duration -= hours * 3600.0;
	int minutes = RoundToFloor(duration / 60.0);
	duration -= minutes * 60.0;
	int seconds = RoundToFloor(duration);
	duration -= seconds;
	int centiseconds = RoundToFloor(duration * 100.0);

	if (hours > 0)
	{
		return Format(buffer, maxLength, "%02d:%02d:%02d.%02d", hours, minutes, seconds, centiseconds);
	}
	if (minutes > 0)
	{
		return Format(buffer, maxLength, "%02d:%02d.%02d", minutes, seconds, centiseconds);
	}
	return Format(buffer, maxLength, "%02d.%02d", seconds, centiseconds);
}

int FormatDurationDiff(char[] buffer, int maxLength, float duration)
{
	// Round the gap once using integer centiseconds, avoiding float subtraction
	// turning an exact displayed 5.78-second gap into 5.77.
	int centiseconds = RoundToNearest(duration * 100.0);
	int seconds = centiseconds / 100;
	if (seconds >= 3600)
	{
		return Format(buffer, maxLength, "%02d:%02d:%02d.%02d", seconds / 3600, (seconds / 60) % 60, seconds % 60, centiseconds % 100);
	}
	if (seconds >= 60)
	{
		return Format(buffer, maxLength, "%02d:%02d.%02d", seconds / 60, seconds % 60, centiseconds % 100);
	}
	return Format(buffer, maxLength, "%02d.%02d", seconds, centiseconds % 100);
}

void URLEncode(const char[] input, char[] output, int maxLength)
{
	static char hex[] = "0123456789ABCDEF";
	int written = 0;
	for (int i = 0; input[i] != '\0' && written < maxLength - 1; i++)
	{
		int c = input[i];
		if ((c >= 'a' && c <= 'z')
			|| (c >= 'A' && c <= 'Z')
			|| (c >= '0' && c <= '9')
			|| c == '-' || c == '_' || c == '.' || c == '~')
		{
			output[written++] = c;
		}
		else if (written < maxLength - 3)
		{
			output[written++] = '%';
			output[written++] = hex[(c >> 4) & 0xF];
			output[written++] = hex[c & 0xF];
		}
	}
	output[written] = '\0';
}

// Run mode 3 is NKZ; leaderboard scope 3 is OVR. NKZ PBs use KZT.
void GetRecordsScopeForMode(int mode, char[] scope, int maxLength)
{
	GetLeaderboardScopeForMode(mode == 3 ? Mode_KZTimer : mode, scope, maxLength);
}
