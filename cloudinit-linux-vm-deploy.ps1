<#
.SYNOPSIS
  Automated vSphere Linux VM deployment using cloud-init seed ISO.
  Version: 0.1.8

.DESCRIPTION
  Automate deployment of a Linux VM from template VM, leveraging cloud-init, in 4 phases:
    (1) Automatic Cloning
    (2) Clone Initialization
    (3) Seed ISO Creation & Cloud-init KickStart
    (4) Cleanup and Finalization (detach seed ISO, remove ISO on DataStore, and disable cloud-init)
  Most parameters for unique deployment are centralized in a parameter file (vm-settings_*.yaml).

  **Requirements:**
  * vSphere virtual machine environment (8+ recommended)
  * VMware PowerCLI
  * powershell-yaml module
  * mkisofs: ISO creator command; If you use an alternative, adjust global $mkisofs and 
    Phase-3 specific $mkArgs in the script.

  **Exit codes:**
    0: Success
    1: General runtime error (VM operations, PowerCLI, etc)
    2: System/environment/file error (directory/file creation, etc)
    3: Bad arguments or parameter/config input

.PARAMETER Phase
  (Alias -p) List of steps (1,2,3,4) to execute, e.g. '-p 1,2,3', '-Phase 3'.
  Non-contiguous lists (e.g., `-Phase 1,3`) are rejected.

.PARAMETER Config
  (Alias -c) Path to parameter YAML file for the VM deployment.

.PARAMETER DiskOnly
  Set this when you want to reapply cloud-init exclusively for disk size expansion on the 
  VM previously deployed with this kit. Before run you must:
  * Extend the desired VMDKs of the VM on vSphere
  * Copy templates/original/user-data_diskonly_template.yaml to templates/ if missing.
  * Make a copy of params/vm-settings_reapply_diskonly_example.yaml and edit it.
  * Run Phase 2, 3 and 4 with '-DiskOnly' passing the parameter file above by '-Config'.
  Refer to README for more information.

.PARAMETER NoRestart
  If set, automatic power-on/shutdown are disabled, except when multi-phase run is requested.
  In certain cases where the logic cannot be satisfied without a power-on/shutdown, user will 
  be prompted for confirmation.

.PARAMETER NoCloudReset
  (Alias -noreset) If set, disables creation of /etc/cloud/cloud-init.disabled in Phase 4.
  ISO detachment and ISO file removal are always performed.

.EXAMPLE
  .\cloudinit-linux-vm-deploy.ps1 -Phase 1,2,3 -Config .\params\vm-settings_myvm01.yaml
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [ValidateSet(1,2,3,4)]
    [Alias("p")]
    [int[]]$Phase,

    [Parameter(Mandatory)]
    [Alias("c")]
    [string]$Config,

    [Parameter()]
    [switch]$DiskOnly,

    [Parameter()]
    [switch]$NoRestart,

    [Parameter()]
    [Alias("noreset")]
    [switch]$NoCloudReset
)

#
# ---- Global variables ----
#
$scriptdir = Split-Path -Path $MyInvocation.MyCommand.Path -Parent
$spooldir = Join-Path $scriptdir "spool"

$mkisofs = "C:\work\cdrtfe\tools\cdrtools\mkisofs.exe"
$seedIsoName = "cloudinit-linux-seed.iso"
$workDirOnVM = "/run/cloudinit-vm-deploy"

# vCenter connection variables
$vcport = 443
$connRetry = 2
$connRetryInterval = 5

if (-not (Test-Path $spooldir)) {
    Write-Host "Error: $spooldir does not exist. Please create it before running this script." -ForegroundColor Red
    Exit 2
}

if (-Not (Get-Module VMware.VimAutomation.Core)) {
    Write-Host "Loading vSphere PowerCLI. This may take a while..."
    Import-Module VMware.VimAutomation.Core -ErrorAction SilentlyContinue
}

Import-Module powershell-yaml -ErrorAction Stop

# ---- Phase argument check ----
$phaseSorted = $Phase | Sort-Object
for ($i=1; $i -lt $phaseSorted.Count; $i++) {
    if ($phaseSorted[$i] -ne $phaseSorted[$i-1] + 1) {
        Write-Host "Error: Invalid -Phase sequence (missing phase between $($phaseSorted[$i-1]) and $($phaseSorted[$i]))." -ForegroundColor Red
        Exit 3
    }
}

# ---- Resolve collision between NoRestart and multi-phase execution ----
if ($phaseSorted.Count -gt 1 -and $NoRestart) {
    Write-Host "Warning: Both multiple phases and -NoRestart are specified." -ForegroundColor Yellow
    Write-Host "Automatic power on/off is required for multi-phase execution."
    $resp = Read-Host "Proceed and ignore -NoRestart? (y/[N])"
    if ($resp -ne "y" -and $resp -ne "Y") {
        Write-Host "Operation cancelled by user."
        Exit 3
    }
    Write-Log -Warn "-NoRestart ignored due to multi-phase execution (user confirmed)"
    $NoRestart = $false
}

# LogFilePath (temporary)
$LogFilePath = Join-Path $spooldir "deploy.log"

function Write-Log {
    param(
        [string]$Message,
        [switch]$Error,
        [switch]$Warn
    )
    $Timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    "$Timestamp - $Message" | Out-File -Append -FilePath $LogFilePath -Encoding UTF8

    if ($Error) {
        Write-Host $Message -ForegroundColor Red
    } elseif ($Warn) {
        Write-Host $Message -ForegroundColor Yellow
    } else {
        Write-Host $Message
    }
}

function ConvertToSecureStringFromPlain {
    param(
        [Parameter()]
        [string]$PlainText
    )

    if (-not $PlainText -or $PlainText.Trim().Length -eq 0) {
        Write-Verbose "ConvertToSecureStringFromPlain: no password supplied."
        return $null
    }

    try {
        $secure = $PlainText | ConvertTo-SecureString -AsPlainText -Force -ErrorAction Stop
        return $secure
    } catch {
        Write-Log -Error "ConvertToSecureStringFromPlain: ConvertTo-SecureString failed: $_"
        return $null
    }
}

function VIConnect {
    # expects $vcserver, $vcuser, $vcpasswd in global scope
    process {
        for ($i = 1; $i -le $connRetry; $i++) {
            try {
                if ([string]::IsNullOrEmpty($vcuser) -or [string]::IsNullOrEmpty($vcpasswd)) {
                    Write-Log "Connect-VIServer $vcserver -Port $vcport -Force"
                    Connect-VIServer $vcserver -Port $vcport -Force -WarningAction SilentlyContinue -ErrorAction Continue -ErrorVariable myErr
                } else {
                    Write-Log "Connect-VIServer $vcserver -Port $vcport -User $vcuser -Password ******** -Force"
                    Connect-VIServer $vcserver -Port $vcport -User $vcuser -Password $vcpasswd -Force -WarningAction SilentlyContinue -ErrorAction Continue -ErrorVariable myErr
                }
                if ($?) { break }
            } catch {
                Write-Log -Warn "Failed to connect (attempt $i): $_"
            }
            if ($i -eq $connRetry) {
                Write-Log -Error "Connection attempts exceeded retry limit"
                Exit 1
            }
            Write-Host "Waiting $connRetryInterval sec. before retry.." -ForegroundColor Yellow
            Start-Sleep -Seconds $connRetryInterval
        }
    }
}


# ---- Get-VM with short retries to tolerate transient vCenter/API glitches ----
function TryGet-VMObject {
    # VM argument may be either object or name
    param(
        [Parameter()]$VM,
        [int]$MaxAttempts = 3,
        [int]$IntervalSec = 2,
        [switch]$Quiet
    )

    if (-not $VM) {
        Write-Log -Error "TryGet-VMObject: invalid VM object passed."
        return $null
    }

    if ($VM -is [string]) {
        $vmName = $VM
    } elseif ($VM -and $VM.PSObject.Properties.Match('Name')) {
        $vmName = $VM.Name
    } else {
        $vmName = $VM.ToString()
    }

    $attempt = 0
    while ($attempt -lt $MaxAttempts) {
        try {
            if ($VM -is [string]) {
                $vmObject = Get-VM -Name $VM -ErrorAction Stop
            } else {
                if ($VM.PSObject.Properties.Match('Id')) {
                    $vmObject = Get-VM -Id $VM.Id -ErrorAction Stop
                } elseif ($VM.PSObject.Properties.Match('Name')) {
                    $vmObject = Get-VM -Name $VM.Name -ErrorAction Stop
                } else {
                    throw "Invalid VM object: missing Id/Name property"
                }
            }
            return $vmObject
        } catch {
            $attempt++
            Write-Verbose "TryGet-VMObject: attempt #$attempt failed for '$vmName': $_"
            if ($attempt -lt $MaxAttempts) { Start-Sleep -Seconds $IntervalSec }
        }
    }
    if (-not $Quiet) {
        Write-Log -Error "TryGet-VMObject: failed to obtain VM object after $MaxAttempts attempts for input '$vmName'"
    }
    return $null
}

