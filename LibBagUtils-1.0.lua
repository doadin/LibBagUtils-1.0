local MAJOR,MINOR = "LibBagUtils-1.0", tonumber(("$Revision: 61 $"):match("%d+"))
local LibStub = _G.LibStub
local lib = LibStub:NewLibrary(MAJOR,MINOR)

--luacheck: no max line length

--
-- LibBagUtils
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
--local floor=math.floor
--local tconcat = table.concat
local band=bit.band
local pairs,select,type,next,tonumber,tostring=pairs,select,type,next,tonumber,tostring
local GetTime=_G.GetTime
local WOW_PROJECT_ID = _G.WOW_PROJECT_ID
local WOW_PROJECT_CLASSIC = _G.WOW_PROJECT_CLASSIC
local WOW_PROJECT_BURNING_CRUSADE_CLASSIC = _G.WOW_PROJECT_BURNING_CRUSADE_CLASSIC
local WOW_PROJECT_WRATH_CLASSIC = _G.WOW_PROJECT_WRATH_CLASSIC
local WOW_PROJECT_CATACLYSM_CLASSIC = _G.WOW_PROJECT_CATACLYSM_CLASSIC
local WOW_PROJECT_MAINLINE = _G.WOW_PROJECT_MAINLINE
local LE_EXPANSION_LEVEL_CURRENT = _G.LE_EXPANSION_LEVEL_CURRENT
local LE_EXPANSION_BURNING_CRUSADE =_G.LE_EXPANSION_BURNING_CRUSADE
local LE_EXPANSION_WRATH_OF_THE_LICH_KING = _G.LE_EXPANSION_WRATH_OF_THE_LICH_KING
local LE_EXPANSION_CATACLYSM = _G.LE_EXPANSION_CATACLYSM
local GetContainerNumSlots = _G.C_Container and _G.C_Container.GetContainerNumSlots or _G.GetContainerNumSlots
local GetContainerNumFreeSlots = _G.C_Container and _G.C_Container.GetContainerNumFreeSlots or _G.GetContainerNumFreeSlots
local GetContainerItemLink = _G.C_Container and _G.C_Container.GetContainerItemLink or _G.GetContainerItemLink
local GetContainerItemInfo = _G.C_Container and _G.C_Container.GetContainerItemInfo or _G.GetContainerItemInfo
local GetItemInfo = _G.GetItemInfo
local GetItemFamily = _G.GetItemFamily
local NUM_BANKBAGSLOTS = _G.NUM_BANKBAGSLOTS
local NUM_BAG_SLOTS = _G.NUM_TOTAL_EQUIPPED_BAG_SLOTS or _G.NUM_BAG_SLOTS
local PickupContainerItem = _G.PickupContainerItem
local CursorHasItem = _G.CursorHasItem
local GetCursorInfo = _G.GetCursorInfo
local ClearCursor = _G.ClearCursor
local geterrorhandler = _G.geterrorhandler

local BANK_CONTAINER = _G.BANK_CONTAINER

local function IsClassicWow() --luacheck: ignore 212
    return WOW_PROJECT_ID == WOW_PROJECT_CLASSIC
end

local function IsTBCWow() --luacheck: ignore 212
    return WOW_PROJECT_ID == WOW_PROJECT_BURNING_CRUSADE_CLASSIC and LE_EXPANSION_LEVEL_CURRENT == LE_EXPANSION_BURNING_CRUSADE
end

local function IsWrathWow() --luacheck: ignore 212
    return WOW_PROJECT_ID == WOW_PROJECT_WRATH_CLASSIC and LE_EXPANSION_LEVEL_CURRENT == LE_EXPANSION_WRATH_OF_THE_LICH_KING
end

local function IsCataWow() --luacheck: ignore 212
    return WOW_PROJECT_ID == WOW_PROJECT_CATACLYSM_CLASSIC and LE_EXPANSION_LEVEL_CURRENT == LE_EXPANSION_CATACLYSM
end

local function IsRetailWow() --luacheck: ignore 212
    return WOW_PROJECT_ID == WOW_PROJECT_MAINLINE
end


-- GLOBALS: error, geterrorhandler, PickupContainerItem
-- GLOBALS: CursorHasItem, ClearCursor, GetCursorInfo
-- GLOBALS: DEFAULT_CHAT_FRAME, SELECTED_CHAT_FRAME

