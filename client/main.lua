local QBCore = exports['qb-core']:GetCoreObject()

local isRadioOpen = false
local currentVehicleNetworkId = 0
local currentRadioVideoId = nil
local lastDriverState = nil
local ActiveRadios = {}
local unresolvedSince = {}
local selectedSourceNetworkId = 0
local selectedSourceDistance = nil
local selectedSourceInside = false
local lastEffectiveVolume = -1
local lastVolumeDebugAt = 0

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

local function Clamp(value, minimum, maximum)
    return math.max(minimum, math.min(maximum, value))
end

local function GetElapsedMilliseconds(startedAt, now)
    local elapsed = now - startedAt
    if elapsed < 0 then
        elapsed = elapsed + 4294967296
    end

    return elapsed
end

local function ResolveVehicle(networkId)
    if type(networkId) ~= 'number'
        or networkId <= 0
        or not NetworkDoesEntityExistWithNetworkId(networkId) then
        return 0
    end

    local vehicle = NetToVeh(networkId)
    if vehicle == 0 or not DoesEntityExist(vehicle) or GetEntityType(vehicle) ~= 2 then
        return 0
    end

    return vehicle
end

local function IsValidVideoId(videoId)
    return type(videoId) == 'string'
        and #videoId == 11
        and videoId:match('^[%w_-]+$') ~= nil
end

local function IsActiveRadioState(state)
    return type(state) == 'table'
        and state.source == 'youtube'
        and IsValidVideoId(state.videoId)
        and type(state.vehicleNetworkId) == 'number'
end

local function StoreRadioState(state)
    if type(state) ~= 'table' or type(state.vehicleNetworkId) ~= 'number' then
        return false
    end

    local networkId = state.vehicleNetworkId
    if not IsActiveRadioState(state) then
        ActiveRadios[networkId] = nil
        unresolvedSince[networkId] = nil
        return false
    end

    state.receivedAt = GetGameTimer()
    ActiveRadios[networkId] = state
    return true
end

local function GetExpectedPosition(state)
    local position = tonumber(state.position) or 0.0
    if state.playing and state.receivedAt then
        position = position + (GetElapsedMilliseconds(state.receivedAt, GetGameTimer()) / 1000.0)
    end

    return math.max(position, 0.0)
end

local function GetOutsideVolume(baseVolume, distance)
    local maxDistance = math.max(tonumber(Config.Audio.MaxDistance) or 35.0, 0.1)
    local fullDistance = Clamp(tonumber(Config.Audio.FullVolumeDistance) or 4.0, 0.0, maxDistance)

    if distance >= maxDistance then
        return 0
    end

    local attenuation = 1.0
    if distance > fullDistance and maxDistance > fullDistance then
        attenuation = 1.0 - ((distance - fullDistance) / (maxDistance - fullDistance))
    end

    return baseVolume * (tonumber(Config.Audio.OutsideVehicleMultiplier) or 0.70) * attenuation
end

local function CalculateEffectiveVolume(state, distance, isInside)
    local baseVolume = Clamp(tonumber(state.volume) or 0.0, 0.0, Config.MaxVolume)
    local volume

    if isInside then
        volume = baseVolume * (tonumber(Config.Audio.InsideVehicleMultiplier) or 1.0)
    else
        volume = GetOutsideVolume(baseVolume, distance or Config.Audio.MaxDistance)
    end

    volume = Clamp(volume, 0.0, 100.0)
    if volume < (tonumber(Config.Audio.MinAudibleVolume) or 1.0) then
        return 0
    end

    return math.floor(volume + 0.5)
end

local function BuildPlaybackState(state, localVolume)
    return {
        vehicleNetworkId = state.vehicleNetworkId,
        source = state.source,
        videoId = state.videoId,
        volume = state.volume,
        localVolume = localVolume,
        playing = state.playing == true,
        position = GetExpectedPosition(state),
        revision = state.revision,
        serverTimestamp = state.serverTimestamp
    }
end

local function SendSelectedState(state, localVolume)
    SendNUIMessage({
        action = 'syncRadioState',
        state = BuildPlaybackState(state, localVolume)
    })
end

