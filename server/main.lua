local QBCore = exports['qb-core']:GetCoreObject()

local VehicleRadios = {}
local RequestTimes = {}
local RateLimitWarnings = {}
local revision = 0
local adminMenuAvailable = nil

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
    if state.source ~= 'youtube' then
        return 0.0
    end

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

local function SanitizeText(value, maximumLength)
    if type(value) ~= 'string' then
        return nil
    end

    value = value:match('^%s*(.-)%s*$')
    if value == '' or value:find('[%z\1-\31\127]') then
        return nil
    end

    return value:sub(1, maximumLength)
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
    if streamUrl == '' or #streamUrl > maximumLength or streamUrl:find('[%z\1-\31\127]') then
        return false
    end

    if streamUrl:find('%s') or not streamUrl:lower():match('^https?://') then
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

local function GetRadioStationById(stationId)
    if type(stationId) ~= 'string'
        or #stationId < 1
        or #stationId > 64
        or not stationId:match('^[%w_-]+$') then
        return nil
    end

    for _, station in ipairs(Config.RadioStations or {}) do
        if type(station) == 'table'
            and station.id == stationId
            and IsValidStreamUrl(station.url) then
            local name = SanitizeText(station.name, 64)
            if name then
                return {
                    id = stationId,
                    name = name,
                    genre = SanitizeText(station.genre, 32) or 'Radio',
                    url = station.url
                }
            end
        end
    end

    return nil
end

local function IsValidNumber(value)
    return type(value) == 'number' and value == value and value ~= math.huge and value ~= -math.huge
end

local function Clamp(value, minimum, maximum)
    return math.max(minimum, math.min(maximum, value))
end

local function NormalizeNetworkId(networkId)
    if not IsValidNumber(networkId)
        or networkId <= 0
        or networkId ~= math.floor(networkId) then
        return nil
    end

    return networkId
end

local function GetAdminMenuResourceName()
    local integrations = Config.Integrations
    local adminMenu = integrations and integrations.AdminMenu

    if not adminMenu or adminMenu.Enabled ~= true then
        return nil
    end

    local resourceName = adminMenu.ResourceName
    if type(resourceName) ~= 'string' or resourceName == '' then
        return nil
    end

    return resourceName
end


local function IsAdminMenuAvailable()
    local resourceName = GetAdminMenuResourceName()
    return resourceName ~= nil and GetResourceState(resourceName) == 'started'
end

local function RefreshAdminMenuAvailability(forceUnavailable)
    local resourceName = GetAdminMenuResourceName()
    local available = not forceUnavailable and IsAdminMenuAvailable()

    if adminMenuAvailable == available then
        return
    end

    adminMenuAvailable = available
    if available then
        DebugPrint(('Optional admin integration available: %s'):format(resourceName))
    else
        DebugPrint('Optional admin integration unavailable; standalone mode')
    end
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

local function NormalizePlate(vehicle)
    if not vehicle or vehicle == 0 or not DoesEntityExist(vehicle) then
        return nil
    end

    local plate = GetVehicleNumberPlateText(vehicle)
    if type(plate) ~= 'string' then
        return nil
    end

    plate = plate:match('^%s*(.-)%s*$'):upper()
    if plate == '' then
        return nil
    end

    return plate:sub(1, 16)
end

local function PreferenceKey(plate)
    return ('agc_carradio_vehicle_%s'):format(plate:gsub('[^%w%-_]', '_'))
end

local function LoadVehiclePreferences(vehicle)
    if not Config.Persistence or Config.Persistence.Enabled ~= true then
        return nil
    end

    local plate = NormalizePlate(vehicle)
    if not plate then return nil end
    local raw = GetResourceKvpString(PreferenceKey(plate))
    if not raw or raw == '' then return { plate = plate } end

    local ok, data = pcall(json.decode, raw)
    if not ok or type(data) ~= 'table' then return { plate = plate } end
    data.plate = plate
    return data
end

local function SaveVehiclePreferences(vehicle, updates)
    if not Config.Persistence or Config.Persistence.Enabled ~= true then return end
    local plate = NormalizePlate(vehicle)
    if not plate then return end

    local existing = LoadVehiclePreferences(vehicle) or { plate = plate }
    for key, value in pairs(updates or {}) do existing[key] = value end
    existing.plate = nil
    SetResourceKvp(PreferenceKey(plate), json.encode(existing))
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
        vehicleEntity = vehicle,
        queue = {}
    }
end

