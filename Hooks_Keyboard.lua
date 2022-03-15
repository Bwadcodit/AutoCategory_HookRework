
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

-- global variables used by sort hooks for change detection
AutoCategory.hookUpdateHash = nil -- a hash representing the last 'state', so changes can be detected. Use bag, filter and sorting infos.
AutoCategory.uniqueIdsToUpdate = {} -- uniqueIds of items that have been updated (need rule re-execution)
AutoCategory.lastNewScrollDataSize = 0

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

-- execute rules and store result in entry.data, if needed. Return false if no entry was updated, true otherwise.
local function handleRules(scrollData, newHash, isAtCraftStation)
	local hasUpdated = false -- indicate if at least one item has been updated with new rule results
	local reloadAll = isAtCraftStation -- at craft stations scrollData seems to be reseted every time, so need to always reload
	if newHash ~= AutoCategory.hookUpdateHash then -- test if changes detected
		--d("[AUTO-CAT] reloading all: "..tostring(AutoCategory.hookUpdateHash).." -> "..tostring(newHash))
		AutoCategory.hookUpdateHash = newHash -- reset hash for next hook
		reloadAll = true
	end
	for _, entry in ipairs(scrollData) do
		if entry.typeId ~= CATEGORY_HEADER then -- headers are not matched with rules
			local newEntryHash = buildHashString(entry.data.isPlayerLocked, entry.data.isGemmable, entry.data.stolen, entry.data.isBoPTradeable, entry.data.isInArmory, entry.data.brandNew, entry.data.bagId, entry.data.statusSortOrder, entry.data.stackCount)
			if reloadAll or (entry.data.AC_categoryName == nil) or (newEntryHash ~= entry.data.AC_hash) then -- reload rules if full reload triggered, hash has changed, or item has nothing loaded
				entry.data.AC_hash = newEntryHash
				hasUpdated = true
				loadRulesResult(entry, isAtCraftStation)
			else
				for _, uniqueId in ipairs(AutoCategory.uniqueIdsToUpdate) do -- look for items with changes detected
					if entry.data.uniqueId == uniqueId then
						--d("[AUTO-CAT] reloading: "..tostring(entry.data.name))
						hasUpdated = true
						loadRulesResult(entry, isAtCraftStation)
					end -- does not break in case there is several slots with same uniqueId
				end
			end
		end
	end
	AutoCategory.uniqueIdsToUpdate = {} -- reset update buffer
	return hasUpdated
end

-- Create new category or update existing. Return created category, or nil.
local function handleCategory(category_list, itemEntry)
	local categoryName = itemEntry.data.AC_categoryName
	if category_list[categoryName] == nil then -- first time seeing this category name -> create new header
		if itemEntry.typeId == CATEGORY_HEADER then -- a category header already existing in scrollData
			if AutoCategory.IsCategoryCollapsed(itemEntry.data.AC_bagTypeId, categoryName) then -- the category is collapsed -> matching items are not contained in scrollData input -> reuse previous count
				category_list[categoryName] = createHeaderEntry(itemEntry, true)
				return category_list[categoryName]
			else --> category not collapsed, do not create header here, will recount items and recreate
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

local function createNewScrollData(scrollData)
	local category_list = {} -- keep track of categories added and their item count
	local newScrollData = {} -- output, entries sorted with category headers
	for _, entry in ipairs(scrollData) do -- create newScrollData with headers and only non hidden items
		if entry.typeId ~= CATEGORY_HEADER then
			if not isHiddenEntry(entry) then table.insert(newScrollData, entry) end -- add entry if visible
		end
		table.insert(newScrollData, handleCategory(category_list, entry)) -- add header or update header count
	end
	AutoCategory.lastNewScrollDataSize = #newScrollData
	return newScrollData
end

