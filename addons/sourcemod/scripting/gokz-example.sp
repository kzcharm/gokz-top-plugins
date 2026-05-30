#include <sourcemod>
#include <sdktools>

#include <gokz/core>

#include <autoexecconfig>

#pragma newdecls required
#pragma semicolon 1



public Plugin myinfo =
{
	name = "GOKZ Example",
	author = "Cinyan10",
	description = "Example GOKZ extension plugin template",
	version = GOKZ_VERSION,
	url = GOKZ_SOURCE_URL
};

bool gB_GOKZCoreReady;
ConVar gCV_gokz_example_broadcast_to_specs;

#include "gokz-example/convars.sp"
#include "gokz-example/options.sp"
#include "gokz-example/commands.sp"
#include "gokz-example/options_menu.sp"
#include "gokz-example/summary.sp"



// =====[ PLUGIN EVENTS ]=====

public APLRes AskPluginLoad2(Handle myself, bool late, char[] error, int err_max)
{
	RegPluginLibrary("gokz-example");
	return APLRes_Success;
}

public void OnPluginStart()
{
	LoadTranslations("common.phrases");
	LoadTranslations("gokz-common.phrases");
	LoadTranslations("gokz-example.phrases");

	CreateConVars();
	RegisterCommands();
}

public void OnAllPluginsLoaded()
{
	gB_GOKZCoreReady = LibraryExists("gokz-core");

	if (gB_GOKZCoreReady)
	{
		OnGOKZCoreReady();
	}
}

public void OnLibraryAdded(const char[] name)
{
	if (!gB_GOKZCoreReady && StrEqual(name, "gokz-core"))
	{
		gB_GOKZCoreReady = true;
		OnGOKZCoreReady();
	}
}

public void OnLibraryRemoved(const char[] name)
{
	if (StrEqual(name, "gokz-core"))
	{
		gB_GOKZCoreReady = false;
		ResetOptionsMenu();
	}
}



// =====[ GOKZ EVENTS ]=====

public void GOKZ_OnTimerEnd_Post(int client, int course, float time, int teleportsUsed)
{
	OnTimerEnd_Summary(client, course, time, teleportsUsed);
}

public void GOKZ_OnOptionChanged(int client, const char[] option, any newValue)
{
	OnOptionChanged_Options(client, option, newValue);
}

public void GOKZ_OnOptionsMenuReady(TopMenu topMenu)
{
	OnOptionsMenuReady_Options();
	OnOptionsMenuReady_OptionsMenu(topMenu);
}



// =====[ PRIVATE ]=====

void OnGOKZCoreReady()
{
	OnOptionsMenuReady_Options();

	TopMenu topMenu = GOKZ_GetOptionsTopMenu();
	if (topMenu != null)
	{
		GOKZ_OnOptionsMenuReady(topMenu);
	}
}
