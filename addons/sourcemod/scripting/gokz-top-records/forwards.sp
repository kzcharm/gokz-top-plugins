void Call_OnRecordAccepted(const char[] id, const char[] canonical)
{
	char query[256];
	Format(query, sizeof(query), "SELECT environment,payload FROM jobs WHERE id='%s'", id);
	DBResultSet rows = SQL_Query(gDB, query);
	if (rows == null || !rows.FetchRow()) { delete rows; return; }
	char environment[512], payload[4096];
	rows.FetchString(0, environment, sizeof(environment));
	rows.FetchString(1, payload, sizeof(payload));
	delete rows;
	JSON_Object run = json_decode(payload);
	if (run == null) return;
	char steam[32], map[PLATFORM_MAX_PATH], modeName[8], time[32];
	run.GetString("steamid64", steam, sizeof(steam));
	run.GetString("map_name", map, sizeof(map));
	run.GetString("mode", modeName, sizeof(modeName));
	run.GetString("time", time, sizeof(time));
	int mode = -1;
	for (int index = 0; index < 4; index++)
	{
		if (StrEqual(gModeNames[index], modeName)) mode = index;
	}
	if (mode != -1)
	{
		Call_StartForward(gH_OnRecordAccepted);
		Call_PushString(environment);
		Call_PushString(steam);
		Call_PushString(map);
		Call_PushCell(run.GetInt("stage"));
		Call_PushCell(mode);
		Call_PushFloat(StringToFloat(time));
		Call_PushCell(run.GetInt("teleports"));
		Call_PushString(canonical);
		Call_Finish();
	}
	run.Cleanup();
	delete run;
}
