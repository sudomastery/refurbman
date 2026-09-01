<#
.SYNOPSIS
    RefurbMan: check what is really inside a Windows PC, and how worn its parts are.

.DESCRIPTION
    A single self-contained script for checking a second-hand machine. It reads
    hardware from sources a seller cannot casually edit and labels every reading
    with where it came from.

    It deliberately avoids the Windows registry. That matters more than it
    sounds: the processor name shown by Task Manager, by most "system info"
    tools, and by Win32_Processor comes from
    HKLM\HARDWARE\DESCRIPTION\System\CentralProcessor\0\ProcessorNameString,
    which is a string anyone with administrator rights can rewrite. Renaming an
    i3 to an i7 there takes about ten seconds and fools nearly every tool people
    reach for. This script parses the raw SMBIOS firmware table instead.

.PARAMETER Json
    Emit the findings as JSON instead of the formatted report, for scripting.

.PARAMETER NoColor
    Disable colour, for redirected or logged output.

.EXAMPLE
    .\RefurbMan.ps1

.EXAMPLE
    irm https://raw.githubusercontent.com/sudomastery/refurbman/main/scripts/RefurbMan.ps1 | iex

.NOTES
    Run in an elevated PowerShell. Without administrator rights the machine is
    still identified in full, but drive health cannot be read, because asking a
    drive about its own condition requires direct device access.

    Part of RefurbMan: https://github.com/sudomastery/refurbman
    Licensed GPL-3.0-or-later.
#>

