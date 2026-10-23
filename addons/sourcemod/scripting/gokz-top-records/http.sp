void HTTP_Next()
{
	char environment[512], key[256], server[37], escaped[1024], query[2048];
	GOKZTop_GetHTTPConfig(environment, sizeof(environment), key, sizeof(key));
	gCV_Server.GetString(server, sizeof(server));
	if (!key[0] || !IsRecordUUID(server)) return;
	if (!StrEqual(key, gAuthKey))
	{
		Queue_SQL("UPDATE jobs SET state=CASE WHEN canonical='' THEN 'record' ELSE 'accepted' END,next=0 WHERE state='auth'");
		strcopy(gAuthKey, sizeof(gAuthKey), key);
	}
	gDB.Escape(environment, escaped, sizeof(escaped));
	Format(query, sizeof(query), "SELECT id,payload,state,canonical,replay,upstream,attempts,eligible,replay_done FROM jobs WHERE environment='%s' AND server='%s' AND state IN ('record','accepted','reconcile','replay') AND next<=%d ORDER BY next,id LIMIT 1", escaped, server, GetTime());
	DBResultSet rows = SQL_Query(gDB, query);
	if (rows == null || !rows.FetchRow()) { delete rows; return; }
	char id[37], payload[4096], state[32], canonical[37], replay[PLATFORM_MAX_PATH];
	rows.FetchString(0, id, sizeof(id));
	rows.FetchString(1, payload, sizeof(payload));
	rows.FetchString(2, state, sizeof(state));
	rows.FetchString(3, canonical, sizeof(canonical));
	rows.FetchString(4, replay, sizeof(replay));
	int upstream = rows.FetchInt(5), attempts = rows.FetchInt(6);
	bool eligible = rows.FetchInt(7) != 0;
	bool replayDone = rows.FetchInt(8) != 0;
	delete rows;
	char path[256];
	EHTTPMethod method = k_EHTTPMethodPOST;
	strcopy(path, sizeof(path), "/v1/records");
	if (!StrEqual(state, "record"))
	{
		if (upstream > 0 && !StrEqual(state, "replay"))
		{
			strcopy(state, sizeof(state), "reconcile");
			Format(path, sizeof(path), "/v1/records/%s/globalapi", canonical);
			Format(payload, sizeof(payload), "{\"globalapi_id\":%d}", upstream);
		}
		else if (eligible && !replayDone && replay[0] && FileExists(replay))
		{
			strcopy(state, sizeof(state), "replay");
			Format(path, sizeof(path), "/v1/records/%s/replay", canonical);
		}
		else
		{
			Queue_State(id, (upstream > 0 || (eligible && !replayDone)) ? "accepted" : "done", GetTime() + 30);
			return;
		}
		method = k_EHTTPMethodPUT;
	}
	char url[768];
	Format(url, sizeof(url), "%s%s", environment, path);
	Handle request = SteamWorks_CreateHTTPRequest(method, url);
	if (request == null) return;
	DataPack pack = new DataPack();
	pack.WriteString(id); pack.WriteString(state); pack.WriteCell(attempts);
	SteamWorks_SetHTTPRequestContextValue(request, pack);
	SteamWorks_SetHTTPCallbacks(request, OnRecordHTTPComplete);
	SteamWorks_SetHTTPRequestHeaderValue(request, "X-Server-Group-Key", key);
	SteamWorks_SetHTTPRequestHeaderValue(request, "Idempotency-Key", id);
	SteamWorks_SetHTTPRequestAbsoluteTimeoutMS(request, 60000);
	bool bodyOK;
	if (StrEqual(state, "replay")) bodyOK = SteamWorks_SetHTTPRequestRawPostBodyFromFile(request, "application/octet-stream", replay);
	else bodyOK = SteamWorks_SetHTTPRequestRawPostBody(request, "application/json", payload, strlen(payload));
	gBusy = true;
	if (!bodyOK || !SteamWorks_SendHTTPRequest(request))
	{
		OnRecordHTTPComplete(request, true, false, view_as<EHTTPStatusCode>(0), pack);
	}
}

