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

.PARAMETER Html
    Write a self-contained HTML report to this path. Open it in a browser and
    choose Print, then Save as PDF, for a PDF copy.

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
    [string]$Html,
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
$script:UseColor = -not $NoColor -and -not $Json -and -not $Html

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

# ---------------------------------------------------------------------------
# HTML report
#
# One self-contained file: no images, no scripts, no network. Any browser turns
# it into a PDF with Print, which is why there is no PDF library here. The
# stylesheet is copied from assets/report.css by scripts/sync-report-css.py,
# and continuous integration fails if this copy drifts from the original.
# ---------------------------------------------------------------------------

function Get-ReportCss {
$css = @'
:root {
  color-scheme: light;
  --surface:      #fcfcfb;
  --surface-2:    #f4f4f2;
  --line:         #e2e1dd;
  --ink:          #0b0b0b;
  --ink-2:        #52514e;
  --ink-3:        #7a7873;

  /* Status palette. Fixed, never themed, never reused for anything else. */
  --good:     #0ca30c;
  --warning:  #fab219;
  --critical: #d03b3b;
  --neutral:  #7a7873;
  --accent:   #2a78d6;
}
@media (prefers-color-scheme: dark) {
  :root:not([data-theme="light"]) {
    color-scheme: dark;
    --surface:   #1a1a19;
    --surface-2: #232322;
    --line:      #35342f;
    --ink:       #ffffff;
    --ink-2:     #c3c2b7;
    --ink-3:     #94938b;
    --accent:    #3987e5;
  }
}
:root[data-theme="dark"] {
  color-scheme: dark;
  --surface:   #1a1a19;
  --surface-2: #232322;
  --line:      #35342f;
  --ink:       #ffffff;
  --ink-2:     #c3c2b7;
  --ink-3:     #94938b;
  --accent:    #3987e5;
}

* { box-sizing: border-box; }
body {
  margin: 0;
  background: var(--surface);
  color: var(--ink);
  font: 15px/1.55 ui-sans-serif, system-ui, -apple-system, "Segoe UI", Roboto,
        "Helvetica Neue", Arial, sans-serif;
  -webkit-font-smoothing: antialiased;
}
.page { max-width: 60rem; margin: 0 auto; padding: 2.5rem 1.5rem 4rem; }

/* --- masthead --- */
.masthead { border-bottom: 2px solid var(--ink); padding-bottom: 1.25rem; margin-bottom: 2rem; }
.brand {
  font-size: .75rem; font-weight: 700; letter-spacing: .14em;
  text-transform: uppercase; color: var(--ink-3);
}
.masthead h1 { margin: .35rem 0 .2rem; font-size: 1.9rem; line-height: 1.2; font-weight: 650; }
.sub { margin: 0; color: var(--ink-2); }
.stamp { margin: .5rem 0 0; font-size: .8rem; color: var(--ink-3); }

/* --- sections --- */
.block { margin: 0 0 2.25rem; }
.block h2 {
  font-size: .78rem; font-weight: 700; letter-spacing: .12em; text-transform: uppercase;
  color: var(--ink-3); margin: 0 0 .9rem; padding-bottom: .4rem;
  border-bottom: 1px solid var(--line);
}
.sub-head { font-size: .95rem; margin: 1.1rem 0 .4rem; font-weight: 620; }
.lede { margin: 0 0 1rem; color: var(--ink-2); max-width: 46rem; }

/* --- condition cards --- */
.cards { display: grid; gap: 1rem; grid-template-columns: repeat(auto-fit, minmax(20rem, 1fr)); }
.card {
  border: 1px solid var(--line); border-radius: 10px; padding: 1.1rem 1.15rem;
  background: var(--surface-2); break-inside: avoid;
}
.card-top { display: flex; align-items: baseline; justify-content: space-between; gap: .75rem; }
.card h3 { margin: 0; font-size: 1rem; font-weight: 620; overflow-wrap: anywhere; }
.headline { margin: .7rem 0 0; color: var(--ink-2); }

/* Verdict badge: shape, word and colour together. Under deuteranopia the good
   green and the poor red are 4.1 apart, so neither the colour nor the shape is
   allowed to be load-bearing on its own. */
.badge {
  display: inline-flex; align-items: center; gap: .3rem; flex: none;
  font-size: .72rem; font-weight: 700; letter-spacing: .06em; text-transform: uppercase;
  padding: .18rem .5rem; border-radius: 99px; border: 1px solid currentColor;
}
.badge .mark { font-size: .85em; }
.b-good    { color: #067a06; }
.b-fair    { color: #8a6000; }
.b-poor    { color: #b02a2a; }
.b-unknown { color: var(--ink-3); }
@media (prefers-color-scheme: dark) {
  :root:not([data-theme="light"]) .b-good { color: #3fbf3f; }
  :root:not([data-theme="light"]) .b-fair { color: var(--warning); }
  :root:not([data-theme="light"]) .b-poor { color: #e56a6a; }
}

/* --- meters --- */
.meter-row { margin: .9rem 0 0; }
.meter-label { font-size: .78rem; color: var(--ink-3); margin-bottom: .3rem; }
.meter { display: flex; align-items: center; gap: .6rem; }
.track {
  position: relative; flex: 1; height: 9px; border-radius: 99px;
  background: color-mix(in oklab, var(--bar, var(--neutral)) 16%, var(--surface));
  overflow: hidden;
}
.fill { height: 100%; border-radius: 99px; background: var(--bar, var(--neutral)); }
.meter-value {
  font-size: .9rem; font-weight: 650; min-width: 4.4rem; text-align: right;
  color: var(--ink);
}
.meter-value.muted { font-weight: 500; color: var(--ink-3); font-size: .82rem; }
.v-good    { --bar: var(--good); }
.v-fair    { --bar: var(--warning); }
.v-poor    { --bar: var(--critical); }
.v-unknown { --bar: var(--neutral); }
.trust     { --bar: var(--accent); margin: 0 0 1.2rem; }

/* A claimed-but-doubted figure. The hatching is the part of the signal that
   survives greyscale printing and every form of colour blindness. */
.meter.doubted .fill {
  background: repeating-linear-gradient(
    135deg,
    var(--neutral) 0 5px,
    color-mix(in oklab, var(--neutral) 30%, var(--surface)) 5px 10px);
}
.meter.doubted .meter-value { color: var(--ink-3); font-weight: 500; }
.qualifier {
  display: block; font-size: .6rem; font-weight: 700; letter-spacing: .06em;
  text-transform: uppercase; color: var(--ink-3); line-height: 1.3;
}
.meter.unmeasured .track {
  background: repeating-linear-gradient(135deg, var(--line) 0 4px, transparent 4px 8px);
}

/* --- fact lists --- */
.facts { margin: .9rem 0 0; display: grid; gap: .3rem 1.5rem; }
.facts.wide { grid-template-columns: repeat(auto-fit, minmax(25rem, 1fr)); }
.fact {
  display: flex; align-items: baseline; gap: .6rem;
  border-bottom: 1px solid var(--line); padding: .3rem 0;
}
.fact dt { flex: none; width: 9rem; color: var(--ink-3); font-size: .85rem; }
.fact dd {
  margin: 0; flex: 1; display: flex; align-items: baseline;
  justify-content: space-between; gap: .6rem; overflow-wrap: anywhere;
}

/* Provenance chip. Deliberately quiet: it qualifies a reading, it is not the
   reading. */
.chip {
  flex: none; font-size: .6rem; font-weight: 700; letter-spacing: .07em;
  text-transform: uppercase; padding: .1rem .38rem; border-radius: 4px;
  border: 1px solid var(--line); color: var(--ink-3); background: var(--surface);
  white-space: nowrap;
}
.t4 { color: #067a06; border-color: currentColor; }
.t3 { color: #1f6f8b; border-color: currentColor; }
.t2 { color: #3a5ea8; border-color: currentColor; }
.t1 { color: var(--ink-3); }
.t0 { color: #8a6000; border-color: currentColor; }

/* --- checks --- */
.checks, .findings, .plain { list-style: none; margin: 0; padding: 0; }
.check { display: flex; gap: .7rem; padding: .55rem 0; border-bottom: 1px solid var(--line); }
.check .mark { flex: none; width: 1.2rem; text-align: center; font-weight: 700; }
.check-title { margin: 0; font-weight: 600; font-size: .93rem; }
.check-word {
  font-size: .68rem; font-weight: 700; letter-spacing: .06em; text-transform: uppercase;
  margin-left: .4rem; padding: .05rem .35rem; border-radius: 4px;
  border: 1px solid currentColor;
}
.check-detail { margin: .2rem 0 0; color: var(--ink-2); font-size: .88rem; }
.check.pass { color: #067a06; }
.check.look { color: #8a6000; }
.check.fail { color: #b02a2a; }
.check.skip { color: var(--ink-3); }
.check.pass .check-detail, .check.skip .check-detail { color: var(--ink-3); }
.check-title, .check.look .check-detail, .check.fail .check-detail { color: var(--ink); }
@media (prefers-color-scheme: dark) {
  :root:not([data-theme="light"]) .check.pass { color: #3fbf3f; }
  :root:not([data-theme="light"]) .check.fail { color: #e56a6a; }
  :root:not([data-theme="light"]) .check.look { color: var(--warning); }
  :root:not([data-theme="light"]) .t4 { color: #3fbf3f; }
  :root:not([data-theme="light"]) .t3 { color: #6fc4dd; }
  :root:not([data-theme="light"]) .t2 { color: #8fb0f0; }
  :root:not([data-theme="light"]) .t0 { color: var(--warning); }
}

/* --- findings --- */
.finding {
  border-left: 3px solid currentColor; padding: .55rem 0 .55rem .85rem;
  margin: 0 0 1rem; break-inside: avoid;
}
.f-head { margin: 0; font-weight: 650; color: var(--ink); }
.f-head .mark { font-weight: 700; margin-right: .4rem; }
.f-word {
  font-size: .66rem; font-weight: 700; letter-spacing: .06em; text-transform: uppercase;
  margin-right: .55rem; padding: .08rem .38rem; border-radius: 4px;
  border: 1px solid currentColor;
}
.f-detail { margin: .3rem 0 0; color: var(--ink-2); max-width: 46rem; }
.evidence {
  margin: .35rem 0 0; font-size: .78rem; color: var(--ink-3);
  font-family: ui-monospace, SFMono-Regular, Menlo, Consolas, monospace;
  overflow-wrap: anywhere;
}
.finding.critical { color: #b02a2a; }
.finding.warn     { color: #8a6000; }
.finding.info     { color: var(--ink-3); }
@media (prefers-color-scheme: dark) {
  :root:not([data-theme="light"]) .finding.critical { color: #e56a6a; }
  :root:not([data-theme="light"]) .finding.warn     { color: var(--warning); }
}

/* --- legend --- */
.legend { display: grid; grid-template-columns: auto 1fr; gap: .35rem .8rem; margin: 0; }
.legend dt { margin: 0; }
.legend dd { margin: 0; color: var(--ink-2); font-size: .88rem; }

/* --- footer --- */
.disclaimer {
  margin-top: 2.5rem; padding-top: 1.25rem; border-top: 1px solid var(--line);
  color: var(--ink-2); font-size: .88rem; break-inside: avoid;
}
.disclaimer strong { color: var(--ink); }
.fine { color: var(--ink-3); font-size: .8rem; }
.plain li { padding: .3rem 0; color: var(--ink-2); border-bottom: 1px solid var(--line); }

/* --- print --- */
@page { margin: 16mm 14mm; }
@media print {
  :root {
    color-scheme: light;
    --surface: #fff; --surface-2: #fff; --line: #ccc;
    --ink: #000; --ink-2: #333; --ink-3: #555;
  }
  body { font-size: 10.5pt; background: #fff; }
  .page { max-width: none; padding: 0; }
  .block { break-inside: auto; }
  .block h2 { break-after: avoid; }
  .card, .finding, .check, .disclaimer { break-inside: avoid; }
  .cards { grid-template-columns: 1fr 1fr; }
  /* Browsers drop backgrounds by default, which would erase every meter. */
  .track, .fill, .badge, .chip { -webkit-print-color-adjust: exact; print-color-adjust: exact; }
  a[href]::after { content: ""; }
}
'@
    return $css
}

function Get-MachineTitle {
    param($Machine)
    $vendor = $Machine.Manufacturer
    $model  = $Machine.Model
    if ($vendor -and $model -and $model.StartsWith("$vendor ")) { return $model }
    $t = (@($vendor, $model) | Where-Object { $_ }) -join ' '
    if ($t) { return $t }
    return 'Unidentified machine'
}

function ConvertTo-HtmlText {
    # These values came off hardware on a machine you did not build, so they are
    # escaped rather than trusted.
    param([string]$Text)
    if ([string]::IsNullOrEmpty($Text)) { return '' }
    $Text.Replace('&', '&amp;').Replace('<', '&lt;').Replace('>', '&gt;').
          Replace('"', '&quot;').Replace("'", '&#39;')
}

function New-HtmlRow {
    param([string]$Label, $Value, [int]$Rank = 2, [string]$Trust = 'SYSTEM FIRMWARE', [string]$Unit = '')
    if ($null -eq $Value -or "$Value" -eq '') { return '' }
    $text = if ($Unit) { "$Value $Unit" } else { "$Value" }
    '<div class="fact"><dt>{0}</dt><dd>{1}<span class="chip t{2}">{3}</span></dd></div>' -f `
        (ConvertTo-HtmlText $Label), (ConvertTo-HtmlText $text), $Rank, $Trust
}

function New-HtmlBadge {
    param([string]$Verdict)
    switch ($Verdict) {
        'Good' { '<span class="badge b-good"><span class="mark" aria-hidden="true">&#10003;</span>Good</span>' }
        'Fair' { '<span class="badge b-fair"><span class="mark" aria-hidden="true">&#33;</span>Fair</span>' }
        'Poor' { '<span class="badge b-poor"><span class="mark" aria-hidden="true">&#10007;</span>Poor</span>' }
        default { '<span class="badge b-unknown"><span class="mark" aria-hidden="true">&#63;</span>Not known</span>' }
    }
}

function New-HtmlMeter {
    param([string]$Label, $Percent, [string]$Verdict)
    $slug = $Verdict.ToLowerInvariant()
    $out = '<div class="meter-row"><div class="meter-label">{0}</div>' -f (ConvertTo-HtmlText $Label)
    if ($null -eq $Percent) {
        return $out + '<div class="meter unmeasured"><div class="track"></div>' +
               '<div class="meter-value muted">not reported</div></div></div>'
    }
    # A figure we do not believe gets a hatched fill: a solid bar at 100% reads
    # as excellent at a glance, which is the opposite of what Not known means.
    $extra = ''; $qual = ''
    if ($Verdict -eq 'Unknown') { $extra = ' doubted'; $qual = '<span class="qualifier">claimed</span>' }
    $out + ('<div class="meter v-{0}{1}"><div class="track"><div class="fill" style="width:{2:N1}%"></div></div>' -f $slug, $extra, $Percent) +
           ('<div class="meter-value">{0:N0}%{1}</div></div></div>' -f $Percent, $qual)
}

function Export-HtmlReport {
    param(
        [string]$Path, $Machine, $Cpus, $Slots, $Batteries, $Drives,
        $DriveVerdicts, $BatteryVerdicts, $KernelMemBytes, $SlotTotalBytes,
        [bool]$IsAdmin
    )

    # Manufacturers often repeat themselves: "HP" alongside "HP Pavilion Aero"
    # should read as one name, not two.
    $title = Get-MachineTitle $Machine
    $t = ConvertTo-HtmlText $title

    $sb = New-Object System.Text.StringBuilder
    $add = { param($x) [void]$sb.AppendLine($x) }

    & $add '<!doctype html>'
    & $add '<html lang="en">'
    & $add '<head>'
    & $add '<meta charset="utf-8">'
    & $add '<meta name="viewport" content="width=device-width, initial-scale=1">'
    & $add "<title>RefurbMan report: $t</title>"
    & $add '<style>'
    & $add (Get-ReportCss)
    & $add '</style></head><body><main class="page">'

    & $add '<header class="masthead"><div class="brand">RefurbMan</div>'
    & $add "<h1>$t</h1>"
    if ($Machine.Chassis) { & $add ('<p class="sub">{0}</p>' -f (ConvertTo-HtmlText $Machine.Chassis)) }
    & $add ('<p class="stamp">Checked {0} &middot; RefurbMan PowerShell &middot; {1} scan</p></header>' -f `
        (Get-Date).ToUniversalTime().ToString('o'), $(if ($IsAdmin) { 'full' } else { 'limited' }))

    # --- condition ---
    if ($Drives.Count -gt 0 -or $Batteries.Count -gt 0) {
        & $add '<section class="block"><h2>Condition of the parts that wear out</h2><div class="cards">'
        foreach ($d in $Drives) {
            $v = $DriveVerdicts[$d.Model]
            & $add ('<article class="card v-{0}"><div class="card-top"><h3>{1}</h3>{2}</div>' -f `
                $v.Verdict.ToLowerInvariant(), (ConvertTo-HtmlText $d.Model), (New-HtmlBadge $v.Verdict))
            & $add (New-HtmlMeter 'Life remaining' $v.Percent $v.Verdict)
            & $add ('<p class="headline">{0}</p><dl class="facts">' -f (ConvertTo-HtmlText $v.Headline))
            & $add (New-HtmlRow 'Capacity' (Format-Bytes $d.SizeBytes) 3 'KERNEL')
            & $add (New-HtmlRow 'Type' ((@($d.MediaType, $d.BusType) | Where-Object { $_ }) -join ' / ') 3 'KERNEL')
            if ($null -ne $d.PowerOnHours) { & $add (New-HtmlRow 'Powered on for' (Format-Hours $d.PowerOnHours) 4 'DEVICE FIRMWARE') }
            if ($null -ne $d.TemperatureC) { & $add (New-HtmlRow 'Temperature' $d.TemperatureC 4 'DEVICE FIRMWARE' 'C') }
            & $add (New-HtmlRow 'Drive self-check' $d.SelfAssessment 4 'DEVICE FIRMWARE')
            & $add '</dl></article>'
        }
        foreach ($b in $Batteries) {
            $v = $BatteryVerdicts[$b.Name]
            & $add ('<article class="card v-{0}"><div class="card-top"><h3>{1}</h3>{2}</div>' -f `
                $v.Verdict.ToLowerInvariant(), (ConvertTo-HtmlText $b.Name), (New-HtmlBadge $v.Verdict))
            & $add (New-HtmlMeter 'Capacity remaining' $v.Percent $v.Verdict)
            & $add ('<p class="headline">{0}</p><dl class="facts">' -f (ConvertTo-HtmlText $v.Headline))
            if ($null -ne $b.CycleCount) { & $add (New-HtmlRow 'Charge cycles' $b.CycleCount 4 'DEVICE FIRMWARE') }
            if ($b.DesignedmWh -gt 0) { & $add (New-HtmlRow 'Capacity when new' $b.DesignedmWh 4 'DEVICE FIRMWARE' 'mWh') }
            if ($b.CurrentmWh -gt 0)  { & $add (New-HtmlRow 'Capacity now' $b.CurrentmWh 4 'DEVICE FIRMWARE' 'mWh') }
            & $add (New-HtmlRow 'Chemistry' $b.Chemistry 4 'DEVICE FIRMWARE')
            & $add '</dl></article>'
        }
        & $add '</div></section>'
    }

    # --- identity ---
    & $add '<section class="block"><h2>This machine</h2><dl class="facts wide">'
    & $add (New-HtmlRow 'Manufacturer'  $Machine.Manufacturer)
    & $add (New-HtmlRow 'Model'         $Machine.Model)
    & $add (New-HtmlRow 'Family'        $Machine.Family)
    & $add (New-HtmlRow 'Serial number' $Machine.SerialNumber)
    & $add (New-HtmlRow 'Form'          $Machine.Chassis)
    & $add (New-HtmlRow 'Motherboard'   ((@($Machine.BoardVendor, $Machine.BoardModel) | Where-Object { $_ }) -join ' '))
    & $add (New-HtmlRow 'BIOS'          ((@($Machine.BiosVendor, $Machine.BiosVersion, $Machine.BiosDate) | Where-Object { $_ }) -join ' '))
    & $add '</dl></section>'

    # --- processor ---
    if ($Cpus.Count -gt 0) {
        & $add '<section class="block"><h2>Processor</h2>'
        foreach ($c in $Cpus) {
            & $add '<dl class="facts wide">'
            & $add (New-HtmlRow 'Processor' $c.Model)
            & $add (New-HtmlRow 'Socket'    $c.Socket)
            if ($c.Contains('Cores'))   { & $add (New-HtmlRow 'Cores'   $c.Cores) }
            if ($c.Contains('Threads')) { & $add (New-HtmlRow 'Threads' $c.Threads) }
            if ($c.MaxSpeedMhz) { & $add (New-HtmlRow 'Maximum speed' $c.MaxSpeedMhz 2 'SYSTEM FIRMWARE' 'MHz') }
            & $add '</dl>'
        }
        & $add '</section>'
    }

    # --- memory ---
    & $add '<section class="block"><h2>Memory</h2><dl class="facts wide">'
    if ($SlotTotalBytes -gt 0) { & $add (New-HtmlRow 'Installed' (Format-Bytes $SlotTotalBytes)) }
    if ($KernelMemBytes) { & $add (New-HtmlRow 'Windows can see' (Format-Bytes $KernelMemBytes) 3 'KERNEL') }
    & $add '</dl>'
    foreach ($s in ($Slots | Where-Object { $_.Populated })) {
        & $add ('<h3 class="sub-head">{0}</h3><dl class="facts wide">' -f (ConvertTo-HtmlText $s.Slot))
        & $add (New-HtmlRow 'Size' (Format-Bytes $s.Bytes))
        & $add (New-HtmlRow 'Type' $s.Type)
        & $add (New-HtmlRow 'Running at' $s.ConfiguredMts 2 'SYSTEM FIRMWARE' 'MT/s')
        & $add (New-HtmlRow 'Made by' $s.Manufacturer)
        & $add (New-HtmlRow 'Part number' $s.PartNumber)
        & $add '</dl>'
    }
    & $add '</section>'

    # --- findings ---
    & $add '<section class="block"><h2>What you should know</h2>'
    if ($script:Findings.Count -eq 0) {
        & $add '<p class="lede">Nothing of concern was found.</p></section>'
    } else {
        & $add '<ul class="findings">'
        $order = @{ Critical = 0; Warn = 1; Info = 2 }
        foreach ($f in ($script:Findings | Sort-Object { $order[$_.Severity] })) {
            $cls  = $f.Severity.ToLowerInvariant()
            $mark = switch ($f.Severity) { 'Critical' { '&#10007;' } 'Warn' { '&#33;' } default { '&#105;' } }
            $word = switch ($f.Severity) { 'Critical' { 'Serious' } 'Warn' { 'Worth knowing' } default { 'For information' } }
            & $add ('<li class="finding {0}"><p class="f-head"><span class="mark" aria-hidden="true">{1}</span><span class="f-word">{2}</span>{3}</p><p class="f-detail">{4}</p>' -f `
                $cls, $mark, $word, (ConvertTo-HtmlText $f.Title), (ConvertTo-HtmlText $f.Detail))
            if ($f.Evidence) { & $add ('<p class="evidence">{0}</p>' -f (ConvertTo-HtmlText $f.Evidence)) }
            & $add '</li>'
        }
        & $add '</ul></section>'
    }

    # --- provenance ---
    & $add '<section class="block"><h2>Where these readings came from</h2><dl class="legend">'
    & $add '<dt><span class="chip t4">DEVICE FIRMWARE</span></dt><dd>The part itself reported this. Changing it means reflashing the part.</dd>'
    & $add '<dt><span class="chip t3">KERNEL</span></dt><dd>Windows'' own view of the hardware.</dd>'
    & $add '<dt><span class="chip t2">SYSTEM FIRMWARE</span></dt><dd>The motherboard firmware tables. Changing them means reflashing the BIOS.</dd>'
    & $add '</dl></section>'

    & $add '<footer class="disclaimer"><p><strong>What this report is, and is not.</strong> It raises the effort needed to deceive you from editing a registry value to reflashing firmware. It is not proof. There is no signing chain here and no hardware attestation, so somebody with deep enough access to this machine can still lie to it. Treat this as strong evidence rather than a guarantee, and weigh it against how the machine actually behaves.</p>'
    & $add '<p class="fine">Generated by RefurbMan, which reads from the Windows kernel, the motherboard firmware tables, and the parts themselves, and never from the registry.</p></footer>'
    & $add '</main></body></html>'

    [System.IO.File]::WriteAllText($Path, $sb.ToString(), [System.Text.UTF8Encoding]::new($false))
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

if ($Html) {
    Export-HtmlReport -Path $Html -Machine $machine -Cpus $cpus -Slots $slots `
        -Batteries $batteries -Drives $drives -DriveVerdicts $driveVerdicts `
        -BatteryVerdicts $batteryVerdicts -KernelMemBytes $kernelMemBytes `
        -SlotTotalBytes $slotTotalBytes -IsAdmin $isAdmin
    Write-Host "Report written to $Html"
    Write-Host 'Open it in a browser and choose Print, then Save as PDF, for a PDF copy.'
    return
}

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
$title = Get-MachineTitle $machine
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
