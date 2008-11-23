local MAJOR,MINOR = "LibBagUtils-1.0",1
local lib = LibStub:NewLibrary(MAJOR,MINOR)

--
-- LibBagUtils
-- 
-- Several useful bag related APIs that you wish were built into the WoW API:
--   :PutItem()
--   :Iterate()
--   :FindSmallestStack()
--
-- Read the well-commented "API" function headers for each function below for usage and descriptions.
--



if not lib then return end -- no upgrade needed

local strmatch=string.match
local gsub=string.gsub

-- This array contains all known bags, sorted with specialty bags first
local bags={
	["BAGS"] = {},
	["BANK"] = {},
	["BAGSBANK"] = {},
}
local bagsChanged = true	-- time to call updateBags()!

lib.frame = lib.frame or CreateFrame("frame", nil, string.gsub(MAJOR,"[^%w]", "_").."_Frame")
lib.frame:SetScript("OnEvent", function() bagsChanged=true end)

lib.frame:RegisterEvent("BAG_CLOSED")	-- happens when bags are shuffled around, also bank bags
lib.frame:RegisterEvent("PLAYERBANKSLOTS_CHANGED")  -- only really necessary when shopping new slots
lib.frame:RegisterEvent("BANKFRAME_OPENED")	-- time to add bank bags to the list
lib.frame:RegisterEvent("BANKFRAME_CLOSED")	-- ... remove em again!


-----------------------------------------------------------------------
-- General-purpose utilities:

local function print(msg) 
	msg = gsub(msg, "\124", "\\124");
	(SELECTED_CHAT_FRAME or DEFAULT_CHAT_FRAME):AddMessage("LibBagUtils: "..msg)
end

local function escapePatterns(str)
	return gsub(str, "([-.?*%%%[%]])", "%%%1")
end

local function truncateArray(array, newLength)
	for i=#array, newLength+1, -1 do
		array[i]=nil
	end
end

local function appendArray(dst, src, at)
	local n=at or #dst
	for i=1,#src do
		n=n+1
		dst[n]=src[i]
	end
	return n
end


-----------------------------------------------------------------------
-- updateBags()
-- Updates the contents of the bags[] arrays, and set bagsChanged to false

local function updateBags()
	-- Update the contents of bags["BAGS"], bags["BANK"], etc
	-- Create the arrays so that specialty bags are FIRST in the list
	local nBags,nBank,nBagsBank=0,0,0

	-- First add special bags
	for i=1,NUM_BAG_SLOTS do
		local free,fam = GetContainerNumFreeSlots(i)
		if fam and fam~=0 then
			bags.BAGS[nBags+1]=i; nBags=nBags+1
		end
	end
	
	for i=NUM_BAG_SLOTS+1,NUM_BAG_SLOTS+NUM_BANKBAGSLOTS do
		local free,fam = GetContainerNumFreeSlots(i)
		if fam and fam~=0 then
			bags.BANK[nBank+1]=i; nBank=nBank+1
		end
	end
	
	-- Keyring
	bags.BAGS[nBags+1]=KEYRING_CONTAINER; nBags=nBags+1

	-- Backpack
	bags.BAGS[nBags+1]=BACKPACK_CONTAINER; nBags=nBags+1

	-- Main bank frame
	if select(2, GetContainerNumFreeSlots(BANK_CONTAINER)) then
		bags.BANK[nBank+1]=BANK_CONTAINER; nBank=nBank+1
	end
	
	-- Now add nonspecial bags
	for i=1,NUM_BAG_SLOTS do
		local free,fam = GetContainerNumFreeSlots(i)
		if fam and fam==0 then
			bags.BAGS[nBags+1]=i; nBags=nBags+1
		end
	end
	
	for i=NUM_BAG_SLOTS+1,NUM_BAG_SLOTS+NUM_BANKBAGSLOTS do
		local free,fam = GetContainerNumFreeSlots(i)
		if fam and fam==0 then
			bags.BANK[nBank+1]=i; nBank=nBank+1
		end
	end
	
	-- Create the "BAGSBANK" array
	nBagsBank = appendArray(bags.BAGSBANK, bags.BAGS, nBagsBank)
	nBagsBank = appendArray(bags.BAGSBANK, bags.BANK, nBagsBank)

	-- Delete leftovers at the end of the arrays
	truncateArray(bags.BAGS, nBags)
	truncateArray(bags.BANK, nBank)
	truncateArray(bags.BAGSBANK, nBagsBank)
	
	-- Declare bags up to date
	bagsChanged = false
end


-----------------------------------------------------------------------
-- API :Iterate("which"[, "lookingfor"])
-- 
-- which       - string: "BAGS", "BANK", "BAGSBANK"
-- lookingfor  - OPTIONAL: itemLink, itemName, itemString or itemId(number)
--
-- Returns an iterator that can be used in a for loop, e.g.:
--   for bag,slot,link in LBU:Iterate("BAGS") do   -- loop all slots
--   for bag,slot,link in LBU:Iterate("BAGSBANK", 29434) do  -- find all badges of justice