# ---- VM Power On/Off Functions ----
function Start-MyVM {
    param(
        [Parameter()]$VM,
        [switch]$Force,
        [int]$WaitPowerSec = 60,
        [int]$WaitToolsSec = 120
    )

    if (-not $VM) {
        Write-Log -Error "Start-MyVM: invalid VM object passed."
        return "start-failed"
    }

    # VM argument may be either object or name as TryGet-VMObject resolves it
    if ($VM -is [string]) {
        $vmName = $VM
    } elseif ($VM -and $VM.PSObject.Properties.Match('Name')) {
        $vmName = $VM.Name
    } else {
        $vmName = $VM.ToString()
    }

    # Refresh VM object
    $vmObj = TryGet-VMObject $VM
    if (-not $vmObj) {
        Write-Log -Error "Start-MyVM: unable to refresh VM object: '$vmName'"
        return "stat-unknown"
    }

    # Respect NoRestart unless Force overrides
    if (-not $Force -and $NoRestart) {
        if ($vmObj.PowerState -eq "PoweredOn") {
            Write-Log "VM already powered on (NoRestart set): '$vmName'"
            return "already-started"
        } else {
            Write-Log "VM remains powered off (NoRestart set): '$vmName'."
            return "skipped"
        }
    }

    # If already on, check tools
    if ($vmObj.PowerState -eq "PoweredOn") {
        Write-Log "VM already powered on: '$vmName'"
        $toolsOk = Wait-ForVMwareTools -VM $vmObj -TimeoutSec $WaitToolsSec
        if ($toolsOk) {
            return "already-started"
        } else {
            Write-Log -Warn "But VMware Tools did not become ready on already-on VM: '$vmName'"
            return "timeout"
        }
    }

    # Start the VM
    Write-Log "Starting VM '$vmName'..."
    try {
        $null = Start-VM -VM $vmObj -Confirm:$false -ErrorAction Stop
    } catch {
        Write-Log -Error "Failed to start VM '$vmName': $_"
        return "start-failed"
    }

    # Wait for PoweredOn and VMware Tools readiness
    $elapsed = 0
    $interval = 5
    $refreshFailCount = 0
    $maxRefreshConsecutiveFails = 3
    while ($elapsed -lt $WaitPowerSec) {
        Start-Sleep -Seconds $interval
        $elapsed += $interval
        $vmObj = TryGet-VMObject $vmObj 1 0
        if (-not $vmObj) {
            $refreshFailCount++
            Write-Verbose "Start-MyVM: transient refresh failure for '$vmName' while waiting (#$refreshFailCount)"
            if ($refreshFailCount -ge $maxRefreshConsecutiveFails) {
                Write-Log -Warn "Start-MyVM: repeated failures refreshing VM object for '$vmName' while waiting; aborting."
                return "start-failed"
            }
            continue
        } else {
            $refreshFailCount = 0
        }

        # Wait for VMware Tools
        if ($vmObj.PowerState -eq "PoweredOn") {
            Write-Log "VM '$vmName' is now PoweredOn. Waiting for VMware Tools..."
            $toolsOk = Wait-ForVMwareTools -VM $vmObj -TimeoutSec $WaitToolsSec
            if ($toolsOk) {
                return "success"
            } else {
                return "timeout"
            }
        }
        Write-Verbose "Waiting for VM '$vmName' to reach PoweredOn... ($elapsed/$WaitPowerSec s)"
    }
    Write-Log -Error "Timeout waiting for VM '$vmName' to reach PoweredOn after $WaitPowerSec s."
    return "start-failed"
}

function Stop-MyVM {
    param(
        [Parameter()]$VM,
        [int]$TimeoutSeconds = 180
    )

    if (-not $VM) {
        Write-Log -Error "Stop-MyVM: invalid VM object passed."
        return "stop-failed"
    }

    # VM argument may be either object or name as TryGet-VMObject resolves it
    if ($VM -is [string]) {
        $vmName = $VM
    } elseif ($VM -and $VM.PSObject.Properties.Match('Name')) {
        $vmName = $VM.Name
    } else {
        $vmName = $VM.ToString()
    }

    # Refresh current state to get current PowerState
    $vmObj = TryGet-VMObject $VM
    if (-not $vmObj) {
        Write-Log -Error "Stop-MyVM: failed to refresh VM object for '$vmName' after retries."
        return "stat-unknown"
    }

    if ($vmObj.PowerState -eq "PoweredOff") {
        if ($NoRestart) {
            Write-Log "VM already powered off (NoRestart set): '$vmName'"
            return "already-stopped"
        }
        Write-Log "VM already powered off: '$vmName'"
        return "already-stopped"
    }

    if ($NoRestart) {
       Write-Log "NoRestart specified: Shutdown was skipped."
       return "skipped"
    }

    Write-Log "Shutting down VM: '$vmName'"
    try {
        $null = Stop-VM -VM $vmObj -Confirm:$false -ErrorAction Stop
    } catch {
        Write-Log -Warn "Failed to stop VM '$vmName': $_"
        return "stop-failed"
    }

    # Wait for powered off
    $elapsed = 0
    $interval = 5
    $refreshFailCount = 0
    $maxRefreshConsecutiveFails = 3
    while ($elapsed -lt $TimeoutSeconds) {
        Start-Sleep -Seconds $interval
        $elapsed += $interval
        $vmObj = TryGet-VMObject $vmObj 1 0
        if (-not $vmObj) {
            $refreshFailCount++
            Write-Verbose "Stop-MyVM: transient refresh failure for '$vmName' while waiting (#$refreshFailCount)"
            if ($refreshFailCount -ge $maxRefreshConsecutiveFails) {
                Write-Log -Warn "Stop-MyVM: repeated failures refreshing VM object for '$vmName' while waiting; aborting."
                return "stop-failed"
            }
            continue
        } else {
            $refreshFailCount = 0
        }

        if ($vmObj.PowerState -eq "PoweredOff") {
            Write-Log "VM is now powered off: $vmName"
            return "success"
        }
        Write-Verbose "Waiting for VM '$vmName' to power off... ($elapsed/$TimeoutSeconds s)"
    }

    Write-Log -Error "Timeout waiting for VM '$vmName' to reach PoweredOff after $TimeoutSeconds seconds."
    return "timeout"
}

# Wait for VMware Tools to become ready inside the VM
function Wait-ForVMwareTools {
    param(
        [Parameter()]$VM,
        [int]$TimeoutSec = 120,
        [int]$PollIntervalSec = 5
    )

    if (-not $VM) {
        Write-Log -Warn "Wait-ForVMwareTools: VM parameter is null or empty."
        return $false
    }
    if ($TimeoutSec -le 0) { $TimeoutSec = 5 }
    if ($PollIntervalSec -le 0) { $PollIntervalSec = 1 }

    if ($VM -is [string]) {
        $vmName = $VM
    } elseif ($VM -and $VM.PSObject.Properties.Match('Name')) {
        $vmName = $VM.Name
    } else {
        $vmName = $VM.ToString()
    }

    # Refresh VM object
    $vmObj = TryGet-VMObject $VM
    if (-not $vmObj) {
        Write-Log -Warn "Wait-ForVMwareTools: cannot refresh VM object: '$vmName'"
        return $false
    }

    $waited = 0
    while ($waited -lt $TimeoutSec) {
        try {
            $toolsStatus = $vmObj.ExtensionData.Guest.ToolsStatus
        } catch {
            # transient failure reading ExtensionData; attempt to refresh and continue
            Write-Verbose "Wait-ForVMwareTools: failed to read ToolsStatus for '$vmName': $_"
            $vmObj = TryGet-VMObject $vmObj 1 0
            if (-not $vmObj) {
                Write-Verbose "Wait-ForVMwareTools: transient refresh failed for '$vmName'"
            }
            Start-Sleep -Seconds $PollIntervalSec
            $waited += $PollIntervalSec
            continue
        }

        if ($toolsStatus -eq "toolsOk") {
            Write-Log "VMware Tools is running on VM: '$vmName' (waited ${waited}s)"
            return $true
        }

        Start-Sleep -Seconds $PollIntervalSec
        $waited += $PollIntervalSec

        # Refresh VM object with minimal retries to keep status current
        $vmObj = TryGet-VMObject $vmObj 1 0
        if (-not $vmObj) {
            Write-Verbose "Wait-ForVMwareTools: transient refresh failure for '$vmName' while waiting (waited ${waited}s)"
        }
    }

    # Final status read attempt
    try {
        $finalName = $vmObj.Name
        $finalStatus = $vmObj.ExtensionData.Guest.ToolsStatus
    } catch {
        $finalName = $vmName
        $finalStatus = $null
    }

    Write-Log -Warn "Timed out waiting for VMware Tools on VM: '$vmName' after ${TimeoutSec}s. Last known status:: Name: $($finalName), ToolsStatus: $($finalStatus)"
    return $false
}

# ---- Load parameter file ----
if (-not (Test-Path $Config)) {
    Write-Log -Error "Configuration parameter file not found: $Config"
    Exit 3
}
try {
    $params = ConvertFrom-Yaml (Get-Content $Config -Raw)
} catch {
    Write-Log -Error "Failed to parse configuration parameter YAML: $Config"
    Exit 3
}

# ---------------------------------------
# ---- Main processing begins from here
# ---------------------------------------

$new_vm_name = $params.new_vm_name

# ---- Resolve working directory ----
$workdir = Join-Path $spooldir $new_vm_name
if (-not (Test-Path $workdir)) {
    try {
        New-Item -ItemType Directory -Path $workdir | Out-Null
        Write-Log "Created VM output directory: $workdir"
    } catch {
        Write-Log -Error "Failed to create workdir ($workdir): $_"
        Exit 2
    }
}
$LogFilePath = Join-Path $workdir ("deploy-" + (Get-Date -Format 'yyyyMMdd') + ".log")

# --- Select "primary" user from "userN" hashes and map its name and password to top-level variables ---
$userKeys = @()
try {
    # Find keys like user1, user2 ... and sort numerically
    $userKeys = $params.Keys | Where-Object { $_ -match '^user\d+$' } | Sort-Object { [int]($_ -replace '^user','') }
} catch {
    $userKeys = @()
}

if ($userKeys.Count -gt 0) {
    # Choose the first user with primary=true; otherwise fall back to the first declared user.
    $primaryUser = $null
    foreach ($k in $userKeys) {
        $u = $params[$k]
        if ($u -and $u.primary) {
            $primaryUser = $u
            break
        }
    }
    if (-not $primaryUser) {
        $primaryUser = $params[$userKeys[0]]
    }

    if ($primaryUser) {
        if ($primaryUser.name)     { $params.username = $primaryUser.name }
        if ($primaryUser.password) { $params.password = $primaryUser.password }
        Write-Log "Primary user selected for in-guest operations: '$($params.username)'"
    }
}

if (
    ($Phase -contains 2) -or ($Phase -contains 3) -or
    ( ($Phase -contains 4) -and -not $NoCloudReset )
) {
    if (-not ($params.username -and $params.password)) {
        Write-Log -Error "Could not determine primary user credentials (username/password) for in-guest operations for '$new_vm_name'. Aborting deployment."
        Exit 3
    }
}

# Connect to vCenter
$vcserver = $params.vcenter_host
$vcuser   = $params.vcenter_user
$vcpasswd = $params.vcenter_password
VIConnect

