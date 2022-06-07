--[[
CHANGE DETECTION STRATEGY
This file uses hooks on API functions: 
	PLAYER_INVENTORY:ApplySort, SMITHING.deconstructionPanel.inventory:SortData, and SMITHING.improvementPanel.inventory:SortData 
to order items in categories, in all inventories (including crafting station)
This process involves executing all active rules for each items, and can be 
triggered multiple times in a row, notably for bank transfers (more than ten calls)
In order to reduce the impact of the add-on:
	1 - The results of rules' execution are stored in 'itemEntry.data'.
 		As 'itemEntry.data' is persistent, results can be reused directly without having to re-execute all the rules every time.
		However, 'itemEntry.data' will not persist forever and will be reset at some point, and rules will need to be re-executed, but this is not much of an issue.
		
	2 - A change detection strategy is used to re-execute rules when necessary.
		A global hash is used to trigger re-execution of rules for all items based on:
			- Quickslots: test if quickslots have changed
		A hash for each item is used to trigger re-execution of rules for a single item based on:
			- Time, as a safety net, in case a change were missed for any reason: test if the results stored are older than 2 seconds
			- Base game data: test various variables like isPlayerLocked, brandNew, isInArmory etc.
			- FCOIS data: test if item's marks have changed
			
		Some API events are monitored:
			- A hook on PLAYER_INVENTORY:OnInventorySlotUpdated triggers re-execution of rules for a single item
			- A hook on ZO_QuickslotManager:DoQuickSlotUpdate triggers an inventory refresh as the game does not do it when updating quickslots. (This is so changes are displayed directly when a quickslot is updated and the quickslot button is pressed to go back to the inventory, otherwise another action would be required to trigger an inventory refresh)
			- A callback on LAM-PanelClosed triggers re-execution of rules
			- The event EVENT_STACKED_ALL_ITEMS_IN_BAG is used so re-execution of rules with inventory refresh can be triggered manually by stacking all items.
		Also, some other add-ons' functions are hooked to provide better compatibility and responsiveness:
			- AG:handlePostChangeGearSetItems and AG:LoadProfile trigger rules re-execution and an inventory refresh
]]


local LMP = LibMediaProvider
local SF = LibSFUtils
local AC = AutoCategory

AutoCategory.dataCount = {}

local sortKeys = {
    slotIndex = { isNumeric = true },
    stackCount = { tiebreaker = "slotIndex", isNumeric = true },
    name = { tiebreaker = "stackCount" },
    quality = { tiebreaker = "name", isNumeric = true },
    stackSellPrice = { tiebreaker = "name", tieBreakerSortOrder = ZO_SORT_ORDER_UP, isNumeric = true },
    statusSortOrder = { tiebreaker = "age", isNumeric = true},
    age = { tiebreaker = "name", tieBreakerSortOrder = ZO_SORT_ORDER_UP, isNumeric = true},
    statValue = { tiebreaker = "name", isNumeric = true, tieBreakerSortOrder = ZO_SORT_ORDER_UP },
    traitInformationSortOrder = { tiebreaker = "name", isNumeric = true, tieBreakerSortOrder = ZO_SORT_ORDER_UP },
    sellInformationSortOrder = { tiebreaker = "name", isNumeric = true, tieBreakerSortOrder = ZO_SORT_ORDER_UP },
	ptValue = { tiebreaker = "name", isNumeric = true },
}

local CATEGORY_HEADER = 998

-- convenience function
local function NilOrLessThan(value1, value2)
    if value1 == nil then
        return true
    elseif value2 == nil then
        return false
	elseif type(value1) == "boolean" then
		if value1 == false then return true end
		return false
    else 
        return value1 < value2
    end
end 

local function buildHashString(...)
	return SF.dstr(":",...)
end

