#if defined _gokz_top_replay_filesystem_included_
#endinput
#endif
#define _gokz_top_replay_filesystem_included_

/** Linux lstat type: 0 missing/unsupported, 1 directory, 2 regular file, 3 link. */
native int GOKZTop_ReplayPathType(const char[] path);
/** Format a positive finite distance using backend-compatible four-place half-up rounding. */
native bool GOKZTop_FormatJumpDistance(float distance, char[] text, int length);
/** Try the shared-directory process lock without blocking; retained until release or process exit. */
native bool GOKZTop_ReplayWorkerLock(const char[] path);
/** Release this process's replay worker lock. */
native void GOKZTop_ReplayReleaseWorker();
/** Copy a regular file's subsecond modification/change times, size, and inode fingerprint. */
native bool GOKZTop_ReplayRevision(const char[] path, char[] revision, int length);
/** Exclusively create a stable regular-file copy (up to 16 MiB), without following final links.
 * Returns a full-content CRC32 in checksum; removes incomplete copies on failure.
 * Callers must additionally validate ancestor directories. Paths are relative to the game. */
native bool GOKZTop_SnapshotReplay(const char[] source, const char[] destination, int &checksum);
public Extension __ext_replay_fs =
{
	name = "GOKZ Top Replay Filesystem",
	file = "gokz_top_replay_fs.ext",
	autoload = 1,
	required = 1
};
