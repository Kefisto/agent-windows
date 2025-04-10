#
#	HetrixTools Server Monitoring Agent
#	Copyright 2015 - 2025 @  HetrixTools
#	For support, please open a ticket on our website https://hetrixtools.com
#
#
#		DISCLAIMER OF WARRANTY
#
#	The Software is provided "AS IS" and "WITH ALL FAULTS," without warranty of any kind, 
#	including without limitation the warranties of merchantability, fitness for a particular purpose and non-infringement. 
#	HetrixTools makes no warranty that the Software is free of defects or is suitable for any particular purpose. 
#	In no event shall HetrixTools be responsible for loss or damages arising from the installation or use of the Software, 
#	including but not limited to any indirect, punitive, special, incidental or consequential damages of any character including, 
#	without limitation, damages for loss of goodwill, work stoppage, computer failure or malfunction, or any and all other commercial damages or losses. 
#	The entire risk as to the quality and performance of the Software is borne by you, the user.
#
#		END OF DISCLAIMER OF WARRANTY

# Script path
$ScriptPath = Split-Path -Parent $MyInvocation.MyCommand.Path

# Agent Version (do not change)
$Version = "2.0.5"

# Load configuration file
$ConfigFile = "$ScriptPath\hetrixtools.cfg"

# Debug log
$debugLog = "$ScriptPath\debug.log"

# Script start time
$ScriptStartTime = Get-Date -Format '[yyyy-MM-dd HH:mm:ss]'

# Function to parse the configuration file
function Get-ConfigValue {
    param (
        [string]$Key
    )
    
    # Read the file and find the line containing the key
    $line = Get-Content $ConfigFile | Where-Object { $_ -match "^$Key=" }
    if ($line) {
        return $line.Split('=')[1].Trim().Trim('"', "'")
    } else {
        exit 1
    }
}

# Function to encode a string to base64
function Encode-Base64 {
    param (
        [string]$InputString
    )
    
    # Return an empty string if the input is null or empty
    if ([string]::IsNullOrEmpty($InputString)) {
        return ""
    }
    
    # Convert the string to bytes
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($InputString)
    
    # Convert the bytes to a base64 string
    $base64String = [Convert]::ToBase64String($bytes)
    
    return $base64String
}

function Check-ProcessOrService {
    param (
        [Parameter(Mandatory=$true)]
        [string]$Name
    )
	
	$Name = $Name -replace '\.exe$', ''
    
    # Check if the given name is a running process
    if (Get-Process -Name $Name -ErrorAction SilentlyContinue) {
        return 1
    }
    # If not a running process, check if it is a running service
    elseif (Get-Service -Name $Name -ErrorAction SilentlyContinue) {
        $service = Get-Service -Name $Name -ErrorAction SilentlyContinue
        if ($service.Status -eq 'Running') {
            return 1
        } else {
            return 0
        }
    } 
    # If neither a running process nor a running service
    else {
        return 0
    }
}

# Function to get localized performance counter names
function Get-LocalPerfCounterName {
    param (
        [Parameter(Mandatory=$true)]
        $Name
    )

    $key009 = 'Registry::HKEY_LOCAL_MACHINE\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Perflib\009'
    $counters009 = (Get-ItemProperty -Path $key009 -Name Counter).Counter.tolower()
    $index = $counters009.IndexOf($name.tolower())
    
    if ($index -eq -1) {
        $null   # not found
    }
    else {
        $idOfName = $counters009[$index - 1]
        $keylocal = 'Registry::HKEY_LOCAL_MACHINE\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Perflib\CurrentLanguage'
        $counterslocal = (Get-ItemProperty -Path $keylocal -Name Counter).Counter
        $indexOfLocalId = $counterslocal.IndexOf($idOfName)
        $counterslocal[$indexOfLocalId + 1]
    }
}

# Configs
$SID = Get-ConfigValue -Key "SID"
$CollectEveryXSeconds = Get-ConfigValue -Key "CollectEveryXSeconds"
$NetworkInterfaces = Get-ConfigValue -Key "NetworkInterfaces"
$CheckServices = Get-ConfigValue -Key "CheckServices"
$CheckDriveHealth = Get-ConfigValue -Key "CheckDriveHealth"
$DEBUG = Get-ConfigValue -Key "DEBUG"