-- setup function for category header type to be added to the scroll list
local function setup_InventoryItemRowHeader(rowControl, slot, overrideOptions)
	--set header
	local appearance = AutoCategory.acctSaved.appearance
	local headerLabel = rowControl:GetNamedChild("HeaderName")	
	headerLabel:SetHorizontalAlignment(appearance["CATEGORY_FONT_ALIGNMENT"])
	headerLabel:SetFont(string.format('%s|%d|%s', 
			LMP:Fetch('font', appearance["CATEGORY_FONT_NAME"]), 
			appearance["CATEGORY_FONT_SIZE"], appearance["CATEGORY_FONT_STYLE"]))
	headerLabel:SetColor(appearance["CATEGORY_FONT_COLOR"][1], appearance["CATEGORY_FONT_COLOR"][2], 
						 appearance["CATEGORY_FONT_COLOR"][3], appearance["CATEGORY_FONT_COLOR"][4])
	
	local data = SF.safeTable(slot.dataEntry.data)
	local cateName = SF.nilDefault(data.AC_categoryName, "Unknown")
	local bagTypeId = SF.nilDefault(data.AC_bagTypeId, 0)
	local num = SF.nilDefault(data.AC_catCount,0)
	--setCount(data.AC_bagTypeId, data.AC_categoryName, 0)
	
	-- Add count to category name if selected in options
	if AutoCategory.acctSaved.general["SHOW_CATEGORY_ITEM_COUNT"] then
		headerLabel:SetText(string.format('%s |cFFE690[%d]|r', cateName, num))
	else
		headerLabel:SetText(cateName)
	end
		
	-- set the collapse marker
	local marker = rowControl:GetNamedChild("CollapseMarker")
	local collapsed = AutoCategory.IsCategoryCollapsed(bagTypeId, cateName) 
	if AutoCategory.acctSaved.general["SHOW_CATEGORY_COLLAPSE_ICON"] then
		marker:SetHidden(false)
		if collapsed then
			marker:SetTexture("EsoUI/Art/Buttons/plus_up.dds")
		else
			marker:SetTexture("EsoUI/Art/Buttons/minus_up.dds")
		end
	else
		marker:SetHidden(true)
	end
	
	rowControl:SetHeight(AutoCategory.acctSaved.appearance["CATEGORY_HEADER_HEIGHT"])
	rowControl.slot = slot
end

-- create the row header type and add to the inventory scroll list
local function AddTypeToList(rowHeight, datalist, inven_ndx) 
	if datalist == nil then return end
	
	local templateName = "AC_InventoryItemRowHeader"
	local setupFunc = setup_InventoryItemRowHeader
	local resetCB = ZO_InventorySlot_OnPoolReset
	local hiddenCB = nil
	if inven_ndx then
		hiddenCB = PLAYER_INVENTORY.inventories[inven_ndx].listHiddenCallback
	end
	ZO_ScrollList_AddDataType(datalist, CATEGORY_HEADER, templateName, 
	    rowHeight, setupFunc, hiddenCB, nil, resetCB)
end

local function isUngroupedHidden(bagTypeId)
	return bagTypeId == nil or AutoCategory.saved.bags[bagTypeId].isUngroupedHidden
end

local function isHiddenEntry(itemEntry)
	if not itemEntry or not itemEntry.data then return false end
	
	local data = itemEntry.data
	if data.AC_isHidden then return true end
	if data.AC_bagTypeId == nil then return true end
	if not data.AC_matched and isUngroupedHidden(data.AC_bagTypeId) then return true end
	
	return AutoCategory.IsCategoryCollapsed(data.AC_bagTypeId, data.AC_categoryName)
end

local function runRulesOnEntry(itemEntry)
	--only match on items(not headers)
	if itemEntry.typeId == CATEGORY_HEADER then return end
	
	local data = itemEntry.data
	local bagId = data.bagId
	local slotIndex = data.slotIndex
	
	local matched, categoryName, categoryPriority, bagTypeId, isHidden 
				= AutoCategory:MatchCategoryRules(bagId, slotIndex)
	data.AC_matched = matched
	if matched then
		data.AC_categoryName = categoryName
		data.AC_sortPriorityName = string.format("%03d%s", 100 - categoryPriority , categoryName)
		data.AC_isHidden = isHidden
	else
		data.AC_categoryName = AutoCategory.acctSaved.appearance["CATEGORY_OTHER_TEXT"]
		data.AC_sortPriorityName = string.format("%03d%s", 999 , data.AC_categoryName)
		-- if was not matched, then the isHidden value that was returned is not valid
		data.AC_isHidden = isUngroupedHidden(bagTypeId)
	end
	data.AC_bagTypeId = bagTypeId
	data.AC_isHeader = false
		
