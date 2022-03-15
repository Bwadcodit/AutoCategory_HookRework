--[[
CHANGE DETECTION STRATEGY
This file use hooks on API functions: PLAYER_INVENTORY:ApplySort, SMITHING.deconstructionPanel.inventory:SortData, and SMITHING.improvementPanel.inventory:SortData to order in categories the item list displayed in all inventories (including crafting station)
This process involves executing all active rules for each items, and can be trigger multiple times in a row, notably for bank transfers (more than ten calls)
In order to reduce the impact of the add-on:
	1 - The results of rules' execution are stored in 'itemEntry.data'.
 	As 'itemEntry.data' is persistent, results can be reused directly without having to re-execute all the rules every time.
		However, 'itemEntry.data' will not persist forever and will be reset at some point, and rules will need to be re-executed, but this is not much of an issue.
	2 - A change detection strategy is used to re-execute rules when necessary.
		A global hash is used to trigger re-execution of rules for all items based on: ???
			- Quickslots: test if quickslots have changed
		A hash for each item is used to trigger re-execution of rules for a single item based on:
			- Time: test if the results stored are older than 2 seconds
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
-- given a (supposed) table variable
-- either return the table variable
-- or return an empty table if the table variable was nil
local function validTable(tbl)
    if tbl == nil then
        tbl = {}
    end
    return tbl
end

-- convenience function
local function NilOrLessThan(value1, value2)
    if value1 == nil then
        return true
    elseif value2 == nil then
        return false
    else
        return value1 < value2
    end
end 

-- utility function: build a string with all parameters, accept any parameters.
local function buildHashString(...)
	local paramList = {...}
	local hashString = ":"
	for _, param in ipairs(paramList) do
		hashString = hashString..tostring(param)..":"
	end
	return hashString
end

-- debug convenience function
local function dTable(table, depth, name)
	if type(table) ~= "table" then 
		d(tostring(table)) 
		return
	end
	if depth < 1 then return end
	for k, v in pairs(table) do
		d(name.." : "..tostring(k).." -> "..tostring(v))
		if type(v) == "table" then dTable(v, depth - 1, name.." - ["..tostring(k).."]") end
	end
end

local function setup_InventoryItemRowHeader(rowControl, slot, overrideOptions)
	--set header
	local headerLabel = rowControl:GetNamedChild("HeaderName")
	-- Add count to category name if selected in options
	if AutoCategory.acctSaved.general["SHOW_CATEGORY_ITEM_COUNT"] then
		count = slot.dataEntry.data.AC_catCount
		headerLabel:SetText(string.format('%s |cFFE690[%d]|r', slot.bestItemTypeName, count))
	else
		headerLabel:SetText(slot.bestItemTypeName)
	end
	
	local appearance = AutoCategory.acctSaved.appearance
	headerLabel:SetHorizontalAlignment(appearance["CATEGORY_FONT_ALIGNMENT"])
	headerLabel:SetFont(string.format('%s|%d|%s', 
			LMP:Fetch('font', appearance["CATEGORY_FONT_NAME"]), 
			appearance["CATEGORY_FONT_SIZE"], appearance["CATEGORY_FONT_STYLE"]))
	headerLabel:SetColor(appearance["CATEGORY_FONT_COLOR"][1], appearance["CATEGORY_FONT_COLOR"][2], 
						 appearance["CATEGORY_FONT_COLOR"][3], appearance["CATEGORY_FONT_COLOR"][4])

	local marker = rowControl:GetNamedChild("CollapseMarker")
	local cateName = slot.dataEntry.data.AC_categoryName
	local bagTypeId = slot.dataEntry.data.AC_bagTypeId
	
	-- set the collapse marker
	local collapsed = (cateName ~= nil) and (bagTypeId ~= nil) and AutoCategory.IsCategoryCollapsed(bagTypeId, cateName) 
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

local function AddTypeToList(rowHeight, datalist, inven_ndx) 
	if datalist == nil then return end
	
	local templateName = "AC_InventoryItemRowHeader"
	local setupFunc = setup_InventoryItemRowHeader
	local resetCB = ZO_InventorySlot_OnPoolReset
	local hiddenCB
	if inven_ndx then
		hiddenCB = PLAYER_INVENTORY.inventories[inven_ndx].listHiddenCallback
	else
		hiddenCB = nil
	end
	ZO_ScrollList_AddDataType(datalist, CATEGORY_HEADER, templateName, 
	    rowHeight, setupFunc, hiddenCB, nil, resetCB)
end

local function isUngroupedHidden(bagTypeId)
	return bagTypeId == nil or AutoCategory.saved.bags[bagTypeId].isUngroupedHidden
end

local function loadRulesResult(itemEntry, isAtCraftStation)
	local specialType = nil
	if isAtCraftStation then specialType = AC_BAG_TYPE_CRAFTSTATION end
	local matched, categoryName, categoryPriority, bagTypeId, isHidden = AutoCategory:MatchCategoryRules(itemEntry.data.bagId, itemEntry.data.slotIndex, specialType)
	itemEntry.data.AC_matched = matched
	if matched then
		itemEntry.data.AC_categoryName = categoryName
		itemEntry.data.AC_sortPriorityName = string.format("%03d%s", 100 - categoryPriority , categoryName)
	else
		itemEntry.data.AC_categoryName = AutoCategory.acctSaved.appearance["CATEGORY_OTHER_TEXT"]
		itemEntry.data.AC_sortPriorityName = string.format("%03d%s", 999 , categoryName)
	end
	itemEntry.data.AC_bagTypeId = bagTypeId
	itemEntry.data.AC_isHidden = isHidden
end

local function isHiddenEntry(itemEntry)
	return itemEntry.data.AC_isHidden or (itemEntry.data.AC_bagTypeId ~= nil and ((not matched and isUngroupedHidden(itemEntry.data.AC_bagTypeId)) or AutoCategory.IsCategoryCollapsed(itemEntry.data.AC_bagTypeId, itemEntry.data.AC_categoryName)))
end

local function createHeaderEntry(itemEntry, reuseCount)
	local headerEntry = ZO_ScrollList_CreateDataEntry(CATEGORY_HEADER, {bestItemTypeName = itemEntry.data.AC_categoryName, stackLaunderPrice = 0})
	headerEntry.data.AC_categoryName = itemEntry.data.AC_categoryName
	headerEntry.data.AC_sortPriorityName = itemEntry.data.AC_sortPriorityName
	headerEntry.data.AC_isHeader = true
	headerEntry.data.AC_bagTypeId = itemEntry.data.AC_bagTypeId
	if reuseCount then headerEntry.data.AC_catCount = itemEntry.data.AC_catCount
	else headerEntry.data.AC_catCount = 1 end
	return headerEntry
end

-- global variables used by sort hooks for change detection
local hashGlobal = "InitialHash" -- a hash representing the last 'state', so changes can be detected. Use bag, filter and sorting infos.
local function forceRuleReloadGlobal(reloadTypeString)
	hashGlobal = "forceRuleReloadGlobal-" .. tostring(reloadTypeString)
end

local function detectGlobalChanges()
	--local scene = "" -- Retrieve current scene
	--if SCENE_MANAGER and SCENE_MANAGER:GetCurrentScene() then
	--	scene = SCENE_MANAGER:GetCurrentScene():GetName()
	--end
	local quickSlotHash = "" -- retrieve quickslots uniqueIDs
	for i = ACTION_BAR_FIRST_UTILITY_BAR_SLOT + 1, ACTION_BAR_FIRST_UTILITY_BAR_SLOT + ACTION_BAR_EMOTE_QUICK_SLOT_SIZE do
		quickSlotHash = quickSlotHash .. ":" .. tostring(GetSlotItemLink(i))
	end
	local newHash = buildHashString(--[[scene, ]]quickSlotHash) -- use hash for change detection
	if newHash ~= hashGlobal then -- test if changes detected
		--d("[AUTO-CAT] global hash change: "..tostring(hashGlobal).." -> "..tostring(newHash))
		hashGlobal = newHash -- reset hash for next hook
		return true
	end
	return false
end

local forceRuleReloadByUniqueIDs = {} -- uniqueIDs of items that have been updated (need rule re-execution), based on PLAYER_INVENTORY:OnInventorySlotUpdated hook
local function forceRuleReloadForSlot(bagId, slotIndex)
	table.insert(forceRuleReloadByUniqueIDs, GetItemUniqueId(bagId, slotIndex))
end

local function detectItemChanges(itemEntry)
	--- Hash construction
	local hashFCOIS = "" -- retrieve FCOIS mark data for change detection with itemEntry hash
	if FCOIS and itemEntry.data.bagId and itemEntry.data.bagId > 0 and itemEntry.data.slotIndex and itemEntry.data.slotIndex > 0 then
		local _, markedIconsArray = FCOIS.IsMarked(itemEntry.data.bagId, itemEntry.data.slotIndex, -1)
		if markedIconsArray then
			for _, value in ipairs(markedIconsArray) do
				hashFCOIS = hashFCOIS .. tostring(value)
			end
		end
	end
	local newEntryHash = buildHashString(itemEntry.data.isPlayerLocked, itemEntry.data.isGemmable, itemEntry.data.stolen, itemEntry.data.isBoPTradeable, itemEntry.data.isInArmory, itemEntry.data.brandNew, itemEntry.data.bagId, itemEntry.data.stackCount, itemEntry.data.uniqueId, itemEntry.data.slotIndex, itemEntry.data.meetsUsageRequirement, itemEntry.data.locked, itemEntry.data.isJunk, hashFCOIS)

	--- Test hash change
	local changeDetected = false
	if itemEntry.data.AC_hash == nil or itemEntry.data.AC_hash ~= newEntryHash then
		if itemEntry.data.AC_hash ~= nil then
			--d("[AUTO-CAT] item hash change: "..tostring(itemEntry.data.AC_hash).." -> "..tostring(newEntryHash))
			--d("[AUTO-CAT] item hash change: "..GetItemLink(itemEntry.data.bagId, itemEntry.data.slotIndex))
		end
		itemEntry.data.AC_hash = newEntryHash
		changeDetected = true
	end

	--- Test last update time, triggers update if more than 2s
	local currentTime = os.clock()
	if not changeDetected and itemEntry.data.AC_lastUpdateTime ~= nil then
		if currentTime - tonumber(itemEntry.data.AC_lastUpdateTime) > 2 then
			changeDetected = true
		end
	end

	--- Test if uniqueID tagged for update
	if not changeDetected then
		for _, uniqueID in ipairs(forceRuleReloadByUniqueIDs) do -- look for items with changes detected
			if itemEntry.data.uniqueID == uniqueID then
				--d("[AUTO-CAT] item uniqueID update: "..GetItemLink(itemEntry.data.bagId, itemEntry.data.slotIndex))
				changeDetected = true
			end
		end
	end

	if changeDetected then itemEntry.data.AC_lastUpdateTime = currentTime end
	return changeDetected
end

--- Execute rules and store result in itemEntry.data, if needed. Return true if scrollData should be processed (no headers was found or at least one itemEntry was updated), false otherwise.
local function handleRules(scrollData, isAtCraftStation)
	local updateCount = 0 -- indicate if at least one item has been updated with new rule results
	local reloadAll = isAtCraftStation or detectGlobalChanges() -- at craft stations scrollData seems to be reset every time, so need to always reload
	for _, itemEntry in ipairs(scrollData) do
		if itemEntry.typeId ~= CATEGORY_HEADER then -- headers are not matched with rules
			-- 'detectItemChanges(itemEntry) or reloadAll' need to be in this order so hash is always computed and stored
			if detectItemChanges(itemEntry) or reloadAll then -- reload rules if full reload triggered, or changes detected
				--d("[AUTO-CAT] reloading one: "..tostring(itemEntry.data.AC_hash).." -> "..tostring(newEntryHash))
				updateCount = updateCount + 1
				loadRulesResult(itemEntry, isAtCraftStation)
			end
		end
	end
	forceRuleReloadByUniqueIDs = {} -- reset update buffer
	return updateCount
end

--- Create new category or update existing. Return created category, or nil.
local function handleCategory(category_list, itemEntry)
	local categoryName = itemEntry.data.AC_categoryName
	if category_list[categoryName] == nil then -- first time seeing this category name -> create new header
		if itemEntry.typeId == CATEGORY_HEADER then -- a category header already existing in scrollData
			if AutoCategory.IsCategoryCollapsed(itemEntry.data.AC_bagTypeId, categoryName) then -- the category is collapsed -> matching items are not contained in scrollData input -> reuse previous count
				category_list[categoryName] = createHeaderEntry(itemEntry, true)
				return category_list[categoryName]
			else --> category not collapsed, do not create header here, will recreate and recount items
				return nil
			end
		elseif itemEntry.data.AC_matched or not isUngroupedHidden(itemEntry.data.AC_bagTypeId) then --> regular item, not ungrouped and hidden
			category_list[categoryName] = createHeaderEntry(itemEntry) -- new header, new count
			return category_list[categoryName]
		end
	elseif itemEntry.typeId ~= CATEGORY_HEADER then -- header already existing -> increment category count if this is not a header
		category_list[categoryName].data.AC_catCount = category_list[categoryName].data.AC_catCount + 1
	end
	return nil
end

local function createNewScrollData(scrollData, inventoryType)
	local category_list = {} -- keep track of categories added and their item count
	local newScrollData = {} -- output, entries sorted with category headers
	for _, itemEntry in ipairs(scrollData) do -- create newScrollData with headers and only non hidden items
		if itemEntry.typeId ~= CATEGORY_HEADER then
			if not isHiddenEntry(itemEntry) then table.insert(newScrollData, itemEntry) end -- add itemEntry if visible
		end
		local category = handleCategory(category_list, itemEntry)
		if category ~= nil then
			table.insert(newScrollData, category) -- add header or update header count
		end
	end
	return newScrollData
end

local function prehookSort(self, inventoryType) 
	--d("[AUTO-CAT] -> prehookSort ("..inventoryType.." - "..tostring(AutoCategory.Enabled)..") <-- START")

	--- Stop conditions: AC is disabled or quest items are displayed
	local stop = (not AutoCategory.Enabled) or (inventoryType == INVENTORY_QUEST_ITEM)
	if stop then return false end -- reverse to default behavior: default ApplySort() function is used

	local inventory = self.inventories[inventoryType]
	if inventory == nil then
		-- Use normal inventory by default (instead of the quest item inventory for example)
		inventory = self.inventories[self.selectedTabType]
	end
	inventory.sortFn =  function(left, right) -- set new inventory sort function
		if AutoCategory.Enabled then
			if right.data.AC_sortPriorityName ~= left.data.AC_sortPriorityName then
				return NilOrLessThan(left.data.AC_sortPriorityName, right.data.AC_sortPriorityName)
			end
			if right.data.AC_isHeader ~= left.data.AC_isHeader then
				return NilOrLessThan(right.data.AC_isHeader, left.data.AC_isHeader)
			end
		end
		--compatible with quality sort
		if type(inventory.currentSortKey) == "function" then
			if inventory.currentSortOrder == ZO_SORT_ORDER_UP then
				return inventory.currentSortKey(left.data, right.data)
			else
				return inventory.currentSortKey(right.data, left.data)
			end
		end
		return ZO_TableOrderingFunction(left.data, right.data, inventory.currentSortKey, sortKeys, inventory.currentSortOrder)
	end

	local scene = "" -- Retrieve current scene
	if SCENE_MANAGER and SCENE_MANAGER:GetCurrentScene() then
		scene = SCENE_MANAGER:GetCurrentScene():GetName()
	end

	--- Bulk mode (when bank is open): hold all sorting for a time, full refresh when it's over (triggered by AutoCategory.ExitBulkMode()).
	if AutoCategory.IsInBulkMode() and (scene == "guildBank" or scene == "bank") then -- No bulk mode if not in bank
		--d("[AUTO-CAT] -> prehookSort - bulk mode")
		forceRuleReloadGlobal("BulkMode") -- trigger rules reload when exiting bulk mode
		return AutoCategory.IsInHardBulkMode() --- also skip default behavior if hard mode
	end
	local scrollData = ZO_ScrollList_GetDataList(inventory.listView)
	if #scrollData == 0 then return false end -- empty inventory -> skip rules execution / category handling

	--- a header existing means the scrollData is untouched since last sort
	local noHeaderFound = true
	for _, itemEntry in ipairs(scrollData) do
		if itemEntry.typeId == CATEGORY_HEADER then
			noHeaderFound = false
			break
		end
	end

	local updateCount = handleRules(scrollData, false)
	if noHeaderFound or updateCount > 0 then
		--- scrollData is reset or item(s) updated --> rebuild scrollData with headers
		inventory.listView.data = createNewScrollData(scrollData, inventoryType)
	end
	--d("[AUTO-CAT] END - "..inventoryType.." ("..tostring(noHeaderFound)..", "..tostring(updateCount)..")")
	return false -- continue with default behavior: default ApplySort() function is used with custom inventory sort function
end

local function prehookCraftSort(self)
	--d("[AUTO-CAT] -> prehookCraftSort ("..tostring(AutoCategory.Enabled)..") <-- START")
	if not AutoCategory.Enabled then return false end -- reverse to default behavior if disabled

	local scrollData = ZO_ScrollList_GetDataList(self.list)
	if #scrollData == 0 then return false end -- empty inventory -> revert to default behavior

	--change sort function
	--self.sortFunction = function(left,right) sortInventoryFn(self,left,right) end
	self.sortFunction = function(left, right) 
		if AutoCategory.Enabled then
			if right.data.AC_sortPriorityName ~= left.data.AC_sortPriorityName then
				return NilOrLessThan(left.data.AC_sortPriorityName, right.data.AC_sortPriorityName)
			end
			if right.data.AC_isHeader ~= left.data.AC_isHeader then
				return NilOrLessThan(right.data.AC_isHeader, left.data.AC_isHeader)
			end
			--compatible with quality sort
			if type(self.sortKey) == "function" then 
				if self.sortOrder == ZO_SORT_ORDER_UP then
					return self.sortKey(left.data, right.data)
				else
					return self.sortKey(right.data, left.data)
				end
			end
		end
		return ZO_TableOrderingFunction(left.data, right.data, self.sortKey, sortKeys, self.sortOrder)
	end

	handleRules(scrollData, "craft-station", true)
	local newScrollData = createNewScrollData(scrollData)
	table.sort(newScrollData, self.sortFunction)
	self.list.data = newScrollData  
end

local function refresh(refreshList, forceRuleReload, reloadTypeString)
	--d("[AUTO-CAT] -> refresh called: " .. tostring(reloadTypeString))
	if forceRuleReload then
		forceRuleReloadGlobal(reloadTypeString)
	end
	if refreshList then
		AutoCategory.RefreshCurrentList(false)
	end
end

local function getRefreshFunc(refreshList, forceRuleReload, reloadTypeString)
	return function() refresh(refreshList, forceRuleReload, reloadTypeString) end
end

local function onDoQuickSlotUpdate(self, physicalSlot, animationOption)
	if animationOption then -- a quickslot has been changed (manually)
		refresh(true, false, "QuickSlot_update")
	end
end

--local function onLAMPanelClosed(currentPanel)
--	if currentPanel and currentPanel.data.name == AutoCategory.settingName then -- closed panel is AC panel
--	end
--end
--local function onAGLoadProfile(profileId)
--	if AG and profileId ~= AG.setdata.currentProfileId then
--		refresh(false, true, "AG_LoadProfile")
--	end
--end

local function onInventorySlotUpdated(self, bagId, slotIndex)
	forceRuleReloadForSlot(bagId, slotIndex)
end

function AutoCategory.HookKeyboardMode()

	--Add a new data type: row with header
	local rowHeight = AutoCategory.acctSaved.appearance["CATEGORY_HEADER_HEIGHT"]
	
    AddTypeToList(rowHeight, ZO_PlayerInventoryList, INVENTORY_BACKPACK)
    AddTypeToList(rowHeight, ZO_CraftBagList, INVENTORY_BACKPACK)
    AddTypeToList(rowHeight, ZO_PlayerBankBackpack, INVENTORY_BACKPACK)
    AddTypeToList(rowHeight, ZO_GuildBankBackpack, INVENTORY_BACKPACK)
    AddTypeToList(rowHeight, ZO_HouseBankBackpack, INVENTORY_BACKPACK)
    AddTypeToList(rowHeight, ZO_PlayerInventoryQuest, INVENTORY_QUEST_ITEM)
    AddTypeToList(rowHeight, SMITHING.deconstructionPanel.inventory.list, nil)
    AddTypeToList(rowHeight, SMITHING.improvementPanel.inventory.list, nil)
    AddTypeToList(rowHeight, UNIVERSAL_DECONSTRUCTION.deconstructionPanel.inventory.list, nil)
	
	-- sort hooks
	ZO_PreHook(PLAYER_INVENTORY, "ApplySort", prehookSort)
    ZO_PreHook(SMITHING.deconstructionPanel.inventory, "SortData", prehookCraftSort)
    ZO_PreHook(SMITHING.improvementPanel.inventory, "SortData", prehookCraftSort)
    ZO_PreHook(UNIVERSAL_DECONSTRUCTION.deconstructionPanel.inventory, "SortData", prehookCraftSort)
	
	--- changes detection events/hook (anticipate if rules results may have changed)
	ZO_PreHook(PLAYER_INVENTORY, "OnInventorySlotUpdated", onInventorySlotUpdated) -- item has changed
	ZO_PostHook(ZO_QuickslotManager, "DoQuickSlotUpdate", onDoQuickSlotUpdate) -- quick slots updated
	CALLBACK_MANAGER:RegisterCallback("LAM-PanelClosed", getRefreshFunc(true, true, "LAM-PanelClosed")) -- AddonMenu panel closed (AC settings, or others, may have changed)
	EVENT_MANAGER:RegisterForEvent(AutoCategory.name, EVENT_STACKED_ALL_ITEMS_IN_BAG, getRefreshFunc(true, true, "Event_ItemsStacked"))

	--- AlphaGear change detection hook
	if AG then
		ZO_PostHook(AG, "handlePostChangeGearSetItems", getRefreshFunc(true, true, "AG_itemChange"))
		ZO_PostHook(AG, "LoadProfile", getRefreshFunc(true, true, "AG_LoadProfile")) -- can be called twice in a row...
	end

	--if PersonalAssistant and PersonalAssistant.Banking then
	--	ZO_PostHook(PersonalAssistant.Banking.KeybindStrip, "updateBankKeybindStrip", forceInventoryBankRefresh)
	--end
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
