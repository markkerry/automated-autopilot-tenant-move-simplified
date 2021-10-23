<#
.Synopsis
    Script to migrate a device to a new tenant.
.DESCRIPTION
    First will copy the AutopilotConfigurationFile.json for the new tenant to the machine,
    then will connect to MS Graph and delete the managed device and Autopilot registration.
    Finally the machine will wipe.
.EXAMPLE
    .\Invoke-AutopilotTenantMove.ps1
.NOTES
    Code for post tbc...
#>

# Ensure the log destination exists
if (!(Test-Path -Path "C:\Users\Public\Documents\IntuneDetectionLogs")) {
    New-Item -Path "C:\Users\Public\Documents" -Name "IntuneDetectionLogs" -ItemType Directory | Out-Null
}

# Create the Write-LogEntry function
function Write-LogEntry {
    param(
        [parameter(Mandatory=$true)]
        [ValidateNotNullOrEmpty()]
        [string]$Value,

        [parameter(Mandatory=$false)]
        [ValidateNotNullOrEmpty()]
        [string]$FileName = "AutopilotTenantMove.log"
    )
    # Determine log file location
    $LogFilePath = Join-Path -Path "C:\Users\Public\Documents" -ChildPath "IntuneDetectionLogs\$($FileName)"

    Write-Host "$Value"

    # Add value to log file
    try {
        Out-File -InputObject $Value -Append -NoClobber -Encoding Default -FilePath $LogFilePath -ErrorAction Stop
    }
    catch [System.Exception] {
        Write-Warning -Message "Unable to append log entry to $FileName file"
        exit 1
    }
}

function Clear-IntuneLog {
    param (
        [string]$string
    )
    
    $intuneLogPath = "$env:ProgramData\Microsoft\IntuneManagementExtension\Logs\IntuneManagementExtension.log"
    if (test-Path -Path $intuneLogPath) {
        try {
            Write-LogEntry -Value "$(Get-Date -format g): Clearing the Intune Log file: $intuneLogPath"
            Set-Content -Path $intuneLogPath -Value (Get-Content -Path $intuneLogPath | Select-String -Pattern $string -notmatch)
        }
        catch {
            Write-LogEntry -Value "$(Get-Date -format g): Failed to clear the Intune Log file"
        }
    }
}

# Function to silently reset Windows
function Reset-OperatingSystem {
    $namespaceName = "root\cimv2\mdm\dmmap"
    $className = "MDM_RemoteWipe"
    $methodName = "doWipeMethod"

    $session = New-CimSession

    $params = New-Object Microsoft.Management.Infrastructure.CimMethodParametersCollection
    $param = [Microsoft.Management.Infrastructure.CimMethodParameter]::Create("param", "", "String", "In")
    $params.Add($param)

    try {
        $instance = Get-CimInstance -Namespace $namespaceName -ClassName $className -Filter "ParentID='./Vendor/MSFT' and InstanceID='RemoteWipe'"
        $session.InvokeMethod($namespaceName, $instance, $methodName, $params)
    }
    catch [Exception] {
        write-host $_ | out-string
        exit 1
    }
}

function Get-AuthHeader {
    param (
        [Parameter(mandatory = $true)]
        [string]$TenantId,
        [Parameter(mandatory = $true)]
        [string]$ClientId,
        [Parameter(mandatory = $true)]
        [string]$ClientSecret,
        [Parameter(mandatory = $true)]
        [string]$ResourceUrl
    )
    $body = @{
        resource      = $ResourceUrl
        client_id     = $ClientId
        client_secret = $ClientSecret
        grant_type    = "client_credentials"
        scope         = "openid"
    }
    try {
        $response = Invoke-RestMethod -Method post -Uri "https://login.microsoftonline.com/$TenantId/oauth2/token" -Body $body -ErrorAction Stop
        $headers = @{ "Authorization" = "Bearer $($response.access_token)" }
        return $headers
    }
    catch {
        Write-Error $_.Exception
        exit 1
    }
}

function Invoke-GraphCall {
    [cmdletbinding()]
    param (
        [parameter(Mandatory = $false)]
        [ValidateSet('Get', 'Post', 'Delete')]
        [string]$Method = 'Get',

        [parameter(Mandatory = $false)]
        [hashtable]$Headers = $script:authHeader,

        [parameter(Mandatory = $true)]
        [string]$Uri,

        [parameter(Mandatory = $false)]
        [string]$ContentType = 'Application/Json',

        [parameter(Mandatory = $false)]
        [hashtable]$Body
    )
    try {
        $params = @{
            Method      = $Method
            Headers     = $Headers
            Uri         = $Uri
            ContentType = $ContentType
        }
        if ($Body) {
            $params.Body = $Body | ConvertTo-Json -Depth 20
        }
        $query = Invoke-RestMethod @params
        return $query
    }
    catch {
        Write-Warning $_.Exception.Message
        exit 1
    }
}

