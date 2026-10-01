-- AllianceWhoScanner.lua
-- Optional WHO/level helper for AllianceRelaySender.
-- Keeps its own cache and only READS TaliaaSpy data when available.
-- Load this file BEFORE AllianceRelaySender.lua in the addon's .toc.

AllianceWhoScanner = AllianceWhoScanner or {}
local M = AllianceWhoScanner

AllianceWhoScannerDB = AllianceWhoScannerDB or {}
local DB = AllianceWhoScannerDB

local frame = CreateFrame("Frame")
local pendingZone = nil
local pendingQuery = nil
local scanIndex = 1
local scanButton = nil
local UpdateButtonText
local scanCooldownSeconds = 3
local scanReadyAt = 0
local countdownTicker = nil
local pendingUnknownKey = nil

local ZONES = {
    { label = "Stranglethorn Vale", query = 'z-"Stranglethorn Vale"', short = "STV" },
    { label = "Duskwood",           query = 'z-"Duskwood"', short = "DW" },
    { label = "Wetlands",           query = 'z-"Wetlands"', short = "Wet" },
    { label = "Redridge Mountains", query = 'z-"Redridge Mountains"', short = "RR" },
    { label = "Burning Steppes",    query = 'z-"Burning Steppes"', short = "BS" },
    { label = "Theramore Isle",     query = 'z-"Theramore Isle"', short = "Thera" },
}

local function BareName(name)
    if not name then return nil end
    return tostring(name):match("^([^%-]+)") or tostring(name)
end

local function NormalizeName(name)
    name = BareName(name)
    return name and string.lower(name) or nil
end

local function EnsureDB()
    DB.players = DB.players or {}
    DB.unknown = DB.unknown or {}
    DB.zoneUnknown = DB.zoneUnknown or {}
    DB.lastZone = DB.lastZone or nil
    DB.lastScan = DB.lastScan or 0
end

local function Print(msg)
    DEFAULT_CHAT_FRAME:AddMessage("|cff66ccff[Alliance WHO]|r " .. tostring(msg))
end

local function GetVoidMarkPlayerData(name)
    if not name then return nil end

    -- VoidMark intentionally still uses the legacy SpyPerCharDB SavedVariable
    -- for compatibility. Read it dynamically every lookup so VoidLink does not
    -- depend on which addon initialized first during the login sequence.
    local vmDB = _G and _G.SpyPerCharDB or SpyPerCharDB
    local players = vmDB and vmDB.PlayerData
    if type(players) ~= "table" then
        return nil
    end

    -- Exact full-name key first.
    local data = players[name]
    if data then return data end

    -- Try bare-name key.
    local bare = BareName(name)
    data = bare and players[bare]
    if data then return data end

    -- Last resort: compare bare names so cross-realm keys still resolve.
    local want = NormalizeName(name)
    if want then
        for key, value in pairs(players) do
            if NormalizeName(key) == want then
                return value
            end
        end
    end

    return nil
end

function M:ImportVoidMarkPlayers()
    EnsureDB()

    local vmDB = _G and _G.SpyPerCharDB or SpyPerCharDB
    local players = vmDB and vmDB.PlayerData
    if type(players) ~= "table" then return 0 end

    local imported = 0
    for name, info in pairs(players) do
        if type(info) == "table" and tonumber(info.level) and tonumber(info.level) > 0 then
            if self:RememberPlayer(
                name,
                info.level,
                info.class,
                info.zone,
                "VoidMark"
            ) then
                imported = imported + 1
            end
        end
    end
    return imported
end

function M:RememberPlayer(name, level, class, zone, source)
    EnsureDB()

    local key = NormalizeName(name)
    level = tonumber(level)
    if not key or not level or level <= 0 then
        return false
    end

    local old = DB.players[key] or {}
    DB.players[key] = {
        name = name or old.name,
        level = level,
        class = (class and class ~= "" and class ~= "?") and class or old.class,
        zone = (zone and zone ~= "") and zone or old.zone,
        source = source or old.source or "Cache",
        updated = time(),
    }

    DB.unknown[key] = nil
    return true