# ---- Phase 1: Clone the VM Template to the target VM with specified spec ----
function AutoClone {
    Write-Log "=== Phase 1: Automatic Cloning ==="

    # Check if a VM with the same name already exists
    $existingVM = TryGet-VMObject $new_vm_name -Quiet
    if ($existingVM) {
        Write-Log -Error "A VM with the same name '$new_vm_name' already exists. Aborting deployment."
        Exit 2
    }

    $templateVM = Get-Template -Name $params.template_vm_name
    if (-not $templateVM) {
        Write-Log -Error "Specified VM Template not found: $($params.template_vm_name)"
        Exit 3
    }

    if ([string]::IsNullOrEmpty($params.resource_pool_name) -or $params.resource_pool_name -eq "Resources") {
        $resourcePool = (Get-Cluster -Name $params.cluster_name | Get-ResourcePool | Where-Object { $_.Name -eq "Resources" })
    } else {
        $resourcePool = (Get-Cluster -Name $params.cluster_name | Get-ResourcePool | Where-Object { $_.Name -eq $params.resource_pool_name })
        if (-not $resourcePool) {
            Write-Log -Error "Specified Resource Pool not found: $($params.resource_pool_name)"
            Exit 3
        }
    }

    $vmParams = @{
        Name         = $new_vm_name
        Template     = $templateVM
        ResourcePool = $resourcePool
        Datastore    = $params.datastore_name
        VMHost       = $params.esxi_host
        ErrorAction  = 'Stop'
    }

    if ($params.disk_format) {
        $vmParams['DiskStorageFormat'] = $params.disk_format
    }

    if ($params.dvs_portgroup) {
        # For Distributed Switch
        $pg = Get-VDPortgroup -Name $params.dvs_portgroup
        if (-not $pg) {
            Write-Log -Error "Specified Distributed Portgroup not found: $($params.dvs_portgroup)"
            Exit 3
        }
        $vmParams['Portgroup'] = $pg
    }
    elseif ($params.network_name) {
        # For standard switch
        $pg = Get-VirtualPortGroup -Name $params.network_name
        if (-not $pg) {
            Write-Log -Error "Specified Standard Portgroup not found: $($params.network_name)"
            Exit 3
        }
        $vmParams['NetworkName'] = $params.network_name
    }

    # Clone the VM Template to target VM
    try {
        $newVM = New-VM @vmParams | Tee-Object -Variable newVMOut
        $newVMOut | Out-File $LogFilePath -Append -Encoding UTF8
        Write-Log "Deployed new VM: '$($newVM.Name)' from template: '$($templateVM.Name)' in datastore: '$($params.datastore_name)'"
        Write-Verbose @"
VM:`"$($vmParams['Name'])`", Template:`"$($templateVM.Name)`", Datastore:`"$($vmParams['Datastore'])`", ESXi-host:`"$($vmParams['VMHost'])`", DiskStorageFormat:`"$($vmParams['DiskStorageFormat'])`", ResourcePool:`"$($resourcePool.Name)`"
"@
    } catch {
        Write-Log -Error "Error occurred while deploying VM: '$new_vm_name': $_"
        Write-Verbose @"
VM:`"$($vmParams['Name'])`", Template:`"$($templateVM.Name)`", Datastore:`"$($vmParams['Datastore'])`", ESXi-host:`"$($vmParams['VMHost'])`", DiskStorageFormat:`"$($vmParams['DiskStorageFormat'])`", ResourcePool:`"$($resourcePool.Name)`"
"@
        Exit 1
    }

    # CPU/mem
    try {
        Set-VM -VM $newVM -NumCpu $params.cpu -MemoryMB $params.memory_mb -Confirm:$false -ErrorAction Stop |
          Tee-Object -Variable setVMOut | Out-File $LogFilePath -Append -Encoding UTF8
        Write-Log "Set CPU: $($params.cpu), Mem: $($params.memory_mb)MB"
    } catch {
        Write-Log -Error "Error during CPU/memory set: $_"
        Exit 1
    }

    # Disks
    if ($params.disks) {
        foreach ($d in $params.disks) {
            if ($d.ContainsKey('name') -and $d.ContainsKey('size_gb')) {
                $disk = Get-HardDisk -VM $newVM | Where-Object { $_.Name -eq $d['name'] }

                if (-not $disk) {
                    Write-Log -Error "Disk named '$($d['name'])' not found on VM '$new_vm_name'. Aborting."
                    Exit 3
                }

                if ($disk.CapacityGB -lt $d['size_gb']) {
                    try {
                        Set-HardDisk -HardDisk $disk -CapacityGB $d['size_gb'] -Confirm:$false |
                          Tee-Object -Variable setHDOut | Out-File $LogFilePath -Append -Encoding UTF8
                        Start-Sleep -Seconds 2
                        Write-Log "Resized disk '$($disk.Name)' to $($d['size_gb']) GB"
                    } catch {
                        Write-Log -Error "Error resizing disk '$($d['name'])': $_"
                        Exit 1
                    }
                }
            } else {
                Write-Log -Warn "Skipping disk entry missing 'name' or 'size_gb': $($d | Out-String)"
            }
        }
    }

    Write-Log "Phase 1 complete"
}

