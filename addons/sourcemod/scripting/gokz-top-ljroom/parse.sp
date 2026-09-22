bool ParseLJRoomsResponse(const char[] body, const char[] expectedMap, int &spotCount)
{
	spotCount = 0;
	gA_Spots.Clear();

	JSON_Object root = json_decode(body);
	if (root == null || root.IsArray)
	{
		json_cleanup(root);
		return false;
	}

	char mapName[PLATFORM_MAX_PATH];
	if (!root.GetString("map_name", mapName, sizeof(mapName)) || !StrEqual(mapName, expectedMap))
	{
		json_cleanup(root);
		return false;
	}

	JSON_Object rooms = root.GetObject("rooms");
	if (rooms == null || !rooms.IsArray)
	{
		json_cleanup(root);
		return false;
	}

	for (int roomIndex = 0; roomIndex < rooms.Length; roomIndex++)
	{
		JSON_Object room = rooms.GetObjectIndexed(roomIndex);
		if (room == null || room.IsArray)
		{
			json_cleanup(root);
			gA_Spots.Clear();
			return false;
		}

		int roomRank = room.GetInt("rank");
		JSON_Object spots = room.GetObject("spots");
		if (roomRank < 0 || spots == null || !spots.IsArray)
		{
			json_cleanup(root);
			gA_Spots.Clear();
			return false;
		}

		for (int spotIndex = 0; spotIndex < spots.Length; spotIndex++)
		{
			JSON_Object source = spots.GetObjectIndexed(spotIndex);
			JSON_Object origin = source == null ? null : source.GetObject("origin");
			JSON_Object angles = source == null ? null : source.GetObject("angles");
			int distance = source == null ? -1 : source.GetInt("distance");
			if (source == null
				|| source.IsArray
				|| distance <= 0
				|| origin == null
				|| !origin.IsArray
				|| origin.Length != 3
				|| angles == null
				|| !angles.IsArray
				|| angles.Length != 2)
			{
				json_cleanup(root);
				gA_Spots.Clear();
				return false;
			}

			int spot[Spot_FieldCount];
			spot[Spot_Distance] = distance;
			spot[Spot_RoomRank] = roomRank;
			spot[Spot_OriginX] = view_as<int>(origin.GetFloatIndexed(0));
			spot[Spot_OriginY] = view_as<int>(origin.GetFloatIndexed(1));
			spot[Spot_OriginZ] = view_as<int>(origin.GetFloatIndexed(2));
			spot[Spot_Pitch] = view_as<int>(angles.GetFloatIndexed(0));
			spot[Spot_Yaw] = view_as<int>(angles.GetFloatIndexed(1));
			gA_Spots.PushArray(spot, sizeof(spot));
			spotCount++;
		}
	}

	json_cleanup(root);
	return true;
}
