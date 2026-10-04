-- Run from the repository root: lua tests/friend_status.lua
-- Uses the real sender/receiver event handlers, with the routing mock.
local M=dofile('tests/guild_forwarding.lua')
local state,emit,DB=M.state,M.emit,M.receiverDB
local initialReceiverAlerts=DB.friendStatusAlerts
local private
for _,f in ipairs(state.frames) do
    if f.kind=='ScrollingMessageFrame' and f.parent==HordeRelayReceiverWindow then private=f end
end
assert(private,'private chat frame missing')
state.faction='Alliance'; state.friends={}; state.transport={}; state.timers={}; state.sounds=0
UnitFactionGroup=function() return state.faction end
UnitName=function() return state.faction=='Alliance' and 'AllianceSpy' or 'Taliaa' end
UnitGUID=function() return 'Player-1-SPY' end
GetRealmName=function() return 'Whitemane' end
PlaySound=function() state.sounds=state.sounds+1 end
C_Timer.After=function(delay,fn) state.timers[#state.timers+1]={delay=delay,fn=fn} end
local function flushQueue()
    for _=1,200 do
        local index
        for i,t in ipairs(state.timers) do if t.delay==0.35 then index=i; break end end
        if not index then return end
        local t=table.remove(state.timers,index)
        t.fn()
    end
    error('sender queue did not settle')
end
local function standardAPI()
    C_FriendList={
        GetNumFriends=function()
            if state.unavailable then return nil end
            return state.friendCount or #state.friends
        end,
        GetFriendInfoByIndex=function(i) return state.friends[i] end,
        ShowFriends=M.noop,
    }
end
standardAPI()
BNSendGameData=function(id,prefix,payload)
    state.transport[#state.transport+1]={id=id,prefix=prefix,payload=payload}
end
AllianceRelaySenderDB={voidLinkSettingsVersion=2,receivers={{id=123,name='Taliaa',lastAck=100}}}
assert(loadfile('AllianceRelaySender.lua'))('VoidLink')
emit('ADDON_LOADED','VoidLink')
local senderDB=AllianceRelaySenderDB
local initialSenderRelay=senderDB.relayFriendStatus
local function row(name,online) return {name=name,connected=online,level=60,className='Priest',area='Duskwood'} end
local function packets()
    local result={}
    for _,p in ipairs(state.transport) do
        if p.payload:sub(1,3)=='FS\031' then result[#result+1]=p.payload end
    end
    return result
end
local function roster(...)
    state.friends={...}
    state.friendCount=nil; state.unavailable=false
    emit('FRIENDLIST_UPDATE'); flushQueue()
end
local function login(...)
    state.friends={...}
    state.friendCount=nil; state.unavailable=false
    emit('PLAYER_LOGIN'); flushQueue()
    state.transport={}
end
local function clearMessages()
    state.sent={}; state.chat={}; state.sounds=0
    private.messages={}; DEFAULT_CHAT_FRAME.messages={}
end
local function archiveCount()
    local count=0
    for _,bucket in pairs(DB.spyChatLog or {}) do count=count+#(bucket.entries or {}) end
    return count
end
local function receive(payload)
    emit('BN_CHAT_MSG_ADDON','AHREL1',payload,123)
end
local sequence=0
local function presence(change,name)
    sequence=sequence+1
    return table.concat({'FS',change or 'OFFLINE',name or 'Zaleskar','21:55:00','AllianceSpy',
        'receiver-test:'..sequence},'\031')
end
local passed,failed=0,0
local function test(name,fn)
    flushQueue()
    state.faction='Alliance'; state.transport={}; state.friendCount=nil; state.unavailable=false
    standardAPI(); GetNumFriends=nil; GetFriendInfo=nil
    senderDB.enabled=true; senderDB.relayFriendStatus=true
    senderDB.receivers={{id=123,name='Taliaa',lastAck=state.now}}
    senderDB.receiverGameAccountID=nil
    DB.enabled=true; DB.friendStatusAlerts=false
    clearMessages()
    local ok,err=pcall(fn)
    if ok then passed=passed+1; print('PASS '..name)
    else failed=failed+1; print('FAIL '..name..': '..tostring(err)) end
end
local function checkbox(parent,label)
    for _,text in ipairs(state.frames) do
        local f=text.parent
        if text.text==label and f and f.parent==parent and f.scripts.OnClick then return f end
    end
    error('missing checkbox '..label)
end
test('receiver alerts default off, sender source defaults on',function()
    assert(initialReceiverAlerts==false)
    assert(initialSenderRelay==true)
end)
test('friend roster events before player login are silent',function()
    roster(row('Zaleskar',true)); roster(row('Zaleskar',false))
    assert(#packets()==0)
end)
test('first friend roster at login is silent',function()
    login(row('Zaleskar',true),row('Aloha',false))
    roster(row('Zaleskar',true),row('Aloha',false))
    assert(#packets()==0,'login announced the existing roster')
end)
test('standard friend logout sends a dedicated private packet',function()
    login(row('Zaleskar',true))
    roster(row('Zaleskar',false))
    local p=packets(); assert(#p==1)
    assert(p[1]:find('FS\031OFFLINE\031Zaleskar\031',1,true)==1)
end)
test('standard friend login sends one online packet',function()
    login(row('Zaleskar',false))
    roster(row('Zaleskar',true))
    local p=packets(); assert(#p==1)
    assert(p[1]:find('FS\031ONLINE\031Zaleskar\031',1,true)==1)
end)
test('repeated unchanged roster does not duplicate alerts',function()
    login(row('Zaleskar',true))
    roster(row('Zaleskar',false)); roster(row('Zaleskar',false))
    assert(#packets()==1)
end)
test('roster sorting does not create status changes',function()
    login(row('Zaleskar',true),row('Aloha',false))
    roster(row('Aloha',false),row('Zaleskar',true))
    assert(#packets()==0)
end)
test('adding and removing friends are silent',function()
    login(row('Zaleskar',true))
    roster(row('Zaleskar',true),row('Newfriend',true))
    roster(row('Newfriend',true))
    roster(row('Zaleskar',true),row('Newfriend',true))
    assert(#packets()==0)
end)
test('friend location and note changes do not alert',function()
    login(row('Zaleskar',true))
    local changed=row('Zaleskar',true); changed.area='Ironforge'; changed.notes='new note'
    roster(changed); assert(#packets()==0)
end)
test('Battle.net presence changes do not produce friend alerts',function()
    login(row('Zaleskar',true))
    state.friends={row('Zaleskar',false)}
    emit('BN_FRIEND_INFO_CHANGED',321); flushQueue()
    emit('BN_FRIEND_ACCOUNT_OFFLINE',321); flushQueue()
    assert(#packets()==0)
end)
test('unavailable friend count preserves last complete snapshot',function()
    login(row('Zaleskar',true))
    state.friends={row('Zaleskar',false)}; state.unavailable=true
    emit('FRIENDLIST_UPDATE'); flushQueue(); assert(#packets()==0)
    state.unavailable=false; emit('FRIENDLIST_UPDATE'); flushQueue()
    assert(#packets()==1)
end)
test('partial friend roster cannot create a false transition',function()
    login(row('Zaleskar',true),row('Aloha',true))
    state.friends={row('Zaleskar',false)}; state.friendCount=2
    emit('FRIENDLIST_UPDATE'); flushQueue(); assert(#packets()==0)
    roster(row('Zaleskar',false),row('Aloha',true))
    assert(#packets()==1)
end)
test('invalid modern connection state is ignored',function()
    login(row('Zaleskar',true))
    roster({name='Zaleskar'}); assert(#packets()==0)
    roster(row('Zaleskar',false)); assert(#packets()==1)
end)
test('friend API error leaves the baseline intact',function()
    login(row('Zaleskar',true))
    C_FriendList.GetFriendInfoByIndex=function() error('roster unavailable') end
    state.friends={row('Zaleskar',false)}; emit('FRIENDLIST_UPDATE'); flushQueue()
    assert(#packets()==0)
    standardAPI(); emit('FRIENDLIST_UPDATE'); flushQueue(); assert(#packets()==1)
end)
test('disabled sender updates baseline without replaying notices',function()
    login(row('Zaleskar',true)); senderDB.enabled=false
    roster(row('Zaleskar',false)); assert(#packets()==0)
    senderDB.enabled=true; roster(row('Zaleskar',false)); assert(#packets()==0)
    roster(row('Zaleskar',true)); assert(#packets()==1)
end)
test('disabled friend source updates baseline without replay',function()
    login(row('Zaleskar',true)); senderDB.relayFriendStatus=false
    roster(row('Zaleskar',false)); assert(#packets()==0)
    senderDB.relayFriendStatus=true; roster(row('Zaleskar',false)); assert(#packets()==0)
    roster(row('Zaleskar',true)); assert(#packets()==1)
end)
test('missing receivers do not queue old friend notices',function()
    login(row('Zaleskar',true))
    senderDB.receivers={}; senderDB.receiverGameAccountID=nil
    roster(row('Zaleskar',false)); assert(#packets()==0)
    senderDB.receivers={{id=123,name='Taliaa'}}
    roster(row('Zaleskar',false)); assert(#packets()==0)
    roster(row('Zaleskar',true)); assert(#packets()==1)
end)
test('Horde character cannot act as the friend spy',function()
    login(row('Zaleskar',true)); state.faction='Horde'
    roster(row('Zaleskar',false)); assert(#packets()==0)
end)
test('reload establishes a silent new baseline',function()
    login(row('Zaleskar',true))
    login(row('Zaleskar',false)); roster(row('Zaleskar',false))
    assert(#packets()==0)
end)
test('rapid reconnects receive distinct packet identifiers',function()
    login(row('Zaleskar',true))
    roster(row('Zaleskar',false)); roster(row('Zaleskar',true)); roster(row('Zaleskar',false))
    local p=packets(); assert(#p==3 and p[1]~=p[3])
    state.faction='Horde'; DB.friendStatusAlerts=true
    clearMessages()
    for _,payload in ipairs(p) do receive(payload) end
    assert(#private.messages==3,'receiver deduplicated a real rapid reconnect')
end)
test('friend names with different realms remain distinct',function()
    login(row('Enemy-Whitemane',true),row('Enemy-Thunderfury',false))
    roster(row('Enemy-Whitemane',true),row('Enemy-Thunderfury',true))
    local p=packets(); assert(#p==1 and p[1]:find('Enemy-Thunderfury',1,true))
end)
test('legacy standard friend APIs remain supported',function()
    C_FriendList=nil
    GetNumFriends=function() return #state.friends end
    GetFriendInfo=function(i)
        local info=state.friends[i]
        return info.name,60,'Priest','Duskwood',info.connected
    end
    login(row('Zaleskar',true)); roster(row('Zaleskar',false)); assert(#packets()==1)
end)
test('absent standard friend APIs are harmless',function()
    C_FriendList=nil; GetNumFriends=nil; GetFriendInfo=nil
    login(row('Zaleskar',true)); roster(row('Zaleskar',false)); assert(#packets()==0)
end)
test('receiver toggle off suppresses friend notices',function()
    state.faction='Horde'; receive(presence())
    assert(#private.messages==0 and #state.sent==0)
end)
test('enabled friend notices stay exclusively in private window',function()
    state.faction='Horde'; DB.friendStatusAlerts=true
    DB.partyRelay=true; DB.raidRelay=true; DB.guildRelay=true; DB.printToChat=true; DB.soundAlert=true
    state.grouped=true; state.raid=true; state.guild=true
    local archived=archiveCount()
    receive(presence())
    assert(#private.messages==1 and private.messages[1]:find('Zaleskar logged OUT.',1,true))
    assert(private.messages[1]:find('|cffff5555',1,true),'logout is not red')
    assert(#DEFAULT_CHAT_FRAME.messages==0,'friend alert leaked into normal chat')
    assert(#state.sent==0,'friend alert leaked into Party/Raid/Guild')
    assert(state.sounds==0,'friend alert played chat alert sound')
    assert(archiveCount()==archived,'friend alert leaked into chat archive/export')
end)
test('online friend notice is green',function()
    state.faction='Horde'; DB.friendStatusAlerts=true
    receive(presence('ONLINE'))
    assert(#private.messages==1 and private.messages[1]:find('logged IN.',1,true))
    assert(private.messages[1]:find('|cff66ff66',1,true))
end)
test('friend notices ignore ordinary chat source and zone filters',function()
    state.faction='Horde'; DB.friendStatusAlerts=true; DB.onlyCurrentZone=true
    DB.relayGeneral=false; DB.relayLocalDefense=false; DB.relayGuild=false
    receive(presence()); assert(#private.messages==1)
end)
test('closed private window retains alert without opening',function()
    state.faction='Horde'; DB.friendStatusAlerts=true; DB.showWindow=false
    HordeRelayReceiverWindow:Hide()
    receive(presence())
    assert(#private.messages==1 and not HordeRelayReceiverWindow:IsShown())
end)
test('duplicate friend transport packet is shown once',function()
    state.faction='Horde'; DB.friendStatusAlerts=true
    local p=presence(); receive(p); receive(p)
    assert(#private.messages==1)
end)
test('malformed friend notices are ignored',function()
    state.faction='Horde'; DB.friendStatusAlerts=true
    receive(presence('BOGUS')); receive(presence('OFFLINE',''))
    assert(#private.messages==0 and #state.sent==0)
end)
test('disabled receiver drops friend notices',function()
    state.faction='Horde'; DB.friendStatusAlerts=true; DB.enabled=false
    receive(presence()); assert(#private.messages==0)
end)
test('receiver checkbox saves and restores friend alert preference',function()
    state.faction='Horde'
    local cb=checkbox(HordeRelayConfig,'Friend login/logout')
    cb:SetChecked(true); cb.scripts.OnClick(cb); cb.scripts.OnShow(cb)
    assert(DB.friendStatusAlerts and cb:GetChecked())
    receive(presence()); assert(#private.messages==1)
    cb:SetChecked(false); cb.scripts.OnClick(cb)
    receive(presence()); assert(#private.messages==1)
end)
test('sender checkbox controls friend source preference',function()
    local cb=checkbox(AllianceRelayConfig,'Relay friend login/logout')
    cb:SetChecked(false); cb.scripts.OnClick(cb); cb.scripts.OnShow(cb)
    assert(not senderDB.relayFriendStatus and not cb:GetChecked())
    login(row('Zaleskar',true)); roster(row('Zaleskar',false)); assert(#packets()==0)
end)
local legacy=os.getenv('VOIDLINK_LEGACY_RECEIVER')
if legacy then
    test('older receiver rejects friend packets instead of forwarding them',function()
        state.faction='Horde'; DB.friendStatusAlerts=false; DB.enabled=true
        DB.partyRelay=true; DB.raidRelay=true; DB.guildRelay=true; DB.printToChat=true
        assert(loadfile(legacy))('VoidLink'); emit('ADDON_LOADED','VoidLink')
        clearMessages(); receive(presence())
        assert(#state.chat==0 and #state.sent==0,'legacy receiver forwarded a private friend packet')
    end)
end
print(string.format('Friend status: %d passed, %d failed',passed,failed))
assert(failed==0,'friend-status regression failed')
