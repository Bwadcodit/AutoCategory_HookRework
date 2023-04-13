local AC = AutoCategory
local LCK = LibCharacterKnowledge

-- A very simple plugin for several one-liner addons which only have
-- a single rule function to register.
--
-- No strings or predefined rules to load.

AutoCategory_MiscAddons = {
    RuleFunc = {},
}

--Initialize plugin for Auto Category - Misc Addons
function AutoCategory_MiscAddons.Initialize()
    -- Master Merchant
	AutoCategory.AddRuleFunc("getpricemm", 
		AutoCategory_MiscAddons.RuleFunc.GetPriceMM)
	AutoCategory.AddRuleFunc("mm_getprice", 
		AutoCategory_MiscAddons.RuleFunc.GetPriceMM)
	
    -- Tamriel Trade Center
	AutoCategory.AddRuleFunc("getamountttc",
		AutoCategory_MiscAddons.RuleFunc.GetAmountTTC)    
	AutoCategory.AddRuleFunc("ttc_getamount",
		AutoCategory_MiscAddons.RuleFunc.GetAmountTTC)    
    AutoCategory.AddRuleFunc("getpricettc", AutoCategory_MiscAddons.RuleFunc.GetPriceTTC)
    AutoCategory.AddRuleFunc("ttc_getpricettc", AutoCategory_MiscAddons.RuleFunc.GetPriceTTC)
    
    -- AlphaGear
    if not AG then
        AutoCategory.AddRuleFunc("alphagear", AutoCategory.dummyRuleFunc)   -- always return false
		
    else
        AutoCategory.AddRuleFunc("alphagear", AutoCategory_MiscAddons.RuleFunc.AlphaGear)
    end
    
    -- SetTracker
    if not SetTrack then
        AutoCategory.AddRuleFunc("istracked", AutoCategory.dummyRuleFunc)    -- always return false
		
    else
        AutoCategory.AddRuleFunc("istracked", AutoCategory_MiscAddons.RuleFunc.IsTracked)
    end
	
	-- Character Knowledge
	if not LibCharacterKnowledge then
        AutoCategory.AddRuleFunc("ck_isknowncat", AutoCategory.dummyRuleFunc)    -- always return false
        AutoCategory.AddRuleFunc("ck_isknown", AutoCategory.dummyRuleFunc)    -- always return false
		
    else
        AutoCategory.AddRuleFunc("ck_isknowncat", AutoCategory_MiscAddons.RuleFunc.CK_IsKnownCat)
        AutoCategory.AddRuleFunc("ck_isknown", AutoCategory_MiscAddons.RuleFunc.CK_IsKnown)
    end
    
    
end

local function getCurrentItemLink()
	return GetItemLink(AC.checkingItemBagId, AC.checkingItemSlotIndex)
end

-- Implement getpricemm() check function for Master Merchant
function AutoCategory_MiscAddons.RuleFunc.GetPriceMM( ... )
	local fn = "mm_getprice"
	if MasterMerchant then
		local itemLink = getCurrentItemLink()
		local mmData = MasterMerchant:itemStats(itemLink, false)
        if (mmData.avgPrice ~= nil) then
            return mmData.avgPrice
        end
	end
	return 0 
end

-- Implement getpricettc() check function for Tamriel Trade Center
function AutoCategory_MiscAddons.RuleFunc.GetPriceTTC( ... )
	local fn = "ttc_getprice"
	if TamrielTradeCentre and TamrielTradeCentrePrice then
		local itemLink = getCurrentItemLink()
		local priceInfo = TamrielTradeCentrePrice:GetPriceInfo(itemLink)
		if priceInfo then 
			local ac = select( '#', ... ) 
			if ac == 0 then
				--get suggested price
				if priceInfo.SuggestedPrice then
					return priceInfo.SuggestedPrice
				end
				
			else
				local arg = select( 1, ... )
				if type( arg ) == "string" then
					if arg == "average" then
						if priceInfo.Avg then
							return priceInfo.Avg
						end
						
					elseif arg == "suggested" then
						if priceInfo.SuggestedPrice then
							return priceInfo.SuggestedPrice
						end
						
					elseif arg == "both" then
						if priceInfo.SuggestedPrice then
							return priceInfo.SuggestedPrice
							
						elseif priceInfo.Avg then
							return priceInfo.Avg
						end
					end
				end
			end 
		end
	end
	return 0 
end

-- Implement getamountttc() check function for Tamriel Trade Center
function AutoCategory_MiscAddons.RuleFunc.GetAmountTTC( ... )
	local fn = "ttc_getamount"
	if TamrielTradeCentre and TamrielTradeCentrePrice then
		local itemLink = getCurrentItemLink()
		local priceInfo = TamrielTradeCentrePrice:GetPriceInfo(itemLink)
		if priceInfo then
			return priceInfo.AmountCount
		end
	end
	return 0
end

