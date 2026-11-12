#define PLAYER_INFO_MAX 344
char gC_BotIdentity[MAXPLAYERS + 1][PLAYER_INFO_MAX];
bool gB_SavedIdentity[MAXPLAYERS + 1], gB_UnsupportedIdentity[MAXPLAYERS + 1];

bool Steam64ToAccount(const char[] steamId, int &account)
{
	if (strlen(steamId) != 17) return false;
	for (int i; i < 17; i++)
		if (steamId[i] < '0' || steamId[i] > '9') return false;
	if (strcmp(steamId, "76561197960265729") < 0 || strcmp(steamId, "76561202255233023") > 0) return false;
	char high[9];
	strcopy(high, sizeof(high), steamId);
	// The validated unsigned account ID intentionally wraps into a 32-bit cell.
	account = (StringToInt(high) - 76561197) * 1000000000 + StringToInt(steamId[8]) - 960265728;
	return true;
}

bool NativeIdentityConnected(const char[] steamId)
{
	for (int i = 1; i <= MaxClients; i++)
	{
		char id[32];
		if (IsClientConnected(i) && !IsFakeClient(i) && IsClientAuthorized(i)
			&& GetClientAuthId(i, AuthId_SteamID64, id, sizeof(id)) && StrEqual(id, steamId)) return true;
	}
	return false;
}

void CopyIdentityFields(const char[] source, char[] target)
{
	for (int i = 8; i < 16; i++) target[i] = source[i];
	for (int i = 148; i < 181; i++) target[i] = source[i];
	for (int i = 184; i < 188; i++) target[i] = source[i];
	target[316] = source[316];
}

void UpdateMirrorIdentity(int bot)
{
	if (!IsMirror(bot) || gB_UnsupportedIdentity[bot]) return;
	int account;
	if (!Steam64ToAccount(gC_Owner[bot], account)) return;
	int table = FindStringTable("userinfo");
	if (table == INVALID_STRING_TABLE) return;
	int length = GetStringTableDataLength(table, bot - 1);
	if (!length) return;
	char current[PLAYER_INFO_MAX], desired[PLAYER_INFO_MAX];
	if (length != 340 && length != 344)
	{
		gB_UnsupportedIdentity[bot] = true;
		LogError("Skipping Web avatar: unsupported userinfo size %d", length);
		return;
	}
	GetStringTableData(table, bot - 1, current, sizeof(current));
	if (!gB_SavedIdentity[bot])
	{
		int userid = (current[144] << 24) | (current[145] << 16) | (current[146] << 8) | current[147];
		if (userid != GetClientUserId(bot) || !StrEqual(current[148], "BOT") || current[316] != 1 || current[317] != 0)
		{
			gB_UnsupportedIdentity[bot] = true;
			LogError("Skipping Web avatar: unexpected userinfo fields for bot %d", bot);
			return;
		}
		CopyIdentityFields(current, gC_BotIdentity[bot]);
		gB_SavedIdentity[bot] = true;
	}
	for (int i; i < length; i++) desired[i] = current[i];
	CopyIdentityFields(gC_BotIdentity[bot], desired);
	if (!NativeIdentityConnected(gC_Owner[bot]))
	{
		desired[8] = 0x01; desired[9] = 0x10; desired[10] = 0x00; desired[11] = 0x01;
		for (int i; i < 4; i++)
		{
			desired[12 + i] = (account >>> ((3 - i) * 8)) & 255;
			desired[184 + i] = desired[12 + i];
		}
		for (int i = 148; i < 181; i++) desired[i] = 0;
		Format(desired[148], 33, "STEAM_1:%d:%d", account & 1, account >>> 1);
		desired[316] = 0;
	}
	for (int i; i < length; i++)
	{
		if (current[i] == desired[i]) continue;
		bool locked = LockStringTables(false);
		SetStringTableData(table, bot - 1, desired, length);
		LockStringTables(locked);
		break;
	}
}

public void RefreshMirrorIdentities(any unused)
{
	for (int i = 1; i <= MaxClients; i++) UpdateMirrorIdentity(i);
}

void ResetMirrorIdentity(int client)
{
	gB_SavedIdentity[client] = false;
	gB_UnsupportedIdentity[client] = false;
}
