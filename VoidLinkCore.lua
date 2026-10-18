-- Repushed banner-panic minimap skull crop: 2026-10-02
local ADDON_NAME = ...

VoidLinkDB = VoidLinkDB or {}
VoidLinkMode = VoidLinkMode or nil
VoidLink = VoidLink or {}
local M = VoidLink
local DB = VoidLinkDB

local defaults = {
    minimapAngle = 225,
    chatLogging = true,
    nativeChatLogging = true,
    chatRetentionDays = 0, -- 0 = never delete history by age
    chatMaxPerDay = 5000,
    independentPairing = false,
    privatePairCode = "",
}

-- The default role follows the logged-in character's faction.
-- Manual role changes are stored per character so changing one character
-- cannot accidentally change the role of characters on the other faction.
local function CharacterKey()
    local name = UnitName("player")
    if not name or name == "" then return nil end
    return tostring(GetRealmName() or "") .. ":" .. name
end

local function FactionMode()
    local faction = UnitFactionGroup("player")
    if faction == "Alliance" then return "sender" end
    if faction == "Horde" then return "receiver" end
    return nil
end

local function ApplyDefaults()
    for k,v in pairs(defaults) do
        if DB[k] == nil then DB[k] = v end
    end

    -- One-time migration: the original 30-day default must not silently
    -- continue deleting old records for players upgrading the addon.
    if not DB.archiveKeepForeverMigrated then
        if DB.chatRetentionDays == 30 or DB.chatRetentionDays == nil then DB.chatRetentionDays = 0 end
        DB.archiveKeepForeverMigrated = true
    end

    local key = CharacterKey()
    local overrides = DB.characterModeOverrides
    local override = key and type(overrides) == "table" and overrides[key]
    local mode = (override == "sender" or override == "receiver") and override or FactionMode()

    -- The faction may not yet be known while Lua files first load.
    -- PLAYER_LOGIN reapplies this once the character is available.
    if not mode then
        mode = (DB.mode == "sender" or DB.mode == "receiver") and DB.mode or "receiver"
    end
    DB.mode = mode
    VoidLinkMode = mode
end

ApplyDefaults()

function M:IsSender()
    return DB.mode == "sender"
end

function M:IsReceiver()
    return DB.mode == "receiver"
end

function M:GetMode()
    return DB.mode
end

local function DayKey(epoch)
    return date("%Y-%m-%d", tonumber(epoch) or time())
end

local function PruneChatLog(currentDay)
    DB.chatLog = DB.chatLog or {}
    if DB._lastChatPruneDay == currentDay then return end
    DB._lastChatPruneDay = currentDay

    local keepDays = tonumber(DB.chatRetentionDays) or 30
    if keepDays <= 0 then return end -- permanent archive
    local cutoff = time() - (keepDays * 86400)

    for dayKey,bucket in pairs(DB.chatLog) do
        local epoch = type(bucket) == "table" and tonumber(bucket.epoch) or nil
        if epoch and epoch < cutoff then
            DB.chatLog[dayKey] = nil
        end
    end
end

function M:LogChat(kind, zone, author, text, direction)
    if not DB.chatLogging then return end
    if kind ~= "GEN" and kind ~= "LD" and kind ~= "PARTY"
       and kind ~= "DM" and kind ~= "DMOUT" and kind ~= "GUILD"
       and kind ~= "RAID" and kind ~= "SAY" and kind ~= "YELL"
       and kind ~= "CHANNEL" then
        return
    end

    DB.chatLog = DB.chatLog or {}
    local now = time()
    local dayKey = DayKey(now)
    PruneChatLog(dayKey)

    local bucket = DB.chatLog[dayKey]
    if type(bucket) ~= "table" then
        bucket = { epoch = now, count = 0, dropped = 0, entries = {} }
        DB.chatLog[dayKey] = bucket
    end

    bucket.entries = bucket.entries or {}
    bucket.count = tonumber(bucket.count) or #bucket.entries
    bucket.dropped = tonumber(bucket.dropped) or 0

    local maxPerDay = tonumber(DB.chatMaxPerDay) or 5000
    if maxPerDay < 100 then maxPerDay = 100 end
    if #bucket.entries >= maxPerDay then
        bucket.dropped = bucket.dropped + 1
        return
    end

    bucket.count = bucket.count + 1
    bucket.entries[#bucket.entries + 1] = {
        t = now,
        time = date("%H:%M:%S", now),
        observer = tostring(UnitName("player") or ""),
        realm = tostring(GetRealmName() or ""),
        kind = kind,
        zone = tostring(zone or ""),
        author = tostring(author or ""),
        direction = tostring(direction or ""),
        text = tostring(text or ""),
    }
