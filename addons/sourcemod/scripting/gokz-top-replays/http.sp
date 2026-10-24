bool JobURL(const char[] path, char[] url, int length)
{
	char suffix[512]; strcopy(suffix, sizeof(suffix), path);
	if (EndsWith(gActiveEnvironment, "/v1") || EndsWith(gActiveEnvironment, "/api/v1")) strcopy(suffix, sizeof(suffix), path[3]);
	return Format(url, length, "%s%s", gActiveEnvironment, suffix) < length - 1;
}

void HTTPNext()
{
	char env[1024], query[1400]; gDB.Escape(gEnvironment, env, sizeof(env));
	Format(query, sizeof(query), "SELECT id,attempts FROM jobs WHERE environment='%s' AND state='pending' AND next<=%d ORDER BY id LIMIT 1", env, GetTime());
	DBResultSet rows = SQL_Query(gDB, query);
	if (rows == null || !rows.FetchRow()) { delete rows; return; }
	gActiveID = rows.FetchInt(0); gAttempts = rows.FetchInt(1) + 1; delete rows;
	strcopy(gActiveEnvironment, sizeof(gActiveEnvironment), gEnvironment);
	char path[PLATFORM_MAX_PATH]; JobPath(gActiveID, path, sizeof(path));
	JumpReplayUploadHeader header;
	if (!ReadJumpReplayUploadHeader(path, header)) { SetJobState(gActiveID, FileExists(path) ? "rejected" : "spooling"); return; }
	Format(query, sizeof(query), "UPDATE jobs SET attempts=%d WHERE id=%d", gAttempts, gActiveID);
	if (!QueueSQL(query)) return;
	char endpoint[512];
	Format(endpoint, sizeof(endpoint), "/v1/jumpstats/replay-eligibility?player_steamid64=%s&mode=%s&type=%s&distance=%s&jumped_at_unix=%d", header.steamID64, header.mode, header.jumpType, header.distanceText, header.timestamp);
	gBusy = true;
	SendJobRequest(false, endpoint);
}

void SendJobRequest(bool upload, const char[] endpoint)
{
	// Never redirect a queued replay or old response to a newly configured API.
	char current[512], key[256]; GOKZTop_GetHTTPConfig(current, sizeof(current), key, sizeof(key));
	int n = strlen(current); if (n && current[n-1] == '/') current[n-1] = '\0';
	if (!StrEqual(current, gActiveEnvironment)) { gBusy = false; return; }
	char url[1024];
	if (!JobURL(endpoint, url, sizeof(url))) { FinishJob(422); return; }
	Handle request = SteamWorks_CreateHTTPRequest(upload ? k_EHTTPMethodPOST : k_EHTTPMethodGET, url);
	if (request == null) { FinishJob(0); return; }
	ApplyCommonHeaders(request, "application/json");
	SteamWorks_SetHTTPRequestHeaderValue(request, "X-Server-Group-Key", key);
	SteamWorks_SetHTTPRequestAbsoluteTimeoutMS(request, gCV_RequestTimeout == null ? 10000 : gCV_RequestTimeout.IntValue * 1000);
	SteamWorks_SetHTTPRequestContextValue(request, upload ? 1 : 0);
	SteamWorks_SetHTTPCallbacks(request, OnJobComplete);
	if (upload)
	{
		char path[PLATFORM_MAX_PATH]; JobPath(gActiveID, path, sizeof(path));
		if (!SteamWorks_SetHTTPRequestRawPostBodyFromFile(request, "application/octet-stream", path))
		{
			delete request; FinishJob(0); return;
		}
	}
	if (!SteamWorks_SendHTTPRequest(request)) { delete request; FinishJob(0); }
}

public void OnJobComplete(Handle request, bool failure, bool requestSuccessful, EHTTPStatusCode statusCode, int upload)
{
	int status = view_as<int>(statusCode);
	if (!IsHTTPResponseOK(failure, requestSuccessful, statusCode))
	{
		delete request; FinishJob(failure || !requestSuccessful ? 0 : status); return;
	}
	if (upload) { delete request; FinishJob(201); return; }
	char response[1024];
	bool read = ReadHTTPResponseBody(request, response, sizeof(response)); delete request;
	JSON_Object body = read ? json_decode(response) : null;
	if (body == null || body.GetKeyType("eligible") != Type_Bool)
	{
		if (body != null) { body.Cleanup(); delete body; }
		FinishJob(0); return;
	}
	bool eligible = body.GetBool("eligible"); body.Cleanup(); delete body;
	if (!eligible) { FinishJob(409); return; }

	SendJobRequest(true, "/v1/jumpstats/replay");
}

void FinishJob(int status)
{
	if (status == 401 || status == 403) SetJobState(gActiveID, "auth", 0, status);
	else if (status == 0 || status == 429 || status >= 500)
	{
		int delay = gAttempts == 1 ? 5 : gAttempts == 2 ? 15 : gAttempts == 3 ? 60 : 300;
		SetJobState(gActiveID, gAttempts >= 8 ? "exhausted" : "pending", GetTime() + delay, status);
	}
	else
	{
		if (SetJobState(gActiveID, status == 201 ? "done" : "rejected", 0, status))
		{
			char path[PLATFORM_MAX_PATH]; JobPath(gActiveID, path, sizeof(path)); DeleteFile(path);
		}
	}
	LogMessage("[gokz-top-replays] job=%d attempt=%d status=%d", gActiveID, gAttempts, status);
	gBusy = false;
}