local BACKPACK_CONTAINER = _G.BACKPACK_CONTAINER
local KEYRING_CONTAINER
if IsClassicWow() or IsTBCWow() or IsWrathWow() then
    KEYRING_CONTAINER = Enum.BagIndex.Keyring
end

local REAGENTBANK_CONTAINER
local REAGENT_CONTAINER
local IsReagentBankUnlocked
if IsRetailWow() then
    REAGENTBANK_CONTAINER = _G.REAGENTBANK_CONTAINER
    REAGENT_CONTAINER = IsRetailWow() and Enum.BagIndex.ReagentBag or math.huge
    IsReagentBankUnlocked = _G.IsReagentBankUnlocked
end


-- no longer used: lib.frame = lib.frame or CreateFrame("frame", string.gsub(MAJOR,"[^%w]", "_").."_Frame")
if lib.frame then
    lib.frame:Hide()
    lib.frame:UnregisterAllEvents()
end

-----------------------------------------------------------------------
-- General-purpose utilities:

--local t = {}
--local function print(...)
--   local msg
--   if select("#",...)>1 then
--      for k=1,select("#",...) do
--         t[k]=tostring(select(k,...))
--      end
--      msg = tconcat(t, " ", 1, select("#",...))
--   else
--      msg = ...
--   end
--    msg = gsub(msg, "\124", "\\124");
--    (SELECTED_CHAT_FRAME or DEFAULT_CHAT_FRAME):AddMessage(MAJOR..": "..msg)
--end

local function escapePatterns(str)
    return ( gsub(str, "([-+.?*%%%[%]%(%)])", "%%%1") )
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

                if uniq then
                    -- suffix was negative, so suffix factors can wobble (really only with wotlk items, not BC ones, but meh)
                    return compareFuzzySuffix,
                        "|H"..escapePatterns(firsteight).."([-0-9]+)[:|]",
                        floor(tonumber(uniq)/65536)
                --else
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
-- Internal slot locking utilities - unfortunately slots where we just dropped an item arent considered locked by the API until the server processes it and returns a bag update event, so we consider them locked for 2 seconds ourselves

lib.slotLocks = {}

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
-- Own family/freeslots handling
-- Pre 4.2: This was to handle the goddamn keyring that doesn't behave like anything else,
-- but i'm keeping these functions in in case blizzard adds something new that behaves badly (tabard rack anyone?)

local function GetContainerFamily(bag)
    if IsClassicWow() or IsTBCWow() or IsWrathWow() then
        if bag==KEYRING_CONTAINER then
            return 256
        end
    end
    local _,fam = GetContainerNumFreeSlots(bag)
    return fam
end

function lib:GetContainerFamily(bag) --luacheck: ignore 212
    return GetContainerFamily(bag)
end


local function myGetContainerNumFreeSlots(bag)
if IsClassicWow() or IsTBCWow() or IsWrathWow() then
    if bag==KEYRING_CONTAINER then
        local free=0
        for slot=1,GetContainerNumSlots(bag) do
            if not GetContainerItemLink(bag,slot) then
                free=free+1
            end
        end
        return free,256
    end
end
    return GetContainerNumFreeSlots(bag)
end

function lib:GetContainerNumFreeSlots(bag) --luacheck: ignore 212
    return myGetContainerNumFreeSlots(bag)
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

function lib:MakeLinkComparator(lookingfor) --luacheck: ignore 212
    return makeLinkComparator(lookingfor)
end



-----------------------------------------------------------------------
-- API :IterateBags("which", itemFamily)
--
-- which       - string: "BAGS", "BANK", "BAGSBANK", "REAGENTBANK"(on retail)
-- itemFamily  - number: bitmasked itemFamily; will accept combinations
--                       0: will only iterate regular bags
--               nil: will iterate all bags (including possible future special bags!)
--
-- Returns an iterator that can be used in a for loop, e.g.:
--   for bag in LBU:IterateBags("BAGS") do  -- loop all carried bags (including backpack & possible future special bags)

local bags = {}
if IsClassicWow() or IsTBCWow() or IsWrathWow() or IsCataWow() then
bags = {
    BAGS = {},
    BANK = {},
    BAGSBANK = {},
}
end
if IsRetailWow() then
bags = {
    BAGS = {},
    BANK = {},
    BAGSBANK = {},
    REAGENTBANK = {},
}
end

