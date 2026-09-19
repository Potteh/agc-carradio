local QBCore = exports['qb-core']:GetCoreObject()

local VehicleRadios = {}
local RequestTimes = {}
local RateLimitWarnings = {}
local revision = 0

local function DebugPrint(message)
    if Config.Debug then
        print(('[acg_radio] %s'):format(message))
    end
end

local function NotifyPlayer(playerSource, message)
    TriggerClientEvent('acg_radio:client:error', playerSource, message)
end

local function GetServerTime()
    return GetGameTimer()
end

local function GetElapsedSeconds(startedAt, now)
    local elapsed = now - startedAt

    -- GetGameTimer wraps after reaching the unsigned 32-bit limit.
    if elapsed < 0 then
        elapsed = elapsed + 4294967296
    end

    return elapsed / 1000.0
end

local function GetCurrentPosition(state, now)
    if not state.playing then
        return state.position
    end

    return state.position + GetElapsedSeconds(state.startedAt, now)
end

local function NextRevision()
    revision = revision + 1
    return revision
end

local function IsRateLimited(playerSource, action)
    local now = GetServerTime()
    local cooldown = math.max(tonumber(Config.Sync.ControlCooldown) or 150, 0)
    local playerRequests = RequestTimes[playerSource]

    if not playerRequests then
        playerRequests = {}
        RequestTimes[playerSource] = playerRequests
    end

    local lastRequest = playerRequests[action]
    if lastRequest and GetElapsedSeconds(lastRequest, now) * 1000.0 < cooldown then
        return true
    end

    playerRequests[action] = now
    return false
end

local function RejectRateLimited(playerSource, action)
    local now = GetServerTime()
    local lastWarning = RateLimitWarnings[playerSource]

    if not lastWarning or GetElapsedSeconds(lastWarning, now) >= 1.0 then
        RateLimitWarnings[playerSource] = now
        NotifyPlayer(playerSource, 'Radio controls are being used too quickly.')
    end

    DebugPrint(('rate-limit player=%s action=%s'):format(playerSource, action))
end

local function IsValidVideoId(videoId)
    return type(videoId) == 'string'
        and #videoId == 11
        and videoId:match('^[%w_-]+$') ~= nil
end

local function IsValidNumber(value)
    return type(value) == 'number' and value == value and value ~= math.huge and value ~= -math.huge
end

local function Clamp(value, minimum, maximum)
    return math.max(minimum, math.min(maximum, value))
end

local function ValidateOccupiedVehicle(playerSource, requestedNetworkId, requireDriver)
    if type(playerSource) ~= 'number' or playerSource <= 0 or not GetPlayerName(playerSource) then
        return nil, nil, 'Invalid player source.'
    end

    if not QBCore.Functions.GetPlayer(playerSource) then
        return nil, nil, 'Player data is unavailable.'
    end

    if not IsValidNumber(requestedNetworkId) or requestedNetworkId <= 0 then
        return nil, nil, 'Invalid vehicle identifier.'
    end

    local ped = GetPlayerPed(playerSource)
    if ped == 0 or not DoesEntityExist(ped) then
        return nil, nil, 'Player entity is unavailable.'
    end

    local vehicle = GetVehiclePedIsIn(ped, false)
    if vehicle == 0 or not DoesEntityExist(vehicle) then
        return nil, nil, 'You must be inside a vehicle to use the radio.'
    end

    local actualNetworkId = NetworkGetNetworkIdFromEntity(vehicle)
    if actualNetworkId == 0 or requestedNetworkId ~= actualNetworkId then
        return nil, nil, 'Vehicle validation failed.'
    end

    if requireDriver and Config.DriverOnly and GetPedInVehicleSeat(vehicle, -1) ~= ped then
        return nil, nil, 'Only the driver can control the vehicle radio.'
    end

    return actualNetworkId, vehicle, nil
end

local function CreateIdleState(now, vehicle)
    return {
        source = 'none',
        videoId = false,
        volume = Clamp(Config.DefaultVolume, 0, Config.MaxVolume),
        playing = false,
        position = 0.0,
        startedAt = now,
        updatedAt = now,
        revision = NextRevision(),
        vehicleEntity = vehicle
    }
end

local function GetOrCreateState(networkId, now, vehicle)
    local state = VehicleRadios[networkId]

    -- A recycled network ID must never inherit another entity's radio state.
    if not state or state.vehicleEntity ~= vehicle then
        state = CreateIdleState(now, vehicle)
        VehicleRadios[networkId] = state
    end

    return state
end

local function BuildSnapshot(networkId, state)
    local now = GetServerTime()

    return {
        vehicleNetworkId = networkId,
        source = state.source,
        videoId = state.videoId,
        volume = state.volume,
        playing = state.playing,
        position = GetCurrentPosition(state, now),
        revision = state.revision,
        serverTimestamp = now
    }