local function prehookSort(self, inventoryType) 
	--d("[AUTO-CAT] -> prehookSort ("..inventoryType.." - "..tostring(AutoCategory.Enabled)..") <-- START")
	if not AutoCategory.Enabled then return false end -- reverse to default behavior if disabled: default ApplySort() function is used
	if PersonalAssistant and PersonalAssistant.Banking and PersonalAssistant.Banking.isBankItemTransferBlocked then -- PABanking is transfering -> exit and prevent running ApplySort()
		AutoCategory.hookUpdateHash = "PAB-refresh" -- change hash to trigger refresh
		return true 
	end
	-- from nogetrandom
	if SCENE_MANAGER and SCENE_MANAGER:GetCurrentScene() then
		if AutoCategory.BulkMode and AutoCategory.BulkMode == true then
			local scene = SCENE_MANAGER:GetCurrentScene():GetName()
			if scene == "guildBank" or (XLGearBanker and scene == "bank") then
				return false	-- skip out early
			end
		end
	end
	-- end nogetrandom recommend
	--[[
    if SCENE_MANAGER and SCENE_MANAGER:GetCurrentScene() then
        if AutoCategory.BulkMode and AutoCategory.BulkMode == true and SCENE_MANAGER:GetCurrentScene():GetName() == "guildBank" then
            return false	-- skip out early
        end
    end
	--]]
	if inventoryType == INVENTORY_QUEST_ITEM then return false end  -- reverse to default behavior if quest item tab opened

	local inventory = self.inventories[inventoryType]
	if inventory == nil then
		-- Use normal inventory by default (instead of the quest item inventory for example)
		inventory = self.inventories[self.selectedTabType]
	end

	local scrollData = ZO_ScrollList_GetDataList(inventory.listView)
	if #scrollData == 0 then return false end -- empty inventory -> revert to default behavior

	local scrollDataHasChanged = (#scrollData ~= AutoCategory.lastNewScrollDataSize) -- scroll data is new if size changed
	if not scrollDataHasChanged then
		local headerFound = false
		for _, entry in ipairs(scrollData) do
			if entry.typeId == CATEGORY_HEADER then
				headerFound = true -- a header existing here means the scroll data is untouched since last sort
				break
			end
		end
		scrollDataHasChanged = not headerFound -- scroll data is new if it contains no header
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

	-- build a hash with bag, filter and sort identifiers, so it detects any changes and triggers a full rule rerun. 
	local newHash = buildHashString(inventoryType, inventory.currentFilter, inventory.currentSortKey, inventory.currentSortOrder, self.selectedTabType)
	local hasUpdated = handleRules(scrollData, newHash, false)
	if hasUpdated or scrollDataHasChanged then -- changes detected --> rebuild scroll data with headers
		inventory.listView.data = createNewScrollData(scrollData)
	end
	--d("[AUTO-CAT] END ("..tostring(scrollDataHasChanged)..", "..tostring(hasUpdated)..") - "..tostring(#scrollData).." -> "..tostring(AutoCategory.lastNewScrollDataSize))
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

-- force re-execution of rules
local function forceInventoryRefresh()
	AutoCategory.hookUpdateHash = "force_refresh" -- trigger rules execution on next sort hook
	PLAYER_INVENTORY:UpdateList(INVENTORY_BACKPACK, true)-- trigger sort for backpack as opening/closing it does not trigger sort
end

local function forceInventoryBankRefresh()
	AutoCategory.hookUpdateHash = "force_refresh_bank" -- trigger rules execution on next sort hook
	PLAYER_INVENTORY:UpdateList(INVENTORY_BACKPACK, true)-- trigger sort for backpack as opening/closing it does not trigger sort
	PLAYER_INVENTORY:UpdateList(INVENTORY_BANK, true) 
end

local function preHookOnInventorySlotUpdated(self, bagId, slotIndex)
	table.insert(AutoCategory.uniqueIdsToUpdate, GetItemUniqueId(bagId, slotIndex))
end

local function preHookDoQuickSlotUpdate(self, physicalSlot, animationOption)
	if animationOption then -- a quickslot has been changed (manually)
		forceInventoryRefresh()
	end
end

local function preHookLAMPanelClosed(currentPanel)
	if currentPanel and currentPanel.data.name == AutoCategory.settingName then -- closed panel is AC panel
		forceInventoryRefresh()
	end
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
	--ZO_PreHook(ZO_InventoryManager, "ApplySort", prehookSort)
	ZO_PreHook(PLAYER_INVENTORY, "ApplySort", prehookSort)
    ZO_PreHook(SMITHING.deconstructionPanel.inventory, "SortData", prehookCraftSort)
    ZO_PreHook(SMITHING.improvementPanel.inventory, "SortData", prehookCraftSort)
    ZO_PreHook(UNIVERSAL_DECONSTRUCTION.deconstructionPanel.inventory, "SortData", prehookCraftSort)
	
	-- changes detection hook (rules results may have changed)
	ZO_PreHook(PLAYER_INVENTORY, "OnInventorySlotUpdated", preHookOnInventorySlotUpdated) -- items has been changed
	-- ZO_PreHook(ZO_QuickslotManager, "DoQuickSlotUpdate", preHookDoQuickSlotUpdate) -- quick slots updated
	EVENT_MANAGER:RegisterForEvent(AutoCategory.name, EVENT_STACKED_ALL_ITEMS_IN_BAG, forceInventoryRefresh)

	CALLBACK_MANAGER:RegisterCallback("LAM-PanelClosed", preHookLAMPanelClosed) -- AddonMenu panel closed (AC settings may have changed)
	
	if AG then
		ZO_PostHook(AG, "handlePostChangeGearSetItems", forceInventoryRefresh)
		ZO_PostHook(AG, "LoadProfile", forceInventoryRefresh)
	end -- AlphaGear item change

	if PersonalAssistant and PersonalAssistant.Banking then
		ZO_PostHook(PersonalAssistant.Banking.KeybindStrip, "updateBankKeybindStrip", forceInventoryBankRefresh)
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