if ($DEBUG -eq "1") {Add-Content -Path $debugLog -Value "$ScriptStartTime-$(Get-Date -Format '[yyyy-MM-dd HH:mm:ss]') Starting HetrixTools Agent v$Version"}

# If SID is empty, exit
if ([string]::IsNullOrEmpty($SID)) {
    Write-Host "SID is empty. Exiting..."
    if ($DEBUG -eq "1") {Add-Content -Path $debugLog -Value "$ScriptStartTime-$(Get-Date -Format '[yyyy-MM-dd HH:mm:ss]') SID is empty"}
    exit 1
}

# Start timers
$START = [datetime]::UtcNow
$tTIMEDIFF = 0

# Get current minute
$M = [int](Get-Date -Format 'mm')

# If minute is empty, set it to 0
if (-not $M) {
    $M = 0
}

# Clear debug log every day at midnight
if ((Get-Date).Hour -eq 0 -and (Get-Date).Minute -eq 0) {
    if (Test-Path $debugLog) {
        Remove-Item -Path $debugLog -Force
        if ($DEBUG -eq "1") {Add-Content -Path $debugLog -Value "$ScriptStartTime-$(Get-Date -Format '[yyyy-MM-dd HH:mm:ss]') Debug log cleared."}
    }
}

# Network interfaces
if (-not [string]::IsNullOrEmpty($NetworkInterfaces)) {
    # Use the network interfaces specified in settings
    $NetworkInterfacesArray = $NetworkInterfaces -split ','
} else {
    # Automatically detect the network interfaces
    $NetworkInterfacesArray = @()
    $activeInterfaces = Get-NetAdapter | Where-Object { $_.Status -eq 'Up' }
    foreach ($interface in $activeInterfaces) {
        $NetworkInterfacesArray += $interface.Name
    }
}

if ($DEBUG -eq "1") {Add-Content -Path $debugLog -Value "$ScriptStartTime-$(Get-Date -Format '[yyyy-MM-dd HH:mm:ss]') Network Interfaces: $($NetworkInterfacesArray -join ', ')"}

# Initial network usage
$networkStats = Get-NetAdapterStatistics
$aRX = @{}
$aTX = @{}

# Loop through network interfaces
foreach ($NIC in $NetworkInterfacesArray) {
     # Get the latest network stats for the NIC
    try {
        $adapterStats = $networkStats | Where-Object { $_.Name -eq $NIC }
        if ($adapterStats) {
            $aRX[$NIC] = $adapterStats.ReceivedBytes
            $aTX[$NIC] = $adapterStats.SentBytes
            if ($DEBUG -eq "1") {Add-Content -Path $debugLog -Value "$ScriptStartTime-$(Get-Date -Format '[yyyy-MM-dd HH:mm:ss]') Network Stats: $NIC - RX: $($aRX[$NIC]) - TX: $($aTX[$NIC])"}
        }
    } catch {
        # Ignore any errors for unavailable NICs
        if ($DEBUG -eq "1") {Add-Content -Path $debugLog -Value "$ScriptStartTime-$(Get-Date -Format '[yyyy-MM-dd HH:mm:ss]') Network Error: $NIC"}
    }
}

if ($DEBUG -eq "1") {Add-Content -Path $debugLog -Value "$ScriptStartTime-$(Get-Date -Format '[yyyy-MM-dd HH:mm:ss]') Network Stats: $($aRX -join ', ') - $($aTX -join ', ')"}

# Check processes/services
if (-not [string]::IsNullOrEmpty($CheckServices)) {
    $SRVCSR = @{}
    $CheckServicesArray = $CheckServices -split ','
    foreach ($serviceName in $CheckServicesArray) {
        $serviceStatus = Check-ProcessOrService -Name $serviceName
        if ($DEBUG -eq "1") {Add-Content -Path $debugLog -Value "$ScriptStartTime-$(Get-Date -Format '[yyyy-MM-dd HH:mm:ss]') Service: $serviceName - Status: $serviceStatus"}
        if ($SRVCSR.ContainsKey($serviceName)) {
            $SRVCSR[$serviceName] += $serviceStatus
        } else {
            $SRVCSR[$serviceName] = $serviceStatus
        }
    }
}

# Calculate how many data sample loops
$RunTimes = [math]::Floor(60 / $CollectEveryXSeconds)

