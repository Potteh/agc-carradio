# Phase 8 — Vehicle persistence and cabin acoustics

## Persistent preferences
`agc-carradio` now stores per-plate preferences in FiveM resource KVP storage, so no SQL resource is required.

Persisted:
- base radio volume
- last configured live-radio station ID

Not persisted:
- YouTube track or timestamp
- queue
- custom stream URLs
- active playback position

With `Config.Persistence.RestoreLastStationOnEnter = true`, entering/requesting state for a vehicle with a saved configured station restores that live station. Disable the option if you only want saved volume.

## Engine/accessory behavior
Engine state affects only the listener's local effective volume. It never pauses playback or changes synchronized server state. This means restarting the engine does not desynchronize the song.

## Windows and doors
Outside listeners now hear a cabin multiplier on top of the existing distance attenuation:
- closed cabin: `ClosedCabinOutsideMultiplier`
- any rolled-down/broken standard cabin window: at least `WindowOpenOutsideMultiplier`
- any open door: at least `DoorOpenOutsideMultiplier`

Inside occupants are not muffled by windows/doors.

All values are configurable in `Config.VehicleAudio`.
