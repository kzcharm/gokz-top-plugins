enum Lookup { MapInfo, CourseWR, NubPB, ProPB, NubRank, ProRank, LongJump, ReplayProfile };
enum struct PersonalBest
{
    bool known;
    float time;
    int points;
    int teleports;
    int rank;
    int total;
}
enum struct Card
{
    int mode;
    int course;
    int tier;
    float wr;
    float siteLJ;
    float localLJ;
    int refreshAt;
    int jumpOffset;
    float rating;
    int globalRank;
    int regionalRank;
    char region[16];
}
Card g_Card[MAXPLAYERS + 1];
PersonalBest g_PB[MAXPLAYERS + 1][2];
int g_Generation[MAXPLAYERS + 1];
char g_Map[PLATFORM_MAX_PATH], g_DisplayMap[PLATFORM_MAX_PATH];

char g_ReplaySteam[MAXPLAYERS + 1][32];

public void GOKZ_RP_OnReplayBotSpawn(int caller, int bot, int account, int weapon, int knife, const char[] path)
{
    if (bot <= 0 || bot > MaxClients) return;
    ResetCard(bot);
    g_ReplaySteam[bot][0] = 0;
    if (!account) return;
    // Add the unsigned account number to the SteamID64 base in decimal on 32-bit SourcePawn.
    char digits[12];
    FormatEx(digits, sizeof(digits), "%u", account);
    strcopy(g_ReplaySteam[bot], sizeof(g_ReplaySteam[]), "76561197960265728");
    int j = strlen(digits) - 1, carry;
    for (int i = 16; i >= 0 && (j >= 0 || carry); i--)
    {
        int sum = g_ReplaySteam[bot][i] - '0' + carry;
        if (j >= 0) sum += digits[j--] - '0';
        g_ReplaySteam[bot][i] = '0' + sum % 10;
        carry = sum / 10;
    }
}

bool CardSteamID(int player, char[] steam, int size)
{
    if (!IsFakeClient(player)) return GetClientAuthId(player, AuthId_SteamID64, steam, size);
    return strcopy(steam, size, g_ReplaySteam[player]) > 0;
}

int ReplayCourse(int player)
{
    // The playback plugin tags bonus runs as "<mode> B<number> <category>".
    char tag[32], fields[3][12];
    CS_GetClientClanTag(player, tag, sizeof(tag));
    if (ExplodeString(tag, " ", fields, sizeof(fields), sizeof(fields[])) == 3 && fields[1][0] == 'B')
        return StringToInt(fields[1][1]);
    return 0;
}

void ResetCard(int player)
{
    Card empty;
    PersonalBest noPB;
    g_Card[player] = empty;
    g_Card[player].mode = -1;
    g_PB[player][0] = noPB;
    g_PB[player][1] = noPB;
    g_Generation[player]++;
}

DataPack CardContext(int player)
{
    DataPack pack = new DataPack();
    pack.WriteCell(GetClientUserId(player));
    pack.WriteCell(g_Generation[player]);
    return pack;
}

int ReadContext(DataPack pack)
{
    pack.Reset();
    int player = GetClientOfUserId(pack.ReadCell());
    int generation = pack.ReadCell();
    return player && g_Generation[player] == generation ? player : 0;
}

void LookupCard(int player, Lookup kind, const char[] path, const char[] mapParameter = "")
{
    char base[512], unusedKey[256], url[1024];
    GOKZTop_GetHTTPConfig(base, sizeof(base), unusedKey, sizeof(unusedKey));
    FormatEx(url, sizeof(url), "%s%s", base, path);
    Handle req = SteamWorks_CreateHTTPRequest(k_EHTTPMethodGET, url);
    if (req == null) return;
    SteamWorks_SetHTTPRequestHeaderValue(req, "Accept", "application/json");
    SteamWorks_SetHTTPRequestUserAgentInfo(req, "gokz-top-board/2.0");
    if (mapParameter[0] && !SteamWorks_SetHTTPRequestGetOrPostParameter(req, mapParameter, g_DisplayMap))
    {
        delete req;
        return;
    }
    DataPack pack = CardContext(player);
    pack.WriteCell(kind);
    SteamWorks_SetHTTPRequestContextValue(req, pack);
    SteamWorks_SetHTTPCallbacks(req, CardResponse);
    SteamWorks_SetHTTPRequestAbsoluteTimeoutMS(req, 12000);
    if (!SteamWorks_SendHTTPRequest(req))
    {
        delete req;
        delete pack;
    }
}

