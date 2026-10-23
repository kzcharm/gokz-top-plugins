static char sCvars[][] = {"sv_cheats", "sv_clamp_unsafe_velocities", "mp_drop_knife_enable", "sv_autobunnyhopping", "sv_minupdaterate", "sv_maxupdaterate", "sv_mincmdrate", "sv_maxcmdrate", "sv_client_cmdrate_difference", "sv_turbophysics"};
static float sValues[] = {0.0, 0.0, 0.0, 0.0, 128.0, 128.0, 128.0, 128.0, 0.0, 0.0};
static bool sClientChecked[MAXPLAYERS + 1], sClientGood[MAXPLAYERS + 1], sYawChecked[MAXPLAYERS + 1], sYawGood[MAXPLAYERS + 1];

void Validation_Init()
{
	for (int i = 0; i < sizeof(sCvars); i++)
	{
		ConVar cvar = FindConVar(sCvars[i]);
		if (cvar != null) cvar.AddChangeHook(OnSettingChanged);
	}
	AddCommandListener(OnUnsafeCommand, "sm_slap");
	AddCommandListener(OnUnsafeCommand, "sm_beacon");
}

void InvalidateAll()
{
	for (int client = 1; client <= MaxClients; client++) gValid[client] = false;
}

bool ServerSettingsValid()
{
	if (FloatAbs(GetTickInterval() - 1.0 / 128.0) > 0.000001) return false;
	for (int i = 0; i < sizeof(sCvars); i++)
	{
		ConVar cvar = FindConVar(sCvars[i]);
		if (cvar == null || cvar.FloatValue != sValues[i]) return false;
	}
	return LibraryExists("gokz-anticheat") && LibraryExists("movementapi");
}

public void OnSettingChanged(ConVar cvar, const char[] oldValue, const char[] newValue)
{
	if (!ServerSettingsValid()) InvalidateAll();
}

public Action OnUnsafeCommand(int client, const char[] command, int argc)
{
	InvalidateAll();
	return Plugin_Continue;
}

public void OnClientPutInServer(int client)
{
	sClientChecked[client] = false;
	sClientGood[client] = false;
	sYawChecked[client] = false;
	sYawGood[client] = false;
}

void QueryClientSettings(int client)
{
	QueryClientConVar(client, "fps_max", OnFPSChecked, GetClientSerial(client));
	QueryClientConVar(client, "m_yaw", OnYawChecked, GetClientSerial(client));
}

public void OnFPSChecked(QueryCookie cookie, int client, ConVarQueryResult result, const char[] name, const char[] value, any serial)
{
	if (GetClientFromSerial(serial) != client) return;
	float fps = StringToFloat(value);
	sClientChecked[client] = result == ConVarQuery_Okay;
	sClientGood[client] = result == ConVarQuery_Okay && (fps == 0.0 || fps >= 120.0);
	if (!sClientGood[client]) gValid[client] = false;
}

public void OnYawChecked(QueryCookie cookie, int client, ConVarQueryResult result, const char[] name, const char[] value, any serial)
{
	if (GetClientFromSerial(serial) != client) return;
	sYawChecked[client] = result == ConVarQuery_Okay;
	sYawGood[client] = result == ConVarQuery_Okay && FloatAbs(StringToFloat(value)) <= 0.3;
	if (!sYawGood[client])
	{
		sClientGood[client] = false;
		gValid[client] = false;
	}
}

public void GOKZ_OnOptionChanged(int client, const char[] option, any value)
{
	if (StrEqual(option, gC_CoreOptionNames[Option_Mode]) || StrEqual(option, gC_CoreOptionNames[Option_Style])) gValid[client] = false;
}

public void GOKZ_OnModeUnloaded(int mode)
{
	for (int client = 1; client <= MaxClients; client++)
	{
		if (gMode[client] == mode) gValid[client] = false;
	}
}

public void GOKZ_AC_OnPlayerSuspected(int client, ACReason reason, const char[] notes, const char[] stats)
{
	gValid[client] = false;
}

public void GOKZ_OnTimerStopped(int client)
{
	gRun[client] = false;
}

bool ClientSettingsValid(int client)
{
	return sClientChecked[client] && sClientGood[client] && sYawChecked[client] && sYawGood[client];
}