-- Implement alphagear() check function for Alpha Gear
function AutoCategory_MiscAddons.RuleFunc.AlphaGear( ... )
	if not AG or not AG.setdata or not AG.setdata.profiles then
		return false
	end
	local _, _, _, _, _, equipType = GetItemInfo(AC.checkingItemBagId, AC.checkingItemSlotIndex)
	if equipType == EQUIP_TYPE_INVALID then return end -- The item is not gear (nor poison)

	local strat_profile = 0 --- 0: no profile name / 1: profile name if item included in a build / 2: profile name if item included in a gear row
	local strat_build = 0 --- 0: no build name / 1: build name if in active profile / 2: build name if any
	local strat_activePrio = 0 --- 0: regular priority, rely on profile sort keys and build numbers / 1: the active profile has priority
	local strat_others = 0 --- 0: The rule return true only if a build/profile name was found according to strategies / 1: The rule return true if the item was found anywhere, and use 'Others' as default additional category name

	local fn = "alphagear"
	local ac = select( '#', ... )
	-- if ac == 0 then
	-- 	error( string.format("error: %s(): require arguments." , fn))
	-- end
	for ax = 1, ac do -- store parameters in profileSortKeysList
		local arg = select( ax, ... )
		local numArg = tonumber(arg)
		if numArg then
			if ax == 1 then strat_profile = numArg
			elseif ax == 2 then strat_build = numArg
			elseif ax == 3 then strat_activePrio = numArg
			elseif ax == 4 then strat_others = numArg
			end
			if strat_build == 1 then strat_activePrio = 1 end -- build name if in active profile requires/implies active profile priority
		end
	end

	local uid = Id64ToString(GetItemUniqueId(AC.checkingItemBagId, AC.checkingItemSlotIndex))
	if not uid then return false end

	--- Retrieve all profile sort keys and sort them. Ignore empty sort key.
	local profileSortKeysList  = {}
	for profileId, profile in ipairs(AG.setdata.profiles) do
		if profile and profile.setdata then
			local profileSortKey = profile.sortKey
			if profileSortKey and profileSortKey ~= "" then
				table.insert(profileSortKeysList, profileSortKey)
			end
		end
	end
	table.sort(profileSortKeysList)
	--- Retrieve all profile IDs in order, the active profile ID is put to the top of the list if strat_activePrio is set to 1.
	local profileIDList = {}
	for _, profileSortKey in ipairs(profileSortKeysList) do
		for profileId, profile in ipairs(AG.setdata.profiles) do
			if strat_activePrio == 1 and AG.setdata.currentProfileId == profileId then
				table.insert(profileIDList, 1, profileId)
			elseif profile and profile.sortKey == profileSortKey then
				table.insert(profileIDList, profileId)
			end
		end
	end
	--- Retrieve the first profile containing the item in any gear row.
	local targetProfileName, targetBuildName
	local isTargetProfileActive = false
	local function testBreak() return targetBuildName or (strat_profile == 2 and strat_build == 0 and targetProfileName) end --- always look for a profile containing the item in a build in priority, except if builds are ignored in strategy (strat_profile == 2 and strat_build == 0)
	for _, profileId in ipairs(profileIDList) do
		local profile = AG.setdata.profiles[profileId]
		if profile and profile.setdata then
			for setDataRow, setData in ipairs(profile.setdata) do
				if setData and setData.Gear then
					for _, itemData in ipairs(setData.Gear) do
						if itemData and itemData.id and itemData.id == uid then
							if not targetProfileName then -- update only if no profile were found (keep priority)
								targetProfileName = profile.name
								if not targetProfileName or (targetProfileName == "") then targetProfileName = "Profile "..tostring(profileId) end
								isTargetProfileActive = (AG.setdata.currentProfileId == profileId)
							end
							--- Retrieve the first build containing the item, continue with other profiles if none found
							for setDataRow2, setdata2 in ipairs(profile.setdata) do
								if setdata2 and setdata2.Set and setdata2.Set.gear and setdata2.Set.gear == setDataRow then
									targetProfileName = profile.name
									if not targetProfileName or (targetProfileName == "") then targetProfileName = "Profile "..tostring(profileId) end
									isTargetProfileActive = (AG.setdata.currentProfileId == profileId)
									targetBuildName = setdata2.Set.text[1]
									if not targetBuildName or (targetBuildName == "") then targetBuildName = "Build "..tostring(setDataRow2) end
									break
								end
							end
							if testBreak() then break end
						end
					end
				end
				if testBreak() then break end
			end
		end
		if testBreak() then break end
	end
	if not targetProfileName then return false end --- Item not found, exit
	--- Compute category name depending on strategies
	if strat_profile == 2 or (strat_profile == 1 and targetBuildName) then
		if (strat_build == 2 or (strat_build == 1 and isTargetProfileActive)) and targetBuildName then   -- use profile and build names
			AC.AdditionCategoryName = targetProfileName.." - ".. targetBuildName
		else  -- use profile name only
			AC.AdditionCategoryName = targetProfileName
		end
	elseif (strat_build == 2 or (strat_build == 1 and isTargetProfileActive)) and targetBuildName then -- use build name only
		AC.AdditionCategoryName = targetBuildName
	end

	if AC.AdditionCategoryName and AC.AdditionCategoryName ~= "" then
		return true
	elseif strat_others == 1 then
		AC.AdditionCategoryName = "Others"
		return true
	elseif strat_profile == 0 and strat_build == 0 and strat_others == 0 then --- Group all matching items in one category if strategy is to ignore everything
		AC.AdditionCategoryName = ""
		return true
	end
	return false