end

local function BroadcastState(networkId, state)
    TriggerClientEvent('acg_radio:client:syncState', -1, BuildSnapshot(networkId, state))
end

local function Reject(playerSource, message)
    NotifyPlayer(playerSource, message)
    DebugPrint(('rejected player=%s reason=%s'):format(playerSource, message))
end

RegisterNetEvent('acg_radio:server:playYoutube', function(request)
    local playerSource = source
    if IsRateLimited(playerSource, 'playYoutube') then
        RejectRateLimited(playerSource, 'playYoutube')
        return
    end

    if type(request) ~= 'table' or not IsValidVideoId(request.videoId) then
        Reject(playerSource, 'Invalid YouTube video ID.')
        return
    end

    local networkId, vehicle, errorMessage = ValidateOccupiedVehicle(playerSource, request.vehicleNetworkId, true)
    if not networkId then
        Reject(playerSource, errorMessage)
        return
    end

    local now = GetServerTime()
    local previousState = GetOrCreateState(networkId, now, vehicle)
    local state = {
        source = 'youtube',
        videoId = request.videoId,
        volume = previousState.volume,
        playing = true,
        position = 0.0,
        startedAt = now,
        updatedAt = now,
        revision = NextRevision(),
        vehicleEntity = vehicle
    }

    VehicleRadios[networkId] = state
    BroadcastState(networkId, state)
    DebugPrint(('play player=%s vehicle=%s video=%s'):format(playerSource, networkId, state.videoId))
end)

RegisterNetEvent('acg_radio:server:pause', function(request)
    local playerSource = source
    if IsRateLimited(playerSource, 'pause') then
        RejectRateLimited(playerSource, 'pause')
        return
    end

    local networkId, vehicle, errorMessage = ValidateOccupiedVehicle(
        playerSource,
        type(request) == 'table' and request.vehicleNetworkId or nil,
        true
    )
    if not networkId then
        Reject(playerSource, errorMessage)
        return
    end

    local state = GetOrCreateState(networkId, GetServerTime(), vehicle)
    if not state or state.source ~= 'youtube' or not state.playing then
        Reject(playerSource, 'There is no playing YouTube source to pause.')
        return
    end

    local now = GetServerTime()
    state.position = GetCurrentPosition(state, now)
    state.playing = false
    state.startedAt = now
    state.updatedAt = now
    state.revision = NextRevision()

    BroadcastState(networkId, state)
    DebugPrint(('pause player=%s vehicle=%s position=%.1f'):format(playerSource, networkId, state.position))
end)

RegisterNetEvent('acg_radio:server:resume', function(request)
    local playerSource = source
    if IsRateLimited(playerSource, 'resume') then
        RejectRateLimited(playerSource, 'resume')
        return
    end

    local networkId, vehicle, errorMessage = ValidateOccupiedVehicle(
        playerSource,
        type(request) == 'table' and request.vehicleNetworkId or nil,
        true
    )
    if not networkId then
        Reject(playerSource, errorMessage)
        return
    end

    local state = GetOrCreateState(networkId, GetServerTime(), vehicle)
    if not state or state.source ~= 'youtube' or state.playing then
        Reject(playerSource, 'There is no paused YouTube source to resume.')
        return
    end

    local now = GetServerTime()
    state.playing = true
    state.startedAt = now
    state.updatedAt = now
    state.revision = NextRevision()

    BroadcastState(networkId, state)
    DebugPrint(('resume player=%s vehicle=%s position=%.1f'):format(playerSource, networkId, state.position))
end)

RegisterNetEvent('acg_radio:server:stop', function(request)
    local playerSource = source
    if type(request) ~= 'table' then
        Reject(playerSource, 'Invalid stop request.')
        return
    end

    if IsRateLimited(playerSource, 'stop') then
        RejectRateLimited(playerSource, 'stop')
        return
    end

    local isTerminalStop = request.terminal == true
        and request.expectedVideoId ~= nil

    local networkId, vehicle, errorMessage = ValidateOccupiedVehicle(
        playerSource,
        request.vehicleNetworkId,
        false
    )
    if not networkId then
        Reject(playerSource, errorMessage)
        return
    end


    local playerPed = GetPlayerPed(playerSource)
    if Config.DriverOnly and GetPedInVehicleSeat(vehicle, -1) ~= playerPed then
        local driverSeatEmpty = GetPedInVehicleSeat(vehicle, -1) == 0
        if not isTerminalStop or not driverSeatEmpty then
            Reject(playerSource, 'Only the driver can control the vehicle radio.')
            return
        end
    end

    local now = GetServerTime()
    local state = GetOrCreateState(networkId, now, vehicle)

    if request.expectedVideoId ~= nil then
        if not IsValidVideoId(request.expectedVideoId) then
            Reject(playerSource, 'Invalid expected YouTube video ID.')
            return
        end

        if state.source ~= 'youtube' or state.videoId ~= request.expectedVideoId then
            DebugPrint(('ignored stale stop player=%s vehicle=%s expected=%s'):format(
                playerSource,
                networkId,
                request.expectedVideoId
            ))
            return
        end
    end

    state.source = 'none'
    state.videoId = false
    state.playing = false
    state.position = 0.0
    state.startedAt = now
    state.updatedAt = now
    state.revision = NextRevision()

    BroadcastState(networkId, state)
    DebugPrint(('stop player=%s vehicle=%s'):format(playerSource, networkId))
end)

