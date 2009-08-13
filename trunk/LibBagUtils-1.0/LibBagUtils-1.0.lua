local MAJOR,MINOR = "LibBagUtils-1.0", tonumber(("$Revision$"):match("%d+"))
local lib = LibStub:NewLibrary(MAJOR,MINOR)

--
-- LibBagUtils
-- 
-- Several useful bag related APIs that you wish were built into the WoW API:
--   :PutItem()
--   :Iterate()
--   :LinkIsItem() - which amongst other things handles the 3.2 wotlk randomstat item madness (changing while in AH/mail/gbank)
--   :GetNumFreeSlots()
--   .. and more!
--
-- Pains have been taken to make sure to use as much FrameXML data and constants as possible,
-- which should let the library (and dependant addons) keep functioning if Blizzard desides
-- to add more bags, or reorder them.
--
-- Read the well-commented "API" function headers for each function below for usage and descriptions.
--



if not lib then return end -- no upgrade needed

local strmatch=string.match
local gsub=string.gsub
local floor=math.floor
local band=bit.band
local select,type,next,tonumber,tostring=select,type,next,tonumber,tostring
local GetTime=GetTime


-- These arrays contain all known bags, sorted with specialty bags first
local bags={
	["BAGS"] = {},
	["BANK"] = {},
	["BAGSBANK"] = {},
}

local bagsChanged = 1  -- incremented every time bags are changed
local bagsChangedProcessed = 0	-- copied in from bagsChanged every time we rescan the bags


lib.frame = lib.frame or CreateFrame("frame", string.gsub(MAJOR,"[^%w]", "_").."_Frame")
lib.frame:SetScript("OnEvent", function() bagsChanged=bagsChanged+1 end)

lib.frame:RegisterEvent("BAG_CLOSED")	-- happens when bags are shuffled around, also bank bags
lib.frame:RegisterEvent("PLAYERBANKSLOTS_CHANGED")  -- only really necessary when shopping new slots (so do we even need it here?)
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
	return ( gsub(str, "([-+.?*%%%[%]%(%)])", "%%%1") )
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
-- makeLinkComparator()
-- Take an itemnumber, name, itemstring, or full link, and return a (funcref,arg2,arg3) tuple that can be used to test against several itemlinks

local floor=math.floor
local function compareFuzzySuffix(link, pattern, uniq16)
	local uniq = strmatch(link, pattern)
	if not uniq then	-- first 8 params didn't match
		return false
	end
	return floor(tonumber(uniq)/65536)==uniq16
end

local function makeLinkComparator(lookingfor)
	if type(lookingfor)=="number" then
		-- "item:-12345" -> "item:%-12345[:|]"
		return strmatch, "|Hitem:"..escapePatterns(lookingfor).."[:|]",nil
	
	elseif type(lookingfor)=="string" then
	
		if strmatch(lookingfor, "^item:") or strmatch(lookingfor, "|H") then	
			-- (convert to itemstring) and ensure there's no level info in it (9th param)
			local str = strmatch(lookingfor, "(item:.-:.-:.-:.-:.-:.-:.-:.-)[:|]")
			if not str then
				str = strmatch(lookingfor, "(item:[-0-9:]+)")
			else
				-- hokay, we have an itemstring. now we need to check for wobbly suffix factors thanks to 3.2 madness
				-- see http://www.wowwiki.com/ItemString#3.2_wotlk_randomstat_items_changing_their_suffix_factors
				local firsteight,uniq = strmatch(str, "(item:.-:.-:.-:.-:.-:.-:%-.-:)([-0-9]+)")
				--                                                                      ^^ note leading "-"
				if uniq then                                                 
					-- suffix was negative, so suffix factors can wobble (really only with wotlk items, not BC ones, but meh)
					return compareFuzzySuffix, 
						"|H"..escapePatterns(firsteight).."([-0-9]+)[:|]", 
						floor(tonumber(uniq)/65536)
				else
					-- unwobbly item, we're done, fall through
				end
			end
			if not str then
				error(MAJOR..": MakeLinkComparator(): '"..tostring(lookingfor).."' does not appear to be a valid itemstring / itemlink", 3)
			end
			return strmatch, "|H" .. escapePatterns(str) .. "[:|]",nil
			
		else	-- put "|h[" and "]|h" around a name
			return strmatch, "|h%["..escapePatterns(lookingfor).."%]|h",nil
		end
	end
	
	error(MAJOR..": MakeLinkComparator(): Expected number or string", 3)
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

	-- Now add nonspecial bags
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
	
	-- Add bank special bags
	for i=1,NUM_BAG_SLOTS do
		local free,fam = GetContainerNumFreeSlots(i)
		if fam and fam==0 then
			bags.BAGS[nBags+1]=i; nBags=nBags+1
		end
	end
	
	-- Add bank normal bags
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
-- API :MakeLinkComparator("itemstring" or "itemLink" or "itemName" or itemId)
--
-- Returns a comparator function and two arguments, that can be used to
-- rapidly compare several itemlinks to a set search pattern.
--
-- This comparator will
--   1) Ignore the 9th "level" parameter introduced in 3.0
--   2) Correctly match items with changing stats in inventory vs AH/Mail/GBank
--      see http://www.wowwiki.com/ItemString#3.2_wotlk_randomstat_items_changing_their_suffix_factors--
--   3) Pick the smartest way to compare available
--
-- local comparator,arg1,arg2 = LBU:MakeLinkComparator(myItemString)
-- for _,itemLink in pairs(myItems) do
--   if comparator(itemLink, arg1,arg2) then
--     print(itemLink, "matches", myItemString)
--

