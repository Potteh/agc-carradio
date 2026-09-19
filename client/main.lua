local QBCore = exports['qb-core']:GetCoreObject()

local isRadioOpen = false
local currentVehicleNetworkId = 0
local currentRadioVideoId = nil
local lastDriverState = nil

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

    local vehicle = GetVehiclePedIsIn(ped, false)
    if vehicle == 0 or not DoesEntityExist(vehicle) then
        return 0
    end

    return vehicle
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

local function IsValidVideoId(videoId)
    return type(videoId) == 'string'
        and #videoId == 11
        and videoId:match('^[%w_-]+$') ~= nil
end

local function CloseRadio()
    isRadioOpen = false
    SetNuiFocus(false, false)
    SendNUIMessage({ action = 'closeRadio' })
end

local function RequestCurrentState(networkId)
    if networkId == 0 then
        return
    end

    TriggerServerEvent('acg_radio:server:requestState', {
        vehicleNetworkId = networkId
    })
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

    currentVehicleNetworkId = networkId
    lastDriverState = IsPlayerDriver(vehicle)
    isRadioOpen = true
    SetNuiFocus(true, true)
    SendNUIMessage({
        action = 'openRadio',
        vehicle = {
            networkId = networkId,
            plate = QBCore.Functions.GetPlate(vehicle),
            isDriver = lastDriverState
        },
        settings = {
            defaultVolume = Config.DefaultVolume,
            maxVolume = Config.MaxVolume,
            driverOnly = Config.DriverOnly,
            sync = Config.Sync,
            debug = Config.Debug
        }
    })
    RequestCurrentState(networkId)
end

-- Browser requests contain only user intent. Vehicle identity is always derived here.
local function SendControlRequest(serverEvent, data, callback)
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

    local request = data or {}
    request.vehicleNetworkId = networkId

    DebugPrint(('request event=%s vehicle=%s'):format(serverEvent, networkId), request)
    TriggerServerEvent(serverEvent, request)
    callback({ ok = true })
end

local function StopFailedSource(videoId)
    if not IsValidVideoId(videoId) or videoId ~= currentRadioVideoId then
        return
    end

    local vehicle = GetCurrentVehicle()
    if vehicle == 0 then
        return
    end

    local driver = GetPedInVehicleSeat(vehicle, -1)
    if Config.DriverOnly and not IsPlayerDriver(vehicle) and driver ~= 0 then
        return
    end

    local networkId = GetVehicleNetworkId(vehicle)
    if networkId == 0 or networkId ~= currentVehicleNetworkId then
        return
    end

    TriggerServerEvent('acg_radio:server:stop', {
        vehicleNetworkId = networkId,
        expectedVideoId = videoId,
        terminal = true
    })
end

RegisterCommand(Config.Command, OpenRadio, false)

RegisterNUICallback('close', function(_, callback)
    CloseRadio()
    callback({ ok = true })
end)

RegisterNUICallback('playYoutube', function(data, callback)
    if type(data) ~= 'table' or not IsValidVideoId(data.videoId) then
        QBCore.Functions.Notify('Enter a valid YouTube URL.', 'error')
        callback({ ok = false, error = 'invalid_video' })
        return
    end

    SendControlRequest('acg_radio:server:playYoutube', {
        videoId = data.videoId
    }, callback)
end)

RegisterNUICallback('playStream', function(_, callback)
    QBCore.Functions.Notify('Direct radio streams are not available yet.', 'error')
    callback({ ok = false, error = 'not_available' })
end)

RegisterNUICallback('pause', function(_, callback)
    SendControlRequest('acg_radio:server:pause', {}, callback)
end)

RegisterNUICallback('resume', function(_, callback)
    SendControlRequest('acg_radio:server:resume', {}, callback)
end)

RegisterNUICallback('stop', function(_, callback)
    SendControlRequest('acg_radio:server:stop', {}, callback)
end)

RegisterNUICallback('seek', function(data, callback)
    local position = type(data) == 'table' and tonumber(data.position) or nil
    if not position then
        callback({ ok = false, error = 'invalid_position' })
        return
    end

    SendControlRequest('acg_radio:server:seek', {
        position = position
    }, callback)
end)

RegisterNUICallback('setVolume', function(data, callback)
    local volume = type(data) == 'table' and tonumber(data.volume) or nil
    if not volume then
        callback({ ok = false, error = 'invalid_volume' })
        return
    end

    SendControlRequest('acg_radio:server:setVolume', {
        volume = volume
    }, callback)
end)