# ---- Phase 2: Initialize the clone VM for Phase-3 kickstart ----
function InitializeClone {
    Write-Log "=== Phase 2: Guest Initialization ==="

    $vm = TryGet-VMObject $new_vm_name
    if (-not $vm) {
        Write-Log -Error "VM not found: '$new_vm_name'"
        Exit 1
    }

    # Prepare username and password for VM commands
    $guestUser = $params.username
    $guestPassPlain = $params.password
    $guestPass = ConvertToSecureStringFromPlain $guestPassPlain
    if (-not $guestPass) {
        Write-Log -Error "Failed to convert guest password to SecureString. Aborting in Phase-2."
        Exit 3
    }

    # Prepare the initialization script
    if ($DiskOnly) {
        $localInitPath = Join-Path $scriptdir "scripts/init-vm-cloudinit-diskonly.sh"
    } else {
        $localInitPath = Join-Path $scriptdir "scripts/init-vm-cloudinit.sh"
    }
    if (-not (Test-Path $localInitPath)) {
        Write-Log -Error "Required script not found: $localInitPath"
        Exit 2
    }

    # Boot-up the clone VM
    if ($NoRestart) {
        if ($vm.PowerState -ne "PoweredOn") {
            Write-Host "'-NoRestart' is specified, but VM must be powered on for initialization."
            $resp = Read-Host "Start VM anyway? [Y]/n (If you answer N, the entire script will abort here)"
            if ($resp -eq "" -or $resp -eq "Y" -or $resp -eq "y") {
                $vmStartStatus = Start-MyVM $vm -Force
            } else {
                Write-Log -Error "User aborted due to NoRestart restriction."
                Exit 1
            }
        } else {
            $vmStartStatus = Start-MyVM $vm -Force
        }
    } else {
        $vmStartStatus = Start-MyVM $vm
    }

    Write-Log "VM boot/init status: '$vmStartStatus'"

    $toolsOk = $false

    switch ($vmStartStatus) {
        "success" {
            $toolsOk = $true
        }
        "already-started" {
            # VM was already on and Tools ready before our operation
            $toolsOk = $true
        }

        <#
        "skipped" {
            # NOTE: This case is intentionally commented out because, in the current InitializeClone flow,
            # Start-MyVM is invoked with -Force whenever -NoRestart is set (or the user explicitly agreed to start).
            # Therefore Start-MyVM should not return "skipped" from this call path; the "skipped" return value
            # is reachable in other phases/call-sites (e.g., Phase-3 Stop/Start operations) and is therefore
            # left implemented in Start-MyVM itself. We keep this commented block here for documentation / future
            # reference and to make it easy to re-enable handling if the calling logic changes later.
            Write-Log "VM was not started due to -NoRestart option. Check current status of the VM and VMware Tools."
        }
        #>

        "timeout" {
            Write-Log -Warn "VMware Tools did not become ready within expected timeframe. Initialization cannot proceed reliably."
        }
        "start-failed" {
            Write-Log -Error "VM could not be started. Initialization aborted."
        }
        "stat-unknown" {
            Write-Log -Error "Unable to determine VM state (stat-unknown). Initialization aborted."
        }
        default {
            Write-Log -Warn "Unrecognized VM start status: `"$vmStartStatus`". Aborting to avoid undefined behaviour."
        }
    }

    # Final gating logic: proceed only when $toolsOk was set by an accepted success case.
    if (-not $toolsOk) {
        Write-Log -Error "Script aborted since VM is not ready for online activities."
        Exit 1
    }

    # Refresh VM object for reliable operations
    $vm = TryGet-VMObject $vm
    if (-not $vm) {
        Write-Log -Error "Unable to refresh VM object: '$($vm.Name)'"
        Exit 1
    }

    # Ensure guest workdir
    $guestInitPath = "$workDirOnVM/init-vm-cloudinit.sh"
    try {
        $phase2cmd = @"
sudo /bin/bash -c "mkdir -p $workDirOnVM && chown $guestUser $workDirOnVM"
"@
        $null = Invoke-VMScript -VM $vm -ScriptText $phase2cmd -ScriptType Bash `
            -GuestUser $guestUser -GuestPassword $guestPass -ErrorAction Stop
        Write-Log "Ensured work directory exists on the VM: $workDirOnVM"
    } catch {
        Write-Log -Error "Failed to create work directory on the VM: $_"
        Exit 1
    }

    # Transfer the script and run on the clone
    try {
        Write-Log "Copying initialization script to the VM: $guestInitPath"
        $null = Copy-VMGuestFile -LocalToGuest -Source $localInitPath -Destination $guestInitPath `
            -VM $vm -GuestUser $guestUser -GuestPassword $guestPass -Force -ErrorAction Stop
        Write-Verbose "Copied initialization script to the VM: $guestInitPath"
    } catch {
        Write-Log -Error "Failed to copy initialization script to the VM: $_"
        Exit 1
    }

    try {
        $phase2cmd = @"
chmod +x $guestInitPath && sudo /bin/bash $guestInitPath
"@
        $null = Invoke-VMScript -VM $vm -ScriptText $phase2cmd -ScriptType Bash `
            -GuestUser $guestUser -GuestPassword $guestPass -ErrorAction Stop
        Write-Log "Executed initialization script on the VM."
    } catch {
        Write-Log -Error "Failed to execute initialization script on the VM: $_"
        Exit 1
    }

    try {
        $null = Invoke-VMScript -VM $vm -ScriptText "rm -f $guestInitPath" -ScriptType Bash `
            -GuestUser $guestUser -GuestPassword $guestPass -ErrorAction Stop
        Write-Log "Removed initialization script from the VM: $guestInitPath"
    } catch {
        Write-Log -Warn "Failed to remove initialization script from the VM: $_"
    }

    Write-Log "Phase 2 complete"

    if ($Phase -notcontains 3) {
        Write-Log "Note: The VM has been left powered on. When you are finished, you may shut it down manually; otherwise it will be shut down automatically when Phase-3 begins."
    }
}

# ---- Phase 3: Generate cloud-init seed ISO and personalize VM ----
function CloudInitKickStart {
    Write-Log "=== Phase 3: Cloud-init Seed Generation & Personalization ==="

    $cloudInitWaitTotalSec = if ($params.cloudinit_wait_sec) { [int]$params.cloudinit_wait_sec } else { 600 }
    $cloudInitPollSec =      if ($params.cloudinit_poll_sec) { [int]$params.cloudinit_poll_sec } else { 10 }
    $toolsWaitSec = if ($params.cloudinit_tools_wait_sec) { [int]$params.cloudinit_tools_wait_sec } else { 60 }
    $toolsPollSec = if ($params.cloudinit_tools_poll_sec) { [int]$params.cloudinit_tools_poll_sec } else { 10 }

    function Replace-Placeholders {
    # Replace each placeholder with a value from YAML key or nested hash key (array keys are not supported for now)
        Param(
            [parameter()]
            [String]$template,
            [parameter()]
            [Object]$params,
            [parameter()]
            [String]$prefix = ""
        )

        foreach ($k in $params.Keys) {
            $v = $params[$k]
            $keyPath = if ($prefix) { "$prefix.$k" } else { $k }
            if (
                $v -is [string] -or
                $v -is [int] -or
                $v -is [bool] -or
                $v -is [double] -or
                $null -eq $v
            ) {
                $pattern = '\{\{\s*' + [Regex]::Escape($keyPath) + '\s*\}\}'
                if ($template -match $pattern) {
                    Write-Verbose "Replacing placeholder: '$keyPath'"
                    $template = $template -replace $pattern, [string]$v
                }
            } elseif ($v -is [hashtable] -or $v -is [PSCustomObject]) {
                $template = Replace-Placeholders -template $template -params $v -prefix $keyPath
            } else {
                $typeName = $v.GetType().Name
                Write-Verbose "Placeholder replacement skipped unsupported data structure for this script: $keyPath (type: $typeName)"
            }
        }
        return $template
    }

    $vm = TryGet-VMObject $new_vm_name
    if (-not $vm) {
        Write-Log -Error "Target VM not found: '$new_vm_name'"
        Exit 1
    }

    # Prepare username and password for VM commands
    $guestUser = $params.username
    $guestPassPlain = $params.password
    $guestPass = ConvertToSecureStringFromPlain $guestPassPlain
    if (-not $guestPass) {
        Write-Log -Error "Failed to convert guest password to SecureString. Aborting in Phase-3."
        Exit 3
    }

    # --- Early check for /etc/cloud/cloud-init.disabled; if the file exists Phase-3 is meaningless
    $wasPowerOnAtBegin = $false      # Flag to indicate this VM was already PoweredOn when this phase started

    if ($vm -and $vm.PowerState -eq 'PoweredOn') {
        $toolsOk = Wait-ForVMwareTools -VM $vm -TimeoutSec 20 -PollIntervalSec 5

        if (-not $toolsOk) {
            Write-Log -Warn "VMware Tools not available to perform early cloud-init.disabled check; proceeding with Phase-3 anyway."
        } else {
            $wasPowerOnAtBegin = $true

            $checkCmd = "sudo /bin/bash -c 'if [ -f /etc/cloud/cloud-init.disabled ]; then echo CLOUDINIT_DISABLED; exit 0; else echo CLOUDINIT_ENABLED; exit 1; fi'"
            try {
                $res = Invoke-VMScript -VM $vm -GuestUser $guestUser -GuestPassword $guestPass `
                    -ScriptText $checkCmd -ScriptType Bash -ErrorAction Stop

                $out = if ($res.ScriptOutput) { ($res.ScriptOutput -join [Environment]::NewLine).Trim() } `
                       elseif ($res.ScriptError) { ($res.ScriptError -join [Environment]::NewLine).Trim() } `
                       else { "" }

                if ($res.ExitCode -eq 0 -and $out -match 'CLOUDINIT_DISABLED') {
                    Write-Log -Warn "VM has /etc/cloud/cloud-init.disabled; Phase-3 (seed attach and kickstart) is unnecessary and may be harmful. Aborting Phase-3."
                    Exit 2
                } else {
                    Write-Log "Early check: no /etc/cloud/cloud-init.disabled found on the VM; proceeding with Phase-3."
                }
            } catch {
                Write-Log -Warn "Early check for cloud-init.disabled failed (Invoke-VMScript error): $_"
                Write-Log -Warn "Proceeding with Phase-3 anyway; note if the VM actually has cloud-init disabled, Phase-3 may be ineffective."
            }
        }
    } else {
        Write-Log -Warn "VM is not powered on; unable to check existence of /etc/cloud/cloud-init.disabled. Proceeding with Phase-3 anyway."
    }

    # 1. Shutdown the VM (skipped automatically if applicable)
    if (-not $NoRestart) {
        Write-Log "The target VM is going to shut down to attach cloud-config seed ISO and boot for actual personalization to take effect."
        Write-Log "Shutting down in 5 seconds..."
        Start-Sleep -Seconds 5
    }

    $stopResult = Stop-MyVM $vm

    switch ($stopResult) {
        "success" {
            Write-Log "Proceeding with Phase-3 operations."
            # Refresh VM object to ensure we have current PowerState for later steps
            $vm = TryGet-VMObject $vm
        }
        "already-stopped" {
            Write-Log "Proceeding with Phase-3 operations."
            $vm = TryGet-VMObject $vm
        }
        "skipped" {
            Write-Log "Continuing without shutdown."
            $vm = TryGet-VMObject $vm
            if ($vm) { Write-Log "VM power state: $($vm.PowerState)" }
            Write-Log -Warn "Note: Ensure the VM power state is appropriate for your needs in this run of Phase-3."
        }
        "timeout" {
            Write-Log -Error "Script aborted."
            Exit 1
        }
        "stop-failed" {
            Write-Log -Error "Script aborted."
            Exit 1
        }
        default {
            Write-Log -Error "Unknown result from Stop-MyVM: '$stopResult'. Script aborted."
            Exit 1
        }
    }

    # 2. Prepare local seed working dir
    $seedDir = Join-Path $workdir "cloudinit-seed"
    if (Test-Path $seedDir) {
        try {
            Remove-Item -Recurse -Force $seedDir -ErrorAction Stop
            Write-Log "Removed old seed dir: '$seedDir'"
        } catch {
            Write-Log -Warn "Failed to remove previous seed dir: $_"
        }
    }
    try {
        New-Item -ItemType Directory -Path $seedDir | Out-Null
        Write-Log "Created seed dir: '$seedDir'"
    } catch {
        Write-Log -Error "Failed to create seed dir: $_"
        Exit 2
    }

    # 3. Generate cloud-config YAMLs; user-data/meta-data/network-config from templates
    $tplDir = Join-Path $scriptdir "templates"
    if ($DiskOnly) {
        $seedFiles = @(
            @{tpl="user-data_diskonly_template.yaml"; out="user-data"},
            @{tpl="meta-data_template.yaml"; out="meta-data"}
        )
    } else {
        $seedFiles = @(
            @{tpl="user-data_template.yaml"; out="user-data"},
            @{tpl="meta-data_template.yaml"; out="meta-data"}
        )
        # Optional: network-config
        $netTpl = Join-Path $tplDir "network-config_template.yaml"
        if (Test-Path $netTpl) {
            $seedFiles += @{tpl="network-config_template.yaml"; out="network-config"}
        } else {
            Write-Log "cloud-config YAML template: '$netTpl' not found; omitted."
        }
    }

    foreach ($f in $seedFiles) {
        $tplPath = Join-Path $tplDir $f.tpl
        $charLF = "`n"
        if (-not (Test-Path $tplPath)) {
            Write-Log -Error "Missing template: '$tplPath'"
            Exit 2
        }
        try {
            Write-Log "Composing '$($f.out)' for cloud-config seed."
            $template = Get-Content $tplPath -Raw

            # For user-data only: construct the filesystem resizing runcmd blocks by substitution
            if ($f.out -eq "user-data") {
                $runcmdList = @()

                # 1. --- Ext2/3/4 filesystems expansion
                if ($params.resize_fs -and $params.resize_fs.Count -gt 0) {
                    foreach ($fsdev in $params.resize_fs) {
                        $runcmdList += @("[ resize2fs, $fsdev ]")
                    }
                }

                # 2. --- Swap devices expansion
                if ($params.swaps) {
                    $swapList = @()
                    try {
                        $keys = $params.swaps.Keys

                        # If keys look numeric, sort numerically for stable ordering; otherwise sort lexicographically for failsafe.
                        $numericKeys = $keys | Where-Object { $_ -as [int] -ne $null }
                        if ($numericKeys.Count -gt 0) {
                            $sortedKeys = $keys | Sort-Object { [int]$_ }
                        } else {
                            $sortedKeys = $keys | Sort-Object
                        }

                        foreach ($k in $sortedKeys) {
                            $val = $params.swaps[$k]
                            if ($val) { $swapList += [string]$val }
                        }
                    } catch {
                        Write-Verbose "Failed to derive swap list from swaps mapping: $_"
                        $swapList = @()
                    }

                    if ($swapList.Count -gt 0) {
                        # -- Placeholder replacement for partitions growpart
                        $swapsQuoted = $swapList | ForEach-Object { "'$($_.ToString().Trim())'" }

                        if ($swapsQuoted -and $swapsQuoted.Count -gt 0) {
                            $swapsToGrow = ($swapsQuoted -join ", ") + ", "
                        } else {
                            $swapsToGrow = " "
                        }

                        $template = $template -replace '\{\{SWAPS_GROW\}\}', $swapsToGrow
                        Write-Log "SWAPS_GROW placeholder replaced: `"$swapsToGrow`""

                        # -- Runcmd composition for swap-space reformatting
                        $swapdevs = $swapList -join " "

                        # Bash script for swap reinit (dividing into parts to avoid PowerShell variable expansion)
                        $shBodyHead = @'
      #!/bin/bash
      set -eux
      for swapdev in 
'@
                        $shBodyTail = @'
      ; do
        OLDUUID=$(blkid -s UUID -o value "$swapdev")
        OLDSWAPUNIT=$(systemd-escape "dev/disk/by-uuid/$OLDUUID").swap
        systemctl mask "$OLDSWAPUNIT"
        swapoff "$swapdev"
        mkswap "$swapdev"
        NEWUUID=$(blkid -s UUID -o value "$swapdev")
        sed -i "s|UUID=$OLDUUID|UUID=$NEWUUID|" /etc/fstab
        systemctl daemon-reload
        systemctl unmask "$OLDSWAPUNIT"
        swapon "$swapdev"
      done
      dracut -f
'@
                        $shBody = $shBodyHead + "$swapdevs" + $shBodyTail

                        # Compose the here-document runcmd entry
                        # By packaging the generated shell script as a here-document for cloud-init runcmd,
                        # complex tasks are delegated to the target VM for reliable execution, avoiding extensive escaping.
                        $swapScriptCmd = @"
|
      bash -c 'cat <<"EOF" >$workDirOnVM/resize_swap.sh
$shBody
      EOF
      '
"@

                        $runcmdList += @("[ mkdir, -p, $workDirOnVM ]")
                        $runcmdList += @("[ chown, $guestUser, $workDirOnVM ]")
                        $runcmdList += @($swapScriptCmd)
                        $runcmdList += @("[ bash, $workDirOnVM/resize_swap.sh ]")
                    }
                }

                # 3. --- Runcmd composition for network devices optimization
                $netifKeys = $params.Keys | Where-Object { $_ -match '^netif\d+$' } | Sort-Object { [int]($_ -replace '^netif','') }
                $conNamePrefix = "System "    # Change this if cloud-init on your environment behaves differently

                foreach ($netifKey in $netifKeys) {
                    $cfg = $params[$netifKey]
                    if (-not $cfg) { continue }
                    $dev = $cfg["netdev"]
                    if (-not $dev) { continue }
                    $conName = "${conNamePrefix}$dev"
                    $netifModified=$false

                    if ($cfg["ignore_auto_routes"]) {         # Not set if the key does not exist or the value is false/no/$null
                        $cmd = @"
[ nmcli, connection, modify, "$conName", ipv4.ignore-auto-routes, yes ]
"@
                        $runcmdList += @($cmd)
                        $netifModified=$true
                    }

                    if ($cfg["ignore_auto_dns"]) {
                        $cmd = @"
[ nmcli, connection, modify, "$conName", ipv4.ignore-auto-dns, yes ]
"@
                        $runcmdList += @($cmd)
                        $netifModified=$true
                    }

                    if ($cfg["ipv6_disable"]) {
                        $cmd = @"
[ nmcli, connection, modify, "$conName", ipv6.method, disabled ]
"@
                        $runcmdList += @($cmd)
                        $netifModified=$true
                    }

                    if ($netifModified) {
                        $cmd = "[ nmcli, device, reapply, $dev ]"
                        $runcmdList += @($cmd)
                    }
                }

                # 4. --- Finally compose USER_RUNCMD_BLOCK for user-data template
                if ($runcmdList.Count -gt 0) {
                    $userRuncmdBlock = $runcmdList -join "`n  - "
                    $userRuncmdBlock = "`n  - " + $userRuncmdBlock
                } else {
                    $userRuncmdBlock = " []"
                }

                $template = $template -replace '\{\{USER_RUNCMD_BLOCK\}\}', $userRuncmdBlock
                Write-Log "USER_RUNCMD_BLOCK placeholder replaced (runcmd count: $($runcmdList.Count))"

                # 5. --- Placeholder replacement for SSH_KEYS block per user
                $userKeys = $params.Keys | Where-Object { $_ -match '^user\d+$' } | Sort-Object { [int]($_ -replace '^user','') }
                foreach ($userKey in $userKeys) {
                    $u = $params[$userKey]
                    if (-not $u) { continue }

                    if ($u.ssh_keys -and $u.ssh_keys.Count -gt 0) {
                        $sshLines = $u.ssh_keys | ForEach-Object { '      - "' + $_.ToString().Trim() + '"' }
                        $userSshBlock = $sshLines -join "`n"
                    } else {
                        $userSshBlock = '      []'
                    }

                    $placeholder = "${userKey}.SSH_KEYS"
                    $pattern = '\{\{\s*' + [Regex]::Escape($placeholder) + '\s*\}\}'

                    if ($template -match $pattern) {
                        Write-Verbose "Replacing per-user SSH placeholder: '$placeholder'"
                        $template = $template -replace $pattern, $userSshBlock
                        Write-Log "SSH_KEYS placeholder for user '$($u.name)' replaced (count: $($u.ssh_keys.Count))"
                    }
                }
            }

            # For network-config only
            if ($f.out -eq "network-config") {
                $netifKeys = $params.Keys | Where-Object { $_ -match '^netif\d+$' } | Sort-Object { [int]($_ -replace '^netif','') }

                foreach ($netifKey in $netifKeys) {
                    $cfg = $params[$netifKey]
                    if (-not $cfg) { continue }

                    # Placeholder replacement for nameserver addresses, e.g. "{{netif1.DNS_ADDRESSES}}" -> "[192.168.0.1, 192.168.0.2]"
                    if ($cfg.dnsaddresses -and $cfg.dnsaddresses.Count -gt 0) {
                        $dnsItems = $cfg.dnsaddresses | ForEach-Object { $_.ToString().Trim() }
                        $dnsBlock = '[' + ($dnsItems -join ', ') + ']'
                    } else {
                        $dnsBlock = '[]'
                    }

                    # Use '[Regex]::Escape' to avoid regex metacharacter surprises in the placeholder name
                    $placeholder = "${netifKey}.DNS_ADDRESSES"
                    $pattern = '\{\{\s*' + [Regex]::Escape($placeholder) + '\s*\}\}'

                    # '-match' and '-replace' are both case-insensitive by default
                    if ($template -match $pattern) {
                        $template = $template -replace $pattern, $dnsBlock
                        Write-Log "Placeholder: '$placeholder' replaced: '$dnsBlock'"
                    } else {
                        Write-Verbose "Network placeholder not present for '$placeholder' (skipped)."
                    }
                }
            }

            # Generic placeholder replacement based on their hierarchial names
            Write-Log "Replacing placeholders in $($f.out)"
            $output = Replace-Placeholders $template $params

            # Write out the file contents, avoiding Set-Content's default behavior of appending a trailing CRLF
            $output = $output.TrimEnd("`r", "`n") + $charLF
            $seedOut = Join-Path $seedDir $f.out
            $utf8NoBomEncoding = New-Object System.Text.UTF8Encoding($false)
            [System.IO.File]::WriteAllText($seedOut, $output, $utf8NoBomEncoding)
            Write-Log "Generated '$($f.out)' for cloud-config seed."
        } catch {
            Write-Log -Error "Failed to render $($f.tpl): $_"
            Exit 2
        }
    }

    # 4. Create seed ISO with mkisofs
    if (-not (Test-Path $mkisofs)) {
        Write-Log -Error "ISO creation tool not found: '$mkisofs'"
        Exit 2
    }
    $isoPath = Join-Path $workdir $seedIsoName

    try {
        $mkArgs = @('-output', $isoPath, '-V', 'cidata', '-r', '-J', $seedDir)

        $quotedArgs = $mkArgs | ForEach-Object { if ($_ -match '\s') { '"{0}"' -f $_ } else { $_ } }
        $cmdForLog = '"' + $mkisofs + '" ' + ($quotedArgs -join ' ')
        Write-Log "Creating ISO; command:`n$cmdForLog"

        $mkisofsOut = & "$mkisofs" @mkArgs 2>&1
        $mkisofsExit = $LASTEXITCODE

        if ($mkisofsExit -ne 0 -or -not (Test-Path $isoPath)) {
            $mkisofsOutStr = if ($mkisofsOut) { $mkisofsOut -join [Environment]::NewLine } else { "" }
            throw "mkisofs failed; exit-code: $mkisofsExit), output:`n$mkisofsOutStr"
        }
        Write-Log "cloud-init seed ISO successfully created: '$isoPath'"
    } catch {
        Write-Log -Error "Failed to generate '$seedIsoName': $_"
        Exit 2
    }

    # 5. Upload ISO to vSphere datastore and attach to VM's CD drive
    $cdd = Get-CDDrive -VM $vm
    if (-not $cdd) {
        Write-Log -Error "No CD/DVD drive found on this VM. Please add a CD/DVD drive and rerun Phase-3."
        Exit 2
    }

    $seedIsoCopyStore = $params.seed_iso_copy_store.TrimEnd('/').TrimEnd('\')
    $datacenterName = $params.datacenter_name
    if (-not $seedIsoCopyStore) {
        Write-Log -Error "Parameter 'seed_iso_copy_store' is not set. Please check your parameter file."
        Exit 2
    }
    if (-not $datacenterName) {
        Write-Log -Error "Parameter 'datacenter_name' is not set. Please check your parameter file."
        Exit 2
    }

    # Datastore full path like [COMMSTORE01] ISO/cloudinit-seed.iso
    $datastoreIsoPath = "$seedIsoCopyStore/$seedIsoName"

    # Split into datastore name and folder path
    if ($seedIsoCopyStore -match "^\[(.+?)\]\s*(.+)$") {
        $datastoreName = $matches[1]
        $datastoreFolder = $matches[2].Trim('/')
    } else {
        Write-Log -Error "Invalid format for parameter 'seed_iso_copy_store': $seedIsoCopyStore"
        Exit 2
    }

    try {
        $datastore = Get-Datastore -Name $datastoreName -ErrorAction Stop
    } catch {
        Write-Log -Error "Datastore not found: '$datastoreName'"
        Exit 2
    }

    $vmstoreFolderPath = "vmstore:\$datacenterName\$datastoreName\$datastoreFolder"
    $vmstoreIsoPath = "$vmstoreFolderPath\$seedIsoName"

    # Pre-checks for upload
    if (-not (Test-Path $vmstoreFolderPath)) {
        Write-Log -Error "Target folder does not exist in datastore: '$vmstoreFolderPath' ($seedIsoCopyStore)"
        Exit 2
    }

    if (Test-Path $vmstoreIsoPath) {
        Write-Log -Error "Seed ISO '$vmstoreIsoPath' ($datastoreIsoPath) already exists. Please remove it or specify another path."
        Exit 2
    }

    # Upload the ISO to the datastore using vmstore:\ path as destination
    try {
        $null = Copy-DatastoreItem -Item "$isoPath" -Destination "$vmstoreIsoPath" -ErrorAction Stop
        Write-Log "Seed ISO uploaded to datastore: '$vmstoreIsoPath' ($datastoreIsoPath)"
    } catch {
        Write-Log -Error "Failed to upload seed ISO to datastore: $_"
        Exit 2
    }

    # Attach ISO to the VM's CD drive
    try {
        $null = Set-CDDrive -CD $cdd -IsoPath "$datastoreIsoPath" -StartConnected $true -Confirm:$false -ErrorAction Stop |
          Tee-Object -Variable setCDOut
          $setCDOut | Select-Object IsoPath,Parent,ConnectionState | Format-List | Out-File $LogFilePath -Append -Encoding UTF8
        Write-Log "Seed ISO attached to VM's CD drive."
    } catch {
        Write-Log -Error "Failed to attach the seed ISO to VM's CD drive: $_"
        try {
            $null = Remove-DatastoreItem -Path $vmstoreIsoPath -Confirm:$false -ErrorAction Stop
            Write-Log "Cleaned up the uploaded seed ISO from datastore: '$vmstoreIsoPath'"
        } catch {
            Write-Log -Error "Failed to clean up ISO from datastore: $_"
        }
        Exit 1
    }

    # When VM has been powered on since before this phase started --
    if ($wasPowerOnAtBegin -and $NoRestart) {
        Write-Log -Warn "Boot with attached cloud-init seed ISO is impossible, because VM had been powered on prior to attach and -NoRestart option inhibited previous shutdown."
        Write-Log -Warn "Phase-3 ends now without cloud-init OS personalization in effect; Manual reboot is required."
        if ($Phase -contains 4) {
            Write-Log -Error "Aborting without proceeding to Phase-4."
            Exit 2
        }
        Exit
    }

    # Record epoch seconds right after attaching the seed ISO to reference later in determination of cloud-init completion.
    $seedAttachEpoch = [int][double]((Get-Date).ToUniversalTime() - (Get-Date "1970-01-01T00:00:00Z")).TotalSeconds
    Write-Verbose "Recorded seed attach epoch '$seedAttachEpoch' for later cloud-init completion checks."

    # 6. Power on VM for personalization
    $vmStartStatus = Start-MyVM $vm

    Write-Verbose "Phase-3: Start-MyVM returned status: '$vmStartStatus'"

    # Use a pass/fail sentinel ($toolsOk) to decide whether we continue.
    $toolsOk = $false

    switch ($vmStartStatus) {
        "success" {
            $toolsOk = $true
        }
        "already-started" {
            $toolsOk = $true
        }
        "skipped" {
            Write-Log -Warn "Power-on operation of the VM was NOT performed due to -NoRestart option."
            Write-Log -Warn "Phase-3 ends now without cloud-init OS personalization in effect; Manual reboot is required."
            Exit
        }
        "timeout" {
            Write-Log -Warn "VMware Tools did not become ready within expected timeframe. Personalization may fail; aborting Phase-3."
        }
        "start-failed" {
            Write-Log -Error "VM could not be started. Aborting Phase-3."
        }
        "stat-unknown" {
            Write-Log -Error "Unable to determine VM state. Aborting Phase-3."
        }
        default {
            Write-Log -Warn "Unknown result from Start-MyVM function: '$vmStartStatus'. Aborting to avoid undefined behaviour."
        }
    }
    if (-not $toolsOk) {
        Write-Log -Error "Script aborted since VM is not ready for online activities."
        Exit 1
    }

    # 7. Wait for cloud-init to complete personalization on the VM

    # Refresh VM object for reliable operations.
    $vm = TryGet-VMObject $vm
    if (-not $vm) {
        Write-Log -Error "Unable to refresh VM object after VM start; aborting."
        Exit 1
    }
    Write-Verbose "Phase-3: VM object refreshed successfully: '$($vm.Name)'"

    # Wait for VMware Tools then stabilize to avoid transient early Tools
    $backoffSec = if ($params.cloudinit_backoff_sec) { [int]$params.cloudinit_backoff_sec } else { 60 }
    $toolsOk = Wait-ForVMwareTools -VM $vm -TimeoutSec 120
    if (-not $toolsOk) {
        Write-Log -Warn "VMware Tools did not report ready within 120s; will still attempt copy with retries."
    }
    Write-Log "Pausing ${backoffSec}s to allow guest services to stabilize..."
    Start-Sleep -Seconds $backoffSec

    #--- Quick cloud-init base status check before the real completion polling, in order to avoid pointless wait in case cloud-init was not invoked on this boot.
    Write-Log "Preparing quick-check script for cloud-init base status..."

    # Build Quick-check script locally then transfer to the VM and utilize.
    $localQuickPath = Join-Path $workdir "quick-check.sh"
    $guestQuickPath = "$workDirOnVM/quick-check.sh"

    # quick-check guest script (template)
    $quickCheckTpl = @'
#!/bin/bash
SEED_TS="{{SEED_TS}}"

# Argument SEED_TS must be numeric
if ! [[ "$SEED_TS" =~ ^[0-9]+$ ]]; then
  echo "TERMINAL:INVALID_SEED_TS:'$SEED_TS'"
  exit 2
fi

# Function to determine current instance-id trying multiple methods in order
get_instance_id() {
  local res ins target latest

  # 1) cloud-init query
  if command -v cloud-init >/dev/null 2>&1; then
    res=$(cloud-init query instance_id 2>/dev/null || cloud-init query instance-id 2>/dev/null || echo "")
    if [ -n "$res" ]; then
      # remove surrounding quotes and trim
      ins=$(printf "%s" "$res" | tr -d '"' | tr -d "'" | xargs)
      if [ -n "$ins" ]; then
        echo "$ins"
        return 0
      fi
    fi
  fi

  # 2) /run cloud-init runtime location
  if [ -f /run/cloud-init/.instance-id ]; then
    ins=$(cat /run/cloud-init/.instance-id 2>/dev/null | xargs)
    if [ -n "$ins" ]; then
      echo "$ins"
      return 0
    fi
  fi

  # 3) legacy/data location
  if [ -f /var/lib/cloud/data/instance-id ]; then
    ins=$(cat /var/lib/cloud/data/instance-id 2>/dev/null | xargs)
    if [ -n "$ins" ]; then
      echo "$ins"
      return 0
    fi
  fi

  # 4) /var/lib/cloud/instance is often a symlink to instances/<id>
  if [ -L /var/lib/cloud/instance ]; then
    target=$(readlink -f /var/lib/cloud/instance 2>/dev/null)
    if [ -n "$target" ]; then
      echo "$(basename "$target")"
      return 0
    fi
  fi

  # 5) fallback: the most-recent /var/lib/cloud/instances/<id> directory
  latest=$(find /var/lib/cloud/instances -maxdepth 1 -mindepth 1 -type d -printf "%T@ %p\n" | sort -rn | head -n1 | cut -d' ' -f2)
  if [ -n "$latest" ]; then
    echo "$(basename "$latest")"
    return 0
  fi

  return 1
}

# Function to check file mtime > seed; label is second arg
check_mtime_after() {
  paths="$1"
  label="$2"
  for f in $paths; do
    [ -e "$f" ] || continue
    file_ts=$(stat -c %Y "$f" 2>/dev/null || echo 0)
    if [ "$file_ts" -gt "$SEED_TS" ]; then
      echo "${label}:$f${instanceIdStr:-}"
      exit 0
    fi
  done
}

##--- Start validation ---

# Get current instance-id if possible
inst=""
instanceIdStr=""
inst=$(get_instance_id 2>/dev/null || echo "")
if [ -n "$inst" ]; then
  instanceIdStr=";$inst"
fi

# 0) Terminal: cloud-init explicitly disabled
if [ -f /etc/cloud/cloud-init.disabled ]; then
  echo "TERMINAL:cloud-init-disabled"
  exit 2
fi

# 1) strong evidence: instance-id files (try common locations)
check_mtime_after '/var/lib/cloud/data/instance-id' RAN
check_mtime_after '/run/cloud-init/.instance-id' RAN

# Check /var/lib/cloud/instances/<id>/, where cloud/instance/ is often a symlink to it.
# If we already discovered an instance id, prefer directly checking it.
if [ -n "$inst" ] && [ -d "/var/lib/cloud/instances/$inst" ]; then
  check_mtime_after "/var/lib/cloud/instances/$inst" RAN
else
  if [ -L /var/lib/cloud/instance ]; then
    inst_link_target=$(readlink -f /var/lib/cloud/instance 2>/dev/null)
    if [ -n "$inst_link_target" ]; then
      check_mtime_after "$inst_link_target" RAN
    fi
  fi
fi

# 2) very strong: sem files (module-level evidence)
if [ -n "$inst" ]; then
  semdir="/var/lib/cloud/instances/$inst/sem"
  if [ -d "$semdir" ]; then
    for s in "$semdir"/*; do
      [ -e "$s" ] || continue
      file_ts=$(stat -c %Y "$s" 2>/dev/null || echo 0)
      if [ "$file_ts" -gt "$SEED_TS" ]; then
        echo "RAN-SEM:$s${instanceIdStr:-}"
        exit 0
      fi
    done
  fi
fi

# 3) strong evidence: cloud-init logs
check_mtime_after /var/log/cloud-init.log RAN
check_mtime_after /var/log/cloud-init-output.log RAN

# 4) boot-finished (fallback)
check_mtime_after /var/lib/cloud/instance/boot-finished RAN

# 5) supporting evidence: network config artifacts
check_mtime_after '/etc/sysconfig/network-scripts/ifcfg-*' RAN-NET
check_mtime_after '/etc/NetworkManager/system-connections/*' RAN-NET
check_mtime_after '/etc/netplan/*.yaml' RAN-NET
check_mtime_after '/etc/systemd/network/*.network' RAN-NET
check_mtime_after '/etc/network/interfaces' RAN-NET

# nothing found
echo "NOTRAN"
exit 1
'@

    # Confirm VMware Tools availability first
    $toolsAvailableForQuickCheck = Wait-ForVMwareTools -VM $vm -TimeoutSec 20 -PollIntervalSec 5

    # Ensure guest workdir
    try {
        $phase3cmd = @"
sudo /bin/bash -c "mkdir -p $workDirOnVM && chown $guestUser $workDirOnVM"
"@
        $null = Invoke-VMScript -VM $vm -ScriptText $phase3cmd -GuestUser $guestUser -GuestPassword $guestPass `
            -ScriptType Bash -ErrorAction Stop
        Write-Log "Ensured work directory exists on the VM: '$workDirOnVM'"
    } catch {
        Write-Log -Error "Failed to ensure work directory on the VM: $_"
        Remove-Item -Path $localQuickPath -ErrorAction SilentlyContinue
        Exit 1
    }

    if (-not $toolsAvailableForQuickCheck) {
        Write-Log -Warn "VMware Tools not available for quick-check; cannot reliably detect whether cloud-init ran in this boot. Proceeding to normal cloud-init completion polling as a fallback."
    } else {
        # Replace placeholder and output locally (with LF line endings)
        $qcContent = $quickCheckTpl.Replace('{{SEED_TS}}', [string]$seedAttachEpoch)
        Set-Content -Path $localQuickPath -Value $qcContent -Encoding UTF8 -Force
        # normalize CRLF -> LF and write as UTF-8 without BOM
        $txt = Get-Content -Raw -Path $localQuickPath -Encoding UTF8
        $txt = $txt -replace "`r`n", "`n"
        $txt = $txt -replace "`r", "`n"
        [System.IO.File]::WriteAllText($localQuickPath, $txt, (New-Object System.Text.UTF8Encoding($false)))
        Write-Verbose "Output quick-check script locally: '$localQuickPath'"

        # Copy quick-check script to the VM
        $maxQCAttempts = 3
        $qcAttempt = 0
        $qcCopied = $false

        Write-Log "Copying quick-check script to the VM..."
        while (-not $qcCopied -and $qcAttempt -lt $maxQCAttempts) {
            $qcAttempt++
            try {
                $null = Copy-VMGuestFile -LocalToGuest -Source $localQuickPath -Destination $guestQuickPath `
                    -VM $vm -GuestUser $guestUser -GuestPassword $guestPass -Force -ErrorAction Stop
                $phase3cmd = @"
sudo /bin/bash -c "chmod +x $guestQuickPath"
"@
                $null = Invoke-VMScript -VM $vm -ScriptText $phase3cmd -ScriptType Bash `
                    -GuestUser $guestUser -GuestPassword $guestPass -ErrorAction Stop
                $qcCopied = $true
                Write-Log "Copied quick-check script to the VM: '$guestQuickPath' (attempt: $qcAttempt)"
            } catch {
                Write-Verbose "Copy-VMGuestFile for quick-check failed (attempt: $qcAttempt): $_"
                # try waiting for tools briefly and retry
                $toolsOk2 = Wait-ForVMwareTools -VM $vm -TimeoutSec 10 -PollIntervalSec 2
                if (-not $toolsOk2) {
                    Write-Verbose "VMware Tools still unavailable; sleeping before next quick-check copy attempt..."
                    Start-Sleep -Seconds 5
                } else {
                    Write-Verbose "VMware Tools recovered; retrying quick-check copy..."
                }
            }
        }

        # Remove local quick script
        Remove-Item -Path $localQuickPath -ErrorAction SilentlyContinue

        $qcExecuted = $false

        if (-not $qcCopied) {
            Write-Log -Warn "Failed to upload quick-check script to the VM after $maxQCAttempts attempts; as a fallback, proceeding to normal cloud-init completion polling."
        } else {
            # Execute quick-check on guest and collect output
            try {
                Write-Log "Performing quick check to collect clout-init base status..."
                $qcExecCmd = "sudo /bin/bash '$guestQuickPath'"
                $qcRes = Invoke-VMScript -VM $vm -ScriptText $qcExecCmd -ScriptType Bash `
                    -GuestUser $guestUser -GuestPassword $guestPass -ErrorAction Stop
                $qcExecuted = $true
            } catch {
                Write-Log -Warn "Quick-check execution failed (Invoke-VMScript error): $_. Proceeding with normal cloud-init completion polling."
            }

            if ($qcExecuted) {
                # Collect stdout primarily and use stderr as fallback; optionally log stderr.
                $qcStdout = ""
                $qcStderr = ""
                if ($qcRes.ScriptOutput -and $qcRes.ScriptOutput.Count -gt 0) {
                    $qcStdout = ($qcRes.ScriptOutput -join [Environment]::NewLine).Trim()
                } elseif ($qcRes.ScriptError -and $qcRes.ScriptError.Count -gt 0) {
                    $qcStderr = ($qcRes.ScriptError -join [Environment]::NewLine).Trim()
                    Write-Verbose "quick-check stderr: $qcStderr"
                    $qcStdout = $qcStderr
                }

                # Take first non-empty line from qcStdout (guard against multi-line noise)
                $firstLine = ""
                if ($qcStdout) {
                    $firstLine = ($qcStdout -split "`r?`n" | Where-Object { $_.Trim() -ne "" } | Select-Object -First 1).Trim()
                }

                # Extract required fields: label, path, optional instance-id if contained in qcStdout
                $currentInstanceId = $null
                $evidencePath = $null
                $label = $null

                if ($firstLine -and ($firstLine -match '^(?<label>[^:]+):(?<path>[^;]+)(?:;(?<inst>.+))?$')) {
                    $label = $matches['label']
                    $evidencePath = $matches['path'].Trim()
                    if ($matches['inst']) { $currentInstanceId = $matches['inst'].Trim() }
                    Write-Verbose "quick-check parsed: label=$label, evidence=$evidencePath, instance=$currentInstanceId"
                } elseif ($firstLine) {
                    Write-Verbose "quick-check: unrecognized stdout format: '$firstLine'"
                }

                if ($currentInstanceId) {
                    Write-Log "Current cloud-init instance-id: $currentInstanceId"
                }

                try {
                    $null = Invoke-VMScript -VM $vm -ScriptText "rm -f $guestQuickPath" -ScriptType Bash `
                        -GuestUser $guestUser -GuestPassword $guestPass -ErrorAction Stop
                    Write-Log "Removed quick-check script from the VM: $guestQuickPath"
                } catch {
                    Write-Log -Warn "Failed to remove quick-check script from the VM: $_"
                }

                switch ($qcRes.ExitCode) {
                    2 {
                        Write-Log -Error "Quick-check reported TERMINAL (exit code 2). stdout: '$firstLine' stderr: '$qcStderr'"
                        Write-Log -Warn "Phase 3 complete (cloud-init activation NOT confirmed)."
                        Exit 2
                    }
                    1 {
                        Write-Log -Warn "Quick-check: guest returned NOTRAN (exit code 1). stdout: '$firstLine' stderr: '$qcStderr'"
                        Write-Log -Warn "Phase 3 complete (cloud-init activation NOT confirmed)."
                        Exit 2
                    }
                    0 {
                        # Success: Use the parsed label to decide action
                        switch ($label) {
                            'RAN-SEM' {
                                Write-Log "Quick-check: cloud-init activation detected; success by module sem; evidence: $evidencePath. Proceeding to cloud-init completion polling."
                            }
                            'RAN' {
                                Write-Log "Quick-check: cloud-init activation detected; success by cloud-init artifacts; evidence: $evidencePath. Proceeding to cloud-init completion polling."
                            }
                            'RAN-NET' {
                                Write-Log "Quick-check: cloud-init activation detected; success by network-config; evidence: $evidencePath. As this is a weak evidence, proceeding to cloud-init completion polling with reduced wait (60s)."
                                $cloudInitWaitTotalSec = [int]([math]::Max(30, [math]::Min($cloudInitWaitTotalSec, 60)))
                            }
                            default {
                                # ExitCode 0 but no recognised token -> fold-down policy (continue polling with shorten wait)
                                Write-Log -Warn "Quick-check: ExitCode 0 but stdout missing expected token (stdout='$firstLine', qcStderr='$qcStderr')"
                                Write-Log -Warn "Proceeding to cloud-init completion check with reduced wait to avoid pointless long polling; operator should investigate."
                                $cloudInitWaitTotalSec = [int]([math]::Max(30, [math]::Min($cloudInitWaitTotalSec, 60)))
                                # fall through to normal polling
                            }
                        }
                    }
                    default {
                        # Unexpected exit code — be conservative
                        Write-Log -Error "Quick-check: failed to probe cloud-init activation; unexpected exit code $($qcRes.ExitCode). stdout: '$qcStdout' stderr: '$qcStderr'. Aborting Phase-3."
                        Exit 2
                    }
                }
            }
        }
    }

    #--- The real cloud-init completion check.
    Write-Log "Preparing cloud-init completion check script..."

    $localCheckPath = Join-Path $workdir "check-cloud-init.sh"
    $guestCheckPath = "$workDirOnVM/check-cloud-init.sh"

    # Template for guest checker. Use {{SEED_TS}} placeholder and replace locally.
    $cloudInitCheckScript = @'
#!/bin/bash
# check-cloud-init.sh - return READY:reason when cloud-init for this seed attach is finished
# Exit codes:
#   0 = READY (success for one of tests)
#   1 = NOTREADY (not finished)
#   2 = TERMINAL (cloud-init disabled or other terminal condition)
if [ -f /etc/cloud/cloud-init.disabled ]; then
  echo "TERMINAL:cloud-init-disabled"
  exit 2
fi
if command -v cloud-init >/dev/null 2>&1; then
  if cloud-init status --wait >/dev/null 2>&1; then
    echo "READY:cloud-init-status"
    exit 0
  fi
fi
if systemctl show -p SubState --value cloud-final 2>/dev/null | grep -q ^exited$; then
  echo "READY:systemd-cloud-final-exited"
  exit 0
fi
if [ -f /var/lib/cloud/instance/boot-finished ]; then
  file_ts=$(stat -c %Y /var/lib/cloud/instance/boot-finished 2>/dev/null || echo 0)
  if [ "$file_ts" -gt {{SEED_TS}} ]; then
    echo "READY:boot-finished-after-seed"
    exit 0
  fi
fi
echo "NOTREADY"
exit 1
'@

    # Replace placeholder with the ISO attach epoch and output script locally (with LF line endings)
    $cloudInitCheckScript = $cloudInitCheckScript.Replace('{{SEED_TS}}', [string]$seedAttachEpoch)
    Set-Content -Path $localCheckPath -Value $cloudInitCheckScript -Encoding UTF8 -Force
    # normalize CRLF -> LF and write as UTF-8 without BOM
    $txt = Get-Content -Raw -Path $localCheckPath -Encoding UTF8
    $txt = $txt -replace "`r`n", "`n"
    $txt = $txt -replace "`r", "`n"
    [System.IO.File]::WriteAllText($localCheckPath, $txt, (New-Object System.Text.UTF8Encoding($false)))
    Write-Verbose "Output check script locally: '$localCheckPath'"

    # Copy the local script to the VM with retries (tools may still be flaky)
    $maxAttempts = 4
    $attempt = 0
    $copied = $false

    Write-Log "Copying check script to the VM..."
    while (-not $copied -and $attempt -lt $maxAttempts) {
        $attempt++
        try {
            $null = Copy-VMGuestFile -LocalToGuest -Source $localCheckPath -Destination $guestCheckPath `
                -VM $vm -GuestUser $guestUser -GuestPassword $guestPass -Force -ErrorAction Stop
            $phase3cmd = @"
sudo /bin/bash -c "chmod +x $guestCheckPath"
"@
            $null = Invoke-VMScript -VM $vm -ScriptText $phase3cmd -ScriptType Bash `
                -GuestUser $guestUser -GuestPassword $guestPass -ErrorAction stop
            $copied = $true
            Write-Log "Copied check script to the VM: '$guestCheckPath' (attempt: $attempt)"
        } catch {
            Write-Verbose "Copy-VMGuestFile failed (attempt: $attempt): $_"
            # try waiting for tools briefly and retry
            $toolsOk2 = Wait-ForVMwareTools -VM $vm -TimeoutSec 30
            if (-not $toolsOk2) {
                Write-Verbose "VMware Tools still unavailable; sleeping before next copy attempt..."
                Start-Sleep -Seconds 10
            } else {
                Write-Verbose "VMware Tools recovered; retrying copy..."
            }
        }
    }

    # clean up local check script
    Remove-Item -Path $localCheckPath -ErrorAction SilentlyContinue

    if (-not $copied) {
        Write-Log -Error "Failed to upload check script to the VM after $maxAttempts attempts."
        Write-Log -Error "Phase-3 ends: VM started with seed ISO but cloud-init completion NOT confirmed."
        if ($Phase -contains 4) {
            Write-Log -Error "Aborting without proceeding to Phase-4."
        }
        Exit 2
    }

    # Poll the script until it returns decision or timeout
    $elapsed = 0
    $cloudInitDone = $false
    $checkExecuted = $false
    $cloudInitDisabled = $false

    Write-Log "Waiting for cloud-init to finish inside VM, polling $guestCheckPath (max ${cloudInitWaitTotalSec}s)..."

    :cmppoll while ($elapsed -lt $cloudInitWaitTotalSec) {
        try {
            $execCmd = "sudo /bin/bash '$guestCheckPath'"
            $res = Invoke-VMScript -VM $vm -ScriptText $execCmd -ScriptType Bash `
                -GuestUser $guestUser -GuestPassword $guestPass -ErrorAction Stop
            $checkExecuted = $true
        } catch {
            Write-Log -Warn "Cloud-init completion check execution failed (Invoke-VMScript error): $_"
        }

        if ($checkExecuted) {
            # Collect stdout primarily and use stderr as fallback; optionally log stderr.
            $stdout = ""
            $stderr = ""
            if ($res.ScriptOutput -and $res.ScriptOutput.Count -gt 0) {
                $stdout = ($res.ScriptOutput -join [Environment]::NewLine).Trim()
            } elseif ($qcRes.ScriptError -and $res.ScriptError.Count -gt 0) {
                $stderr = ($res.ScriptError -join [Environment]::NewLine).Trim()
                Write-Verbose "completion check script stderr: $stderr"
                $stdout = $stderr
            }

            # Take first non-empty line from stdout (guard against multi-line noise)
            $firstLine = ""
            if ($stdout) {
                $firstLine = ($stdout -split "`r?`n" | Where-Object { $_.Trim() -ne "" } | Select-Object -First 1).Trim()
            }

            $label=""
            $evidence=""
            if ($firstLine -and ($firstLine -match '^(?<label>[^:]+):(?<evidence>[^;]+)$')) {
                $label = $matches['label']
                $evidence = $matches['evidence'].Trim()
                Write-Verbose "Completion check parsed: label=$label, evidence=$evidence"
            } elseif ($firstLine) {
                Write-Verbose "Completion check: unrecognized stdout format: '$firstLine'"
            }

            switch ($res.ExitCode) {
                0 {
                    Write-Log "Detected cloud-init completion on guest (evidence: $evidence)."
                    $cloudInitDone = $true
                    break cmppoll
                }
                2 {
                    Write-Log -Warn "Check reported TERMINAL (exit code 2): cloud-init is disabled by /etc/cloud/cloud-init.disabled"
                    Write-Log -Warn "Phase 3 complete (cloud-init may NOT have been effective)."
                    if ($Phase -contains 4) {
                        Write-Log -Error "Aborting without proceeding to Phase-4 to avoid pointless operation."
                    }
                    $cloudInitDisabled = $true
                    break cmppoll
                }
                default {
                    # NOTREADY (ExitCode 1/(!= 0))
                    Write-Verbose "cloud-init not yet finished."
                }
            }
        }

        Write-Verbose "Waiting up to ${toolsWaitSec}s for VMware Tools to recover (poll interval ${toolsPollSec}s)..."

        $toolsBack = Wait-ForVMwareTools -VM $vm -TimeoutSec $toolsWaitSec -PollIntervalSec $toolsPollSec
        if (-not $toolsBack) {
            Write-Verbose "VMware Tools did not recover within ${toolsWaitSec}s; will retry completion check after the normal poll sleep."
        } else {
            Write-Verbose "VMware Tools recovered; retrying guest check immediately."
        }

        Start-Sleep -Seconds $cloudInitPollSec
        $elapsed += $cloudInitPollSec
    }

    try {
        $null = Invoke-VMScript -VM $vm -ScriptText "rm -f $guestCheckPath" -ScriptType Bash `
            -GuestUser $guestUser -GuestPassword $guestPass -ErrorAction Stop
        Write-Log "Removed check script from the VM: $guestCheckPath"
    } catch {
        Write-Verbose "Failed to remove check script from the VM: $_"
    }

    if (-not $cloudInitDone) {
        if (-not $cloudInitDisabled) {
            Write-Log -Error "cloud-init was triggered at VM startup, but it could not be confirmed the VM has completed applying the personalization within expected timeframe: ${cloudInitWaitTotalSec}s"
            if ($Phase -contains 4) {
                Write-Log -Error "Aborting without proceeding to Phase-4 to avoid detaching the seed ISO before cloud-init completion."
            }
        }
        Exit 2
    }

    Write-Log "Phase 3 complete"
}

# ---- Phase 4: Clean up and Finalize the deployed VM ----
function CloseDeploy {
    Write-Log "=== Phase 4: Cleanup and Finalization ==="

    # 1. Get VM object
    $vm = TryGet-VMObject $new_vm_name
    if (-not $vm) {
        Write-Log -Error "Target VM not found: '$new_vm_name'"
        Exit 1
    }

    # 2. Get datacenter, datastore, and seed ISO path (same logic as Phase 3)
    $seedIsoCopyStore = $params.seed_iso_copy_store.TrimEnd('/').TrimEnd('\')
    $datacenterName = $params.datacenter_name

    if (-not $seedIsoCopyStore) {
        Write-Log -Error "Parameter 'seed_iso_copy_store' is not set. Please check your parameter file."
        Exit 2
    }
    if (-not $datacenterName) {
        Write-Log -Error "Parameter 'datacenter_name' is not set. Please check your parameter file."
        Exit 2
    }

    # Split into datastore name and folder path (same as Phase 3)
    if ($seedIsoCopyStore -match "^\[(.+?)\]\s*(.+)$") {
        $datastoreName = $matches[1]
        $datastoreFolder = $matches[2].Trim('/')
    } else {
        Write-Log -Error "Invalid format for parameter 'seed_iso_copy_store': $seedIsoCopyStore"
        Exit 2
    }

    $vmstoreFolderPath = "vmstore:\$datacenterName\$datastoreName\$datastoreFolder"
    $vmstoreIsoPath = "$vmstoreFolderPath\$seedIsoName"

    # 3. Detach seed ISO from VM's CD drive
    $cdd = Get-CDDrive -VM $vm
    if (-not $cdd) {
        Write-Log -Warn "No CD/DVD drive found on this VM."
    } else {
        try {
            $null = Set-CDDrive -CD $cdd -NoMedia -Confirm:$false -ErrorAction Stop
            Write-Log "Seed ISO media is detached from the VM: '$new_vm_name'"
        } catch {
            Write-Log -Warn "Failed to detach CD/DVD drive from VM: $_"
        }
    }

    # 4. Remove seed ISO file from datastore (use Remove-Item on vmstore: path)
    if (Test-Path "$vmstoreIsoPath") {
        try {
            Remove-Item -Path $vmstoreIsoPath -Force
            Write-Log "Removed seed ISO from datastore: '$vmstoreIsoPath'"
        } catch {
            Write-Log -Warn "Failed to remove seed ISO '$vmstoreIsoPath' from datastore: $_"
        }
    } else {
        Write-Log "Seed ISO file not found in datastore for removal: '$vmstoreIsoPath'"
    }

    # 5. Disable cloud-init for future boots (unless -NoCloudReset switch is specified)
    if (-not $NoCloudReset) {
        $vm = TryGet-VMObject $new_vm_name
        if (-not $vm) {
            Write-Log -Error "Unable to refresh VM object while preparing to disable cloud-init: '$new_vm_name'; Phase-4 aborted."
            Exit 1
        }

        if ($NoRestart -and ($vm.PowerState -ne "PoweredOn")) {
            Write-Log "Skipped deactivation of cloud-init; NoRestart specified and VM is not PoweredOn."
        } else {
            # Normal behaviour: wait for VMware Tools and attempt to create cloud-init.disabled.
            $toolsOk = Wait-ForVMwareTools -VM $vm -TimeoutSec 30
            if (-not $toolsOk) {
                Write-Log -Error "Unable to disable cloud-init since VMware Tools is NOT running. Make sure the VM is powered on and rerun Phase-4."
                Exit 1
            }

            # Prepare username and password for VM commands
            $guestUser = $params.username
            $guestPassPlain = $params.password
            $guestPass = ConvertToSecureStringFromPlain $guestPassPlain
            if (-not $guestPass) {
                Write-Log -Error "Failed to convert guest password to SecureString. Aborting in Phase-4."
                Exit 3
            }

            try {
                $phase4cmd = @'
sudo /bin/bash -c "install -m 644 /dev/null /etc/cloud/cloud-init.disabled"
'@
                $null = Invoke-VMScript -VM $vm -ScriptText $phase4cmd -GuestUser $guestUser `
                    -GuestPassword $guestPass -ScriptType Bash -ErrorAction Stop
                Write-Log "Created /etc/cloud/cloud-init.disabled to prevent future cloud-init invocation."
            } catch {
                Write-Log -Error "Failed to create cloud-init.disabled file: $_"
            }
        }
    } else {
        Write-Log "Skipped deactivation of cloud-init due to -NoCloudReset switch."
    }

    Write-Log "Phase 4 complete"
}

# ---- Phase dispatcher (add phase 3) ----
foreach ($p in $phaseSorted) {
    switch ($p) {
        1 { AutoClone }
        2 { InitializeClone }
        3 { CloudInitKickStart }
        4 { CloseDeploy }
    }
}

Write-Log "Deployment script completed."

