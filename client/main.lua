local QBCore = exports['qb-core']:GetCoreObject()

local isRadioOpen = false

local function DebugPrint(message, data)
    if not Config.Debug then
        return
    end

    if data then
        print(('[acg_radio] %s: %s'):format(message, json.encode(data)))
        return
    end

    print(('[acg_radio] %s'):format(message))
end

local function GetCurrentVehicle()
    local ped = PlayerPedId()

    if not IsPedInAnyVehicle(ped, false) then
        return 0
    end

    return GetVehiclePedIsIn(ped, false)
end

local function IsPlayerDriver(vehicle)
    return vehicle ~= 0 and GetPedInVehicleSeat(vehicle, -1) == PlayerPedId()
end

local function GetVehicleNetworkId(vehicle)
    if vehicle == 0 or not DoesEntityExist(vehicle) then
        return 0
    end

    return NetworkGetNetworkIdFromEntity(vehicle)
end

local function CloseRadio()
    if not isRadioOpen then
        SetNuiFocus(false, false)
        return
    end

    isRadioOpen = false
    SetNuiFocus(false, false)
    SendNUIMessage({ action = 'closeRadio' })
end

local function OpenRadio()
    local vehicle = GetCurrentVehicle()

    if vehicle == 0 then
        QBCore.Functions.Notify('You must be inside a vehicle to use the radio.', 'error')
        return
    end

    local networkId = GetVehicleNetworkId(vehicle)
    if networkId == 0 then
        QBCore.Functions.Notify('Unable to identify this vehicle.', 'error')
        return
    end

    local isDriver = IsPlayerDriver(vehicle)
    local plate = QBCore.Functions.GetPlate(vehicle)

    isRadioOpen = true
    SetNuiFocus(true, true)
    SendNUIMessage({
        action = 'openRadio',
        vehicle = {
            networkId = networkId,
            plate = plate,
            isDriver = isDriver
        },
        settings = {
            defaultVolume = Config.DefaultVolume,
            maxVolume = Config.MaxVolume,
            driverOnly = Config.DriverOnly
        }
    })
end

-- Browser data contains only user input. Vehicle context is always derived here.
local function HandlePlaybackRequest(action, data, callback)
    local vehicle = GetCurrentVehicle()
    if vehicle == 0 then
        CloseRadio()
        QBCore.Functions.Notify('You must be inside a vehicle to use the radio.', 'error')
        callback({ ok = false, error = 'not_in_vehicle' })
        return
    end

    if Config.DriverOnly and not IsPlayerDriver(vehicle) then
        QBCore.Functions.Notify('Only the driver can control the vehicle radio.', 'error')
        callback({ ok = false, error = 'driver_only' })
        return
    end

    local networkId = GetVehicleNetworkId(vehicle)
    if networkId == 0 then
        QBCore.Functions.Notify('Unable to identify this vehicle.', 'error')
        callback({ ok = false, error = 'invalid_vehicle' })
        return
    end

    local request = {
        vehicleNetworkId = networkId,
        action = action,
        data = data or {}
    }

    DebugPrint(('NUI callback "%s"'):format(action), request)
    TriggerServerEvent('acg_radio:server:requestAction', request)
    callback({ ok = true })
end

RegisterCommand(Config.Command, OpenRadio, false)

RegisterNUICallback('close', function(_, callback)
    CloseRadio()
    callback({ ok = true })
end)

RegisterNUICallback('playYoutube', function(data, callback)
    HandlePlaybackRequest('playYoutube', data, callback)
end)

RegisterNUICallback('playStream', function(data, callback)
    HandlePlaybackRequest('playStream', data, callback)
end)

RegisterNUICallback('pause', function(data, callback)
    HandlePlaybackRequest('pause', data, callback)
end)

RegisterNUICallback('resume', function(data, callback)
    HandlePlaybackRequest('resume', data, callback)
end)

RegisterNUICallback('stop', function(data, callback)
    HandlePlaybackRequest('stop', data, callback)
end)

RegisterNUICallback('setVolume', function(data, callback)
    HandlePlaybackRequest('setVolume', data, callback)
end)

AddEventHandler('onResourceStop', function(resourceName)
    if resourceName ~= GetCurrentResourceName() then
        return
    end

    isRadioOpen = false
    SetNuiFocus(false, false)
end)
