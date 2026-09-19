Config = {}

Config.Command = 'carradio'
Config.DriverOnly = true

Config.DefaultVolume = 50
Config.MaxVolume = 100

Config.Audio = {
    MaxDistance = 35.0,
    FullVolumeDistance = 4.0,
    InsideVehicleMultiplier = 1.0,
    OutsideVehicleMultiplier = 0.70,
    UpdateInterval = 250,
    MinAudibleVolume = 1,
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

Config.Debug = false
