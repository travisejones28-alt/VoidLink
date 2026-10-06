-- Repush: faction-based auto-connect transport confirmed

local ADDON_NAME = ...
local PREFIX = "AHREL1"

AllianceRelaySenderDB = AllianceRelaySenderDB or {}
local DB = AllianceRelaySenderDB
local f = CreateFrame("Frame")

local queue = {}
local sending = false
local recent = {}
local pairing = false
local pairNonce = nil
local pairCandidates = {}
local pairCandidateIndex = 1
local pairFallbackNextID = 1
local pairFallbackMaxID = 100
local pairUsingFallback = false
local pairButton
local idBox
local heartbeatTicker = nil
local RestartHeartbeat
local MAX_RECEIVERS = 2
local receiverMonitorTicker = nil
local lastAutoPairAt = 0
local pairAcks = {}
local pendingRemoteWhoZone = nil -- legacy internal scanner fallback
local pendingRemoteWhoRequesterID = nil
local pendingRemoteWhoKind = nil
local pendingRemoteWhoValue = nil
local pendingRemoteWhoRaw = nil
local pendingRemoteWhoFilter = nil
local pendingRemoteWhoSourceName = nil
local pendingRemoteWhoSourceLabel = nil
local pendingRemoteWhoToken = 0
local pendingRemoteWhoClicked = false
local remoteWhoRequestQueue = {}
local ActivateNextRemoteWho
local FinishActiveRemoteWho
local RemoteWhoQueueCount
local remoteWhoPrompt = nil
local remoteWhoPromptText = nil
local remoteWhoPromptButton = nil
local remoteWhoPromptIgnoreButton = nil
local remoteWhoPromptStatus = nil
local whoCache = {}
local pendingWho = {}
local RemovePendingWho
local lastWhoScan = 0
local scanBtn
local friendSnapshot = nil
local friendStatusReady = false
local friendStatusSequence = 0

local defaults = {
    enabled = true,
    relayGeneral = true,
    relayLocalDefense = true,
    relayParty = true,
    relayGuild = true,
    relayWhispers = true,
    relayFriendStatus = true, -- receiver's optional private-window alert decides visibility
    receiverGameAccountID = nil, -- legacy/primary mirror
    receivers = {},

    includeTimestamp = true,
    includeZone = true,
    abbreviateZone = true,
    includeLevel = true,
    includeAuthor = true,

    whoEnabled = false,
    whoInterval = 300,
    whoCurrentZoneOnly = true,

    keywordFilterEnabled = false,
    keywordFilter = "",
    ignoreOwnMessages = true,
    duplicateWindow = 4,
    maxQueue = 100,
    debug = false,
    heartbeatEnabled = true,
    heartbeatInterval = 5,

    whoDatabase = {},
    whoDatabaseMaxAgeDays = 30,

    launcherPoint = "CENTER",
    launcherX = -300,
    launcherY = 0,
}

local ZONE_ABBR = {
    ["Redridge Mountains"]="RR", ["Wetlands"]="Wet", ["Duskwood"]="Dusk",
    ["Elwynn Forest"]="Elwynn", ["Westfall"]="WF", ["Loch Modan"]="Loch",
    ["Dun Morogh"]="DM", ["Darkshore"]="DS", ["Ashenvale"]="Ash",
    ["Stonetalon Mountains"]="STM", ["Desolace"]="Deso", ["Feralas"]="Fer",
    ["Tanaris"]="Tan", ["Un'Goro Crater"]="UG", ["Silithus"]="Sil",
    ["Stranglethorn Vale"]="STV", ["Swamp of Sorrows"]="SoS",
    ["Blasted Lands"]="BL", ["Burning Steppes"]="BS", ["Searing Gorge"]="SG",
    ["Badlands"]="Bad", ["Hillsbrad Foothills"]="Hills",
    ["Alterac Mountains"]="Alt", ["Arathi Highlands"]="Arathi",
    ["The Hinterlands"]="Hinter", ["Western Plaguelands"]="WPL",
    ["Eastern Plaguelands"]="EPL", ["Tirisfal Glades"]="Tiris",
    ["Silverpine Forest"]="SF", ["Mulgore"]="Mul", ["The Barrens"]="Barrens",
    ["Durotar"]="Duro", ["Thousand Needles"]="1K", ["Dustwallow Marsh"]="Dust",
    ["Felwood"]="Fel", ["Winterspring"]="WS", ["Azshara"]="Az",
    ["Moonglade"]="Moon", ["Deadwind Pass"]="DWP", ["Ironforge"]="IF",
    ["Stormwind City"]="SW", ["Stormwind"]="SW", ["Darnassus"]="Darn",
    ["Orgrimmar"]="Org", ["Thunder Bluff"]="TB", ["Undercity"]="UC",
}

local function Print(msg)
    DEFAULT_CHAT_FRAME:AddMessage("|cff33ff99VoidLink Sender|r: " .. tostring(msg))
end

local function ApplyDefaults()
whoCache = DB.whoDatabase or {}
DB.whoDatabase = whoCache
    AllianceRelaySenderDB = AllianceRelaySenderDB or {}
    DB = AllianceRelaySenderDB
    for k,v in pairs(defaults) do
        if DB[k] == nil then DB[k] = v end
    end

    -- VoidLink unified-mode migration: the Sender role is intended to capture
    -- and relay the complete player-chat feed requested for intelligence history.
    if (tonumber(DB.voidLinkSettingsVersion) or 0) < 2 then
        DB.relayGeneral = true
        DB.relayLocalDefense = true
        DB.relayParty = true
        DB.relayWhispers = true
        DB.voidLinkSettingsVersion = 2
    end
end

-- GUI widgets such as UIDropDownMenu may run their initialization function
-- immediately while the Lua file is loading. Initialize SavedVariables before
-- constructing any widgets so DB is never nil during those callbacks.
ApplyDefaults()

