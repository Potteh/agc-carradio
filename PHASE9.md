# Phase 9 - Premium Infotainment Entertainment

Adds a local passenger entertainment tab for YouTube video and Kick live channels.

- Entertainment playback is local to the player; it does not change the synchronized vehicle radio.
- Starting entertainment locally ducks the synchronized radio to zero for that player and restores it when entertainment stops.
- Closing the infotainment UI stops the local entertainment iframe to prevent ghost video/audio.
- Streamer Mode reloads the entertainment embed muted.
- YouTube uses the official embed player.
- Kick uses the official `player.kick.com/<channel>` embed.

No new server dependency was added. Existing radio, queue, proximity, persistence, and admin APIs are unchanged.
