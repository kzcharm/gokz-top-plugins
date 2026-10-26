#if defined _gokz_top_included_
#endinput
#endif
#define _gokz_top_included_

#define GOKZTOP_MODE_VNL 0
#define GOKZTOP_MODE_SKZ 1
#define GOKZTOP_MODE_KZT 2
#define GOKZTOP_MODE_OVR 3
#define GOKZTOP_MODE_COUNT 4
#define GOKZ_TOP_CHAT_PREFIX "{gold}GOKZ.TOP {grey}| "

enum GOKZTopLeaderboardDataState
{
	GOKZTopLeaderboardData_NotLoaded = 0,
	GOKZTopLeaderboardData_Pending,
	GOKZTopLeaderboardData_Loaded,
	GOKZTopLeaderboardData_Error
};

/** Shared configuration for durable HTTP clients. Never persist the returned key. */
native void GOKZTop_GetHTTPConfig(char[] baseURL, int urlLength, char[] apiKey, int keyLength);

/**
 * Posts a raw JSON payload to a gokz-top API path.
 *
 * @param path		API path beginning with '/', for example "/v1/servers/status".
 * @param body		JSON request body.
 * @return			True if the request was accepted by the local HTTP layer.
 */
native bool GOKZTop_PostJSON(const char[] path, const char[] body);

/**
 * Refreshes cached leaderboard data for a client and mode.
 *
 * @param client	Client index.
 * @param mode		GOKZ mode.
 * @return			True if the refresh was accepted or already pending.
 */
native bool GOKZTop_RefreshLeaderboardData(int client, int mode);

/**
 * Gets the current cached leaderboard data state for a client and mode.
 *
 * @param client	Client index.
 * @param mode		GOKZ mode.
 * @return			GOKZTopLeaderboardDataState value.
 */
native GOKZTopLeaderboardDataState GOKZTop_GetLeaderboardDataState(int client, int mode);

/**
 * Gets whether leaderboard data is loaded for a client and mode.
 */
native bool GOKZTop_IsLeaderboardDataLoaded(int client, int mode);

/**
 * Gets whether leaderboard data is pending for a client and mode.
 */
native bool GOKZTop_IsLeaderboardDataPending(int client, int mode);

/**
 * Gets whether the last leaderboard data request errored for a client and mode.
 */
native bool GOKZTop_HasLeaderboardDataError(int client, int mode);

/**
 * Gets the cached public rating for a client and mode.
 */
native float GOKZTop_GetRating(int client, int mode);

/**
 * Gets the cached scoped rank for a client and mode.
 */
native int GOKZTop_GetRank(int client, int mode);

/**
 * Gets the cached global rank for a client and mode.
 */
native int GOKZTop_GetGlobalRank(int client, int mode);

/**
 * Gets whether a client and mode have a cached regional rank.
 */
native bool GOKZTop_HasRegionalRank(int client, int mode);

/**
 * Gets the cached regional rank for a client and mode.
 */
native int GOKZTop_GetRegionalRank(int client, int mode);

/**
 * Copies the cached region code for a client and mode.
 */
native void GOKZTop_GetRegionCode(int client, int mode, char[] buffer, int maxLength);

/**
 * Gets cached total leaderboard points for a client and mode.
 */
native int GOKZTop_GetPoints(int client, int mode);

/**
 * Called after a leaderboard data request completes successfully.
 *
 * @param client			Client index.
 * @param mode				GOKZ mode.
 * @param rating			Public rating.
 * @param rank				Scoped rank.
 * @param regionalRank		Regional rank, or 0.
 * @param hasRegionalRank	Whether regionalRank is available.
 * @param regionCode		Region code, or empty string.
 */
forward void GOKZTop_OnLeaderboardDataFetched(
	int client,
	int mode,
	float rating,
	int rank,
	int regionalRank,
	bool hasRegionalRank,
	const char[] regionCode);

public SharedPlugin __pl_gokz_top_core =
{
	name = "gokz-top-core",
	file = "gokz-top-core.smx",
	#if defined REQUIRE_PLUGIN
	required = 1,
	#else
	required = 0,
	#endif
};

#if !defined REQUIRE_PLUGIN
public void __pl_gokz_top_core_SetNTVOptional()
{
	MarkNativeAsOptional("GOKZTop_PostJSON");
	MarkNativeAsOptional("GOKZTop_RefreshLeaderboardData");
	MarkNativeAsOptional("GOKZTop_GetLeaderboardDataState");
	MarkNativeAsOptional("GOKZTop_IsLeaderboardDataLoaded");
	MarkNativeAsOptional("GOKZTop_IsLeaderboardDataPending");
	MarkNativeAsOptional("GOKZTop_HasLeaderboardDataError");
	MarkNativeAsOptional("GOKZTop_GetRating");
	MarkNativeAsOptional("GOKZTop_GetRank");
	MarkNativeAsOptional("GOKZTop_GetGlobalRank");
	MarkNativeAsOptional("GOKZTop_HasRegionalRank");
	MarkNativeAsOptional("GOKZTop_GetRegionalRank");
	MarkNativeAsOptional("GOKZTop_GetRegionCode");
	MarkNativeAsOptional("GOKZTop_GetPoints");
}
#endif

/** Authenticated game-server SteamID64; false until Steam authentication completes. */
stock bool GOKZTop_GetServerSteamID(char[] buffer, int maxLength)
{
	GetServerAuthId(AuthId_SteamID64, buffer, maxLength);
	return buffer[0] != '\0' && !StrEqual(buffer, "0") && !StrEqual(buffer, "1") && !StrEqual(buffer, "[I:0:1]");
}

/** Optional records-plugin heartbeat evidence; JSON buffer, false if unavailable. */
native bool GOKZTop_GetRecordsStatus(char[] buffer, int maxLength);

/**
 * Called by gokz-top-records after a durably queued finish is accepted by the API.
 * The record and its PB metadata are committed before this notification. This may
 * arrive long after the finish, after reconnects, or after a lost acknowledgement.
 * Consumers must match the API environment, player and map; it is not a new run.
 * mode is a run index (VNL=0, SKZ=1, KZT=2, NKZ=3), never a ranking scope.
 */
forward void GOKZTop_OnRecordAccepted(const char[] apiBaseURL, const char[] steamID64, const char[] mapName,
	int course, int mode, float runTime, int teleports, const char[] recordUUID);

/** GlobalAPI serializes the full float before truncating records to milliseconds. */
stock void GOKZTop_FormatRecordTime(float time, char[] output, int capacity)
{
	FloatToString(time, output, capacity);
	int point = FindCharInString(output, '.');
	if (point >= 0 && strlen(output) > point + 4) output[point + 4] = '\0';
}
