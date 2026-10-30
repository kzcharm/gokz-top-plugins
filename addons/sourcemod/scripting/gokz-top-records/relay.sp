// Consumer of the AXEKZ-owned relay v1 API. Evidence is opaque to the producer.
static bool sRelaySession[MAXPLAYERS + 1];
static int sStoppedSerial[MAXPLAYERS + 1], sStoppedTick[MAXPLAYERS + 1];
static char sStoppedID[MAXPLAYERS + 1][37], sStoppedEvidence[MAXPLAYERS + 1][GOKZ_RELAY_EVIDENCE_MAX];

void Relay_Init()
{
	Queue_SQL("CREATE TABLE IF NOT EXISTS relay_receipts (id TEXT PRIMARY KEY,completion TEXT NOT NULL,evidence TEXT NOT NULL,result TEXT NOT NULL)");
}

bool Relay_Available()
{
	return LibraryExists("gokz-relay")
		&& GetFeatureStatus(FeatureType_Native, "GOKZ_Relay_IsResumed") == FeatureStatus_Available
		&& GetFeatureStatus(FeatureType_Native, "GOKZ_Relay_IsEligible") == FeatureStatus_Available
		&& GetFeatureStatus(FeatureType_Native, "GOKZ_Relay_GetRunID") == FeatureStatus_Available
		&& GetFeatureStatus(FeatureType_Native, "GOKZ_Relay_AcknowledgeCompletion") == FeatureStatus_Available;
}

void Relay_ResetClient(int client)
{
	sRelaySession[client] = false;
	sStoppedSerial[client] = 0;
	sStoppedID[client][0] = '\0';
	sStoppedEvidence[client][0] = '\0';
}

void Relay_OnLibraryRemoved(const char[] name)
{
	if (!StrEqual(name, "gokz-relay")) return;
	for (int client = 1; client <= MaxClients; client++)
	{
		if (sRelaySession[client]) { gValid[client] = false; gRun[client] = false; }
		Relay_ResetClient(client);
	}
}

bool Relay_CoreInvalidityExpected(int client)
{
	if (!sRelaySession[client] || !Relay_Available() || !GOKZ_Relay_IsResumed(client)) return false;
	char id[37];
	return GOKZ_Relay_GetRunID(client, id, sizeof(id)) && StrEqual(id, gGUID[client]);
}

bool Relay_UUID(const char[] id)
{
	return IsRecordUUID(id) && id[14] == '7' && (id[19] == '8' || id[19] == '9' || id[19] == 'a' || id[19] == 'b' || id[19] == 'A' || id[19] == 'B');
}

bool Relay_Integrity(JSON_Object body)
{
	if (!body.HasKey("integrity")) return false;
	if (body.GetKeyType("integrity") != Type_Object) return false;
	JSON_Object integrity = body.GetObject("integrity");
	if (integrity == null) return false;
	static char checks[][] = {"fresh_map", "server_settings", "client_settings", "required_plugins", "timer_valid", "mode_stable", "anticheat_clear"};
	for (int i = 0; i < sizeof(checks); i++)
	{
		if (integrity.GetKeyType(checks[i]) != Type_Bool || !integrity.GetBool(checks[i])) return false;
	}
	return true;
}

bool Relay_StringEquals(JSON_Object left, const char[] leftKey, JSON_Object right, const char[] rightKey)
{
	char a[512], b[512];
	return left.GetString(leftKey, a, sizeof(a)) && right.GetString(rightKey, b, sizeof(b)) && StrEqual(a, b);
}

public Action GOKZ_Relay_OnResumeCheck(int client)
{
	if (client < 1 || client > MaxClients || !IsClientInGame(client) || IsFakeClient(client)) return Plugin_Handled;
	if (ClientSettingsResolved(client)) return Plugin_Continue;
	QueryClientSettings(client);
	return Plugin_Handled;
}

void Relay_FreezeStoppedEvidence(int client)
{
	sStoppedSerial[client] = 0;
	sStoppedID[client][0] = '\0';
	sStoppedEvidence[client][0] = '\0';
	if (!gRun[client]) return;
	GOKZ_Relay_OnCaptureEvidence(client, sStoppedEvidence[client], sizeof(sStoppedEvidence[]));
	if (!sStoppedEvidence[client][0]) return;
	sStoppedSerial[client] = GetClientSerial(client);
	sStoppedTick[client] = GetGameTickCount();
	strcopy(sStoppedID[client], sizeof(sStoppedID[]), gGUID[client]);
}

