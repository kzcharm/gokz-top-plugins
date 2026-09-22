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