end

-- Go through all of the entries in a scroll list and if
-- they are entry items (not headers) then run the list
-- of rules against them and save the match info in them.
--
-- modifies the entries in the list
local function runRulesOnList(scrollData)
	if AutoCategory.Enabled == false then return scrollData end
	
	for i, entry in ipairs(scrollData) do
		runRulesOnEntry(entry)
	end
	return scrollData
end



local function createHeaderEntry(catInfo)
	local headerEntry = ZO_ScrollList_CreateDataEntry(CATEGORY_HEADER, { 
			AC_categoryName = catInfo.AC_categoryName,
			AC_sortPriorityName = catInfo.AC_sortPriorityName,
			AC_bagTypeId = catInfo.AC_bagTypeId,
			AC_isHeader = true,
			AC_catCount = catInfo.AC_catCount,
			stackLaunderPrice = 0})
	return headerEntry
end

local function sortInventoryFn(inven, left, right, key, order) 
	if AutoCategory.BulkMode then
		-- revert to default
		return ZO_TableOrderingFunction(left.data, right.data, 
			inven.currentSortKey, sortKeys, inven.currentSortOrder)
	end
	
	local ldata = left.data
	local rdata = right.data
	
	if AutoCategory.Enabled then
		if rdata.AC_sortPriorityName ~= ldata.AC_sortPriorityName then
			return NilOrLessThan(ldata.AC_sortPriorityName, rdata.AC_sortPriorityName)
		end
		if rdata.AC_isHeader ~= ldata.AC_isHeader then
			return NilOrLessThan(rdata.AC_isHeader, ldata.AC_isHeader)
		end
	end
	
	--compatible with quality sort
	if type(inven.sortKey) == "function" then 
		if inven.sortOrder == ZO_SORT_ORDER_UP then
			return inven.sortKey(left.data, right.data)
		else
			return inven.sortKey(right.data, left.data)
		end
	end
	
	return ZO_TableOrderingFunction(left.data, right.data, 
			key, sortKeys, order)
end

local hashGlobal = "InitialHash" --- a hash representing the last 'global state', so changes can be detected.
local function forceRuleReloadGlobal(reloadTypeString)
	hashGlobal = SF.str("forceRuleReloadGlobal-", tostring(reloadTypeString))
end

local function detectGlobalChanges()
	-- return false
	local quickSlotHash = "" --- retrieve quickslots uniqueIDs
	-- for i = ACTION_BAR_FIRST_UTILITY_BAR_SLOT + 1, ACTION_BAR_FIRST_UTILITY_BAR_SLOT + ACTION_BAR_EMOTE_QUICK_SLOT_SIZE do
	-- for i = 8 + 1, 8 + 8 do
	-- 	quickSlotHash = quickSlotHash .. ":" .. tostring(GetSlotItemLink(i))
	-- end
	local newHash = buildHashString(quickSlotHash) --- use hash for change detection
	-- d("OLD HASH : "..tostring(hashGlobal))
	-- d("NEW HASH : "..tostring(newHash))
	if newHash ~= hashGlobal then 
		-- changes detected
		hashGlobal = newHash --- reset hash for next hook
		return true
	end
	return false
end

-- uniqueIDs of items that have been updated (need rule re-execution), 
-- based on PLAYER_INVENTORY:OnInventorySlotUpdated hook
local forceRuleReloadByUniqueIDs = {} 
local function forceRuleReloadForSlot(bagId, slotIndex)
	table.insert(forceRuleReloadByUniqueIDs, GetItemUniqueId(bagId, slotIndex))
end