[CmdletBinding()]
param(
    [switch]$Json,
    [switch]$NoColor,
    # Define the functions and stop, so the test suite can dot-source this file
    # and exercise the parsing and judgement logic without a Windows machine.
    [switch]$LoadOnly
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

# These checks run before anything else because this script is commonly pasted
# into whatever terminal happens to be open. Failing with a sentence beats
# failing with a stack trace.
if ($PSVersionTable.PSVersion.Major -lt 5) {
    Write-Host 'RefurbMan needs PowerShell 5.1 or newer.' -ForegroundColor Red
    Write-Host "This is PowerShell $($PSVersionTable.PSVersion)." -ForegroundColor DarkGray
    return
}


# ---------------------------------------------------------------------------
# Provenance
#
# Same five-rung ladder the desktop application uses. The rank is printed
# beside every reading so it is obvious which numbers carry weight.
# ---------------------------------------------------------------------------

$script:Trust = @{
    Device   = @{ Rank = 4; Label = 'DEVICE  '; Color = 'Green'    }
    Kernel   = @{ Rank = 3; Label = 'KERNEL  '; Color = 'Cyan'     }
    Firmware = @{ Rank = 2; Label = 'FIRMWARE'; Color = 'Blue'     }
    Derived  = @{ Rank = 1; Label = 'CALC    '; Color = 'DarkGray' }
    Software = @{ Rank = 0; Label = 'SOFTWARE'; Color = 'DarkYellow' }
}

$script:Findings = New-Object System.Collections.ArrayList
$script:Report   = [ordered]@{}
$script:UseColor = -not $NoColor -and -not $Json

function Write-C {
    param([string]$Text, [string]$Color = 'Gray', [switch]$NoNewline)
    if ($script:UseColor) {
        Write-Host $Text -ForegroundColor $Color -NoNewline:$NoNewline
    } else {
        Write-Host $Text -NoNewline:$NoNewline
    }
}

function Add-Finding {
    param(
        [ValidateSet('Info', 'Warn', 'Critical')][string]$Severity,
        [string]$Title,
        [string]$Detail,
        [string]$Evidence = ''
    )
    [void]$script:Findings.Add([pscustomobject]@{
        Severity = $Severity; Title = $Title; Detail = $Detail; Evidence = $Evidence
    })
}

function Test-Admin {
    try {
        $id = [Security.Principal.WindowsIdentity]::GetCurrent()
        return (New-Object Security.Principal.WindowsPrincipal $id).IsInRole(
            [Security.Principal.WindowsBuiltInRole]::Administrator)
    } catch {
        return $false
    }
}

# ---------------------------------------------------------------------------
# Raw SMBIOS
#
# MSSmBios_RawSMBiosTables hands back the firmware's own table, byte for byte,
# exactly as GetSystemFirmwareTable('RSMB') would. Changing what it says means
# reflashing the BIOS, which is a different league of effort from editing a
# registry value.
# ---------------------------------------------------------------------------

function Get-SmbiosStructures {
    try {
        $raw = (Get-CimInstance -Namespace root/WMI -ClassName MSSmBios_RawSMBiosTables -ErrorAction Stop).SMBiosData
    } catch {
        Add-Finding -Severity Warn -Title 'Firmware tables could not be read' `
            -Detail ('The raw SMBIOS table was unavailable, so the motherboard, memory slot ' +
                     'and processor details below are missing. This is unusual and is worth ' +
                     'noting in itself.') -Evidence $_.Exception.Message
        return @()
    }

    $structures = New-Object System.Collections.ArrayList
    $i = 0
    while ($i -lt $raw.Length - 4) {
        $type   = $raw[$i]
        $length = $raw[$i + 1]
        if ($length -lt 4) { break }

        # Type 127 marks the end of the table.
        if ($type -eq 127) { break }

        $formatted = $raw[$i..($i + $length - 1)]

        # The string table follows the formatted area and ends with two nulls.
        $s = $i + $length
        $strings = New-Object System.Collections.ArrayList
        $cur = New-Object System.Text.StringBuilder
        while ($s -lt $raw.Length) {
            if ($raw[$s] -eq 0) {
                if ($cur.Length -eq 0) { $s++; break }
                [void]$strings.Add($cur.ToString())
                [void]$cur.Clear()
            } else {
                [void]$cur.Append([char]$raw[$s])
            }
            $s++
        }

        [void]$structures.Add([pscustomobject]@{
            Type = $type; Data = $formatted; Strings = $strings
        })
        $i = $s
    }
    return $structures
}

# OEMs leave placeholder junk in these fields. Showing "To Be Filled By O.E.M."
# to someone deciding whether to buy a laptop is worse than showing nothing,
# because it looks like a reading.
$script:Placeholders = @(
    'to be filled by o.e.m.', 'to be filled by oem', 'default string',
    'not specified', 'not applicable', 'none', 'unknown', 'oem', 'o.e.m.',
    'system manufacturer', 'system product name', 'system version',
    'system serial number', 'chassis manufacture', 'chassis serial number',
    'x.x.', '0123456789'
)

function Get-SmbiosString {
    param($Struct, [int]$Offset)
    if ($Offset -ge $Struct.Data.Length) { return $null }
    $index = $Struct.Data[$Offset]
    if ($index -eq 0 -or $index -gt $Struct.Strings.Count) { return $null }
    $v = $Struct.Strings[$index - 1]
    if ($null -eq $v) { return $null }
    $v = $v.Trim()
    if ([string]::IsNullOrWhiteSpace($v)) { return $null }
    if ($script:Placeholders -contains $v.ToLowerInvariant()) { return $null }
    return $v
}

function Get-U16 { param($Struct, [int]$Offset)
    if ($Offset + 1 -ge $Struct.Data.Length) { return $null }
    [int]$Struct.Data[$Offset] -bor ([int]$Struct.Data[$Offset + 1] -shl 8)
}
function Get-U32 { param($Struct, [int]$Offset)
    if ($Offset + 3 -ge $Struct.Data.Length) { return $null }
    [int64]$Struct.Data[$Offset] -bor ([int64]$Struct.Data[$Offset+1] -shl 8) -bor `
    ([int64]$Struct.Data[$Offset+2] -shl 16) -bor ([int64]$Struct.Data[$Offset+3] -shl 24)
}

function Format-Bytes {
    param([double]$Bytes)
    $units = @('B','KB','MB','GB','TB')
    $i = 0
    while ($Bytes -ge 1000 -and $i -lt $units.Count - 1) { $Bytes /= 1000; $i++ }
    if ($i -eq 0) { return "$([int]$Bytes) B" }
    if ($Bytes -ge 100) { return ('{0:N0} {1}' -f $Bytes, $units[$i]) }
    return ('{0:N1} {1}' -f $Bytes, $units[$i])
}

$script:MemoryTypes = @{
    0x01='Other'; 0x02='Unknown'; 0x03='DRAM'; 0x0F='SDRAM'; 0x12='DDR';
    0x13='DDR2'; 0x18='DDR3'; 0x1A='DDR4'; 0x22='DDR5'; 0x1B='LPDDR';
    0x1C='LPDDR2'; 0x1D='LPDDR3'; 0x1E='LPDDR4'; 0x23='LPDDR5'
}
$script:ChassisTypes = @{
    3='Desktop'; 4='Low profile desktop'; 6='Mini tower'; 7='Tower'; 8='Portable';
    9='Laptop'; 10='Notebook'; 11='Hand held'; 13='All in one'; 14='Sub notebook';
    15='Space saving'; 17='Main server chassis'; 23='Rack mount'; 30='Tablet';
    31='Convertible'; 32='Detachable'
}

# ---------------------------------------------------------------------------
# Machine identity, processor, memory: all from the firmware table
# ---------------------------------------------------------------------------

function Get-Machine {
    param($Structures)

    $out = [ordered]@{
        Manufacturer = $null; Model = $null; Version = $null; SerialNumber = $null
        Family = $null; BoardVendor = $null; BoardModel = $null; BoardSerial = $null
        BiosVendor = $null; BiosVersion = $null; BiosDate = $null; Chassis = $null
    }
    $sys   = $Structures | Where-Object Type -eq 1 | Select-Object -First 1
    $board = $Structures | Where-Object Type -eq 2 | Select-Object -First 1
    $bios  = $Structures | Where-Object Type -eq 0 | Select-Object -First 1
    $chas  = $Structures | Where-Object Type -eq 3 | Select-Object -First 1

    if ($sys) {
        $out.Manufacturer = Get-SmbiosString $sys 0x04
        $out.Model        = Get-SmbiosString $sys 0x05
        $out.Version      = Get-SmbiosString $sys 0x06
        $out.SerialNumber = Get-SmbiosString $sys 0x07
        $out.Family       = Get-SmbiosString $sys 0x1A
    }
    if ($board) {
        $out.BoardVendor = Get-SmbiosString $board 0x04
        $out.BoardModel  = Get-SmbiosString $board 0x05
        $out.BoardSerial = Get-SmbiosString $board 0x07
    }
    if ($bios) {
        $out.BiosVendor  = Get-SmbiosString $bios 0x04
        $out.BiosVersion = Get-SmbiosString $bios 0x05
        $out.BiosDate    = Get-SmbiosString $bios 0x08
    }
    if ($chas -and $chas.Data.Length -gt 0x05) {
        # The top bit of the chassis type byte is a lock flag, not part of the value.
        $code = $chas.Data[0x05] -band 0x7F
        if ($script:ChassisTypes.ContainsKey([int]$code)) {
            $out.Chassis = $script:ChassisTypes[[int]$code]
        }
    }
    return $out
}

function Get-Processor {
    param($Structures)

    $cpus = @($Structures | Where-Object Type -eq 4)
    $result = New-Object System.Collections.ArrayList

    foreach ($c in $cpus) {
        # Status bit 6 indicates a populated socket. An empty socket is worth
        # knowing about but is not a processor.
        if ($c.Data.Length -gt 0x18) {
            $populated = ($c.Data[0x18] -band 0x40) -ne 0
            if (-not $populated) { continue }
        }

        $entry = [ordered]@{
            # The firmware's own name for the part. Unlike Win32_Processor.Name
            # this does not come from a registry string.
            Model    = Get-SmbiosString $c 0x10
            Socket   = Get-SmbiosString $c 0x04
            Vendor   = Get-SmbiosString $c 0x07
            MaxSpeedMhz = Get-U16 $c 0x14
        }
        if ($c.Data.Length -gt 0x25) {
            $cores   = [int]$c.Data[0x23]
            $threads = [int]$c.Data[0x25]
            if ($cores   -gt 0 -and $cores   -ne 0xFF) { $entry.Cores   = $cores }
            if ($threads -gt 0 -and $threads -ne 0xFF) { $entry.Threads = $threads }
        }
        [void]$result.Add($entry)
    }
    return $result
}

function Get-MemorySlots {
    param($Structures)

    $slots = New-Object System.Collections.ArrayList
    foreach ($m in ($Structures | Where-Object Type -eq 17)) {
        $sizeField = Get-U16 $m 0x0C
        if ($null -eq $sizeField) { continue }

        $bytes = 0
        if ($sizeField -eq 0) {
            $bytes = 0                      # empty slot
        } elseif ($sizeField -eq 0x7FFF) {
            $ext = Get-U32 $m 0x1C          # 32GB and above escape to the extended field
            if ($ext) { $bytes = [int64]$ext * 1MB }
        } elseif ($sizeField -eq 0xFFFF) {
            $bytes = 0                      # unknown
        } else {
            # Bit 15 clear means megabytes, set means kilobytes.
            if ($sizeField -band 0x8000) { $bytes = [int64]($sizeField -band 0x7FFF) * 1KB }
            else                         { $bytes = [int64]$sizeField * 1MB }
        }

        $locator = Get-SmbiosString $m 0x10
        if (-not $locator) { $locator = "Slot $($slots.Count + 1)" }

        $typeCode = if ($m.Data.Length -gt 0x12) { [int]$m.Data[0x12] } else { 0 }
        $typeName = if ($script:MemoryTypes.ContainsKey($typeCode)) { $script:MemoryTypes[$typeCode] } else { $null }

        [void]$slots.Add([ordered]@{
            Slot         = $locator
            Bytes        = $bytes
            Populated    = ($bytes -gt 0)
            Type         = $typeName
            SpeedMts     = Get-U16 $m 0x15
            ConfiguredMts= Get-U16 $m 0x20
            Manufacturer = Get-SmbiosString $m 0x17
            PartNumber   = Get-SmbiosString $m 0x1A
        })
    }
    return $slots
}

# ---------------------------------------------------------------------------
# Battery
#
# These WMI classes are served by the ACPI battery driver, which relays what
# the pack's own controller reports. Nothing here touches the registry.
# ---------------------------------------------------------------------------

function Get-Batteries {
    $out = New-Object System.Collections.ArrayList

    try   { $static = @(Get-CimInstance -Namespace root/WMI -ClassName BatteryStaticData -ErrorAction Stop) }
    catch { return $out }
    if (-not $static) { return $out }

    $full   = @()
    $cycles = @()
    try { $full   = @(Get-CimInstance -Namespace root/WMI -ClassName BatteryFullChargedCapacity -ErrorAction Stop) } catch { }
    try { $cycles = @(Get-CimInstance -Namespace root/WMI -ClassName BatteryCycleCount -ErrorAction Stop) } catch { }

    foreach ($b in $static) {
        $tag = $b.Tag
        $f = $full   | Where-Object { $_.Tag -eq $tag } | Select-Object -First 1
        $c = $cycles | Where-Object { $_.Tag -eq $tag } | Select-Object -First 1

        $design     = [double]$b.DesignedCapacity
        $charged    = if ($f) { [double]$f.FullChargedCapacity } else { 0 }
        $cycleCount = if ($c -and $c.CycleCount -gt 0) { [int]$c.CycleCount } else { $null }

        $health = $null
        if ($design -gt 0 -and $charged -gt 0) {
            $health = [math]::Round(($charged / $design) * 100, 1)
        }

        [void]$out.Add([ordered]@{
            Name        = if ($b.DeviceName) { $b.DeviceName } else { "Battery $tag" }
            Manufacturer= $b.ManufactureName
            Chemistry   = $b.Chemistry
            DesignedmWh = [int]$design
            CurrentmWh  = [int]$charged
            HealthPercent = $health
            CycleCount  = $cycleCount
        })
    }
    return $out
}

# ---------------------------------------------------------------------------
# Storage
#
# Get-StorageReliabilityCounter asks the drive itself, through the storage
# driver, and needs administrator rights. Get-PhysicalDisk supplies identity
# from the same stack.
# ---------------------------------------------------------------------------

function Get-Drives {
    param([bool]$IsAdmin)

    $out = New-Object System.Collections.ArrayList
    try   { $disks = @(Get-PhysicalDisk -ErrorAction Stop) }
    catch {
        Add-Finding -Severity Warn -Title 'Drives could not be listed' `
            -Detail 'The storage subsystem did not respond, so no drive health is shown.' `
            -Evidence $_.Exception.Message
        return $out
    }

    foreach ($d in $disks) {
        $entry = [ordered]@{
            Model        = $d.FriendlyName
            SerialNumber = $d.SerialNumber
            Firmware     = $d.FirmwareVersion
            SizeBytes    = [int64]$d.Size
            MediaType    = [string]$d.MediaType
            BusType      = [string]$d.BusType
            SelfAssessment = [string]$d.HealthStatus
            Wear         = $null
            PowerOnHours = $null
            TemperatureC = $null
            ReadErrors   = $null
            WriteErrors  = $null
            Locked       = $false
        }

        if ($IsAdmin) {
            try {
                $r = $d | Get-StorageReliabilityCounter -ErrorAction Stop
                if ($null -ne $r) {
                    if ($null -ne $r.Wear)         { $entry.Wear         = [int]$r.Wear }
                    if ($null -ne $r.PowerOnHours) { $entry.PowerOnHours = [int]$r.PowerOnHours }
                    if ($null -ne $r.Temperature)  { $entry.TemperatureC = [int]$r.Temperature }
                    if ($null -ne $r.ReadErrorsUncorrected)  { $entry.ReadErrors  = [int]$r.ReadErrorsUncorrected }
                    if ($null -ne $r.WriteErrorsUncorrected) { $entry.WriteErrors = [int]$r.WriteErrorsUncorrected }
                }
            } catch {
                # Plenty of drives, especially behind USB bridges, simply do not
                # implement these counters. That is not a fault.
                $entry.Locked = $true
            }
        } else {
            $entry.Locked = $true
        }

        [void]$out.Add($entry)
    }
    return $out
}

# ---------------------------------------------------------------------------
# Judgement
#
# Same thresholds and the same plain wording as the desktop application, so the
# two never disagree about the same machine.
# ---------------------------------------------------------------------------

function Get-DriveVerdict {
    param($Drive)

    $verdict  = 'Good'
    $percent  = $null
    $headline = ''
    $rank = @{ Good = 0; Fair = 1; Unknown = 2; Poor = 3 }
    function Worse { param($a, $b) if ($rank[$b] -gt $rank[$a]) { $b } else { $a } }

    if ($Drive.Locked) {
        return @{ Verdict = 'Unknown'; Percent = $null
                  Headline = 'Health could not be read without administrator rights.' }
    }

    if ($Drive.SelfAssessment -and $Drive.SelfAssessment -ne 'Healthy') {
        $verdict = Worse $verdict 'Poor'
        Add-Finding -Severity Critical -Title "The drive reports that it is failing" `
            -Detail ("$($Drive.Model) has raised its own failure warning. That is the strongest " +
                     'signal a drive can give, and it means data loss is likely. Do not rely on it.') `
            -Evidence "HealthStatus = $($Drive.SelfAssessment)"
    }

    if ($null -ne $Drive.Wear) {
        $percent = [math]::Max(0, 100 - $Drive.Wear)
        if     ($Drive.Wear -ge 90) {
            $verdict = Worse $verdict 'Poor'
            Add-Finding -Severity Critical -Title 'The drive is nearly worn out' `
                -Detail ("$($Drive.Model) reports that it has used $($Drive.Wear)% of the write " +
                         'life it was designed for. It is close to the end of its service life.')
        }
        elseif ($Drive.Wear -ge 70) {
            $verdict = Worse $verdict 'Fair'
            Add-Finding -Severity Warn -Title 'The drive is significantly worn' `
                -Detail ("$($Drive.Model) reports that it has used $($Drive.Wear)% of its designed " +
                         'write life. It works now, but it has more life behind it than ahead of it.')
        }
        elseif ($Drive.Wear -ge 30) { $verdict = Worse $verdict 'Fair' }
    }

    $errs = 0
    if ($null -ne $Drive.ReadErrors)  { $errs += $Drive.ReadErrors }
    if ($null -ne $Drive.WriteErrors) { $errs += $Drive.WriteErrors }
    if ($errs -gt 0) {
        $verdict = Worse $verdict 'Fair'
        Add-Finding -Severity Warn -Title 'The drive has reported unrecoverable errors' `
            -Detail ("$($Drive.Model) logged $errs error(s) it could not correct. On a solid state " +
                     'drive this usually points to failing memory cells.') `
            -Evidence "Read $($Drive.ReadErrors), write $($Drive.WriteErrors) uncorrected"
    }

    # The counter reset check: heavy wear alongside almost no recorded running
    # time cannot be true of both, and is what a reset used drive looks like.
    if ($null -ne $Drive.PowerOnHours -and $null -ne $Drive.Wear) {
        if ($Drive.PowerOnHours -lt 100 -and $Drive.Wear -gt 5) {
            $verdict = Worse $verdict 'Unknown'
            Add-Finding -Severity Critical -Title "This drive's usage history does not add up" `
                -Detail ("$($Drive.Model) reports only $($Drive.PowerOnHours) hours of use, yet also " +
                         "reports $($Drive.Wear)% of its write life consumed. Those two figures cannot " +
                         'both be true: wearing a drive that far takes far longer than that. The most ' +
                         'likely explanation is that the usage counters have been reset to make the ' +
                         'drive look newer than it is. Treat this drive, and this seller, with caution.') `
                -Evidence "PowerOnHours $($Drive.PowerOnHours) against wear $($Drive.Wear)%"
        }
    }

    if ($null -ne $percent) {
        $age = if ($Drive.PowerOnHours) { Format-Hours $Drive.PowerOnHours } else { $null }
        $headline = switch ($verdict) {
            'Good'    { if ($age) { "Healthy, with $percent% of its life left after $age of use." }
                        else      { "Healthy, with $percent% of its life left." } }
            'Fair'    { "Worn but working, with $percent% of its life left." }
            'Poor'    { "Near the end of its life, with $percent% left." }
            'Unknown' { "This drive's reported history is inconsistent." }
        }
    } else {
        $headline = if ($Drive.PowerOnHours) {
            "No faults reported after $(Format-Hours $Drive.PowerOnHours) of use."
        } elseif ($verdict -eq 'Good') { 'No faults reported.' }
        else { 'This drive is failing and should not be relied on.' }
    }

    return @{ Verdict = $verdict; Percent = $percent; Headline = $headline }
}

function Format-Hours {
    param([int]$Hours)
    $years = $Hours / 8760.0
    if ($years -ge 1) { return ('{0:N1} years' -f $years) }
    $days = $Hours / 24.0
    if ($days -ge 1) { return ('{0:N0} days' -f $days) }
    return "$Hours hours"
}

function Get-BatteryVerdict {
    param($Battery)

    if ($null -eq $Battery.HealthPercent) {
        Add-Finding -Severity Info -Title 'Battery health could not be read' `
            -Detail ('The battery did not report the figures needed to work out how much capacity ' +
                     'it has lost. This is common on desktops and on some older laptops, and is ' +
                     'not a sign of a fault.')
        return @{ Verdict = 'Unknown'; Percent = $null
                  Headline = 'This battery would not report its condition.' }
    }

    $h = $Battery.HealthPercent
    $cycles = $Battery.CycleCount

    # A pack charged hundreds of times has not kept every last percent. When it
    # claims otherwise, the laptop is repeating its factory rating rather than
    # measuring the pack, and the number should not be presented as a health
    # reading at all.
    if ($h -ge 99.5 -and $cycles -and $cycles -gt 200) {
        Add-Finding -Severity Warn -Title 'Battery health figure looks unreliable' `
            -Detail ("This battery claims $([math]::Round($h))% of its original capacity while also " +
                     "reporting $cycles charge cycles. A pack that has been charged that many times " +
                     'has almost always lost noticeable capacity, so this laptop is very likely ' +
                     'reporting its factory rating rather than measuring the pack. Judge this ' +
                     'battery by how long it actually lasts unplugged, not by this number.') `
            -Evidence "Health $h% from FullChargedCapacity / DesignedCapacity, CycleCount $cycles"
        return @{ Verdict = 'Unknown'; Percent = $h
                  Headline = "Reports perfect health after $cycles charge cycles, which is unlikely to be measured." }
    }

    $verdict = if ($h -ge 80) { 'Good' } elseif ($h -ge 60) { 'Fair' } else { 'Poor' }

    if ($verdict -eq 'Fair') {
        Add-Finding -Severity Warn -Title 'Battery has lost some capacity' `
            -Detail ("This battery holds about $([math]::Round($h))% of what it held when new, so it " +
                     'will last roughly that share of the original time between charges. A ' +
                     'replacement is worth pricing up when you negotiate.')
    } elseif ($verdict -eq 'Poor') {
        Add-Finding -Severity Critical -Title 'Battery is worn out' `
            -Detail ("This battery holds only about $([math]::Round($h))% of its original capacity. " +
                     'It will need replacing soon, and on many laptops that is not a cheap or ' +
                     'simple job. Factor the cost of a new pack into the price.')
    }

    if ($cycles -and $cycles -ge 1000) {
        Add-Finding -Severity Warn -Title 'Battery has been charged a great many times' `
            -Detail ("This pack has been through $cycles charge cycles. Most laptop batteries are " +
                     'designed for 300 to 500, so it is well past its intended service life even ' +
                     'if it still tests reasonably.') -Evidence "CycleCount $cycles"
    }

    $headline = switch ($verdict) {
        'Good' { "Holds $([math]::Round($h))% of its original charge. In good shape." }
        'Fair' { "Holds $([math]::Round($h))% of its original charge. Noticeably worn but usable." }
        'Poor' { "Holds only $([math]::Round($h))% of its original charge. Expect a short time unplugged." }
    }
    return @{ Verdict = $verdict; Percent = $h; Headline = $headline }
}
# ---------------------------------------------------------------------------
# Rendering
# ---------------------------------------------------------------------------

$script:VerdictColor = @{
    Good = 'Green'; Fair = 'Yellow'; Poor = 'Red'; Unknown = 'DarkGray'
}

function Get-Banner {
    # Kept as a here-string so the backslashes and backtick survive verbatim.
    @'
    ____       ____           __    __  ___
   / __ \___  / __/_  _______/ /_  /  |/  /___ _____
  / /_/ / _ \/ /_/ / / / ___/ __ \/ /|_/ / __ `/ __ \
 / _, _/  __/ __/ /_/ / /  / /_/ / /  / / /_/ / / / /
/_/ |_|\___/_/  \__,_/_/  /_.___/_/  /_/\__,_/_/ /_/
'@ -split "`n"
}

function Write-Banner {
    Write-Host ''
    foreach ($line in (Get-Banner)) { Write-C $line 'Cyan' }
    Write-C '  what is really in this machine, and how worn it is' 'DarkGray'
    Write-Host ''
}

# Wrap prose to a column so long explanations stay readable in a console.
function Split-Wrapped {
    param([string]$Text, [int]$Width = 72)
    $out = New-Object System.Collections.ArrayList
    if ([string]::IsNullOrWhiteSpace($Text)) { return $out }
    $line = ''
    foreach ($word in ($Text -split '\s+')) {
        if ($line.Length -eq 0) { $line = $word }
        elseif (($line.Length + 1 + $word.Length) -le $Width) { $line = "$line $word" }
        else { [void]$out.Add($line); $line = $word }
    }
    if ($line) { [void]$out.Add($line) }
    return $out
}

function Join-Parts {
    param([object[]]$Parts, [string]$Separator = ' ')
    ($Parts | Where-Object { $_ -ne $null -and "$_" -ne '' }) -join $Separator
}

function Write-Rule {
    param([string]$Title = '')
    $width = 78
    if ($Title) {
        Write-C ("-- $Title " + ('-' * [math]::Max(0, $width - $Title.Length - 4))) 'DarkCyan'
    } else {
        Write-C ('-' * $width) 'DarkGray'
    }
}

function Write-Row {
    param([string]$Label, $Value, [string]$Trust = 'Firmware', [string]$Unit = '')
    if ($null -eq $Value -or "$Value" -eq '') { return }
    $t = $script:Trust[$Trust]
    $text = if ($Unit) { "$Value $Unit" } else { "$Value" }
    Write-C ('  {0,-22} ' -f $Label) 'Gray' -NoNewline
    Write-C ('{0,-40}' -f $text) 'White' -NoNewline
    Write-C $t.Label $t.Color
}

function Write-Note {
    param([string]$Text)
    Write-C ('  {0,-22} ' -f '') 'Gray' -NoNewline
    Write-C $Text 'DarkGray'
}

function Write-Gauge {
    param([string]$Label, $Percent, [string]$Verdict)
    Write-C ('  {0,-22} ' -f $Label) 'Gray' -NoNewline
    if ($null -eq $Percent) {
        Write-C ('{0,-40}' -f 'not reported') 'DarkGray' -NoNewline
        Write-C $Verdict.ToUpper() $script:VerdictColor[$Verdict]
        return
    }
    $width  = 24
    $filled = [int][math]::Round(($Percent / 100.0) * $width)
    $filled = [math]::Max(0, [math]::Min($width, $filled))
    $bar = ('#' * $filled) + ('.' * ($width - $filled))
    Write-C "[$bar] " $script:VerdictColor[$Verdict] -NoNewline
    Write-C ('{0,4}%   ' -f [math]::Round($Percent)) 'White' -NoNewline
    Write-C $Verdict.ToUpper() $script:VerdictColor[$Verdict]
}

function Write-Legend {
    Write-Host ''
    Write-C '  Where each reading came from:' 'Gray'
    Write-C '    DEVICE  ' 'Green'      -NoNewline
    Write-C ' the part itself answered. Faking it means reflashing the part.' 'DarkGray'
    Write-C '    KERNEL  ' 'Cyan'       -NoNewline
    Write-C " Windows' own view of the hardware." 'DarkGray'
    Write-C '    FIRMWARE' 'Blue'       -NoNewline
    Write-C ' the motherboard firmware tables. Faking it means reflashing the BIOS.' 'DarkGray'
    Write-C '    CALC    ' 'DarkGray'   -NoNewline
    Write-C ' worked out by RefurbMan from the readings above.' 'DarkGray'
    Write-C '    SOFTWARE' 'DarkYellow' -NoNewline
    Write-C ' editable settings. Never used to back a hardware claim.' 'DarkGray'
}

if ($LoadOnly) { return }

$script:IsWindowsHost = $true
if (Test-Path Variable:\IsWindows) { $script:IsWindowsHost = $IsWindows }
if (-not $script:IsWindowsHost) {
    Write-Host ''
    Write-Host '  RefurbMan.ps1 reads Windows hardware interfaces, and this is not Windows.' -ForegroundColor Yellow
    Write-Host '  For Linux, use the shell script instead:' -ForegroundColor Gray
    Write-Host ''
    Write-Host '    curl -fsSL https://raw.githubusercontent.com/sudomastery/refurbman/main/scripts/refurbman.sh | sudo bash' -ForegroundColor Cyan
    Write-Host ''
    return
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

$isAdmin = Test-Admin
$structures = @(Get-SmbiosStructures)

$machine   = Get-Machine       $structures
$cpus      = @(Get-Processor   $structures)
$slots     = @(Get-MemorySlots $structures)
$batteries = @(Get-Batteries)
$drives    = @(Get-Drives      $isAdmin)

# The kernel's own memory total, deliberately independent of the firmware
# table, so that the two can be compared against each other.
$kernelMemBytes = $null
try {
    $kernelMemBytes = [int64](Get-CimInstance -ClassName Win32_ComputerSystem -ErrorAction Stop).TotalPhysicalMemory
} catch { }

$slotTotalBytes = 0
foreach ($s in $slots) { $slotTotalBytes += $s.Bytes }
$populated = @($slots | Where-Object { $_.Populated }).Count

# Firmware claiming sticks Windows cannot see is a strong signal. Allow for the
# slice firmware reserves for integrated graphics, which legitimately hides a
# few hundred megabytes from the operating system.
if ($kernelMemBytes -and $slotTotalBytes -gt 0) {
    if (($slotTotalBytes - $kernelMemBytes) -gt 2GB) {
        Add-Finding -Severity Critical -Title 'Installed memory does not match what Windows can see' `
            -Detail ("The firmware lists $(Format-Bytes $slotTotalBytes) of memory across " +
                     "$populated slot(s), but Windows only sees $(Format-Bytes $kernelMemBytes). " +
                     'A gap this large usually means a faulty stick, a stick that is not seated ' +
                     'properly, or memory that is not really there.') `
            -Evidence "SMBIOS $slotTotalBytes bytes against kernel $kernelMemBytes bytes"
    }
}

if (-not $isAdmin) {
    Add-Finding -Severity Info -Title 'Drive health needs administrator rights' `
        -Detail ('This scan ran without administrator rights, so the drives could not be asked ' +
                 'about their own condition. Everything else below is complete. To see drive ' +
                 'wear, close this window, right click PowerShell, choose "Run as administrator", ' +
                 'and run this script again.')
}

# Verdicts are computed before rendering because they are what add the
# findings, and the findings section is printed last.
$driveVerdicts   = @{}
foreach ($d in $drives)    { $driveVerdicts[$d.Model]   = Get-DriveVerdict   $d }
$batteryVerdicts = @{}
foreach ($b in $batteries) { $batteryVerdicts[$b.Name]  = Get-BatteryVerdict $b }

if ($Json) {
    [pscustomobject]@{
        GeneratedAt       = (Get-Date).ToUniversalTime().ToString('o')
        Tool              = 'RefurbMan PowerShell'
        Privileged        = $isAdmin
        Machine           = $machine
        Processors        = $cpus
        MemorySlots       = $slots
        MemorySmbiosBytes = $slotTotalBytes
        MemoryKernelBytes = $kernelMemBytes
        Batteries         = $batteries
        Drives            = $drives
        Findings          = $script:Findings
    } | ConvertTo-Json -Depth 8
    return
}

Write-Banner

# --- Identity ---------------------------------------------------------------
Write-Rule 'This machine'
$title = Join-Parts @($machine.Manufacturer, $machine.Model)
if ($title) {
    Write-Host ''
    Write-C "  $title" 'White'
    if ($machine.Chassis) { Write-C "  $($machine.Chassis)" 'DarkGray' }
}
Write-Host ''
Write-Row 'Manufacturer'  $machine.Manufacturer
Write-Row 'Model'         $machine.Model
Write-Row 'Serial number' $machine.SerialNumber
Write-Row 'Motherboard'   (Join-Parts @($machine.BoardVendor, $machine.BoardModel))
Write-Row 'BIOS'          (Join-Parts @($machine.BiosVendor, $machine.BiosVersion, $machine.BiosDate))

# --- Processor --------------------------------------------------------------
Write-Host ''
Write-Rule 'Processor'
if ($cpus.Count -eq 0) {
    Write-Host ''
    Write-C '  Not reported by the firmware.' 'DarkGray'
} else {
    foreach ($c in $cpus) {
        Write-Host ''
        Write-Row 'Model'  $c.Model
        Write-Row 'Socket' $c.Socket
        if ($c.Contains('Cores'))   { Write-Row 'Cores'   $c.Cores }
        if ($c.Contains('Threads')) { Write-Row 'Threads' $c.Threads }
        if ($c.MaxSpeedMhz)         { Write-Row 'Rated speed' $c.MaxSpeedMhz 'Firmware' 'MHz' }
    }
    Write-Host ''
    Write-C '  Read from the firmware table, not from the registry string that most tools' 'DarkGray'
    Write-C '  report and that anyone with administrator rights can rewrite in seconds.' 'DarkGray'
}

# --- Memory -----------------------------------------------------------------
Write-Host ''
Write-Rule 'Memory'
Write-Host ''
if ($slotTotalBytes -gt 0) {
    Write-Row 'Installed'  (Format-Bytes $slotTotalBytes)
    Write-Row 'Slots used' "$populated of $($slots.Count)"
}
if ($kernelMemBytes) { Write-Row 'Windows can see' (Format-Bytes $kernelMemBytes) 'Kernel' }
if ($slots.Count -gt 0) { Write-Host '' }
foreach ($s in $slots) {
    if (-not $s.Populated) {
        Write-C ('  {0,-22} ' -f $s.Slot) 'Gray' -NoNewline
        Write-C 'empty' 'DarkGray'
        continue
    }
    $line = Join-Parts @((Format-Bytes $s.Bytes), $s.Type)
    if     ($s.ConfiguredMts) { $line += " at $($s.ConfiguredMts) MT/s" }
    elseif ($s.SpeedMts)      { $line += " at $($s.SpeedMts) MT/s" }
    Write-Row $s.Slot $line
    $part = Join-Parts @($s.Manufacturer, $s.PartNumber)
    if ($part) { Write-Note $part }
}

# --- Storage ----------------------------------------------------------------
Write-Host ''
Write-Rule 'Storage'
if ($drives.Count -eq 0) {
    Write-Host ''
    Write-C '  No drives reported.' 'DarkGray'
}
foreach ($d in $drives) {
    $v = $driveVerdicts[$d.Model]
    Write-Host ''
    Write-C "  $($d.Model)" 'White'
    Write-C "  $($v.Headline)" $script:VerdictColor[$v.Verdict]
    Write-Host ''
    Write-Gauge 'Life remaining' $v.Percent $v.Verdict
    Write-Row 'Capacity'  (Format-Bytes $d.SizeBytes) 'Kernel'
    Write-Row 'Type'      (Join-Parts @($d.MediaType, $d.BusType) ' / ') 'Kernel'
    Write-Row 'Firmware'  $d.Firmware 'Device'
    if ($null -ne $d.PowerOnHours) { Write-Row 'Powered on for' (Format-Hours $d.PowerOnHours) 'Device' }
    if ($null -ne $d.TemperatureC) { Write-Row 'Temperature'    $d.TemperatureC 'Device' 'C' }
    if ($null -ne $d.Wear)         { Write-Row 'Life used'      $d.Wear 'Device' '%' }
    Write-Row 'Drive self-check' $d.SelfAssessment 'Device'
}

# --- Battery ----------------------------------------------------------------
if ($batteries.Count -gt 0) {
    Write-Host ''
    Write-Rule 'Battery'
    foreach ($b in $batteries) {
        $v = $batteryVerdicts[$b.Name]
        Write-Host ''
        Write-C "  $($b.Name)" 'White'
        Write-C "  $($v.Headline)" $script:VerdictColor[$v.Verdict]
        Write-Host ''
        Write-Gauge 'Health' $v.Percent $v.Verdict
        if ($b.DesignedmWh -gt 0) { Write-Row 'Capacity when new' $b.DesignedmWh 'Device' 'mWh' }
        if ($b.CurrentmWh  -gt 0) { Write-Row 'Capacity now'      $b.CurrentmWh  'Device' 'mWh' }
        if ($null -ne $b.CycleCount) { Write-Row 'Charge cycles' $b.CycleCount 'Device' }
        else {
            Write-C ('  {0,-22} ' -f 'Charge cycles') 'Gray' -NoNewline
            Write-C 'not reported by this battery' 'DarkGray'
        }
        Write-Row 'Chemistry' $b.Chemistry 'Device'
    }
}

# --- Findings ---------------------------------------------------------------
Write-Host ''
Write-Rule 'What you should know'
Write-Host ''
if ($script:Findings.Count -eq 0) {
    Write-C '  Nothing of concern was found.' 'Green'
    Write-Host ''
} else {
    $order = @{ Critical = 0; Warn = 1; Info = 2 }
    foreach ($f in ($script:Findings | Sort-Object { $order[$_.Severity] })) {
        $color = switch ($f.Severity) { 'Critical' { 'Red' } 'Warn' { 'Yellow' } default { 'Cyan' } }
        $mark  = switch ($f.Severity) { 'Critical' { '[!]' } 'Warn' { '[*]' } default { '[i]' } }
        Write-C "  $mark $($f.Title)" $color
        foreach ($line in (Split-Wrapped $f.Detail 72)) { Write-C "      $line" 'Gray' }
        if ($f.Evidence) { Write-C "      evidence: $($f.Evidence)" 'DarkGray' }
        Write-Host ''
    }
}

Write-Legend

Write-Host ''
Write-Rule
Write-C '  This report raises the effort needed to deceive you from editing a registry' 'DarkGray'
Write-C '  value to reflashing firmware. It is not proof. Someone with deep access to' 'DarkGray'
Write-C '  this machine can still lie to it, so treat it as strong evidence rather than' 'DarkGray'
Write-C '  a guarantee, and weigh it against how the machine actually behaves.' 'DarkGray'
Write-Host ''