bool Relay_StoppedEvidence(int client, const char[] id, char[] evidence, int maxlength)
{
	if (sStoppedSerial[client] == 0 || sStoppedSerial[client] != GetClientSerial(client)
		|| sStoppedTick[client] != GetGameTickCount() || !StrEqual(id, sStoppedID[client])) return false;
	// A later invalidation in the same forward must still poison the final save.
	if (!GOKZ_GetValidTimer(client) && !Relay_CoreInvalidityExpected(client)) gValid[client] = false;
	if (!gValid[client])
	{
		JSON_Object saved = json_decode(sStoppedEvidence[client]);
		if (saved == null) return false;
		JSON_Object integrity = saved.GetObject("integrity");
		integrity.SetBool("timer_valid", false); integrity.SetBool("anticheat_clear", false);
		json_encode(saved, evidence, maxlength);
		saved.Cleanup(); delete saved;
	}
	else strcopy(evidence, maxlength, sStoppedEvidence[client]);
	return true;
}

public void GOKZ_Relay_OnCaptureEvidence(int client, char[] evidence, int maxlength)
{
	evidence[0] = '\0';
	if (!Relay_Available() || client < 1 || client > MaxClients || !IsClientInGame(client) || IsFakeClient(client)) return;
	char id[37];
	if (!GOKZ_Relay_GetRunID(client, id, sizeof(id)) || !Relay_UUID(id)) return;
	if (!gRun[client])
	{
		Relay_StoppedEvidence(client, id, evidence, maxlength);
		return;
	}
	if (!ServerSettingsValid() || !ClientSettingsValid(client)
		|| (!GOKZ_GetValidTimer(client) && !Relay_CoreInvalidityExpected(client))) gValid[client] = false;
	if (sRelaySession[client] && (!Relay_CoreInvalidityExpected(client) || !GOKZ_Relay_IsEligible(client))) gValid[client] = false;
	JSON_Object body = Capture_Check(client, GOKZ_GetCourse(client));
	if (body == null) return;
	char steam2[32];
	GetClientAuthId(client, AuthId_Steam2, steam2, sizeof(steam2));
	body.SetString("steam2", steam2);
	body.SetInt("evidence_version", 1);
	body.SetString("run_id", id);
	body.SetString("environment", gEnvironment[client]);
	json_encode(body, evidence, maxlength);
	body.Cleanup(); delete body;
	// The logical relay ID supersedes an unfinished fresh run's fallback UUID.
	strcopy(gGUID[client], sizeof(gGUID[]), id);
}

public void GOKZ_Relay_OnResume(int client, const char[] runID, const char[] evidence, bool eligible)
{
	if (!Relay_Available() || client < 1 || client > MaxClients || !IsClientInGame(client) || IsFakeClient(client)) return;
	gRun[client] = false;
	gValid[client] = false;
	Relay_ResetClient(client);
	char owned[37];
	if (!Relay_UUID(runID) || !GOKZ_Relay_IsResumed(client)
		|| !GOKZ_Relay_GetRunID(client, owned, sizeof(owned)) || !StrEqual(owned, runID)) return;
	if (!evidence[0]) return;
	JSON_Object saved = json_decode(evidence);
	if (saved == null) return;
	char environment[512], key[256], server[37], savedID[37], savedEnvironment[512], savedServer[37];
	GOKZTop_GetHTTPConfig(environment, sizeof(environment), key, sizeof(key));
	GOKZTop_GetServerSteamID(server, sizeof(server));
	saved.GetString("run_id", savedID, sizeof(savedID));
	saved.GetString("environment", savedEnvironment, sizeof(savedEnvironment));
	saved.GetString("server_id", savedServer, sizeof(savedServer));
	JSON_Object current = Capture_Check(client, GOKZ_GetCourse(client));
	int mode = GOKZ_GetCoreOption(client, Option_Mode);
	bool matches = current != null && saved.GetInt("evidence_version") == 1 && StrEqual(savedID, runID)
		&& StrEqual(environment, savedEnvironment) && server[0] && StrEqual(server, savedServer);
	if (matches)
	{
		matches = Relay_StringEquals(saved, "steamid64", current, "steamid64")
			&& Relay_StringEquals(saved, "map_name", current, "map_name")
			&& Relay_StringEquals(saved, "mode", current, "mode")
			&& saved.GetInt("stage") == current.GetInt("stage") && saved.GetInt("style") == 0 && current.GetInt("style") == 0
			&& saved.GetInt("bsp_size") == current.GetInt("bsp_size")
			&& saved.GetInt("mode_version") == current.GetInt("mode_version") && saved.GetInt("tickrate") == 128;
	}
	if (matches && mode >= 0 && mode <= 3)
	{
		gRun[client] = true;
		sRelaySession[client] = true;
		gMode[client] = mode;
		gVersion[client] = saved.GetInt("mode_version");
		strcopy(gGUID[client], sizeof(gGUID[]), runID);
		strcopy(gEnvironment[client], sizeof(gEnvironment[]), environment);
		strcopy(gServer[client], sizeof(gServer[]), server);
		gValid[client] = eligible && GOKZ_Relay_IsEligible(client) && Relay_Integrity(saved)
			&& gFreshMap && ServerSettingsValid() && ClientSettingsValid(client);
	}
	if (current != null) { current.Cleanup(); delete current; }
	saved.Cleanup(); delete saved;
}

