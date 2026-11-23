# gokz-top-plugins

SourceMod plugins for integrating a GOKZ server with [GOKZ.TOP](https://gokz.top).

## Plugins

| Plugin | Purpose |
| --- | --- |
| `gokz-top-core` | Provides shared API access, authentication, and HTTP utilities for the other plugins. |
| `gokz-top-records` | Uploads completed runs and their replays to GOKZ.TOP, with persistent queues and retries. |
| `gokz-top-replays` | Uploads eligible jumpstat replay files recorded on the server. |
| `gokz-top-board` | Shows player stats and course records while holding Tab. |
| `gokz-top-profile` | Displays player profiles, ranks, ratings, tags, and scoreboard levels. |
| `gokz-top-reviews` | Lets players rate maps and browse map comments in-game. |
| `gokz-top-servers` | Publishes live server status, including the current map, players, and performance metrics. |
| `gokz-top-ljroom` | Lets players teleport to detected long-jump blocks on the current map. |
| `gokz-top-web-bridge` (optional) | Connects browser players to the native server through mirror bots and shared chat. |

## Player scoreboard

Use `!tabinfo` to toggle the overlay. Your preference is saved across reconnects. Hold Tab for your player card or the card of the runner you are watching. AXE replay bots use the recorded runner’s SteamID from the replay spawn event. Free camera shows your own card. An active run appears below the scoreboard with the configured GOKZ timer format, teleports and optional route progress. The card shows the public scaled rating, global and regional ranks, best ordinary LJ distance, course tier, NUB WR and both course PBs. The NUB line includes the saved teleport count when positive. PB ranks and totals use GOKZ.TOP leaderboard categories. NKZ uses the site's overall ranking scope and its own LJ mode.

Install `gokz-top-board.smx` and `translations/kz_ui.phrases.txt` alongside `gokz-top-core`. The board works with the stock client. The progress plugin and local jump database are optional. The AXE PostgreSQL backend supplies saved local jump distances. The board also listens for new local jump PBs. Updating `gokz-top-records` enables immediate PB refresh after an accepted submission.

When upgrading the development example, unload `kz_ui` and move `plugins/kz_ui.smx` into `plugins/disabled/` before loading `gokz-top-board`. Tap Tab or use `!kzboard` for the roster, `!kzplayer` for player details and `!kzsettings` for HUD preferences.

## Requirements

- SourceMod 1.11+
- SteamWorks extension
- Existing GOKZ installation
- A GOKZ.TOP server group API key

The optional web bridge additionally needs REST in Pawn for JSON, SDKHooks and
basecomm. Version 0.7.1 uses SteamWorks for HTTP, including disable notifications;
it does not call REST in Pawn's HTTP client. Install this plugin separately from
normal release packages and opt in per server. `sm_webbridge_status` reports the
transport and last HTTP result. SteamWorks follows redirects with custom headers;
use only trusted canonical HTTPS exchange URLs and trusted redirect destinations.
Version 0.8.0 waits for an authenticated browser join before capturing native
players or forwarding chat. Empty rooms keep one lightweight waiting request,
renewed about every 20 seconds, so discovery stays available. The last browser
departure stops movement work and returns the plugin to waiting.

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
