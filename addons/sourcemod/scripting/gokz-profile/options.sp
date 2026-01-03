
// =====[ OPTIONS ]=====

void OnOptionsMenuReady_Options()
{
	RegisterOptions();
}

void RegisterOptions()
{
	for (ProfileOption option; option < PROFILEOPTION_COUNT; option++)
	{
		int maxValue = gI_ProfileOptionCounts[option] - 1;
		
		// Extend max value for TagType option if gokz-top-core is available
		if (option == ProfileOption_TagType && LibraryExists("gokz-top-core"))
		{
			maxValue = ProfileTagType_Rating; // Highest extended tag type
		}
		
		GOKZ_RegisterOption(gC_ProfileOptionNames[option], gC_ProfileOptionDescriptions[option], 
			OptionType_Int, gI_ProfileOptionDefaults[option], 0, maxValue);
	}
}



// =====[ OPTIONS MENU ]=====

TopMenu gTM_Options;
TopMenuObject gTMO_CatProfile;
TopMenuObject gTMO_ItemsProfile[PROFILEOPTION_COUNT];

void OnOptionsMenuCreated_OptionsMenu(TopMenu topMenu)
{
	if (gTM_Options == topMenu && gTMO_CatProfile != INVALID_TOPMENUOBJECT)
	{
		return;
	}
	
	gTMO_CatProfile = topMenu.AddCategory(PROFILE_OPTION_CATEGORY, TopMenuHandler_Categories);
}

void OnOptionsMenuReady_OptionsMenu(TopMenu topMenu)
{
	// Make sure category exists
	if (gTMO_CatProfile == INVALID_TOPMENUOBJECT)
	{
		GOKZ_OnOptionsMenuCreated(topMenu);
	}
	
	if (gTM_Options == topMenu)
	{
		return;
	}
	
	gTM_Options = topMenu;
	
	// Add gokz-profile option items	
	for (int option = 0; option < view_as<int>(PROFILEOPTION_COUNT); option++)
	{
		gTMO_ItemsProfile[option] = gTM_Options.AddItem(gC_ProfileOptionNames[option], TopMenuHandler_Profile, gTMO_CatProfile);
	}
}

void DisplayProfileOptionsMenu(int client)
{
	if (gTMO_CatProfile != INVALID_TOPMENUOBJECT)
	{
		gTM_Options.DisplayCategory(gTMO_CatProfile, client);
	}
}

public void TopMenuHandler_Categories(TopMenu topmenu, TopMenuAction action, TopMenuObject topobj_id, int param, char[] buffer, int maxlength)
{
	if (action == TopMenuAction_DisplayOption || action == TopMenuAction_DisplayTitle)
	{
		if (topobj_id == gTMO_CatProfile)
		{
			Format(buffer, maxlength, "%T", "Options Menu - Profile", param);
		}
	}
}

public void TopMenuHandler_Profile(TopMenu topmenu, TopMenuAction action, TopMenuObject topobj_id, int param, char[] buffer, int maxlength)
{
	ProfileOption option = PROFILEOPTION_INVALID;
	for (int i = 0; i < view_as<int>(PROFILEOPTION_COUNT); i++)
	{
		if (topobj_id == gTMO_ItemsProfile[i])
		{
			option = view_as<ProfileOption>(i);
			break;
		}
	}
	
	if (option == PROFILEOPTION_INVALID)
	{
		return;
	}
	
	if (action == TopMenuAction_DisplayOption)
	{
		if (option == ProfileOption_TagType)
		{
			int tagType = GOKZ_GetOption(param, gC_ProfileOptionNames[option]);
			char tagTypeName[64];
			
			// Handle extended tag types
			if (tagType == ProfileTagType_GlobalRank)
			{
				FormatEx(tagTypeName, sizeof(tagTypeName), "Global Rank");
			}
			else if (tagType == ProfileTagType_RegionalRank)
			{
				FormatEx(tagTypeName, sizeof(tagTypeName), "Regional Rank");
			}
			else if (tagType == ProfileTagType_Rating)
			{
				FormatEx(tagTypeName, sizeof(tagTypeName), "Rating");
			}
			else if (tagType < PROFILETAGTYPE_COUNT)
			{
				// Use translation for standard tag types
				FormatEx(tagTypeName, sizeof(tagTypeName), "%T", gC_ProfileTagTypePhrases[tagType], param);
			}
			else
			{
				FormatEx(tagTypeName, sizeof(tagTypeName), "Unknown");
			}
			
			FormatEx(buffer, maxlength, "%T - %s",
					gC_ProfileOptionPhrases[option], param,
					tagTypeName);
		}
		else
		{
			FormatEx(buffer, maxlength, "%T - %T",
					gC_ProfileOptionPhrases[option], param,
					gC_ProfileBoolPhrases[GOKZ_GetOption(param, gC_ProfileOptionNames[option])], param);
		}
	}
	else if (action == TopMenuAction_SelectOption)
	{
		if (option == ProfileOption_TagType)
		{
			int currentTagType = GOKZ_GetOption(param, gC_ProfileOptionNames[option]);
			int maxTagType = PROFILETAGTYPE_COUNT - 1;
			
			// Extend max to include new tag types if gokz-top-core is available
			if (LibraryExists("gokz-top-core"))
			{
				maxTagType = ProfileTagType_Rating; // Highest extended tag type
			}
			
			// Find next usable tag type starting from current + 1
			int nextTagType = currentTagType;
			int startTagType = currentTagType;
			int attempts = 0;
			int maxAttempts = maxTagType + 1;
			bool foundTagType = false;
			
			// Cycle through all possible tag types
			while (!foundTagType && attempts < maxAttempts)
			{
				nextTagType++;
				if (nextTagType > maxTagType)
				{
					nextTagType = 0; // Wrap around to Rank
				}
				attempts++;
				
				// Check if this tag type is usable
				if (CanUseTagType(param, nextTagType))
				{
					foundTagType = true;
				}
				// Safety: if we've cycled back to start, default to Rank
				else if (nextTagType == startTagType)
				{
					nextTagType = ProfileTagType_Rank; // Rank is always usable
					foundTagType = true;
				}
			}
			
			// Fallback: if we exhausted all attempts, default to Rank
			if (!foundTagType)
			{
				nextTagType = ProfileTagType_Rank; // Rank is always usable
			}
			
			// Set the tag type
			char optionName[64];
			strcopy(optionName, sizeof(optionName), gC_ProfileOptionNames[option]);
			GOKZ_SetOption(param, optionName, nextTagType);
		}
		else
		{
			GOKZ_CycleOption(param, gC_ProfileOptionNames[option]);
		}

		gTM_Options.Display(param, TopMenuPosition_LastCategory);
	}
}



