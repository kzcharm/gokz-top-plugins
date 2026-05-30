#define LEGACY_PROFILE_PLUGIN "addons/sourcemod/plugins/gokz-profile.smx"
#define LEGACY_PROFILE_DISABLED_DIR "addons/sourcemod/plugins/disabled"
#define LEGACY_PROFILE_DISABLED_PLUGIN "addons/sourcemod/plugins/disabled/gokz-profile.smx"

void UnloadLegacyProfilePlugin()
{
	ServerCommand("sm plugins unload gokz-profile");
	ServerExecute();
}

bool IsLegacyProfileSurfaceOccupied()
{
	return GetFeatureStatus(FeatureType_Native, "GOKZ_PF_GetRank") == FeatureStatus_Available
		|| LibraryExists("gokz-profile")
		|| FindPluginByFile("gokz-profile.smx") != INVALID_HANDLE
		|| FileExists(LEGACY_PROFILE_PLUGIN);
}

void DisableLegacyProfileBinary()
{
	UnloadLegacyProfilePlugin();

	if (!FileExists(LEGACY_PROFILE_PLUGIN))
	{
		return;
	}

	if (!DirExists(LEGACY_PROFILE_DISABLED_DIR) && !CreateDirectory(LEGACY_PROFILE_DISABLED_DIR, 511))
	{
		LogError("[gokz-top-profile] Failed to create %s", LEGACY_PROFILE_DISABLED_DIR);
		return;
	}

	if (RenameFile(LEGACY_PROFILE_DISABLED_PLUGIN, LEGACY_PROFILE_PLUGIN))
	{
		LogMessage("[gokz-top-profile] Moved legacy gokz-profile.smx to plugins/disabled");
		return;
	}

	LogError("[gokz-top-profile] Failed to move legacy gokz-profile.smx to plugins/disabled");
}
