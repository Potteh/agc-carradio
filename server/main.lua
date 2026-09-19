local QBCore = exports['qb-core']:GetCoreObject()

local validActions = {
    playYoutube = true,
    playStream = true,
    pause = true,
    resume = true,
    stop = true,
    setVolume = true
}

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

local function GetPlayerVehicle(source)
    local ped = GetPlayerPed(source)
    if ped == 0 then
        return 0
    end

    return GetVehiclePedIsIn(ped, false)
end

local function IsPlayerDriver(source, vehicle)
    return vehicle ~= 0 and GetPedInVehicleSeat(vehicle, -1) == GetPlayerPed(source)
end

RegisterNetEvent('acg_radio:server:requestAction', function(request)
    local source = source

    if type(request) ~= 'table' or not validActions[request.action] then
        DebugPrint(('Rejected malformed action from player %s'):format(source), request)
        return
    end

    local vehicle = GetPlayerVehicle(source)
    if vehicle == 0 then
        DebugPrint(('Rejected action from player %s: not in a vehicle'):format(source))
        return
    end

    -- Never trust the browser/client identifier without matching it to server state.
    local actualNetworkId = NetworkGetNetworkIdFromEntity(vehicle)
    if type(request.vehicleNetworkId) ~= 'number' or request.vehicleNetworkId ~= actualNetworkId then
        DebugPrint(('Rejected vehicle mismatch from player %s'):format(source), request)
        return
    end

    if Config.DriverOnly and not IsPlayerDriver(source, vehicle) then
        DebugPrint(('Rejected non-driver action from player %s'):format(source), request)
        return
    end

    -- Playback and synchronization will be implemented in a later phase.
    DebugPrint(('Validated "%s" from player %s for vehicle %s'):format(
        request.action,
        source,
        actualNetworkId
    ), request.data)
end)