-- Carried bags
for i=1,NUM_BAG_SLOTS do
    bags.BAGS[i]=i
end
bags.BAGS[BACKPACK_CONTAINER]=BACKPACK_CONTAINER
if IsClassicWow() or IsTBCWow() or IsWrathWow() then
    bags.BAGS[KEYRING_CONTAINER]=KEYRING_CONTAINER
end

-- Bank bags
for i=NUM_BAG_SLOTS+1,NUM_BAG_SLOTS+NUM_BANKBAGSLOTS do
    bags.BANK[i]=i
end
bags.BANK[BANK_CONTAINER]=BANK_CONTAINER

-- Both
for k,v in pairs(bags.BAGS) do
    bags.BAGSBANK[k]=v
end
for k,v in pairs(bags.BANK) do
    bags.BAGSBANK[k]=v
end

if IsRetailWow() then
-- Reagent Bank
bags.REAGENTBANK[REAGENTBANK_CONTAINER] = REAGENTBANK_CONTAINER
end

local function iterbags(tab, cur)
    cur = next(tab, cur)
    while cur do
        if GetContainerFamily(cur) then
            return cur
        end
        cur = next(tab, cur)
    end
end

local function iterbagsfam0(tab, cur)
    cur = next(tab, cur)
    while cur do
        local _,fam = GetContainerNumFreeSlots(cur)
        if fam==0 then
            return cur
        end
        cur = next(tab, cur)
    end
end

function lib:IterateBags(which, itemFamily) --luacheck: ignore 212

    local baglist=bags[which]
    if not baglist then
        error([[Usage: LibBagUtils:IterateBags("which"[, itemFamily])]], 2)
    end

    if IsRetailWow() and which == "REAGENTBANK" and not IsReagentBankUnlocked() then return function() end, baglist end

    if not itemFamily then
        return iterbags, baglist
    elseif itemFamily==0 then
        return iterbagsfam0, baglist
    else
        return function(tab, cur)
            cur = next(tab, cur)
            while cur do
                local fam = GetContainerFamily(cur)
                if fam and band(itemFamily,fam)~=0 then
                    return cur
                end
                cur = next(tab, cur)
            end
        end, baglist
    end
end


-----------------------------------------------------------------------
-- API: CountSlots(which, itemFamily)
--
-- which       - string: "BAGS", "BANK", "BAGSBANK", "REAGENTBANK"(on retail)
-- itemFamily  - bitmasked itemFamily; see :IterateBags
--
-- Returns: numFreeSlots, numTotalSlots
--          BANK is considered to have 0 slots if bank window is not open

function lib:CountSlots(which, itemFamily) --luacheck: ignore 212
    local baglist=bags[which]
    if not baglist then
        error([[Usage: LibBagUtils:IterateBags("which"[, itemFamily])]], 2)
    end

    local free,tot=0,0
    if IsRetailWow() and which == "REAGENTBANK" and not IsReagentBankUnlocked() then return free,tot end

    if not itemFamily then
        for bag in pairs(baglist) do
            free = free + myGetContainerNumFreeSlots(bag)
            tot = tot + GetContainerNumSlots(bag)
        end
    elseif itemFamily==0 then
        for bag in pairs(baglist) do
            local f,bagFamily = GetContainerNumFreeSlots(bag)
            if bagFamily==0 then
                free = free + f
                tot = tot + GetContainerNumSlots(bag)
            end
        end
    else
        for bag in pairs(baglist) do
            local f,bagFamily = myGetContainerNumFreeSlots(bag)
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
-- bag        - number: bag number
-- Returns true if the given bag is a bank bag

function lib:IsBank(bag, incReagentBank) --luacheck: ignore 212
    return bag==BANK_CONTAINER or
        (bag>=NUM_BAG_SLOTS+1 and bag<=NUM_BAG_SLOTS+NUM_BANKBAGSLOTS) or (incReagentBank and lib:IsReagentBank(bag))
end

-----------------------------------------------------------------------
-- API :IsReagentBank(bag)
-- bag        - number: bag number
-- Returns true if the given bag is the reagent bank "bag"

function lib:IsReagentBank(bag) --luacheck: ignore 212
    if IsRetailWow() then
        return IsReagentBankUnlocked() and (bag==REAGENTBANK_CONTAINER and true or nil) or nil
    end
end

