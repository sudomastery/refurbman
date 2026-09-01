<#
    Tests for the RefurbMan PowerShell script.

    These run anywhere PowerShell runs, including Linux and macOS, because they
    exercise the parts that do not touch Windows: the SMBIOS byte parsing and
    the judgement logic. Those are the parts where a mistake would be silent,
    so they are the parts worth pinning down.

    Run:  pwsh -File tests/RefurbMan.Tests.ps1
#>

$ErrorActionPreference = 'Stop'
$script:Pass = 0
$script:Fail = 0

function Assert-Equal {
    param($Expected, $Actual, [string]$Because)
    if ($Expected -eq $Actual) {
        $script:Pass++
        Write-Host "  ok   $Because" -ForegroundColor DarkGreen
    } else {
        $script:Fail++
        Write-Host "  FAIL $Because" -ForegroundColor Red
        Write-Host "         expected: $Expected" -ForegroundColor DarkGray
        Write-Host "         actual:   $Actual"   -ForegroundColor DarkGray
    }
}

function Assert-True {
    param($Condition, [string]$Because)
    Assert-Equal $true ([bool]$Condition) $Because
}

$here = Split-Path -Parent $MyInvocation.MyCommand.Path
. (Join-Path $here '..' 'scripts' 'RefurbMan.ps1') -LoadOnly

# ---------------------------------------------------------------------------
# Synthetic SMBIOS tables
#
# Built by hand from the DMTF specification so the byte offsets in the parser
# are checked against the spec rather than against whatever this machine
# happens to report.
# ---------------------------------------------------------------------------

function New-SmbiosStructure {
    param([byte]$Type, [byte[]]$Formatted, [string[]]$Strings)
    $bytes = New-Object System.Collections.Generic.List[byte]
    $bytes.Add($Type)
    $bytes.Add([byte]($Formatted.Length + 4))
    $bytes.AddRange([byte[]]@(0x01, 0x00))   # handle
    $bytes.AddRange($Formatted)
    if ($Strings.Count -eq 0) {
        $bytes.AddRange([byte[]]@(0x00, 0x00))
    } else {
        foreach ($s in $Strings) {
            $bytes.AddRange([System.Text.Encoding]::ASCII.GetBytes($s))
            $bytes.Add(0x00)
        }
        $bytes.Add(0x00)
    }
    # The leading comma stops PowerShell unrolling the array into Object[].
    return ,$bytes.ToArray()
}

function New-TestTable {
    $all = New-Object System.Collections.Generic.List[byte]

    # Type 1, System Information. Offsets 4..7 are string indexes, 8..23 the
    # UUID, 25 the SKU and 26 the family.
    $sys = New-Object byte[] 23
    $sys[0] = 1  # manufacturer
    $sys[1] = 2  # product name
    $sys[2] = 3  # version
    $sys[3] = 4  # serial number
    $sys[21] = 5 # SKU
    $sys[22] = 6 # family
    $all.AddRange((New-SmbiosStructure 1 $sys @(
        'ACME Computers', 'SuperBook 9000', '1.0', 'SN-TEST-0001', 'SKU-1', 'SuperBook')))

    # Type 17, Memory Device. Size at 12..13 in megabytes when bit 15 is clear,
    # locator at 16, memory type at 18, speed at 21..22, manufacturer at 23,
    # part number at 26, configured speed at 32..33.
    $mem = New-Object byte[] 30
    $mem[8]  = 0x00; $mem[9] = 0x20      # size 0x2000 = 8192 MB = 8 GB
    $mem[12] = 1                          # device locator
    $mem[13] = 2                          # bank locator
    $mem[14] = 0x1A                       # DDR4
    $mem[17] = 0x80; $mem[18] = 0x0C      # speed 3200 MT/s
    $mem[19] = 3                          # manufacturer
    $mem[20] = 4                          # serial
    $mem[21] = 5                          # asset tag
    $mem[22] = 6                          # part number
    $mem[28] = 0x80; $mem[29] = 0x0C      # configured speed 3200 MT/s
    $all.AddRange((New-SmbiosStructure 17 $mem @(
        'DIMM A', 'BANK 0', 'Micron', 'MEMSER1', 'AssetTag', 'MT40A1G8')))

    # An empty second slot: size zero, and the OEM left placeholder junk behind.
    $empty = New-Object byte[] 30
    $empty[8] = 0; $empty[9] = 0
    $empty[12] = 1
    $empty[19] = 2
    $all.AddRange((New-SmbiosStructure 17 $empty @('DIMM B', 'To Be Filled By O.E.M.')))

    # Type 4, Processor. Version string at 16, status at 24, core count at 35,
    # thread count at 37, max speed at 20..21.
    $cpu = New-Object byte[] 34
    $cpu[0]  = 1                          # socket designation
    $cpu[3]  = 2                          # manufacturer
    $cpu[12] = 3                          # version
    $cpu[16] = 0x10; $cpu[17] = 0x0E      # max speed 3600 MHz
    $cpu[20] = 0x41                       # status: populated, enabled
    $cpu[31] = 6                          # core count
    $cpu[33] = 12                         # thread count
    $all.AddRange((New-SmbiosStructure 4 $cpu @('AM4', 'ACME', 'ACME Ryzen 5 5600U')))

    # Type 127 terminates the table.
    $all.AddRange([byte[]]@(127, 4, 0x02, 0x00, 0x00, 0x00))
    return $all.ToArray()
}

