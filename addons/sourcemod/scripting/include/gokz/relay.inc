#if defined _gokz_relay_included
 #endinput
#endif
#define _gokz_relay_included

#define GOKZ_RELAY_API_VERSION 2
#define GOKZ_RELAY_EVIDENCE_MAX 4096

/** Capture gokz.top-owned, versioned cumulative integrity evidence before each
 * snapshot and completion. The single gokz.top consumer writes this buffer.
 * Empty evidence means unverified; consumers must reject it for ranking.
 * Called synchronously while the player's run context is still available. */
forward void GOKZ_Relay_OnCaptureEvidence(int client, char[] evidence, int maxlength);

/** Readiness only: return Plugin_Handled while integrity queries are unresolved.
 * Producer retries for up to five seconds before acquiring a claim. Completed
 * failed checks may resume gameplay but must remain ineligible in evidence. */
forward Action GOKZ_Relay_OnResumeCheck(int client);

/** Successful resume, after timer/checkpoints/replay are restored. Core timer
 * validity is true in API v2; genuine invalidations still disqualify the run. Evidence is the exact opaque string from the save.
 * eligible describes relay's independent validation, not gokz.top validation. */
forward void GOKZ_Relay_OnResume(int client, const char[] runID, const char[] evidence, bool eligible);

/** Durable completion delivery; may repeat across reloads or without a client.
 * JSON fields: version (1 legacy, 2 core-valid completion), run_id (UUIDv7), steamid64 (string), map_name,
 * course, mode, style, time_ms, teleports, finished_at (Unix seconds), eligible
 * (bool). All fields and evidence are immutable. Acknowledge ONLY after durable
 * processing, including a durable rejection. consumer: "localdb" or "gokz.top".
 * API v2 uses real core finish events. Consumers must skip ordinary record capture
 * for restored/resumed sessions; this durable event owns record delivery. */
forward void GOKZ_Relay_OnCompleted(const char[] completionJson, const char[] evidence);

/** Immutable replay filename for a logical run; delivery may repeat. */
forward void GOKZ_Relay_OnReplaySaved(const char[] runID, const char[] filePath);

/** Runtime semantics negotiation; optional for legacy v1 producers. */
native int GOKZ_Relay_GetAPIVersion();

native bool GOKZ_Relay_IsResumed(int client);
native bool GOKZ_Relay_IsRestoring(int client);
native bool GOKZ_Relay_IsEligible(int client);
native bool GOKZ_Relay_GetRunID(int client, char[] runID, int maxlength);
native bool GOKZ_Relay_AcknowledgeCompletion(const char[] runID, const char[] consumer);

public SharedPlugin __pl_gokz_relay =
{
 name = "gokz-relay",
 file = "gokz-relay.smx",
#if defined REQUIRE_PLUGIN
 required = 1,
#else
 required = 0,
#endif
};

#if !defined REQUIRE_PLUGIN
public void __pl_gokz_relay_SetNTVOptional()
{
 MarkNativeAsOptional("GOKZ_Relay_GetAPIVersion");
 MarkNativeAsOptional("GOKZ_Relay_IsResumed");
 MarkNativeAsOptional("GOKZ_Relay_IsRestoring");
 MarkNativeAsOptional("GOKZ_Relay_IsEligible");
 MarkNativeAsOptional("GOKZ_Relay_GetRunID");
 MarkNativeAsOptional("GOKZ_Relay_AcknowledgeCompletion");
}
#endif
