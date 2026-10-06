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
local function query(text,event,author,channelIndex,channelName)
    state.faction='Horde'; state.transport={}
    if event then
        emit(event,'who '..text,author or 'Taliaa',nil,channelName,nil,nil,nil,channelIndex)
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

local function startRequest(text,event)
    state.faction='Horde'; state.transport={}
    if event then emit(event,'who '..text,'Taliaa') else SlashCmdList.REMOTEWHO(text) end
    assert(#state.transport==1,'request was not sent')
    return state.transport[1].payload
end
local function queueRequest(request)
    state.faction='Alliance'; state.transport={}
    emit('BN_CHAT_MSG_ADDON','AHREL1',request,456)
end
local function runActiveWho(updates)
    state.faction='Alliance'; state.transport={}
    local button=runButton()
    button.scripts.OnClick(button)
    for _=1,updates or 1 do emit('WHO_LIST_UPDATE') end
    flushResults()
    return state.transport
end
local function ignoreActiveWho()
    state.faction='Alliance'; state.transport={}
    for _,f in ipairs(state.frames) do
        if f.parent==VoidLinkRemoteWhoPrompt and f.text=='Ignore' and f.scripts.OnClick then
            f.scripts.OnClick(f)
            return state.transport
        end
    end
    error('Ignore button missing')
end
local function replay(packets)
    state.faction='Horde'
    for _,packet in ipairs(packets) do
        emit('BN_CHAT_MSG_ADDON',packet.prefix,packet.payload,123)
    end
end
local function packetOf(packets,subtype)
    for _,packet in ipairs(packets) do
        if packet.payload:sub(1,#subtype+4)=='WR\031'..subtype..'\031' then return packet end
    end
    error('missing '..subtype..' response')
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

test('party player-not-found reply overrides every selected forwarding destination',function()
    state.grouped=true; DB.guildRelay=true; DB.partyRelay=true; DB.raidRelay=true
    query('polterge','CHAT_MSG_PARTY')
    assert(output('PARTY')=='[WHO] polterge — not found / offline')
end)
test('self say and yell requests reply only to their originating channels',function()
    DB.guildRelay=true
    query('Saylookup','CHAT_MSG_SAY')
    assert(output('SAY')=='[WHO] Saylookup — not found / offline')
    query('Yelllookup','CHAT_MSG_YELL')
    assert(output('YELL')=='[WHO] Yelllookup — not found / offline')
end)
test('numbered channel request retains its original channel index',function()
    DB.guildRelay=true
    C_ChatInfo.SendChatMessage=function(msg,channel,language,target)
        state.sent[#state.sent+1]={msg=msg,channel=channel,target=target}
    end
    query('Channellookup','CHAT_MSG_CHANNEL','Taliaa',7,'General')
    assert(output('CHANNEL')=='[WHO] Channellookup — not found / offline')
    assert(state.sent[1].target==7,'numbered channel index changed')
end)
test('a stale local request cannot redirect a later party reply to guild',function()
    DB.guildRelay=true
    local stale=startRequest('Lostrequest')
    local party=startRequest('polterge','CHAT_MSG_PARTY')
    queueRequest(party)
    state.sent={}; replay(runActiveWho())
    assert(output('PARTY')=='[WHO] polterge — not found / offline')
    queueRequest(stale); replay(ignoreActiveWho())
end)
test('out-of-order completed requests keep their own guild and party routes',function()
    local guild=startRequest('Guildlookup','CHAT_MSG_GUILD')
    local party=startRequest('Partylookup','CHAT_MSG_PARTY')
    queueRequest(guild); queueRequest(party)
    local guildPackets=runActiveWho()
    local partyPackets=runActiveWho()
    state.sent={}; replay(partyPackets); replay(guildPackets)
    assert(#state.sent==2)
    assert(state.sent[1].channel=='PARTY' and state.sent[1].msg:find('Partylookup',1,true))
    assert(state.sent[2].channel=='GUILD' and state.sent[2].msg:find('Guildlookup',1,true))
end)
test('late ignore notice removes only its own request',function()
    local ignored=startRequest('Ignoredlookup','CHAT_MSG_GUILD')
    local party=startRequest('polterge','CHAT_MSG_PARTY')
    queueRequest(ignored); queueRequest(party)
    local ignoredPackets=ignoreActiveWho()
    local partyPackets=runActiveWho()
    state.sent={}; replay(partyPackets); replay(ignoredPackets)
    assert(output('PARTY')=='[WHO] polterge — not found / offline')
end)
test('late timeout notice cannot consume another request destination',function()
    local expired=startRequest('Expiredlookup','CHAT_MSG_GUILD')
    local party=startRequest('polterge','CHAT_MSG_PARTY')
    queueRequest(expired); queueRequest(party)
    local expiry
    for _,timer in ipairs(state.timers) do if timer.delay==30 then expiry=timer.fn; break end end
    assert(expiry,'30-second expiry timer missing')
    state.transport={}; expiry()
    local expiredPackets=state.transport
    local partyPackets=runActiveWho()
    state.sent={}; replay(partyPackets); replay(expiredPackets)
    assert(output('PARTY')=='[WHO] polterge — not found / offline')
end)
test('interleaved zone packets keep names and channels separate',function()
    local party=startRequest('RR 60','CHAT_MSG_PARTY')
    local guild=startRequest('Wet 60','CHAT_MSG_GUILD')
    queueRequest(party); queueRequest(guild)
    state.rows={row('Aloha')}; local partyPackets=runActiveWho()
    state.rows={row('Boatmage','Mage',60,'Wetlands')}; local guildPackets=runActiveWho()
    state.sent={}
    replay({packetOf(partyPackets,'ZH'),packetOf(guildPackets,'ZH'),
        packetOf(partyPackets,'ZP'),packetOf(guildPackets,'ZP'),
        packetOf(guildPackets,'ZT'),packetOf(partyPackets,'ZT')})
    assert(#state.sent==2)
    assert(state.sent[1].channel=='GUILD' and state.sent[1].msg=='[WHO] Wet: 1 60s: Boatmage(Mage)')
    assert(state.sent[2].channel=='PARTY' and state.sent[2].msg=='[WHO] RR: 1 60s: Aloha(Rog)')
end)
test('identical missing-player results from distinct requests are not deduplicated',function()
    local party=startRequest('polterge','CHAT_MSG_PARTY')
    local guild=startRequest('polterge','CHAT_MSG_GUILD')
    queueRequest(party); queueRequest(guild)
    local first=runActiveWho(); local second=runActiveWho()
    state.sent={}; replay(first); replay(second)
    assert(#state.sent==2)
    assert(state.sent[1].channel=='PARTY' and state.sent[2].channel=='GUILD')
end)
test('replayed terminal packet cannot consume the next queued route',function()
    local party=startRequest('Firstlookup','CHAT_MSG_PARTY')
    local guild=startRequest('Secondlookup','CHAT_MSG_GUILD')
    queueRequest(party); queueRequest(guild)
    local first=runActiveWho(); local second=runActiveWho()
    state.sent={}; replay(first)
    state.now=state.now+6; replay(first); replay(second)
    assert(#state.sent==2)
    assert(state.sent[1].channel=='PARTY' and state.sent[2].channel=='GUILD')
    assert(state.sent[2].msg:find('Secondlookup',1,true))
end)
test('duplicate WHO updates cannot consume the next unclicked prompt',function()
    local party=startRequest('Firstlookup','CHAT_MSG_PARTY')
    local guild=startRequest('Secondlookup','CHAT_MSG_GUILD')
    queueRequest(party); queueRequest(guild)
    local first=runActiveWho(2)
    assert(VoidLinkRemoteWhoPrompt:IsShown(),'unclicked request was completed')
    assert(runButton(),'next request is not waiting for a click')
    local second=runActiveWho()
    state.sent={}; replay(first); replay(second)
    assert(#state.sent==2)
    assert(state.sent[1].channel=='PARTY' and state.sent[2].channel=='GUILD')
end)
test('unknown legacy response stays local despite selected guild forwarding',function()
    DB.guildRelay=true; state.faction='Horde'; state.sent={}; DEFAULT_CHAT_FRAME.messages={}
    emit('BN_CHAT_MSG_ADDON','AHREL1',table.concat({'WR','PN','Unmatchedlookup'},'\031'),123)
    assert(#state.sent==0,'unmatched WHO result leaked to guild')
    assert(table.concat(DEFAULT_CHAT_FRAME.messages,'\n'):find('Unmatchedlookup',1,true))
end)
test('legacy sender reply still honors a known party request',function()
    DB.guildRelay=true
    startRequest('Legacylookup','CHAT_MSG_PARTY')
    emit('BN_CHAT_MSG_ADDON','AHREL1',table.concat({'WR','PN','Legacylookup'},'\031'),123)
    assert(output('PARTY')=='[WHO] Legacylookup — not found / offline')
end)
test('slash WHO preserves explicitly selected default outputs',function()
    DB.guildRelay=true
    query('Slashlookup')
    assert(output('GUILD')=='[WHO] Slashlookup — not found / offline')
end)
test('receiver reload retains original party channel from sender context',function()
    DB.guildRelay=true; state.grouped=true
    local request=startRequest('polterge','CHAT_MSG_PARTY')
    queueRequest(request)
    local packets=runActiveWho()
    -- Recreate only the receiver event handler to emulate losing its pending
    -- queue at /reload while retaining the saved forwarding settings.
    for _,f in ipairs(state.frames) do
        if f.events.CHAT_MSG_RAID then f.events={} end
    end
    state.faction='Horde'
    assert(loadfile('HordeRelayReceiver.lua'))('VoidLink')
    emit('ADDON_LOADED','VoidLink')
    state.sent={}; replay(packets)
    assert(output('PARTY')=='[WHO] polterge — not found / offline')
end)

print(string.format('WHO results: %d passed, %d failed',passed,failed))
assert(failed==0,'WHO-results regression failed')