RegisterNUICallback('youtubeError', function(data, callback)
    local code = type(data) == 'table' and tonumber(data.code) or 0
    local videoId = type(data) == 'table' and data.videoId or nil
    local messages = {
        [-1] = 'YouTube autoplay was blocked. Press resume to try again.',
        [2] = 'YouTube rejected the video ID.',
        [5] = 'This video cannot play in the embedded player.',
        [100] = 'This video is unavailable or private.',
        [101] = 'The video owner disabled embedded playback.',
        [150] = 'The video owner disabled embedded playback.',
        [153] = 'YouTube rejected the embedded player client.'
    }

    QBCore.Functions.Notify(messages[code] or 'YouTube playback failed.', 'error')
    if not (type(data) == 'table' and data.recoverable == true) then
        StopFailedSource(videoId)
    end
    callback({ ok = true })
end)

RegisterNUICallback('youtubeEnded', function(data, callback)
    StopFailedSource(type(data) == 'table' and data.videoId or nil)
    callback({ ok = true })
end)

RegisterNUICallback('syncReport', function(data, callback)
    if Config.Debug and type(data) == 'table' then
        DebugPrint(('sync vehicle=%s expected=%.1f actual=%.1f'):format(
            currentVehicleNetworkId,
            tonumber(data.expected) or 0.0,
            tonumber(data.actual) or 0.0
        ))
    end

    callback({ ok = true })
end)

RegisterNUICallback('youtubeDebug', function(data, callback)
    if Config.Debug and type(data) == 'table' and type(data.message) == 'string' then
        DebugPrint(data.message:sub(1, 512))
    end

    callback({ ok = true })
end)

RegisterNUICallback('nuiReady', function(_, callback)
    local vehicle = GetCurrentVehicle()
    local networkId = GetVehicleNetworkId(vehicle)

    if networkId ~= 0 then
        currentVehicleNetworkId = networkId
        lastDriverState = IsPlayerDriver(vehicle)
        RequestCurrentState(networkId)
    end

    callback({ ok = true })
end)

RegisterNetEvent('acg_radio:client:syncState', function(state)
    if type(state) ~= 'table'
        or type(state.vehicleNetworkId) ~= 'number'
        or state.vehicleNetworkId ~= currentVehicleNetworkId then
        return
    end


    currentRadioVideoId = state.source == 'youtube' and state.videoId or nil

    SendNUIMessage({
        action = 'syncRadioState',
        state = state
    })
end)

RegisterNetEvent('acg_radio:client:error', function(message)
    local safeMessage = type(message) == 'string' and message or 'Radio request failed.'
    QBCore.Functions.Notify(safeMessage, 'error')
    SendNUIMessage({
        action = 'radioError',
        message = safeMessage
    })
end)

CreateThread(function()
    while true do
        Wait(Config.Sync.VehicleCheckInterval)

        local vehicle = GetCurrentVehicle()
        local networkId = GetVehicleNetworkId(vehicle)

        if networkId ~= currentVehicleNetworkId then
            if currentVehicleNetworkId ~= 0 then
                SendNUIMessage({ action = 'stopLocalPlayback' })
            end

            currentRadioVideoId = nil
            lastDriverState = networkId ~= 0 and IsPlayerDriver(vehicle) or nil

            if isRadioOpen then
                CloseRadio()
            end

            currentVehicleNetworkId = networkId

            if networkId ~= 0 then
                RequestCurrentState(networkId)
            end
        elseif networkId ~= 0 and isRadioOpen then
            local isDriver = IsPlayerDriver(vehicle)
            if isDriver ~= lastDriverState then
                lastDriverState = isDriver
                SendNUIMessage({
                    action = 'updateVehicleRole',
                    isDriver = isDriver,
                    driverOnly = Config.DriverOnly
                })
            end
        end
    end
end)

AddEventHandler('onClientResourceStart', function(resourceName)
    if resourceName ~= GetCurrentResourceName() then
        return
    end

    isRadioOpen = false
    currentVehicleNetworkId = 0
    currentRadioVideoId = nil
    lastDriverState = nil
    SetNuiFocus(false, false)
    SendNUIMessage({
        action = 'initialize',
        settings = {
            maxVolume = Config.MaxVolume,
            sync = Config.Sync,
            debug = Config.Debug
        }
    })
    SendNUIMessage({ action = 'closeRadio' })
end)

AddEventHandler('onResourceStop', function(resourceName)
    if resourceName ~= GetCurrentResourceName() then
        return
    end

    isRadioOpen = false
    currentVehicleNetworkId = 0
    currentRadioVideoId = nil
    lastDriverState = nil
    SetNuiFocus(false, false)
    SendNUIMessage({ action = 'stopLocalPlayback' })
end)
