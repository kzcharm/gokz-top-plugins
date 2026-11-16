#include <sourcemod>
#include <ripext>
#include <SteamWorks>
#pragma newdecls required
#pragma semicolon 1
#pragma dynamic 5242880

char gC_URL[512], gC_Key[128] = "fixture-not-a-secret", gC_Server[256] = "fixture:10000";
int gI_Epoch = 1, gI_Step, gI_Callbacks, gI_Assertions;
bool gB_Enabled = true;
#include "../addons/sourcemod/scripting/optional/gokz-top-web-bridge/http.sp"

public Plugin myinfo = {name="Web bridge HTTP regression", author="GOKZ.TOP", version="1"};

void Check(bool condition, const char[] label)
{
	if (!condition) SetFailState("web-bridge-http-test: %s (step %d)", label, gI_Step);
	gI_Assertions++;
}

public void OnPluginStart()
{
	CreateTimer(0.1, Next);
}

public Action Next(Handle timer)
{
	static const char paths[][] = {"ok", "error", "empty", "reset", "timeout", "large", "ok", "disabled", "ok", "redirect", "waiting"};
	if (gI_Step == sizeof(paths))
	{
		Check(gI_Callbacks == 9, "stale and disable responses never reach frame handler");
		Check(gH_Request == null && gH_DisableRequest == null, "all completed handles released");
		Check(gI_Requests == 11 && gI_Waits == 1, "active and idle request counters");
		PrintToServer("[web-bridge-http-test] PASS assertions=%d callbacks=%d", gI_Assertions, gI_Callbacks);
		return Plugin_Stop;
	}
	FormatEx(gC_URL, sizeof(gC_URL), "http://127.0.0.1:18093/%s", paths[gI_Step]);
	JSONObject body = new JSONObject();
	body.SetInt("step", gI_Step);
	body.SetBool("enabled", gI_Step != 7);
	body.SetBool("wait", gI_Step == 10);
	if (gI_Step == 5)
	{
		char[] large = new char[150001];
		for (int i; i < 150000; i++) large[i] = 'x';
		large[150000] = 0;
		body.SetString("padding", large);
		body.SetString("unicode", "玩家 ✓");
	}
	if (gI_Step == 7) gH_DisableRequest = SendBridgeRequest(body, true);
	else gH_Request = SendBridgeRequest(body, false, gI_Step == 10);
	delete body;
	Check((gI_Step == 7 ? gH_DisableRequest : gH_Request) != null, "request dispatched");
	if (gI_Step == 6 || gI_Step == 7)
	{
		gI_Epoch++;
		CreateTimer(1.0, CheckIgnored);
	}
	return Plugin_Stop;
}

public Action CheckIgnored(Handle timer)
{
	Check(gH_Request == null && gH_DisableRequest == null, "stale/disable handle released");
	gI_Step++;
	CreateTimer(0.1, Next);
	return Plugin_Stop;
}

void OnFrame(int status, const char[] error, const char[] payload)
{
	gI_Callbacks++;
	Check(gH_Request == null, "request released before frame handler");
	switch (gI_Step)
	{
		case 0, 5, 8, 10:
		{
			Check(status == 200 && !error[0] && payload[0], "success and recovery");
			JSONObject frame = JSONObject.FromString(payload);
			Check(frame.GetBool("ok"), "valid JSON response");
			delete frame;
		}
		case 1: Check(status == 503 && error[0] && !payload[0], "HTTP failure");
		case 2: Check(status == 200 && error[0] && !payload[0], "empty response");
		case 3, 4: Check(error[0] && !payload[0], "reset/timeout failure");
		case 9: Check(status == 200 && !error[0] && payload[0], "SteamWorks follows redirects");
		default: Check(false, "ignored callback entered frame handler");
	}
	gI_Step++;
	CreateTimer(0.1, Next);
}

public void OnPluginEnd()
{
	delete gH_Request;
	delete gH_DisableRequest;
}