local function GetOrCreateState(networkId, now, vehicle)
    local state = VehicleRadios[networkId]

    -- A recycled network ID must never inherit another entity's radio state.
    if not state or state.vehicleEntity ~= vehicle then
        state = CreateIdleState(now, vehicle)
        local prefs = LoadVehiclePreferences(vehicle)
        if prefs and Config.Persistence and Config.Persistence.SaveVolume ~= false then
            local savedVolume = tonumber(prefs.volume)
            if savedVolume then state.volume = Clamp(math.floor(savedVolume + 0.5), 0, Config.MaxVolume) end
        end

        if prefs and Config.Persistence and Config.Persistence.RestoreLastStationOnEnter == true
            and Config.Persistence.SaveConfiguredStation ~= false and type(prefs.stationId) == 'string' then
            local station = GetRadioStationById(prefs.stationId)
            if station then
                state.source = 'stream'
                state.stationId = station.id
                state.stationName = station.name
                state.genre = station.genre
                state.streamUrl = station.url
                state.playing = true
                state.updatedAt = now
                state.revision = NextRevision()
            end
        end
        VehicleRadios[networkId] = state
    end

    return state
end

local function BuildSnapshot(networkId, state)
    local now = GetServerTime()
    local snapshot = {
        vehicleNetworkId = networkId,
        source = state.source,
        videoId = state.videoId,
        volume = state.volume,
        playing = state.playing,
        position = GetCurrentPosition(state, now),
        revision = state.revision,
        serverTimestamp = now,
        title = state.title,
        author = state.author,
        duration = state.duration,
        queue = {}
    }

    for index, item in ipairs(state.queue or {}) do
        snapshot.queue[index] = {
            videoId = item.videoId,
            title = item.title,
            author = item.author,
            duration = item.duration
        }
    end

    if state.source == 'stream' then
        snapshot.stationId = state.stationId
        snapshot.stationName = state.stationName
        snapshot.genre = state.genre
        snapshot.streamUrl = state.streamUrl
    end

    return snapshot
end

local function BroadcastState(networkId, state)
    TriggerClientEvent('acg_radio:client:syncState', -1, BuildSnapshot(networkId, state))
end

local function IsActiveRadioState(state)
    if type(state) ~= 'table' then
        return false
    end

    if state.source == 'youtube' then
        return IsValidVideoId(state.videoId)
    end

    return state.source == 'stream' and IsValidStreamUrl(state.streamUrl)
end

local function StopVehicleRadioInternal(networkId, reason, expectedVideoId)
    networkId = NormalizeNetworkId(networkId)
    if not networkId then
        return false
    end

    local state = VehicleRadios[networkId]
    if not IsActiveRadioState(state) then
        return false
    end

    if expectedVideoId ~= nil and state.videoId ~= expectedVideoId then
        return false
    end

    local now = GetServerTime()
    state.source = 'none'
    state.videoId = false
    state.stationId = nil
    state.stationName = nil
    state.genre = nil
    state.streamUrl = nil
    state.title = nil
    state.author = nil
    state.duration = nil
    state.queue = {}
    state.playing = false
    state.position = 0.0
    state.startedAt = now
    state.updatedAt = now
    state.revision = NextRevision()

    BroadcastState(networkId, state)
    DebugPrint(('stop vehicle=%s reason=%s'):format(networkId, reason or 'unspecified'))
    return true
end

local function GetVehiclePlate(state)
    local vehicle = state.vehicleEntity
    if not vehicle or vehicle == 0 or not DoesEntityExist(vehicle) then
        return nil
    end

    local success, plate = pcall(GetVehicleNumberPlateText, vehicle)
    if not success or type(plate) ~= 'string' then
        return nil
    end

    plate = plate:match('^%s*(.-)%s*$')
    return plate ~= '' and plate:sub(1, 32) or nil
end

local function BuildPublicRadioState(networkId, state)
    if not IsActiveRadioState(state) then
        return nil
    end

    local publicState = {
        netId = networkId,
        plate = GetVehiclePlate(state),
        source = state.source,
        videoId = state.videoId,
        volume = state.volume,
        playing = state.playing == true,
        title = state.title,
        author = state.author,
        duration = state.duration,
        queueLength = #(state.queue or {})
    }

    if state.source == 'youtube' then
        publicState.position = GetCurrentPosition(state, GetServerTime())
    else
        publicState.stationId = state.stationId
        publicState.stationName = state.stationName
        publicState.genre = state.genre
    end

    return publicState
end

