
local ADDON_NAME = ...
local PREFIX = "AHREL1"

HordeRelayReceiverDB = HordeRelayReceiverDB or {}
local DB
local f = CreateFrame("Frame")
local recentPayloads = {}
local history = {}
local allianceSenderGameAccountID = nil
local allianceSpyCharacterName = nil
local remoteWhoState = { total=0, ganks=0, zone="", names={} }
local remotePlayerCache = {}
local lastHeartbeat = nil
local connectionLost = false
local connectionTicker = nil

-- Distinct local color for Alliance spy-relay traffic.
-- ElvUI can skin the chat frame, but explicit AddMessage RGB values remain
-- separate from normal Horde channel colors. Embedded class/channel colors
-- inside BuildLine still override this base color where appropriate.
local SPY_CHAT_R, SPY_CHAT_G, SPY_CHAT_B = 0.78, 0.45, 1.00
local connectScanning = false
local connectNonce = nil
local connectCandidates = {}
local connectIndex = 1
local connectFallbackID = 1
local connectFallbackMaxID = 100
local connectButton = nil
local lastAutoConnectAt = 0

local defaults = {
    enabled=true,
    showWindow=true,
    locked=false,
    printToChat=false,
    whoResultsToChat=false,
    partyRelay=false,
    raidRelay=false,
    guildRelay=false,

    -- Choose which Alliance message TYPES this Horde receiver accepts at all.
    -- These are independent of the output destinations below.
    relayGeneral=true,
    relayLocalDefense=true,
    relayPartySource=true,
    relayGuild=true,
    relayIncomingDM=true,
    relayOutgoingDM=true,

    -- Persistent spy-chat archive. Every Alliance spy relay packet is logged
    -- as soon as it reaches this receiver, before receiver display/output
    -- filters are applied. This includes General, LocalDefense, Party, Guild,
    -- incoming DMs, and outgoing DMs.
    spyChatLogging=true,
    spyChatRetentionDays=30,
    spyChatMaxPerDay=5000,

    -- DMs are private by default. These only control whether a relayed whisper
    -- is re-broadcast into Party/Raid/Guild on the Horde character.
    broadcastIncomingDM=false,
    broadcastOutgoingDM=false,

    includeTimestamp=false,
    includeZone=true,
    abbreviateZone=true,
    includeLevel=true,
    includeAuthor=true,
    includeChannel=true,

    onlyCurrentZone=false,
    duplicateWindow=2,
    maxHistory=150,
    soundAlert=false,
    connectionAlert=true,
    connectionTimeout=20,
    connectionSound=true,
    connectionReportSelf=true,
    connectionReportParty=false,
    bnDebug=false,
    settingsVersion=124,

    backgroundAlpha=0.85,
    width=620,
    height=260,

    point="CENTER",
    x=0,
    y=170,
}

local ZONE_ABBR = {
    ["Redridge Mountains"]="RR", ["Wetlands"]="Wet", ["Duskwood"]="DW",
    ["Elwynn Forest"]="Elwynn", ["Westfall"]="WF", ["Loch Modan"]="Loch",
    ["Dun Morogh"]="DM", ["Darkshore"]="DS", ["Ashenvale"]="Ash",
    ["Stonetalon Mountains"]="STM", ["Desolace"]="Deso", ["Feralas"]="Fer",
    ["Tanaris"]="Tan", ["Un'Goro Crater"]="UG", ["Silithus"]="Sil",
    ["Stranglethorn Vale"]="STV", ["Swamp of Sorrows"]="SoS",
    ["Blasted Lands"]="BL", ["Burning Steppes"]="BS", ["Searing Gorge"]="SG",
    ["Badlands"]="Bad", ["Hillsbrad Foothills"]="HF",
    ["Alterac Mountains"]="Alt", ["Arathi Highlands"]="AH",
    ["The Hinterlands"]="Hinter", ["Western Plaguelands"]="WPL",
    ["Eastern Plaguelands"]="EPL", ["Tirisfal Glades"]="Tiris",
    ["Silverpine Forest"]="SF", ["Mulgore"]="Mul", ["The Barrens"]="Barrens",
    ["Durotar"]="Duro", ["Thousand Needles"]="1K", ["Dustwallow Marsh"]="DM",
    ["Felwood"]="Fel", ["Winterspring"]="WS", ["Azshara"]="Az",
    ["Moonglade"]="Moon", ["Deadwind Pass"]="DWP", ["Ironforge"]="IF",
    ["Stormwind City"]="SW", ["Stormwind"]="SW", ["Darnassus"]="Darn",
    ["Orgrimmar"]="Org", ["Thunder Bluff"]="TB", ["Undercity"]="UC",
}

local CLASS_COLORS = {
    ["Warrior"]="ffc79c6e",
    ["Mage"]="ff69ccf0",
    ["Rogue"]="fffff569",
    ["Druid"]="ffff7d0a",
    ["Hunter"]="ffabd473",
    ["Shaman"]="ff0070de",
    ["Priest"]="ffffffff",
    ["Warlock"]="ff9482c9",
    ["Paladin"]="fff58cba",
}

local CLASS_ABBR = {
    ["Warrior"]="War",
    ["Mage"]="Mage",
    ["Rogue"]="Rog",
    ["Druid"]="Dru",
    ["Hunter"]="Hun",
    ["Shaman"]="Sham",
    ["Priest"]="Pri",
    ["Warlock"]="Lock",
    ["Paladin"]="Pal",
}

local function ClassAbbr(class)
    return CLASS_ABBR[tostring(class or "")] or tostring(class or "")
end

local function ColorName(name, class)
    local hex = CLASS_COLORS[tostring(class or "")]
    if hex then
        return "|c"..hex..tostring(name).."|r"
    end
    return tostring(name)
end

local function BareName(name)
    name = tostring(name or "")
    return name:match("^([^%-]+)") or name
end

local function PlayerKey(name)
    return string.lower(BareName(name))
end

local function RememberRemotePlayer(name, level, class)
    if not name or name == "" then return end
    local key = PlayerKey(name)
    remotePlayerCache[key] = remotePlayerCache[key] or {}

    if tonumber(level) and tonumber(level) > 0 then
        remotePlayerCache[key].level = tostring(tonumber(level))
    end
    if class and class ~= "" and class ~= "?" then
        remotePlayerCache[key].class = class
    end
end

local function GetRememberedRemotePlayer(name)
    return remotePlayerCache[PlayerKey(name)]
end

local function Print(msg)
    DEFAULT_CHAT_FRAME:AddMessage("|cffff5555HordeRelay|r: "..tostring(msg))
end

local function ApplyDefaults()
    DB=HordeRelayReceiverDB
    for k,v in pairs(defaults) do
        if DB[k]==nil then DB[k]=v end
    end
end


local function Apply124Migration()
    if (tonumber(DB.settingsVersion) or 0) < 124 then
        DB.bnDebug=false
        DB.settingsVersion=124
    end
end