# Get-SmbiosStructures reads from WMI, so the parse loop is exercised through a
# small local copy of the same walk. Keeping this in step with the script is the
# point of the offset assertions below.
function Parse-TestTable {
    param([byte[]]$raw)
    $structures = New-Object System.Collections.ArrayList
    $i = 0
    while ($i -lt $raw.Length - 4) {
        $type = $raw[$i]; $length = $raw[$i + 1]
        if ($length -lt 4) { break }
        if ($type -eq 127) { break }
        $formatted = $raw[$i..($i + $length - 1)]
        $s = $i + $length
        $strings = New-Object System.Collections.ArrayList
        $cur = New-Object System.Text.StringBuilder
        while ($s -lt $raw.Length) {
            if ($raw[$s] -eq 0) {
                if ($cur.Length -eq 0) { $s++; break }
                [void]$strings.Add($cur.ToString()); [void]$cur.Clear()
            } else { [void]$cur.Append([char]$raw[$s]) }
            $s++
        }
        [void]$structures.Add([pscustomobject]@{ Type = $type; Data = $formatted; Strings = $strings })
        $i = $s
    }
    return $structures
}

Write-Host "`nSMBIOS parsing" -ForegroundColor Cyan
$structures = @(Parse-TestTable (New-TestTable))
Assert-Equal 4 $structures.Count 'walks every structure and stops at the end marker'

$machine = Get-Machine $structures
Assert-Equal 'ACME Computers' $machine.Manufacturer 'reads the manufacturer string'
Assert-Equal 'SuperBook 9000' $machine.Model        'reads the model string'
Assert-Equal 'SN-TEST-0001'   $machine.SerialNumber 'reads the serial number'
Assert-Equal 'SuperBook'      $machine.Family       'reads the family from offset 0x1A'

$cpus = @(Get-Processor $structures)
Assert-Equal 1 $cpus.Count 'finds the populated processor socket'
Assert-Equal 'ACME Ryzen 5 5600U' $cpus[0].Model 'reads the processor name from the firmware, not the registry'
Assert-Equal 6  $cpus[0].Cores      'reads core count from offset 0x23'
Assert-Equal 12 $cpus[0].Threads    'reads thread count from offset 0x25'
Assert-Equal 3600 $cpus[0].MaxSpeedMhz 'reads rated speed from offset 0x14'

$slots = @(Get-MemorySlots $structures)
Assert-Equal 2 $slots.Count 'reports every slot, filled or not'
Assert-Equal 8589934592 $slots[0].Bytes 'decodes an 8 GB module from the megabyte-encoded size field'
Assert-Equal 'DIMM A'   $slots[0].Slot  'reads the slot locator'
Assert-Equal 'DDR4'     $slots[0].Type  'maps memory type 0x1A to DDR4'
Assert-Equal 3200 $slots[0].ConfiguredMts 'reads configured speed from offset 0x20'
Assert-Equal 'MT40A1G8' $slots[0].PartNumber 'reads the part number'
Assert-True (-not $slots[1].Populated) 'reports an empty slot as empty'
Assert-Equal $null $slots[1].Manufacturer 'drops the OEM placeholder string rather than showing it'

Write-Host "`nFormatting" -ForegroundColor Cyan
Assert-Equal '512 GB'   (Format-Bytes 512110190592) 'formats a drive capacity'
Assert-Equal '8.6 GB'  (Format-Bytes 8589934592) 'formats a memory size'
Assert-Equal '2.4 years' (Format-Hours 21000) 'turns hours into years'
Assert-Equal '10 days'   (Format-Hours 240)   'turns hours into days'
Assert-Equal '12 hours'  (Format-Hours 12)    'leaves small hour counts alone'
$wrapped = @(Split-Wrapped ('word ' * 30) 40)
Assert-True ($wrapped.Count -gt 1) 'wraps long prose onto several lines'
Assert-Equal 0 @($wrapped | Where-Object { $_.Length -gt 40 }).Count 'and no line exceeds the requested column'
Assert-Equal 'word word word word word word word word' $wrapped[0] 'packing each line as full as it will go'