public void LoadCard(DataPack pack)
{
    int player = ReadContext(pack);
    delete pack;
    if (!player) return;
    char steam[32];
    if (!CardSteamID(player, steam, sizeof(steam))) return;
    int mode = g_Card[player].mode;
    int stage = g_Card[player].course;
    char path[320], scope[8];
    strcopy(scope, sizeof(scope), mode == Mode_NoPerfKZ ? "OVR" : gC_ModeNamesShort[mode]);
    if (IsFakeClient(player))
    {
        FormatEx(path, sizeof(path), "/v1/leaderboards/players/%s?scope=%s", steam, scope);
        LookupCard(player, ReplayProfile, path);
    }
    else if (!GOKZTop_IsLeaderboardDataLoaded(player, mode)) GOKZTop_RefreshLeaderboardData(player, mode);
    LookupCard(player, MapInfo, "/v1/maps?limit=1", "name");
    for (int pro = 0; pro < 2; pro++)
    {
        FormatEx(path, sizeof(path), "/v1/records/pb?stage=%d&identifier=%s&scope=%s&type=%s&limit=1", stage, steam, scope, pro ? "PRO" : "NUB");
        LookupCard(player, pro ? ProPB : NubPB, path, "map_name");
    }
    g_Card[player].jumpOffset = 0;
    LookupJumpPage(player);
    LoadLocalJump(player, steam);
}

void LookupJumpPage(int player)
{
    char steam[32], path[256];
    if (!CardSteamID(player, steam, sizeof(steam))) return;
    FormatEx(path, sizeof(path), "/v1/players/%s/jumpstats?mode=%s&type=LJ&offset=%d&limit=12&sort_by=distance&sort_order=desc",
        steam, gC_ModeNamesShort[g_Card[player].mode], g_Card[player].jumpOffset);
    LookupCard(player, LongJump, path);
}

void LoadLocalJump(int player, const char[] steam)
{
    if (GetFeatureStatus(FeatureType_Native, "GOKZ_DB_GetDatabase") != FeatureStatus_Available) return;
    Database db = GOKZ_DB_GetDatabase();
    if (db == null) return;
    char driver[24];
    db.Driver.GetIdentifier(driver, sizeof(driver));
    if (StrEqual(driver, "pgsql"))
    {
        char query[256];
        FormatEx(query, sizeof(query), "SELECT MAX(distance) FROM gokz.jumpstat WHERE steamid64=%s AND mode=%d AND jump_type=%d AND NOT is_block_jump", steam, g_Card[player].mode, JumpType_LongJump);
        db.Query(LocalJumpResult, query, CardContext(player));
    }
    delete db;
}

public void LocalJumpResult(Database db, DBResultSet rows, const char[] error, DataPack pack)
{
    int player = ReadContext(pack);
    delete pack;
    if (!player || rows == null || !rows.FetchRow() || rows.IsFieldNull(0)) return;
    float distance = rows.FetchFloat(0) / GOKZ_DB_JS_DISTANCE_PRECISION;
    if (distance > g_Card[player].localLJ) g_Card[player].localLJ = distance;
}

public void GOKZ_DB_OnJumpstatPB(int player, int type, int mode, float distance, int block, int strafes, float sync, float pre, float max, int airtime)
{
    if (player > 0 && type == JumpType_LongJump && !block && mode == g_Card[player].mode && distance > g_Card[player].localLJ)
        g_Card[player].localLJ = distance;
}