if ($DEBUG -eq "1") {Add-Content -Path $debugLog -Value "$ScriptStartTime-$(Get-Date -Format '[yyyy-MM-dd HH:mm:ss]') RunTimes: $RunTimes"}

# Initialise values
$total_cpuUsage = 0
$total_diskTime = 0

# Determine localized names of CPU performance counters
$processorInformationName = Get-LocalPerfCounterName "Processor Information"
$processorUtilityName = Get-LocalPerfCounterName "% Processor Utility"

# Determine localized names of Disk performance counters
$physicalDiskName = Get-LocalPerfCounterName "PhysicalDisk"
$diskTimeName = Get-LocalPerfCounterName "% Disk Time"

# Collect data loop
for ($X = 1; $X -le $RunTimes; $X++) {
    if ($DEBUG -eq "1") {Add-Content -Path $debugLog -Value "$ScriptStartTime-$(Get-Date -Format '[yyyy-MM-dd HH:mm:ss]') Start Loop: $X"}
    # Start both commands as jobs
    $cpuJob = Start-Job -ScriptBlock { 
        $cpuCounter = Get-Counter "\$using:processorInformationName(_Total)\$using:processorUtilityName" -SampleInterval $using:CollectEveryXSeconds
        return $cpuCounter.CounterSamples.CookedValue
    }

    $diskJob = Start-Job -ScriptBlock { 
        $diskCounter = Get-Counter "\$using:physicalDiskName(_Total)\$using:diskTimeName" -SampleInterval $using:CollectEveryXSeconds
        return $diskCounter.CounterSamples.CookedValue
    }

    # Wait for both jobs to complete
    $cpuJob | Wait-Job
    $diskJob | Wait-Job

    # Retrieve results and process them
    $cpuUsage = Receive-Job -Job $cpuJob
    $diskTime = Receive-Job -Job $diskJob

    if ($DEBUG -eq "1") {Add-Content -Path $debugLog -Value "$ScriptStartTime-$(Get-Date -Format '[yyyy-MM-dd HH:mm:ss]') CPU Usage: $cpuUsage - Disk Time: $diskTime"}

    # Add up the results
    $total_cpuUsage += [math]::Round($cpuUsage, 2)
    $total_diskTime += [math]::Round($diskTime, 2)

    # Clean up jobs
    Remove-Job -Job $cpuJob
    Remove-Job -Job $diskJob

    # Check if the minute has changed, so we can end the loop
    $MM = [int](Get-Date -Format 'mm')

    # If minute is empty or zero, set it to 0
    if (-not $MM) {
        $MM = 0
    }

    # Compare the current minute with the initial minute ($M)
    if ($MM -ne $M) {
        if ($DEBUG -eq "1") {Add-Content -Path $debugLog -Value "$ScriptStartTime-$(Get-Date -Format '[yyyy-MM-dd HH:mm:ss]') Break Loop: $X"}
        break
    }
    if ($DEBUG -eq "1") {Add-Content -Path $debugLog -Value "$ScriptStartTime-$(Get-Date -Format '[yyyy-MM-dd HH:mm:ss]') End Loop: $X"}
}

# Get Win32_OperatingSystem
$Win32_OperatingSystem = Get-CimInstance -ClassName Win32_OperatingSystem

# Get the OS name
$osName = $Win32_OperatingSystem.Caption
if ($DEBUG -eq "1") {Add-Content -Path $debugLog -Value "$ScriptStartTime-$(Get-Date -Format '[yyyy-MM-dd HH:mm:ss]') OS Name: $osName"}
$osName = Encode-Base64 -InputString $osName

# Get the OS version
$osVersion = $Win32_OperatingSystem.Version
$buildLabEx = (Get-ItemProperty -Path "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion").BuildLabEx
if ($buildLabEx) {
    $osVersion += ",$buildLabEx"
}
if ($DEBUG -eq "1") {Add-Content -Path $debugLog -Value "$ScriptStartTime-$(Get-Date -Format '[yyyy-MM-dd HH:mm:ss]') OS Version: $osVersion"}
$osVersion = Encode-Base64 -InputString $osVersion