local function constructEntryHash(itemEntry)
	local data = itemEntry.data
	--- Hash construction
	local hashFCOIS = "" -- retrieve FCOIS mark data for change detection with itemEntry hash
	if FCOIS and data.bagId and data.bagId > 0 and data.slotIndex and data.slotIndex > 0 then
		local _, markedIconsArray = FCOIS.IsMarked(data.bagId, data.slotIndex, -1)
		if markedIconsArray then
			for _, value in ipairs(markedIconsArray) do
				hashFCOIS = hashFCOIS .. tostring(value)
			end
		end
	end
	local newEntryHash = buildHashString(data.isPlayerLocked, data.isGemmable, data.stolen, data.isBoPTradeable,
					data.isInArmory, data.brandNew, data.bagId, data.stackCount, data.uniqueId, data.slotIndex,
					data.meetsUsageRequirement, data.locked, data.isJunk, hashFCOIS)
	return newEntryHash
end

local function detectItemChanges(itemEntry, newEntryHash, needReload)
	local data = itemEntry.data
	local changeDetected = false
	local currentTime = os.clock()
	
	local function setChange(val)
		if val == true then
			data.AC_lastUpdateTime = currentTime
			changeDetected = true
		end	
		return changeDetected
	end
	
	if needReload == true then
		return setChange(true)
	end

	--- Update hash and test if changed
	if data.AC_hash == nil or data.AC_hash ~= newEntryHash then
		data.AC_hash = newEntryHash
		return setChange(true)
	end

	--- Test last update time, triggers update if more than 2s
	if data.AC_lastUpdateTime == nil then
		return setChange(true)
	elseif currentTime - tonumber(data.AC_lastUpdateTime) > 2 then
		return setChange(true)
	end

	--- Test if uniqueID tagged for update
	for _, uniqueID in ipairs(forceRuleReloadByUniqueIDs) do --- look for items with changes detected
		if data.uniqueID == uniqueID then
			return setChange(true)
		end
	end

	return changeDetected
end

-- Execute rules and store results in itemEntry.data, if needed. 
-- Return the number of items updated with rule re-execution.
local function handleRules(scrollData, needsReload)
	local updateCount = 0 -- indicate if at least one item has been updated with new rule results
	
	-- at craft stations scrollData seems to be reset every time, so need to always reload
	local reloadAll = needsReload or detectGlobalChanges() 
	for _, itemEntry in ipairs(scrollData) do
		if itemEntry.typeId ~= CATEGORY_HEADER then 
			local newHash = constructEntryHash(itemEntry)
			-- 'detectItemChanges(itemEntry) or reloadAll' need to be in this order so hash is always updated
			if detectItemChanges(itemEntry, newHash, reloadAll) then 
				-- reload rules if full reload triggered, or changes detected
				updateCount = updateCount + 1
				runRulesOnEntry(itemEntry)
			end
		end
	end
	forceRuleReloadByUniqueIDs = {} --- reset update buffer
	return updateCount
end

-- look for the bag ID associated with the scrollData list
--
-- may return nil if there is no (non-header) data in the scrollData list
local function getListBagID(scrollData)
	local bagId = nil
	for i, entry in ipairs(scrollData) do
		if entry.typeId ~= CATEGORY_HEADER then
			local slotData = entry.data
			bagId = slotData.bagId
			break
		end
	end
	return bagId
end

