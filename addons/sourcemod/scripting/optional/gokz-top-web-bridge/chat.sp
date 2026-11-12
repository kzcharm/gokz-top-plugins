void SanitiseWebChat(char[] text, int length)
{
	Color_StripFromChatText(text, text, length);
	CRemoveColors(text, length);
}

void PrintWebMessages(JSONObject frame)
{
	bool structured = frame.HasKey("messages");
	JSONArray messages = view_as<JSONArray>(frame.Get(structured ? "messages" : "chat"));
	for (int i; i < messages.Length; i++)
	{
		char name[129], text[401], kind[16];
		if (structured)
		{
			JSONObject message = view_as<JSONObject>(messages.Get(i));
			message.GetString("name", name, sizeof(name));
			message.GetString("text", text, sizeof(text));
			message.GetString("kind", kind, sizeof(kind));
			delete message;
			SanitiseWebChat(name, sizeof(name));
		}
		else messages.GetString(i, text, sizeof(text));
		SanitiseWebChat(text, sizeof(text));
		for (int client = 1; client <= MaxClients; client++)
		{
			if (!IsClientInGame(client) || IsFakeClient(client)) continue;
			// Call the native directly so user percent signs are formatted only once.
			if (!structured) GOKZ_PrintToChat(client, false, "{default}%s", text);
			else if (StrEqual(kind, "chat"))
				GOKZ_PrintToChat(client, false, "{default}[Web] {lime}%s{default} : %s", name, text);
			else if (StrEqual(kind, "join"))
				GOKZ_PrintToChat(client, false, "%t", "Web Player Joined", name);
			else if (StrEqual(kind, "leave"))
				GOKZ_PrintToChat(client, false, "%t", "Web Player Left", name);
			else GOKZ_PrintToChat(client, false, "{grey}[Web] {lime}%s {grey}%s", name, text);
		}
		if (structured) PrintToServer("[Web] %s%s%s", name, StrEqual(kind, "chat") ? " : " : " ", text);
		else PrintToServer("%s", text);
	}
	delete messages;
}
