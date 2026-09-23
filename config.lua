Config = {}

Config.Command = 'carradio'
Config.StreamerModeCommand = 'streamermode'
Config.DriverOnly = false

Config.DefaultVolume = 50
Config.MaxVolume = 100

Config.Queue = {
    Enabled = true,
    MaxItems = 20
}

Config.Library = {
    FavoritesMaxItems = 50,
    HistoryMaxItems = 25
}

-- Phase 8: persistent per-vehicle preferences. Uses resource KVP storage, so no SQL dependency.
-- Only volume and configured live-station ID are persisted; YouTube positions and custom URLs are never restored.
Config.Persistence = {
    Enabled = true,
    RestoreLastStationOnEnter = true,
    SaveVolume = true,
    SaveConfiguredStation = true
}

-- Phase 8: engine/accessory and cabin acoustics. These are local volume multipliers only;
-- they never alter the server-authoritative base volume or playback position.
Config.VehicleAudio = {
    EngineOffInsideMultiplier = 0.35,
    EngineOffOutsideMultiplier = 0.20,
    ClosedCabinOutsideMultiplier = 0.35,
    WindowOpenOutsideMultiplier = 0.70,
    DoorOpenOutsideMultiplier = 1.00,
    DoorOpenThreshold = 0.05
}

Config.Streams = {
    AllowCustomUrls = true,
    MaxUrlLength = 2048
}

-- Add browser-compatible direct MP3/AAC/Icecast/Shoutcast endpoints here.
Config.RadioStations = {}

Config.Audio = {
    MaxDistance = 35.0,
    FullVolumeDistance = 2.0,
    InsideVehicleMultiplier = 1.0,
    OutsideVehicleMultiplier = 1.0,
    UpdateInterval = 100,
    MinAudibleVolume = 1,
    AttenuationExponent = 1.5,
    SourceSwitchThreshold = 3.0,
    HearOutsideWhileInSilentVehicle = false,
    EntityResolveGrace = 2000
}

Config.Sync = {
    VehicleCheckInterval = 500,
    DriftCheckInterval = 5000,
    DriftThreshold = 2.5,
    StateCleanupInterval = 60000,
    ControlCooldown = 150
}

Config.Integrations = {
    AdminMenu = {
        Enabled = true,
        ResourceName = 'fivem_admin'
    }
}

Config.Debug = false