-----------------------------------------------------------------------
-- API :Iterate("which"[, "lookingfor"])
-- which       - string: "BAGS", "BANK", "BAGSBANK", "REAGENTBANK"
-- lookingfor  - OPTIONAL: itemLink, itemName, itemString or itemId(number)
--
-- Returns an iterator that can be used in a for loop, e.g.:
--   for bag,slot,link in LBU:Iterate("BAGS") do   -- loop all slots in carried bags (including backpack & keyring)
--   for bag,slot,link in LBU:Iterate("BAGSBANK", 29434) do  -- find all badges of justice

function lib:Iterate(which, lookingfor) --luacheck: ignore 212
    if IsRetailWow() and which == "REAGENTBANK" and not IsReagentBankUnlocked() then return function() end end

    local baglist=bags[which]
    if not baglist then
        error([[Usage: LibBagUtils:Iterate(which [, item])]], 2)
    end

    local bag,slot,curbagsize=nil,0,0
    local function iterator()
        while slot>=curbagsize do
            bag = iterbags(baglist, bag)
            if not bag then return nil end
            curbagsize=GetContainerNumSlots(bag) or 0
            slot=0
        end

        slot=slot+1
        return bag,slot,GetContainerItemLink(bag,slot)
    end

    if lookingfor==nil then
        return iterator
    else
        local comparator,arg1,arg2 = makeLinkComparator(lookingfor)
        return function()
            for bag,slot,link in iterator do --luacheck: ignore 431
                if link and comparator(link, arg1,arg2) then
                    return bag,slot,link
                end
            end
        end
    end
end


-----------------------------------------------------------------------
-- API :Find("where", "lookingfor", findLocked])
--
-- where       - string: "BAGS", "BANK", "BAGSBANK", "REAGENTBANK"
-- lookingfor  - itemLink, itemName, itemString or itemId(number)
-- findLocked   - OPTIONAL: if true, will also return locked slots
--
-- Returns:  bag,slot,link    or nil on failure

function lib:Find(where,lookingfor,findLocked) --luacheck: ignore 212
    if IsRetailWow() and where == "REAGENTBANK" and not IsReagentBankUnlocked() then return nil end

    for bag,slot,link in lib:Iterate(where,lookingfor) do
        local locked
        if IsRetailWow() then
            local itemInfo = GetContainerItemInfo(bag, slot)
            locked = itemInfo and itemInfo.isLocked
        else
            locked = select(3, GetContainerItemInfo(bag, slot))
        end
        if findLocked or not locked then
            return bag,slot,link
        end
    end
end


-----------------------------------------------------------------------
-- API :FindSmallestStack("where", "lookingfor"[, findLocked])
--
-- where       - string: "BAGS", "BANK", "BAGSBANK", REAGENTBANK
-- lookingfor  - itemLink, itemName, itemString or itemId(number)
-- findLocked   - OPTIONAL: if true, will also return locked slots
--
-- Returns:  bag,slot,size    or nil on failure

function lib:FindSmallestStack(where,lookingfor,findLocked) --luacheck: ignore 212
    if IsRetailWow() and where == "REAGENTBANK" and not IsReagentBankUnlocked() then return nil end

    local smallest=9e9
    local smbag,smslot
    for bag,slot in lib:Iterate(where,lookingfor) do
        local locked
        local itemCount
        if IsRetailWow() then
            local itemInfo = GetContainerItemInfo(bag, slot)
            locked = itemInfo and itemInfo.isLocked
            itemCount = itemInfo and itemInfo.stackCount
        else
            locked = select(3, GetContainerItemInfo(bag, slot))
            itemCount = select(2, GetContainerItemInfo(bag, slot))
        end
        if itemCount and itemCount<smallest and (findLocked or not locked) then
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
-- where           - string: "BAGS", "BANK", "BAGSBANK", "REAGENTBANK"
-- count           - OPTIONAL: number: if given, PutItem() will attempt to stack the item on top of another suitable stack. This is not possible without knowing the count.
-- dontClearOnFail - OPTIONAL: boolean: If the put operation fails due to no room, do NOT clear the cursor. (Note that some other wow client errors WILL clear the cursor)
--
-- Returns:  bag,slot    or false for out-of-room
--           0,0 will be returned if the function is called without an item in the cursor
--           nil when which is REAGENTBANK and the ReagentBank has not been unlocked