local function SendLocalVolume(networkId, state, localVolume, distance)
    if math.abs(localVolume - lastEffectiveVolume) < 1 then
        return
    end

    lastEffectiveVolume = localVolume
    SendNUIMessage({
        action = 'setLocalVolume',
        vehicleNetworkId = networkId,
        volume = localVolume
    })

    if Config.Debug then
        local now = GetGameTimer()
        if GetElapsedMilliseconds(lastVolumeDebugAt, now) >= 2000 then
            lastVolumeDebugAt = now
            DebugPrint(('effective volume vehicle=%s base=%s local=%s distance=%.1f'):format(
                networkId,
                tonumber(state.volume) or 0,
                localVolume,
                distance or 0.0
            ))
        end
    end
end

local function GetRadioCandidate(networkId, state, playerCoords, occupiedVehicle)
    local vehicle = 0
    if occupiedVehicle ~= 0 and GetVehicleNetworkId(occupiedVehicle) == networkId then
        vehicle = occupiedVehicle
    else
        vehicle = ResolveVehicle(networkId)
    end

    if vehicle == 0 then
        if not unresolvedSince[networkId] then
            unresolvedSince[networkId] = GetGameTimer()
        end
        return nil
    end

    unresolvedSince[networkId] = nil
    local distance = #(playerCoords - GetEntityCoords(vehicle))
    return {
        networkId = networkId,
        state = state,
        vehicle = vehicle,
        distance = distance
    }
end

local function ChangeSelectedSource(networkId, distance, isInside)
    local previousSource = selectedSourceNetworkId
    if previousSource == networkId then
        selectedSourceDistance = distance
        selectedSourceInside = isInside
        return
    end

    if previousSource ~= 0 then
        SendNUIMessage({ action = 'stopLocalPlayback' })
    end

    selectedSourceNetworkId = networkId
    selectedSourceDistance = distance
    selectedSourceInside = isInside
    lastEffectiveVolume = -1

    DebugPrint(('source changed %s -> %s'):format(previousSource, networkId))

    if networkId == 0 then
        currentRadioVideoId = nil
        return
    end

    local state = ActiveRadios[networkId]
    if not state then
        selectedSourceNetworkId = 0
        currentRadioVideoId = nil
        return
    end

    local localVolume = CalculateEffectiveVolume(state, distance, isInside)
    lastEffectiveVolume = localVolume
    currentRadioVideoId = state.videoId
    SendSelectedState(state, localVolume)

    DebugPrint(('selected source vehicle=%s distance=%.1f'):format(networkId, distance or 0.0))
    if isInside then
        DebugPrint(('entered source vehicle=%s'):format(networkId))
    end
end

local function RefreshSelectedState()
    local networkId = selectedSourceNetworkId
    local state = ActiveRadios[networkId]
    if networkId == 0 or not state then
        return
    end

    local localVolume = CalculateEffectiveVolume(state, selectedSourceDistance, selectedSourceInside)
    lastEffectiveVolume = localVolume
    currentRadioVideoId = state.videoId
    SendSelectedState(state, localVolume)
end

