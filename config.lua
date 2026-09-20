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
