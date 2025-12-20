// gokztop-core
// Shared core plugin for GOKZ Top SourceMod plugins.
//
// Responsibilities:
// - Provide ConVars:
//   - gokztop_base_url (in cfg/sourcemod/gokztop/gokztop-core.cfg)
//   - gokztop_apikey   (in cfg/sourcemod/gokztop/apikey.cfg)
// - Ensure both config files exist (AutoExecConfig)

#include <sourcemod>
#include <autoexecconfig>

#pragma semicolon 1
#pragma newdecls required

public Plugin myinfo =
{
    name        = "GOKZTop Core",
    author      = "Cinyan10",
    description = "Core utilities/config for gokztop plugins",
    version     = "0.1.0"
};

static ConVar gCvarBaseUrl;
static ConVar gCvarApiKey;

public void OnPluginStart()
{
    // Set up main config file: cfg/sourcemod/gokztop/gokztop-core.cfg
    // Note: AutoExecConfig_SetCreateDirectory will create cfg/sourcemod/gokztop/
    // since cfg/sourcemod/ should already exist
    AutoExecConfig_SetFile("gokztop-core", "sourcemod/gokztop");
    AutoExecConfig_SetCreateFile(true);
    AutoExecConfig_SetCreateDirectory(true);

    gCvarBaseUrl = AutoExecConfig_CreateConVar(
        "gokztop_base_url",
        "https://api.gokz.top",
        "Base URL for GOKZTop API (no trailing slash recommended)",
        FCVAR_PROTECTED
    );

    // Execute and clean up the main config file
    AutoExecConfig_ExecuteFile();
    AutoExecConfig_CleanFile();

    // Set up API key config file: cfg/sourcemod/gokztop/apikey.cfg
    AutoExecConfig_SetFile("apikey", "sourcemod/gokztop");
    AutoExecConfig_SetCreateFile(true);
    AutoExecConfig_SetCreateDirectory(true);

    gCvarApiKey = AutoExecConfig_CreateConVar(
        "gokztop_apikey",
        "",
        "GOKZTop API key used by server-side plugins. Set in cfg/sourcemod/gokztop/apikey.cfg",
        FCVAR_PROTECTED
    );

    // Execute and clean up the API key config file
    AutoExecConfig_ExecuteFile();
    AutoExecConfig_CleanFile();

    // Optional: execute both configs explicitly to ensure they apply even if autoexec is disabled.
    ServerCommand("exec sourcemod/gokztop/gokztop-core.cfg");
    ServerCommand("exec sourcemod/gokztop/apikey.cfg");

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
            LogMessage("[gokztop-core] API key not set. Edit cfg/sourcemod/gokztop/apikey.cfg and set gokztop_apikey.");
        }
    }
    return Plugin_Stop;
}