public void OnRecordHTTPComplete(Handle request, bool failure, bool successful, EHTTPStatusCode statusCode, DataPack pack)
{
	pack.Reset();
	char id[37], state[32];
	pack.ReadString(id, sizeof(id)); pack.ReadString(state, sizeof(state));
	int attempts = pack.ReadCell(), status = view_as<int>(statusCode);
	delete pack;
	gBusy = false;
	Format(gLastStatus, sizeof(gLastStatus), "HTTP %d (%s)", status, state);
	if (status >= 400 && status < 500)
	{
		char detail[1024];
		if (HTTP_ReadBody(request, detail, sizeof(detail))) Format(gLastStatus, sizeof(gLastStatus), "HTTP %d: %s", status, detail);
	}
	if (!failure && successful && status >= 200 && status < 300)
	{
		char response[16384], query[2048];
		HTTP_ReadBody(request, response, sizeof(response));
		JSON_Object body = json_decode(response);
		Queue_State(id, state, GetTime() + 30, "Waiting for valid upload acknowledgement");
		if (body != null)
		{
			if (StrEqual(state, "record"))
			{
				char canonical[37];
				body.GetString("record_uuid", canonical, sizeof(canonical));
				if (IsRecordUUID(canonical))
				{
					Format(query, sizeof(query), "UPDATE jobs SET canonical='%s',state='accepted',attempts=0,next=0,eligible=%d,error='' WHERE id='%s'", canonical, body.GetBool("replay_eligible") ? 1 : 0, id);
					Queue_SQL(query);
				}
			}
			else if (StrEqual(state, "reconcile"))
			{
				char result[32]; body.GetString("state", result, sizeof(result));
				if (StrEqual(result, "verified"))
				{
					Format(query, sizeof(query), "UPDATE jobs SET upstream=0,state='replay',attempts=0,next=0,eligible=%d,error='' WHERE id='%s'", body.GetBool("replay_eligible") ? 1 : 0, id);
					Queue_SQL(query);
				}
				else Queue_State(id, "replay", GetTime() + 30, "Upstream reconciliation pending; inspect backend claim");
			}
			else if (body.GetBool("available"))
			{
				Format(query, sizeof(query), "UPDATE jobs SET replay_done=1,state=CASE WHEN upstream>0 THEN 'accepted' ELSE 'done' END,next=%d,error='' WHERE id='%s'", GetTime() + 60, id);
				Queue_SQL(query);
			}
			body.Cleanup(); delete body;
		}
	}
	else if (status == 401 || (status == 403 && StrEqual(state, "record"))) Queue_State(id, "auth", 0, gLastStatus);
	else if (failure || !successful || status == 408 || status == 429 || status >= 500 || status == 0)
	{
		int delay = RoundToCeil(5.0 * Pow(2.0, float(attempts > 8 ? 8 : attempts)));
		if (delay > 900) delay = 900;
		delay += GetRandomInt(0, delay / 5);
		if (delay > 900) delay = 900;
		char retry[64];
		if (SteamWorks_GetHTTPResponseHeaderValue(request, "Retry-After", retry, sizeof(retry)))
		{
			int requested = StringToInt(retry);
			if (requested > delay) delay = requested;
		}
		char query[256];
		Format(query, sizeof(query), "UPDATE jobs SET attempts=attempts+1 WHERE id='%s'", id);
		Queue_SQL(query);
		Queue_State(id, state, GetTime() + delay, gLastStatus);
	}
	else Queue_State(id, "rejected", 0, gLastStatus);
	delete request;
}

bool HTTP_ReadBody(Handle request, char[] body, int capacity)
{
	body[0] = '\0';
	int length;
	if (!SteamWorks_GetHTTPResponseBodySize(request, length) || length <= 0 || length >= capacity) return false;
	bool success = SteamWorks_GetHTTPResponseBodyData(request, body, length);
	body[length] = '\0';
	return success;
}
