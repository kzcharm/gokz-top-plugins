# SourceMod regression probes

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
