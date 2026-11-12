#include <sourcemod>
#include <sdktools>
#include <cstrike>
#pragma newdecls required
#pragma semicolon 1

char gC_Owner[MAXPLAYERS + 1][32];
int gI_ProbeUserId, gI_Assertions;
#include "../addons/sourcemod/scripting/optional/gokz-top-web-bridge/identity.sp"

public Plugin myinfo = {name="Web bridge identity regression", author="GOKZ.TOP", version="1"};

bool IsMirror(int client)
{
	return client > 0 && client <= MaxClients && gC_Owner[client][0] && IsClientInGame(client) && IsFakeClient(client);
}

void Check(bool condition, const char[] label)
{
	if (!condition) SetFailState("web-bridge-identity-test: %s", label);
	gI_Assertions++;
}

public void OnPluginStart()
{
	int account;
	Check(Steam64ToAccount("76561197960265729", account) && account == 1, "minimum account");
	Check(Steam64ToAccount("76561199022242128", account) && account == 1061976400, "normal account");
	Check(Steam64ToAccount("76561200107749376", account) && account == -2147483648, "unsigned high bit");
	Check(Steam64ToAccount("76561202255233023", account) && account == -1, "maximum account");
	Check(!Steam64ToAccount("76561202255233024", account), "overflow rejected");
	Check(!Steam64ToAccount("76561197960265728", account), "zero rejected");
	Check(!Steam64ToAccount("7656119796026572x", account), "non-digit rejected");
	Check(!Steam64ToAccount("7656119796026572", account), "short ID rejected");
	Check(!Steam64ToAccount("99999999999999999", account), "invalid identity rejected");
	char source[PLAYER_INFO_MAX], target[PLAYER_INFO_MAX];
	for (int i; i < PLAYER_INFO_MAX; i++) { source[i] = 90; target[i] = 165; }
	CopyIdentityFields(source, target);
	for (int i; i < PLAYER_INFO_MAX; i++)
	{
		bool identity = (i >= 8 && i < 16) || (i >= 148 && i < 181) || (i >= 184 && i < 188) || i == 316;
		Check(target[i] == (identity ? 90 : 165), "only identity fields restored");
	}
	PrintToServer("[web-bridge-identity-test] PASS assertions=%d", gI_Assertions);
	RegServerCmd("sm_bridge_identity_test", Probe);
	CreateTimer(0.1, Refresh, _, TIMER_REPEAT);
}

public Action Refresh(Handle timer)
{
	RefreshMirrorIdentities(0);
	return Plugin_Continue;
}

public Action Probe(int args)
{
	char id[32]; int account;
	GetCmdArg(1, id, sizeof(id));
	if (args != 1 || !Steam64ToAccount(id, account)) return Plugin_Handled;
	int bot = GetClientOfUserId(gI_ProbeUserId);
	if (!bot)
	{
		bot = CreateFakeClient("[Web] Avatar identity test");
		Check(bot != 0, "test bot created");
		gI_ProbeUserId = GetClientUserId(bot);
		CS_SwitchTeam(bot, CS_TEAM_CT);
		CS_RespawnPlayer(bot);
		SetEntityMoveType(bot, MOVETYPE_NONE);
	}
	strcopy(gC_Owner[bot], sizeof(gC_Owner[]), id);
	UpdateMirrorIdentity(bot);
	char info[PLAYER_INFO_MAX], auth[32];
	GetStringTableData(FindStringTable("userinfo"), bot - 1, info, sizeof(info));
	bool duplicate = NativeIdentityConnected(id);
	Check(info[316] == (duplicate ? 1 : 0), "native identity collision guard");
	GetClientAuthId(bot, AuthId_Steam2, auth, sizeof(auth), false);
	Check(IsFakeClient(bot) && StrEqual(auth, "BOT") && GetSteamAccountID(bot, false) == 0, "server identity stays bot");
	PrintToServer("[web-bridge-identity-test] PASS userid=%d duplicate=%d wire_fake=%d wire_auth=%s engine_auth=%s",
		gI_ProbeUserId, duplicate, info[316] & 255, info[148], auth);
	return Plugin_Handled;
}

public void OnClientAuthorized(int client, const char[] auth)
{
	if (!IsFakeClient(client)) RefreshMirrorIdentities(0);
}

public void OnClientDisconnect(int client)
{
	gC_Owner[client][0] = 0;
	ResetMirrorIdentity(client);
	RequestFrame(RefreshMirrorIdentities);
}

public void OnPluginEnd()
{
	int bot = GetClientOfUserId(gI_ProbeUserId);
	if (bot && IsClientInGame(bot) && IsFakeClient(bot)) KickClient(bot, "Avatar test completed");
}
