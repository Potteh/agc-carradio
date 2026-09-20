local QBCore = exports['qb-core']:GetCoreObject()

local STREAMER_MODE_KVP = 'acg_radio_streamer_mode'

local isRadioOpen = false
local streamerMode = GetResourceKvpString(STREAMER_MODE_KVP) == '1'
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

local function IsValidIpv6Host(host)
    local address = host:sub(2, -2)
    if address == '' or address:find('[^0-9a-fA-F:]') or address:find(':::', 1, true) then
        return false
    end

    local _, compressionCount = address:gsub('::', '')
    if compressionCount > 1 then
        return false
    end

    local groupCount = 0
    for group in address:gmatch('[^:]+') do
        if #group < 1 or #group > 4 then
            return false
        end
        groupCount = groupCount + 1
    end

    if compressionCount == 1 then
        return groupCount < 8
    end

    return groupCount == 8 and address:sub(1, 1) ~= ':' and address:sub(-1) ~= ':'
end

local function IsValidStreamUrl(streamUrl)
    if type(streamUrl) ~= 'string' then
        return false
    end

    local maximumLength = math.max(tonumber(Config.Streams and Config.Streams.MaxUrlLength) or 2048, 1)
    if streamUrl == ''
        or #streamUrl > maximumLength
        or streamUrl:find('[%z\1-\31\127]')
        or streamUrl:find('%s')
        or not streamUrl:lower():match('^https?://') then
        return false
    end

    local schemeEnd = streamUrl:find('://', 1, true)
    local authority = schemeEnd and streamUrl:sub(schemeEnd + 3):match('^([^/%?#]+)') or nil
    if not authority or authority == '' or authority:find('@', 1, true) then
        return false
    end

    local host
    local port
    if authority:sub(1, 1) == '[' then
        host = authority:match('^(%[[0-9a-fA-F:]+%])$')
        if host then
            port = ''
        else
            host, port = authority:match('^(%[[0-9a-fA-F:]+%]):(%d+)$')
        end
        if not host or not IsValidIpv6Host(host) then
            return false
        end
    else
        host, port = authority:match('^([%w%.%-]+):?(%d*)$')
        if not host or not host:match('[%w]') then
            return false
        end
    end

    return port == '' or (tonumber(port) and tonumber(port) >= 1 and tonumber(port) <= 65535)
end

local function IsActiveRadioState(state)
    if type(state) ~= 'table' or type(state.vehicleNetworkId) ~= 'number' then
        return false
    end

    if state.source == 'youtube' then
        return IsValidVideoId(state.videoId)
    end

    return state.source == 'stream' and IsValidStreamUrl(state.streamUrl)
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
    if state.source ~= 'youtube' then
        return 0.0
    end

    local position = tonumber(state.position) or 0.0
    if state.playing and state.receivedAt then
        position = position + (GetElapsedMilliseconds(state.receivedAt, GetGameTimer()) / 1000.0)
    end

    return math.max(position, 0.0)
end

local function GetOutsideAttenuation(distance)
    local maxDistance = math.max(tonumber(Config.Audio.MaxDistance) or 35.0, 0.1)
    local fullDistance = Clamp(tonumber(Config.Audio.FullVolumeDistance) or 2.0, 0.0, maxDistance)

    if distance >= maxDistance then
        return 0.0
    end

    local range = maxDistance - fullDistance
    if range <= 0.0 then
        return distance <= fullDistance and 1.0 or 0.0
    end

    local normalized = Clamp((distance - fullDistance) / range, 0.0, 1.0)
    local exponent = math.max(tonumber(Config.Audio.AttenuationExponent) or 1.5, 0.01)
    return (1.0 - normalized) ^ exponent
end