local function SplitPayload(payload)
    local out={}
    local start=1
    while true do
        local p=payload:find("\031",start,true)
        if not p then
            out[#out+1]=payload:sub(start)
            break
        end
        out[#out+1]=payload:sub(start,p-1)
        start=p+1
    end
    return out
end

local REMOTE_ZONE_ALIASES = {
    ["rr"]="Redridge Mountains",
    ["red"]="Redridge Mountains",
    ["redr"]="Redridge Mountains",
    ["redridge"]="Redridge Mountains",
    ["redridge mountains"]="Redridge Mountains",
    ["dw"]="Duskwood",
    ["dusk"]="Duskwood",
    ["duskwood"]="Duskwood",
    ["wet"]="Wetlands",
    ["wl"]="Wetlands",
    ["wetl"]="Wetlands",
    ["wetlands"]="Wetlands",
    ["stv"]="Stranglethorn Vale",
    ["stranglethorn"]="Stranglethorn Vale",
    ["stranglethorn vale"]="Stranglethorn Vale",
    ["wpl"]="Western Plaguelands",
    ["western plaguelands"]="Western Plaguelands",
    ["epl"]="Eastern Plaguelands",
    ["eastern plaguelands"]="Eastern Plaguelands",
    ["bs"]="Burning Steppes",
    ["burning steppes"]="Burning Steppes",
    ["sg"]="Searing Gorge",
    ["searing gorge"]="Searing Gorge",
    ["hills"]="Hillsbrad Foothills",
    ["hillsbrad"]="Hillsbrad Foothills",
    ["arathi"]="Arathi Highlands",
    ["hinter"]="The Hinterlands",
    ["hinterlands"]="The Hinterlands",
    ["bad"]="Badlands",
    ["badlands"]="Badlands",
    ["bl"]="Blasted Lands",
    ["blasted lands"]="Blasted Lands",
    ["sos"]="Swamp of Sorrows",
    ["swamp of sorrows"]="Swamp of Sorrows",
    ["wf"]="Westfall",
    ["westfall"]="Westfall",
    ["loch"]="Loch Modan",
    ["elwynn"]="Elwynn Forest",
    ["dm"]="Dun Morogh",
    ["dun morogh"]="Dun Morogh",
    ["ds"]="Darkshore",
    ["darkshore"]="Darkshore",
    ["ash"]="Ashenvale",
    ["ashenvale"]="Ashenvale",
    ["stm"]="Stonetalon Mountains",
    ["stonetalon"]="Stonetalon Mountains",
    ["deso"]="Desolace",
    ["desolace"]="Desolace",
    ["fer"]="Feralas",
    ["feralas"]="Feralas",
    ["tan"]="Tanaris",
    ["tanaris"]="Tanaris",
    ["ug"]="Un'Goro Crater",
    ["ungoro"]="Un'Goro Crater",
    ["sil"]="Silithus",
    ["silithus"]="Silithus",
    ["fel"]="Felwood",
    ["felwood"]="Felwood",
    ["ws"]="Winterspring",
    ["winterspring"]="Winterspring",
    ["az"]="Azshara",
    ["azshara"]="Azshara",
    ["dust"]="Dustwallow Marsh",
    ["dustwallow"]="Dustwallow Marsh",
    ["1k"]="Thousand Needles",
    ["thousand needles"]="Thousand Needles",
    ["hf"]="Hillsbrad Foothills",
    ["alt"]="Alterac Mountains",
    ["alterac"]="Alterac Mountains",
    ["alterac mountains"]="Alterac Mountains",
    ["ah"]="Arathi Highlands",
    ["tiris"]="Tirisfal Glades",
    ["tirisfal"]="Tirisfal Glades",
    ["tirisfal glades"]="Tirisfal Glades",
    ["sf"]="Silverpine Forest",
    ["silverpine"]="Silverpine Forest",
    ["silverpine forest"]="Silverpine Forest",
    ["mul"]="Mulgore",
    ["mulgore"]="Mulgore",
    ["barrens"]="The Barrens",
    ["the barrens"]="The Barrens",
    ["duro"]="Durotar",
    ["durotar"]="Durotar",
    ["thera"]="Theramore Isle",
    ["theramore"]="Theramore Isle",
    ["theramore isle"]="Theramore Isle",
    ["moon"]="Moonglade",
    ["moonglade"]="Moonglade",
    ["dwp"]="Deadwind Pass",
    ["deadwind"]="Deadwind Pass",
    ["deadwind pass"]="Deadwind Pass",
    ["if"]="Ironforge",
    ["ironforge"]="Ironforge",
    ["sw"]="Stormwind City",
    ["stormwind"]="Stormwind City",
    ["stormwind city"]="Stormwind City",
    ["darn"]="Darnassus",
    ["darnassus"]="Darnassus",
    ["org"]="Orgrimmar",
    ["orgrimmar"]="Orgrimmar",
    ["tb"]="Thunder Bluff",
    ["thunder bluff"]="Thunder Bluff",
    ["uc"]="Undercity",
    ["undercity"]="Undercity",
}

local function NormalizeRemoteZone(query)
    local q=tostring(query or ""):lower()
    q=q:match("^%s*(.-)%s*$") or q
    return REMOTE_ZONE_ALIASES[q] or tostring(query or "")
end

-- Resolve loose receiver input. Exact/common aliases win first; otherwise a
-- unique zone-name/alias prefix is treated as a zone. Anything ambiguous or
-- unknown falls back to a player-name WHO lookup.
local function ParseRemoteWhoRequest(query)
    local raw=tostring(query or ""):match("^%s*(.-)%s*$") or ""
    if raw=="" then return "",nil end

    local tokens={}
    for token in raw:gmatch("%S+") do
        tokens[#tokens+1]=token
    end

    local kept={}
    local filter=nil
    local i=1
    while i<=#tokens do
        local token=tostring(tokens[i] or "")
        local lower=token:lower()
        local nextLower=tostring(tokens[i+1] or ""):lower()

        if lower=="60" or lower=="60s" or lower=="lvl60"
            or lower=="level60" or lower=="level-60"
        then
            filter="60"
        elseif (lower=="level" or lower=="lvl") and nextLower=="60" then
            filter="60"
            i=i+1
        else
            kept[#kept+1]=token
        end
        i=i+1
    end

    return table.concat(kept," "):match("^%s*(.-)%s*$") or "",filter
end

local function ResolveRemoteWhoTarget(query)
    local raw=tostring(query or ""):match("^%s*(.-)%s*$") or ""
    local q=raw:lower()
    if q=="" then return nil,nil end

    local exact=REMOTE_ZONE_ALIASES[q]
    if exact then return "zone",exact end

    if #q >= 3 then
        local matches={}
        for alias,zone in pairs(REMOTE_ZONE_ALIASES) do
            local zl=tostring(zone):lower()
            if alias:sub(1,#q)==q or zl:sub(1,#q)==q then
                matches[zone]=true
            end
        end
        local found,count=nil,0
        for zone in pairs(matches) do
            found=zone
            count=count+1
        end
        if count==1 then return "zone",found end
    end

    return "player",raw
end

local function Clean(s)
    s = tostring(s or "")
    s = s:gsub("|", "/"):gsub("\r", " "):gsub("\n", " ")
    return s
end

local function StripRealm(name)
    name = tostring(name or "")
    return name:match("^([^%-]+)") or name
end

local function GetZone()
    return GetRealZoneText and GetRealZoneText() or GetZoneText() or "Unknown"
end

local function AbbrevZone(zone)
    return ZONE_ABBR[zone] or zone
end

local function IsDuplicate(key)
    local now = GetTime()
    local old = recent[key]
    recent[key] = now
    for k,t in pairs(recent) do
        if now - t > 15 then recent[k] = nil end
    end
    return old and (now-old) < (DB.duplicateWindow or 4)
end

local function MatchesKeyword(text)
    if not DB.keywordFilterEnabled then return true end
    local filter = tostring(DB.keywordFilter or ""):lower()
    if filter == "" then return true end

    local lower = tostring(text or ""):lower()
    for token in filter:gmatch("[^,]+") do
        token = token:match("^%s*(.-)%s*$")
        if token ~= "" and lower:find(token, 1, true) then
            return true
        end
    end
    return false
end

local function SendBN(gameAccountID, prefix, payload)
    local id = tonumber(gameAccountID)
    if not id then return false, "Receiver ID not set" end

    -- Prefer the legacy API used by the original working build.
    if BNSendGameData then
        local ok, result = pcall(BNSendGameData, id, prefix, payload)
        return ok, result
    elseif C_BattleNet and C_BattleNet.SendGameData then
        local ok, result = pcall(C_BattleNet.SendGameData, id, prefix, payload)
        return ok, result
    end

    return false, "Battle.net API unavailable"
end

local function EnsureReceiverDB()
    DB.receivers = DB.receivers or {}

    -- One-time compatibility with the old single-receiver setting. Keep it as
    -- a temporary slot; auto pairing will replace/update it as soon as a real
    -- receiver answers.
    if #DB.receivers == 0 and tonumber(DB.receiverGameAccountID) then
        DB.receivers[1] = {
            id = tonumber(DB.receiverGameAccountID),
            name = "Legacy",
            lastAck = 0,
            lastSeen = time(),
        }
    end
    return DB.receivers
end

local function ReceiverNameKey(name)
    name = tostring(name or "")
    if name == "" or name == "Legacy" or name == "Manual" then return nil end
    return name:lower()
end

local function SyncLegacyPrimary()
    local r = EnsureReceiverDB()
    DB.receiverGameAccountID = r[1] and tonumber(r[1].id) or nil
    if idBox then
        idBox:SetText(DB.receiverGameAccountID and tostring(DB.receiverGameAccountID) or "")
    end
end

local function ReceiverCount(activeOnly)
    local n = 0
    local now = GetTime()
    for _, r in ipairs(EnsureReceiverDB()) do
        if tonumber(r.id) then
            if not activeOnly or (tonumber(r.lastAck) and (now - tonumber(r.lastAck)) <= 25) then
                n = n + 1
            end
        end
    end
    return n
end

local function ReceiverSummary()
    local parts = {}
    for _, r in ipairs(EnsureReceiverDB()) do
        if tonumber(r.id) then
            parts[#parts+1] = tostring(r.name or "Horde") .. "(" .. tostring(r.id) .. ")"
        end
    end
    return #parts > 0 and table.concat(parts, ", ") or "none"
end

local function AddOrUpdateReceiver(id, name, silent)
    id = tonumber(id)
    if not id then return false end
    name = tostring(name or "Horde")
    local key = ReceiverNameKey(name)
    local receivers = EnsureReceiverDB()
    local found = nil

    for _, r in ipairs(receivers) do
        if tonumber(r.id) == id then
            found = r
            break
        end
        local rk = ReceiverNameKey(r.name)
        if key and rk and rk == key then
            found = r
            break
        end
    end

    if not found then
        if #receivers < MAX_RECEIVERS then
            found = {}
            receivers[#receivers+1] = found
        else
            -- Replace the stalest slot. This lets a relogged account whose
            -- character/name and session ID both changed recover automatically.
            local oldestIndex, oldestValue = 1, math.huge
            for i, r in ipairs(receivers) do
                local v = tonumber(r.lastAck) or 0
                if v < oldestValue then oldestIndex, oldestValue = i, v end
            end
            found = receivers[oldestIndex]
        end
    end

    local changed = tonumber(found.id) ~= id or tostring(found.name or "") ~= name
    found.id = id
    found.name = name
    found.lastAck = GetTime()
    found.lastSeen = time()
    SyncLegacyPrimary()

    if not silent and changed then
        Print("CONNECTED Horde receiver " .. name .. " (session ID " .. tostring(id) .. ").")
    end
    if RestartHeartbeat then RestartHeartbeat() end
    return true
end

local function SendToReceivers(prefix, payload)
    local sent = 0
    local seen = {}
    for _, r in ipairs(EnsureReceiverDB()) do
        local id = tonumber(r.id)
        if id and not seen[id] then
            seen[id] = true
            local ok = SendBN(id, prefix, payload)
            if ok then sent = sent + 1 end
        end
    end
    return sent
end

local function SendPairProbe(id)
    if not pairing or not pairNonce then return end
    local payload = table.concat({"PAIR", pairNonce, UnitName("player") or "Alliance"}, "\031")
    SendBN(id, PREFIX, payload)
end

-- Build a list of CURRENT online WoW Battle.net game-account IDs.
local function DiscoverOnlineWoWGameAccountIDs()
    local out, seen = {}, {}
    local wowClient = BNET_CLIENT_WOW or "WoW"

    local function Add(id)
        id = tonumber(id)
        if id and id > 0 and not seen[id] then
            seen[id] = true
            out[#out + 1] = id
        end
    end

    for _, r in ipairs(EnsureReceiverDB()) do Add(r.id) end

    if BNGetNumFriends then
        for i = 1, (BNGetNumFriends() or 0) do
            if C_BattleNet and C_BattleNet.GetFriendAccountInfo then
                local info = C_BattleNet.GetFriendAccountInfo(i)
                local ga = info and info.gameAccountInfo
                if ga and ga.isOnline and ga.gameAccountID
                    and (not ga.clientProgram or ga.clientProgram == "WoW" or ga.clientProgram == wowClient) then
                    Add(ga.gameAccountID)
                end
                if C_BattleNet.GetFriendNumGameAccounts and C_BattleNet.GetFriendGameAccountInfo then
                    for j = 1, (C_BattleNet.GetFriendNumGameAccounts(i) or 0) do
                        local g = C_BattleNet.GetFriendGameAccountInfo(i, j)
                        if g and g.isOnline and g.gameAccountID
                            and (not g.clientProgram or g.clientProgram == "WoW" or g.clientProgram == wowClient) then
                            Add(g.gameAccountID)
                        end
                    end
                end
            end

            if BNGetNumFriendGameAccounts and BNGetFriendGameAccountInfo then
                for j = 1, (BNGetNumFriendGameAccounts(i) or 0) do
                    local vals = {BNGetFriendGameAccountInfo(i, j)}
                    local client, gameID, online
                    for _, v in ipairs(vals) do
                        if type(v) == "string" and (v == "WoW" or v == wowClient) then client = v end
                        if type(v) == "number" then gameID = v end
                        if type(v) == "boolean" and v == true then online = true end
                    end
                    if gameID and (client == "WoW" or client == wowClient) and online ~= false then Add(gameID) end
                end
            end
        end
    end
    return out
end

local function FinishPairScan(silent)
    pairing = false
    if pairButton then pairButton:SetText("Find Receivers") end
    if not silent then
        Print("Receiver scan complete. Connected: " .. ReceiverSummary())
    end
end

local function AcceptPairAck(hordeID, hordeName, silent)
    local id = tonumber(hordeID)
    if not id then return end
    pairAcks[id] = true
    AddOrUpdateReceiver(id, hordeName, silent)
end

local function PairStep()
    if not pairing then return end

    local ackCount = 0
    for _ in pairs(pairAcks) do ackCount = ackCount + 1 end
    if ackCount >= MAX_RECEIVERS then
        FinishPairScan(true)
        return
    end

    local candidate = pairCandidates[pairCandidateIndex]
    if candidate then
        if pairButton then pairButton:SetText("Finding "..pairCandidateIndex.."/"..#pairCandidates) end
        pairCandidateIndex = pairCandidateIndex + 1
        SendPairProbe(candidate)
        C_Timer.After(0.30, PairStep)
        return
    end

    -- Classic fallback for builds that fail to expose current IDs through the
    -- friends API. Scan through 100 because live IDs such as 57 are normal.
    if pairFallbackNextID <= pairFallbackMaxID then
        SendPairProbe(pairFallbackNextID)
        pairFallbackNextID = pairFallbackNextID + 1
        C_Timer.After(0.08, PairStep)
        return
    end

    FinishPairScan(true)
end

local function StartPairing(silent)
    if UnitFactionGroup("player") ~= "Alliance" then return false end
    if pairing then
        if not silent then Print("Receiver scan already running.") end
        return
    end

    if silent then
        local now = GetTime()
        if (now - lastAutoPairAt) < 8 then return end
        lastAutoPairAt = now
    end

    pairNonce = tostring(time()).."-"..tostring(math.random(10000,99999))
    pairCandidates = DiscoverOnlineWoWGameAccountIDs()
    pairCandidateIndex = 1
    pairFallbackNextID = 1
    pairAcks = {}
    pairing = true
    if not silent then Print("Searching for up to two Horde receivers...") end
    PairStep()
end


local function PumpQueue()
    if sending or #queue == 0 then return end
    sending = true
    local payload = table.remove(queue, 1)
    local sent = SendToReceivers(PREFIX, payload)

    if DB.debug then
        Print("sent to " .. tostring(sent) .. " receiver(s); queue=" .. #queue)
    end

    C_Timer.After(0.35, function()
        sending = false
        PumpQueue()
    end)
end

local function QueuePayload(payload)
    if #queue >= (DB.maxQueue or 100) then
        table.remove(queue, 1)
    end
    queue[#queue+1] = payload
    PumpQueue()
end

local function ReadStandardFriends()
    local getCount = C_FriendList and C_FriendList.GetNumFriends or GetNumFriends
    local getInfo = C_FriendList and C_FriendList.GetFriendInfoByIndex
    if type(getCount) ~= "function" or (type(getInfo) ~= "function" and type(GetFriendInfo) ~= "function") then
        return nil
    end
    local ok, count = pcall(getCount)
    if not ok or type(count) ~= "number" or count < 0 then return nil end

    local snapshot = {}
    for i = 1, count do
        local info
        if type(getInfo) == "function" then
            ok, info = pcall(getInfo, i)
            if not ok or type(info) ~= "table" or type(info.connected) ~= "boolean" then return nil end
        else
            local name, level, class, area, connected
            ok, name, level, class, area, connected = pcall(GetFriendInfo, i)
            if not ok then return nil end
            info = {name=name, connected=connected and true or false}
        end
        -- A partial roster is not a status change. Keep the last complete
        -- snapshot until Blizzard supplies all entries again.
        if type(info.name) ~= "string" or info.name == "" then return nil end
        snapshot[info.name:lower()] = {name=info.name, online=info.connected}
    end
    return snapshot
end

local function UpdateFriendStatus()
    if not friendStatusReady or UnitFactionGroup("player") ~= "Alliance" then return end
    local current = ReadStandardFriends()
    if not current then return end
    local previous = friendSnapshot
    friendSnapshot = current

    -- Always keep the baseline current, including while disabled/disconnected.
    -- First load, newly added friends, and removed friends produce no alert.
    if not previous or not DB.enabled or not DB.relayFriendStatus or ReceiverCount(false) == 0 then return end
    for key, info in pairs(current) do
        local old = previous[key]
        if old and old.online ~= info.online then
            friendStatusSequence = friendStatusSequence + 1
            -- Use a dedicated packet rather than an AM chat type. Older
            -- receivers reject FS, so these notices can never be public chat.
            local payload = table.concat({
                "FS", info.online and "ONLINE" or "OFFLINE",
                Clean(info.name):gsub("\031", " "), date("%H:%M:%S"),
                Clean(UnitName("player") or "?"),
                tostring(time())..":"..tostring(friendStatusSequence),
            }, "\031")
            QueuePayload(payload)
        end
    end
end

local function CacheWho(name, level, zone, class)
    if not name or not level then return end
    local short = StripRealm(name)
    local key = short:lower()

    whoCache[key] = {
        name = short,
        fullName = tostring(name),
        level = tonumber(level),
        zone = zone or "",
        class = class or "",
        seen = time(),
        seenText = date("%Y-%m-%d %H:%M"),
    }

    DB.whoDatabase = whoCache
    RemovePendingWho(name)

    -- Keep AllianceWhoScanner's persistent cache synchronized too.
    if AllianceWhoScanner and AllianceWhoScanner.RememberPlayer then
        AllianceWhoScanner:RememberPlayer(name, level, class, zone, "Relay")
    end
end

local function SyncScannerToRelayCache()
    if not AllianceWhoScanner or not AllianceWhoScanner.GetPlayers then
        return 0
    end

    local players = AllianceWhoScanner:GetPlayers()
    if type(players) ~= "table" then return 0 end

    local synced = 0
    for _, info in pairs(players) do
        if type(info) == "table" and info.name and tonumber(info.level) then
            CacheWho(
                info.name,
                info.level,
                info.zone,
                info.class
            )
            synced = synced + 1
        end
    end
    return synced
end

local function SyncRelayCacheToScanner()
    if not AllianceWhoScanner or not AllianceWhoScanner.ImportPlayers then
        return 0
    end
    return AllianceWhoScanner:ImportPlayers(whoCache)
end

local function GetCachedLevel(name)
    local item = whoCache[StripRealm(name):lower()]
    return item and item.level or nil
end

local function GetCachedClass(name)
    local item = whoCache[StripRealm(name):lower()]
    return item and item.class or nil
end

local function PendingWhoCount()
    local n = 0
    for _ in pairs(pendingWho) do n = n + 1 end
    return n
end

local function UpdateScanButton()
    if not scanBtn then return end
    local n = PendingWhoCount()
    if n > 0 then
        scanBtn:SetText("Scan WHO (" .. n .. ")")
    else
        scanBtn:SetText("Scan WHO Now")
    end
end

local function QueueWhoName(name)
    local short = StripRealm(name)
    if not short or short == "" then return end

    if AllianceWhoScanner and AllianceWhoScanner.MarkUnknown then
        AllianceWhoScanner:MarkUnknown(short, GetZone())
        return
    end

    -- Legacy fallback if the scanner helper failed to load.
    local key = short:lower()
    if not whoCache[key] then
        pendingWho[key] = short
        UpdateScanButton()
    end
end

RemovePendingWho = function(name)
    local short = StripRealm(name)
    if not short then return end
    pendingWho[short:lower()] = nil

    -- AllianceWhoScanner owns the visible WHO button when loaded.
    if not (AllianceWhoScanner and AllianceWhoScanner.AttachButton) then
        UpdateScanButton()
    end
end

local function NextPendingWho()
    for key, name in pairs(pendingWho) do
        return key, name
    end
    return nil, nil
end

local function ReadWhoResults()
    if not C_FriendList or not C_FriendList.GetNumWhoResults or not C_FriendList.GetWhoInfo then
        return
    end

    local count = C_FriendList.GetNumWhoResults() or 0
    local added = 0

    for i=1,count do
        local info = C_FriendList.GetWhoInfo(i)
        if type(info) == "table" then
            local name = info.fullName or info.name
            local level = info.level
            local zone = info.area or info.zone
            local class = info.classStr or info.class
            if name and level then
                CacheWho(name, level, zone, class)
                added = added + 1
            end
        end
    end

    if added > 0 then
        Print("WHO cache updated: " .. added .. " players.")
    end
end

local function SendRemoteWhoDatabaseResults(query, requesterID)
    if not requesterID then return end
    local zone = NormalizeRemoteZone(query)
    local results = {}

    for _,info in pairs(whoCache) do
        if tostring(info.zone or "") == zone then
            results[#results+1]=info
        end
    end

    table.sort(results,function(a,b)
        local al=tonumber(a.level) or 0
        local bl=tonumber(b.level) or 0
        if al~=bl then return al>bl end
        return tostring(a.name or "") < tostring(b.name or "")
    end)

    local function send(payload)
        if BNSendGameData then
            pcall(BNSendGameData,tonumber(requesterID),PREFIX,payload)
        elseif C_BattleNet and C_BattleNet.SendGameData then
            pcall(C_BattleNet.SendGameData,tonumber(requesterID),PREFIX,payload)
        end
    end

    if #results==0 then
        send(table.concat({"WR","0",Clean(query),Clean(zone),"No cached players found."},"\031"))
        return
    end

    send(table.concat({"WR","H",Clean(query),Clean(zone),tostring(#results)},"\031"))

    local maxResults=math.min(#results,50)
    for i=1,maxResults do
        local info=results[i]
        send(table.concat({
            "WR","P",
            Clean(info.name or "?"),
            Clean(info.level or ""),
            Clean(info.class or ""),
            Clean(info.zone or ""),
            Clean(info.seenText or "")
        },"\031"))
    end

    local tail=""
    if #results>maxResults then
        tail=tostring(#results-maxResults).." more cached matches not shown."
    end
    send(table.concat({"WR","T",tail},"\031"))
end

local function DoWhoScan()
    if not DB.whoEnabled then
        Print("WHO cache is disabled.")
        return
    end

    if not C_FriendList or not C_FriendList.SendWho then
        Print("WHO API unavailable.")
        return
    end

    local now = GetTime()
    local remaining = (DB.whoInterval or 300) - (now-lastWhoScan)
    if lastWhoScan > 0 and remaining > 0 then
        Print("WHO scan available again in " .. math.ceil(remaining) .. " sec.")
        return
    end

    if C_FriendList.SetWhoToUi then
        pcall(C_FriendList.SetWhoToUi, true)
    end

    -- Prioritize a speaker whose level/class is missing.
    local pendingKey, pendingName = NextPendingWho()
    local query = ""

    if pendingRemoteWhoZone then
        query = 'z-"' .. pendingRemoteWhoZone .. '"'
    elseif pendingName then
        query = 'n-"' .. pendingName .. '"'
    elseif DB.whoCurrentZoneOnly then
        query = 'z-"' .. GetZone() .. '"'
    end

    lastWhoScan = now
    local ok, err = pcall(C_FriendList.SendWho, query)
    if ok then
        if pendingRemoteWhoZone then
            Print("WHO scan requested for Horde query: " .. pendingRemoteWhoZone .. ".")
        elseif pendingName then
            Print("WHO requested for " .. pendingName .. ".")
        elseif query ~= "" then
            Print("WHO scan requested for " .. GetZone() .. ".")
        else
            Print("WHO scan requested.")
        end
    else
        Print("WHO scan blocked: " .. tostring(err))
    end
end

local function Relay(kind, senderName, text)
    -- HARD SAFETY GATE: this addon may exist in the shared AddOns folder on
    -- Horde clients too. Never forward local Horde chat into the relay.
    if UnitFactionGroup("player") ~= "Alliance" then return end
    if not DB.enabled or ReceiverCount(false) == 0 then return end
    if DB.ignoreOwnMessages and StripRealm(senderName) == UnitName("player") then return end
    if not MatchesKeyword(text) then return end

    -- Guild chat does not identify the speaker's physical zone. Do not stamp
    -- the spy's current zone onto a remote guild member or feed that false
    -- location into the WHO-resolution queue. Existing cached level/class data
    -- is still safe to reuse when available.
    local isGuild = kind == "GUILD"
    local zone = isGuild and "" or GetZone()
    local author = StripRealm(senderName)

    local level, class
    if AllianceWhoScanner and AllianceWhoScanner.GetPlayerInfo then
        local info = AllianceWhoScanner:GetPlayerInfo(senderName)
        if info then
            level = info.level
            class = info.class

            -- Mirror authoritative scanner data into the relay database so the
            -- database browser and old compatibility code always agree.
            if level then
                CacheWho(senderName, level, info.zone or zone, class)
            end
        end
    end

    -- Legacy relay cache remains a fallback for old saved data.
    level = level or GetCachedLevel(senderName)
    class = class or GetCachedClass(senderName)

    if not level then
        if not isGuild then
            QueueWhoName(senderName)
            if AllianceWhoScanner and AllianceWhoScanner.MarkUnknown then
                AllianceWhoScanner:MarkUnknown(senderName, zone)
            end
        end
    elseif not isGuild and AllianceWhoScanner and AllianceWhoScanner.RememberPlayer then
        AllianceWhoScanner:RememberPlayer(senderName, level, class, zone, "Relay")
    end
    local levelText = level and tostring(level) or ""
    local classText = class or ""
    local timestamp = date("%H:%M")

    local key = table.concat({kind,zone,author,text}, "\031")
    if IsDuplicate(key) then return end

    local payload = table.concat({
        "AM",
        Clean(kind),
        Clean(zone),
        Clean(author),
        Clean(levelText),
        Clean(classText),
        Clean(timestamp),
        Clean(text),
        Clean(UnitName("player") or "?") -- current broadcaster / spy character
    }, "\031")

    if #payload > 240 then
        payload = payload:sub(1,240)
    end

    QueuePayload(payload)
end

local function ChannelKind(channelName, channelBaseName)
    local a = tostring(channelBaseName or ""):lower():gsub("%s+","")
    local b = tostring(channelName or ""):lower():gsub("%s+","")

    if a:find("localdefense",1,true) or b:find("localdefense",1,true) then
        return "LD"
    end
    if a == "general" or a:find("general",1,true)==1 or b:find("general",1,true) then
        return "GEN"
    end
end

local function SendTest()
    local payload = table.concat({"T", Clean(GetZone()), Clean(UnitName("player") or "?"), date("%H:%M:%S")}, "\031")
    local sent = SendToReceivers(PREFIX, payload)
    Print("Manual test sent to " .. tostring(sent) .. " receiver(s).")
end


local function PruneWhoDatabase()
    local maxDays = tonumber(DB.whoDatabaseMaxAgeDays) or 30
    if maxDays <= 0 then return end
    local cutoff = time() - (maxDays * 86400)
    for key,info in pairs(whoCache) do
        if not info.seen or info.seen < cutoff then
            whoCache[key] = nil
        end
    end
    DB.whoDatabase = whoCache
end

local function WhoDatabaseCount()
    local n = 0
    for _ in pairs(whoCache) do n = n + 1 end
    return n
end

local ZONE_ALIASES = {
    ["rr"]="Redridge Mountains",
    ["redridge"]="Redridge Mountains",
    ["redridge mountains"]="Redridge Mountains",
    ["wet"]="Wetlands",
    ["wetlands"]="Wetlands",
    ["dusk"]="Duskwood",
    ["duskwood"]="Duskwood",
    ["stv"]="Stranglethorn Vale",
    ["stranglethorn"]="Stranglethorn Vale",
    ["stranglethorn vale"]="Stranglethorn Vale",
    ["wpl"]="Western Plaguelands",
    ["western plaguelands"]="Western Plaguelands",
    ["western plague"]="Western Plaguelands",
    ["epl"]="Eastern Plaguelands",
    ["eastern plaguelands"]="Eastern Plaguelands",
    ["eastern plague"]="Eastern Plaguelands",
    ["bs"]="Burning Steppes",
    ["burning steppes"]="Burning Steppes",
    ["sg"]="Searing Gorge",
    ["searing gorge"]="Searing Gorge",
    ["sos"]="Swamp of Sorrows",
    ["swamp"]="Swamp of Sorrows",
    ["swamp of sorrows"]="Swamp of Sorrows",
    ["bl"]="Blasted Lands",
    ["blasted"]="Blasted Lands",
    ["blasted lands"]="Blasted Lands",
    ["hills"]="Hillsbrad Foothills",
    ["hillsbrad"]="Hillsbrad Foothills",
    ["hillsbrad foothills"]="Hillsbrad Foothills",
    ["arathi"]="Arathi Highlands",
    ["arathi highlands"]="Arathi Highlands",
    ["hinter"]="The Hinterlands",
    ["hinterlands"]="The Hinterlands",
    ["the hinterlands"]="The Hinterlands",
    ["bad"]="Badlands",
    ["badlands"]="Badlands",
    ["wf"]="Westfall",
    ["westfall"]="Westfall",
    ["loch"]="Loch Modan",
    ["loch modan"]="Loch Modan",
    ["dm"]="Dun Morogh",
    ["dun morogh"]="Dun Morogh",
    ["elwynn"]="Elwynn Forest",
    ["elwynn forest"]="Elwynn Forest",
    ["ds"]="Darkshore",
    ["darkshore"]="Darkshore",
    ["ash"]="Ashenvale",
    ["ashenvale"]="Ashenvale",
    ["stm"]="Stonetalon Mountains",
    ["stonetalon"]="Stonetalon Mountains",
    ["stonetalon mountains"]="Stonetalon Mountains",
    ["deso"]="Desolace",
    ["desolace"]="Desolace",
    ["fer"]="Feralas",
    ["feralas"]="Feralas",
    ["tan"]="Tanaris",
    ["tanaris"]="Tanaris",
    ["ug"]="Un'Goro Crater",
    ["ungoro"]="Un'Goro Crater",
    ["un'goro"]="Un'Goro Crater",
    ["un'goro crater"]="Un'Goro Crater",
    ["sil"]="Silithus",
    ["silithus"]="Silithus",
    ["fel"]="Felwood",
    ["felwood"]="Felwood",
    ["ws"]="Winterspring",
    ["winterspring"]="Winterspring",
    ["az"]="Azshara",
    ["azshara"]="Azshara",
    ["dust"]="Dustwallow Marsh",
    ["dustwallow"]="Dustwallow Marsh",
    ["dustwallow marsh"]="Dustwallow Marsh",
    ["1k"]="Thousand Needles",
    ["thousand needles"]="Thousand Needles",
}

local function NormalizeWhoQuery(query)
    query = tostring(query or ""):lower()
    query = query:match("^%s*(.-)%s*$") or query
    return ZONE_ALIASES[query] or query
end

local function SendBNToID(gameAccountID, payload)
    local id = tonumber(gameAccountID)
    if not id then return false end
    if C_BattleNet and C_BattleNet.SendGameData then
        return pcall(C_BattleNet.SendGameData, id, PREFIX, payload)
    elseif BNSendGameData then
        return pcall(BNSendGameData, id, PREFIX, payload)
    end
    return false
end

local function RemoteWhoResults(query)
    local normalized = NormalizeWhoQuery(query)
    local q = tostring(normalized or ""):lower()
    local out = {}

    for _,info in pairs(whoCache) do
        local zone = tostring(info.zone or ""):lower()
        local name = tostring(info.name or ""):lower()
        local cls = tostring(info.class or ""):lower()
        local lvl = tostring(info.level or "")

        if q == "" or zone == q or zone:find(q,1,true) or name:find(q,1,true)
           or cls:find(q,1,true) or lvl == q then
            out[#out+1] = info
        end
    end

    table.sort(out,function(a,b)
        local al=tonumber(a.level) or 0
        local bl=tonumber(b.level) or 0
        if al ~= bl then return al > bl end
        return tostring(a.name or "") < tostring(b.name or "")
    end)

    return out, normalized
end

local function HandleRemoteWhoQuery(query, requesterID)
    local results, normalized = RemoteWhoResults(query)

    if #results == 0 then
        local payload = table.concat({"WR","0",Clean(query),Clean(normalized),"No cached players found."},"\031")
        SendBNToID(requesterID,payload)
        return
    end

    -- Header
    SendBNToID(requesterID,table.concat({"WR","H",Clean(query),Clean(normalized),tostring(#results)},"\031"))

    -- Send at most 25 entries per query to avoid flooding.
    local maxResults = math.min(#results,25)
    for i=1,maxResults do
        local info=results[i]
        local payload=table.concat({
            "WR",
            "P",
            Clean(info.name or "?"),
            Clean(info.level or ""),
            Clean(info.class or ""),
            Clean(info.zone or ""),
            Clean(info.seenText or "")
        },"\031")
        SendBNToID(requesterID,payload)
    end

    if #results > maxResults then
        SendBNToID(requesterID,table.concat({
            "WR","T",tostring(#results-maxResults).." more cached matches not shown."
        },"\031"))
    else
        SendBNToID(requesterID,table.concat({"WR","T",""},"\031"))
    end
end

local function GetRemoteWhoInfo(index)
    if C_FriendList and C_FriendList.GetWhoInfo then
        local info=C_FriendList.GetWhoInfo(index)
        if not info then return nil end
        return info.fullName or info.name, tonumber(info.level), info.classStr or info.class,
            info.area or info.zone
    end
    if GetWhoInfo then
        local name,_,level,_,class,zone=GetWhoInfo(index)
        return name,tonumber(level),class,zone
    end
end

local function GetRemoteWhoCounts()
    if C_FriendList and C_FriendList.GetNumWhoResults then
        local shown,total=C_FriendList.GetNumWhoResults()
        return tonumber(shown) or 0, tonumber(total) or tonumber(shown) or 0
    end
    if GetNumWhoResults then
        local shown,total=GetNumWhoResults()
        return tonumber(shown) or 0, tonumber(total) or tonumber(shown) or 0
    end
    return 0,0
end

local function ClearPendingRemoteWho()
    pendingRemoteWhoKind=nil
    pendingRemoteWhoValue=nil
    pendingRemoteWhoRaw=nil
    pendingRemoteWhoFilter=nil
    pendingRemoteWhoRequesterID=nil
    pendingRemoteWhoSourceName=nil
    pendingRemoteWhoSourceLabel=nil
    pendingRemoteWhoClicked=false
end

local function SendLiveRemoteWhoResults()
    local kind=pendingRemoteWhoKind
    local value=pendingRemoteWhoValue
    local filter=pendingRemoteWhoFilter
    local requesterID=pendingRemoteWhoRequesterID
    if not kind or not value or not requesterID then return end

    local shown,total=GetRemoteWhoCounts()
    local matches={}
    local wantName=StripRealm(value):lower()
    local noobs=0
    local sixties=0

    for i=1,shown do
        local name,level,class,zone=GetRemoteWhoInfo(i)
        if name then
            if kind=="zone" then
                local lvl=tonumber(level)
                if tostring(zone or "")==value then
                    if lvl==60 then
                        sixties=sixties+1
                        matches[#matches+1]={name=name,level=level,class=class or "",zone=zone or value}
                    elseif lvl and lvl<60 then
                        noobs=noobs+1
                    end
                end
            elseif StripRealm(name):lower()==wantName then
                matches[#matches+1]={name=name,level=level,class=class or "",zone=zone or ""}
            end
        end
    end

    if kind=="zone" then
        local reportedSixties=sixties
        if filter=="60" and tonumber(total) and tonumber(total)>=shown then
            -- The live query itself is level-filtered, so total is the best
            -- available count even when Blizzard only exposes part of the list.
            reportedSixties=tonumber(total) or sixties
        end

        SendBNToID(requesterID,table.concat({
            "WR","ZH",Clean(value),tostring(noobs),tostring(reportedSixties),
            tostring(shown),tostring(total or shown),Clean(filter or "")
        },"\031"))

        -- A "who <zone> 60" request is count-only. Do not spam the receiver
        -- with player rows when the user only asked how many 60s are present.
        if filter~="60" then
            for _,info in ipairs(matches) do
                SendBNToID(requesterID,table.concat({
                    "WR","ZP",Clean(info.name),Clean(info.class),Clean(info.zone)
                },"\031"))
            end
        end

        local tail=""
        if filter~="60" and tonumber(total) and tonumber(total)>shown then
            tail="WHO capped at "..tostring(shown).." visible results; zone totals may be higher."
        end
        SendBNToID(requesterID,table.concat({"WR","ZT",tail},"\031"))
    else
        local info=matches[1]
        if info then
            SendBNToID(requesterID,table.concat({
                "WR","PL",Clean(info.name),Clean(info.level or ""),Clean(info.class),Clean(info.zone)
            },"\031"))
        else
            SendBNToID(requesterID,table.concat({"WR","PN",Clean(value)},"\031"))
        end
    end

    FinishActiveRemoteWho(nil)
end

local function RunPendingRemoteWho()
    if not pendingRemoteWhoKind or not pendingRemoteWhoValue then return end

    if C_FriendList and C_FriendList.SetWhoToUi then
        pcall(C_FriendList.SetWhoToUi,true)
    elseif SetWhoToUI then
        pcall(SetWhoToUI,1)
    end

    local query
    if pendingRemoteWhoKind=="zone" then
        if pendingRemoteWhoFilter=="60" then
            -- Exact level filter keeps "who RR 60" focused on the requested
            -- count and makes GetNumWhoResults() useful even when results cap.
            query='z-"'..pendingRemoteWhoValue..'" 60'
        else
            -- Full zone query preserves the normal noobs + 60s report.
            query='z-"'..pendingRemoteWhoValue..'"'
        end
    else
        query='n-"'..pendingRemoteWhoValue..'"'
    end

    local ok,err=false,"WHO API unavailable"
    if C_FriendList and C_FriendList.SendWho then
        ok,err=pcall(C_FriendList.SendWho,query)
    elseif SendWho then
        ok,err=pcall(SendWho,query)
    end

    if ok then
        pendingRemoteWhoClicked=true
        if remoteWhoPromptButton then
            remoteWhoPromptButton:SetText("Waiting...")
            remoteWhoPromptButton:SetEnabled(false)
        end
        if remoteWhoPromptIgnoreButton then remoteWhoPromptIgnoreButton:SetEnabled(false) end
        if remoteWhoPromptStatus then
            local queued=RemoteWhoQueueCount()
            remoteWhoPromptStatus:SetText("WHO sent • waiting for results"..(queued>0 and (" • "..tostring(queued).." queued") or ""))
        end
        Print("Receiver WHO: "..query)
    else
        if remoteWhoPromptStatus then remoteWhoPromptStatus:SetText("WHO failed: "..tostring(err)) end
        Print("Receiver WHO failed: "..tostring(err))
    end
end

RemoteWhoQueueCount=function()
    return #remoteWhoRequestQueue
end

local function RemoteWhoPromptDescription()
    local source=""
    if pendingRemoteWhoSourceName and pendingRemoteWhoSourceName~="" then
        source=tostring(pendingRemoteWhoSourceName)
        if pendingRemoteWhoSourceLabel and pendingRemoteWhoSourceLabel~="" then
            source=source.." ["..tostring(pendingRemoteWhoSourceLabel).."]"
        end
        source=source..": "
    end

    if pendingRemoteWhoKind=="zone" then
        if pendingRemoteWhoFilter=="60" then
            return source.."WHO "..tostring(pendingRemoteWhoValue).." 60"
        end
        return source.."WHO "..tostring(pendingRemoteWhoValue)
    end
    return source.."WHO "..tostring(pendingRemoteWhoValue or "?")
end

local function EnsureRemoteWhoPrompt()
    if remoteWhoPrompt then return end

    local box=CreateFrame("Frame","VoidLinkRemoteWhoPrompt",UIParent,"BackdropTemplate")
    box:SetSize(410,154)
    box:SetPoint("CENTER",0,180)
    box:SetFrameStrata("DIALOG")
    box:SetClampedToScreen(true)
    box:SetBackdrop({
        bgFile="Interface\\DialogFrame\\UI-DialogBox-Background",
        edgeFile="Interface\\Tooltips\\UI-Tooltip-Border",
        tile=true,tileSize=16,edgeSize=14,
        insets={left=4,right=4,top=4,bottom=4}
    })
    box:Hide()

    local title=box:CreateFontString(nil,"OVERLAY","GameFontNormalLarge")
    title:SetPoint("TOP",0,-14)
    title:SetText("VoidLink WHO Queue")

    local textLine=box:CreateFontString(nil,"OVERLAY","GameFontHighlight")
    textLine:SetPoint("TOPLEFT",18,-46)
    textLine:SetWidth(374)
    textLine:SetJustifyH("LEFT")

    local statusLine=box:CreateFontString(nil,"OVERLAY","GameFontHighlightSmall")
    statusLine:SetPoint("TOPLEFT",18,-75)
    statusLine:SetWidth(374)
    statusLine:SetJustifyH("LEFT")

    local run=CreateFrame("Button",nil,box,"UIPanelButtonTemplate")
    run:SetSize(120,26)
    run:SetPoint("BOTTOMLEFT",18,15)
    run:SetText("Run WHO")
    run:SetScript("OnClick",RunPendingRemoteWho)

    local ignore=CreateFrame("Button",nil,box,"UIPanelButtonTemplate")
    ignore:SetSize(100,26)
    ignore:SetPoint("BOTTOMRIGHT",-18,15)
    ignore:SetText("Ignore")
    ignore:SetScript("OnClick",function()
        if FinishActiveRemoteWho then
            FinishActiveRemoteWho("IGNORED")
        end
    end)

    remoteWhoPrompt=box
    remoteWhoPromptText=textLine
    remoteWhoPromptButton=run
    remoteWhoPromptIgnoreButton=ignore
    remoteWhoPromptStatus=statusLine
end

local function RefreshRemoteWhoPrompt()
    if not pendingRemoteWhoKind then
        if remoteWhoPrompt then remoteWhoPrompt:Hide() end
        return
    end

    EnsureRemoteWhoPrompt()
    remoteWhoPromptText:SetText(RemoteWhoPromptDescription())

    local queued=RemoteWhoQueueCount()
    local queueText=queued>0 and (" • "..tostring(queued).." queued") or ""
    if pendingRemoteWhoClicked then
        remoteWhoPromptButton:SetText("Waiting...")
        remoteWhoPromptButton:SetEnabled(false)
        if remoteWhoPromptIgnoreButton then remoteWhoPromptIgnoreButton:SetEnabled(false) end
        remoteWhoPromptStatus:SetText("WHO sent • waiting for results"..queueText)
    else
        remoteWhoPromptButton:SetText("Run WHO")
        remoteWhoPromptButton:SetEnabled(true)
        if remoteWhoPromptIgnoreButton then remoteWhoPromptIgnoreButton:SetEnabled(true) end
        remoteWhoPromptStatus:SetText("Click Run WHO or Ignore • expires in 30s"..queueText)
    end
    remoteWhoPrompt:Show()
end

ActivateNextRemoteWho=function()
    if pendingRemoteWhoKind then
        RefreshRemoteWhoPrompt()
        return
    end

    local item=table.remove(remoteWhoRequestQueue,1)
    if not item then
        if remoteWhoPrompt then remoteWhoPrompt:Hide() end
        return
    end

    pendingRemoteWhoKind=item.kind
    pendingRemoteWhoValue=item.value
    pendingRemoteWhoRaw=item.raw
    pendingRemoteWhoFilter=item.filter
    pendingRemoteWhoRequesterID=item.requesterID
    pendingRemoteWhoSourceName=item.sourceName
    pendingRemoteWhoSourceLabel=item.sourceLabel
    pendingRemoteWhoClicked=false

    pendingRemoteWhoToken=pendingRemoteWhoToken+1
    local token=pendingRemoteWhoToken
    RefreshRemoteWhoPrompt()

    C_Timer.After(30,function()
        if pendingRemoteWhoKind and pendingRemoteWhoToken==token
            and not pendingRemoteWhoClicked
        then
            FinishActiveRemoteWho("TIMEOUT")
        end
    end)
end

FinishActiveRemoteWho=function(reason)
    local requesterID=pendingRemoteWhoRequesterID
    local raw=pendingRemoteWhoRaw or pendingRemoteWhoValue or "?"
    if requesterID and reason then
        SendBNToID(requesterID,table.concat({
            "WR","X",Clean(reason),Clean(raw)
        },"\031"))
    end

    ClearPendingRemoteWho()
    if remoteWhoPrompt then remoteWhoPrompt:Hide() end
    ActivateNextRemoteWho()
end

local function QueueRemoteWhoRequest(item)
    if not item then return end
    if pendingRemoteWhoKind then
        remoteWhoRequestQueue[#remoteWhoRequestQueue+1]=item
        RefreshRemoteWhoPrompt()
    else
        remoteWhoRequestQueue[#remoteWhoRequestQueue+1]=item
        ActivateNextRemoteWho()
    end
end

local function SortedWhoResults(query)
    query = tostring(query or ""):lower()
    local out = {}
    for _,info in pairs(whoCache) do
        local blob = table.concat({
            tostring(info.name or ""),
            tostring(info.fullName or ""),
            tostring(info.class or ""),
            tostring(info.zone or ""),
            tostring(info.level or "")
        }, " "):lower()

        if query == "" or blob:find(query, 1, true) then
            out[#out+1] = info
        end
    end

    table.sort(out, function(a,b)
        local an = tostring(a.name or "")
        local bn = tostring(b.name or "")
        return an < bn
    end)

    return out
end

PruneWhoDatabase()

local function SendHeartbeat()
    if UnitFactionGroup("player") ~= "Alliance" then return end
    if not DB.heartbeatEnabled then return end
    if ReceiverCount(false) == 0 then return end

    local payload=table.concat({
        "HB",
        tostring(time()),
        Clean(UnitName("player") or "?") -- current broadcaster / spy character
    },"\031")

    SendToReceivers(PREFIX,payload)
end

RestartHeartbeat = function()
    if heartbeatTicker and heartbeatTicker.Cancel then
        heartbeatTicker:Cancel()
    end
    heartbeatTicker=nil

    if not DB.heartbeatEnabled then return end

    local interval=tonumber(DB.heartbeatInterval) or 5
    if interval < 3 then interval=3 end

    if C_Timer and C_Timer.NewTicker then
        heartbeatTicker=C_Timer.NewTicker(interval,SendHeartbeat)
        C_Timer.After(1,SendHeartbeat)
    end
end

-- ---------- GUI ----------

local launcher = CreateFrame("Button","AllianceRelayLauncher",UIParent,"UIPanelButtonTemplate")
launcher:SetSize(46,24)
launcher:SetText("AR")
launcher:SetMovable(true)
launcher:EnableMouse(true)
launcher:RegisterForDrag("LeftButton")
launcher:SetClampedToScreen(true)
launcher:Hide()

local cfg = CreateFrame("Frame","AllianceRelayConfig",UIParent,"BackdropTemplate")
cfg:SetSize(460,560)
cfg:SetPoint("CENTER")
cfg:SetFrameStrata("DIALOG")
cfg:SetMovable(true)
cfg:SetClampedToScreen(true)
cfg:SetBackdrop({
    bgFile="Interface\\DialogFrame\\UI-DialogBox-Background",
    edgeFile="Interface\\Tooltips\\UI-Tooltip-Border",
    tile=true,tileSize=16,edgeSize=14,
    insets={left=4,right=4,top=4,bottom=4}
})
cfg:Hide()

local title = cfg:CreateFontString(nil,"OVERLAY","GameFontNormalLarge")
title:SetPoint("TOP",0,-14)
title:SetText("VoidLink Sender Settings")

-- Drag the settings window by the title/header area.
local cfgDragBar = CreateFrame("Frame", nil, cfg)
cfgDragBar:SetPoint("TOPLEFT", 6, -5)
cfgDragBar:SetPoint("TOPRIGHT", -6, -5)
cfgDragBar:SetHeight(34)
cfgDragBar:EnableMouse(true)
cfgDragBar:RegisterForDrag("LeftButton")
cfgDragBar:SetFrameLevel(cfg:GetFrameLevel() + 5)

cfgDragBar:SetScript("OnDragStart", function()
    cfg:StartMoving()
end)

cfgDragBar:SetScript("OnDragStop", function()
    cfg:StopMovingOrSizing()
end)

local function MakeCheck(parent,label,x,y,getter,setter)
    local cb=CreateFrame("CheckButton",nil,parent,"UICheckButtonTemplate")
    cb:SetPoint("TOPLEFT",x,y)
    local tx=cb:CreateFontString(nil,"OVERLAY","GameFontNormal")
    tx:SetPoint("LEFT",cb,"RIGHT",4,1)
    tx:SetText(label)
    cb:SetScript("OnShow",function(self) self:SetChecked(getter()) end)
    cb:SetScript("OnClick",function(self) setter(self:GetChecked() and true or false) end)
    return cb
end

MakeCheck(cfg,"Enable sender",20,-50,function() return DB.enabled end,function(v) DB.enabled=v end)
MakeCheck(cfg,"Heartbeat",20,-178,function() return DB.heartbeatEnabled end,function(v) DB.heartbeatEnabled=v; RestartHeartbeat() end)
MakeCheck(cfg,"Relay Direct Messages",20,-210,function() return DB.relayWhispers end,function(v) DB.relayWhispers=v end)
MakeCheck(cfg,"Relay General",20,-82,function() return DB.relayGeneral end,function(v) DB.relayGeneral=v end)
MakeCheck(cfg,"Relay LocalDefense",20,-114,function() return DB.relayLocalDefense end,function(v) DB.relayLocalDefense=v end)
MakeCheck(cfg,"Relay Party",20,-146,function() return DB.relayParty end,function(v) DB.relayParty=v end)
MakeCheck(cfg,"Relay Guild",220,-210,function() return DB.relayGuild end,function(v) DB.relayGuild=v end)
MakeCheck(cfg,"Ignore my own messages",220,-242,function() return DB.ignoreOwnMessages end,function(v) DB.ignoreOwnMessages=v end)
MakeCheck(cfg,"Relay friend login/logout",20,-414,function() return DB.relayFriendStatus end,function(v) DB.relayFriendStatus=v end)
local friendStatusHint=cfg:CreateFontString(nil,"OVERLAY","GameFontHighlightSmall")
friendStatusHint:SetPoint("TOPLEFT",20,-448)
friendStatusHint:SetWidth(410)
friendStatusHint:SetJustifyH("LEFT")
friendStatusHint:SetText("Regular WoW friends only. Alerts stay in the receiver's private window.")

MakeCheck(cfg,"Include timestamp",220,-50,function() return DB.includeTimestamp end,function(v) DB.includeTimestamp=v end)
MakeCheck(cfg,"Include zone",220,-82,function() return DB.includeZone end,function(v) DB.includeZone=v end)
MakeCheck(cfg,"Abbreviate zone",220,-114,function() return DB.abbreviateZone end,function(v) DB.abbreviateZone=v end)
MakeCheck(cfg,"Include level",220,-146,function() return DB.includeLevel end,function(v) DB.includeLevel=v end)
MakeCheck(cfg,"Include player name",220,-178,function() return DB.includeAuthor end,function(v) DB.includeAuthor=v end)

local idLabel=cfg:CreateFontString(nil,"OVERLAY","GameFontNormal")
idLabel:SetPoint("TOPLEFT",20,-250)
idLabel:SetText("Manual receiver ID (backup):")

idBox=CreateFrame("EditBox",nil,cfg,"InputBoxTemplate")
idBox:SetSize(135,24)
idBox:SetPoint("TOPLEFT",250,-244)
idBox:SetAutoFocus(false)
idBox:SetNumeric(true)
idBox:SetScript("OnShow",function(self)
    self:SetText(DB.receiverGameAccountID and tostring(DB.receiverGameAccountID) or "")
end)
idBox:SetScript("OnEnterPressed",function(self)
    local id=tonumber(self:GetText())
    self:ClearFocus()
    if id then
        AddOrUpdateReceiver(id,"Manual",false)
        SendHeartbeat()
    end
end)

local whoEnableCB=MakeCheck(cfg,"Enable WHO cache",20,-240,function() return DB.whoEnabled end,function(v) DB.whoEnabled=v end)
whoEnableCB:Hide()
local whoZoneCB=MakeCheck(cfg,"WHO current zone only",220,-240,function() return DB.whoCurrentZoneOnly end,function(v) DB.whoCurrentZoneOnly=v end)
whoZoneCB:Hide()

local intervalLabel=cfg:CreateFontString(nil,"OVERLAY","GameFontNormal")
intervalLabel:SetPoint("TOPLEFT",20,-278)
intervalLabel:SetText("WHO interval:")

local dropdown=CreateFrame("Frame","AllianceRelayWhoIntervalDropdown",cfg,"UIDropDownMenuTemplate")
dropdown:SetPoint("TOPLEFT",105,-262)
local options={{"2 min",120},{"5 min",300},{"10 min",600},{"15 min",900}}
UIDropDownMenu_Initialize(dropdown,function(self,level)
    for _,o in ipairs(options) do
        local info=UIDropDownMenu_CreateInfo()
        info.text=o[1]
        info.checked=(DB.whoInterval==o[2])
        info.func=function()
            DB.whoInterval=o[2]
            UIDropDownMenu_SetText(dropdown,o[1])
        end
        UIDropDownMenu_AddButton(info,level)
    end
end)
UIDropDownMenu_SetWidth(dropdown,90)
intervalLabel:Hide()
dropdown:Hide()

local function SetIntervalText()
    for _,o in ipairs(options) do
        if DB.whoInterval==o[2] then
            UIDropDownMenu_SetText(dropdown,o[1])
            return
        end
    end
    UIDropDownMenu_SetText(dropdown,"5 min")
end

local keywordCB=MakeCheck(cfg,"Keyword filter",20,-310,function() return DB.keywordFilterEnabled end,function(v) DB.keywordFilterEnabled=v end)
keywordCB:Hide()

local filterBox=CreateFrame("EditBox",nil,cfg,"InputBoxTemplate")
filterBox:SetSize(360,24)
filterBox:SetPoint("TOPLEFT",20,-345)
filterBox:Hide()
filterBox:SetAutoFocus(false)
filterBox:SetScript("OnShow",function(self) self:SetText(DB.keywordFilter or "") end)
filterBox:SetScript("OnEnterPressed",function(self)
    DB.keywordFilter=self:GetText()
    self:ClearFocus()
end)

local hint=cfg:CreateFontString(nil,"OVERLAY","GameFontHighlightSmall")
hint:SetPoint("TOPLEFT",20,-286)
hint:SetWidth(400)
hint:SetJustifyH("LEFT")
hint:SetText("WHO scanner: click the zone button repeatedly to advance through the PvP zone list.")

-- Manual WHO scanner button from AllianceWhoScanner.lua.
-- This stays separate from the relay's older internal WHO code.
if AllianceWhoScanner and AllianceWhoScanner.AttachButton then
    scanBtn = AllianceWhoScanner:AttachButton(cfg, "TOPLEFT", cfg, "TOPLEFT", 20, -330)
else
    scanBtn=CreateFrame("Button",nil,cfg,"UIPanelButtonTemplate")
    scanBtn:SetSize(135,28)
    scanBtn:SetPoint("TOPLEFT",20,-330)
    scanBtn:SetText("WHO scanner missing")
    scanBtn:SetEnabled(false)
end

pairButton=CreateFrame("Button",nil,cfg,"UIPanelButtonTemplate")
pairButton:SetSize(125,28)
pairButton:SetPoint("TOPLEFT",130,-330)
pairButton:SetText("Find Receivers")
pairButton:SetScript("OnClick",function() StartPairing(false) end)

local testBtn=CreateFrame("Button",nil,cfg,"UIPanelButtonTemplate")
testBtn:SetSize(100,28)
testBtn:SetPoint("LEFT",pairButton,"RIGHT",10,0)
testBtn:SetText("Send Test")
testBtn:SetScript("OnClick",SendTest)


local dbBtn=CreateFrame("Button",nil,cfg,"UIPanelButtonTemplate")
dbBtn:SetSize(135,28)
dbBtn:SetPoint("TOPLEFT",20,-370)
dbBtn:SetText("WHO Database")
dbBtn:Show()

local debugCB=MakeCheck(cfg,"Debug",180,-367,function() return DB.debug end,function(v) DB.debug=v end)

local closeBtn=CreateFrame("Button",nil,cfg,"UIPanelButtonTemplate")
closeBtn:SetSize(80,26)
closeBtn:SetPoint("TOPLEFT",340,-370)
closeBtn:SetText("Close")
closeBtn:SetScript("OnClick",function() cfg:Hide() end)

cfg:SetScript("OnShow",function()
    SetIntervalText()
    idBox:SetText(DB.receiverGameAccountID and tostring(DB.receiverGameAccountID) or "")
    filterBox:SetText(DB.keywordFilter or "")
end)


-- Persistent WHO database browser.
local dbWin=CreateFrame("Frame","AllianceRelayWhoDatabase",UIParent,"BackdropTemplate")
dbWin:SetSize(560,420)
dbWin:SetPoint("CENTER",UIParent,"CENTER",220,0)
dbWin:SetFrameStrata("DIALOG")
dbWin:SetMovable(true)
dbWin:SetClampedToScreen(true)
dbWin:SetBackdrop({
    bgFile="Interface\\DialogFrame\\UI-DialogBox-Background",
    edgeFile="Interface\\Tooltips\\UI-Tooltip-Border",
    tile=true,tileSize=16,edgeSize=14,
    insets={left=4,right=4,top=4,bottom=4}
})
dbWin:Hide()

local dbTitle=dbWin:CreateFontString(nil,"OVERLAY","GameFontNormalLarge")
dbTitle:SetPoint("TOP",0,-14)
dbTitle:SetText("WHO Player Database")

-- Drag the WHO database window by the title/header area.
local dbDragBar = CreateFrame("Frame", nil, dbWin)
dbDragBar:SetPoint("TOPLEFT", 6, -5)
dbDragBar:SetPoint("TOPRIGHT", -6, -5)
dbDragBar:SetHeight(34)
dbDragBar:EnableMouse(true)
dbDragBar:RegisterForDrag("LeftButton")
dbDragBar:SetFrameLevel(dbWin:GetFrameLevel() + 5)

dbDragBar:SetScript("OnDragStart", function()
    dbWin:StartMoving()
end)

dbDragBar:SetScript("OnDragStop", function()
    dbWin:StopMovingOrSizing()
end)

local searchLabel=dbWin:CreateFontString(nil,"OVERLAY","GameFontNormal")
searchLabel:SetPoint("TOPLEFT",18,-48)
searchLabel:SetText("Search:")

local searchBox=CreateFrame("EditBox",nil,dbWin,"InputBoxTemplate")
searchBox:SetSize(250,24)
searchBox:SetPoint("LEFT",searchLabel,"RIGHT",8,0)
searchBox:SetAutoFocus(false)

local countText=dbWin:CreateFontString(nil,"OVERLAY","GameFontHighlightSmall")
countText:SetPoint("TOPRIGHT",-18,-52)

local resultFrame=CreateFrame("ScrollingMessageFrame",nil,dbWin)
resultFrame:SetPoint("TOPLEFT",18,-82)
resultFrame:SetPoint("BOTTOMRIGHT",-18,52)
resultFrame:SetFontObject(ChatFontNormal)
resultFrame:SetJustifyH("LEFT")
resultFrame:SetFading(false)
resultFrame:SetMaxLines(500)
resultFrame:EnableMouseWheel(true)
resultFrame:SetScript("OnMouseWheel",function(self,d)
    if d>0 then self:ScrollUp() else self:ScrollDown() end
end)

local function RefreshDatabaseWindow()
    resultFrame:Clear()
    local results = SortedWhoResults(searchBox:GetText() or "")
    countText:SetText(#results.." / "..WhoDatabaseCount().." players")

    if #results == 0 then
        resultFrame:AddMessage("|cffaaaaaaNo matching players.|r")
        return
    end

    for _,info in ipairs(results) do
        local lvl = info.level and ("L:"..tostring(info.level)) or ""
        local cls = tostring(info.class or "")
        local zone = tostring(info.zone or "")
        local seenText = tostring(info.seenText or "")
        local line = string.format("%s  %s  %s  %s  |cff888888%s|r",
            tostring(info.name or "?"), lvl, cls, zone, seenText)
        resultFrame:AddMessage(line)
    end
end

searchBox:SetScript("OnTextChanged",function()
    RefreshDatabaseWindow()
end)
searchBox:SetScript("OnEnterPressed",function(self)
    self:ClearFocus()
    RefreshDatabaseWindow()
end)

local clearOldBtn=CreateFrame("Button",nil,dbWin,"UIPanelButtonTemplate")
clearOldBtn:SetSize(125,24)
clearOldBtn:SetPoint("BOTTOMLEFT",18,18)
clearOldBtn:SetText("Prune Old Data")
clearOldBtn:SetScript("OnClick",function()
    PruneWhoDatabase()
    RefreshDatabaseWindow()
    Print("WHO database pruned.")
end)

local clearAllBtn=CreateFrame("Button",nil,dbWin,"UIPanelButtonTemplate")
clearAllBtn:SetSize(125,24)
clearAllBtn:SetPoint("LEFT",clearOldBtn,"RIGHT",8,0)
clearAllBtn:SetText("Clear Database")
clearAllBtn:SetScript("OnClick",function()
    wipe(whoCache)
    DB.whoDatabase = whoCache
    RefreshDatabaseWindow()
    Print("WHO database cleared.")
end)

local dbClose=CreateFrame("Button",nil,dbWin,"UIPanelButtonTemplate")
dbClose:SetSize(80,24)
dbClose:SetPoint("BOTTOMRIGHT",-18,18)
dbClose:SetText("Close")
dbClose:SetScript("OnClick",function() dbWin:Hide() end)

dbBtn:SetScript("OnClick",function()
    if dbWin:IsShown() then
        dbWin:Hide()
    else
        RefreshDatabaseWindow()
        dbWin:Show()
    end
end)

launcher:SetScript("OnClick",function()
    if UnitFactionGroup("player") == "Horde" then return end
    if cfg:IsShown() then cfg:Hide() else cfg:Show() end
end)
launcher:SetScript("OnDragStart",function(self) self:StartMoving() end)
launcher:SetScript("OnDragStop",function(self)
    self:StopMovingOrSizing()
    local p,_,_,x,y=self:GetPoint(1)
    DB.launcherPoint=p; DB.launcherX=x; DB.launcherY=y
end)

local function RestoreLauncher()
    launcher:ClearAllPoints()
    launcher:SetPoint(DB.launcherPoint or "CENTER",UIParent,DB.launcherPoint or "CENTER",DB.launcherX or -300,DB.launcherY or 0)
end

SLASH_ALLIANCERELAYDIAG1="/ardiag"
SlashCmdList["ALLIANCERELAYDIAG"]=function()
    Print("Sender diag:")
    Print("receivers="..ReceiverSummary())
    Print("friend status relay="..tostring(DB.relayFriendStatus))
    Print("PREFIX="..PREFIX)
    if C_ChatInfo and C_ChatInfo.IsAddonMessagePrefixRegistered then
        Print("registered="..tostring(C_ChatInfo.IsAddonMessagePrefixRegistered(PREFIX)))
    end
    Print("BNSendGameData="..tostring(BNSendGameData ~= nil))
    Print("C_BattleNet.SendGameData="..tostring(C_BattleNet and C_BattleNet.SendGameData ~= nil))
    if AllianceWhoScanner and AllianceWhoScanner.GetUnknownCount then
        Print("levelCache="..tostring(WhoDatabaseCount()).." unresolved="..tostring(AllianceWhoScanner:GetUnknownCount()))
    else
        Print("levelCache="..tostring(WhoDatabaseCount()).." scanner=missing")
    end
end

_G.VoidLink_OpenSenderSettings=function()
    if UnitFactionGroup("player") ~= "Alliance" then return end
    cfg:Show()
end

SLASH_ALLIANCERELAY1="/ar"
SlashCmdList["ALLIANCERELAY"]=function()
    if _G.VoidLink_OpenSenderSettings then
        _G.VoidLink_OpenSenderSettings()
    end
end

f:RegisterEvent("ADDON_LOADED")
f:RegisterEvent("PLAYER_LOGIN")
f:RegisterEvent("CHAT_MSG_CHANNEL")
f:RegisterEvent("CHAT_MSG_PARTY")
f:RegisterEvent("CHAT_MSG_PARTY_LEADER")
f:RegisterEvent("CHAT_MSG_GUILD")
f:RegisterEvent("FRIENDLIST_UPDATE")
f:RegisterEvent("CHAT_MSG_WHISPER")
f:RegisterEvent("CHAT_MSG_WHISPER_INFORM")
f:RegisterEvent("WHO_LIST_UPDATE")
f:RegisterEvent("BN_CHAT_MSG_ADDON")
f:RegisterEvent("BN_FRIEND_INFO_CHANGED")

f:SetScript("OnEvent",function(self,event,...)
    if event=="ADDON_LOADED" then
        local name=...
        if name==ADDON_NAME then ApplyDefaults() end
        return
    end
    if event=="PLAYER_LOGIN" then
        if UnitFactionGroup("player") ~= "Alliance" then
            -- The WoW AddOns directory is shared by every account using this
            -- install, so AllianceRelaySender can load on Horde characters too.
            -- Make the sender completely inert there.
            pairing = false
            if heartbeatTicker and heartbeatTicker.Cancel then heartbeatTicker:Cancel() end
            heartbeatTicker = nil
            if receiverMonitorTicker and receiverMonitorTicker.Cancel then receiverMonitorTicker:Cancel() end
            receiverMonitorTicker = nil
            friendStatusReady = false
            friendSnapshot = nil
            self:UnregisterEvent("CHAT_MSG_CHANNEL")
            self:UnregisterEvent("CHAT_MSG_PARTY")
            self:UnregisterEvent("CHAT_MSG_PARTY_LEADER")
            self:UnregisterEvent("CHAT_MSG_GUILD")
            self:UnregisterEvent("FRIENDLIST_UPDATE")
            self:UnregisterEvent("CHAT_MSG_WHISPER")
            self:UnregisterEvent("CHAT_MSG_WHISPER_INFORM")
            self:UnregisterEvent("WHO_LIST_UPDATE")
            self:UnregisterEvent("BN_CHAT_MSG_ADDON")
            self:UnregisterEvent("BN_FRIEND_INFO_CHANGED")
            if launcher then launcher:Hide() end
            if cfg then cfg:Hide() end
            if dbWin then dbWin:Hide() end
            return
        end
        ApplyDefaults()
        whoCache = DB.whoDatabase or whoCache or {}
        DB.whoDatabase = whoCache

        -- Merge old relay WHO data into the scanner, then mirror the scanner
        -- back into the relay DB. This makes both files use one effective cache.
        SyncRelayCacheToScanner()
        SyncScannerToRelayCache()

        PruneWhoDatabase()
        if C_ChatInfo and C_ChatInfo.RegisterAddonMessagePrefix then
            C_ChatInfo.RegisterAddonMessagePrefix(PREFIX)
        end
        if launcher then launcher:Hide() end
        EnsureReceiverDB()
        friendStatusReady = true
        friendSnapshot = nil
        UpdateFriendStatus()
        local refreshFriends = C_FriendList and C_FriendList.ShowFriends or ShowFriends
        if type(refreshFriends) == "function" then pcall(refreshFriends) end
        for _,r in ipairs(DB.receivers or {}) do r.lastAck=0 end
        RestartHeartbeat()
        if receiverMonitorTicker and receiverMonitorTicker.Cancel then receiverMonitorTicker:Cancel() end
        if C_Timer and C_Timer.NewTicker then
            receiverMonitorTicker=C_Timer.NewTicker(15,function()
                -- If nobody has ACKed recently, force rediscovery. If one is alive,
                -- still do a quiet discovery periodically so a second Horde account
                -- can appear later without touching the Alliance client.
                local active=ReceiverCount(true)
                if active == 0 or (active < MAX_RECEIVERS and (GetTime()-lastAutoPairAt) > 45) then
                    StartPairing(true)
                end
            end)
        end
        -- Always refresh session-scoped receiver IDs after login.
        -- If the receiver is not online yet, BN_FRIEND_INFO_CHANGED below will
        -- retry when Battle.net reports a presence change.
        C_Timer.After(3, function() StartPairing(true) end)
        Print("Loaded. Auto-connect enabled (up to 2 Horde receivers). WHO DB: "..WhoDatabaseCount().." players.")
        return
    end

    -- Belt-and-suspenders faction lock. No runtime event from this sender is
    -- allowed to do work unless the current character is Alliance.
    if UnitFactionGroup("player") ~= "Alliance" then return end

    if event=="FRIENDLIST_UPDATE" then
        UpdateFriendStatus()
        return
    end

    if event=="BN_FRIEND_INFO_CHANGED" then
        if not pairing then
            C_Timer.After(1, function() StartPairing(true) end)
        end
        return
    end
    if event=="BN_CHAT_MSG_ADDON" then
        -- Classic Era has used more than one argument layout for this event.
        -- Do not assume the sender gameAccountID is always argument #4.
        local args={...}
        local prefix=args[1]
        local payload=args[2]
        local senderID=nil
        for i=3,#args do
            local v=args[i]
            if type(v)=="number" then
                senderID=v
                break
            end
        end
        if not senderID then
            for i=3,#args do
                local v=args[i]
                if type(v)=="string" and v:match("^%d+$") then
                    senderID=tonumber(v)
                    break
                end
            end
        end

        if prefix==PREFIX and payload then
            local p=SplitPayload(payload)

            if p[1]=="PAIRACK" and pairing and p[2]==pairNonce then
                AcceptPairAck(senderID or tonumber(p[4]), p[3], true)
                return
            end

            -- A Horde receiver can push-connect itself at any time. This is the
            -- manual fallback for a second/late receiver and requires no numeric
            -- ID entry on the Alliance side.
            if p[1]=="PAIRME" then
                local rid = senderID or tonumber(p[4])
                if rid and AddOrUpdateReceiver(rid, p[3], false) then
                    local ack=table.concat({"PAIRMEACK",p[2] or "",Clean(UnitName("player") or "Alliance")},"\031")
                    SendBN(rid,PREFIX,ack)
                    SendHeartbeat()
                end
                return
            end

            -- Receiver heartbeat ACK keeps session IDs fresh without any visible
            -- TEST message.
            if p[1]=="HBACK" then
                AddOrUpdateReceiver(senderID or tonumber(p[3]), p[2], true)
                return
            end

            -- Live WHO request from the Horde receiver. SendWho is hardware
            -- protected, so queue the request and show a dedicated click box.
            if p[1]=="WQ" then
                local query=p[2] or ""
                local requesterID=senderID or tonumber(p[3])
                local sourceName=p[4] or ""
                local sourceLabel=p[5] or ""
                local targetQuery,filter=ParseRemoteWhoRequest(query)
                local kind,value=ResolveRemoteWhoTarget(targetQuery)

                if not requesterID or not kind or not value or value=="" then
                    return
                end

                pendingRemoteWhoZone=nil
                QueueRemoteWhoRequest({
                    kind=kind,
                    value=value,
                    raw=query,
                    filter=filter,
                    requesterID=requesterID,
                    sourceName=sourceName,
                    sourceLabel=sourceLabel,
                })

                SendBNToID(requesterID,table.concat({
                    "WR","Q",kind,Clean(value),Clean(filter or ""),tostring(RemoteWhoQueueCount())
                },"\031"))

                if kind=="zone" and filter=="60" then
                    Print("Queued WHO: level 60 count in "..value..".")
                elseif kind=="zone" then
                    Print("Queued WHO: "..value..".")
                else
                    Print("Queued WHO: player "..value..".")
                end
                return
            end
        end
        return
    end

    if event=="WHO_LIST_UPDATE" then
        ReadWhoResults()

        -- AllianceWhoScanner also receives WHO_LIST_UPDATE. Delay one frame so
        -- its cache is saved, then mirror it into this relay database.
        C_Timer.After(0.05, function()
            SyncScannerToRelayCache()
        end)

        if pendingRemoteWhoKind and pendingRemoteWhoRequesterID and pendingRemoteWhoClicked then
            -- Only a request that was actually clicked may consume WHO results.
            -- Background scanner updates must not complete a queued prompt.
            C_Timer.After(0.05,SendLiveRemoteWhoResults)
        elseif pendingRemoteWhoZone and pendingRemoteWhoRequesterID then
            -- Legacy fallback retained for older queued zone scans.
            local zone=pendingRemoteWhoZone
            local requester=pendingRemoteWhoRequesterID
            pendingRemoteWhoZone=nil
            pendingRemoteWhoRequesterID=nil
            C_Timer.After(0.25,function()
                SendRemoteWhoDatabaseResults(zone,requester)
                if scanBtn then UpdateScanButton() end
            end)
        end
        return
    end
    if event=="CHAT_MSG_CHANNEL" then
        local text,senderName,languageName,channelName,target,flags,
              zoneChannelID,channelIndex,channelBaseName=...
        local kind=ChannelKind(channelName,channelBaseName)
        if kind=="GEN" and DB.relayGeneral then Relay(kind,senderName,text)
        elseif kind=="LD" and DB.relayLocalDefense then Relay(kind,senderName,text)
        end
        return
    end

    if event=="CHAT_MSG_PARTY" or event=="CHAT_MSG_PARTY_LEADER" then
        local text,senderName=...
        if DB.relayParty then
            Relay("PARTY",senderName,text)
        end
        return
    end

    if event=="CHAT_MSG_GUILD" then
        local text,senderName=...
        if DB.relayGuild then
            Relay("GUILD",senderName,text)
        end
        return
    end

    -- Relay normal in-game /whisper direct messages in both directions.
    -- DM = received whisper; DMOUT = whisper sent by this Alliance character.
    if event=="CHAT_MSG_WHISPER" then
        local text,senderName=...
        if DB.relayWhispers then
            Relay("DM",senderName,text)
        end
        return
    end

    if event=="CHAT_MSG_WHISPER_INFORM" then
        local text,targetName=...
        if DB.relayWhispers then
            Relay("DMOUT",targetName,text)
        end
        return
    end
end)
