static StringMap sRequests;

public void GlobalAPI_OnRequestStarted(Handle request, GlobalAPIRequestData hData)
{
	if (hData.RequestType != GlobalAPIRequestType_POST || hData.IsRetried) return;
	char steam[32], mode[32], auth[32], key[32];
	hData.GetString("steam_id", steam, sizeof(steam));
	hData.GetString("mode", mode, sizeof(mode));
	if (!steam[0] || !mode[0]) return;
	if (sRequests == null) sRequests = new StringMap();
	for (int client = 1; client <= MaxClients; client++)
	{
		if (!IsClientInGame(client) || IsFakeClient(client) || !gGUID[client][0]) continue;
		if (!GetClientAuthId(client, AuthId_Steam2, auth, sizeof(auth)) || !StrEqual(auth, steam)) continue;
		IntToString(view_as<int>(request), key, sizeof(key));
		sRequests.SetString(key, gGUID[client]);
		break;
	}
}

// Observe response data while the owner still owns the request. Never replace
// callbacks, read hData.Data, or modify/delete either upstream handle.
public void GlobalAPI_OnRequestFinished(Handle request, GlobalAPIRequestData hData)
{
	char observed[37], requestKey[32];
	IntToString(view_as<int>(request), requestKey, sizeof(requestKey));
	if (sRequests != null)
	{
		sRequests.GetString(requestKey, observed, sizeof(observed));
		sRequests.Remove(requestKey);
	}
	if (hData.RequestType != GlobalAPIRequestType_POST || hData.Failure || hData.Status < 200 || hData.Status >= 300) return;
	char response[16384];
	if (!HTTP_ReadBody(request, response, sizeof(response))) return;
	JSON_Object body = json_decode(response);
	if (body == null) return;
	int upstream = body.GetInt("record_id");
	if (upstream <= 0) upstream = body.GetInt("id");
	body.Cleanup(); delete body;
	if (upstream <= 0) return;
	char steam[32], mode[32];
	hData.GetString("steam_id", steam, sizeof(steam));
	hData.GetString("mode", mode, sizeof(mode));
	if (!steam[0] || !mode[0]) return;
	// Only a unique captured finish can be associated. Ambiguous retries remain
	// separate for operator review instead of merging equal-time runs.
	DBResultSet rows = SQL_Query(gDB, "SELECT id,payload,steam2 FROM jobs WHERE upstream=0 ORDER BY id DESC");
	if (rows == null) return;
	int matches;
	char match[37];
	while (rows.FetchRow())
	{
		char id[37], payload[4096], player[32], runMode[16];
		rows.FetchString(2, player, sizeof(player));
		rows.FetchString(0, id, sizeof(id)); rows.FetchString(1, payload, sizeof(payload));
		if (observed[0] && !StrEqual(observed, id)) continue;
		JSON_Object run = json_decode(payload);
		if (run == null) continue;
		run.GetString("mode", runMode, sizeof(runMode));
		char timeString[32], upstreamTime[32]; run.GetString("time", timeString, sizeof(timeString));
		Capture_FormatGlobalTime(hData.GetFloat("time"), upstreamTime, sizeof(upstreamTime));
		bool modeMatches = (StrEqual(mode, "kz_vanilla") && StrEqual(runMode, "VNL")) || (StrEqual(mode, "kz_simple") && StrEqual(runMode, "SKZ")) || (StrEqual(mode, "kz_timer") && StrEqual(runMode, "KZT"));
		if (StrEqual(player, steam) && modeMatches && run.GetInt("stage") == hData.GetInt("stage") && run.GetInt("teleports") == hData.GetInt("teleports") && (StrEqual(timeString, upstreamTime) || (observed[0] && FloatAbs(StringToFloat(timeString) - hData.GetFloat("time")) <= 0.0011)))
		{
			matches++; strcopy(match, sizeof(match), id);
		}
		run.Cleanup(); delete run;
	}
	delete rows;
	if (matches == 1)
	{
		char query[256];
		Format(query, sizeof(query), "UPDATE jobs SET upstream=%d,state=CASE WHEN canonical='' THEN state ELSE 'reconcile' END,next=0 WHERE id='%s'", upstream, match);
		Queue_SQL(query);
	}
	else if (matches > 1) LogError("Ambiguous GlobalAPI record %d: %d captured finishes; manual reconciliation required", upstream, matches);
}