local function putinbag(destbag)
    for slot=1,GetContainerNumSlots(destbag) do
        if (not GetContainerItemInfo(destbag,slot)) and (not isLocked(destbag,slot)) then	-- empty!
            PickupContainerItem(destbag,slot)
            if not CursorHasItem() then -- success!
                lockSlot(destbag,slot)
                return slot
            end
            -- If we get here, something is probably severely broken. But we keep looping hoping for the best.
        end
    end
end

function lib:PutItem(where, count, dontClearOnFail) --luacheck: ignore 212
    if IsRetailWow() and where == "REAGENTBANK" and not IsReagentBankUnlocked() then return nil end

    local cursorType,itemId,itemLink = GetCursorInfo()
    if cursorType~="item" then
        geterrorhandler()(MAJOR..": PutItem(): There was no item in the cursor.")
        return 0,0	-- we consider nothing-at-all successfully disposed of (0,0 contains nil)
    end

    local baglist=bags[where]
    if not baglist then
        error("Usage: LibBagUtils:PutItem(where[, count[, dontClearOnFail]])", 2)
    end

    -- FIRST: if we have a known count, and the item is stackable, we try putting it on top of something else (look for the BIGGEST stack to put it on top of for max packing!)
    if count and count>=1 then
        local _, _, _, _, _, _, _, itemStackCount = GetItemInfo(itemLink)
        if itemStackCount>1 and count<itemStackCount then
            local bestsize,bestbag,bestslot=0,0,0
            for bag,slot in lib:Iterate(where, itemId) do -- Only look for itemId, not the full string; we assume everything of the same itemId is stackable. Looking at the full itemstring is futile since everything has unique IDs these days.
                local _, ciCount, ciLocked
                if Baggins:IsRetailWow() then
                    local itemInfo = GetContainerItemInfo(bag, slot)
                    ciLocked = itemInfo and itemInfo.isLocked
                    ciCount = itemInfo and itemInfo.stackCount
                else
                    ciLocked = select(3, GetContainerItemInfo(bag, slot))
                    ciCount = select(2, GetContainerItemInfo(bag, slot))
                end
                if ciCount+count<=itemStackCount and ciCount>bestsize and not ciLocked and not isLocked(bag,slot)then
                    bestsize=ciCount
                    bestbag=bag
                    bestslot=slot
                end
            end
            if bestbag then	-- Place it!
                PickupContainerItem(bestbag,bestslot)
                if not CursorHasItem() then	-- success!
                    lockSlot(bestbag,bestslot)
                    local _, _, _, _, _ = GetContainerItemInfo(bestbag,bestslot)
                    return bestbag,bestslot
                end
                -- if we got here, the item couldn't be placed on top of the other for some reason, possibly because our assumption about equal itemids being wrong
                -- either way, we fall down and continue looking for somewhere to put it
            end
            -- Fall down and look for empty slots instead
        end
    end

    -- Put the item in the first empty slot that it CAN be put in!
    local itemFam = GetItemFamily(itemLink)
    if itemFam~=0 and select(9,GetItemInfo(itemLink))=="INVTYPE_BAG" then
        itemFam = 0	-- Ouch, it was a bag. Bags are always family 0 for purposes of trying to PUT them somewhere.
    end

    -- If this is a specialty item, we try specialty bags first
    if itemFam~=0 then
        for bag in iterbags, baglist do
            local _, bagFam = myGetContainerNumFreeSlots(bag)
            if bagFam~=0 and band(itemFam,bagFam)~=0 then
                local slot = putinbag(bag)
                if slot then
                    return bag,slot
                end
            end
        end
    end

    -- If we couldn't put it in a special bag, try normal bags
    for bag in iterbagsfam0, baglist do
        if GetContainerNumFreeSlots(bag)>0 then
            local slot = putinbag(bag)
            if slot then
                return bag,slot
            end
        end
    end

    -- Set sail on the failboat!
    if not dontClearOnFail then
        ClearCursor()
    end
    return false	-- no room for it!
end



-----------------------------------------------------------------------
-- API :LinkIsItem(fullLink, lookingfor)
-- See if "lookingfor" equals the full link given. "lookingfor" can be any kind of item identifier.
-- Level information is always ignored. Wobbly 3.2 randomstats are compensated for.

function lib:LinkIsItem(fullLink, lookingfor) --luacheck: ignore 212
    local comparator,arg1,arg2 = makeLinkComparator(lookingfor)
    return comparator(fullLink, arg1,arg2)
end