local function UpdateProximitySelection()
    local ped = PlayerPedId()
    if ped == 0 or not DoesEntityExist(ped) then
        ChangeSelectedSource(0, nil, false)
        return
    end

    local playerCoords = GetEntityCoords(ped)
    local occupiedVehicle = GetCurrentVehicle()
    local occupiedNetworkId = GetVehicleNetworkId(occupiedVehicle)
    local targetNetworkId = 0
    local targetDistance = nil
    local targetInside = false

    if occupiedNetworkId ~= 0 and ActiveRadios[occupiedNetworkId] then
        targetNetworkId = occupiedNetworkId
        targetDistance = 0.0
        targetInside = true
    elseif occupiedNetworkId ~= 0 and not Config.Audio.HearOutsideWhileInSilentVehicle then
        targetNetworkId = 0
    else
        local nearestCandidate = nil
        local currentCandidate = nil
        local maxDistance = tonumber(Config.Audio.MaxDistance) or 35.0

        for networkId, state in pairs(ActiveRadios) do
            local candidate = GetRadioCandidate(networkId, state, playerCoords, occupiedVehicle)
            if candidate and candidate.distance < maxDistance then
                if not nearestCandidate or candidate.distance < nearestCandidate.distance then
                    nearestCandidate = candidate
                end
                if networkId == selectedSourceNetworkId then
                    currentCandidate = candidate
                end
            end
        end

        if selectedSourceNetworkId ~= 0
            and ActiveRadios[selectedSourceNetworkId]
            and not currentCandidate
            and unresolvedSince[selectedSourceNetworkId] then
            local unresolvedFor = GetElapsedMilliseconds(
                unresolvedSince[selectedSourceNetworkId],
                GetGameTimer()
            )
            if unresolvedFor < (tonumber(Config.Audio.EntityResolveGrace) or 2000) then
                local state = ActiveRadios[selectedSourceNetworkId]
                selectedSourceDistance = maxDistance
                selectedSourceInside = false
                SendLocalVolume(selectedSourceNetworkId, state, 0, maxDistance)
                return
            end
        end

        if currentCandidate then
            targetNetworkId = currentCandidate.networkId
            targetDistance = currentCandidate.distance

            if nearestCandidate and nearestCandidate.networkId ~= currentCandidate.networkId then
                local threshold = tonumber(Config.Audio.SourceSwitchThreshold) or 3.0
                if nearestCandidate.distance + threshold < currentCandidate.distance then
                    targetNetworkId = nearestCandidate.networkId
                    targetDistance = nearestCandidate.distance
                end
            end
        elseif nearestCandidate then
            targetNetworkId = nearestCandidate.networkId
            targetDistance = nearestCandidate.distance
        end
    end

    if selectedSourceNetworkId ~= 0 and targetNetworkId == 0 then
        DebugPrint(('source vehicle out of range=%s'):format(selectedSourceNetworkId))
    end

    local previousSource = selectedSourceNetworkId
    local previousInside = selectedSourceInside
    ChangeSelectedSource(targetNetworkId, targetDistance, targetInside)

    if targetNetworkId == 0 then
        return
    end

    local state = ActiveRadios[targetNetworkId]
    if not state then
        return
    end

    if previousSource == targetNetworkId and previousInside and not targetInside then
        DebugPrint(('left source vehicle=%s'):format(targetNetworkId))
    elseif previousSource == targetNetworkId and not previousInside and targetInside then
        DebugPrint(('entered source vehicle=%s'):format(targetNetworkId))
    end

    local localVolume = CalculateEffectiveVolume(state, targetDistance, targetInside)
    SendLocalVolume(targetNetworkId, state, localVolume, targetDistance)
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

    TriggerServerEvent('acg_radio:server:requestActiveRadios')

    callback({ ok = true })
end)

RegisterNetEvent('acg_radio:client:syncState', function(state)
    if type(state) ~= 'table' or type(state.vehicleNetworkId) ~= 'number' then
        return
    end

    local networkId = state.vehicleNetworkId
    StoreRadioState(state)

    if selectedSourceNetworkId == networkId then
        if ActiveRadios[networkId] then
            RefreshSelectedState()
        else
            ChangeSelectedSource(0, nil, false)
            UpdateProximitySelection()
        end
    else
        UpdateProximitySelection()
    end
end)

RegisterNetEvent('acg_radio:client:activeRadios', function(states)
    if type(states) ~= 'table' then
        return
    end

    for _, state in ipairs(states) do
        StoreRadioState(state)
    end

    UpdateProximitySelection()
end)

RegisterNetEvent('acg_radio:client:removeRadio', function(networkId)
    if type(networkId) ~= 'number' then
        return
    end

    ActiveRadios[networkId] = nil
    unresolvedSince[networkId] = nil

    if selectedSourceNetworkId == networkId then
        DebugPrint(('selected source vehicle removed=%s'):format(networkId))
        ChangeSelectedSource(0, nil, false)
        UpdateProximitySelection()
    end
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

CreateThread(function()
    while true do
        Wait(Config.Audio.UpdateInterval)
        UpdateProximitySelection()
    end
end)

RegisterNetEvent('QBCore:Client:OnPlayerLoaded', function()
    TriggerServerEvent('acg_radio:server:requestActiveRadios')
end)

AddEventHandler('onClientResourceStart', function(resourceName)
    if resourceName ~= GetCurrentResourceName() then
        return
    end

    isRadioOpen = false
    currentVehicleNetworkId = 0
    currentRadioVideoId = nil
    lastDriverState = nil
    ActiveRadios = {}
    unresolvedSince = {}
    selectedSourceNetworkId = 0
    selectedSourceDistance = nil
    selectedSourceInside = false
    lastEffectiveVolume = -1
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
    ActiveRadios = {}
    unresolvedSince = {}
    selectedSourceNetworkId = 0
    selectedSourceDistance = nil
    selectedSourceInside = false
    lastEffectiveVolume = -1
    SetNuiFocus(false, false)
    SendNUIMessage({ action = 'stopLocalPlayback' })
end)