local function SplitSep(s)
    local t={}
    local start=1
    while true do
        local p=s:find("\031",start,true)
        if not p then t[#t+1]=s:sub(start); break end
        t[#t+1]=s:sub(start,p-1)
        start=p+1
    end
    return t
end

local function AbbrevZone(zone)
    return ZONE_ABBR[zone] or zone
end

local function IsDuplicate(payload,senderID)
    local now=GetTime()
    -- BNet can surface the same addon payload more than once. senderID can
    -- vary by event path, so dedupe by payload itself.
    local key=tostring(payload or "")
    local old=recentPayloads[key]
    recentPayloads[key]=now

    for k,t in pairs(recentPayloads) do
        if now-t>15 then recentPayloads[k]=nil end
    end

    return old and (now-old)<5
end

local win=CreateFrame("Frame","HordeRelayReceiverWindow",UIParent,"BackdropTemplate")

local recoveryBtn=CreateFrame("Button","HordeRelayRecoveryButton",UIParent,"UIPanelButtonTemplate")
recoveryBtn:SetSize(42,22)
recoveryBtn:SetText("HR")
recoveryBtn:SetPoint("CENTER",UIParent,"CENTER",300,0)
recoveryBtn:SetMovable(true)
recoveryBtn:EnableMouse(true)
recoveryBtn:RegisterForDrag("LeftButton")
recoveryBtn:SetClampedToScreen(true)
win:SetSize(620,260)
win:SetMovable(true)
win:SetResizable(true)
-- Classic Era does not provide SetMinResize/SetMaxResize on this frame.
-- We clamp the size manually after resizing instead.
win:EnableMouse(true)
win:RegisterForDrag("LeftButton")
win:SetClampedToScreen(true)
win:SetBackdrop({
    bgFile="Interface\\DialogFrame\\UI-DialogBox-Background",
    edgeFile="Interface\\Tooltips\\UI-Tooltip-Border",
    tile=true,tileSize=16,edgeSize=14,
    insets={left=4,right=4,top=4,bottom=4}
})

local function ApplyBackgroundAlpha()
    if not DB then return end
    local alpha = tonumber(DB.backgroundAlpha) or 0.85
    if alpha < 0 then alpha = 0 elseif alpha > 1 then alpha = 1 end

    -- DialogBox background is gray/black; alpha 0 makes it fully invisible.
    win:SetBackdropColor(1,1,1,alpha)
    -- Keep a faint edge so the resize area is still findable.
    win:SetBackdropBorderColor(1,1,1, math.max(0.15, alpha))
end


local function ClampWindowSize()
    local w = win:GetWidth() or 620
    local h = win:GetHeight() or 260

    if w < 300 then w = 300 end
    if h < 110 then h = 110 end
    if w > 1100 then w = 1100 end
    if h > 700 then h = 700 end

    win:SetSize(w,h)

    if DB then
        DB.width = math.floor(w + 0.5)
        DB.height = math.floor(h + 0.5)
    end
end

local connectionAlertFrame=CreateFrame("Frame","HordeRelayConnectionAlert",UIParent,"BackdropTemplate")
connectionAlertFrame:SetSize(360,90)
connectionAlertFrame:SetPoint("TOP",UIParent,"TOP",0,-180)
connectionAlertFrame:SetFrameStrata("DIALOG")
connectionAlertFrame:SetBackdrop({
    bgFile="Interface\\DialogFrame\\UI-DialogBox-Background",
    edgeFile="Interface\\Tooltips\\UI-Tooltip-Border",
    tile=true,tileSize=16,edgeSize=14,
    insets={left=4,right=4,top=4,bottom=4}
})
connectionAlertFrame:Hide()

local connectionAlertText=connectionAlertFrame:CreateFontString(nil,"OVERLAY","GameFontNormalLarge")
connectionAlertText:SetPoint("CENTER")
connectionAlertText:SetText("SPY CONNECTION LOST")

-- Acknowledge/close button.
-- Closing the alert does NOT change connectionLost, so CheckConnection()
-- will not reopen it during the same outage. A future reconnect resets
-- connectionLost, allowing a new disconnect to alert again.
local connectionAlertClose=CreateFrame("Button",nil,connectionAlertFrame,"UIPanelCloseButton")
connectionAlertClose:SetPoint("TOPRIGHT",-3,-3)
connectionAlertClose:SetScript("OnClick",function()
    connectionAlertFrame:Hide()
end)

local title=win:CreateFontString(nil,"OVERLAY","GameFontNormal")
title:SetPoint("TOPLEFT",10,-8)
title:SetText("Alliance Defense Relay")


-- Dedicated drag strip so the message frame/buttons do not steal mouse drags.
local winDragBar=CreateFrame("Frame",nil,win)
winDragBar:SetPoint("TOPLEFT",4,-4)
winDragBar:SetPoint("TOPRIGHT",-145,-4)
winDragBar:SetHeight(26)
winDragBar:EnableMouse(true)
winDragBar:RegisterForDrag("LeftButton")
winDragBar:SetFrameLevel(win:GetFrameLevel()+5)

winDragBar:SetScript("OnDragStart",function()
    if not DB.locked then
        win:StartMoving()
    end
end)

winDragBar:SetScript("OnDragStop",function()
    win:StopMovingOrSizing()
    local p,_,_,x,y=win:GetPoint(1)
    DB.point=p
    DB.x=x
    DB.y=y
    DB.width=math.floor(win:GetWidth()+0.5)
    DB.height=math.floor(win:GetHeight()+0.5)
end)

local status=win:CreateFontString(nil,"OVERLAY","GameFontHighlightSmall")
status:SetPoint("TOP",0,-9)
status:SetText("waiting")

local optionsBtn=CreateFrame("Button",nil,win,"UIPanelButtonTemplate")
optionsBtn:SetSize(70,20)
optionsBtn:SetPoint("TOPRIGHT",-8,-6)
optionsBtn:SetText("Options")

local clearBtn=CreateFrame("Button",nil,win,"UIPanelButtonTemplate")
clearBtn:SetSize(55,20)
clearBtn:SetPoint("RIGHT",optionsBtn,"LEFT",-6,0)
clearBtn:SetText("Clear")


local whoZoneLabel=win:CreateFontString(nil,"OVERLAY","GameFontNormalSmall")
whoZoneLabel:SetPoint("TOPLEFT",10,-31)
whoZoneLabel:SetText("WHO:")

local whoZoneDropdown=CreateFrame("Frame","HordeRelayWhoZoneDropdown",win,"UIDropDownMenuTemplate")
whoZoneDropdown:SetPoint("LEFT",whoZoneLabel,"RIGHT",-8,-1)
UIDropDownMenu_SetWidth(whoZoneDropdown,150)
UIDropDownMenu_SetText(whoZoneDropdown,"Select Zone")
whoZoneLabel:Hide()
whoZoneDropdown:Hide()


-- Bottom-right resize grip.
local resizeGrip=CreateFrame("Button",nil,win)
resizeGrip:SetSize(20,20)
resizeGrip:SetPoint("BOTTOMRIGHT",-2,2)
resizeGrip:EnableMouse(true)
resizeGrip:RegisterForClicks("LeftButtonDown","LeftButtonUp")

local resizeTexture=resizeGrip:CreateTexture(nil,"OVERLAY")
resizeTexture:SetAllPoints()
resizeTexture:SetTexture("Interface\\ChatFrame\\UI-ChatIM-SizeGrabber-Up")

resizeGrip:SetScript("OnMouseDown",function(self,button)
    if button=="LeftButton" and not DB.locked then
        win:StartSizing("BOTTOMRIGHT")
    end
end)

resizeGrip:SetScript("OnMouseUp",function()
    win:StopMovingOrSizing()
    ClampWindowSize()
end)

local scroll=CreateFrame("ScrollingMessageFrame",nil,win)
scroll:SetPoint("TOPLEFT",10,-34)
scroll:SetPoint("BOTTOMRIGHT",-10,10)
scroll:SetFontObject(ChatFontNormal)
scroll:SetJustifyH("LEFT")
scroll:SetFading(false)
scroll:SetMaxLines(150)
scroll:EnableMouseWheel(true)
scroll:SetScript("OnMouseWheel",function(self,d)
    if d>0 then self:ScrollUp() else self:ScrollDown() end
end)

clearBtn:SetScript("OnClick",function()
    scroll:Clear()
    history={}
    status:SetText("cleared")
end)

win:SetScript("OnDragStart",function(self)
    if not DB.locked then self:StartMoving() end
end)
win:SetScript("OnDragStop",function(self)
    self:StopMovingOrSizing()
    local p,_,_,x,y=self:GetPoint(1)
    DB.point=p; DB.x=x; DB.y=y
    DB.width=math.floor(self:GetWidth()+0.5)
    DB.height=math.floor(self:GetHeight()+0.5)
end)

local cfg=CreateFrame("Frame","HordeRelayConfig",UIParent,"BackdropTemplate")
cfg:SetSize(540,720)
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

local ct=cfg:CreateFontString(nil,"OVERLAY","GameFontNormalLarge")
ct:SetPoint("TOP",0,-15)
ct:SetText("Horde Relay Settings")


local cfgDragBar=CreateFrame("Frame",nil,cfg)
cfgDragBar:SetPoint("TOPLEFT",6,-5)
cfgDragBar:SetPoint("TOPRIGHT",-6,-5)
cfgDragBar:SetHeight(34)
cfgDragBar:EnableMouse(true)
cfgDragBar:RegisterForDrag("LeftButton")
cfgDragBar:SetFrameLevel(cfg:GetFrameLevel()+5)

cfgDragBar:SetScript("OnDragStart",function()
    cfg:StartMoving()
end)
cfgDragBar:SetScript("OnDragStop",function()
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

-- Relay type filters. These decide WHAT is allowed through the Horde receiver.
local relayTypesLabel=cfg:CreateFontString(nil,"OVERLAY","GameFontNormal")
relayTypesLabel:SetPoint("TOPLEFT",20,-48)
relayTypesLabel:SetText("Relay types")

MakeCheck(cfg,"General",20,-70,function() return DB.relayGeneral end,function(v) DB.relayGeneral=v end)
MakeCheck(cfg,"Local Defense",20,-102,function() return DB.relayLocalDefense end,function(v) DB.relayLocalDefense=v end)
MakeCheck(cfg,"Guild",20,-134,function() return DB.relayGuild end,function(v) DB.relayGuild=v end)
MakeCheck(cfg,"Party source",140,-134,function() return DB.relayPartySource end,function(v) DB.relayPartySource=v end)
MakeCheck(cfg,"Incoming DMs",20,-166,function() return DB.relayIncomingDM end,function(v) DB.relayIncomingDM=v end)
MakeCheck(cfg,"Outgoing DMs",20,-198,function() return DB.relayOutgoingDM end,function(v) DB.relayOutgoingDM=v end)

-- Output destinations. These decide WHERE enabled relay types are shown/sent.
local destinationsLabel=cfg:CreateFontString(nil,"OVERLAY","GameFontNormal")
destinationsLabel:SetPoint("TOPLEFT",20,-242)
destinationsLabel:SetText("Output destinations")

MakeCheck(cfg,"Enable receiver",20,-264,function() return DB.enabled end,function(v) DB.enabled=v end)
MakeCheck(cfg,"Private relay window",20,-296,function() return DB.showWindow end,function(v) DB.showWindow=v; if v then win:Show() else win:Hide() end end)
MakeCheck(cfg,"Normal chat",20,-328,function() return DB.printToChat end,function(v) DB.printToChat=v end)
MakeCheck(cfg,"Party chat",20,-360,function() return DB.partyRelay end,function(v) DB.partyRelay=v end)
MakeCheck(cfg,"Raid chat",20,-392,function() return DB.raidRelay end,function(v) DB.raidRelay=v end)
MakeCheck(cfg,"Guild chat",20,-424,function() return DB.guildRelay end,function(v) DB.guildRelay=v end)

-- Formatting / behavior.
local formattingLabel=cfg:CreateFontString(nil,"OVERLAY","GameFontNormal")
formattingLabel:SetPoint("TOPLEFT",270,-48)
formattingLabel:SetText("Formatting / behavior")

MakeCheck(cfg,"Timestamp",270,-70,function() return DB.includeTimestamp end,function(v) DB.includeTimestamp=v end)
MakeCheck(cfg,"Channel label",270,-102,function() return DB.includeChannel end,function(v) DB.includeChannel=v end)
MakeCheck(cfg,"Zone",270,-134,function() return DB.includeZone end,function(v) DB.includeZone=v end)
MakeCheck(cfg,"Abbreviate zone",270,-166,function() return DB.abbreviateZone end,function(v) DB.abbreviateZone=v end)
MakeCheck(cfg,"Player name",270,-198,function() return DB.includeAuthor end,function(v) DB.includeAuthor=v end)
MakeCheck(cfg,"Level",270,-230,function() return DB.includeLevel end,function(v) DB.includeLevel=v end)
local whoResultsCB=MakeCheck(cfg,"WHO results to normal chat",270,-262,function() return DB.whoResultsToChat end,function(v) DB.whoResultsToChat=v end)
whoResultsCB:Hide()
MakeCheck(cfg,"Only current zone",270,-294,function() return DB.onlyCurrentZone end,function(v) DB.onlyCurrentZone=v end)
MakeCheck(cfg,"Play alert sound",270,-326,function() return DB.soundAlert end,function(v) DB.soundAlert=v end)
MakeCheck(cfg,"Spy disconnect alert",270,-358,function() return DB.connectionAlert end,function(v) DB.connectionAlert=v end)
MakeCheck(cfg,"Disconnect alert sound",270,-390,function() return DB.connectionSound end,function(v) DB.connectionSound=v end)
MakeCheck(cfg,"Lock relay window",270,-422,function() return DB.locked end,function(v) DB.locked=v end)

-- DM safety gate. Even with Incoming/Outgoing DMs enabled above, these remain
-- OFF by default so whispers stay private to the receiver window / local chat.
local dmSafetyLabel=cfg:CreateFontString(nil,"OVERLAY","GameFontNormal")
dmSafetyLabel:SetPoint("TOPLEFT",20,-462)
dmSafetyLabel:SetText("DM public broadcast safety")

MakeCheck(cfg,"Allow incoming DMs to Party/Raid/Guild",20,-484,function() return DB.broadcastIncomingDM end,function(v) DB.broadcastIncomingDM=v end)
MakeCheck(cfg,"Allow outgoing DMs to Party/Raid/Guild",20,-516,function() return DB.broadcastOutgoingDM end,function(v) DB.broadcastOutgoingDM=v end)
MakeCheck(cfg,"Lost alert to myself",270,-454,function() return DB.connectionReportSelf end,function(v) DB.connectionReportSelf=v end)
MakeCheck(cfg,"Lost alert to party/raid",270,-486,function() return DB.connectionReportParty end,function(v) DB.connectionReportParty=v end)

local alphaLabel=cfg:CreateFontString(nil,"OVERLAY","GameFontNormal")
alphaLabel:SetPoint("TOPLEFT",20,-555)
alphaLabel:SetText("Background transparency")

local alphaSlider=CreateFrame("Slider","HordeRelayBackgroundAlphaSlider",cfg,"OptionsSliderTemplate")
alphaSlider:SetPoint("TOPLEFT",20,-583)
alphaSlider:SetWidth(490)
alphaSlider:SetMinMaxValues(0,100)
alphaSlider:SetValueStep(5)
alphaSlider:SetObeyStepOnDrag(true)
_G[alphaSlider:GetName().."Low"]:SetText("0")
_G[alphaSlider:GetName().."High"]:SetText("100")
_G[alphaSlider:GetName().."Text"]:SetText("")

local alphaValue=cfg:CreateFontString(nil,"OVERLAY","GameFontHighlightSmall")
alphaValue:SetPoint("TOP",alphaSlider,"BOTTOM",0,-2)

local function RefreshAlphaSlider()
    local transparency=math.floor((1-(DB.backgroundAlpha or 0.85))*100+0.5)
    alphaSlider:SetValue(transparency)
    alphaValue:SetText(transparency.."% transparent")
end

alphaSlider:SetScript("OnValueChanged",function(self,value)
    if not DB then return end
    value=math.floor(value+0.5)
    DB.backgroundAlpha=1-(value/100)
    alphaValue:SetText(value.."% transparent")
    ApplyBackgroundAlpha()
end)

local preview=cfg:CreateFontString(nil,"OVERLAY","GameFontHighlight")
preview:SetPoint("TOPLEFT",20,-635)
preview:SetWidth(500)
preview:SetJustifyH("LEFT")
preview:SetText("Example: (G) [RR] [Marker] Playername [Marker] (60) message")

cfg:SetScript("OnShow",function()
    RefreshAlphaSlider()
end)

local idBtn=CreateFrame("Button",nil,cfg,"UIPanelButtonTemplate")
idBtn:SetSize(140,26)
idBtn:SetPoint("BOTTOMLEFT",20,18)
idBtn:SetText("Show My BNet ID")

connectButton=CreateFrame("Button",nil,cfg,"UIPanelButtonTemplate")
connectButton:SetSize(150,26)
connectButton:SetPoint("BOTTOM",cfg,"BOTTOM",0,18)
connectButton:SetText("Connect to Alliance")

local closeBtn=CreateFrame("Button",nil,cfg,"UIPanelButtonTemplate")
closeBtn:SetSize(80,26)
closeBtn:SetPoint("BOTTOMRIGHT",-20,18)
closeBtn:SetText("Close")
closeBtn:SetScript("OnClick",function() cfg:Hide() end)

local function OwnGameAccountID()
    local guid=UnitGUID("player")
    if C_BattleNet and C_BattleNet.GetGameAccountInfoByGUID and guid then
        local vals={C_BattleNet.GetGameAccountInfoByGUID(guid)}
        for _,v in ipairs(vals) do
            if type(v)=="table" then
                local id=v.gameAccountID or v.gameAccountId or v.id
                if id then return id end
            elseif type(v)=="number" then
                return v
            end
        end
    end
end

local function SendBNToID(id,payload)
    id=tonumber(id)
    if not id or not payload then return false end
    if BNSendGameData then
        local ok=pcall(BNSendGameData,id,PREFIX,payload)
        return ok
    elseif C_BattleNet and C_BattleNet.SendGameData then
        local ok=pcall(C_BattleNet.SendGameData,id,PREFIX,payload)
        return ok
    end
    return false
end

local function DiscoverOnlineWoWGameAccountIDs()
    local out,seen={},{}
    local wowClient=BNET_CLIENT_WOW or "WoW"
    local function Add(id)
        id=tonumber(id)
        if id and id>0 and not seen[id] then seen[id]=true; out[#out+1]=id end
    end
    if allianceSenderGameAccountID then Add(allianceSenderGameAccountID) end
    if BNGetNumFriends then
        for i=1,(BNGetNumFriends() or 0) do
            if C_BattleNet and C_BattleNet.GetFriendAccountInfo then
                local info=C_BattleNet.GetFriendAccountInfo(i)
                local ga=info and info.gameAccountInfo
                if ga and ga.isOnline and ga.gameAccountID and (not ga.clientProgram or ga.clientProgram=="WoW" or ga.clientProgram==wowClient) then Add(ga.gameAccountID) end
                if C_BattleNet.GetFriendNumGameAccounts and C_BattleNet.GetFriendGameAccountInfo then
                    for j=1,(C_BattleNet.GetFriendNumGameAccounts(i) or 0) do
                        local g=C_BattleNet.GetFriendGameAccountInfo(i,j)
                        if g and g.isOnline and g.gameAccountID and (not g.clientProgram or g.clientProgram=="WoW" or g.clientProgram==wowClient) then Add(g.gameAccountID) end
                    end
                end
            end
        end
    end
    return out
end

local function FinishConnectScan(found)
    connectScanning=false
    if connectButton then connectButton:SetText(found and "Connected" or "Connect to Alliance") end
end

local function ConnectStep()
    if not connectScanning then return end
    local id=connectCandidates[connectIndex]
    if id then
        connectIndex=connectIndex+1
        local payload=table.concat({"PAIRME",connectNonce,UnitName("player") or "Horde",tostring(OwnGameAccountID() or "")},"\031")
        SendBNToID(id,payload)
        C_Timer.After(0.25,ConnectStep)
        return
    end
    if connectFallbackID<=connectFallbackMaxID then
        local payload=table.concat({"PAIRME",connectNonce,UnitName("player") or "Horde",tostring(OwnGameAccountID() or "")},"\031")
        SendBNToID(connectFallbackID,payload)
        connectFallbackID=connectFallbackID+1
        C_Timer.After(0.08,ConnectStep)
        return
    end
    FinishConnectScan(false)
end

local function StartAllianceConnect(silent)
    if connectScanning then return end
    if silent then
        local now=GetTime()
        if (now-lastAutoConnectAt)<10 then return end
        lastAutoConnectAt=now
    end
    connectNonce=tostring(time()).."-"..tostring(math.random(10000,99999))
    connectCandidates=DiscoverOnlineWoWGameAccountIDs()
    connectIndex=1
    connectFallbackID=1
    connectScanning=true
    if connectButton then connectButton:SetText("Connecting...") end
    if not silent then Print("Looking for Alliance relay...") end
    ConnectStep()
end

connectButton:SetScript("OnClick",function() StartAllianceConnect(false) end)

idBtn:SetScript("OnClick",function()
    local id=OwnGameAccountID()
    if id then Print("YOUR gameAccountID = |cffffff00"..tostring(id).."|r")
    else Print("Could not determine gameAccountID.") end
end)

optionsBtn:SetScript("OnClick",function()
    if cfg:IsShown() then cfg:Hide() else cfg:Show() end
end)

local function CleanOutgoing(s)
    s=tostring(s or "")

    -- Strip WoW color markup before forwarding to Party/Raid/Guild.
    -- Some relayed system/defense messages arrive with the pipe character
    -- already converted to '/', e.g. /cfffff00Southshore is under attack!/r.
    -- Handle both forms so formatting codes never leak into public chat.
    s=s:gsub("|c%x%x%x%x%x%x%x%x","")
       :gsub("|r","")
       :gsub("/c%x%x%x%x%x%x%x%x","")
       :gsub("/r","")
       :gsub("|","/")
    return s
end

-- Blizzard injects zone-defense system alerts into LocalDefense (for example
-- "Southshore is under attack!"). They are not player intelligence and are
-- intentionally suppressed while normal LocalDefense player chat still relays.
local function IsDefenseSystemAlert(kind, text)
    if kind ~= "LD" then return false end
    local clean = CleanOutgoing(text):lower():match("^%s*(.-)%s*$") or ""
    return clean:find(" is under attack!?$", 1, false) ~= nil
end

local function PlayerMarkerIndex(name)
    name=tostring(name or "")
    local hash=0
    for i=1,#name do
        hash=(hash*33+name:byte(i))%8
    end
    return hash+1
end

local PUBLIC_MARKER_BY_CLASS = {
    -- Normal PARTY/RAID chat cannot transmit arbitrary |cff class colors.
    -- These built-in raid-target tokens DO render for everyone, so use the
    -- closest available marker color as a compact class-color cue.
    Warrior = "{cross}",     -- red / closest available to warrior brown
    Mage    = "{square}",    -- blue
    Rogue   = "{star}",      -- yellow
    Druid   = "{circle}",    -- orange
    Hunter  = "{triangle}",  -- green
    Shaman  = "{square}",    -- blue
    Priest  = "{moon}",      -- silver/white
    Warlock = "{diamond}",   -- purple
    Paladin = "{circle}",    -- closest available to pink
}

local function PlayerMarker(name,colored)
    local idx=PlayerMarkerIndex(name)
    if colored then
        return "|TInterface\\TargetingFrame\\UI-RaidTargetingIcon_"..idx..":14:14:0:0|t"
    end

    -- Public WoW chat cannot use texture markup, but it DOES understand
    -- the built-in raid-target tokens.
    local fallback={
        "{star}",
        "{circle}",
        "{diamond}",
        "{triangle}",
        "{moon}",
        "{square}",
        "{cross}",
        "{skull}",
    }
    return fallback[idx] or "{star}"
end

local function PublicClassMarker(class, author)
    return PUBLIC_MARKER_BY_CLASS[tostring(class or "")] or PlayerMarker(author,false)
end

local function BuildLine(kind,zone,author,level,class,timestamp,text,colored)
    local pieces={}

    if DB.includeTimestamp then
        table.insert(pieces, colored and ("|cff888888["..timestamp.."]|r") or ("["..timestamp.."]"))
    end

    if DB.includeChannel then
        local short
        if kind=="LD" then
            short="(LD)"
        elseif kind=="GEN" then
            short="(G)"
        elseif kind=="PARTY" then
            short="(P)"
        elseif kind=="DM" then
            short="(DM IN)"
        elseif kind=="DMOUT" then
            short="(DM OUT)"
        else
            short="("..tostring(kind or "?")..")"
        end

        if colored then
            if kind=="LD" then
                table.insert(pieces,"|cffffcc00"..short.."|r")
            elseif kind=="DM" or kind=="DMOUT" then
                table.insert(pieces,"|cffff88ff"..short.."|r")
            else
                table.insert(pieces,"|cff66ccff"..short.."|r")
            end
        else
            table.insert(pieces,short)
        end
    end

    if DB.includeZone then
        local z = DB.abbreviateZone and AbbrevZone(zone) or zone
        table.insert(pieces,"["..z.."]")
    end

    if DB.includeAuthor then
        local marker=PlayerMarker(author,colored)
        table.insert(pieces,marker)
        table.insert(pieces,colored and ColorName(author,class) or author)
        table.insert(pieces,marker)

        if DB.includeLevel and level and level ~= "" and level ~= "?" then
            table.insert(pieces,"("..level..")")
        end

        -- Private defense relay keeps the full intelligence profile.
        if class and class ~= "" and class ~= "?" then
            table.insert(pieces,"["..tostring(class).."]")
        end
    elseif DB.includeLevel and level and level ~= "" and level ~= "?" then
        table.insert(pieces,"("..level..")")
        if class and class ~= "" and class ~= "?" then
            table.insert(pieces,"["..tostring(class).."]")
        end
    end

    table.insert(pieces,text)
    return table.concat(pieces," ")
end

local function BuildPublicLine(zone,author,level,class,text)
    local zoneText = ""
    local markerText = ""
    local levelText = ""
    local classText = ""
    local authorText = tostring(author or "?")

    -- Minimal party/raid format:
    -- The marker color now follows class when class data is known.
    -- Non-60: [ZONE]{class-color marker}(LEVEL)Name: Message
    -- Level 60: [ZONE]{class-color marker}(60)Name[Rog]: Message
    if DB.includeZone then
        local z = AbbrevZone(zone)
        zoneText = "[" .. z .. "]"
    end

    if DB.includeAuthor then
        -- PARTY/RAID gets a visible class-color cue using a built-in raid marker.
        -- If class is unknown, fall back to the stable per-player marker.
        markerText = PublicClassMarker(class,author)
    end

    if DB.includeLevel and level and level ~= "" and level ~= "?" then
        levelText = "(" .. level .. ")"
    end

    if tonumber(level) == 60 and class and class ~= "" and class ~= "?" then
        classText = "[" .. ClassAbbr(class) .. "]"
    end

    local spyText = ""
    if allianceSpyCharacterName
        and PlayerKey(authorText) == PlayerKey(allianceSpyCharacterName) then
        spyText = "(SPY)"
    end

    -- Only the ACTUAL Alliance spy character gets the tag when that character
    -- personally speaks. Everyone else is relayed normally.
    -- Example spy:
    -- [RR]{moon}(60)MyAllianceSpy(SPY)[Rog]: inc bridge
    -- Example normal player:
    -- [RR]{moon}(60)Mixtape[Rog]: rogue by the lake
    return zoneText .. markerText .. levelText .. authorText .. spyText .. classText .. ": " .. tostring(text or "")
end

local function PublicRelay(kind,zone,author,level,class,timestamp,text)
    local isIncomingDM = kind=="DM"
    local isOutgoingDM = kind=="DMOUT"

    -- Privacy gate: relayed whispers NEVER enter public/group chat unless the
    -- matching DM broadcast option is explicitly enabled by the user.
    if isIncomingDM and not DB.broadcastIncomingDM then return end
    if isOutgoingDM and not DB.broadcastOutgoingDM then return end

    local msg
    if isIncomingDM then
        msg=CleanOutgoing("[DM IN] From "..tostring(author or "?")..": "..tostring(text or ""))
    elseif isOutgoingDM then
        msg=CleanOutgoing("[DM OUT] To "..tostring(author or "?")..": "..tostring(text or ""))
    else
        -- General/LocalDefense public forwarding intentionally omits timestamp
        -- and channel label. The private relay window keeps full formatting.
        msg=CleanOutgoing(BuildPublicLine(zone,author,level,class,text))
    end

    if #msg>240 then msg=msg:sub(1,240) end

    if DB.partyRelay and IsInGroup(LE_PARTY_CATEGORY_HOME) and not IsInRaid() then
        SendChatMessage(msg,"PARTY")
    end
    if DB.raidRelay and IsInRaid() then
        SendChatMessage(msg,"RAID")
    end
    if DB.guildRelay and IsInGuild and IsInGuild() then
        SendChatMessage(msg,"GUILD")
    end
end

local function AddHistory(line)
    history[#history+1]=line
    if #history>(DB.maxHistory or 150) then
        table.remove(history,1)
    end
end

local WHO_ZONE_OPTIONS = {
    {label="Redridge Mountains (RR)", query="RR"},
    {label="Duskwood (Dusk)", query="Dusk"},
    {label="Wetlands (Wet)", query="Wet"},
    {label="Stranglethorn Vale (STV)", query="STV"},
    {label="Western Plaguelands (WPL)", query="WPL"},
    {label="Eastern Plaguelands (EPL)", query="EPL"},
    {label="Burning Steppes (BS)", query="BS"},
    {label="Searing Gorge (SG)", query="SG"},
    {label="Hillsbrad Foothills (Hills)", query="Hills"},
    {label="Arathi Highlands", query="Arathi"},
    {label="The Hinterlands", query="Hinter"},
    {label="Badlands", query="Bad"},
    {label="Blasted Lands (BL)", query="BL"},
    {label="Swamp of Sorrows (SoS)", query="SoS"},
    {label="Westfall (WF)", query="WF"},
    {label="Loch Modan", query="Loch"},
    {label="Elwynn Forest", query="Elwynn"},
    {label="Dun Morogh (DM)", query="DM"},
    {label="Darkshore (DS)", query="DS"},
    {label="Ashenvale (Ash)", query="Ash"},
    {label="Stonetalon Mountains (STM)", query="STM"},
    {label="Desolace", query="Deso"},
    {label="Feralas", query="Fer"},
    {label="Tanaris", query="Tan"},
    {label="Un'Goro Crater (UG)", query="UG"},
    {label="Silithus", query="Sil"},
    {label="Felwood", query="Fel"},
    {label="Winterspring (WS)", query="WS"},
    {label="Azshara", query="Az"},
    {label="Dustwallow Marsh", query="Dust"},
    {label="Thousand Needles (1K)", query="1K"},
}

local function SendRemoteWhoQuery(query)
    query=tostring(query or ""):match("^%s*(.-)%s*$") or ""
    if query=="" then
        AddWhoOutput("|cffff7777WHO:|r Select a zone or use /rwho RR")
        return
    end

    if not allianceSenderGameAccountID then
        AddWhoOutput("|cffff7777WHO:|r Alliance connection not learned yet. Pair/receive a test first.")
        return
    end

    local payload=table.concat({"WQ",query},"\031")
    local ok,result

    -- Pairing works through the legacy BNet API on Classic Era, so WHO
    -- queries intentionally use that same transport first.
    if BNSendGameData then
        ok,result=pcall(BNSendGameData,allianceSenderGameAccountID,PREFIX,payload)
    elseif C_BattleNet and C_BattleNet.SendGameData then
        ok,result=pcall(C_BattleNet.SendGameData,allianceSenderGameAccountID,PREFIX,payload)
    else
        AddWhoOutput("|cffff7777WHO:|r Battle.net send API unavailable.")
        return
    end

    if ok then
        AddWhoOutput("|cffaaaaaaWHO request sent: "..query.."|r")
    else
        AddWhoOutput("|cffff7777WHO query failed:|r "..tostring(result))
    end
end

UIDropDownMenu_Initialize(whoZoneDropdown,function(self,level)
    for _,opt in ipairs(WHO_ZONE_OPTIONS) do
        local label=opt.label
        local query=opt.query

        local info=UIDropDownMenu_CreateInfo()
        info.text=label
        info.checked=false
        info.func=function()
            UIDropDownMenu_SetText(whoZoneDropdown,label)
            SendRemoteWhoQuery(query)
        end
        UIDropDownMenu_AddButton(info,level)
    end
end)

local function AddWhoOutput(line)
    scroll:AddMessage(line)
    if DB.whoResultsToChat then
        DEFAULT_CHAT_FRAME:AddMessage(line)
    end
end

local function HandleRemoteWhoResponse(p)
    local subtype=p[2]

    if subtype=="Q" then
        local zone=p[3] or "?"
        AddWhoOutput("|cffffcc00WHO DB|r "..zone..": no cache yet.")
        AddWhoOutput("|cffaaaaaaAlliance WHO scan queued — click Scan WHO on Alliance.|r")
        return
    end

    if subtype=="0" then
        local normalized=p[4] or p[3] or "?"
        AddWhoOutput("|cffff7777WHO DB|r "..normalized..": no cached players found.")
        remoteWhoState={total=0,ganks=0,zone=normalized,names={}}
        return
    end

    if subtype=="H" then
        local normalized=p[4] or p[3] or "?"
        local count=tonumber(p[5] or "0") or 0
        remoteWhoState={total=count,ganks=0,zone=normalized,names={}}
        AddWhoOutput("|cff66ff66WHO DB|r "..normalized.." ("..count.." cached)")
        return
    end

    if subtype=="P" then
        local name=p[3] or "?"
        local level=tonumber(p[4] or "")
        local class=p[5] or ""
        RememberRemotePlayer(name, level, class)
        local displayName=ColorName(name,class)
        local entry=displayName.." ("..ClassAbbr(class)..")"
        table.insert(remoteWhoState.names,entry)
        if level and level < 60 then
            remoteWhoState.ganks=remoteWhoState.ganks+1
        end
        return
    end

    if subtype=="T" then
        if #remoteWhoState.names > 0 then
            -- Print in chunks so long lists wrap sanely.
            local chunk={}
            for i,name in ipairs(remoteWhoState.names) do
                chunk[#chunk+1]=name
                if #chunk==5 or i==#remoteWhoState.names then
                    AddWhoOutput(table.concat(chunk,", "))
                    chunk={}
                end
            end
        end
        AddWhoOutput("|cffffcc00Ganks: "..tostring(remoteWhoState.ganks).."|r")
        if p[3] and p[3]~="" then
            AddWhoOutput("|cffaaaaaa"..tostring(p[3]).."|r")
        end
        return
    end
end

local function ReplyPair(senderID, nonce)
    local id=tonumber(senderID)
    if not id or not nonce or nonce=="" then return end

    local payload=table.concat({
        "PAIRACK",
        nonce,
        UnitName("player") or "Horde",
        tostring(OwnGameAccountID() or "")
    },"\031")

    local ok=SendBNToID(id,payload)
    local result=nil

    if DB.bnDebug then
        Print("Pair request from senderID="..tostring(senderID)
            .." reply ok="..tostring(ok).." result="..tostring(result))
    end
end

local function ReportConnectionStatus(message)
    if DB.connectionReportSelf then
        DEFAULT_CHAT_FRAME:AddMessage("|cffff3333HordeRelay:|r "..message)
    end

    if DB.connectionReportParty and IsInGroup and IsInGroup() then
        local channel = "PARTY"
        if IsInRaid and IsInRaid() then
            channel = "RAID"
        end
        SendChatMessage(message, channel)
    end
end

local function ShowConnectionLost()
    if connectionLost then return end
    connectionLost=true

    if DB.connectionAlert then
        connectionAlertFrame:Show()
    end

    if DB.connectionSound and PlaySound then
        PlaySound(SOUNDKIT and SOUNDKIT.RAID_WARNING or 8959,"Master")
    end

    ReportConnectionStatus("SPY CONNECTION LOST")
end

local function RestoreConnection()
    if not connectionLost then return end
    connectionLost=false
    connectionAlertFrame:Hide()
    ReportConnectionStatus("Spy connection restored.")
end

local function ReceiveHeartbeat(senderID, broadcasterName)
    if senderID then
        allianceSenderGameAccountID=senderID
    end

    -- The sender heartbeat contains the CURRENT Alliance broadcaster character.
    -- Update this every heartbeat so swapping Alliance characters automatically
    -- changes who is identified as (SPY), with no manual re-pair required.
    if broadcasterName and broadcasterName ~= "" and broadcasterName ~= "?" then
        allianceSpyCharacterName = BareName(broadcasterName)
    end

    lastHeartbeat=GetTime()
    connectScanning=false
    RestoreConnection()
    if connectButton then connectButton:SetText("Connected") end

    -- Silent ACK lets the Alliance sender know this receiver is still alive and
    -- refreshes its temporary session ID. This is NOT shown in the relay window.
    if allianceSenderGameAccountID then
        local ack=table.concat({"HBACK",UnitName("player") or "Horde",tostring(OwnGameAccountID() or "")},"\031")
        SendBNToID(allianceSenderGameAccountID,ack)
    end
end

local function CheckConnection()
    if not DB.connectionAlert then return end
    if not lastHeartbeat then return end

    local timeout=tonumber(DB.connectionTimeout) or 20
    if timeout < 10 then timeout=10 end

    if (GetTime()-lastHeartbeat) > timeout then
        ShowConnectionLost()
    end
end

local function StartConnectionMonitor()
    if connectionTicker and connectionTicker.Cancel then
        connectionTicker:Cancel()
    end
    connectionTicker=nil

    if C_Timer and C_Timer.NewTicker then
        connectionTicker=C_Timer.NewTicker(2,CheckConnection)
    end
end

-- Persistent relay-chat archive ------------------------------------------------
-- Stored inside HordeRelayReceiverDB, which is already a SavedVariables table.
-- Log every readable chat packet sent by the Alliance spy: General,
-- LocalDefense, Party, Guild, incoming DMs, and outgoing DMs. Addon diagnostics,
-- heartbeat/pairing traffic, WHO responses, and test packets are not archived.
local function SpyLogDayKey(epoch)
    epoch = tonumber(epoch) or (time and time()) or 0
    if date then
        return date("%Y-%m-%d", epoch)
    end
    return tostring(epoch)
end

local function PruneSpyChatLog(currentDay)
    if not DB or type(DB.spyChatLog) ~= "table" then return end
    if DB._spyChatLastPruneDay == currentDay then return end
    DB._spyChatLastPruneDay = currentDay

    local keepDays = tonumber(DB.spyChatRetentionDays) or 30
    if keepDays < 1 then keepDays = 1 end

    local now = (time and time()) or 0
    local cutoff = now - (keepDays * 86400)

    for dayKey, bucket in pairs(DB.spyChatLog) do
        local bucketEpoch = type(bucket) == "table" and tonumber(bucket.epoch) or nil
        if bucketEpoch and bucketEpoch < cutoff then
            DB.spyChatLog[dayKey] = nil
        end
    end
end

local function LogSpyRelayChat(kind, zone, author, level, class, timestamp, message)
    if not DB or not DB.spyChatLogging then return end

    -- Only archive supported human-readable chat types from the Alliance spy.
    -- Keep protocol/system packets out of the persistent chat history.
    if kind ~= "GEN"
       and kind ~= "LD"
       and kind ~= "PARTY"
       and kind ~= "GUILD"
       and kind ~= "DM"
       and kind ~= "DMOUT" then
        return
    end

    DB.spyChatLog = DB.spyChatLog or {}

    local now = (time and time()) or 0
    local dayKey = SpyLogDayKey(now)
    PruneSpyChatLog(dayKey)

    local bucket = DB.spyChatLog[dayKey]
    if type(bucket) ~= "table" then
        bucket = {
            epoch = now,
            count = 0,
            dropped = 0,
            entries = {},
        }
        DB.spyChatLog[dayKey] = bucket
    end

    bucket.entries = bucket.entries or {}
    bucket.count = tonumber(bucket.count) or #bucket.entries
    bucket.dropped = tonumber(bucket.dropped) or 0

    local maxPerDay = tonumber(DB.spyChatMaxPerDay) or 5000
    if maxPerDay < 100 then maxPerDay = 100 end

    -- Never perform table.remove(1) on a large archive during play. If someone
    -- somehow exceeds the generous daily cap, count the overflow and keep the
    -- already-recorded lines intact.
    if #bucket.entries >= maxPerDay then
        bucket.dropped = bucket.dropped + 1
        return
    end

    bucket.count = bucket.count + 1
    bucket.entries[#bucket.entries + 1] = {
        t = now,
        time = tostring(timestamp or ""),
        kind = tostring(kind or ""),
        zone = tostring(zone or ""),
        author = tostring(author or ""),
        level = tostring(level or ""),
        class = tostring(class or ""),
        text = tostring(message or ""),
    }
end

local function HandlePayload(payload,senderID)
    if senderID then
        allianceSenderGameAccountID=senderID
    end

    if not DB.enabled or IsDuplicate(payload,senderID) then return end
    local p=SplitSep(payload)

    if p[1]=="HB" then
        ReceiveHeartbeat(senderID, p[3])
        return
    end

    if p[1]=="PAIR" then
        ReplyPair(senderID,p[2])
        return
    end

    if p[1]=="PAIRMEACK" and (not connectNonce or p[2]==connectNonce) then
        if senderID then allianceSenderGameAccountID=senderID end

        -- The Alliance sender includes its character name in p[3].
        -- Remember it so only THAT character is labeled (SPY) when it
        -- personally talks in General/LocalDefense.
        if p[3] and p[3] ~= "" then
            allianceSpyCharacterName = BareName(p[3])
        end

        lastHeartbeat=GetTime()
        FinishConnectScan(true)
        RestoreConnection()
        status:SetText("connected")
        return
    end

    if p[1]=="WR" then
        HandleRemoteWhoResponse(p)
        return
    end

    if p[1]=="T" then
        local line="|cff888888["..date("%H:%M").."]|r |cff66ff66TEST RECEIVED|r from "..(p[3] or "?")
        scroll:AddMessage(line)
        AddHistory(line)
        status:SetText("test received")
        return
    end

    -- Only accept relay chat packets created by the faction-locked Alliance
    -- sender. Legacy "M" packets are intentionally rejected because an old
    -- sender loaded on a Horde client could forward Horde General/LD chat.
    if p[1]~="AM" then return end

    local kind=p[2] or "?"
    local zone=p[3] or "?"
    local author=p[4] or "?"
    local level=p[5] or "?"
    local class=p[6] or "?"
    local timestamp=p[7] or date("%H:%M")
    local text=p[8] or ""
    local broadcasterName=p[9]

    -- Ignore Blizzard-generated LocalDefense zone alerts such as
    -- "Southshore is under attack!". Keep actual player LocalDefense chat.
    if IsDefenseSystemAlert(kind, text) then return end

    -- Archive the raw readable spy feed before display/output filtering.
    -- This preserves every supported spy chat type even if receiver type,
    -- current-zone, or output settings would otherwise hide it.
    LogSpyRelayChat(kind, zone, author, level, class, timestamp, text)

    -- Per-type receiver filters. Turning one of these off drops that message
    -- type completely on Horde: no private window, local chat, sound, or
    -- Party/Raid/Guild forwarding.
    if kind=="GEN" and not DB.relayGeneral then return end
    if kind=="LD" and not DB.relayLocalDefense then return end
    if kind=="PARTY" and not DB.relayPartySource then return end
    if kind=="GUILD" and not DB.relayGuild then return end
    if kind=="DM" and not DB.relayIncomingDM then return end
    if kind=="DMOUT" and not DB.relayOutgoingDM then return end

    -- New sender builds stamp every relay packet with the CURRENT Alliance
    -- broadcaster character. This makes the (SPY) label correct immediately
    -- after character swaps, even before the next heartbeat arrives.
    if broadcasterName and broadcasterName ~= "" and broadcasterName ~= "?" then
        allianceSpyCharacterName = BareName(broadcasterName)
    end

    -- Prefer the level/class sent by AllianceRelaySender.
    -- If they are missing, use anything learned from Alliance WHO results.
    local remembered = GetRememberedRemotePlayer(author)
    if (not level or level == "" or level == "?") and remembered and remembered.level then
        level = remembered.level
    end
    if (not class or class == "" or class == "?") and remembered and remembered.class then
        class = remembered.class
    end

    RememberRemotePlayer(author, level, class)

    -- Zone filtering applies to General/LocalDefense reports only. A direct
    -- message is still relevant even when the Alliance and Horde characters
    -- are in different zones.
    if (kind=="GEN" or kind=="LD" or kind=="GUILD") and DB.onlyCurrentZone
       and zone ~= (GetRealZoneText and GetRealZoneText() or GetZoneText()) then
        return
    end

    local line=BuildLine(kind,zone,author,level,class,timestamp,text,true)

    if DB.showWindow then
        scroll:AddMessage(line, SPY_CHAT_R, SPY_CHAT_G, SPY_CHAT_B)
    end
    AddHistory(line)

    if DB.printToChat then
        DEFAULT_CHAT_FRAME:AddMessage(line, SPY_CHAT_R, SPY_CHAT_G, SPY_CHAT_B)
    end

    if DB.soundAlert and PlaySound then
        PlaySound(SOUNDKIT and SOUNDKIT.RAID_WARNING or 8959, "Master")
    end

    status:SetText(timestamp.." received")
    PublicRelay(kind,zone,author,level,class,timestamp,text)
end

local function RegisterPrefix()
    if C_ChatInfo and C_ChatInfo.RegisterAddonMessagePrefix then
        local ok = C_ChatInfo.RegisterAddonMessagePrefix(PREFIX)
        if DB and DB.bnDebug then
            Print("Register prefix "..PREFIX.." = "..tostring(ok))
            if C_ChatInfo.IsAddonMessagePrefixRegistered then
                Print("Prefix registered? "..tostring(C_ChatInfo.IsAddonMessagePrefixRegistered(PREFIX)))
            end
        end
        return ok
    end
    Print("RegisterAddonMessagePrefix API unavailable.")
    return false
end

local function Restore()
    win:ClearAllPoints()
    win:SetSize(DB.width or 620, DB.height or 260)
    ClampWindowSize()
    win:SetPoint(DB.point or "CENTER",UIParent,DB.point or "CENTER",DB.x or 0,DB.y or 170)
    ApplyBackgroundAlpha()
    if DB.showWindow then win:Show() else win:Hide() end
end


recoveryBtn:SetScript("OnClick",function()
    DB.enabled=true
    DB.showWindow=true
    if not DB.width or DB.width < 300 then DB.width=620 end
    if not DB.height or DB.height < 110 then DB.height=260 end
    Restore()
    win:Show()
end)

recoveryBtn:SetScript("OnDragStart",function(self)
    self:StartMoving()
end)

recoveryBtn:SetScript("OnDragStop",function(self)
    self:StopMovingOrSizing()
end)

local function ForceRecoverWindow()
    DB.enabled=true
    DB.showWindow=true

    local w=tonumber(DB.width) or 620
    local h=tonumber(DB.height) or 260
    if w < 300 or w > 1100 then DB.width=620 end
    if h < 110 or h > 700 then DB.height=260 end

    if not DB.point then
        DB.point="CENTER"
        DB.x=0
        DB.y=170
    end

    Restore()
    win:Show()
    recoveryBtn:Show()
end

SLASH_REMOTEWHO1="/rwho"
SlashCmdList["REMOTEWHO"]=function(msg)
    Print("WHO lookup is disabled in this stable build.")
end

SLASH_HORDERELAYRESET1="/hrreset"
SlashCmdList["HORDERELAYRESET"]=function()
    DB.enabled=true
    DB.showWindow=true
    DB.width=620
    DB.height=260
    DB.point="CENTER"
    DB.x=0
    DB.y=170
    DB.backgroundAlpha=0.85
    ForceRecoverWindow()
    Print("Relay window reset.")
end

SLASH_HORDERELAYDIAG1="/hrdiag"
SlashCmdList["HORDERELAYDIAG"]=function(msg)
    ApplyDefaults()
    msg=tostring(msg or ""):lower():match("^%s*(.-)%s*$")
    if msg=="debug" then
        DB.bnDebug=not DB.bnDebug
        Print("BNet receive debug="..tostring(DB.bnDebug))
        return
    end
    Print("Receiver diag:")
    Print("enabled="..tostring(DB.enabled).." showWindow="..tostring(DB.showWindow))
    Print("PREFIX="..PREFIX)
    if C_ChatInfo and C_ChatInfo.IsAddonMessagePrefixRegistered then
        Print("registered="..tostring(C_ChatInfo.IsAddonMessagePrefixRegistered(PREFIX)))
    else
        Print("IsAddonMessagePrefixRegistered unavailable")
    end
    Print("BNSendGameData="..tostring(BNSendGameData ~= nil))
    Print("C_BattleNet.SendGameData="..tostring(C_BattleNet and C_BattleNet.SendGameData ~= nil))
    Print("learned Alliance senderID="..tostring(allianceSenderGameAccountID))
    Print("current Alliance broadcaster/SPY="..tostring(allianceSpyCharacterName))
end

SLASH_HORDERELAYLOG1="/hrlog"
SlashCmdList["HORDERELAYLOG"]=function(msg)
    ApplyDefaults()
    msg=tostring(msg or ""):lower():match("^%s*(.-)%s*$")

    if msg=="on" then
        DB.spyChatLogging=true
        Print("Spy chat logging ON.")
        return
    elseif msg=="off" then
        DB.spyChatLogging=false
        Print("Spy chat logging OFF.")
        return
    elseif msg=="stats" or msg=="" then
        local days=0
        local lines=0
        local dropped=0
        for _, bucket in pairs(DB.spyChatLog or {}) do
            if type(bucket)=="table" then
                days=days+1
                lines=lines+#(bucket.entries or {})
                dropped=dropped+(tonumber(bucket.dropped) or 0)
            end
        end
        Print("Spy chat log: "..tostring(lines).." lines across "..tostring(days)
            .." day(s); dropped "..tostring(dropped)..". Logging="
            ..tostring(DB.spyChatLogging==true)..".")
        return
    end

    Print("Usage: /hrlog [stats|on|off]")
end

SLASH_HORDERELAY1="/hr"
SlashCmdList["HORDERELAY"]=function()
    if cfg:IsShown() then cfg:Hide() else cfg:Show() end
end

f:RegisterEvent("ADDON_LOADED")
f:RegisterEvent("PLAYER_LOGIN")
f:RegisterEvent("BN_CHAT_MSG_ADDON")
f:RegisterEvent("CHAT_MSG_ADDON")
f:RegisterEvent("BN_FRIEND_INFO_CHANGED")

f:SetScript("OnEvent",function(self,event,...)
    if event=="ADDON_LOADED" then
        local name=...
        if name==ADDON_NAME then ApplyDefaults(); Apply124Migration(); DB.bnDebug=false; RegisterPrefix() end
        return
    end
    if event=="PLAYER_LOGIN" then
        ApplyDefaults()
        Apply124Migration()
        DB.bnDebug=false
        RegisterPrefix()
        ForceRecoverWindow()
        StartConnectionMonitor()
        C_Timer.After(3,function() StartAllianceConnect(true) end)
        Print("Loaded. Auto-connect enabled; use Connect to Alliance as a fallback.")
        return
    end
    if event=="BN_FRIEND_INFO_CHANGED" then
        if not lastHeartbeat or (GetTime()-lastHeartbeat)>15 then
            C_Timer.After(1,function() StartAllianceConnect(true) end)
        end
        return
    end
    if event=="BN_CHAT_MSG_ADDON" then
        -- Classic Era/BNet builds can expose the sender gameAccountID in
        -- different argument positions. Parse the event defensively.
        local args={...}
        local prefix=args[1]
        local payload=args[2]
        local senderID=nil

        -- Prefer numeric values after prefix/payload. Ignore channel-like strings.
        for i=3,#args do
            local v=args[i]
            if type(v)=="number" then
                senderID=v
                break
            end
        end

        -- Some builds may provide the ID as a numeric string.
        if not senderID then
            for i=3,#args do
                local v=args[i]
                if type(v)=="string" and v:match("^%d+$") then
                    senderID=tonumber(v)
                    break
                end
            end
        end

        if DB and DB.bnDebug then
            Print("BN RX prefix="..tostring(prefix)
                .." senderID="..tostring(senderID)
                .." argc="..tostring(#args))
        end

        if prefix==PREFIX and payload then
            HandlePayload(payload,senderID)
        end
        return
    end

    if event=="CHAT_MSG_ADDON" then
        local prefix,payload,channel,sender=...
end
end)