end

-- Implement istracked() check function for Set Tracker
function AutoCategory_MiscAddons.RuleFunc.IsTracked( ... )
  local fn = "istracked"
  if SetTrack == nil then
    return false
  end
  local ac = select( '#', ... ) 
  local checkSets = {}
  for ax = 1, ac do
    
    local arg = select( ax, ... )
    if not arg then
      error( string.format("error: %s():  argument is nil." , fn))
    end
    checkSets[arg]=true
  end
  
  local iTrackIndex, sTrackName, sTrackColour, sTrackNotes = SetTrack.GetTrackingInfo(AC.checkingItemBagId, AC.checkingItemSlotIndex)
  if iTrackIndex >= 0 then
    if ac > 0 then
      if checkSets[sTrackName] ~= nil then
        -- true only if a specified set name is tracked on this item
        return true
      end
      -- item was tracked but not one of the specified sets, so return false
      return false
    else
      -- specific set names weren't given so true if tracked at all
      return true
    end
  end
  -- not a set tracked by SetTrack
  return false  
end

local function getCharId( charname )
	local sv = {}
	for i = 1, GetNumCharacters() do
		local name, _, _, _, _, _, characterId = GetCharacterInfo(i)
		sv[name] = characterId
	end
	if sv[charname] ~= nil then
	    return sv[charname]
	end
	return nil
end

-- Get a list of all characters on all local accounts
local function initChars()
	if LibCharacterKnowledge == nil then
		return
	end
	AutoCategory_MiscAddons.server = zo_strsplit(" ", GetWorldName())[1]
	AutoCategory_MiscAddons.charlist = 
		LCK.GetCharacterList(AutoCategory_MiscAddons.server)
end

-- Implement ck_isknown() check function for Set Tracker
function AutoCategory_MiscAddons.RuleFunc.CK_IsKnown( ... )
	local fn = "ck_isknown"
	if LibCharacterKnowledge == nil then
		return false
	end
	
	local itemLink = getCurrentItemLink()
	local cat = LCK.GetItemCategory(itemLink)
	
	--local server = zo_strsplit(" ", GetWorldName())[1]
	if AutoCategory_MiscAddons.charlist == nil then
		initChars()
	end
	local ac = select( '#', ... )
	local crafter, knowledge
	if ac == 0 then
		knowledge = LCK.GetItemKnowledgeForCharacter(itemLink, server)
		
	else
		--local charlist = LCK.GetCharacterList(server)
		local arg = select(1, ...)
		for i,v in pairs(AutoCategory_MiscAddons.charlist) do
		--for i = 1, GetNumCharacters() do
		--	local name, _, _, _, _, _, characterId = GetCharacterInfo(i)
		--	name = zo_strformat("<<1>>", name)
			local name = zo_strformat("<<1>>",v.name)
			if name == arg then
				crafter = v.id --characterId
			end
		end
		knowledge = LCK.GetItemKnowledgeForCharacter(itemLink, server, crafter)
	end
	if knowledge  == LCK.KNOWLEDGE_KNOWN then
		return true
	end
  -- not known by character
  return false  
end

-- Implement ck_isknowncat() check function for Set Tracker
function AutoCategory_MiscAddons.RuleFunc.CK_IsKnownCat( ... )
	local fn = "ck_isknowncat"
	if LibCharacterKnowledge == nil then
		return false
	end

	-- check if item is in one of CK's defined categories
	local itemLink = getCurrentItemLink()
	local cat = LCK.GetItemCategory(itemLink)
	if cat == LCK.ITEM_CATEGORY_NONE then return false end
	
	-- decide which CK categories to look for
	local names = { 
		["recipe"] =  LCK.ITEM_CATEGORY_RECIPE, 
		["plan"] = LCK.ITEM_CATEGORY_PLAN, 
		["motif"] = LCK.ITEM_CATEGORY_MOTIF,
		}
	local chkCats = {}
	local ac = select( '#', ... )
	if ac == 0 then
		return true
	else
		for ax = 1, ac do
			local arg = select(ax, ...)
			if not arg or not names[arg] then 
				error( string.format("error: %s(): argument %d is error. %s not recognized." , fn, ax, arg ) )
			end
			
			chkCats[names[arg]] = true
		end
	end	
	if chkCats[cat] then
	    return true
	end
	return false  
end


-- Register this plugin with AutoCategory to be initialized and used when AutoCategory loads.
AutoCategory.RegisterPlugin("MiscAddons", AutoCategory_MiscAddons.Initialize)