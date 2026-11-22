#if defined _axekz_autosafe_included
 #endinput
#endif
#define _axekz_autosafe_included

#include <gokz/core>

native bool AutoSafe_IsRunProtected(int client);

public SharedPlugin __pl_autosafe =
{
	name = "gokz-autosafe",
	file = "gokz-autosafe.smx",
	required = 0
};

public void __pl_autosafe_SetNTVOptional()
{
	MarkNativeAsOptional("AutoSafe_IsRunProtected");
}

stock bool AutoSafe_CheckRun(int client)
{
	if (GetFeatureStatus(FeatureType_Native, "AutoSafe_IsRunProtected") == FeatureStatus_Available)
	{
		return AutoSafe_IsRunProtected(client);
	}
	return GOKZ_GetCoreOption(client, Option_Safeguard) > Safeguard_Disabled
		&& GOKZ_GetTimerRunning(client) && GOKZ_GetValidTimer(client);
}