# Get the hostname
$hostname = $env:COMPUTERNAME
if ($DEBUG -eq "1") {Add-Content -Path $debugLog -Value "$ScriptStartTime-$(Get-Date -Format '[yyyy-MM-dd HH:mm:ss]') Hostname: $hostname"}
$hostname = Encode-Base64 -InputString $hostname

# Get current time
$time = Get-Date -Format "yyyy-MM-dd HH:mm:ss zzz"
if ($DEBUG -eq "1") {Add-Content -Path $debugLog -Value "$ScriptStartTime-$(Get-Date -Format '[yyyy-MM-dd HH:mm:ss]') Time: $time"}
$time = Encode-Base64 -InputString $time

# Get Reboot Required
$needsRestart = "0"
if (Test-Path "Rental: "3")
    $needsRestart = "1"
}
if ($DEBUG -eq "1") {Add-Content -Path $debugLog -Value "$ScriptStartTime-$(Get-Date -Format '[yyyy-MM-dd HH:mm:ss]') Reboot Required: $needsRestart"}

# Get the system uptime
$uptime = $Win32_OperatingSystem.LastBootUpTime
$uptime = [math]::Round((New-TimeSpan -Start $uptime -End (Get-Date)).TotalSeconds, 0)
if ($DEBUG -eq "1") {Add-Content -Path $debugLog -Value "$ScriptStartTime-$(Get-Date -Format '[yyyy-MM-dd HH:mm:ss]') Uptime: $uptime"}

# Get the CPU information
$sysInfo = Get-CimInstance -ClassName Win32_Processor

# Get the CPU model
$cpuModel = $sysInfo[0].Name
if ($DEBUG -eq "1") {Add-Content -Path $debugLog -Value "$ScriptStartTime-$(Get-Date -Format '[yyyy-MM-dd HH:mm:ss]') CPU Model: $cpuModel"}
$cpuModel = Encode-Base64 -InputString $cpuModel

# Get the CPU sockets
$cpuSockets = ($sysInfo | Measure-Object).Count
if ($DEBUG -eq "1") {Add-Content -Path $debugLog -Value "$ScriptStartTime-$(Get-Date -Format '[yyyy-MM-dd HH:mm:ss]') CPU Sockets: $cpuSockets"}

# Get the number of CPU cores
$cpuCores = $sysInfo.NumberOfCores
if ($DEBUG -eq "1") {Add-Content -Path $debugLog -Value "$ScriptStartTime-$(Get-Date -Format '[yyyy-MM-dd HH:mm:ss]') CPU Cores: $cpuCores"}

# Get the number of CPU threads
$cpuThreads = $sysInfo.NumberOfLogicalProcessors
if ($DEBUG -eq "1") {Add-Content -Path $debugLog -Value "$ScriptStartTime-$(Get-Date -Format '[yyyy-MM-dd HH:mm:ss]') CPU Threads: $cpuThreads"}

# Get the CPU Frequency
$cpuFreq = [math]::Round(($sysInfo | Measure-Object -Property CurrentClockSpeed -Average).Average)
if ($DEBUG -eq "1") {Add-Content -Path $debugLog -Value "$ScriptStartTime-$(Get-Date -Format '[yyyy-MM-dd HH:mm:ss]') CPU Frequency: $cpuFreq"}

# Calculate CPU Usage
$cpuUsage = [math]::Round($total_cpuUsage / $X, 2)
if ($DEBUG -eq "1") {Add-Content -Path $debugLog -Value "$ScriptStartTime-$(Get-Date -Format '[yyyy-MM-dd HH:mm:ss]') CPU Usage: $cpuUsage"}

# Get the disk I/O wait time
$diskTime = [math]::Round($total_diskTime / $X, 2)
if ($DEBUG -eq "1") {Add-Content -Path $debugLog -Value "$ScriptStartTime-$(Get-Date -Format '[yyyy-MM-dd HH:mm:ss]') Disk Time: $diskTime"}

# Get the total RAM
$totalMemory = $Win32_OperatingSystem.TotalVisibleMemorySize * 1024
if ($DEBUG -eq "1") {Add-Content -Path $debugLog -Value "$ScriptStartTime-$(Get-Date -Format '[yyyy-MM-dd HH:mm:ss]') Total Memory: $totalMemory"}