local function StartStreamState(networkId, vehicle, streamData)
    local now = GetServerTime()
    local previousState = GetOrCreateState(networkId, now, vehicle)
    local state = {
        source = 'stream',
        videoId = false,
        stationId = streamData.id,
        stationName = streamData.name,
        genre = streamData.genre,
        streamUrl = streamData.url,
        volume = previousState.volume,
        playing = true,
        position = 0.0,
        startedAt = now,
        updatedAt = now,
        revision = NextRevision(),
        vehicleEntity = vehicle,
        queue = {}
    }

    VehicleRadios[networkId] = state
    if streamData.id and Config.Persistence and Config.Persistence.SaveConfiguredStation ~= false then
        SaveVehiclePreferences(vehicle, { stationId = streamData.id })
    end
    BroadcastState(networkId, state)
    return state
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
        vehicleEntity = vehicle,
        queue = previousState.queue or {},
        title = nil,
        author = nil,
        duration = nil
    }

    VehicleRadios[networkId] = state
    BroadcastState(networkId, state)
    DebugPrint(('play player=%s vehicle=%s video=%s'):format(playerSource, networkId, state.videoId))
end)

local function AdvanceQueue(networkId, state, vehicle, reason)
    if type(state.queue) ~= 'table' or #state.queue == 0 then
        return false
    end

    local nextItem = table.remove(state.queue, 1)
    if not nextItem or not IsValidVideoId(nextItem.videoId) then
        return false
    end

    local now = GetServerTime()
    state.source = 'youtube'
    state.videoId = nextItem.videoId
    state.stationId = nil
    state.stationName = nil
    state.genre = nil
    state.streamUrl = nil
    state.title = nextItem.title
    state.author = nextItem.author
    state.duration = nextItem.duration
    state.playing = true
    state.position = 0.0
    state.startedAt = now
    state.updatedAt = now
    state.revision = NextRevision()
    state.vehicleEntity = vehicle or state.vehicleEntity

    BroadcastState(networkId, state)
    DebugPrint(('queue advance vehicle=%s video=%s reason=%s remaining=%s'):format(
        networkId, state.videoId, reason or 'unspecified', #state.queue
    ))
    return true
end

RegisterNetEvent('acg_radio:server:addToQueue', function(request)
    local playerSource = source
    if IsRateLimited(playerSource, 'addToQueue') then
        RejectRateLimited(playerSource, 'addToQueue')
        return
    end

    if not Config.Queue or Config.Queue.Enabled ~= true then
        Reject(playerSource, 'The radio queue is disabled.')
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

    local state = GetOrCreateState(networkId, GetServerTime(), vehicle)
    state.queue = state.queue or {}
    local maxItems = math.max(math.floor(tonumber(Config.Queue.MaxItems) or 20), 1)
    if #state.queue >= maxItems then
        Reject(playerSource, ('Queue is full (%s tracks).'):format(maxItems))
        return
    end

    state.queue[#state.queue + 1] = {
        videoId = request.videoId,
        title = SanitizeText(request.title, 120),
        author = SanitizeText(request.author, 80),
        duration = (IsValidNumber(tonumber(request.duration)) and tonumber(request.duration) > 0 and tonumber(request.duration) <= 86400) and math.floor(tonumber(request.duration) * 10 + 0.5) / 10 or nil
    }
    state.updatedAt = GetServerTime()
    state.revision = NextRevision()

    -- If nothing is playing, queued music starts immediately.
    if not IsActiveRadioState(state) then
        AdvanceQueue(networkId, state, vehicle, 'idle-add')
    else
        BroadcastState(networkId, state)
    end
end)

RegisterNetEvent('acg_radio:server:removeQueueItem', function(request)
    local playerSource = source
    if IsRateLimited(playerSource, 'removeQueueItem') then
        RejectRateLimited(playerSource, 'removeQueueItem')
        return
    end

    if type(request) ~= 'table' or not IsValidNumber(request.index) then
        Reject(playerSource, 'Invalid queue item.')
        return
    end

    local networkId, vehicle, errorMessage = ValidateOccupiedVehicle(playerSource, request.vehicleNetworkId, true)
    if not networkId then
        Reject(playerSource, errorMessage)
        return
    end

    local state = GetOrCreateState(networkId, GetServerTime(), vehicle)
    local index = math.floor(request.index)
    if type(state.queue) ~= 'table' or index < 1 or index > #state.queue then
        Reject(playerSource, 'That queue item no longer exists.')
        return
    end

    table.remove(state.queue, index)
    state.updatedAt = GetServerTime()
    state.revision = NextRevision()
    BroadcastState(networkId, state)
end)

