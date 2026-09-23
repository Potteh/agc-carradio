# Phase 9 - Premium Infotainment Entertainment

Adds a local passenger entertainment tab for YouTube video, Twitch live channels, and Kick live channels.

- Entertainment playback is local to the player; it does not change the synchronized vehicle radio.
- Starting entertainment locally ducks the synchronized radio to zero for that player and restores it when entertainment stops.
- Closing the infotainment UI stops the local entertainment iframe to prevent ghost video/audio.
- Streamer Mode reloads the entertainment embed muted.
- YouTube uses the official embed player.
- Kick uses the official `player.kick.com/<channel>` embed.
- Twitch uses the official Twitch player with FiveM's `cfx-nui-<resource>` host as the required `parent`. Twitch may reject playback if its domain validation does not accept the FiveM NUI host; this is a platform limitation rather than a radio synchronization issue.

No new server dependency was added. Existing radio, queue, proximity, persistence, and admin APIs are unchanged.
