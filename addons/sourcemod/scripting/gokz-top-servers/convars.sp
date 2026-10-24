void FindRequiredConVars()
{
	gCV_Hostname = FindConVar("hostname");
	gCV_HostPort = FindConVar("hostport");
}

void CreateConVars()
{
	AutoExecConfig_SetCreateDirectory(true);
	AutoExecConfig_SetCreateFile(true);
	AutoExecConfig_SetFile("gokz-top-servers", GOKZ_TOP_CFG_FOLDER);

	gCV_PushInterval = AutoExecConfig_CreateConVar("gokz_top_servers_push_interval", "4.0",
		"Interval in seconds between gokz-top server status heartbeats.", _, true, 2.0, true, 10.0);
	gCV_PushInterval.AddChangeHook(OnPushIntervalChanged);

	AutoExecConfig_ExecuteFile();
	AutoExecConfig_CleanFile();
}

public void OnPushIntervalChanged(ConVar convar, const char[] oldValue, const char[] newValue)
{
	CreateHeartbeatTimer();
}