function lib:Iterate(which,lookingfor)
	if bagsChanged then
		updateBags()
	end
	
	local baglist=bags[which]
	if not baglist  then
		error([[Usage: LibBagUtils:Iterate(which [, itemid or itemlink])]], 2)
	end
	
	local bagidx,slot,curbagsize=0,0,0
	local function iterator()
		if bagsChanged then
			print("Bags were changed during work. Aborting current operation.")	-- This should tell the user he fubard.
			return nil
		end
		while slot>=curbagsize do
			bagidx=bagidx+1
			if not baglist[bagidx] then
				return nil
			end
			curbagsize=GetContainerNumSlots(baglist[bagidx]) or 0
			slot=0
		end	
		
		slot=slot+1
		return baglist[bagidx],slot,GetContainerItemLink(baglist[bagidx],slot)
	end
	
	if not lookingfor then
		return iterator
	else
		if type(lookingfor)=="number" then
			lookingfor="|Hitem:"..escapePatterns(lookingfor).."[:|]"	-- "item:-12345" -> "item:%-12345[:|]"
		elseif type(lookingfor)=="string" then
			if strmatch(lookingfor, "^item:.*") then	-- terminate itemstring
				lookingfor = "|H" .. escapePatterns(lookingfor) .. "[:|]"
			elseif strmatch(lookingfor, "|H") then		-- as it were
				lookingfor = escapePatterns(lookingfor)
			else	-- put "|h[" and "]|h" around a name
				lookingfor = "|h%["..escapePatterns(lookingfor).."%]|h"
			end
		end
		return function()
			for bag,slot in iterator do
				local link=GetContainerItemLink(bag,slot)
				if link and strmatch(GetContainerItemLink(bag,slot) or "", lookingfor) then
					return bag,slot,link
				end
			end
		end
	end
	
end

-----------------------------------------------------------------------
-- API :FindSmallestStack("where", "lookingfor"[, notLocked])
--
-- where       - string: "BAGS", "BANK", "BAGSBANK"
-- lookingfor  - itemLink, itemName, itemString or itemId(number)
-- notLocked   - OPTIONAL: if true, will NOT return locked slots
--
-- Returns:  bag,slot,size    or nil on failure

function lib:FindSmallestStack(where,lookingfor,notLocked)
	local lockedIsOk = not notLocked
	local smallest=9e9
	local smbag,smslot
	for bag,slot in lib:Iterate(where,lookingfor) do
		local _, itemCount, locked, _, _ = GetContainerItemInfo(bag,slot)
		if itemCount<smallest and (lockedIsOk or not locked) then
			smbag=bag
			smslot=slot
		end
	end
	return smbag,smslot,smallest	-- will be nil if none was found
end


-----------------------------------------------------------------------
-- API :PutItem("where"[, dontClearOnFail[, count]])
--
-- Put the item currently held by the cursor in the most suitable bag 
-- (considering specialty bags, already-existing stacks..)
--
-- where           - string: "BAGS", "BANK", "BAGSBANK"
-- dontClearOnFail - OPTIONAL: boolean: If the put operation fails due to no room, do NOT clear the cursor. (Note that some other wow client errors WILL clear the cursor)
-- count           - OPTIONAL: number: if given, PutItem() will attempt to stack the item on top of another suitable stack. This is not possible without knowing the count.
--
-- Returns:  bag,slot    or false for out-of-room
--           0,0 will be returned if the function is called without an item in the cursor

function lib:PutItem(where, dontClearOnFail, count)
	if bagsChanged then
		updateBags()
	end

	local cursorType,itemId,itemLink = GetCursorInfo()
	if cursorType~="item" then
		geterrorhandler()(MAJOR..": PutItem(): There was no item in the cursor.")
		return 0,0	-- we consider nothing-at-all successfully disposed of (0,0 contains nil)
	end

	local baglist=bags[where]
	if not baglist then
		error([[Usage: LibBagUtils:PutItem(where[, dontClearOnFail])]], 2)
	end

	-- FIRST: if we have a known count, and the item is stackable, we try putting it on top of something else (look for the BIGGEST stack to put it on top of for max packing!)
	if count and count>=1 then
		local _, _, _, _, _, _, _, itemStackCount = GetItemInfo(itemLink)
		if itemStackCount>1 and count<itemStackCount then
			local bestsize,bestbag,bestslot=0
			for bag,slot in lib:Iterate(where, itemId) do -- Only look for itemId, not the full string; we assume everything of the same itemId is stackable. Looking at the full itemstring is futile since everything has unique IDs these days.
				local _, ciCount, ciLocked, _, _ = GetContainerItemInfo(bag,slot)
				if ciLocked then
					-- nope!
				elseif ciCount+count<=itemStackCount and ciCount>bestsize then
					bestsize=ciCount
					bestbag=bestbag
					bestslot=bestslot
				end
			end
			if bestbag then	-- Place it!
				PickupContainerItem(bestbag,bestslot)
				if not CursorHasItem() then	-- success!
					return bestbag,bestslot
				end
				-- if we got here, the item couldn't be placed on top of the other for some reason, possibly because our assumption about equal itemids being wrong
				-- either way, we fall down and continue looking for somewhere to put it
			end
			-- Fall down and look for empty slots instead
		end
	end
	
	-- Put the item in the first empty slot that it CAN be put in!  (our bag list is sorted with specialty bags first!)
	local itemFam = GetItemFamily(itemLink)
	if itemFam~=0 and select(9,GetItemInfo(itemLink))=="INVTYPE_BAG" then
		itemFam = 0	-- Ouch, it was a bag. Bags are always family 0 for purposes of trying to PUT them somewhere.
	end
	
	for _,bag in ipairs(baglist) do
		local bagFree, bagFam = GetContainerNumFreeSlots(bag)
		if (bagFree or 0)<1 then
			-- full
		elseif bagFam==0 or bit.band(itemFam,bagFam)~=0 then	-- compatible bag!
			for slot=1,GetContainerNumSlots(bag) do
				if not GetContainerItemInfo(bag,slot) then	-- empty!
					PickupContainerItem(bag,slot)
					if not CursorHasItem() then -- success!
						return bag,slot
					end
					-- If we get here, something is probably severely broken. But we keep looping hoping for the best.
				end
			end
		end
	end
	
	if not dontClearOnFail then
		ClearCursor()
	end
	return false	-- no room for it!
end



