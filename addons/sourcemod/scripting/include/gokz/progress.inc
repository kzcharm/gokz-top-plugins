/*
	gokz-progress Plugin Include
	
	Website: https://bitbucket.org/kztimerglobalteam/gokz
*/

#if defined _gokz_progress_included_
#endinput
#endif
#define _gokz_progress_included_



// =====[ NATIVES ]=====

/**
 * Gets the player's current progress (0.0 to 1.0).
 *
 * @param client		Client index.
 * @return				Progress value from 0.0 to 1.0, or 0.0 if not tracking.
 */
native float GOKZ_PG_GetProgress(int client);

/**
 * Gets the player's progress formatted as display text.
 *
 * @param client		Client index.
 * @param buffer		Buffer to store formatted text.
 * @param maxLength		Maximum length of buffer.
 * @return				1 on success.
 */
native int GOKZ_PG_GetProgressFormatted(int client, char[] buffer, int maxLength);

/**
 * Checks if progress tracking is enabled and active for a client.
 *
 * @param client		Client index.
 * @return				True if progress tracking is active, false otherwise.
 */
native bool GOKZ_PG_IsEnabled(int client);

/**
 * Gets the player's time difference vs PB replay (current_time - pb_time_at_same_position).
 *
 * @param client		Client index.
 * @return				Time difference in seconds. Positive = behind PB, negative = ahead of PB, 0.0 if not available.
 */
native float GOKZ_PG_GetTimeDiff(int client);

/**
 * Gets the player's time difference formatted as display text.
 *
 * @param client		Client index.
 * @param buffer		Buffer to store formatted text.
 * @param maxLength		Maximum length of buffer.
 * @return				1 on success.
 */
native int GOKZ_PG_GetTimeDiffFormatted(int client, char[] buffer, int maxLength);

/**
 * Checks if time-diff is available for a client.
 *
 * @param client		Client index.
 * @return				True if time-diff is available (PB replay loaded and timer running), false otherwise.
 */
native bool GOKZ_PG_HasTimeDiff(int client);

/**
 * Checks if the player's progress is out of route (too far from replay route, >500 units).
 *
 * @param client		Client index.
 * @return				True if progress is out of route (location progress is zero), false otherwise.
 */
native bool GOKZ_PG_IsOutOfRoute(int client);

/**
 * Forces loading a replay for a specific mode for consistent progress tracking.
 *
 * @param mode			Mode to load replay for (0=VNL, 1=SKZ, 2=KZT, 3=NKZ).
 * @return				1 on success, 0 on failure.
 */
native int GOKZ_PG_ForceLoadReplayForMode(int mode);

/**
 * Sets the player's progress to 100% (used when timer finishes).
 *
 * @param client		Client index.
 * @return				1 on success, 0 on failure.
 */
native int GOKZ_PG_SetProgressTo100(int client);

/**
 * Gets the player's rank formatted as display text (e.g., "Rank: 2/16").
 *
 * @param client		Client index.
 * @param buffer		Buffer to store formatted text.
 * @param maxLength		Maximum length of buffer.
 * @return				1 on success.
 */
native int GOKZ_PG_GetRankFormatted(int client, char[] buffer, int maxLength);



// =====[ DEPENDENCY ]=====

public SharedPlugin __pl_gokz_progress = 
{
	name = "gokz-progress", 
	file = "gokz-progress.smx", 
	#if defined REQUIRE_PLUGIN
	required = 1, 
	#else
	required = 0, 
	#endif
};

#if !defined REQUIRE_PLUGIN
public void __pl_gokz_progress_SetNTVOptional()
{
	MarkNativeAsOptional("GOKZ_PG_GetProgress");
	MarkNativeAsOptional("GOKZ_PG_GetProgressFormatted");
	MarkNativeAsOptional("GOKZ_PG_IsEnabled");
	MarkNativeAsOptional("GOKZ_PG_GetTimeDiff");
	MarkNativeAsOptional("GOKZ_PG_GetTimeDiffFormatted");
	MarkNativeAsOptional("GOKZ_PG_HasTimeDiff");
	MarkNativeAsOptional("GOKZ_PG_IsOutOfRoute");
	MarkNativeAsOptional("GOKZ_PG_ForceLoadReplayForMode");
	MarkNativeAsOptional("GOKZ_PG_SetProgressTo100");
	MarkNativeAsOptional("GOKZ_PG_GetRankFormatted");
}
#endif