--- Create list with visible items and headers (performs category count).
local function createNewScrollData(scrollData)
	local newScrollData = {} --- output, entries sorted with category headers
	local categoryList = {} --- keep track of categories added and their item count
	local bagTypeId = getListBagID(scrollData)
	
	local function addCount(name)
		categoryList[name] = SF.safeTable(categoryList[name])
		if categoryList[name].AC_catCount == nil then
			categoryList[name].AC_catCount = 0
		end
		categoryList[name].AC_catCount = categoryList[name].AC_catCount + 1
	end

	local function getCount(name)
		categoryList[name] = SF.safeTable(categoryList[name])
		if categoryList[name].AC_catCount == nil then
			categoryList[name].AC_catCount = 0
		end
		return categoryList[name].AC_catCount
	end

	local function setCount(bagTypeId, name, count)
		categoryList[name] = SF.safeTable(categoryList[name])
		categoryList[name].AC_catCount = count
	end
	
	-- create newScrollData with headers and only non hidden items. No sorting here!
	for _, itemEntry in ipairs(scrollData) do 
		if itemEntry.typeId ~= CATEGORY_HEADER and not isHiddenEntry(itemEntry) then 
			-- add item if visible
			table.insert(newScrollData, itemEntry)
		end
		
		-- look up the owning category in our list, update entry count
		-- or else create an entry with count = 1
		local data = itemEntry.data
		
		local AC_categoryName = data.AC_categoryName
		if not categoryList[AC_categoryName] then 
		
			-- keep track of categories and required data
			categoryList[AC_categoryName] =  {
				AC_sortPriorityName = data.AC_sortPriorityName,
				AC_categoryName = AC_categoryName, 
				AC_bagTypeId = data.AC_bagTypeId, 
				AC_catCount = 0, 
				isNewCount = false,
			} 
		end
		local catInfo = categoryList[AC_categoryName]
		
		local catCountIsNew = false
		if itemEntry.typeId ~= CATEGORY_HEADER then --- this is an item, start new count
			addCount(AC_categoryName)
			catCountIsNew = true
			
		elseif itemEntry.typeId == CATEGORY_HEADER 
				and AutoCategory.IsCategoryCollapsed(data.AC_bagTypeId, AC_categoryName) then 
			-- this is a collapsed category --> reuse previous count, since
			--   				the content is not available in scrollData
			setCount(AC_categoryName, data.AC_catCount)
			catCountIsNew = false
		end
						
	end
	
	-- Create headers and append to newScrollData
	for _, catInfo in pairs(categoryList) do ---> add tracked categories
		if catInfo.AC_catCount ~= nil then
			local headerEntry = createHeaderEntry(catInfo)
			table.insert(newScrollData, headerEntry)
		end
	end
	return newScrollData
end

local function prehookSort(self, inventoryType) 
	if not AutoCategory.Enabled then return false end -- revert to default behaviour
	if inventoryType == INVENTORY_QUEST_ITEM then return false end -- revert to default behaviour

	local inventory = self.inventories[inventoryType]
	if inventory == nil then
		-- Use normal inventory by default (instead of the quest item inventory for example)
		inventory = self.inventories[self.selectedTabType]
	end
	
	--change sort function
	inventory.sortFn =  function(left, right) 
			return sortInventoryFn(inventory, left, right, inventory.currentSortKey, inventory.currentSortOrder)
		end

	-- from nogetrandom
	local scene
	if SCENE_MANAGER and SCENE_MANAGER:GetCurrentScene() then
		scene = SCENE_MANAGER:GetCurrentScene():GetName()
	end

	if scene then
		if AutoCategory.BulkMode and AutoCategory.BulkMode == true then
			if scene == "guildBank" or scene == "bank" then
				forceRuleReloadGlobal("BulkMode") --- trigger rules reload when exiting bulk mode
				return true	-- skip out early
			end
		end
	end	
	-- end nogetrandom recommend

	local list = inventory.listView 
	local scrollData = ZO_ScrollList_GetDataList(list) 
	local bagId = getListBagID(scrollData)
	
	local needsReload = false
	-- local needsReload = true
	-- if scene == "bank" or scene == "guildBank" then
	-- 	needsReload = false
	-- end
	handleRules(scrollData, needsReload) --> update rules' results if necessary

	if hashGlobal == "forceRuleReloadGlobal-Event_ItemsStacked" then --- TWEAK: remove all new flags if stacking all items
		for _, itemEntry in ipairs(scrollData) do
			if itemEntry.typeId ~= CATEGORY_HEADER and itemEntry.data.brandNew then
				itemEntry.data.clearAgeOnClose = nil -- code here comes from inventory.lua:1926
				SHARED_INVENTORY:ClearNewStatus(itemEntry.data.bagId, itemEntry.data.slotIndex)
				--ZO_SharedInventoryManager:ClearNewStatus(itemEntry.bagId, itemEntry.slotIndex)
			end
		end
	end
	
	-- add header rows	   
	list.data = createNewScrollData(scrollData) --> rebuild scrollData with headers and visible items
	table.sort(scrollData, inventory.sortFn)  
	ZO_ScrollList_Commit(list)
	return false
