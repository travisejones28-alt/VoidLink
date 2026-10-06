-- Run from the repository root: lua tests/who_results.lua
-- Exercises the real chat command, sender prompt, WHO events, and receiver.
-- Live WHO permissions, Battle.net delivery, and chat limits still need WoW.
local M=dofile('tests/guild_forwarding.lua')
local state,emit,DB=M.state,M.emit,M.receiverDB
state.faction='Alliance'; state.transport={}; state.timers={}
UnitFactionGroup=function() return state.faction end
UnitName=function() return state.faction=='Alliance' and 'AllianceSpy' or 'Taliaa' end
UnitGUID=function() return 'Player-1-WHO' end
GetRealmName=function() return 'Whitemane' end
C_Timer.After=function(delay,fn)
    state.timers[#state.timers+1]={delay=delay,fn=fn}
end
BNSendGameData=function(id,prefix,payload)
    state.transport[#state.transport+1]={id=id,prefix=prefix,payload=payload}
end
C_FriendList={
    SendWho=function(query) state.whoQuery=query end,
    SetWhoToUi=M.noop,
    GetNumWhoResults=function() return #state.rows,state.total or #state.rows end,
    GetWhoInfo=function(i) return state.rows[i] end,
}
AllianceRelaySenderDB={voidLinkSettingsVersion=2}
assert(loadfile('AllianceRelaySender.lua'))('VoidLink')
emit('ADDON_LOADED','VoidLink')

local function row(name,class,level,zone)
    return {fullName=name,classStr=class or 'Rogue',level=level or 60,
        area=zone or 'Redridge Mountains'}
end
local function flushResults()
    local timers=state.timers
    state.timers={}
    for _,timer in ipairs(timers) do
        if timer.delay<1 then timer.fn() end
    end
end
local function runButton()
    for _,f in ipairs(state.frames) do
        if f.parent==VoidLinkRemoteWhoPrompt and f.text=='Run WHO' and f.scripts.OnClick then
            return f
        end
    end
    error('Run WHO prompt button missing')
end
local function query(text,event,author)
    state.faction='Horde'; state.transport={}
    if event then
        emit(event,'who '..text,author or 'Taliaa')
    else
        SlashCmdList.REMOTEWHO(text)
    end
    assert(#state.transport==1,'receiver did not send one WHO query')
    local request=state.transport[1].payload
    assert(request:sub(1,3)=='WQ\031','WHO request missing')
    state.faction='Alliance'; state.transport={}
    emit('BN_CHAT_MSG_ADDON','AHREL1',request,456)
    assert(VoidLinkRemoteWhoPrompt:IsShown(),'sender prompt missing')
    local button=runButton()
    button.scripts.OnClick(button)
    emit('WHO_LIST_UPDATE')
    flushResults()
    assert(not VoidLinkRemoteWhoPrompt:IsShown(),'completed prompt remained open')
    local responses=state.transport
    state.faction='Horde'; state.sent={}; state.chat={}
    DEFAULT_CHAT_FRAME.messages={}
    for _,packet in ipairs(responses) do
        assert(packet.id==456,'WHO response sent to wrong receiver')
        emit('BN_CHAT_MSG_ADDON',packet.prefix,packet.payload,123)
    end
    return responses
end
local function output(channel)
    local messages={}
    for _,entry in ipairs(state.sent) do
        assert(entry.channel==channel,'WHO replied to wrong chat channel')
        assert(#entry.msg<=240,'WHO message exceeds chat limit')
        assert(not entry.msg:find('|c',1,true),'class color leaked into public chat')
        messages[#messages+1]=entry.msg
    end
    return table.concat(messages,'\n')
end
local passed,failed=0,0
local function test(name,fn)
    M.reset()
    state.rows={}; state.total=nil; state.timers={}; state.transport={}; state.whoQuery=nil
    DB.partyRelay=false; DB.raidRelay=false; DB.guildRelay=false
    local ok,err=pcall(fn)
    if ok then passed=passed+1; print('PASS '..name)
    else failed=failed+1; print('FAIL '..name..': '..tostring(err)) end
end

test('party who RR 60 includes both names and abbreviated classes in one line',function()
    state.grouped=true
    state.rows={row('Charliework','Druid'),row('Aloha-Whitemane','Rogue')}
    local packets=query('rr 60','CHAT_MSG_PARTY')
    assert(state.whoQuery=='z-"Redridge Mountains" 60','level filter was lost')
    local rows=0
    for _,packet in ipairs(packets) do
        if packet.payload:sub(1,6)=='WR\031ZP\031' then rows=rows+1 end
    end
    assert(rows==2,'sender omitted level-60 player rows')
    assert(#state.sent==1,'short result was split unnecessarily')
    assert(output('PARTY')=='[WHO] RR: 2 60s: Charliework(Dru),Aloha(Rog)')
end)
test('guild member request replies with names to guild',function()
    state.grouped=true; DB.partyRelay=true
    state.rows={row('Icebarrier','Mage')}
    query('Redridge 60s','CHAT_MSG_GUILD','Guildie')
    assert(output('GUILD')=='[WHO] RR: 1 60s: Icebarrier(Mage)')
end)
test('raid request keeps every result in raid chat',function()
    state.grouped=true; state.raid=true
    state.rows={row('Fearward','Priest')}
    query('RR lvl60','CHAT_MSG_RAID_LEADER','Raidleader')
    assert(output('RAID')=='[WHO] RR: 1 60s: Fearward(Pri)')
end)
test('unfiltered zone keeps noob totals and lists only level-60 matches',function()
    state.rows={row('Lowbie','Warrior',32),row('Almost','Mage',59),row('Aloha'),
        row('Elsewhere','Mage',60,'Duskwood')}
    query('RR','CHAT_MSG_PARTY')
    assert(state.whoQuery=='z-"Redridge Mountains"')
    assert(output('PARTY')=='[WHO] RR: 2 noobs / 1 60s: Aloha(Rog)')
end)
test('solo slash query includes names in system chat',function()
    state.rows={row('Aloha')}
    query('RR 60')
    assert(#state.sent==0,'solo query was broadcast')
    local text=table.concat(DEFAULT_CHAT_FRAME.messages,'\n')
        :gsub('|c%x%x%x%x%x%x%x%x',''):gsub('|r','')
    assert(text=='[WHO] RR: 1 60s: Aloha(Rog)','solo result omitted names')
end)
test('zero level-60 results has a clean count without an empty name list',function()
    query('RR 60','CHAT_MSG_PARTY')
    assert(output('PARTY')=='[WHO] RR: 0 60s')
end)
test('capped level-60 query preserves total and marks the visible name list',function()
    state.rows={row('Aloha'),row('Icebarrier','Mage')}; state.total=67
    query('RR 60','CHAT_MSG_PARTY')
    assert(output('PARTY')=='[WHO] RR: 67 60s: Aloha(Rog),Icebarrier(Mage) (capped)')
end)
test('long filtered result relays all names within chat limits',function()
    for i=1,30 do state.rows[i]=row(string.format('Longplayer%02d',i),'Warlock') end
    state.total=67
    query('RR 60','CHAT_MSG_GUILD')
    local text=output('GUILD')
    assert(#state.sent>1,'long result was not split')
    assert(state.sent[1].msg=='[WHO] RR: 67 60s (capped)')
    for _,player in ipairs(state.rows) do
        local token=player.fullName..'(Lock)'
        local start,finish=text:find(token,1,true)
        assert(start,'name lost while splitting: '..token)
        assert(not text:find(token,finish+1,true),'name duplicated: '..token)
    end
end)
test('older count-only sender still produces its count',function()
    state.faction='Horde'
    SlashCmdList.REMOTEWHO('RR 60')
    state.chat={}; DEFAULT_CHAT_FRAME.messages={}
    emit('BN_CHAT_MSG_ADDON','AHREL1',
        table.concat({'WR','ZH','Redridge Mountains','0','2','2','2','60'},'\031'),123)
    emit('BN_CHAT_MSG_ADDON','AHREL1',table.concat({'WR','ZT',''},'\031'),123)
    local text=table.concat(DEFAULT_CHAT_FRAME.messages,'\n')
        :gsub('|c%x%x%x%x%x%x%x%x',''):gsub('|r','')
    assert(text=='[WHO] RR: 2 60s')
end)
test('player lookup remains unchanged',function()
    state.rows={row('Aloha')}
    query('Aloha','CHAT_MSG_PARTY')
    assert(state.whoQuery=='n-"Aloha"')
    assert(output('PARTY')=='[WHO] Aloha(Rog) / Lv60 / Redridge Mountains')
end)

print(string.format('WHO results: %d passed, %d failed',passed,failed))
assert(failed==0,'WHO-results regression failed')