# Get the free RAM
$freeMemory = $Win32_OperatingSystem.FreePhysicalMemory * 1024
if ($DEBUG -eq "1") {Add-Content -Path $debugLog -Value "$ScriptStartTime-$(Get-Date -Format '[yyyy-MM-dd HH:mm:ss]') Free Memory: $freeMemory"}

# Calculate used memory
$usedMemory = $totalMemory - $freeMemory
$usedMemory = [math]::Round(($usedMemory / $totalMemory) * 100, 2)
if ($DEBUG -eq "1") {Add-Content -Path $debugLog -Value "$ScriptStartTime-$(Get-Date -Format '[yyyy-MM-dd HH:mm:ss]') Used Memory: $usedMemory"}

# Get swap (paging file) information
$swapInfo = Get-CimInstance -ClassName Win32_PageFileUsage

# Get the total swap size
$totalSwapSize = ($swapInfo | Measure-Object -Property AllocatedBaseSize -Sum).Sum * 1024 * 1024
if ($DEBUG -eq "1") {Add-Content -Path $debugLog -Value "$ScriptStartTime-$(Get-Date -Format '[yyyy-MM-dd HH:mm:ss]') Total Swap Size: $totalSwapSize"}

# Get the used swap size
$usedSwapSize = ($swapInfo | Measure-Object -Property CurrentUsage -Sum).Sum * 1024 * 1024
if ($DEBUG -eq "1") {Add-Content -Path $debugLog -Value "$ScriptStartTime-$(Get-Date -Format '[yyyy-MM-dd HH:mm:ss]') Used Swap Size: $usedSwapSize"}

# Calculate swap usage percentage
if($totalSwapSize -and $usedSwapSize -and ($totalSwapSize -is [int] -or $totalSwapSize -is [double]) -and ($usedSwapSize -is [int] -or $usedSwapSize -is [double])) {
    $swapUsage = [math]::Round(($usedSwapSize / $totalSwapSize) * 100, 2)
} else {
    $swapUsage = 0
}
if ($DEBUG -eq "1") {Add-Content -Path $debugLog -Value "$ScriptStartTime-$(Get-Date -Format '[yyyy-MM-dd HH:mm:ss]') Swap Usage: $swapUsage"}

# Get disk information and usage details
$disksInfo = Get-CimInstance -ClassName Win32_LogicalDisk | Where-Object { $_.DriveType -eq 3 }
$allDiskData = @()
foreach ($disk in $disksInfo) {
    try {
        $diskUsage = Get-PSDrive -Name $disk.DeviceID.Substring(0,1)
        $totalSize = $disk.Size
        $usedSize = $disk.Size - $disk.FreeSpace

        # Format and add the disk data
        $diskData = "$($disk.DeviceID),$($totalSize),$($usedSize),$($disk.FreeSpace)"
        $allDiskData += $diskData
        if ($DEBUG -eq "1") {Add-Content -Path $debugLog -Value "$ScriptStartTime-$(Get-Date -Format '[yyyy-MM-dd HH:mm:ss]') Disk Data: $diskData"}
    } catch {
        # Ignore any errors for unavailable disks
        if ($DEBUG -eq "1") {Add-Content -Path $debugLog -Value "$ScriptStartTime-$(Get-Date -Format '[yyyy-MM-dd HH:mm:ss]') Disk Error: $disk"}
    }
}

# Join all disk data into a single string
$disks = ($allDiskData -join ';') + ';'
if ($DEBUG -eq "1") {Add-Content -Path $debugLog -Value "$ScriptStartTime-$(Get-Date -Format '[yyyy-MM-dd HH:mm:ss]') Disks: $disks"}
$disks = Encode-Base64 -InputString $disks