end

local function prehookCraftSort(self)
	if not AutoCategory.Enabled then return false end --- revert to default behavior if disabled

	--AutoCategory.validateBagRules(nil, AC_BAG_TYPE_CRAFTSTATION)
	
	--change sort function
	self.sortFunction =  function(left, right) 
			return sortInventoryFn(self, left, right, self.sortKey, self.sortOrder)
		end

	local scrollData = ZO_ScrollList_GetDataList(self.list)
	if #scrollData == 0 then return false end --- empty inventory -> revert to default behavior

	handleRules(scrollData, true)

	-- add header rows	    
	self.list.data = createNewScrollData(scrollData)
	table.sort(scrollData, self.sortFunction)
	ZO_ScrollList_Commit(self.list)
	return false
end

-- perform refresh of list
local function refresh(refreshList, forceRuleReload, reloadTypeString)
	if forceRuleReload then
		forceRuleReloadGlobal(reloadTypeString)
	end
	if refreshList then
		AutoCategory.RefreshCurrentList()
	end
end

-- new hook
local function getRefreshFunc(refreshList, forceRuleReload, reloadTypeString)
	return function() 
			refresh(refreshList, forceRuleReload, reloadTypeString)
		end
end

-- new hook
local function onDoQuickSlotUpdate(self, physicalSlot, animationOption)
	if animationOption then --- a quickslot has been changed (manually)
		refresh(true, false, "QuickSlot_update")
	end
end

-- new hook
local function onInventorySlotUpdated(self, bagId, slotIndex)
	forceRuleReloadForSlot(bagId, slotIndex)
end


function AutoCategory.HookKeyboardMode()
	--Add a new header row data type
	local rowHeight = AutoCategory.acctSaved.appearance["CATEGORY_HEADER_HEIGHT"]
	
    AddTypeToList(rowHeight, ZO_PlayerInventoryList,  INVENTORY_BACKPACK)
    AddTypeToList(rowHeight, ZO_CraftBagList,         INVENTORY_BACKPACK)
    AddTypeToList(rowHeight, ZO_PlayerBankBackpack,   INVENTORY_BACKPACK)
    AddTypeToList(rowHeight, ZO_GuildBankBackpack,    INVENTORY_BACKPACK)
    AddTypeToList(rowHeight, ZO_HouseBankBackpack,    INVENTORY_BACKPACK)
    AddTypeToList(rowHeight, ZO_PlayerInventoryQuest, INVENTORY_QUEST_ITEM)
	
    AddTypeToList(rowHeight, SMITHING.deconstructionPanel.inventory.list, nil)
    AddTypeToList(rowHeight, SMITHING.improvementPanel.inventory.list,    nil)
	
    AddTypeToList(rowHeight, ZO_UniversalDeconstructionTopLevel_KeyboardPanelInventoryBackpack, nil )
	
	--- sort hooks
	ZO_PreHook(PLAYER_INVENTORY,                       "ApplySort", prehookSort)
    ZO_PreHook(SMITHING.deconstructionPanel.inventory, "SortData",  prehookCraftSort)
    ZO_PreHook(SMITHING.improvementPanel.inventory,    "SortData",  prehookCraftSort)
    ZO_PreHook(UNIVERSAL_DECONSTRUCTION.deconstructionPanel.inventory, "SortData", prehookCraftSort)
	
	--- changes detection events/hooks (anticipate if rules results may have changed)
	ZO_PreHook(PLAYER_INVENTORY, "OnInventorySlotUpdated", onInventorySlotUpdated) -- item has changed
	--ZO_PostHook(ZO_QuickslotManager, "DoQuickSlotUpdate", onDoQuickSlotUpdate) -- quick slots updated
	-- AddonMenu panel closed (AC settings, or others, may have changed)
	CALLBACK_MANAGER:RegisterCallback("LAM-PanelClosed", 
			getRefreshFunc(true, true, "LAM-PanelClosed")) 
	EVENT_MANAGER:RegisterForEvent(AutoCategory.name, EVENT_STACKED_ALL_ITEMS_IN_BAG, 
			getRefreshFunc(true, true, "Event_ItemsStacked"))

	-- AlphaGear change detection hook
	if AG then
		ZO_PostHook(AG, "handlePostChangeGearSetItems", 
				getRefreshFunc(true, true, "AG_itemChange"))
		ZO_PostHook(AG, "LoadProfile", 
				getRefreshFunc(true, true, "AG_LoadProfile")) -- can be called twice in a row...
	end