RegisterNetEvent('acg_radio:server:skip', function(request)
    local playerSource = source
    if IsRateLimited(playerSource, 'skip') then
        RejectRateLimited(playerSource, 'skip')
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
    if state.source ~= 'youtube' then
        Reject(playerSource, 'There is no YouTube track to skip.')
        return
    end

    if not AdvanceQueue(networkId, state, vehicle, 'manual-skip') then
        StopVehicleRadioInternal(networkId, ('skip-empty player=%s'):format(playerSource))
    end
end)

RegisterNetEvent('acg_radio:server:trackEnded', function(request)
    local playerSource = source
    if type(request) ~= 'table' or not IsValidVideoId(request.expectedVideoId) then
        return
    end

    local networkId, vehicle = ValidateOccupiedVehicle(playerSource, request.vehicleNetworkId, false)
    if not networkId then
        return
    end

    local state = VehicleRadios[networkId]
    if not state or state.source ~= 'youtube' or state.videoId ~= request.expectedVideoId then
        return
    end

    if not AdvanceQueue(networkId, state, vehicle, 'track-ended') then
        StopVehicleRadioInternal(networkId, ('track-ended player=%s'):format(playerSource), request.expectedVideoId)
    end
end)

RegisterNetEvent('acg_radio:server:updateMetadata', function(request)
    local playerSource = source
    if type(request) ~= 'table' or not IsValidVideoId(request.videoId) then
        return
    end

    local networkId, vehicle = ValidateOccupiedVehicle(playerSource, request.vehicleNetworkId, false)
    if not networkId then
        return
    end

    local state = VehicleRadios[networkId]
    if not state or state.source ~= 'youtube' or state.videoId ~= request.videoId then
        return
    end

    local changed = false
    local title = SanitizeText(request.title, 120)
    local author = SanitizeText(request.author, 80)
    local duration = tonumber(request.duration)
    if title and title ~= state.title then state.title = title; changed = true end
    if author and author ~= state.author then state.author = author; changed = true end
    if duration and IsValidNumber(duration) and duration > 0 and duration <= 86400 then
        duration = math.floor(duration * 10 + 0.5) / 10
        if duration ~= state.duration then state.duration = duration; changed = true end
    end

    if changed then
        state.updatedAt = GetServerTime()
        state.revision = NextRevision()
        BroadcastState(networkId, state)
    end
end)

RegisterNetEvent('acg_radio:server:playStation', function(request)
    local playerSource = source
    if IsRateLimited(playerSource, 'playStation') then
        RejectRateLimited(playerSource, 'playStation')
        return
    end

    if type(request) ~= 'table' then
        Reject(playerSource, 'Invalid radio station request.')
        return
    end

    local station = GetRadioStationById(request.stationId)
    if not station then
        Reject(playerSource, 'That configured radio station is unavailable.')
        return
    end

    local networkId, vehicle, errorMessage = ValidateOccupiedVehicle(playerSource, request.vehicleNetworkId, true)
    if not networkId then
        Reject(playerSource, errorMessage)
        return
    end

    StartStreamState(networkId, vehicle, station)
    DebugPrint(('stream player=%s vehicle=%s station=%s'):format(playerSource, networkId, station.id))
end)