float JSONNumber(JSON_Object row, const char[] key)
{
    if (row.GetKeyType(key) == Type_Int) return float(row.GetInt(key));
    return row.GetKeyType(key) == Type_Float ? row.GetFloat(key) : 0.0;
}

public void CardResponse(Handle req, bool failed, bool success, EHTTPStatusCode status, DataPack pack)
{
    int player = ReadContext(pack);
    Lookup kind = pack.ReadCell();
    delete pack;
    int size;
    if (player && !failed && success && status == k_EHTTPStatusCode200OK && SteamWorks_GetHTTPResponseBodySize(req, size) && size > 0 && size < 32768)
    {
        char[] body = new char[size + 1];
        if (SteamWorks_GetHTTPResponseBodyData(req, body, size))
        {
            body[size] = 0;
            JSON_Object root = json_decode(body);
            if (root != null)
            {
                ApplyLookup(player, kind, root);
                root.Cleanup();
                delete root;
            }
        }
    }
    delete req;
}

void ApplyLookup(int player, Lookup kind, JSON_Object root)
{
    if (kind == ReplayProfile)
    {
        g_Card[player].rating = JSONNumber(root, "rating");
        g_Card[player].globalRank = root.GetInt("global_rank");
        g_Card[player].regionalRank = root.GetInt("rank_regional");
        root.GetString("region", g_Card[player].region, sizeof(g_Card[].region));
        return;
    }
    JSON_Object list = root.IsArray ? root : root.GetObject("data");
    if (list == null || !list.IsArray) return;
    int pro = (kind == ProPB || kind == ProRank) ? 1 : 0;
    if (!list.Length)
    {
        if (kind == NubPB || kind == ProPB)
        {
            PersonalBest empty;
            g_PB[player][pro] = empty;
            g_PB[player][pro].known = true;
        }
        if (kind == CourseWR) g_Card[player].wr = 0.0;
        if (kind == LongJump) g_Card[player].siteLJ = 0.0;
        return;
    }
    JSON_Object row = list.GetObjectIndexed(0);
    if (row == null) return;
    int mode = g_Card[player].mode;
    char scope[8];
    strcopy(scope, sizeof(scope), mode == Mode_NoPerfKZ ? "OVR" : gC_ModeNamesShort[mode]);
    switch (kind)
    {
        case MapInfo:
        {
            char name[PLATFORM_MAX_PATH];
            JSON_Object tiers = row.GetObject("tiers");
            if (!row.GetString("name", name, sizeof(name)) || !StrEqual(name, g_DisplayMap, false)) return;
            if (!g_Card[player].course && tiers != null) g_Card[player].tier = tiers.GetInt(scope);
            char path[160];
            FormatEx(path, sizeof(path), "/v1/maps/%d/leaderboard?scope=%s&type=NUB&stage=%d&limit=1", row.GetInt("id"), scope, g_Card[player].course);
            LookupCard(player, CourseWR, path);
        }
        case CourseWR:
        {
            g_Card[player].wr = JSONNumber(row, "time");
            if (g_Card[player].course > 0) g_Card[player].tier = row.GetInt("map_tier");
        }
        case LongJump:
        {
            // GOKZ.TOP stores ordinary jumps with block=null; block=0 excludes them.
            for (int i = 0; i < list.Length; i++)
            {
                JSON_Object jump = list.GetObjectIndexed(i);
                if (jump != null && (jump.GetKeyType("block") == Type_Null || jump.GetInt("block") == 0))
                {
                    g_Card[player].siteLJ = JSONNumber(jump, "distance");
                    return;
                }
            }
            g_Card[player].jumpOffset += list.Length;
            if (g_Card[player].jumpOffset < root.GetInt("count")) LookupJumpPage(player);
            else g_Card[player].siteLJ = 0.0;
        }
        case NubPB, ProPB:
        {
            char uuid[40], path[180];
            if (!row.GetString("uuid", uuid, sizeof(uuid)) || strlen(uuid) != 36) return;
            PersonalBest pb;
            pb.known = true;
            pb.time = JSONNumber(row, "time");
            pb.teleports = row.GetInt("teleports");
            pb.points = row.GetInt("points");
            g_PB[player][pro] = pb;
            FormatEx(path, sizeof(path), "/v1/records/rank?uuid_list=%s&scope=%s&type=%s", uuid, scope, pro ? "PRO" : "NUB");
            LookupCard(player, pro ? ProRank : NubRank, path);
        }
        case NubRank, ProRank:
        {
            g_PB[player][pro].rank = row.GetInt("rank");
            g_PB[player][pro].total = row.GetInt("total_count");
        }
    }
}

