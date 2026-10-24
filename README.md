# gokz-top-plugins

SourceMod plugins for integrating a GOKZ server with [GOKZ.TOP](https://gokz.top).

## Requirements

- SourceMod 1.11+
- SteamWorks extension
- Existing GOKZ installation
- A GOKZ.TOP server group API key

## Apply For An API Key

API keys are issued per server group on GOKZ.TOP.

1. Sign in to [gokz.top](https://gokz.top).
2. Open [Admin Servers](https://gokz.top/admin/servers).
3. Open the `Server Group` tab.
4. Create a group for your community, or select an existing group you own.
5. Copy the API key from the `API Key` column.
6. Assign your GlobalAPI or public server rows to the same group.

## Configure The API Key

After `gokz-top-core` starts once, it creates:

```text
cfg/sourcemod/gokz-top/apikey.cfg
```

Paste your server group API key there:

```cfg
paste-your-server-group-api-key-here
```

Reload the API key or restart the server:

```cfg
gokz_top_reload_api_key
```

## Live Server Telemetry

`gokz-top-servers` publishes live map and player state to GOKZ.TOP. Version
0.2.0 adds each player's average round-trip ping and the CS:GO server's
net-graph-style `SV` and `VAR` frame metrics.

`SV` and `VAR` require the bundled `gokz-top-sv-var.games.txt` gamedata to
match the server engine. If those addresses are unavailable, the plugin logs
the problem once and continues publishing all other heartbeat fields,
including player ping. Older plugin versions remain supported by the website.

## Detected LJ Rooms

`gokz-top-ljroom` downloads the current map's detected long-jump rooms from
GOKZ.TOP when the map starts. It uses the API base URL configured by
`gokz-top-core`; the LJ-room read endpoint does not require an API key.

- `!lj [distance]` or `!ljroom [distance]` teleports to the exact or nearest
  detected block. The default distance is 260.
- `!ljdefault <distance>` saves a player's preferred distance; omit the value
  to display the current preference.
- `sm_ljreload` or `sm_reloadlj` refreshes the current map's data and requires
  root admin access when run by a player.

Like GOKZ's `!goto`, the command blocks teleporting during a valid run when
the player's safeguard is enabled. Otherwise it stops a running timer before
teleporting. Maps without detected rooms return an empty result and remain
playable normally.

## Jumpstat replay uploads

Install `gokz-top-replays.smx` with the bundled Linux `gokz_top_replay_fs.ext.so`
in `addons/sourcemod/extensions/`. The helper inspects filesystem entries with
`lstat` so discovery skips symbolic links. No recorder changes are required.

The uploader discovers both legacy player/type filenames and AXE UUID filenames
under `data/gokz-replays/_jumps/`. Identity and statistics come from the replay
header; players can disconnect before upload. Only normal-style supported jumps
are eligible: each player's best 10 LJs and best jump of each other type per mode.
The recorder must save a file first; this plugin does not record additional jumps.

Scanning processes at most 128 entries with a 2 ms budget every 100 ms and waits
60 seconds between complete passes. A private SQLite index avoids resubmitting
unchanged files. First installation starts at activation time; existing older
files require manual recovery. Subsequent reloads retain that activation floor
and discover files saved during downtime. Empty servers must process game ticks
for background work to progress.

Back up `data/sqlite/gokz-top-replays.sq3` and `data/gokz-top-replays/` together.
The latter contains immutable upload snapshots. Jobs retain their original API
URL and never store keys. A process-held filesystem lock elects one uploader
when multiple game instances share the same SourceMod directory; other instances
wait and take over automatically when it exits or hibernates. In-flight requests
are cancelled on hibernation, with a retry delay to let any accepted POST settle. One request runs at a time. Transient failures retry
with delays of 5, 15, 60, then 300 seconds, up to eight attempts. Authentication
failures pause; correct the key and run `sm_topreplays_retry`. That command also
resumes exhausted jobs. `sm_topreplays_status` shows queue counts and scan timing.
Rejected/ineligible snapshots are deleted; exhausted/authentication jobs remain.

To build the helper on Linux, provide a SourceMod SDK checkout **with its pinned
SourcePawn and AMTL submodules**, then run:

```bash
SOURCEMOD_SDK=/path/to/sourcemod \
SOURCEPAWN_SDK=/path/to/sourcemod/sourcepawn \
AMTL_SDK=/path/to/sourcemod/public/amtl \
  bash extensions/replay-filesystem/build.sh /output/gokz_top_replay_fs.ext.so
```

The build uses a multilib C++ compiler for CS:GO's 32-bit Linux runtime. Do not
substitute SourcePawn master headers for the SDK's pinned revision: their native
context ABI can differ. Release archives include the compiled helper.
