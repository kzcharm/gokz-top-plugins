# gokz-top-plugins

SourceMod plugins for integrating a GOKZ server with [GOKZ.TOP](https://gokz.top).

## Plugins

| Plugin | Purpose |
| --- | --- |
| `gokz-top-core` | Provides shared API access, authentication, and HTTP utilities for the other plugins. |
| `gokz-top-records` | Uploads completed runs and their replays to GOKZ.TOP, with persistent queues and retries. |
| `gokz-top-replays` | Uploads eligible jumpstat replay files recorded on the server. |
| `gokz-top-profile` | Displays player profiles, ranks, ratings, tags, and scoreboard levels. |
| `gokz-top-reviews` | Lets players rate maps and browse map comments in-game. |
| `gokz-top-servers` | Publishes live server status, including the current map, players, and performance metrics. |
| `gokz-top-ljroom` | Lets players teleport to detected long-jump blocks on the current map. |
| `gokz-top-web-bridge` (optional) | Connects browser players to the native server through mirror bots and shared chat. |

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
