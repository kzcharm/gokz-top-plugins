#include <sourcemod>
#include <cstrike>
#include <gokz/core>
#include <gokz/profile>

#pragma newdecls required
#pragma semicolon 1

// Load under two filenames to exercise competing owners. Each copy registers
// its filename as a server command: <userid> [<expected full tag> [suffix [status]]].
public void OnPluginStart()
{
	char filename[PLATFORM_MAX_PATH];
	GetPluginFilename(null, filename, sizeof(filename));
	ReplaceString(filename, sizeof(filename), ".smx", "");
	RegServerCmd(filename, CheckTag);
}

public Action CheckTag(int args)
{
	if (args < 1 || args > 4)
	{
		return Plugin_Handled;
	}
	int client = GetClientOfUserId(GetCmdArgInt(1));
	char expected[64], actual[64], suffix[64];
	if (!client || !IsClientInGame(client) || IsFakeClient(client))
	{
		ThrowError("Expected a connected human userid");
	}
	if (args == 1)
	{
		CS_GetClientClanTag(client, actual, sizeof(actual));
		PrintToServer("Current tag: %s", actual);
		return Plugin_Handled;
	}
	GetCmdArg(2, expected, sizeof(expected));
	if (args >= 3)
	{
		GetCmdArg(3, suffix, sizeof(suffix));
		if (args == 4)
		{
			GOKZ_PF_SetClanTagStatus(client, suffix);
		}
		else
		{
			GOKZ_PF_SetClanTagSuffix(client, suffix);
		}
	}
	CS_GetClientClanTag(client, actual, sizeof(actual));
	if (!StrEqual(expected, actual))
	{
		ThrowError("Expected '%s', got '%s'", expected, actual);
	}
	PrintToServer("PASS %s", actual);
	return Plugin_Handled;
}
