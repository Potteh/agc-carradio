# ACG Radio Server Integration

`fivem_admin` is optional.

`acg_radio` has no dependency on `fivem_admin` and continues to work when the admin resource is missing, stopped, restarted, renamed, or removed.

## Configuration

```lua
Config.Integrations = {
    AdminMenu = {
        Enabled = true,
        ResourceName = 'fivem_admin'
    }
}
```

`Enabled = true` permits optional availability detection. It does not start, require, or call the configured resource. Change `ResourceName` in this one location if the admin resource is renamed.

## Trust Model

All exports documented below are server-side exports intended for trusted server resources. A resource such as `fivem_admin` must validate administrator permissions before calling an action export.

Do not expose these action exports through an unprotected client event. `acg_radio` does not accept a client claim that the player is an administrator. Normal player controls continue to validate the player's actual occupied vehicle on the `acg_radio` server.

Query exports return newly constructed, sanitized tables. They never return the internal `VehicleRadios` table or its mutable state objects.

## Sanitized Radio State

Query results use this structure:

```lua
{
    netId = 123,
    plate = 'ABC123', -- nil when unavailable
    source = 'youtube',
    videoId = 'abcdefghijk',
    volume = 80,
    playing = true,
    position = 123.5
}
```

Live stream states use the same base structure with stream-specific fields:

```lua
{
    netId = 123,
    plate = 'ABC123',
    source = 'stream',
    stationId = 'station1', -- nil for a custom URL
    stationName = 'Example FM',
    genre = 'Rock',
    volume = 80,
    playing = true
}
```

`position` is present for YouTube sources and is calculated when the export is called. While playing, it is the stored position plus elapsed authoritative server time. Live streams do not expose a playback position. Custom stream URLs are not returned by the administrative query API. Internal entity handles, timer anchors, revisions, direct stream URLs, and implementation-only fields are not exposed.

Additional optional fields, such as metadata or queue summaries, may be added in future versions without changing the existing fields.

## GetActiveRadios

Arguments: none.

Returns: an array of sanitized active radio states, sorted by network ID. Returns `{}` when none are active.

```lua
local radios = exports['acg_radio']:GetActiveRadios()

for _, radio in ipairs(radios) do
    print(
        ('Vehicle %s playing %s'):format(
            radio.netId,
            radio.videoId or radio.stationName or 'unknown'
        )
    )
end
```

## GetVehicleRadio

Arguments: `netId` as a positive integer.

Returns: a sanitized active radio state, or `nil` for invalid input or an inactive radio.

```lua
local radio = exports['acg_radio']:GetVehicleRadio(netId)

if radio then
    print('Radio exists')
end
```

## IsVehicleRadioActive

Arguments: `netId` as a positive integer.

Returns: strictly `true` or `false`. Invalid input returns `false`.

```lua
local active = exports['acg_radio']:IsVehicleRadioActive(netId)

if active then
    print('Vehicle radio is active')
end
```

## GetActiveRadioCount

Arguments: none.

Returns: the number of active vehicle radios. Returns `0` when none are active.

```lua
local count = exports['acg_radio']:GetActiveRadioCount()

print(('Active vehicle radios: %s'):format(count))
```

## StopVehicleRadio

Arguments: `netId` as a positive integer.

Returns: `true` when an active radio was stopped. Returns `false` for invalid input or when no active radio exists.

This is a trusted server-resource action. It uses the same authoritative stop and client broadcast path as normal occupant controls.

```lua
local success = exports['acg_radio']:StopVehicleRadio(netId)

if success then
    print('Radio stopped')
else
    print('No active radio found')
end
```

## StopAllRadios

Arguments: none.

Returns: the number of active radios stopped. Returns `0` when none are active.

```lua
local stopped = exports['acg_radio']:StopAllRadios()

print(('Stopped %s radios'):format(stopped))
```

## Operation Without fivem_admin

`acg_radio` remains a QBCore resource and requires its declared `qb-core` dependency. It has no dependency on `fivem_admin`, and there is no required start order between those two resources. Assuming QBCore is already running, all of these are supported:

```text
ensure acg_radio
```

```text
ensure acg_radio
ensure fivem_admin
```

```text
ensure fivem_admin
ensure acg_radio
```

Stopping or restarting `fivem_admin` does not modify radio state, restart YouTube playback, or interrupt synchronization. `acg_radio` only observes the configured resource state for optional debug logging and never calls an export on it.
