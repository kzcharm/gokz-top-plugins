"""Read-only smoke check for the public API fields consumed by the scoreboard."""
import json
from urllib.parse import urlencode
from urllib.request import Request, urlopen


def get(path, **params):
    url = f"https://api.gokz.top/v1/{path}?{urlencode(params)}"
    request = Request(url, headers={"User-Agent": "GOKZ.TOP scoreboard contract check", "Accept": "application/json"})
    with urlopen(request, timeout=15) as response:
        return json.load(response)


def check():
    map_name = "kz_ominous2"
    scope = "KZT"
    course = 0
    map_info, = get("maps", name=map_name, limit=1)
    assert map_info["name"] == map_name and map_info["tiers"][scope] > 0
    for category in ("NUB", "PRO"):
        bucket = dict(scope=scope, stage=course, type=category)
        leader, = get(f"maps/{map_info['id']}/leaderboard", **bucket, limit=1)["data"]
        steam = leader["player"]["steamid64"]
        pb, = get("records/pb", map_name=map_name, identifier=steam, **bucket, limit=1)
        assert pb["stage"] == course and pb["time"] == leader["time"] > 0
        assert pb["points"] >= 0 and pb["teleports"] >= 0
        rank, = get("records/rank", uuid_list=pb["uuid"], scope=scope, type=category)["data"]
        assert rank["record_uuid"] == pb["uuid"] and 1 <= rank["rank"] <= rank["total_count"]
        profile = get(f"leaderboards/players/{steam}", scope=scope)
        assert profile["player"]["steamid64"] == steam
        assert 1 <= profile["rating"] <= 11 and profile["global_rank"] > 0
        assert not profile["rank_regional"] or profile["region"]


if __name__ == "__main__":
    check()
    print("Scoreboard API contract passed")
