VoidLink
========

VoidMark cross-account/faction intelligence relay.

Combined package containing the existing:
- Alliance Relay Sender
- Alliance WHO Scanner
- Horde Relay Receiver

Install:
Place the VoidLink folder in World of Warcraft\_classic_era_\Interface\AddOns.

This initial merged build preserves the existing sender, scanner, receiver,
SavedVariables, protocol prefix, and behavior so it can be tested before deeper cleanup.

CHAT RECORDING (1.0.1)
Local chat is archived on every character, independently of sender/receiver role, connection, relay toggles, and the ignore-own-messages relay setting. Includes channels (General/LocalDefense identified), party, raid, guild, say, yell, and whispers in both directions. The archive is VoidLinkDB.chatLog in WTF/Account/<account>/SavedVariables/VoidLink.lua; relayed history remains in HordeRelayReceiverDB.spyChatLog. Default retention: 30 days, 5,000 entries per day.

WoW native chat logging starts automatically each login and writes to your client folder's Logs/WoWChatLog.txt (Classic Era: _classic_era_/Logs/WoWChatLog.txt). Open this file in Notepad. This captures chat received by that client, including whispers; it does not recreate missing history or capture Alliance chat the receiver did not receive. Clients using the same installation share this file; use the archive's observer/realm fields to distinguish local character records. Native logs have no automatic retention cleanup.

/voidlink log - archive count and text logging status
/voidlink log on - enable archive and text logging
/voidlink log off - disable archive and text logging
/voidlink export - copy today's local and received history
/voidlink export YYYY-MM-DD - copy a particular date
In the export window press Ctrl+A, Ctrl+C, and paste into Notepad. Dates use the WoW client's local clock. Export identifies local and relay sources.

SavedVariables are written by WoW on /reload or clean logout, not after each message; a crash can lose unsaved archive entries. Native logging provides an independent text log but is still subject to the client's buffering. /reload before collecting SavedVariables.

GUILD FORWARDING (1.0.2)
Receiver Settings > Output destinations > Forward to guild sends accepted relay messages to the Horde character's guild. Alliance guild under Relay types controls the source feed; it does not select an output. Guild-source messages pass Only current zone because their speaker's zone is unknown. General/LocalDefense still honor that filter, and DMs still require explicit public-broadcast permission.
Chat sending prefers C_ChatInfo.SendChatMessage with legacy support. Each output is attempted independently; repeating Lua send errors are reported once until that output succeeds. /hrdiag shows selected outputs, guild membership, chat API availability, and any retained forwarding errors. A successful API call is not confirmation of server delivery.

Offline routing regression: lua tests/guild_forwarding.lua (run from this folder). The mock checks receiver events and preferences; live server delivery and protected execution require in-game validation.
