Handle gH_Request, gH_DisableRequest;
int gI_Requests, gI_Waits;
#define BRIDGE_HTTP_MAX_BODY (16 * 1024 * 1024)

Handle SendBridgeRequest(JSONObject body, bool disabling = false, bool waiting = false)
{
	// RIP's ToString reports success on truncation; leave room for a partial UTF-8 character.
	for (int capacity = 65536; capacity <= BRIDGE_HTTP_MAX_BODY; capacity *= 2)
	{
		char[] payload = new char[capacity];
		if (!body.ToString(payload, capacity, JSON_COMPACT)) return null;
		int length = strlen(payload);
		if (length >= capacity - 4) continue;
		Handle request = SteamWorks_CreateHTTPRequest(k_EHTTPMethodPOST, gC_URL);
		if (request == null) return null;
		if (!SteamWorks_SetHTTPRequestHeaderValue(request, "X-Bridge-Key", gC_Key)
			|| !SteamWorks_SetHTTPRequestHeaderValue(request, "X-Bridge-Server", gC_Server)
			|| !SteamWorks_SetHTTPRequestHeaderValue(request, "Accept", "application/json")
			|| !SteamWorks_SetHTTPRequestAbsoluteTimeoutMS(request, waiting ? 25000 : 3000)
			|| !SteamWorks_SetHTTPRequestRequiresVerifiedCertificate(request, true)
			|| !SteamWorks_SetHTTPRequestRawPostBody(request, "application/json", payload, length)
			|| !SteamWorks_SetHTTPRequestContextValue(request, gI_Epoch, disabling)
			|| !SteamWorks_SetHTTPCallbacks(request, OnBridgeHTTPCompleted)
			|| !SteamWorks_SendHTTPRequest(request))
		{
			delete request;
			return null;
		}
		gI_Requests++;
		if (waiting) gI_Waits++;
		return request;
	}
	return null;
}

public void OnBridgeHTTPCompleted(Handle request, bool failure, bool successful, EHTTPStatusCode status, int epoch, bool disabling)
{
	if (disabling)
	{
		if (request == gH_DisableRequest) gH_DisableRequest = null;
		delete request;
		return;
	}
	if (request != gH_Request || epoch != gI_Epoch || !gB_Enabled)
	{
		if (request == gH_Request) gH_Request = null;
		delete request;
		return;
	}
	gH_Request = null;
	int size;
	bool valid = !failure && successful && status == k_EHTTPStatusCode200OK
		&& SteamWorks_GetHTTPResponseBodySize(request, size) && size > 0 && size < BRIDGE_HTTP_MAX_BODY;
	if (!valid)
	{
		delete request;
		OnFrame(view_as<int>(status), "SteamWorks request failed or response empty/oversized", "");
		return;
	}
	char[] payload = new char[size + 1];
	valid = SteamWorks_GetHTTPResponseBodyData(request, payload, size);
	payload[size] = 0;
	delete request;
	OnFrame(view_as<int>(status), valid ? "" : "Unable to read SteamWorks response", valid ? payload : "");
}