RegisterNetEvent('acg_radio:server:playCustomStream', function(request)
    local playerSource = source
    if IsRateLimited(playerSource, 'playCustomStream') then
        RejectRateLimited(playerSource, 'playCustomStream')
        return
    end

    if not Config.Streams or Config.Streams.AllowCustomUrls ~= true then
        Reject(playerSource, 'Custom stream URLs are disabled.')
        return
    end

    if type(request) ~= 'table' then
        Reject(playerSource, 'Invalid custom stream request.')
        return
    end

    local maximumLength = math.max(tonumber(Config.Streams.MaxUrlLength) or 2048, 1)
    if type(request.streamUrl) ~= 'string' or #request.streamUrl > maximumLength then
        Reject(playerSource, 'Enter a valid HTTP or HTTPS direct stream URL.')
        return
    end

    local streamUrl = request.streamUrl:match('^%s*(.-)%s*$')
    if not IsValidStreamUrl(streamUrl) then
        Reject(playerSource, 'Enter a valid HTTP or HTTPS direct stream URL.')
        return
    end

    local networkId, vehicle, errorMessage = ValidateOccupiedVehicle(playerSource, request.vehicleNetworkId, true)
    if not networkId then
        Reject(playerSource, errorMessage)
        return
    end

    local stationName = SanitizeText(request.stationName, 64) or 'Custom Stream'
    StartStreamState(networkId, vehicle, {
        name = stationName,
        genre = 'Custom',
        url = streamUrl
    })
    DebugPrint(('stream player=%s vehicle=%s station=custom'):format(playerSource, networkId))
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
    if not IsActiveRadioState(state) or not state.playing then
        Reject(playerSource, 'There is no playing radio source to pause.')
        return
    end

    local now = GetServerTime()
    if state.source == 'youtube' then
        state.position = GetCurrentPosition(state, now)
    else
        state.position = 0.0
    end
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
    if not IsActiveRadioState(state) or state.playing then
        Reject(playerSource, 'There is no paused radio source to resume.')
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

    local state = GetOrCreateState(networkId, GetServerTime(), vehicle)

    if request.expectedVideoId ~= nil then
        if not IsValidVideoId(request.expectedVideoId) then
            Reject(playerSource, 'Invalid expected YouTube video ID.')
            return
        end

        if not IsActiveRadioState(state) or state.videoId ~= request.expectedVideoId then
            DebugPrint(('ignored stale stop player=%s vehicle=%s expected=%s'):format(
                playerSource,
                networkId,
                request.expectedVideoId
            ))
            return
        end
    end

    StopVehicleRadioInternal(networkId, ('player=%s'):format(playerSource), request.expectedVideoId)
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
    if Config.Persistence and Config.Persistence.SaveVolume ~= false then
        SaveVehiclePreferences(vehicle, { volume = state.volume })
    end
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
        if IsActiveRadioState(state) then
            snapshots[#snapshots + 1] = BuildSnapshot(networkId, state)
        end
    end

    TriggerClientEvent('acg_radio:client:activeRadios', playerSource, snapshots)
end)

exports('GetActiveRadios', function()
    local radios = {}

    for networkId, state in pairs(VehicleRadios) do
        local publicState = BuildPublicRadioState(networkId, state)
        if publicState then
            radios[#radios + 1] = publicState
        end
    end

    table.sort(radios, function(left, right)
        return left.netId < right.netId
    end)

    return radios
end)

exports('GetVehicleRadio', function(networkId)
    networkId = NormalizeNetworkId(networkId)
    if not networkId then
        return nil
    end

    return BuildPublicRadioState(networkId, VehicleRadios[networkId])
end)

exports('IsVehicleRadioActive', function(networkId)
    networkId = NormalizeNetworkId(networkId)
    return networkId ~= nil and IsActiveRadioState(VehicleRadios[networkId]) or false
end)

exports('GetActiveRadioCount', function()
    local count = 0
    for _, state in pairs(VehicleRadios) do
        if IsActiveRadioState(state) then
            count = count + 1
        end
    end

    return count
end)

exports('StopVehicleRadio', function(networkId)
    local invokingResource = GetInvokingResource() or 'unknown-server-resource'
    local stopped = StopVehicleRadioInternal(
        networkId,
        ('external-resource=%s'):format(invokingResource)
    )

    if stopped then
        DebugPrint(('External server resource stopped radio vehicle=%s resource=%s'):format(
            networkId,
            invokingResource
        ))
    end

    return stopped
end)

exports('StopAllRadios', function()
    local invokingResource = GetInvokingResource() or 'unknown-server-resource'
    local activeNetworkIds = {}

    for networkId, state in pairs(VehicleRadios) do
        if IsActiveRadioState(state) then
            activeNetworkIds[#activeNetworkIds + 1] = networkId
        end
    end

    local stoppedCount = 0
    for _, networkId in ipairs(activeNetworkIds) do
        if StopVehicleRadioInternal(
            networkId,
            ('external-stop-all resource=%s'):format(invokingResource)
        ) then
            stoppedCount = stoppedCount + 1
        end
    end

    DebugPrint(('External server resource stopped %s active radios resource=%s'):format(
        stoppedCount,
        invokingResource
    ))
    return stoppedCount
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

AddEventHandler('onResourceStart', function(resourceName)
    local adminResourceName = GetAdminMenuResourceName()
    if resourceName == GetCurrentResourceName() or resourceName == adminResourceName then
        RefreshAdminMenuAvailability(false)
    end
end)

AddEventHandler('onResourceStop', function(resourceName)
    local adminResourceName = GetAdminMenuResourceName()
    if adminResourceName and resourceName == adminResourceName then
        RefreshAdminMenuAvailability(true)
    end
end)