public void GOKZTop_OnRecordAccepted(const char[] apiBaseURL, const char[] steam, const char[] map, int course, int mode, float runTime, int teleports, const char[] recordUUID)
{
    if (!StrEqual(map, g_Map, false) && !StrEqual(map, g_DisplayMap, false)) return;
    for (int i = 1; i <= MaxClients; i++)
    {
        int cached = g_Card[i].mode;
        if (cached < 0 || g_Card[i].course != course) continue;
        if (cached == Mode_NoPerfKZ || (cached == Mode_KZTimer && mode == Mode_NoPerfKZ) || cached == mode)
        {
            g_Generation[i]++;
            g_Card[i].refreshAt = 0;
        }
    }
}

void RecordTime(float time, char[] out, int length)
{
    int ms = RoundToNearest(time * 1000.0);
    FormatEx(out, length, "%d:%02d.%03d", ms / 60000, ms / 1000 % 60, ms % 1000);
}

void PBLine(int viewer, int player, int pro, char[] out, int length)
{
    PersonalBest pb;
    pb = g_PB[player][pro];
    char value[128] = "-";
    if (pb.time > 0.0)
    {
        char clock[24], place[32] = "-";
        RecordTime(pb.time, clock, sizeof(clock));
        if (pb.rank > 0 && pb.total > 0) FormatEx(place, sizeof(place), "#%d/%d", pb.rank, pb.total);
        FormatEx(value, sizeof(value), "%s | %s | %d %T", clock, place, pb.points, "Score points", viewer);
        if (!pro && pb.teleports > 0) Format(value, sizeof(value), "%s | %d TP", value, pb.teleports);
    }
    else if (pb.known)
    {
        out[0] = 0;
        if (!pro) FormatEx(out, length, "NUB PB - %T", "Unfinished", viewer);
        return;
    }
    FormatEx(out, length, "%s PB  %s", pro ? "PRO" : "NUB", value);
}

