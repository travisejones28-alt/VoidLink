-- Run from the repository root: lua tests/guild_forwarding.lua
-- Exercises real receiver events with a small UI/transport mock.
-- Server delivery and protected execution still require the WoW client.
local state = {now=100, frames={}, sent={}, chat={}, grouped=false, raid=false, guild=true}
local noop = function() end
local methods = {}
setmetatable(methods, {__index=function(_, key)
    if key:match('^Set') or key:match('^Register') or key:match('^Enable')
       or key:match('^Clear') or key:match('^Start') or key:match('^Stop') then
        return noop
    end
end})
local function frame(name)
    local f = setmetatable({name=name, scripts={}, events={}, shown=false}, {__index=methods})
    state.frames[#state.frames+1] = f
    if name then _G[name]=f end
    return f
end
function methods:SetScript(key, fn) self.scripts[key]=fn end
function methods:RegisterEvent(event) self.events[event]=true end
function methods:UnregisterEvent(event) self.events[event]=nil end
function methods:CreateFontString()
    local f=frame(); f.parent=self; return f
end
methods.CreateTexture = methods.CreateFontString
function methods:Show() self.shown=true end
function methods:Hide() self.shown=false end
function methods:IsShown() return self.shown end
function methods:SetText(text) self.text=text end
function methods:GetName() return self.name end
function methods:GetWidth() return 620 end
function methods:GetHeight() return 260 end
function methods:GetFrameLevel() return 1 end
function methods:AddMessage(msg) state.chat[#state.chat+1]=msg end
function methods:SetChecked(value) self.checked=value end
function methods:GetChecked() return self.checked end
CreateFrame = function(_, name, parent, template)
    local f=frame(name)
    f.parent=parent
    if template=='OptionsSliderTemplate' then
        for _,suffix in ipairs({'Low','High','Text'}) do frame(name..suffix) end
    end
    return f
end
UIParent=frame('UIParent')
DEFAULT_CHAT_FRAME=frame('DEFAULT_CHAT_FRAME')
SlashCmdList={}
UIDropDownMenu_SetWidth=noop
UIDropDownMenu_Initialize=noop
UIDropDownMenu_SetText=noop
UIDropDownMenu_JustifyText=noop
UIDropDownMenu_CreateInfo=function() return {} end
UIDropDownMenu_AddButton=noop
LE_PARTY_CATEGORY_HOME=1
GetTime=function() return state.now end
time=function(t) return t and os.time(t) or 1791081000 end
date=os.date
GetZoneText=function() return 'Redridge Mountains' end
GetRealZoneText=GetZoneText
UnitFactionGroup=function() return 'Horde' end
UnitName=function() return 'Taliaa' end
IsInGroup=function() return state.grouped end
IsInRaid=function() return state.raid end
IsInGuild=function() return state.guild end
C_Timer={After=noop, NewTicker=function() return {Cancel=noop} end}
local function send(msg, channel)
    state.sent[#state.sent+1]={msg=msg, channel=channel}
end
C_ChatInfo={RegisterAddonMessagePrefix=noop, SendChatMessage=send}
SendChatMessage=nil -- Modern client with deprecation fallbacks disabled.
assert(loadfile('HordeRelayReceiver.lua'))('VoidLink')
local function emit(event, ...)
    for _,f in ipairs(state.frames) do
        if f.events[event] and f.scripts.OnEvent then f.scripts.OnEvent(f,event,...) end
    end
end
emit('ADDON_LOADED', 'VoidLink')
local DB=HordeRelayReceiverDB
local sequence=0
local function packet(kind, zone, text, author)
    sequence=sequence+1
    return table.concat({'AM',kind or 'GEN',zone or 'Redridge Mountains',author or 'Enemy',
        '60','Priest','21:38',text or ('relay '..sequence),'AllianceSpy'}, '\031')
end
local function receive(kind,zone,text)
    emit('BN_CHAT_MSG_ADDON','AHREL1',packet(kind,zone,text),123)
end
local function reset()
    state.now=state.now+10
    state.sent={}; state.chat={}
    state.grouped=false; state.raid=false; state.guild=true
    C_ChatInfo=C_ChatInfo or {RegisterAddonMessagePrefix=noop}
    C_ChatInfo.SendChatMessage=send; SendChatMessage=nil
    DB.enabled=true; DB.guildRelay=true; DB.partyRelay=false; DB.raidRelay=false
    DB.onlyCurrentZone=false; DB.printToChat=false; DB.relayGeneral=true; DB.relayLocalDefense=true
    DB.relayGuild=true; DB.relayPartySource=true
    DB.relayIncomingDM=true; DB.relayOutgoingDM=true
    DB.broadcastIncomingDM=false; DB.broadcastOutgoingDM=false
end
local failures,passed=0,0
local function test(name,fn)
    reset()
    local ok,err=pcall(fn)
    if ok then passed=passed+1; print('PASS '..name)
    else failures=failures+1; print('FAIL '..name..': '..tostring(err)) end
end
local function channels(expected)
    local actual={}
    for _,entry in ipairs(state.sent) do actual[#actual+1]=entry.channel end
    assert(table.concat(actual,',')==expected,
        'expected ['..expected..'] got ['..table.concat(actual,',')..']')
end
test('guild alone forwards through current chat API',function()
    receive(); channels('GUILD')
end)
test('modern API takes priority over legacy global',function()
    SendChatMessage=function() error('deprecated sender used') end
    receive(); channels('GUILD')
end)
test('legacy-only clients still forward',function()
    C_ChatInfo.SendChatMessage=nil; SendChatMessage=send
    receive(); channels('GUILD')
end)
test('legacy client without C_ChatInfo still forwards',function()
    C_ChatInfo=nil; SendChatMessage=send
    receive(); channels('GUILD')
end)
test('guild source without zone passes current-zone filter',function()
    DB.onlyCurrentZone=true; DB.printToChat=true
    receive('GUILD',''); channels('GUILD')
    assert(not state.sent[1].msg:find('[]',1,true),'unknown zone printed as empty brackets')
    assert(not state.chat[1]:find('[]',1,true),'unknown zone printed in local chat')
end)
test('guild source from legacy sender also passes zone filter',function()
    DB.onlyCurrentZone=true
    receive('GUILD','Duskwood'); channels('GUILD')
end)
test('General from another zone remains filtered',function()
    DB.onlyCurrentZone=true
    receive('GEN','Duskwood'); channels('')
end)
test('General in current zone forwards normally',function()
    DB.onlyCurrentZone=true
    receive('GEN','Redridge Mountains'); channels('GUILD')
end)
test('LocalDefense from another zone remains filtered',function()
    DB.onlyCurrentZone=true
    receive('LD','Duskwood'); channels('')
end)
test('party and guild both forward independently',function()
    state.grouped=true; DB.partyRelay=true
    receive(); channels('PARTY,GUILD')
end)
test('raid and guild forward without extra party copy',function()
    state.grouped=true; state.raid=true; DB.partyRelay=true; DB.raidRelay=true
    receive(); channels('RAID,GUILD')
end)
test('failed party send still attempts guild',function()
    state.grouped=true; DB.partyRelay=true
    C_ChatInfo.SendChatMessage=function(msg,channel)
        if channel=='PARTY' then error('party send regression') end
        send(msg,channel)
    end
    receive(); channels('GUILD')
end)
test('failed raid send still attempts guild',function()
    state.grouped=true; state.raid=true; DB.raidRelay=true
    C_ChatInfo.SendChatMessage=function(msg,channel)
        if channel=='RAID' then error('raid send regression') end
        send(msg,channel)
    end
    receive(); channels('GUILD')
end)
test('unselected guild output stays off',function()
    DB.guildRelay=false
    receive(); channels('')
end)
test('character without guild sends no guild message',function()
    state.guild=false
    receive(); channels('')
end)
test('disabled receiver sends nothing',function()
    DB.enabled=false
    receive(); channels('')
end)
test('disabled guild source stays filtered',function()
    DB.relayGuild=false
    receive('GUILD',''); channels('')
end)
test('incoming whispers stay private by default',function()
    receive('DM','Duskwood'); channels('')
end)
test('outgoing whispers stay private by default',function()
    receive('DMOUT','Duskwood'); channels('')
end)
test('explicit incoming whisper broadcast reaches guild',function()
    DB.broadcastIncomingDM=true
    receive('DM','Duskwood'); channels('GUILD')
end)
test('explicit outgoing whisper broadcast reaches guild',function()
    DB.broadcastOutgoingDM=true
    receive('DMOUT','Duskwood'); channels('GUILD')
end)
test('duplicate packet sends once',function()
    local p=packet()
    emit('BN_CHAT_MSG_ADDON','AHREL1',p,123)
    emit('BN_CHAT_MSG_ADDON','AHREL1',p,123)
    channels('GUILD')
end)
test('defense system alerts remain suppressed',function()
    receive('LD','Redridge Mountains','Southshore is under attack!'); channels('')
end)
test('packet is archived before source filtering',function()
    DB.relayGuild=false
    receive('GUILD','','guild archive regression')
    channels('')
    local bucket=DB.spyChatLog[date('%Y-%m-%d',time())]
    assert(bucket.entries[#bucket.entries].text=='guild archive regression')
end)
test('output checkbox saves guild forwarding preference',function()
    DB.guildRelay=false
    local found=false
    for _,f in ipairs(state.frames) do
        if f.parent==HordeRelayConfig and f.scripts.OnClick and f.scripts.OnShow then
            for _,label in ipairs(state.frames) do
                if label.parent==f and label.text=='Forward to guild' then
                    f:SetChecked(true); f.scripts.OnClick(f)
                    f.scripts.OnShow(f)
                    assert(f:GetChecked()==true,'guild output did not restore its saved value')
                    found=true
                    break
                end
            end
            if found then break end
        end
    end
    assert(found,'guild output checkbox did not write guildRelay')
    receive(); channels('GUILD')
end)
test('outgoing formatting is clean and within chat limit',function()
    receive('GEN','Redridge Mountains','|cffff0000'..string.rep('a',300)..'|r')
    channels('GUILD')
    assert(#state.sent[1].msg<=240,'public message exceeds limit')
    assert(not state.sent[1].msg:find('|c',1,true),'color markup leaked into guild chat')
end)
test('missing chat API is reported once and shown in diagnostics',function()
    C_ChatInfo.SendChatMessage=nil; SendChatMessage=nil
    receive(); receive(); channels('')
    assert(#state.chat==1,'repeating unavailable-API error spammed chat')
    SlashCmdList.HORDERELAYDIAG('')
    local output=table.concat(state.chat,'\n')
    assert(output:find('guild=true',1,true),'guild output missing from diagnostic')
    assert(output:find('inGuild=true',1,true),'guild membership missing from diagnostic')
    assert(output:find('chat API=unavailable',1,true),'API status missing from diagnostic')
    assert(output:find('GUILD last forwarding error=',1,true),'last send error missing from diagnostic')
end)
test('successful guild send clears retained failure',function()
    receive(); channels('GUILD')
    state.chat={}
    SlashCmdList.HORDERELAYDIAG('')
    assert(not table.concat(state.chat,'\n'):find('GUILD last forwarding error=',1,true),
        'old guild failure remained after successful API call')
end)
print(string.format('%d passed, %d failed',passed,failures))
assert(failures==0,'guild-forwarding regression failed')