end

function M:MarkUnknown(name, zone)
    EnsureDB()
    local key = NormalizeName(name)
    if not key then return end
    if DB.players[key] then
        DB.unknown[key] = nil
        return
    end

    local entry = DB.unknown[key] or {}
    entry.name = BareName(name)
    entry.lastSeen = time()
    entry.zone = (zone and zone ~= "") and zone or entry.zone
    entry.attempts = entry.attempts or 0
    entry.nextTry = entry.nextTry or 0
    DB.unknown[key] = entry
    UpdateButtonText()
end

local function UnknownCountsByZone()
    EnsureDB()
    local counts = {}
    for key, entry in pairs(DB.unknown) do
        if not DB.players[key] and type(entry)=="table" and entry.zone and entry.zone~="" then
            counts[entry.zone]=(counts[entry.zone] or 0)+1
        end
    end
    return counts
end

local function BestUnknownZone()
    local counts=UnknownCountsByZone()
    local bestZone,bestCount=nil,0
    for zone,count in pairs(counts) do
        if count>bestCount then
            bestZone,bestCount=zone,count
        end
    end
    return bestZone,bestCount
end

local function NextUnknown()
    EnsureDB()
    local now = time()
    local bestKey, bestEntry

    for key, entry in pairs(DB.unknown) do
        if not DB.players[key] and type(entry) == "table" then
            local nextTry = tonumber(entry.nextTry) or 0
            if nextTry <= now then
                if not bestEntry or (tonumber(entry.lastSeen) or 0) < (tonumber(bestEntry.lastSeen) or 0) then
                    bestKey = key
                    bestEntry = entry
                end
            end
        end
    end

    return bestKey, bestEntry
end

function M:GetUnknownCount()
    EnsureDB()
    local n = 0
    for key in pairs(DB.unknown) do
        if not DB.players[key] then n = n + 1 end
    end
    return n
end


function M:GetPlayers()
    EnsureDB()
    return DB.players
end

function M:ImportPlayers(players)
    EnsureDB()
    if type(players) ~= "table" then return 0 end

    local imported = 0
    for _, info in pairs(players) do
        if type(info) == "table" and info.name and tonumber(info.level) then
            if self:RememberPlayer(
                info.fullName or info.name,
                info.level,
                info.class,
                info.zone,
                info.source or "Legacy"
            ) then
                imported = imported + 1
            end
        end
    end
    return imported
end

function M:GetPlayerInfo(name)
    EnsureDB()

    -- Prefer live VoidMark data when available, and immediately persist it
    -- into this cache so later relay messages keep the level/class.
    local spy = GetVoidMarkPlayerData(name)
    if spy and tonumber(spy.level) and tonumber(spy.level) > 0 then
        self:RememberPlayer(name, spy.level, spy.class, spy.zone, "VoidMark")
        local key = NormalizeName(name)
        return key and DB.players[key] or nil
    end

    -- Persistent WHO/learned cache fallback.
    local key = NormalizeName(name)
    local cached = key and DB.players[key]
    if cached and tonumber(cached.level) and tonumber(cached.level) > 0 then
        return cached
    end

    return nil
end

function M:GetLevel(name)
    local info = self:GetPlayerInfo(name)
    return info and info.level or nil
end

function M:GetLevelText(name)
    local level = self:GetLevel(name)
    return level and ("L:" .. tostring(level)) or "L:?"
end

local function GetNumWhoResultsCompat()
    if C_FriendList and C_FriendList.GetNumWhoResults then
        return C_FriendList.GetNumWhoResults() or 0
    end
    if GetNumWhoResults then
        return GetNumWhoResults() or 0
    end
    return 0
end

local function GetWhoInfoCompat(index)
    if C_FriendList and C_FriendList.GetWhoInfo then
        local info = C_FriendList.GetWhoInfo(index)
        if not info then return nil end
        return info.fullName or info.name, info.level, info.filename or info.classStr or info.class, info.area or info.zone
    end

    if GetWhoInfo then
        local name, guild, level, race, class, zone = GetWhoInfo(index)
        return name, level, class, zone
    end

    return nil
