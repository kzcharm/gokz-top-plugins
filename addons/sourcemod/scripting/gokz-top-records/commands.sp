#define CheckMark(%1) ((%1) ? "{green}✓" : "{darkred}X")

public Action Command_Queue(int client, int args)
{
	if (args > 0)
	{
		char id[37], query[256];
		GetCmdArg(1, id, sizeof(id));
		if (!IsRecordUUID(id)) { ReplyToCommand(client, "[gokz.top] Supply a record UUID."); return Plugin_Handled; }
		Format(query, sizeof(query), "SELECT environment,server,state,attempts,next,error,payload FROM jobs WHERE id='%s'", id);
		DBResultSet row = SQL_Query(gDB, query);
		if (row != null && row.FetchRow())
		{
			char value[4096];
			for (int column = 0; column < 7; column++)
			{
				row.FetchString(column, value, sizeof(value));
				ReplyToCommand(client, "[gokz.top] %d: %s", column, value);
			}
		}
		delete row;
		return Plugin_Handled;
	}
	char environment[512], key[256], server[37];
	GOKZTop_GetHTTPConfig(environment, sizeof(environment), key, sizeof(key));
	gCV_Server.GetString(server, sizeof(server));
	ReplyToCommand(client, "[gokz.top] API=%s server=%s credentials=%s busy=%d last=%s", environment, server, key[0] ? "configured" : "missing", gBusy, gLastStatus);
	ReplyToCommand(client, "[gokz.top] Queue summary (use sm_toprecords_queue UUID for details):");
	DBResultSet rows = SQL_Query(gDB, "SELECT state,count(*) FROM jobs GROUP BY state");
	while (rows != null && rows.FetchRow())
	{
		char state[32]; rows.FetchString(0, state, sizeof(state));
		ReplyToCommand(client, "[gokz.top] %s: %d", state, rows.FetchInt(1));
	}
	delete rows;
	return Plugin_Handled;
}

public Action Command_Retry(int client, int args)
{
	Queue_SQL("UPDATE jobs SET state=CASE WHEN canonical='' THEN 'record' ELSE 'accepted' END,next=0,attempts=0 WHERE state IN ('rejected','auth')");
	ReplyToCommand(client, "[gokz.top] Retained failed jobs are ready to retry in their original environment.");
	return Plugin_Handled;
}

public Action Command_Check(int client, int args)
{
	if (client <= 0) return Command_Queue(client, args);
	JSON_Object body = Capture_Check(client, GOKZ_GetCourse(client));
	if (body == null)
	{
		PrintCheckUnavailable(client);
		return Plugin_Handled;
	}
	char payload[4096], environment[512], key[256], url[768];
	json_encode(body, payload, sizeof(payload)); body.Cleanup(); delete body;
	GOKZTop_GetHTTPConfig(environment, sizeof(environment), key, sizeof(key));
	GOKZ_PrintToChat(client, false, "%sRecords Availability Check", GOKZ_TOP_CHAT_PREFIX);
	Format(url, sizeof(url), "%s/v1/records/check", environment);
	Handle request = SteamWorks_CreateHTTPRequest(k_EHTTPMethodPOST, url);
	if (request == null)
	{
		PrintCheckUnavailable(client);
		return Plugin_Handled;
	}
	SteamWorks_SetHTTPRequestHeaderValue(request, "X-Server-Group-Key", key);
	SteamWorks_SetHTTPRequestRawPostBody(request, "application/json", payload, strlen(payload));
	SteamWorks_SetHTTPRequestContextValue(request, GetClientSerial(client));
	SteamWorks_SetHTTPCallbacks(request, OnCheckComplete);
	SteamWorks_SetHTTPRequestAbsoluteTimeoutMS(request, 10000);
	if (!SteamWorks_SendHTTPRequest(request))
	{
		delete request;
		PrintCheckUnavailable(client);
	}
	return Plugin_Handled;
}

public void OnCheckComplete(Handle request, bool failure, bool successful, EHTTPStatusCode statusCode, any serial)
{
	int client = GetClientFromSerial(serial);
	if (client)
	{
		char response[4096];
		HTTP_ReadBody(request, response, sizeof(response));
		PrintToConsole(client, "GOKZ.TOP | HTTP %d: %s", statusCode, response);
		JSON_Object body = json_decode(response);
		JSON_Object checks = body != null ? body.GetObject("checks") : null;
		if (!failure && successful && statusCode == k_EHTTPStatusCode200OK && checks != null)
		{
			GOKZ_PrintToChat(client, false, "%sAPI Key %s {grey}| Server %s {grey}| Group %s", GOKZ_TOP_CHAT_PREFIX,
				CheckMark(checks.GetBool("authentication")), CheckMark(checks.GetBool("server")), CheckMark(checks.GetBool("group")));
			GOKZ_PrintToChat(client, false, "%sMap %s {grey}| Course %s {grey}| Filter %s {grey}| You %s", GOKZ_TOP_CHAT_PREFIX,
				CheckMark(checks.GetBool("map")), CheckMark(checks.GetBool("course")), CheckMark(checks.GetBool("filter")), CheckMark(checks.GetBool("player")));
			GOKZ_PrintToChat(client, false, "%sMode %s {grey}| Integrity %s {grey}| API {green}✓", GOKZ_TOP_CHAT_PREFIX,
				CheckMark(checks.GetBool("mode")), CheckMark(checks.GetBool("integrity")));
		}
		else PrintCheckUnavailable(client);
		if (body != null) body.Cleanup();
		delete body;
		DBResultSet queue = SQL_Query(gDB, "SELECT count(*) FROM jobs WHERE state NOT IN ('done','rejected')");
		int pending;
		if (queue != null && queue.FetchRow()) pending = queue.FetchInt(0);
		delete queue;
		GOKZ_PrintToChat(client, false, "%sQueued: {purple}%d {grey}| Details in console", GOKZ_TOP_CHAT_PREFIX, pending);
	}
	delete request;
}

static void PrintCheckUnavailable(int client)
{
	GOKZ_PrintToChat(client, false, "%sAPI {darkred}X {grey}| Eligibility unavailable. Details in console.", GOKZ_TOP_CHAT_PREFIX);
}
