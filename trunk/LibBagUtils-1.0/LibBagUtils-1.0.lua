local MAJOR,MINOR = "LibBagUtils-1.0", tonumber(("$Revision$"):match("%d+"))
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
local bagsChangedProcessed = 0
local bagsChanged = 1  -- time to call updateBags()!

lib.frame = lib.frame or CreateFrame("frame", string.gsub(MAJOR,"[^%w]", "_").."_Frame")
lib.frame:SetScript("OnEvent", function() bagsChanged=bagsChanged+1 end)

lib.frame:RegisterEvent("BAG_CLOSED")	-- happens when bags are shuffled around, also bank bags
lib.frame:RegisterEvent("PLAYERBANKSLOTS_CHANGED")  -- only really necessary when shopping new slots
lib.frame:RegisterEvent("BANKFRAME_OPENED")	-- time to add bank bags to the list
lib.frame:RegisterEvent("BANKFRAME_CLOSED")	-- ... remove em again!


-----------------------------------------------------------------------
-- General-purpose utilities:

local t = {}
local function print(...) 
   if select("#",...)>1 then
      for k=1,select("#",...) do
         t[k]=tostring(select(k,...))
      end
      msg = table.concat(t, " ", 1, select("#",...))
   else
      msg = ...
   end
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
-- makeLinkPattern()
-- Take an itemnumber, name, itemstring, or full link, and create a Lua pattern that can be ran against full itemlinks

local function makeLinkPattern(lookingfor)
	if type(lookingfor)=="number" then
		-- "item:-12345" -> "item:%-12345[:|]"
		return "|Hitem:"..escapePatterns(lookingfor).."[:|]"	
	
	elseif type(lookingfor)=="string" then
	
		if strmatch(lookingfor, "^item:") or strmatch(lookingfor, "|H") then	
			-- (convert to itemstring) and ensure there's no level info in it
			local str = strmatch(lookingfor, "(item:.-:.-:.-:.-:.-:.-:.-:.-)[:|]")
			if not str then
				str = strmatch(lookingfor, "(item:[-0-9:]+)")
			end
			if not str then
				error(MAJOR..": '"..tostring(lookingfor).."' does not appear to be a valid itemstring / itemlink", 2)
			end
			return "|H" .. escapePatterns(str) .. "[:|]"
			
		else	-- put "|h[" and "]|h" around a name
			return "|h%["..escapePatterns(lookingfor).."%]|h"
		end
	end
	
	error("makeLinkPattern(): Expected number or string", 1)
end




-----------------------------------------------------------------------
-- updateBags()
-- Updates the contents of the bags[] arrays, and set bagsChangedProcessed = bagsChanged

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
	
	-- Keyring (if it exists)
	if select(2, GetContainerNumFreeSlots(KEYRING_CONTAINER)) then
		bags.BAGS[nBags+1]=KEYRING_CONTAINER; nBags=nBags+1
	end

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
	bagsChangedProcessed = bagsChanged
end

-----------------------------------------------------------------------
-- Internal slot locking utilities - unfortunately slots where we just dropped an item arent considered locked by the API until the server processes it and returns a bag update event, so we consider them locked for 2 seconds ourselves

lib.slotLocks = {}

local GetTime = GetTime

local function lockSlot(bag,slot)
	local slots = lib.slotLocks[bag] or {}
	if not lib.slotLocks[bag] then 
		lib.slotLocks[bag] = slots
	end
	slots[slot] = GetTime()
end

local function isLocked(bag,slot)
	local slots = lib.slotLocks[bag]
	if not slots then return false end
	return GetTime() - (slots[slot] or 0) < 2
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
	if bagsChanged>bagsChangedProcessed then
		updateBags()
	end
	
	local baglist=bags[which]
	if not baglist  then
		error([[Usage: LibBagUtils:Iterate(which [, itemid or itemlink])]], 2)
	end
	
	local bagidx,slot,curbagsize=0,0,0
	local bagsChangedAtStart = bagsChanged
	local function iterator()
		if bagsChanged>bagsChangedAtStart then
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
	
	if lookingfor==nil then
		return iterator
	else
		lookingfor = makeLinkPattern(lookingfor)
		return function()
			for bag,slot in iterator do
				if strmatch(GetContainerItemLink(bag,slot) or "", lookingfor) then
					return bag,slot,link
				end
			end
		end
	end
	
end


-----------------------------------------------------------------------
-- API :Find("where", "lookingfor", findLocked])

function lib:Find(where,lookingfor,findLocked)
	for bag,slot in lib:Iterate(where,lookingfor) do
		local _, itemCount, locked, _, _ = GetContainerItemInfo(bag,slot)
		if findLocked or not locked then
			return bag,slot
		end
	end
end


-----------------------------------------------------------------------
-- API :FindSmallestStack("where", "lookingfor"[, findLocked])
--
-- where       - string: "BAGS", "BANK", "BAGSBANK"
-- lookingfor  - itemLink, itemName, itemString or itemId(number)
-- findLocked   - OPTIONAL: if true, will also return locked slots
--
-- Returns:  bag,slot,size    or nil on failure

function lib:FindSmallestStack(where,lookingfor,findLocked)
	local smallest=9e9
	local smbag,smslot
	for bag,slot in lib:Iterate(where,lookingfor) do
		local _, itemCount, locked, _, _ = GetContainerItemInfo(bag,slot)
		if itemCount<smallest and (findLocked or not locked) then
			smbag=bag
			smslot=slot
			smallest=itemCount
		end
	end
	if smbag then
		return smbag,smslot,smallest
	end
end


-----------------------------------------------------------------------
-- API :PutItem("where"[, dontClearOnFail[, count]])
--
-- Put the item currently held by the cursor in the most suitable bag 
-- (considering specialty bags, already-existing stacks..)
--
-- where           - string: "BAGS", "BANK", "BAGSBANK"
-- count           - OPTIONAL: number: if given, PutItem() will attempt to stack the item on top of another suitable stack. This is not possible without knowing the count.
-- dontClearOnFail - OPTIONAL: boolean: If the put operation fails due to no room, do NOT clear the cursor. (Note that some other wow client errors WILL clear the cursor)
--
-- Returns:  bag,slot    or false for out-of-room
--           0,0 will be returned if the function is called without an item in the cursor

function lib:PutItem(where, count, dontClearOnFail)
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
				elseif isLocked(bag,slot) then
					-- nope!
				elseif ciCount+count<=itemStackCount and ciCount>bestsize then
					bestsize=ciCount
					bestbag=bag
					bestslot=slot
				end
			end
			if bestbag then	-- Place it!
				PickupContainerItem(bestbag,bestslot)
				if not CursorHasItem() then	-- success!
					
					lockSlot(bestbag,bestslot)
					local _, ciCount, ciLocked, _, _ = GetContainerItemInfo(bestbag,bestslot)
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
				if (not GetContainerItemInfo(bag,slot)) and (not isLocked(bag,slot)) then	-- empty!
					PickupContainerItem(bag,slot)
					if not CursorHasItem() then -- success!
						lockSlot(bag,slot)
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



-----------------------------------------------------------------------
-- API :LinkIsItem(fullLink, lookingfor)
-- 
-- See if "lookingfor" equals the full link given. "lookingfor" can be any kind of item identifier.
-- Level information is always ignored.

function lib:LinkIsItem(fullLink, lookingfor)
	return strmatch(fullLink, makeLinkPattern(lookingfor))
end