local function GetOutsideVolume(baseVolume, distance)
    local attenuation = GetOutsideAttenuation(distance)
    return baseVolume * (tonumber(Config.Audio.OutsideVehicleMultiplier) or 1.0) * attenuation
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
    if streamerMode then
        return 0
    end

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
        stationId = state.stationId,
        stationName = state.stationName,
        genre = state.genre,
        streamUrl = state.streamUrl,
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
            local attenuation = selectedSourceInside and 1.0 or GetOutsideAttenuation(distance or 0.0)
            DebugPrint(('proximity vehicle=%s distance=%.1f baseVolume=%s attenuation=%.2f effectiveVolume=%s'):format(
                networkId,
                distance or 0.0,
                tonumber(state.volume) or 0,
                attenuation,
                localVolume
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
    elseif occupiedVehicle ~= 0 and not Config.Audio.HearOutsideWhileInSilentVehicle then
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

local function SetStreamerMode(enabled, showNotification)
    streamerMode = enabled == true
    SetResourceKvp(STREAMER_MODE_KVP, streamerMode and '1' or '0')

    local restoreVolume = nil
    local state = ActiveRadios[selectedSourceNetworkId]
    if not streamerMode and state then
        restoreVolume = CalculateEffectiveVolume(
            state,
            selectedSourceDistance,
            selectedSourceInside
        )
    end

    SendNUIMessage({
        action = 'setStreamerMode',
        enabled = streamerMode,
        restoreVolume = restoreVolume
    })

    lastEffectiveVolume = -1
    UpdateProximitySelection()

    if showNotification then
        if streamerMode then
            QBCore.Functions.Notify('Streamer Mode Enabled - Vehicle music muted.', 'success')
        else
            QBCore.Functions.Notify('Streamer Mode Disabled - Vehicle music restored.', 'success')
        end
    end

    DebugPrint(('streamer mode=%s'):format(streamerMode and 'enabled' or 'disabled'))
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

local function GetStreamUiSettings()
    local stations = {}

    for _, station in ipairs(Config.RadioStations or {}) do
        if type(station) == 'table'
            and type(station.id) == 'string'
            and #station.id >= 1
            and #station.id <= 64
            and station.id:match('^[%w_-]+$')
            and type(station.name) == 'string'
            and not station.name:find('[%z\1-\31\127]')
            and station.name:match('%S')
            and IsValidStreamUrl(station.url) then
            local genre = type(station.genre) == 'string'
                and not station.genre:find('[%z\1-\31\127]')
                and station.genre:match('%S')
                and station.genre:match('^%s*(.-)%s*$'):sub(1, 32)
                or 'Radio'
            stations[#stations + 1] = {
                id = station.id,
                name = station.name:match('^%s*(.-)%s*$'):sub(1, 64),
                genre = genre
            }
        end
    end

    return {
        allowCustomUrls = Config.Streams and Config.Streams.AllowCustomUrls == true,
        maxUrlLength = math.max(tonumber(Config.Streams and Config.Streams.MaxUrlLength) or 2048, 1),
        stations = stations
    }
end

local function GetNuiSettings()
    return {
        defaultVolume = Config.DefaultVolume,
        maxVolume = Config.MaxVolume,
        driverOnly = Config.DriverOnly,
        sync = Config.Sync,
        debug = Config.Debug,
        streamerMode = streamerMode,
        streams = GetStreamUiSettings(),
        queue = {
            enabled = Config.Queue and Config.Queue.Enabled == true,
            maxItems = math.max(math.floor(tonumber(Config.Queue and Config.Queue.MaxItems) or 20), 1)
        }
    }
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
        settings = GetNuiSettings()
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

RegisterCommand(Config.StreamerModeCommand, function()
    SetStreamerMode(not streamerMode, true)
end, false)

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

RegisterNUICallback('playStation', function(data, callback)
    local stationId = type(data) == 'table' and data.stationId or nil
    if type(stationId) ~= 'string'
        or #stationId < 1
        or #stationId > 64
        or not stationId:match('^[%w_-]+$') then
        callback({ ok = false, error = 'invalid_station' })
        return
    end

    SendControlRequest('acg_radio:server:playStation', {
        stationId = stationId
    }, callback)
end)

RegisterNUICallback('playStream', function(data, callback)
    if not Config.Streams or Config.Streams.AllowCustomUrls ~= true then
        callback({ ok = false, error = 'custom_streams_disabled' })
        return
    end

    local streamUrl = type(data) == 'table' and data.streamUrl or nil
    if not IsValidStreamUrl(streamUrl) then
        QBCore.Functions.Notify('Enter a valid HTTP or HTTPS direct stream URL.', 'error')
        callback({ ok = false, error = 'invalid_stream_url' })
        return
    end

    SendControlRequest('acg_radio:server:playCustomStream', {
        streamUrl = streamUrl,
        stationName = type(data.stationName) == 'string' and data.stationName:sub(1, 64) or nil
    }, callback)
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

RegisterNUICallback('addToQueue', function(data, callback)
    local videoId = type(data) == 'table' and data.videoId or nil
    if not IsValidVideoId(videoId) then
        callback({ ok = false, error = 'invalid_video' })
        return
    end

    SendControlRequest('acg_radio:server:addToQueue', {
        videoId = videoId,
        title = type(data.title) == 'string' and data.title or nil,
        author = type(data.author) == 'string' and data.author or nil
    }, callback)
end)

RegisterNUICallback('removeQueueItem', function(data, callback)
    local index = type(data) == 'table' and tonumber(data.index) or nil
    if not index then
        callback({ ok = false, error = 'invalid_index' })
        return
    end

    SendControlRequest('acg_radio:server:removeQueueItem', { index = index }, callback)
end)

RegisterNUICallback('skip', function(_, callback)
    SendControlRequest('acg_radio:server:skip', {}, callback)
end)

RegisterNUICallback('youtubeMetadata', function(data, callback)
    if type(data) ~= 'table' or not IsValidVideoId(data.videoId) then
        callback({ ok = false })
        return
    end

    local vehicle = GetCurrentVehicle()
    local networkId = GetVehicleNetworkId(vehicle)
    if networkId == 0 or networkId ~= currentVehicleNetworkId then
        callback({ ok = false })
        return
    end

    TriggerServerEvent('acg_radio:server:updateMetadata', {
        vehicleNetworkId = networkId,
        videoId = data.videoId,
        title = data.title,
        author = data.author,
        duration = tonumber(data.duration)
    })
    callback({ ok = true })
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
    local videoId = type(data) == 'table' and data.videoId or nil
    if not IsValidVideoId(videoId) or videoId ~= currentRadioVideoId then
        callback({ ok = false })
        return
    end

    local vehicle = GetCurrentVehicle()
    local networkId = GetVehicleNetworkId(vehicle)
    if networkId == 0 or networkId ~= currentVehicleNetworkId then
        callback({ ok = false })
        return
    end

    TriggerServerEvent('acg_radio:server:trackEnded', {
        vehicleNetworkId = networkId,
        expectedVideoId = videoId
    })
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

RegisterNUICallback('streamError', function(data, callback)
    local message = 'Unable to play this radio stream.'
    if isRadioOpen then
        QBCore.Functions.Notify(message, 'error')
    end
    if Config.Debug then
        DebugPrint(('stream playback error code=%s'):format(
            type(data) == 'table' and tostring(data.code or 'unknown') or 'unknown'
        ))
    end

    callback({ ok = true })
end)

RegisterNUICallback('streamDebug', function(data, callback)
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
    SendNUIMessage({
        action = 'initialize',
        settings = GetNuiSettings()
    })

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
        settings = GetNuiSettings()
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