end

function M:GetTransportPrefix()
    if not DB.independentPairing then return "AHREL1" end
    local code=tostring(DB.privatePairCode or ""):upper()
    if #code<6 or #code>12 or not code:match("^[A-Z0-9]+$") then return nil end
    return "VL"..code
end

local panel = CreateFrame("Frame","VoidLinkControlPanel",UIParent,"BackdropTemplate")
panel:SetSize(360,355)
panel:SetPoint("CENTER")
panel:SetFrameStrata("DIALOG")
panel:SetMovable(true)
panel:SetClampedToScreen(true)
panel:SetBackdrop({
    bgFile="Interface\\DialogFrame\\UI-DialogBox-Background",
    edgeFile="Interface\\Tooltips\\UI-Tooltip-Border",
    tile=true,tileSize=16,edgeSize=14,
    insets={left=4,right=4,top=4,bottom=4}
})
panel:Hide()

local title = panel:CreateFontString(nil,"OVERLAY","GameFontNormalLarge")
title:SetPoint("TOP",0,-16)
title:SetText("VoidLink")

local modeText = panel:CreateFontString(nil,"OVERLAY","GameFontHighlight")
modeText:SetPoint("TOP",0,-48)

local hint = panel:CreateFontString(nil,"OVERLAY","GameFontHighlightSmall")
hint:SetPoint("TOP",0,-70)
hint:SetWidth(300)
hint:SetText("Choose which role this client runs. The selection is saved.")

local function SetMode(mode)
    if mode ~= "sender" and mode ~= "receiver" then return end

    -- Write through both the local table reference and the SavedVariables
    -- globals before reloading. The dedicated scalar prevents the client from
    -- falling back to receiver if the table is rebuilt during reload.
    local key = CharacterKey()
    if key then
        DB.characterModeOverrides = DB.characterModeOverrides or {}
        DB.characterModeOverrides[key] = mode
    end
    DB.mode = mode
    VoidLinkDB = VoidLinkDB or DB or {}
    VoidLinkDB.mode = mode
    VoidLinkMode = mode

    modeText:SetText("Active mode: |cffffffff"..string.upper(mode).."|r")

    if ReloadUI then
        C_Timer.After(0, ReloadUI)
    end
end

local senderBtn = CreateFrame("Button",nil,panel,"UIPanelButtonTemplate")
senderBtn:SetSize(130,28)
senderBtn:SetPoint("TOPLEFT",30,-102)
senderBtn:SetText("Use Sender")
senderBtn:SetScript("OnClick",function() SetMode("sender") end)

local receiverBtn = CreateFrame("Button",nil,panel,"UIPanelButtonTemplate")
receiverBtn:SetSize(130,28)
receiverBtn:SetPoint("TOPRIGHT",-30,-102)
receiverBtn:SetText("Use Receiver")
receiverBtn:SetScript("OnClick",function() SetMode("receiver") end)

local senderSettings = CreateFrame("Button",nil,panel,"UIPanelButtonTemplate")
senderSettings:SetSize(130,26)
senderSettings:SetPoint("TOPLEFT",30,-145)
senderSettings:SetText("Sender Settings")
senderSettings:SetScript("OnClick",function()
    if _G.VoidLink_OpenSenderSettings then _G.VoidLink_OpenSenderSettings() end
end)

local receiverSettings = CreateFrame("Button",nil,panel,"UIPanelButtonTemplate")
receiverSettings:SetSize(130,26)
receiverSettings:SetPoint("TOPRIGHT",-30,-145)
receiverSettings:SetText("Receiver Settings")
receiverSettings:SetScript("OnClick",function()
    if _G.VoidLink_OpenReceiverSettings then _G.VoidLink_OpenReceiverSettings() end
end)

local chatBtn = CreateFrame("Button",nil,panel,"UIPanelButtonTemplate")
chatBtn:SetSize(160,28)
chatBtn:SetPoint("TOPLEFT",20,-188)
chatBtn:SetText("Show / Hide Chat Window")
chatBtn:SetScript("OnClick",function()
    if _G.VoidLink_ToggleReceiverWindow then
        _G.VoidLink_ToggleReceiverWindow()
    end
end)