end

local function SendWhoCompat(query)
    if C_FriendList and C_FriendList.SendWho then
        C_FriendList.SendWho(query)
        return true
    end
    if SendWho then
        SendWho(query)
        return true
    end
    return false
end

UpdateButtonText = function()
    if not scanButton then return end

    local now = GetTime()
    if scanReadyAt and scanReadyAt > now then
        local remain = math.ceil(scanReadyAt - now)
        scanButton:SetText("Wait " .. remain .. "s")
        scanButton:SetEnabled(false)
        return
    end

    local bestZone,bestCount=BestUnknownZone()
    if bestZone and bestCount>0 then
        local short=bestZone
        for _,z in ipairs(ZONES) do
            if z.label==bestZone then short=z.short break end
        end
        scanButton:SetText("WHO " .. short .. " (" .. bestCount .. ")")
        scanButton:SetEnabled(true)
        return
    end

    local z = ZONES[scanIndex]
    scanButton:SetText("Scan " .. (z and z.short or "?"))
    scanButton:SetEnabled(true)
end

local function StartScanCooldown()
    scanReadyAt = GetTime() + scanCooldownSeconds

    if countdownTicker and countdownTicker.Cancel then
        countdownTicker:Cancel()
    end

    UpdateButtonText()

    if C_Timer and C_Timer.NewTicker then
        countdownTicker = C_Timer.NewTicker(0.25, function(ticker)
            if GetTime() >= scanReadyAt then
                if ticker and ticker.Cancel then ticker:Cancel() end
                countdownTicker = nil
                UpdateButtonText()
                return
            end
            UpdateButtonText()
        end)
    end
end

function M:GetCurrentZone()
    return ZONES[scanIndex]
end

function M:ResetQueue()
    scanIndex = 1
    pendingZone = nil
    pendingQuery = nil
    UpdateButtonText()
end

function M:ScanNext()
    EnsureDB()

    local now = GetTime()
    if scanReadyAt and scanReadyAt > now then
        UpdateButtonText()
        return false
    end

    -- Best-effort batching: one hardware click scans the zone containing the
    -- most unresolved chat speakers, potentially resolving many at once.
    local bestZone,bestCount=BestUnknownZone()
    if bestZone and bestCount>0 then
        pendingUnknownKey=nil
        pendingZone=bestZone
        pendingQuery='z-"' .. bestZone .. '"'

        if not SendWhoCompat(pendingQuery) then
            Print("WHO API unavailable.")
            return false
        end

        Print("Scanning " .. bestZone .. " for " .. bestCount .. " unresolved player" .. (bestCount==1 and "" or "s") .. "...")
        -- Keep only a short local debounce. Blizzard's server throttle remains
        -- authoritative; a dropped query simply leaves players unresolved.
        StartScanCooldown()
        return true
    end

    local z=ZONES[scanIndex]
    if not z then scanIndex=1; z=ZONES[scanIndex] end

    pendingUnknownKey=nil
    pendingZone=z.label
    pendingQuery=z.query
    if not SendWhoCompat(z.query) then
        Print("WHO API unavailable.")
        return false
    end
    Print("Scanning " .. z.label .. "...")
    scanIndex=scanIndex+1
    if scanIndex>#ZONES then scanIndex=1 end
    StartScanCooldown()
    return true
end

function M:ScanZoneByIndex(index)
    index = tonumber(index)
    local z = index and ZONES[index]
    if not z then return false end

    pendingZone = z.label
    pendingQuery = z.query

    if not SendWhoCompat(z.query) then
        Print("WHO API unavailable.")
        return false
    end

    Print("Scanning " .. z.label .. "...")
    return true
end

function M:GetZones()
    return ZONES
end