// Construct the ordinary record contract from immutable completion and evidence.
// Never consult a client slot: delivery survives disconnects, map changes and reloads.
JSON_Object Relay_Record(JSON_Object completion, JSON_Object saved)
{
	static char savedIntegers[][] = {"evidence_version", "bsp_size", "stage", "style", "mode_version", "tickrate"};
	for (int i = 0; i < sizeof(savedIntegers); i++) if (saved.GetKeyType(savedIntegers[i]) != Type_Int) return null;
	static char savedStrings[][] = {"run_id", "steamid64", "steam2", "map_name", "environment", "server_id", "mode"};
	for (int i = 0; i < sizeof(savedStrings); i++) if (saved.GetKeyType(savedStrings[i]) != Type_String) return null;
	if (completion.GetKeyType("eligible") != Type_Bool) return null;
	static char integers[][] = {"version", "course", "mode", "style", "time_ms", "teleports", "finished_at"};
	for (int i = 0; i < sizeof(integers); i++) if (completion.GetKeyType(integers[i]) != Type_Int) return null;
	static char strings[][] = {"run_id", "steamid64", "map_name"};
	for (int i = 0; i < sizeof(strings); i++) if (completion.GetKeyType(strings[i]) != Type_String) return null;
	if (completion.GetInt("version") != 1 || !completion.GetBool("eligible")
		|| saved.GetInt("evidence_version") != 1 || !Relay_Integrity(saved)) return null;
	char id[37], savedID[37], modeName[8], steam[32], map[PLATFORM_MAX_PATH], environment[512], server[37];
	completion.GetString("run_id", id, sizeof(id)); saved.GetString("run_id", savedID, sizeof(savedID));
	saved.GetString("mode", modeName, sizeof(modeName));
	saved.GetString("steamid64", steam, sizeof(steam)); saved.GetString("map_name", map, sizeof(map));
	saved.GetString("environment", environment, sizeof(environment)); saved.GetString("server_id", server, sizeof(server));
	int mode = completion.GetInt("mode"), ms = completion.GetInt("time_ms"), finished = completion.GetInt("finished_at");
	if (!Relay_UUID(id) || !StrEqual(id, savedID) || mode < 0 || mode > 3 || !StrEqual(modeName, gModeNames[mode])
		|| !Relay_StringEquals(saved, "steamid64", completion, "steamid64") || !Relay_StringEquals(saved, "map_name", completion, "map_name")
		|| saved.GetInt("stage") != completion.GetInt("course") || completion.GetInt("course") < 0 || completion.GetInt("course") > 255
		|| !completion.HasKey("style") || completion.GetInt("style") != 0 || saved.GetInt("style") != 0
		|| completion.GetInt("teleports") < 0 || ms <= 0 || finished <= 0 || saved.GetInt("bsp_size") <= 0
		|| saved.GetInt("mode_version") <= 0 || saved.GetInt("tickrate") != 128 || !environment[0] || !server[0] || !steam[0] || !map[0]) return null;
	// Decode a copy so the evidence remains intact for durable duplicate checks.
	char encoded[GOKZ_RELAY_EVIDENCE_MAX];
	json_encode(saved, encoded, sizeof(encoded));
	JSON_Object body = json_decode(encoded);
	if (body == null) return null;
	body.Remove("evidence_version"); body.Remove("environment"); body.Remove("run_id");
	char time[32], timestamp[40];
	Format(time, sizeof(time), "%d.%03d", ms / 1000, ms % 1000);
	FormatTime(timestamp, sizeof(timestamp), "%Y-%m-%dT%H:%M:%S%z", finished);
	body.SetString("record_uuid", id); body.SetString("time", time); body.SetString("finished_at", timestamp);
	body.SetInt("teleports", completion.GetInt("teleports"));
	return body;
}