# Disk Health
$DH = ""
if ($CheckDriveHealth -eq "1") {
    $CheckDriveHealth = Get-PhysicalDisk
    foreach ($disk in $CheckDriveHealth) {
        $wearLevel = 0
        $powerCycleCount = 0
        $powerOnHours = 0
        $unsafeShutdownCount = 0
        $writeErrorsTotal = 0
        $writeErrorsCorrected = 0
        $writeErrorsUncorrected = 0
        $temperature = 0
        try {
            $reliabilityData = Get-StorageReliabilityCounter -PhysicalDisk $disk
            if ($DEBUG -eq "1") {Add-Content -Path $debugLog -Value "$ScriptStartTime-$(Get-Date -Format '[yyyy-MM-dd HH:mm:ss]') Disk Health: $($disk.DeviceID) - $($reliabilityData.Wear) - $($reliabilityData.PowerCycleCount) - $($reliabilityData.PowerOnHours) - $($reliabilityData.StartStopCycleCount) - $($reliabilityData.WriteErrorsTotal) - $($reliabilityData.WriteErrorsCorrected) - $($reliabilityData.WriteErrorsUncorrected) - $($reliabilityData.Temperature)"}
            if ($reliabilityData) {
                $wearLevel = $reliabilityData.Wear
                $powerCycleCount = $reliabilityData.PowerCycleCount
                $powerOnHours = $reliabilityData.PowerOnHours
                $unsafeShutdownCount = $reliabilityData.StartStopCycleCount
                $writeErrorsTotal = $reliabilityData.WriteErrorsTotal
                $writeErrorsCorrected = $reliabilityData.WriteErrorsCorrected
                $writeErrorsUncorrected = $reliabilityData.WriteErrorsUncorrected
                $temperature = $reliabilityData.Temperature
            }
        } catch {
            # Ignore any errors for unavailable disks
            if ($DEBUG -eq "1") {Add-Content -Path $debugLog -Value "$ScriptStartTime-$(Get-Date -Format '[yyyy-MM-dd HH:mm:ss]') Disk Health Error: $disk"}
        }
        $DH += "$($disk.DeviceID),$($disk.MediaType),$($disk.FriendlyName),$($disk.SerialNumber),$($disk.OperationalStatus),$($disk.HealthStatus),$wearLevel,$powerCycleCount,$powerOnHours,$unsafeShutdownCount,$writeErrorsTotal,$writeErrorsCorrected,$writeErrorsUncorrected,$temperature;"
    }
    $DH = Encode-Base64 -InputString $DH
}

# Total network usage and IP addresses
$RX = 0
$TX = 0
$NICS = ""
$IPv4 = ""
$IPv6 = ""
$tTIMEDIFF = ([datetime]::UtcNow - $START).TotalSeconds
# Loop through network interfaces
foreach ($NIC in $NetworkInterfacesArray) {
    # Get the latest network stats for the NIC
    try {
        $adapterStats = Get-NetAdapterStatistics | Where-Object { $_.Name -eq $NIC }

        if ($DEBUG -eq "1") {Add-Content -Path $debugLog -Value "$ScriptStartTime-$(Get-Date -Format '[yyyy-MM-dd HH:mm:ss]') Network Stats: $NIC - RX: $($adapterStats.ReceivedBytes) - TX: $($adapterStats.SentBytes)"}

        # Check if the adapter stats were retrieved successfully
        if ($adapterStats) {
            # Calculate Received Traffic
            $rxDiff = $adapterStats.ReceivedBytes - $aRX[$NIC]
            $RX = [math]::Round($rxDiff / $tTIMEDIFF, 0)

            # Calculate Transferred Traffic
            $txDiff = $adapterStats.SentBytes - $aTX[$NIC]
            $TX = [math]::Round($txDiff / $tTIMEDIFF, 0)

            # Add the RX and TX values to the string
            $NICS += "$NIC,$RX,$TX;"

            # Individual NIC IP addresses
            $ipv4Addresses = (Get-NetIPAddress -InterfaceAlias $NIC -AddressFamily IPv4).IPAddress -join ","
            if (Get-NetAdapter -Name $NIC -ErrorAction SilentlyContinue) {
                $ipv6Addresses = (Get-NetIPAddress -InterfaceAlias $NIC -AddressFamily IPv6 -ErrorAction SilentlyContinue | Where-Object {
                    $_.IPAddress -notmatch '^fe80::'
                }).IPAddress -join ","
                if (!$ipv6Addresses) {
                    $ipv6Addresses = ""
                }
            } else {
                $ipv6Addresses = ""
            }
            $IPv4 += "$NIC,$ipv4Addresses;"
            $IPv6 += "$NIC,$ipv6Addresses;"
            if ($DEBUG -eq "1") {Add-Content -Path $debugLog -Value "$ScriptStartTime-$(Get-Date -Format '[yyyy-MM-dd HH:mm:ss]') Network Stats: $NIC - RX: $RX - TX: $TX - IPv4: $ipv4Addresses - IPv6: $ipv6Addresses"}
        }
    } catch {
        # Ignore any errors for unavailable NICs
        if ($DEBUG -eq "1") {Add-Content -Path $debugLog -Value "$ScriptStartTime-$(Get-Date -Format '[yyyy-MM-dd HH:mm:ss]') Network Error: $NIC"}
    }
}
$NICS = Encode-Base64 -InputString $NICS
$IPv4 = Encode-Base64 -InputString $IPv4
$IPv6 = Encode-Base64 -InputString $IPv6

