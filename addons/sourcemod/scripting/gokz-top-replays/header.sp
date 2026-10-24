bool ReadJumpReplayUploadHeader(const char[] replayPath, JumpReplayUploadHeader header)
{
	File file = OpenFile(replayPath, "rb");
	if (file == null)
	{
		return false;
	}

	int magic;
	int version;
	int replayType;
	if (!file.ReadInt32(magic)
		|| !file.ReadInt8(version)
		|| !file.ReadInt8(replayType)
		|| magic != GOKZ_TOP_REPLAY_MAGIC
		|| version != GOKZ_TOP_REPLAY_FORMAT_VERSION
		|| replayType != ReplayType_Jump)
	{
		delete file;
		return false;
	}

	if (!SkipReplayString(file) || !SkipReplayString(file))
	{
		delete file;
		return false;
	}

	int ignored;
	int timestamp;
	int account;
	int modeIndex;
	int styleIndex;
	if (!file.ReadInt32(ignored)
		|| !file.ReadInt32(ignored)
		|| !file.ReadInt32(timestamp)
		|| !SkipReplayString(file)
		|| !file.ReadInt32(account)
		|| !file.ReadInt8(modeIndex)
		|| !file.ReadInt8(styleIndex))
	{
		delete file;
		return false;
	}

	if (styleIndex != 0 || !GetModeName(modeIndex, header.mode, sizeof(JumpReplayUploadHeader::mode)))
	{
		delete file;
		return false;
	}

	for (int i = 0; i < 6; i++)
	{
		if (!file.ReadInt32(ignored))
		{
			delete file;
			return false;
		}
	}

	int jumpTypeIndex;
	int distanceRaw;
	if (!file.ReadInt8(jumpTypeIndex)
		|| !file.ReadInt32(distanceRaw)
		|| !GetJumpTypeName(jumpTypeIndex, header.jumpType, sizeof(JumpReplayUploadHeader::jumpType)))
	{
		delete file;
		return false;
	}

	if (account <= 0 || timestamp <= 0 || (distanceRaw & 0x7F800000) == 0x7F800000 || view_as<float>(distanceRaw) <= 0.0)
	{
		delete file;
		return false;
	}
	// Decimal addition avoids overflowing SourcePawn's signed 32-bit cells.
	AccountToSteam64(account, header.steamID64, sizeof(JumpReplayUploadHeader::steamID64));

	header.timestamp = timestamp;
	header.distance = view_as<float>(distanceRaw);
	if (!GOKZTop_FormatJumpDistance(header.distance, header.distanceText, sizeof(JumpReplayUploadHeader::distanceText))) { delete file; return false; }
	delete file;
	return true;
}

bool SkipReplayString(File file)
{
	int length;
	if (!file.ReadInt8(length))
	{
		return false;
	}

	char buffer[256];
	if (length >= sizeof(buffer))
	{
		return false;
	}

	return file.ReadString(buffer, sizeof(buffer), length) == length;
}

bool GetModeName(int modeIndex, char[] buffer, int maxLength)
{
	switch (modeIndex)
	{
		case 0: strcopy(buffer, maxLength, "VNL");
		case 1: strcopy(buffer, maxLength, "SKZ");
		case 2: strcopy(buffer, maxLength, "KZT");
		case 3: strcopy(buffer, maxLength, "NKZ");
		default: return false;
	}
	return true;
}

bool GetJumpTypeName(int jumpTypeIndex, char[] buffer, int maxLength)
{
	switch (jumpTypeIndex)
	{
		case JumpType_LongJump: strcopy(buffer, maxLength, "LJ");
		case JumpType_Bhop: strcopy(buffer, maxLength, "BH");
		case JumpType_MultiBhop: strcopy(buffer, maxLength, "MBH");
		case JumpType_WeirdJump: strcopy(buffer, maxLength, "WJ");
		case JumpType_LadderJump: strcopy(buffer, maxLength, "LAJ");
		case JumpType_Ladderhop: strcopy(buffer, maxLength, "LAH");
		case JumpType_Jumpbug: strcopy(buffer, maxLength, "JB");
		case JumpType_LowpreBhop: strcopy(buffer, maxLength, "LBH");
		case JumpType_LowpreWeirdJump: strcopy(buffer, maxLength, "LWJ");
		default: return false;
	}
	return true;
}

bool IsRetainableJumpType(int jumpType)
{
	char buffer[8];
	return GetJumpTypeName(jumpType, buffer, sizeof(buffer));
}

void FormatJumpReplayPath(char[] buffer, int maxLength, int client, int jumpType, int block, int mode, int style)
{
	if (block > 0)
	{
		BuildPath(Path_SM, buffer, maxLength,
			"%s/%d/%s/%d_%d_%s_%s.%s",
			RP_DIRECTORY_JUMPS,
			GetSteamAccountID(client),
			RP_DIRECTORY_BLOCKJUMPS,
			jumpType,
			block,
			gC_ModeNamesShort[mode],
			gC_StyleNamesShort[style],
			RP_FILE_EXTENSION);
		return;
	}

	BuildPath(Path_SM, buffer, maxLength,
		"%s/%d/%d_%s_%s.%s",
		RP_DIRECTORY_JUMPS,
		GetSteamAccountID(client),
		jumpType,
		gC_ModeNamesShort[mode],
		gC_StyleNamesShort[style],
		RP_FILE_EXTENSION);
}

bool IsValidUploadClient(int client)
{
	return 0 < client <= MaxClients
		&& IsClientInGame(client)
		&& !IsFakeClient(client)
		&& GetSteamAccountID(client) > 0;
}


void AccountToSteam64(int account, char[] output, int length)
{
	strcopy(output, length, "76561197960265728");
	int carry = account;
	for (int i = strlen(output) - 1; i >= 0 && carry > 0; i--)
	{
		int digit = output[i] - '0' + carry % 10;
		carry /= 10;
		if (digit >= 10) { digit -= 10; carry++; }
		output[i] = '0' + digit;
	}
}
