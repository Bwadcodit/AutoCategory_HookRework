--[[
CHANGE DETECTION STRATEGY
This file uses hooks on API functions: PLAYER_INVENTORY:ApplySort, SMITHING.deconstructionPanel.inventory:SortData, and SMITHING.improvementPanel.inventory:SortData to order items in categories, in all inventories (including crafting station)
This process involves executing all active rules for each items, and can be triggered multiple times in a row, notably for bank transfers (more than ten calls)
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
	if (itemEntry.data.bagId ~= AutoCategory.checkingItemBagId) or (itemEntry.data.slotIndex ~= AutoCategory.checkingItemSlotIndex) then --- Weird bug: sometimes AutoCategory.checkingItemSlotIndex reset to 0 during rules matching and thus the result is invalid
		--local itemLink1 = GetItemLink(itemEntry.data.bagId, itemEntry.data.slotIndex)
		--local itemLink2 = GetItemLink(AutoCategory.checkingItemBagId, AutoCategory.checkingItemSlotIndex)
		--d("[AUTO-CAT] MATCHING BUG: "..itemLink1.."("..tostring(itemEntry.data.bagId).."-"..tostring(itemEntry.data.slotIndex)..") --> "..itemLink2.."("..tostring(AutoCategory.checkingItemBagId).."-"..tostring(AutoCategory.checkingItemSlotIndex)..")")
		matched, categoryName, categoryPriority, bagTypeId, isHidden = AutoCategory:MatchCategoryRules(itemEntry.data.bagId, itemEntry.data.slotIndex, specialType)
		if (itemEntry.data.bagId ~= AutoCategory.checkingItemBagId) or (itemEntry.data.slotIndex ~= AutoCategory.checkingItemSlotIndex) then
			local itemLink1 = GetItemLink(itemEntry.data.bagId, itemEntry.data.slotIndex)
			local itemLink2 = GetItemLink(AutoCategory.checkingItemBagId, AutoCategory.checkingItemSlotIndex)
			d("[AUTO-CAT] MATCHING BUG 2: "..itemLink1.."("..tostring(itemEntry.data.bagId).."-"..tostring(itemEntry.data.slotIndex)..") --> "..itemLink2.."("..tostring(AutoCategory.checkingItemBagId).."-"..tostring(AutoCategory.checkingItemSlotIndex)..")")
		end
	end
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
	return itemEntry.data.AC_isHidden or (itemEntry.data.AC_bagTypeId ~= nil and ((not itemEntry.data.AC_matched and isUngroupedHidden(itemEntry.data.AC_bagTypeId)) or AutoCategory.IsCategoryCollapsed(itemEntry.data.AC_bagTypeId, itemEntry.data.AC_categoryName)))
end

local hashGlobal = "InitialHash" --- a hash representing the last 'global state', so changes can be detected.
local function forceRuleReloadGlobal(reloadTypeString)
	hashGlobal = "forceRuleReloadGlobal-" .. tostring(reloadTypeString)
end

local function detectGlobalChanges()
	--local scene = "" -- Retrieve current scene
	--if SCENE_MANAGER and SCENE_MANAGER:GetCurrentScene() then
	--	scene = SCENE_MANAGER:GetCurrentScene():GetName()
	--end
	local quickSlotHash = "" --- retrieve quickslots uniqueIDs
	for i = ACTION_BAR_FIRST_UTILITY_BAR_SLOT + 1, ACTION_BAR_FIRST_UTILITY_BAR_SLOT + ACTION_BAR_EMOTE_QUICK_SLOT_SIZE do
		quickSlotHash = quickSlotHash .. ":" .. tostring(GetSlotItemLink(i))
	end
	local newHash = buildHashString(--[[scene, ]]quickSlotHash) --- use hash for change detection
	if newHash ~= hashGlobal then --- test if changes detected
		--d("[AUTO-CAT] global hash change: "..tostring(hashGlobal).." -> "..tostring(newHash))
		hashGlobal = newHash --- reset hash for next hook
		return true
	end
	return false
end

local forceRuleReloadByUniqueIDs = {} --- uniqueIDs of items that have been updated (need rule re-execution), based on PLAYER_INVENTORY:OnInventorySlotUpdated hook
local function forceRuleReloadForSlot(bagId, slotIndex)
	table.insert(forceRuleReloadByUniqueIDs, GetItemUniqueId(bagId, slotIndex))
end

local function detectItemChanges(itemEntry)
	--- Hash construction
	local hashFCOIS = "" --- retrieve FCOIS mark data for change detection with itemEntry hash
	if FCOIS and itemEntry.data.bagId and itemEntry.data.bagId > 0 and itemEntry.data.slotIndex and itemEntry.data.slotIndex > 0 then
		local _, markedIconsArray = FCOIS.IsMarked(itemEntry.data.bagId, itemEntry.data.slotIndex, -1)
		if markedIconsArray then
			for _, value in ipairs(markedIconsArray) do
				hashFCOIS = hashFCOIS .. tostring(value)
			end
		end
	end
	local newEntryHash = buildHashString(itemEntry.data.isPlayerLocked, itemEntry.data.isGemmable, itemEntry.data.stolen, itemEntry.data.isBoPTradeable, itemEntry.data.isInArmory, itemEntry.data.brandNew, itemEntry.data.bagId, itemEntry.data.stackCount, itemEntry.data.uniqueId, itemEntry.data.slotIndex, itemEntry.data.meetsUsageRequirement, itemEntry.data.locked, itemEntry.data.isJunk, hashFCOIS)

	--- Update hash and test if changed
	local changeDetected = false
	if itemEntry.data.AC_hash == nil or itemEntry.data.AC_hash ~= newEntryHash then
		--if itemEntry.data.AC_hash ~= nil then
			--d("[AUTO-CAT] item hash change: "..tostring(itemEntry.data.AC_hash).." -> "..tostring(newEntryHash))
			--d("[AUTO-CAT] item hash change: "..GetItemLink(itemEntry.data.bagId, itemEntry.data.slotIndex))
		--end
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
		for _, uniqueID in ipairs(forceRuleReloadByUniqueIDs) do --- look for items with changes detected
			if itemEntry.data.uniqueID == uniqueID then
				--d("[AUTO-CAT] item uniqueID update: "..GetItemLink(itemEntry.data.bagId, itemEntry.data.slotIndex))
				changeDetected = true
			end
		end
	end

	if changeDetected then itemEntry.data.AC_lastUpdateTime = currentTime end
	return changeDetected
end

--- Execute rules and store results in itemEntry.data, if needed. Return the number of items updated with rule re-execution.
local function handleRules(scrollData, isAtCraftStation)
	local updateCount = 0 --- indicate if at least one item has been updated with new rule results
	local reloadAll = isAtCraftStation or detectGlobalChanges() --- at craft stations scrollData seems to be reset every time, so need to always reload
	for _, itemEntry in ipairs(scrollData) do
		if itemEntry.typeId ~= CATEGORY_HEADER then --- headers are not matched with rules
			--- 'detectItemChanges(itemEntry) or reloadAll' need to be in this order so hash is always updated
			if detectItemChanges(itemEntry) or reloadAll then -- reload rules if full reload triggered, or changes detected
				--d("[AUTO-CAT] reloading one: "..tostring(itemEntry.data.AC_hash).." -> "..tostring(newEntryHash))
				updateCount = updateCount + 1
				loadRulesResult(itemEntry, isAtCraftStation)
			end
		end
	end
	forceRuleReloadByUniqueIDs = {} --- reset update buffer
	return updateCount
end

--- Create list with visible items and header (performs category count).
local function createNewScrollData(scrollData)
	local newScrollData = {} --- output, entries sorted with category headers
	local category_dataList = {} --- keep track of categories added and their item count
	for _, itemEntry in ipairs(scrollData) do --- create newScrollData with headers and only non hidden items. No sorting here
		if itemEntry.typeId ~= CATEGORY_HEADER and not isHiddenEntry(itemEntry) then --- add item if visible
			table.insert(newScrollData, itemEntry)
		end
		local categorySortName = itemEntry.data.AC_sortPriorityName
		if categorySortName then
			if not category_dataList[categorySortName] then --- new category --> track it
				local catCount = -1
				local catCountIsNew = false
				if itemEntry.typeId ~= CATEGORY_HEADER then --- this is an item, start new count
					catCount = 1 ---> new count (counting the current item)
					catCountIsNew = true
				elseif itemEntry.typeId == CATEGORY_HEADER and AutoCategory.IsCategoryCollapsed(itemEntry.data.AC_bagTypeId, itemEntry.data.AC_categoryName) then --- this is a collapsed category --> reuse previous count, this is in case the category is collapsed and the content is not available in scrollData
					catCount = itemEntry.data.AC_catCount
					catCountIsNew = false
				end
				if catCount > 0 then
					category_dataList[categorySortName] =  {name = itemEntry.data.AC_categoryName, bagTypeId = itemEntry.data.AC_bagTypeId, count = catCount, isNewCount = catCountIsNew} --- keep track of categories and required data
				end --- else this is an expanded category -> do not reuse
			elseif itemEntry.typeId ~= CATEGORY_HEADER then --- category is tracked and this a regular item
				local categoryData = category_dataList[categorySortName]
				if categoryData.isNewCount then --- new count in progress --> increment
					categoryData.count = categoryData.count + 1
				else --- was using previous count --> use new count, (counting the current item)
					categoryData.count = 1
					categoryData.isNewCount = true
				end
			end
		end
	end
	for categorySortName, categoryData in pairs(category_dataList) do ---> add tracked categories
		local headerEntry = ZO_ScrollList_CreateDataEntry(CATEGORY_HEADER, {bestItemTypeName = categoryData.name, stackLaunderPrice = 0})
		headerEntry.data.AC_categoryName = categoryData.name
		headerEntry.data.AC_sortPriorityName = categorySortName
		headerEntry.data.AC_isHeader = true
		headerEntry.data.AC_bagTypeId = categoryData.bagTypeId
		headerEntry.data.AC_catCount = categoryData.count
		table.insert(newScrollData, headerEntry)
	end
	return newScrollData
end

local function prehookSort(self, inventoryType) 
	--d("[AUTO-CAT] -> prehookSort ("..inventoryType.." - "..tostring(AutoCategory.Enabled)..") <-- START")
	--- Stop conditions: AC is disabled or quest items are displayed
	local stop = (not AutoCategory.Enabled) or (inventoryType == INVENTORY_QUEST_ITEM)
	if stop then return false end --- reverse to default behavior: default ApplySort() function is used

	local inventory = self.inventories[inventoryType]
	if inventory == nil then
		--- Use normal inventory by default (instead of the quest item inventory for example)
		inventory = self.inventories[self.selectedTabType]
	end
	inventory.sortFn =  function(left, right) --- set new inventory sort function
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
	if AutoCategory.IsInBulkMode() and (scene == "guildBank" or scene == "bank") then --- No bulk mode if not in bank
		--d("[AUTO-CAT] -> prehookSort - bulk mode")
		forceRuleReloadGlobal("BulkMode") --- trigger rules reload when exiting bulk mode
		return AutoCategory.IsInHardBulkMode() --- also skip default behavior if hard mode
	end

	local scrollData = ZO_ScrollList_GetDataList(inventory.listView)
	if #scrollData == 0 then return false end --- empty inventory -> skip rules execution / category handling

	local updateCount = handleRules(scrollData, false) ---> update rules' results if necessary
	inventory.listView.data = createNewScrollData(scrollData) ---> rebuild scrollData with headers and visible items
	--d("[AUTO-CAT] END - "..inventoryType.." ("..tostring(updateCount)..")")
	return false --- continue with default behavior: default ApplySort() function is used with custom inventory sort function
end

local function prehookCraftSort(self)
	--d("[AUTO-CAT] -> prehookCraftSort ("..tostring(AutoCategory.Enabled)..") <-- START")
	if not AutoCategory.Enabled then return false end --- reverse to default behavior if disabled

	local scrollData = ZO_ScrollList_GetDataList(self.list)
	if #scrollData == 0 then return false end --- empty inventory -> revert to default behavior

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
	if animationOption then --- a quickslot has been changed (manually)
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
	
	--- sort hooks
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