# Check processes/services
$SRVCS = ""
if (-not [string]::IsNullOrEmpty($CheckServices)) {
    foreach ($serviceName in $CheckServicesArray) {
        $serviceStatus = Check-ProcessOrService -Name $serviceName
        if ($SRVCSR.ContainsKey($serviceName)) {
            $SRVCSR[$serviceName] += $serviceStatus
        } else {
            $SRVCSR[$serviceName] = $serviceStatus
        }
        # Append to the SRVCS string based on the status
        if ($SRVCSR[$serviceName] -eq 0) {
            $SRVCS += "$serviceName,0;"
        } else {
            $SRVCS += "$serviceName,1;"
        }
    }
}
if ($DEBUG -eq "1") {Add-Content -Path $debugLog -Value "$ScriptStartTime-$(Get-Date -Format '[yyyy-MM-dd HH:mm:ss]') Services: $SRVCS"}
$SRVCS = Encode-Base64 -InputString $SRVCS

# Create a custom object with all the data
$Data = [PSCustomObject]@{
    version = $Version
    SID = $SID
    os = $osName
    kernel = $osVersion
    hostname = $hostname
    time = $time
    reqreboot = $needsRestart
    uptime = $uptime
    cpumodel = $cpuModel
    cpusockets = $cpuSockets
    cpucores = $cpuCores
    cputhreads = $cpuThreads
    cpuspeed = $cpuFreq
    cpu = $cpuUsage
    wa = $diskTime
    ramsize = $totalMemory
    ram = $usedMemory
    ramswapsize = $totalSwapSize
    ramswap = $swapUsage
    disks = $disks
    nics = $NICS
    ipv4 = $IPv4
    ipv6 = $IPv6
    serv = $SRVCS
    dh = $DH
}

# Convert the custom object to JSON
$Data = $Data | ConvertTo-Json
if ($DEBUG -eq "1") {Add-Content -Path $debugLog -Value "$ScriptStartTime-$(Get-Date -Format '[yyyy-MM-dd HH:mm:ss]') Data: $Data"}

# Send the data
$APIURL = "https://sm.hetrixtools.net/win/"
$Headers = @{
    'Content-Type' = 'application/json'
}
$MaxRetries = 3
$Timeout = 15
$RetryCount = 0
$Success = $false
while ($RetryCount -lt $MaxRetries -and -not $Success) {
    try {
        $startTime = Get-Date
        $Response = Invoke-RestMethod -Uri $APIURL -Method Post -Headers $Headers -Body $Data -TimeoutSec $Timeout
        $endTime = Get-Date
        $responseTime = [math]::Round(($endTime - $startTime).TotalMilliseconds, 0)
        if ($DEBUG -eq "1") {Add-Content -Path $debugLog -Value "$ScriptStartTime-$(Get-Date -Format '[yyyy-MM-dd HH:mm:ss]') Response: $Response | Status: 200 | Time: ${responseTime}ms"}
        $Success = $true
    } catch {
        $errorMessage = "Exception: $($_.Exception.Message)"
        $statusCode = $null
        if ($_.Exception.Response) {
            $statusCode = [int]$_.Exception.Response.StatusCode
            $errorMessage += " | Status Code: $statusCode"
        }
        if ($_.Exception.InnerException) {
            $errorMessage += " | Inner Exception: $($_.Exception.InnerException.Message)"
        }
        if ($DEBUG -eq "1") {Add-Content -Path $debugLog -Value "$ScriptStartTime-$(Get-Date -Format '[yyyy-MM-dd HH:mm:ss]') Error: $errorMessage | Attempt: $($RetryCount + 1) of $MaxRetries"}
        $RetryCount++
        if ($RetryCount -ne $MaxRetries) {
            Start-Sleep -Seconds 1
        }
    }
}