RegisterNetEvent('acg_radio:server:seek', function(request)
    local playerSource = source
    if IsRateLimited(playerSource, 'seek') then
        RejectRateLimited(playerSource, 'seek')
        return
    end

    if type(request) ~= 'table' or not IsValidNumber(request.position) then
        Reject(playerSource, 'Invalid playback position.')
        return
    end

    local networkId, vehicle, errorMessage = ValidateOccupiedVehicle(playerSource, request.vehicleNetworkId, true)
    if not networkId then
        Reject(playerSource, errorMessage)
        return
    end

    local state = GetOrCreateState(networkId, GetServerTime(), vehicle)
    if not state or state.source ~= 'youtube' then
        Reject(playerSource, 'There is no YouTube source to seek.')
        return
    end

    local now = GetServerTime()
    state.position = Clamp(request.position, 0.0, 86400.0)
    state.startedAt = now
    state.updatedAt = now
    state.revision = NextRevision()

    BroadcastState(networkId, state)
    DebugPrint(('seek player=%s vehicle=%s position=%.1f'):format(playerSource, networkId, state.position))
end)

RegisterNetEvent('acg_radio:server:setVolume', function(request)
    local playerSource = source
    if IsRateLimited(playerSource, 'setVolume') then
        RejectRateLimited(playerSource, 'setVolume')
        return
    end

    if type(request) ~= 'table' or not IsValidNumber(request.volume) then
        Reject(playerSource, 'Invalid volume value.')
        return
    end

    local networkId, vehicle, errorMessage = ValidateOccupiedVehicle(playerSource, request.vehicleNetworkId, true)
    if not networkId then
        Reject(playerSource, errorMessage)
        return
    end

    local now = GetServerTime()
    local state = GetOrCreateState(networkId, now, vehicle)
    state.volume = Clamp(math.floor(request.volume + 0.5), 0, Config.MaxVolume)
    state.updatedAt = now
    state.revision = NextRevision()

    BroadcastState(networkId, state)
    DebugPrint(('volume player=%s vehicle=%s volume=%s'):format(playerSource, networkId, state.volume))
end)

RegisterNetEvent('acg_radio:server:requestState', function(request)
    local playerSource = source
    local networkId, vehicle, errorMessage = ValidateOccupiedVehicle(
        playerSource,
        type(request) == 'table' and request.vehicleNetworkId or nil,
        false
    )
    if not networkId then
        Reject(playerSource, errorMessage)
        return
    end

    local state = GetOrCreateState(networkId, GetServerTime(), vehicle)
    TriggerClientEvent('acg_radio:client:syncState', playerSource, BuildSnapshot(networkId, state))
end)

RegisterNetEvent('acg_radio:server:requestActiveRadios', function()
    local playerSource = source
    if type(playerSource) ~= 'number'
        or playerSource <= 0
        or not GetPlayerName(playerSource)
        or not QBCore.Functions.GetPlayer(playerSource) then
        return
    end

    if IsRateLimited(playerSource, 'requestActiveRadios') then
        return
    end

    local snapshots = {}
    for networkId, state in pairs(VehicleRadios) do
        if state.source == 'youtube' then
            snapshots[#snapshots + 1] = BuildSnapshot(networkId, state)
        end
    end

    TriggerClientEvent('acg_radio:client:activeRadios', playerSource, snapshots)
end)

CreateThread(function()
    while true do
        Wait(Config.Sync.StateCleanupInterval)

        for networkId, state in pairs(VehicleRadios) do
            local vehicle = NetworkGetEntityFromNetworkId(networkId)
            if vehicle == 0 or not DoesEntityExist(vehicle) or state.vehicleEntity ~= vehicle then
                VehicleRadios[networkId] = nil
                TriggerClientEvent('acg_radio:client:removeRadio', -1, networkId)
                DebugPrint(('cleanup vehicle=%s'):format(networkId))
            end
        end
    end
end)

AddEventHandler('playerDropped', function()
    RequestTimes[source] = nil
    RateLimitWarnings[source] = nil
end)