Write-Host "`nDrive judgement" -ForegroundColor Cyan
function New-Drive {
    param($Wear, $Hours, $Health = 'Healthy', $Read = 0, $Write = 0, $Locked = $false)
    [ordered]@{
        Model = 'EXAMPLE SSD'; SizeBytes = 512110190592; MediaType = 'SSD'; BusType = 'NVMe'
        Firmware = '1.0'; SerialNumber = 'x'; SelfAssessment = $Health
        Wear = $Wear; PowerOnHours = $Hours; TemperatureC = 34
        ReadErrors = $Read; WriteErrors = $Write; Locked = $Locked
    }
}

$script:Findings.Clear()
$v = Get-DriveVerdict (New-Drive 3 1200)
Assert-Equal 'Good' $v.Verdict 'a lightly used drive is Good'
Assert-Equal 97 $v.Percent 'life remaining is the inverse of wear'
Assert-Equal 0 $script:Findings.Count 'a healthy drive raises nothing'

$script:Findings.Clear()
$v = Get-DriveVerdict (New-Drive 94 40000)
Assert-Equal 'Poor' $v.Verdict 'a nearly worn drive is Poor'

$script:Findings.Clear()
$v = Get-DriveVerdict (New-Drive 75 30000)
Assert-Equal 'Fair' $v.Verdict 'a significantly worn drive is Fair'

$script:Findings.Clear()
$v = Get-DriveVerdict (New-Drive 2 500 'Unhealthy')
Assert-Equal 'Poor' $v.Verdict "a drive reporting its own failure is Poor whatever else it says"

$script:Findings.Clear()
$v = Get-DriveVerdict (New-Drive 40 12)
Assert-Equal 'Unknown' $v.Verdict 'heavy wear with almost no hours does not add up'
Assert-True ($script:Findings | Where-Object { $_.Title -match 'does not add up' }) 'and it is called out'

$script:Findings.Clear()
$v = Get-DriveVerdict (New-Drive 0 12)
Assert-Equal 'Good' $v.Verdict 'low hours on a genuinely new drive are not an accusation'
Assert-Equal 0 $script:Findings.Count 'and raise nothing'

$script:Findings.Clear()
$v = Get-DriveVerdict (New-Drive $null $null -Locked $true)
Assert-Equal 'Unknown' $v.Verdict 'a drive we were not allowed to read is Unknown, never Poor'

Write-Host "`nBattery judgement" -ForegroundColor Cyan
function New-Battery {
    param($Health, $Cycles)
    [ordered]@{
        Name = 'EXAMPLE PACK'; Manufacturer = 'ACME'; Chemistry = 'LION'
        DesignedmWh = 43000; CurrentmWh = if ($Health) { [int](43000 * $Health / 100) } else { 0 }
        HealthPercent = $Health; CycleCount = $Cycles
    }
}

$script:Findings.Clear()
Assert-Equal 'Good' (Get-BatteryVerdict (New-Battery 94 120)).Verdict 'a healthy pack is Good'
$script:Findings.Clear()
Assert-Equal 'Fair' (Get-BatteryVerdict (New-Battery 71 400)).Verdict 'a worn pack is Fair'
$script:Findings.Clear()
Assert-Equal 'Poor' (Get-BatteryVerdict (New-Battery 44 900)).Verdict 'a spent pack is Poor'

$script:Findings.Clear()
$v = Get-BatteryVerdict (New-Battery 100 766)
Assert-Equal 'Unknown' $v.Verdict 'perfect health after 766 cycles is not a measurement'
Assert-True ($script:Findings | Where-Object { $_.Title -match 'unreliable' }) 'and is explained as unreliable'

$script:Findings.Clear()
Assert-Equal 'Good' (Get-BatteryVerdict (New-Battery 100 12)).Verdict 'perfect health on a new pack is believed'

$script:Findings.Clear()
$v = Get-BatteryVerdict (New-Battery $null $null)
Assert-Equal 'Unknown' $v.Verdict 'a pack that will not answer is Unknown, never Poor'

Write-Host ''
if ($script:Fail -gt 0) {
    Write-Host "$script:Pass passed, $script:Fail FAILED" -ForegroundColor Red
    exit 1
}
Write-Host "$script:Pass passed, 0 failed" -ForegroundColor Green
