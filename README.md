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
