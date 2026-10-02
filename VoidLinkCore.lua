local ADDON_NAME = ...

VoidLinkDB = VoidLinkDB or {}
VoidLink = VoidLink or {}
local M = VoidLink
local DB = VoidLinkDB

local defaults = {
    mode = "receiver",
    minimapAngle = 225,
    chatLogging = true,
    chatRetentionDays = 30,
    chatMaxPerDay = 5000,
}

local function ApplyDefaults()
    for k,v in pairs(defaults) do
        if DB[k] == nil then DB[k] = v end
    end
    if DB.mode ~= "sender" and DB.mode ~= "receiver" then
        DB.mode = "receiver"
    end
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
    if keepDays < 1 then keepDays = 1 end
    local cutoff = time() - (keepDays * 86400)

    for dayKey,bucket in pairs(DB.chatLog) do
        local epoch = type(bucket) == "table" and tonumber(bucket.epoch) or nil
        if epoch and epoch < cutoff then
            DB.chatLog[dayKey] = nil
        end
    end
end

function M:LogChat(kind, zone, author, text, direction)
    if not DB.chatLogging or not self:IsSender() then return end
    if kind ~= "GEN" and kind ~= "LD" and kind ~= "PARTY"
       and kind ~= "DM" and kind ~= "DMOUT" then
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
        time = date("%H:%M"),
        kind = kind,
        zone = tostring(zone or ""),
        author = tostring(author or ""),
        direction = tostring(direction or ""),
        text = tostring(text or ""),
    }
end

local panel = CreateFrame("Frame","VoidLinkControlPanel",UIParent,"BackdropTemplate")
panel:SetSize(340,260)
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
    if DB.mode == mode then return end
    DB.mode = mode
    if ReloadUI then
        ReloadUI()
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
chatBtn:SetSize(230,28)
chatBtn:SetPoint("TOP",0,-188)
chatBtn:SetText("Show / Hide Chat Window")
chatBtn:SetScript("OnClick",function()
    if _G.VoidLink_ToggleReceiverWindow then
        _G.VoidLink_ToggleReceiverWindow()
    end
end)

local closeBtn = CreateFrame("Button",nil,panel,"UIPanelButtonTemplate")
closeBtn:SetSize(80,24)
closeBtn:SetPoint("BOTTOM",0,16)
closeBtn:SetText("Close")
closeBtn:SetScript("OnClick",function() panel:Hide() end)

local function RefreshPanel()
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
minimapButton:RegisterForClicks("LeftButtonUp")
minimapButton:RegisterForDrag("LeftButton")
minimapButton:SetHighlightTexture("Interface\\Minimap\\UI-Minimap-ZoomButton-Highlight")

local border = minimapButton:CreateTexture(nil,"OVERLAY")
border:SetSize(53,53)
border:SetPoint("TOPLEFT")
border:SetTexture("Interface\\Minimap\\MiniMap-TrackingBorder")

local icon = minimapButton:CreateTexture(nil,"BACKGROUND")
icon:SetSize(20,20)
icon:SetPoint("CENTER",0,1)
icon:SetTexture("Interface\\TargetingFrame\\UI-RaidTargetingIcon_8")
icon:SetTexCoord(0,1,0,1)

local function UpdateMinimapPosition()
    local angle = math.rad(tonumber(DB.minimapAngle) or 225)
    local radius = 80
    minimapButton:ClearAllPoints()
    minimapButton:SetPoint("CENTER",Minimap,"CENTER",math.cos(angle)*radius,math.sin(angle)*radius)
end

minimapButton:SetScript("OnDragStart",function(self)
    self:SetScript("OnUpdate",function()
        local mx,my = Minimap:GetCenter()
        local scale = Minimap:GetEffectiveScale()
        local cx,cy = GetCursorPosition()
        cx,cy = cx/scale,cy/scale
        DB.minimapAngle = math.deg(math.atan2(cy-my,cx-mx))
        UpdateMinimapPosition()
    end)
end)

minimapButton:SetScript("OnDragStop",function(self)
    self:SetScript("OnUpdate",nil)
end)

minimapButton:SetScript("OnClick",function()
    if panel:IsShown() then panel:Hide() else panel:Show() end
end)

minimapButton:SetScript("OnEnter",function(self)
    GameTooltip:SetOwner(self,"ANCHOR_LEFT")
    GameTooltip:SetText("VoidLink")
    GameTooltip:AddLine("Mode: "..tostring(DB.mode),1,1,1)
    GameTooltip:AddLine("Click: settings",0.8,0.8,0.8)
    GameTooltip:AddLine("Drag: move icon",0.8,0.8,0.8)
    GameTooltip:Show()
end)
minimapButton:SetScript("OnLeave",function() GameTooltip:Hide() end)

UpdateMinimapPosition()

SLASH_VOIDLINK1="/voidlink"
SlashCmdList["VOIDLINK"]=function()
    if panel:IsShown() then panel:Hide() else panel:Show() end
end
