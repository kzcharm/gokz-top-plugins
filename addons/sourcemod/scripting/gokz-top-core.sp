// gokz-top-core
// Shared core plugin for GOKZ Top SourceMod plugins.
//
// Responsibilities:
// - Provide ConVars:
//   - gokz_top_base_url (in cfg/sourcemod/gokz-top/gokz-top-core.cfg)
//   - gokz_top_apikey   (in cfg/sourcemod/gokz-top/apikey.cfg)
// - Ensure both config files exist (AutoExecConfig)

#include <sourcemod>
#include <autoexecconfig>

#pragma semicolon 1
#pragma newdecls required

public Plugin myinfo =
{
    name        = "GOKZTop Core",
    author      = "Cinyan10",
    description = "Core utilities/config for gokz-top plugins",
    version     = "0.1.0"
};

static ConVar gCvarBaseUrl;
static ConVar gCvarApiKey;

public void OnPluginStart()
{
    // Set up main config file: cfg/sourcemod/gokz-top/gokz-top-core.cfg
    // Note: AutoExecConfig_SetCreateDirectory will create cfg/sourcemod/gokz-top/
    // since cfg/sourcemod/ should already exist
    AutoExecConfig_SetFile("gokz-top-core", "sourcemod/gokz-top");
    AutoExecConfig_SetCreateFile(true);
    AutoExecConfig_SetCreateDirectory(true);

    gCvarBaseUrl = AutoExecConfig_CreateConVar(
        "gokz_top_base_url",
        "https://api.gokz.top",
        "Base URL for GOKZTop API (no trailing slash recommended)",
        FCVAR_PROTECTED
    );

    // Execute and clean up the main config file
    AutoExecConfig_ExecuteFile();
    AutoExecConfig_CleanFile();

    // Set up API key config file: cfg/sourcemod/gokz-top/apikey.cfg
    AutoExecConfig_SetFile("apikey", "sourcemod/gokz-top");
    AutoExecConfig_SetCreateFile(true);
    AutoExecConfig_SetCreateDirectory(true);

    gCvarApiKey = AutoExecConfig_CreateConVar(
        "gokz_top_apikey",
        "",
        "GOKZTop API key used by server-side plugins. Set in cfg/sourcemod/gokz-top/apikey.cfg",
        FCVAR_PROTECTED
    );

    // Execute and clean up the API key config file
    AutoExecConfig_ExecuteFile();
    AutoExecConfig_CleanFile();

    // Optional: execute both configs explicitly to ensure they apply even if autoexec is disabled.
    ServerCommand("exec sourcemod/gokz-top/gokz-top-core.cfg");
    ServerCommand("exec sourcemod/gokz-top/apikey.cfg");

    // Gentle hint if missing
    CreateTimer(3.0, Timer_AnnounceIfMissing, _, TIMER_FLAG_NO_MAPCHANGE);
}

public Action Timer_AnnounceIfMissing(Handle timer)
{
    if (gCvarApiKey != null)
    {
        char apiKey[128];
        gCvarApiKey.GetString(apiKey, sizeof(apiKey));
        TrimString(apiKey);
        if (apiKey[0] == '\0')
        {
            LogMessage("[gokz-top-core] API key not set. Edit cfg/sourcemod/gokz-top/apikey.cfg and set gokz_top_apikey.");
        }
    }
    return Plugin_Stop;
}


