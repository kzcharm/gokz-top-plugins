static Address gA_FrameStartTimeStdDev = Address_Null;
static Address gA_FrameComputationTime = Address_Null;
static bool gB_ServerPerformanceAvailable;

void InitializeServerPerformance()
{
	Handle gameConfig = LoadGameConfigFile("gokz-top-sv-var.games");
	if (gameConfig == null)
	{
		LogError("[gokz-top-servers] Server SV/VAR telemetry unavailable: failed to load gokz-top-sv-var.games");
		return;
	}

	gA_FrameStartTimeStdDev = GameConfGetAddress(gameConfig, "host_framestarttime_stddeviation");
	gA_FrameComputationTime = GameConfGetAddress(gameConfig, "host_frameendtime_computationduration");
	delete gameConfig;

	if (gA_FrameStartTimeStdDev == Address_Null
		|| gA_FrameComputationTime == Address_Null)
	{
		LogError("[gokz-top-servers] Server SV/VAR telemetry unavailable: engine addresses were not found");
		return;
	}

	gB_ServerPerformanceAvailable = true;
}

bool TryGetServerPerformance(float &svMs, float &varMs)
{
	if (!gB_ServerPerformanceAvailable)
	{
		return false;
	}

	svMs = view_as<float>(LoadFromAddress(gA_FrameComputationTime, NumberType_Int32)) * 1000.0;
	varMs = view_as<float>(LoadFromAddress(gA_FrameStartTimeStdDev, NumberType_Int32)) * 1000.0;

	if (svMs < 0.0 || svMs > 10000.0 || varMs < 0.0 || varMs > 10000.0)
	{
		return false;
	}

	return true;
}
