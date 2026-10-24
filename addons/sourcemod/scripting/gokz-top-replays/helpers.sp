bool EndsWith(const char[] value, const char[] suffix)
{
	int valueLength = strlen(value);
	int suffixLength = strlen(suffix);
	if (suffixLength > valueLength)
	{
		return false;
	}

	return StrEqual(value[valueLength - suffixLength], suffix, false);
}

void ApplyCommonHeaders(Handle request, const char[] accept)
{
	SteamWorks_SetHTTPRequestHeaderValue(request, "Accept", accept);
	SteamWorks_SetHTTPRequestHeaderValue(request, "X-Request-Origin", GOKZ_TOP_REPLAYS_USER_AGENT);
	SteamWorks_SetHTTPRequestHeaderValue(request, "User-Agent", GOKZ_TOP_REPLAYS_USER_AGENT);
	SteamWorks_SetHTTPRequestUserAgentInfo(request, GOKZ_TOP_REPLAYS_USER_AGENT);
}

bool IsHTTPResponseOK(bool failure, bool requestSuccessful, EHTTPStatusCode statusCode)
{
	return !failure
		&& requestSuccessful
		&& statusCode >= k_EHTTPStatusCode200OK
		&& statusCode < k_EHTTPStatusCode300MultipleChoices;
}

bool ReadHTTPResponseBody(Handle request, char[] out, int maxLength)
{
	out[0] = '\0';

	int size;
	if (!SteamWorks_GetHTTPResponseBodySize(request, size) || size <= 0)
	{
		return false;
	}

	if (size >= maxLength) return false;

	bool ok = SteamWorks_GetHTTPResponseBodyData(request, out, size);
	out[size] = '\0';
	return ok;
}