function lib:MakeLinkComparator(lookingfor)
	return makeLinkComparator(lookingfor)
end



-----------------------------------------------------------------------
-- API :IterateBags("which", itemFamily)
--
-- which       - string: "BAGS", "BANK", "BAGSBANK"
-- itemFamily  - number: bitmasked itemFamily; will accept combinations
--                       0: will only iterate regular bags
--               nil: will iterate all bags (including keyring, and possibly feature special bags!)
--
-- Returns an iterator that can be used in a for loop, e.g.:
--   for bag in LBU:IterateBags("BANK") do  -- loop all bank bags (including bankframe)

function lib:IterateBags(which, itemFamily)
	if bagsChanged>bagsChangedProcessed then
		updateBags()
	end
	local baglist=bags[which]
	if not baglist then
		error([[Usage: LibBagUtils:IterateBags("which"[, itemFamily])]], 2)
	end
	local i=0
	if not itemFamily then
		return function()
			i=i+1
			return baglist[i]
		end
	elseif itemFamily==0 then
		return function()
			i=i+1
			while baglist[i] do
				local _,bagFamily = GetContainerNumFreeSlots(baglist[i])
				if bagFamily and bagFamily==0 then
					return baglist[i]
				end
				i=i+1
			end	
		end
	else
		return function()
			i=i+1
			while baglist[i] do
				local _,bagFamily = GetContainerNumFreeSlots(baglist[i])
				if bagFamily and band(itemFamily,bagFamily)~=0 then
					return baglist[i]
				end
				i=i+1
			end	
		end
	end
end


-----------------------------------------------------------------------
-- API: CountSlots(which, itemFamily)
--
-- which       - string: "BAGS", "BANK", "BAGSBANK"
-- itemFamily  - bitmasked itemFamily; see :IterateBags
--
-- Returns: numFreeSlots, numTotalSlots
--          BANK is considered to have 0 slots if bank window is not open

function lib:CountSlots(which, itemFamily)
	if bagsChanged>bagsChangedProcessed then
		updateBags()
	end
	local baglist=bags[which]
	if not baglist then
		error([[Usage: LibBagUtils:IterateBags("which"[, itemFamily])]], 2)
	end
	
	
	local free,tot=0,0

	if not itemFamily then
		for _,bag in ipairs(baglist) do
			free = free + GetContainerNumFreeSlots(bag)
			tot = tot + GetContainerNumSlots(bag)
		end
	elseif itemFamily==0 then
		for _,bag in ipairs(baglist) do
			local f,bagFamily = GetContainerNumFreeSlots(bag)
			if bagFamily and bagFamily==0 then
				free = free + f
				tot = tot + GetContainerNumSlots(bag)
			end
		end
	else
		for _,bag in ipairs(baglist) do
			local f,bagFamily = GetContainerNumFreeSlots(bag)
			if bagFamily and band(itemFamily,bagFamily)~=0 then
				free = free + f
				tot = tot + GetContainerNumSlots(bag)
			end
		end
	end
	return free,tot
end


-----------------------------------------------------------------------
-- API :IsBank(bag)
--
-- bag        - number: bag number
--
-- Returns true if the given bag is a bank bag

function lib:IsBank(bag)
	return bag==BANK_CONTAINER or
		(bag>=NUM_BAG_SLOTS+1 and bag<=NUM_BAG_SLOTS+NUM_BANKBAGSLOTS)
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

function lib:Iterate(which, lookingfor)
	if bagsChanged>bagsChangedProcessed then
		updateBags()
	end
	
	local baglist=bags[which]
	if not baglist  then
		error([[Usage: LibBagUtils:Iterate(which [, item])]], 2)
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
		local comparator,arg1,arg2 = makeLinkComparator(lookingfor)
		return function()
			for bag,slot in iterator do
				if comparator(GetContainerItemLink(bag,slot) or "", arg1,arg2) then
					return bag,slot,link
				end
			end
		end
	end
	
end


-----------------------------------------------------------------------
-- API :Find("where", "lookingfor", findLocked])
--
-- where       - string: "BAGS", "BANK", "BAGSBANK"
-- lookingfor  - itemLink, itemName, itemString or itemId(number)
-- findLocked   - OPTIONAL: if true, will also return locked slots
--
-- Returns:  bag,slot,link    or nil on failure

function lib:Find(where,lookingfor,findLocked)
	for bag,slot in lib:Iterate(where,lookingfor) do
		local _, itemCount, locked, _, _ = GetContainerItemInfo(bag,slot)
		if findLocked or not locked then
			return bag,slot,GetContainerItemLink(bag,slot)
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
					print("Odd. Couldn't place",count or "",itemLink,"in slot",bag,slot)
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
-- Level information is always ignored. Wobbly 3.2 randomstats are compensated for.

function lib:LinkIsItem(fullLink, lookingfor)
	local comparator,arg1,arg2 = makeLinkComparator(lookingfor)
	return comparator(fullLink, arg1,arg2)
end