public void GOKZ_Relay_OnCompleted(const char[] completionJson, const char[] evidence)
{
	if (!Relay_Available()) return;
	// Reject oversized deliveries before storing truncated duplicate fingerprints.
	if (strlen(completionJson) >= 4096 || strlen(evidence) >= GOKZ_RELAY_EVIDENCE_MAX) return;
	JSON_Object completion = json_decode(completionJson);
	if (completion == null) return;
	char id[37]; completion.GetString("run_id", id, sizeof(id));
	if (!Relay_UUID(id)) { completion.Cleanup(); delete completion; return; }
	char query[20480];
	Format(query, sizeof(query), "SELECT completion,evidence FROM relay_receipts WHERE id='%s'", id);
	DBResultSet receipt = SQL_Query(gDB, query);
	if (receipt == null) { completion.Cleanup(); delete completion; return; }
	if (receipt.FetchRow())
	{
		char previousCompletion[4096], previousEvidence[GOKZ_RELAY_EVIDENCE_MAX];
		receipt.FetchString(0, previousCompletion, sizeof(previousCompletion)); receipt.FetchString(1, previousEvidence, sizeof(previousEvidence));
		bool identical = StrEqual(previousCompletion, completionJson) && StrEqual(previousEvidence, evidence);
		delete receipt;
		completion.Cleanup(); delete completion;
		if (identical) GOKZ_Relay_AcknowledgeCompletion(id, "gokz.top");
		else LogError("Conflicting relay delivery %s; receipt retained", id);
		return;
	}
	delete receipt;
	JSON_Object saved = evidence[0] ? json_decode(evidence) : null;
	JSON_Object body = saved != null ? Relay_Record(completion, saved) : null;
	bool durable = true, valid = body != null;
	if (body != null)
	{
		char environment[512], server[37], steam2[32], payload[4096];
		saved.GetString("environment", environment, sizeof(environment)); saved.GetString("server_id", server, sizeof(server));
		saved.GetString("steam2", steam2, sizeof(steam2));
		body.Remove("steam2");
		json_encode(body, payload, sizeof(payload));
		durable = Queue_Insert(id, environment, server, payload, steam2, true);
		body.Cleanup(); delete body;
	}
	if (durable)
	{
		char escapedCompletion[8192], escapedEvidence[GOKZ_RELAY_EVIDENCE_MAX * 2];
		gDB.Escape(completionJson, escapedCompletion, sizeof(escapedCompletion)); gDB.Escape(evidence, escapedEvidence, sizeof(escapedEvidence));
		Format(query, sizeof(query), "INSERT INTO relay_receipts(id,completion,evidence,result) VALUES('%s','%s','%s','%s')", id, escapedCompletion, escapedEvidence, valid ? "queued" : "rejected");
		if (Queue_SQL(query)) GOKZ_Relay_AcknowledgeCompletion(id, "gokz.top");
	}
	if (saved != null) { saved.Cleanup(); delete saved; }
	completion.Cleanup(); delete completion;
}

public void GOKZ_Relay_OnReplaySaved(const char[] runID, const char[] filePath)
{
	if (!Relay_Available() || !Relay_UUID(runID)) return;
	char query[256];
	Format(query, sizeof(query), "SELECT id FROM jobs WHERE id='%s' AND relay=1 AND state NOT IN ('done','rejected')", runID);
	DBResultSet row = SQL_Query(gDB, query);
	if (row != null && row.FetchRow()) SpoolReplay(runID, filePath);
	delete row;
}