end


--[[
-------- HINTS FOR REFERENCE -----------

In sharedInventory.lua we can see a breakdown of how slotData is build, under is a truncated summary:

slot.rawName = GetItemName(bagId, slotIndex)
slot.name = zo_strformat(SI_TOOLTIP_ITEM_NAME, slot.rawName)
slot.requiredLevel = GetItemRequiredLevel(bagId, slotIndex)
slot.requiredChampionPoints = GetItemRequiredChampionPoints(bagId, slotIndex)
slot.itemType, slot.specializedItemType = GetItemType(bagId, slotIndex)
slot.uniqueId = GetItemUniqueId(bagId, slotIndex)
slot.iconFile = icon
slot.stackCount = stackCount
slot.sellPrice = sellPrice
slot.launderPrice = launderPrice
slot.stackSellPrice = stackCount * sellPrice
slot.stackLaunderPrice = stackCount * launderPrice
slot.bagId = bagId
slot.slotIndex = slotIndex
slot.meetsUsageRequirement = meetsUsageRequirement or (bagId == BAG_WORN)
slot.locked = locked
slot.functionalQuality = functionalQuality
slot.displayQuality = displayQuality
-- slot.quality is deprecated, included here for addon backwards compatibility
slot.quality = displayQuality
slot.equipType = equipType
slot.isPlayerLocked = IsItemPlayerLocked(bagId, slotIndex)
slot.isBoPTradeable = IsItemBoPAndTradeable(bagId, slotIndex)
slot.isJunk = IsItemJunk(bagId, slotIndex)
slot.statValue = GetItemStatValue(bagId, slotIndex) or 0
slot.itemInstanceId = GetItemInstanceId(bagId, slotIndex) or nil
slot.brandNew = isNewItem
slot.stolen = IsItemStolen(bagId, slotIndex)
slot.filterData = { GetItemFilterTypeInfo(bagId, slotIndex) }
slot.condition = GetItemCondition(bagId, slotIndex)
slot.isPlaceableFurniture = IsItemPlaceableFurniture(bagId, slotIndex)
slot.traitInformation = GetItemTraitInformation(bagId, slotIndex)
slot.traitInformationSortOrder = ZO_GetItemTraitInformation_SortOrder(slot.traitInformation)
slot.sellInformation = GetItemSellInformation(bagId, slotIndex)
slot.sellInformationSortOrder = ZO_GetItemSellInformationCustomSortOrder(slot.sellInformation)
slot.actorCategory = GetItemActorCategory(bagId, slotIndex)
slot.isInArmory = IsItemInArmory(bagId, slotIndex)
slot.isGemmable = false
slot.requiredPerGemConversion = nil
slot.gemsAwardedPerConversion = nil
slot.isFromCrownStore = IsItemFromCrownStore(bagId, slotIndex)
slot.age = GetFrameTimeSeconds()

slotData.statusSortOrder = self:ComputeDynamicStatusMask(slotData.isPlayerLocked, slotData.isGemmable, slotData.stolen, slotData.isBoPTradeable, slotData.isInArmory, slotData.brandNew, slotData.bagId == BAG_WORN)

]]