function M:AttachButton(parent, point, relativeTo, relativePoint, x, y)
    if scanButton then
        if parent then scanButton:SetParent(parent) end
        return scanButton
    end

    parent = parent or UIParent
    relativeTo = relativeTo or parent
    point = point or "TOPRIGHT"
    relativePoint = relativePoint or "TOPRIGHT"
    x = x or -8
    y = y or -8

    local b = CreateFrame("Button", "AllianceWhoScannerButton", parent, "UIPanelButtonTemplate")
    b:SetSize(92, 22)
    b:SetPoint(point, relativeTo, relativePoint, x, y)
    b:SetText("WHO")
    b:SetScript("OnClick", function()
        M:ScanNext()
    end)

    b:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        GameTooltip:SetText("Alliance WHO Scanner")
        local z = M:GetCurrentZone()
        GameTooltip:AddLine("Click to scan: " .. (z and z.label or "?"), 1, 1, 1)
        GameTooltip:AddLine("One click scans the highest-priority zone and caches all returned players. 3-second cooldown.", 0.8, 0.8, 0.8)
        GameTooltip:AddLine("Cycle: STV -> DW -> Wet -> RR -> BS -> Theramore.", 0.8, 0.8, 0.8)
        GameTooltip:AddLine("Level lookup: live VoidMark -> persistent cache -> ?", 0.8, 0.8, 0.8)
        GameTooltip:Show()
    end)
    b:SetScript("OnLeave", function()
        GameTooltip:Hide()
    end)

    scanButton = b
    UpdateButtonText()
    return b
end

local function SaveWhoResults()
    EnsureDB()

    local count = GetNumWhoResultsCompat()
    local saved = 0
    local resolvedPendingUnknown = false

    for i = 1, count do
        local name, level, class, zone = GetWhoInfoCompat(i)
        level = tonumber(level)

        if name and level and level > 0 then
            if M:RememberPlayer(name, level, class, zone or pendingZone, "WHO") then
                saved = saved + 1
                local key = NormalizeName(name)
                if pendingUnknownKey and key == pendingUnknownKey then
                    resolvedPendingUnknown = true
                end
            end
        end
    end

    DB.lastZone = pendingZone
    DB.lastScan = time()

    if pendingZone then
        Print(string.format("%s: cached %d player%s.", pendingZone, saved, saved == 1 and "" or "s"))
    end

    if pendingUnknownKey and not resolvedPendingUnknown then
        local entry = DB.unknown[pendingUnknownKey]
        if entry then
            -- Keep it unresolved, but its nextTry delay prevents repeat spam.
            entry.lastFailed = time()
        end
    end

    pendingUnknownKey = nil
    pendingZone = nil
    pendingQuery = nil
    UpdateButtonText()
end

frame:RegisterEvent("ADDON_LOADED")
frame:RegisterEvent("WHO_LIST_UPDATE")

frame:SetScript("OnEvent", function(self, event, ...)
    if event == "ADDON_LOADED" then
        local loadedAddon = ...
        EnsureDB()

        -- VoidMark can initialize after VoidLink on a fresh login. When it
        -- finishes loading, import its known player levels/classes immediately.
        -- This removes the old "/reload makes levels appear" load-order issue.
        if loadedAddon == "VoidMark" then
            M:ImportVoidMarkPlayers()
        end

        UpdateButtonText()
        return
    end

    if event == "WHO_LIST_UPDATE" then
        SaveWhoResults()
    end
end)

-- Optional slash commands for testing.
SLASH_ALLIANCEWHOSCAN1 = "/awho"
SlashCmdList["ALLIANCEWHOSCAN"] = function(msg)
    msg = tostring(msg or ""):match("^%s*(.-)%s*$")
    if msg == "" or msg == "next" then
        M:ScanNext()
    elseif msg == "reset" then
        M:ResetQueue()
        Print("Zone queue reset.")
    elseif msg == "status" then
        EnsureDB()
        local players = 0
        for _ in pairs(DB.players) do players = players + 1 end
        Print("Cached players: " .. players .. " | unresolved: " .. M:GetUnknownCount())
    else
        local n = tonumber(msg)
        if n and M:ScanZoneByIndex(n) then return end
        Print("Use /awho, /awho next, /awho reset, /awho status, or /awho <zone number>.")
    end
end