# Copy the AutopilotConfigurationFile.json
$config = "AutopilotConfigurationFile.json"
$configDest = "C:\Windows\Provisioning\Autopilot"
Write-LogEntry -Value "$(Get-Date -format g): Checking all files are in-place"
if (!(Test-Path $PSScriptRoot\$config)) {
    Write-LogEntry -Value "$(Get-Date -format g): Autpilot configuration file not found in - $PSScriptRoot"
    exit 1
}

Write-LogEntry -Value "$(Get-Date -format g): Autpilot configuration file found in - $PSScriptRoot"
Write-LogEntry -Value "$(Get-Date -format g): Copying to $configDest"
try {
    Copy-Item -Path $PSScriptRoot\$config -Destination $configDest -Force -ErrorAction Stop
}
catch {
    Write-LogEntry -Value "$(Get-Date -format g): Failed to copy Autopilot config to $configDest"
    exit 1
}

# Connect to Graph
$clientSecret = ''
$clientID = ''
$tenantID = ''
$deviceName = $env:COMPUTERNAME

Write-LogEntry -Value "$(Get-Date -format g): Authenticating to MS Grpah"

# authentication
$params = @{
    TenantId     = $tenantID
    ClientId     = $clientID
    ClientSecret = $clientSecret
    ResourceUrl  = "https://graph.microsoft.com"
}
$script:authHeader = Get-AuthHeader @params

Write-LogEntry -Value "$(Get-Date -format g): Retrieving Intune managed device record/s..."

$graphUri = "https://graph.microsoft.com/Beta/deviceManagement/managedDevices?`$filter=deviceName eq '$($deviceName)'"
$managedDevice = Invoke-GraphCall -Uri $graphUri

# Delete the intune managed device. Ensure there is only one found
if ($managedDevice.'@odata.count' -eq 1) {
    Write-LogEntry -Value "$(Get-Date -format g):   Deleting Intune Managed Device..."
    Write-LogEntry -Value "$(Get-Date -format g):     Device Name: $($managedDevice.value.deviceName)"
    Write-LogEntry -Value "$(Get-Date -format g):     Intune Device ID: $($managedDevice.value.Id)"
    Write-LogEntry -Value "$(Get-Date -format g):     Azure Device ID: $($managedDevice.value.azureADDeviceId)"
    Write-LogEntry -Value "$(Get-Date -format g):     Serial Number: $($managedDevice.value.serialNumber)"

    $graphUri = "https://graph.microsoft.com/v1.0/deviceManagement/managedDevices/$($managedDevice.value.Id)"
    Invoke-GraphCall -Uri $graphUri -Method Delete
    Start-Sleep -Seconds 3
}
elseif ($managedDevice.'@odata.count' -eq 0) {
    Write-LogEntry -Value "$(Get-Date -format g): Intune managed device for $deviceName not found"
    exit 1
}
else {
    Write-LogEntry -Value "$(Get-Date -format g): Too many devices discovered with the same name of $deviceName"
    exit 1
}

# Delete Autopilot device
Write-LogEntry -Value "$(Get-Date -format g): Retrieving Autopilot device registration..."

# delete Autopilot registered device
$graphUri = "https://graph.microsoft.com/beta/deviceManagement/windowsAutopilotDeviceIdentities?`$filter=contains(serialNumber,'$($managedDevice.value.serialNumber)')"
$query = Invoke-GraphCall -Uri $graphUri

if ($query.'@odata.count' -eq 1) {
    Write-LogEntry -Value "$(Get-Date -format g):   Deleting Autopilot Registration..."
    Write-LogEntry -Value "$(Get-Date -format g):     SerialNumber: $($query.value.serialNumber)"
    Write-LogEntry -Value "$(Get-Date -format g):     Model: $($query.value.model)"
    Write-LogEntry -Value "$(Get-Date -format g):     Id: $($query.value.id)"
    Write-LogEntry -Value "$(Get-Date -format g):     ManagedDeviceId: $($query.value.managedDeviceId)"

    $graphUri = "https://graph.microsoft.com/beta/deviceManagement/windowsAutopilotDeviceIdentities/$($query.value.Id)"
    Invoke-GraphCall -Uri $graphUri -Method Delete
    Start-Sleep -Seconds 3

    # Sync the Autopilot service
    Write-LogEntry -Value "$(Get-Date -format g): Synchronising the Autopilot registration service"
    $graphUri = "https://graph.microsoft.com/beta/deviceManagement/windowsAutopilotSettings/sync"
    Invoke-GraphCall -Uri $graphUri -Method Post
}
else {
    Write-LogEntry -Value "$(Get-Date -format g): Device with serial number $($managedDevice.value.serialNumber) not found as being registered in tenant"
}

# Clear the Intune Management Log
Clear-IntuneLog -string "ClientSecret"

# Reset the OS
Write-LogEntry -Value "$(Get-Date -format g): Resetting Windows"
Reset-OperatingSystem