void ShowScoreCard(int viewer)
{
    int player = ObservedRunner(viewer);
    if (!player) player = viewer;
    HUDInfo playback;
    bool replay = player > 0 && IsFakeClient(player);
    if (replay)
    {
        if (GetFeatureStatus(FeatureType_Native, "GOKZ_RP_GetPlaybackInfo") == FeatureStatus_Available)
            GOKZ_RP_GetPlaybackInfo(player, playback);
        if (playback.ID != player) player = 0;
    }
    if (!player)
    {
        ClearScoreCard(viewer);
        return;
    }
    int mode = GOKZ_GetCoreOption(player, Option_Mode);
    bool running = replay ? playback.TimerRunning : GOKZ_GetTimerRunning(player);
    int course = running ? (replay ? ReplayCourse(player) : GOKZ_GetCourse(player)) : 0;
    if (mode != g_Card[player].mode || course != g_Card[player].course)
    {
        ResetCard(player);
        g_Card[player].mode = mode;
        g_Card[player].course = course;
    }
    if (GetTime() >= g_Card[player].refreshAt)
    {
        g_Card[player].refreshAt = GetTime() + 60;
        g_Generation[player]++;
        RequestFrame(LoadCard, CardContext(player));
    }
    char run[120], rating[16] = "-", global[16] = "-", region[24], regional[16] = "-";
    if (running)
    {
        char clock[24];
        strcopy(clock, sizeof(clock), GOKZ_FormatTime(replay ? playback.Time : GOKZ_GetTime(player),
            GOKZ_HUD_GetOption(viewer, HUDOption_TimerStyle) == TimerStyle_Precise));
        FormatEx(run, sizeof(run), "%T  %s | %d TP", (replay ? playback.Paused : GOKZ_GetPaused(player)) ? "Paused" : (replay || GOKZ_GetValidTimer(player) ? "Run" : "Practice"), viewer, clock, replay ? playback.CurrentTeleport : GOKZ_GetTeleportCount(player));
        if (!replay && GetFeatureStatus(FeatureType_Native, "GOKZ_PG_IsEnabled") == FeatureStatus_Available && GOKZ_PG_IsEnabled(player))
            Format(run, sizeof(run), "%s | %.1f%%", run, GOKZ_PG_GetProgress(player) * 100.0);
    }
    if (replay || GOKZTop_IsLeaderboardDataLoaded(player, mode))
    {
        float scaled = replay ? g_Card[player].rating : GOKZTop_GetRating(player, mode);
        if (scaled > 0.0) FormatEx(rating, sizeof(rating), "%.2f", scaled);
        int rank = replay ? g_Card[player].globalRank : GOKZTop_GetGlobalRank(player, mode);
        if (rank > 0) FormatEx(global, sizeof(global), "#%d", rank);
        if (replay ? g_Card[player].regionalRank > 0 : GOKZTop_HasRegionalRank(player, mode))
        {
            if (replay) strcopy(region, sizeof(region), g_Card[player].region);
            else GOKZTop_GetRegionCode(player, mode, region, sizeof(region));
            FormatEx(regional, sizeof(regional), "#%d", replay ? g_Card[player].regionalRank : GOKZTop_GetRegionalRank(player, mode));
        }
    }
    if (!region[0]) FormatEx(region, sizeof(region), "%T", "Region", viewer);
    char lj[16] = "-", wr[24] = "-", tier[12] = "-", stage[32], nub[144], pro[144];
    float distance = FloatMax(g_Card[player].localLJ, g_Card[player].siteLJ);
    if (distance > 0.0) FormatEx(lj, sizeof(lj), "%.2f", distance);
    if (g_Card[player].wr > 0.0) RecordTime(g_Card[player].wr, wr, sizeof(wr));
    if (g_Card[player].tier > 0) FormatEx(tier, sizeof(tier), "T%d", g_Card[player].tier);
    if (course) FormatEx(stage, sizeof(stage), "%T %d | ", "Bonus course", viewer, course);
    PBLine(viewer, player, 0, nub, sizeof(nub));
    PBLine(viewer, player, 1, pro, sizeof(pro));
    SetHudTextParams(-1.0, 0.110, 0.65, 255, 219, 149, 255, 0, 0.0, 0.0, 0.0);
    ShowSyncHudText(viewer, g_MapHud, "%s | %s%s | NUB WR %s", g_DisplayMap, stage, tier, wr);
    SetHudTextParams(-1.0, 0.150, 0.65, 221, 241, 255, 255, 0, 0.0, 0.0, 0.0);
    ShowSyncHudText(viewer, g_ScoreHud, "Rt %s | %T %s | %s %s | LJ %s\n%s%s%s",
        rating, "World rank", viewer, global, region, regional, lj, nub, pro[0] ? "\n" : "", pro);
    if (running)
    {
        SetHudTextParams(-1.0, 0.735, 0.65, 221, 241, 255, 255, 0, 0.0, 0.0, 0.0);
        ShowSyncHudText(viewer, g_RunHud, "%s", run);
    }
}