local archiveBtn=CreateFrame("Button",nil,panel,"UIPanelButtonTemplate")
archiveBtn:SetSize(145,28)
archiveBtn:SetPoint("TOPRIGHT",-20,-188)
archiveBtn:SetText("Chat Archive")
archiveBtn:SetScript("OnClick",function() if VoidLink_OpenArchive then VoidLink_OpenArchive() end end)

local privateToggle=CreateFrame("CheckButton",nil,panel,"UICheckButtonTemplate")
privateToggle:SetPoint("TOPLEFT",22,-222)
privateToggle:SetSize(26,26)
local privateLabel=panel:CreateFontString(nil,"OVERLAY","GameFontHighlight")
privateLabel:SetPoint("LEFT",privateToggle,"RIGHT",5,0)
privateLabel:SetText("Independent pairing")
local privateHint=panel:CreateFontString(nil,"OVERLAY","GameFontHighlightSmall")
privateHint:SetPoint("TOPLEFT",30,-255)
privateHint:SetText("Same code on BOTH accounts (6-12 letters/numbers):")
local privateCode=CreateFrame("EditBox",nil,panel,"InputBoxTemplate")
privateCode:SetSize(165,24)
privateCode:SetPoint("TOPLEFT",36,-277)
privateCode:SetAutoFocus(false)
privateCode:SetMaxLetters(12)
privateCode:SetScript("OnEscapePressed",function(self) self:ClearFocus() end)
local privateSave=CreateFrame("Button",nil,panel,"UIPanelButtonTemplate")
privateSave:SetSize(110,25)
privateSave:SetPoint("LEFT",privateCode,"RIGHT",14,0)
privateSave:SetText("Save / Reload")
privateSave:SetScript("OnClick",function()
    local enabled=privateToggle:GetChecked() and true or false
    local code=tostring(privateCode:GetText() or ""):upper():gsub("%s+","")
    if enabled and (#code<6 or #code>12 or not code:match("^[A-Z0-9]+$")) then
        DEFAULT_CHAT_FRAME:AddMessage("|cffff5555VoidLink:|r Enter a valid 6-12 character code.")
        return
    end
    DB.privatePairCode=code
    DB.independentPairing=enabled
    if ReloadUI then ReloadUI() end
end)

local closeBtn = CreateFrame("Button",nil,panel,"UIPanelButtonTemplate")
closeBtn:SetSize(80,24)
closeBtn:SetPoint("BOTTOM",0,16)
closeBtn:SetText("Close")
closeBtn:SetScript("OnClick",function() panel:Hide() end)

local function RefreshPanel()
    privateToggle:SetChecked(DB.independentPairing and true or false)
    privateCode:SetText(tostring(DB.privatePairCode or ""))
    modeText:SetText("Active mode: |cffffffff"..string.upper(DB.mode or "receiver").."|r")
    senderBtn:SetEnabled(DB.mode ~= "sender")
    receiverBtn:SetEnabled(DB.mode ~= "receiver")
    senderSettings:SetEnabled(DB.mode == "sender")
    receiverSettings:SetEnabled(DB.mode == "receiver")
    chatBtn:SetEnabled(DB.mode == "receiver")
end

panel:SetScript("OnShow",RefreshPanel)

local drag = CreateFrame("Frame",nil,panel)
drag:SetPoint("TOPLEFT",6,-5)
drag:SetPoint("TOPRIGHT",-6,-5)
drag:SetHeight(34)
drag:EnableMouse(true)
drag:RegisterForDrag("LeftButton")
drag:SetScript("OnDragStart",function() panel:StartMoving() end)
drag:SetScript("OnDragStop",function() panel:StopMovingOrSizing() end)

local minimapButton = CreateFrame("Button","VoidLinkMinimapButton",Minimap)
minimapButton:SetSize(31,31)
minimapButton:SetFrameStrata("MEDIUM")
minimapButton:SetFrameLevel(8)
minimapButton:RegisterForClicks("LeftButtonUp","RightButtonUp")
minimapButton:RegisterForDrag("LeftButton")
minimapButton:SetHighlightTexture("Interface\\Minimap\\UI-Minimap-ZoomButton-Highlight")

local border = minimapButton:CreateTexture(nil,"OVERLAY")
border:SetSize(53,53)
border:SetPoint("TOPLEFT")
border:SetTexture("Interface\\Minimap\\MiniMap-TrackingBorder")

local icon = minimapButton:CreateTexture(nil,"BACKGROUND")
icon:SetSize(20,20)
icon:SetPoint("CENTER",0,1)
-- Use the skull badge from VoidMark's custom Banner panic artwork.
-- The banner is 300x150; this crops its left skull/badge section into the
-- square minimap icon instead of using the generic Blizzard raid skull.
icon:SetTexture("Interface\\AddOns\\VoidMark\\Media\\Panic\\panic_banner.tga")
icon:SetTexCoord(0.02,0.38,0.10,0.90)

local MINIMAP_RADIUS = 80
local MINIMAP_EDGE_PAD = 2

local function IsSquareMinimap()
    if type(GetMinimapShape) == "function" then
        local ok, shape = pcall(GetMinimapShape)
        if ok and type(shape) == "string" then
            shape = shape:upper()
            if shape:find("SQUARE", 1, true) then return true end
            if shape == "ROUND" then return false end
        end
    end

    -- ElvUI's Classic minimap is square even when the Blizzard shape hint
    -- still reports ROUND or is unavailable.
    if type(_G.ElvUI) == "table" then return true end

    return false
end

local function SquareOffset(angle)
    local dx,dy = math.cos(angle),math.sin(angle)
    local halfW = ((Minimap and Minimap:GetWidth()) or (MINIMAP_RADIUS*2))*0.5 + MINIMAP_EDGE_PAD
    local halfH = ((Minimap and Minimap:GetHeight()) or (MINIMAP_RADIUS*2))*0.5 + MINIMAP_EDGE_PAD

    local ax,ay = math.abs(dx),math.abs(dy)
    local tx = ax > 0.0001 and (halfW/ax) or math.huge
    local ty = ay > 0.0001 and (halfH/ay) or math.huge
    local t = math.min(tx,ty)

    return dx*t,dy*t
end

local function Atan2(y,x)
    if math.atan2 then return math.atan2(y,x) end
    if x > 0 then return math.atan(y/x) end
    if x < 0 and y >= 0 then return math.atan(y/x)+math.pi end
    if x < 0 and y < 0 then return math.atan(y/x)-math.pi end
    if x == 0 and y > 0 then return math.pi/2 end
    if x == 0 and y < 0 then return -math.pi/2 end
    return 0
end

local function UpdateMinimapPosition()
    local angle = math.rad(tonumber(DB.minimapAngle) or 225)
    local x,y

    if IsSquareMinimap() then
        x,y = SquareOffset(angle)
    else
        x,y = math.cos(angle)*MINIMAP_RADIUS,math.sin(angle)*MINIMAP_RADIUS
    end

    minimapButton:ClearAllPoints()
    minimapButton:SetPoint("CENTER",Minimap,"CENTER",x,y)
end

minimapButton:SetScript("OnDragStart",function(self)
    self:SetScript("OnUpdate",function()
        local mx,my = Minimap:GetCenter()
        local scale = UIParent:GetEffectiveScale()
        local cx,cy = GetCursorPosition()
        if not mx or not my or not cx or not cy or not scale or scale == 0 then return end
        cx,cy = cx/scale,cy/scale
        DB.minimapAngle = math.deg(Atan2(cy-my,cx-mx))
        UpdateMinimapPosition()
    end)
end)

minimapButton:SetScript("OnDragStop",function(self)
    self:SetScript("OnUpdate",nil)
end)

minimapButton:SetScript("OnClick",function(self,button)
    if button=="RightButton" then
        if _G.VoidLink_OpenReceiverWindow then
            _G.VoidLink_OpenReceiverWindow()
        end
        return
    end
    if panel:IsShown() then panel:Hide() else panel:Show() end
end)

minimapButton:SetScript("OnEnter",function(self)
    GameTooltip:SetOwner(self,"ANCHOR_LEFT")
    GameTooltip:SetText("VoidLink")
    GameTooltip:AddLine("Mode: "..tostring(DB.mode),1,1,1)
    GameTooltip:AddLine("Left-click: settings",0.8,0.8,0.8)
    GameTooltip:AddLine("Right-click: open chat",0.8,0.8,0.8)
    GameTooltip:AddLine("Drag: move icon",0.8,0.8,0.8)
    GameTooltip:Show()
end)
minimapButton:SetScript("OnLeave",function() GameTooltip:Hide() end)

UpdateMinimapPosition()

SLASH_VOIDLINK1="/voidlink"
local function LogPrint(message)
    DEFAULT_CHAT_FRAME:AddMessage("|cffb080ffVoidLink:|r "..message)
end

local function StartNativeLog()
    if DB.nativeChatLogging and type(LoggingChat) == "function" then
        local ok = pcall(LoggingChat, true)
        if not ok then LogPrint("Text logging could not start. Try /chatlog.") end
    end
end

function M:GetChatTranscript(day)
    day = day or DayKey(time())
    local rows = {}
    local function Collect(log, source)
        local bucket = type(log) == "table" and log[day]
        if type(bucket) ~= "table" then return end
        for _, entry in ipairs(bucket.entries or {}) do
            rows[#rows+1] = {entry=entry, source=source}
        end
    end
    Collect(DB.chatLog, "local")
    Collect(HordeRelayReceiverDB and HordeRelayReceiverDB.spyChatLog, "relay")
    table.sort(rows, function(a,b) return (tonumber(a.entry.t) or 0) < (tonumber(b.entry.t) or 0) end)
    local lines = {"VoidLink chat history - "..day}
    for _, row in ipairs(rows) do
        local e = row.entry
        local stamp = tonumber(e.t) and date("%H:%M:%S", e.t) or tostring(e.time or "")
        lines[#lines+1] = string.format("[%s] [%s] [%s] [%s] %s: %s",
            stamp, row.source, tostring(e.kind or ""), tostring(e.zone or ""),
            tostring(e.author or ""), tostring(e.text or ""))
    end
    if #rows == 0 then lines[#lines+1] = "No saved messages for this date." end
    return table.concat(lines, "\n"), #rows
end

local exportWindow
local function ShowExport(day)
    if not exportWindow then
        exportWindow = CreateFrame("Frame", "VoidLinkExportWindow", UIParent, "BackdropTemplate")
        exportWindow:SetSize(700, 480)
        exportWindow:SetPoint("CENTER")
        exportWindow:SetFrameStrata("DIALOG")
        exportWindow:SetBackdrop({bgFile="Interface\\DialogFrame\\UI-DialogBox-Background"})
        local label = exportWindow:CreateFontString(nil,"OVERLAY","GameFontNormal")
        label:SetPoint("TOP",0,-12)
        label:SetText("Chat export: Ctrl+A, Ctrl+C, then paste into Notepad")
        local scroll = CreateFrame("ScrollFrame",nil,exportWindow,"UIPanelScrollFrameTemplate")
        scroll:SetPoint("TOPLEFT",16,-40)
        scroll:SetPoint("BOTTOMRIGHT",-36,44)
        local edit = CreateFrame("EditBox",nil,scroll)
        edit:SetMultiLine(true)
        edit:SetAutoFocus(false)
        edit:SetFontObject(ChatFontNormal)
        edit:SetWidth(640)
        edit:SetScript("OnEscapePressed",function() exportWindow:Hide() end)
        scroll:SetScrollChild(edit)
        exportWindow.edit = edit
        local close = CreateFrame("Button",nil,exportWindow,"UIPanelButtonTemplate")
        close:SetSize(80,24)
        close:SetPoint("BOTTOM",0,12)
        close:SetText("Close")
        close:SetScript("OnClick",function() exportWindow:Hide() end)
    end
    local transcript = M:GetChatTranscript(day)
    exportWindow.edit:SetText(transcript)
    exportWindow:Show()
    exportWindow.edit:SetFocus()
    exportWindow.edit:HighlightText()
end


-- Search the existing saved chat logs. Never create a duplicate archive.
local archiveFrame
local function ShowArchive()
    if not archiveFrame then
        local f=CreateFrame("Frame","VoidLinkArchiveWindow",UIParent,"BackdropTemplate")
        archiveFrame=f
        f:SetSize(750,540)
        f:SetPoint("CENTER")
        f:SetFrameStrata("DIALOG")
        f:SetMovable(true)
        f:EnableMouse(true)
        f:RegisterForDrag("LeftButton")
        f:SetClampedToScreen(true)
        f:SetScript("OnDragStart",function(self) self:StartMoving() end)
        f:SetScript("OnDragStop",function(self) self:StopMovingOrSizing() end)
        f:SetBackdrop({bgFile="Interface\\DialogFrame\\UI-DialogBox-Background",edgeFile="Interface\\Tooltips\\UI-Tooltip-Border",edgeSize=14,
            insets={left=4,right=4,top=4,bottom=4}})
        local heading=f:CreateFontString(nil,"OVERLAY","GameFontNormalLarge")
        heading:SetPoint("TOP",0,-16)
        heading:SetText("VoidLink Chat Archive")
        local hint=f:CreateFontString(nil,"OVERLAY","GameFontHighlightSmall")
        hint:SetPoint("TOPLEFT",20,-42)
        hint:SetText("Search player or message. Date: YYYY-MM-DD (optional). Results can be copied with Ctrl+A, Ctrl+C.")
        local function MakeInput(x,w,placeholder)
            local edit=CreateFrame("EditBox",nil,f,"InputBoxTemplate")
            edit:SetSize(w,25)
            edit:SetPoint("TOPLEFT",x,-72)
            edit:SetAutoFocus(false)
            edit:SetScript("OnEscapePressed",function(self) self:ClearFocus() end)
            edit:SetText("")
            local label=f:CreateFontString(nil,"OVERLAY","GameFontNormalSmall")
            label:SetPoint("BOTTOMLEFT",edit,"TOPLEFT",0,3)
            label:SetText(placeholder)
            return edit
        end
        local search=MakeInput(20,400,"Player / keyword")
        local day=MakeInput(435,130,"Date (optional)")
        local channel=MakeInput(575,85,"Channel")
        local results=f:CreateFontString(nil,"OVERLAY","GameFontHighlightSmall")
        results:SetPoint("TOPLEFT",20,-117)
        results:SetText("Enter search criteria or leave blank for recent messages.")
        local scroll=CreateFrame("ScrollFrame",nil,f,"UIPanelScrollFrameTemplate")
        scroll:SetPoint("TOPLEFT",20,-139)
        scroll:SetPoint("BOTTOMRIGHT",-42,54)
        local edit=CreateFrame("EditBox",nil,scroll)
        edit:SetMultiLine(true)
        edit:SetAutoFocus(false)
        edit:SetFontObject(ChatFontNormal)
        edit:SetWidth(665)
        edit:SetScript("OnEscapePressed",function(self) self:ClearFocus() end)
        scroll:SetScrollChild(edit)
        local function Refresh()
            local q=search:GetText():lower()
            local dateFilter=day:GetText()
            local channelFilter=channel:GetText():lower()
            local rows={}
            local function Collect(log,source)
                if type(log)~="table" then return end
                for dateKey,bucket in pairs(log) do
                    if (dateFilter=="" or dateKey==dateFilter) and type(bucket)=="table" then
                        for _,entry in ipairs(bucket.entries or {}) do
                            local name=tostring(entry.author or "")
                            local message=tostring(entry.text or "")
                            local kind=tostring(entry.kind or "")
                            if (q=="" or name:lower():find(q,1,true) or message:lower():find(q,1,true))
                                and (channelFilter=="" or kind:lower():find(channelFilter,1,true)) then
                                rows[#rows+1]={entry=entry,source=source,day=dateKey}
                            end
                        end
                    end
                end
            end
            Collect(DB.chatLog,"local")
            Collect(HordeRelayReceiverDB and HordeRelayReceiverDB.spyChatLog,"relay")
            table.sort(rows,function(a,b)
                local at,bt=tonumber(a.entry.t) or 0,tonumber(b.entry.t) or 0
                if at~=bt then return at>bt end
                return tostring(a.day)>tostring(b.day)
            end)
            local lines={}
            local count=math.min(#rows,300)
            for i=1,count do
                local row=rows[i];local e=row.entry
                local stamp=tonumber(e.t) and date("%Y-%m-%d %H:%M:%S",e.t)
                    or (row.day.." "..tostring(e.time or ""))
                lines[#lines+1]=string.format("[%s] [%s] [%s] %s: %s",
                    stamp,row.source,tostring(e.kind or ""),tostring(e.author or ""),tostring(e.text or ""))
            end
            if count==0 then lines[1]="No matching saved messages." end
            edit:SetText(table.concat(lines,"\n"))
            edit:SetCursorPosition(0)
            results:SetText("Matches: "..#rows.." | Showing newest "..count.." | Select text, Ctrl+C to copy")
            scroll:SetVerticalScroll(0)
        end
        local find=CreateFrame("Button",nil,f,"UIPanelButtonTemplate")
        find:SetSize(80,25)
        find:SetPoint("TOPLEFT",666,-72)
        find:SetText("Search")
        find:SetScript("OnClick",Refresh)
        for _,input in ipairs({search,day,channel}) do
            input:SetScript("OnEnterPressed",function(self) self:ClearFocus(); Refresh() end)
        end
        local copy=CreateFrame("Button",nil,f,"UIPanelButtonTemplate")
        copy:SetSize(130,26)
        copy:SetPoint("BOTTOMLEFT",20,14)
        copy:SetText("Select All / Copy")
        copy:SetScript("OnClick",function() edit:SetFocus();edit:HighlightText() end)
        local close=CreateFrame("Button",nil,f,"UIPanelButtonTemplate")
        close:SetSize(85,26)
        close:SetPoint("BOTTOMRIGHT",-20,14)
        close:SetText("Close")
        close:SetScript("OnClick",function() f:Hide() end)
        f.RefreshArchive=Refresh
    end
    archiveFrame:Show()
    archiveFrame:RefreshArchive()
end

_G.VoidLink_OpenArchive=ShowArchive

-- Record directly from chat events, independently of role, relay connection,
-- relay filters and faction. Own messages must be retained for conversations.
local logger = CreateFrame("Frame")
logger:RegisterEvent("PLAYER_LOGIN")
local chatKinds = {
    CHAT_MSG_PARTY="PARTY", CHAT_MSG_PARTY_LEADER="PARTY",
    CHAT_MSG_RAID="RAID", CHAT_MSG_RAID_LEADER="RAID", CHAT_MSG_RAID_WARNING="RAID",
    CHAT_MSG_GUILD="GUILD", CHAT_MSG_WHISPER="DM", CHAT_MSG_WHISPER_INFORM="DMOUT",
    CHAT_MSG_SAY="SAY", CHAT_MSG_YELL="YELL", CHAT_MSG_CHANNEL="CHANNEL",
}
for event in pairs(chatKinds) do logger:RegisterEvent(event) end
logger:SetScript("OnEvent",function(_,event,...)
    if event == "PLAYER_LOGIN" then
        ApplyDefaults()
        StartNativeLog()
        LogPrint("Chat archive "..(DB.chatLogging and "ON" or "OFF")..
            "; text log "..((type(LoggingChat)=="function" and LoggingChat()) and "ON" or "OFF")..
            ". /voidlink log shows status; /voidlink export copies history.")
        return
    end
    local text, author, _, channelName, _, _, _, _, channelBaseName = ...
    local kind = chatKinds[event]
    if event == "CHAT_MSG_CHANNEL" then
        local channel = tostring(channelBaseName or channelName or ""):lower():gsub("%s+", "")
        if channel:find("localdefense",1,true) then kind="LD"
        elseif channel:find("general",1,true) then kind="GEN" end
    end
    M:LogChat(kind, GetRealZoneText() or "", author, text,
        event == "CHAT_MSG_WHISPER_INFORM" and "OUT" or "IN")
end)

SlashCmdList["VOIDLINK"]=function(message)
    local command, arg = tostring(message or ""):match("^(%S*)%s*(.-)$")
    command = command:lower()
    if command == "export" then
        if arg ~= "" and not arg:match("^%d%d%d%d%-%d%d%-%d%d$") then
            LogPrint("Use /voidlink export YYYY-MM-DD (or omit date for today).")
            return
        end
        ShowExport(arg ~= "" and arg or nil)
    elseif command == "archive" or command == "search" then
        ShowArchive()
    elseif command == "log" then
        if arg == "on" or arg == "off" then
            DB.chatLogging = arg == "on"
            DB.nativeChatLogging = DB.chatLogging
            if type(LoggingChat)=="function" then pcall(LoggingChat, DB.nativeChatLogging) end
        end
        local _, count = M:GetChatTranscript()
        LogPrint("Archive "..(DB.chatLogging and "ON" or "OFF").."; today: "..count..
            " messages. Text log "..((type(LoggingChat)=="function" and LoggingChat()) and "ON" or "OFF")..
            ": Logs\\WoWChatLog.txt. SavedVariables flush on /reload or logout.")
    else
        if panel:IsShown() then panel:Hide() else panel:Show() end
    end
end
