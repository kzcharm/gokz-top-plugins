# SourceMod regression probes

## Record filter queue gates

Compile `record_filters.sp` with the records plugin's include paths and load it
on a dedicated csgotest server. It uses its own SQLite database and spool and
stubs HTTP creation, so no finishes or metadata requests leave the probe. Expect
`[record-filters-test] PASS assertions=61`, then unload and remove the probe.

The checks cover exact map/course/128-tick filters, wildcard rejection, all four
modes, NKZ/KZT sharing, NUB/PRO eligibility, persisted caches, malformed responses,
API environment isolation, unknown-filter waits, skipping new unsupported jobs,
pruning old rejected jobs before upload, private-spool cleanup, acknowledged-job
preservation, and revoking stale positive filters after backend rejection.

The real plugin's staging integration can be checked by inspecting the
`record_filters` table in its existing private queue database after loading. A
successful lookup stores a 512-character course-bit mask for the exact API/map
pair. The probe never opens this real database.

## PB announcements

Compile `pb_announcements.sp` with the same project and SourceMod include paths as
`gokz-top-core.sp`, then load it on a dedicated test server with the normal
gokz.top dependencies installed. It exercises production PB handlers with
synthetic API responses and captures chat output without creating players, runs,
timers, or HTTP writes. Successful execution logs
`[pb-announcements-test] PASS assertions=55`. Unload and remove the probe afterward.

The checks cover slower finishes, PB improvements and point gains, matching PB
dates, stale ingestion responses, delayed acknowledgements, ties, first records,
one-millisecond improvements, out-of-order responses, authoritative fallbacks,
all four modes and both record types, NKZ/KZT scope sharing, superseded finishes,
disconnect/map cancellation, and API environment changes.

## Jump replay uploader

On a dedicated Linux csgotest server, generate fixtures with
`python3 tests/jump_replay_fixtures.py /path/to/addons/sourcemod/data/gokz-replays/_jumps`.
Add `--load-count 150000` for the directory-scan workload. Fixtures use synthetic
account 12345 and never copy production player data.

Build/install `gokz_top_replay_fs.ext.so` using the SDK's pinned submodules as
described in the main README. Compile `tests/jump_replays.sp` with the same include
paths as the uploader, then load the probe. It exercises the production modules
without starting a worker or making HTTP requests. Expect
`[jump-replays-test] PASS assertions=42`. The probe creates its own
`data/sqlite/gokz-top-replays-tests.sq3` and snapshot directory, and overwrites one
byte of the synthetic fixture to check that an existing snapshot stays unchanged.
Regenerate fixtures before repeating the probe.

Checks cover header identity with no connected player, large Steam account IDs,
normal-style filtering, arbitrary filenames, URL version suffixes, symlinks,
parent traversal, snapshot exclusivity, same-size overwrites, immutable copies,
retry delays/exhaustion, authentication pauses, and terminal outcomes.

For integration checks, load the actual uploader against staging with these
fixtures; check both legacy and arbitrary filenames reach `done` with status 201.
Repeat a scan and reload the plugin to check that completed jobs are not repeated.
A localhost mock can return HTTP 429/503 before 201 to exercise the real callbacks;
restore the staging URL afterward. Quote URLs in console commands so `//` is not
interpreted as a configuration comment. Use `sm_topreplays_status` to inspect
scan timing and private SQLite to inspect environment-bound jobs. Unload/remove
the probe and generated fixtures when finished; do not run it on production.

`record_precision.sp` tests the records plugin against GlobalAPI float serialization,
including the 268.601989 ->268.601 boundary, and verifies that `record_id` wakes a
completed private SQLite job for reconciliation. Compile and load on the dedicated
test server only; it makes no HTTP requests and never submits a run.
