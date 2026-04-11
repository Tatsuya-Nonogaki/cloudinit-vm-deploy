<#
 .DESCRIPTION
  Function library to connect to vSphere vCenter Server.
  Version: 1.2

  Requirements:
    The parent script must define variables such as
    $vcserver, $vcport, $vcuser, $vcpasswd, $Vault, $VaultDefault, $connRetry, $connRetryInterval, etc.
#>

Function isPlainMode {
    <#
      .SYNOPSIS
        Returns $true when plain password mode should be used.

      .DESCRIPTION
        Checks whether $vcpasswd is defined and non-empty. If so, the caller
        should use VIConnectPlain instead of SecretStore / VICredentialStore.
    #>
    if ($vcpasswd -and $vcpasswd.Length -gt 0) {
        return $true
    }
    return $false
}

Function VIConnectPlain {
    <#
      .SYNOPSIS
        Connects to vCenter using plain password from the parent script.

      .DESCRIPTION
        This function implements the connection logic for "plain password mode".
        It expects $vcserver, $vcport, $vcuser, $vcpasswd, $connRetry, and
        $connRetryInterval to be defined in the parent script.

        Typical usage:
          - $vcpasswd is defined in the parent script.
          - Newer connection functions (VIConnect / VIConnectLegacy) delegate
            to VIConnectPlain when isPlainMode returns true.

        It does not use SecretStore, VISecret, or VICredentialStore.
    #>
    PROCESS {
        #---------------------------
        # Basic parameter checks
        #---------------------------
        if (-not $vcserver -or $vcserver.Length -lt 1) {
            Write-Error '$vcserver is not set. Please check the parent script.'
            Exit 40
        }
        if (-not $vcuser -or $vcuser.Length -lt 1) {
            Write-Error '$vcuser is not set. Please specify the vCenter login user in the parent script.'
            Exit 41
        }
        if (-not $vcpasswd -or $vcpasswd.Length -lt 1) {
            Write-Error '$vcpasswd is not set. Plain password mode requires a password in the parent script.'
            Exit 42
        }

        #---------------------------
        # Connection retry loop (plain password)
        #---------------------------
        for ($i = 1; $i -le $connRetry; $i++) {
            Write-Output "Connect-VIServer $vcserver -Port $vcport -User $vcuser -Password ******** -Force (plain password mode)"
            Connect-VIServer $vcserver -Port $vcport -User $vcuser -Password $vcpasswd -Force `
                -WarningAction SilentlyContinue -ErrorAction Continue -ErrorVariable myErr

            if ($?) {
                # Connection succeeded
                return
            }

            if ($i -eq $connRetry) {
                Write-Output "Connection attempts exceeded retry limit (plain password mode)."
                Exit 43
            }

            Write-Output "Waiting $connRetryInterval seconds before retry (plain password mode)...`r`n"
            Start-Sleep -Seconds $connRetryInterval
        }
    }
}

Function VIConnect {
    <#
      .SYNOPSIS
        Connects to vCenter using SecretStore / VISecret (or falls back to plain mode if configured).

      .DESCRIPTION
        Modern connection function for environments that use the new
        Microsoft.PowerShell.SecretManagement / SecretStore stack together
        with the VMware.VISecret module.

        Behavior:
          - If isPlainMode() returns $true (i.e. $vcpasswd is set), the function
            delegates to VIConnectPlain and returns.
          - Otherwise, it expects a SecretVault (e.g. "VMwareSecretStore") to be
            configured and accessible via SecretManagement and VMware.VISecret.
          - On the first run without an existing secret, it prompts for the
            password. If the script global switch parameter 'UpdatePassword' is
            set and the connection succeeds, the secret will be updated or created
            for future runs.

        Requirements:
          - the parent script must define at least:
              $vcserver, $vcport, $vcuser, $connRetry, $connRetryInterval, $VaultDefault
            and optionally:
              $Vault
          - Modules:
              Microsoft.PowerShell.SecretManagement
              VMware.VISecret
    #>
    PROCESS {
        #---------------------------
        # Basic parameter checks
        #---------------------------
        if (-not $vcserver -or $vcserver.Length -lt 1) {
            Write-Error '$vcserver is not set. Please check the parent script.'
            Exit 10
        }
        if (-not $vcuser -or $vcuser.Length -lt 1) {
            Write-Error '$vcuser is not set. Please specify the vCenter login user in the parent script.'
            Exit 11
        }

        #---------------------------
        # Plain password short-circuit
        #---------------------------
        if (isPlainMode) {
            Write-Verbose "Using plain password mode from the parent script (delegated to VIConnectPlain)."
            VIConnectPlain
            return
        }

        #---------------------------
        # Secret / Vault mode (no plain password)
        #---------------------------

        # Determine Vault name
        if (-not $Vault -or $Vault.Length -lt 1) {
            # If the parent script does not define $Vault, fall back to script default
            if (-not $VaultDefault -or $VaultDefault.Length -lt 1) {
                Write-Error "SecretStore is intended to be used but both `$Vault and `$VaultDefault are empty. Please set one of them."
                Exit 19
            }
            $Vault = $VaultDefault
            Write-Verbose "Vault not specified in the parent script. Using default Vault name: '$Vault'"
        } else {
            Write-Verbose "Using Vault name from the parent script: '$Vault'"
        }

        # Verify required modules (only once, before retry loop)
        if (-not (Get-Module -ListAvailable Microsoft.PowerShell.SecretManagement)) {
            Write-Error "Microsoft.PowerShell.SecretManagement module is not available. Ensure it is installed."
            Exit 20
        }
        if (-not (Get-Module -ListAvailable Microsoft.PowerShell.SecretStore)) {
            Write-Error "Microsoft.PowerShell.SecretStore module is not available. Ensure it is installed."
            Exit 21
        }

        # Verify VISecret module (try to import automatically if not loaded)
        if (-not (Get-Module VMware.VISecret)) {
            if (Get-Module -ListAvailable VMware.VISecret) {
                Write-Output "Loading VMware.VISecret module..."
                try {
                    Import-Module VMware.VISecret -ErrorAction Stop
                }
                catch {
                    Write-Error "Failed to import VMware.VISecret module even though it is available: $($_.Exception.Message)"
                    Exit 22
                }
            }
            else {
                Write-Error 'VMware.VISecret module is not available. Place Modules/VISecret from GitHub: @vmware-archive/PowerCLI-Example-Scripts onto PSModulePath as VMware.VISecret.'
                Exit 22
            }
        }

        # Verify Vault existence (only once)
        $vaultInfo = Get-SecretVault -Name $Vault -ErrorAction SilentlyContinue
        if (-not $vaultInfo) {
            Write-Error "SecretVault '$Vault' is not registered. Set it up using Initialize-VISecret (see comments in the parent script for more detail)."
            Exit 22
        }

        #---------------------------
        # Connection retry loop (Secret / Vault mode)
        #---------------------------
        Write-Verbose "Using modern SecretStore/Vault mode."

        for ($i = 1; $i -le $connRetry; $i++) {

            $connectionSucceeded = $false

            try {
                if ($i -eq 1) {
                    # First attempt: use existing secret
                    Write-Output "Connect-VIServerWithSecret -Server $vcserver -User $vcuser -Vault $Vault"
                }
                else {
                    # Subsequent retries: same call, but log attempt count
                    Write-Output "Retrying Connect-VIServerWithSecret -Server $vcserver -User $vcuser -Vault $Vault (attempt $i)"
                }

                Connect-VIServerWithSecret -Server $vcserver -User $vcuser -Vault $Vault `
                    -WarningAction SilentlyContinue -ErrorAction Stop
                $connectionSucceeded = $true
            }
            catch {
                if ($i -eq 1) {
                    # Only on the first attempt we optionally register/update the secret interactively
                    Write-Warning "Secret for $vcuser / $vcserver in vault '$Vault' is missing or cannot be used."

                    Write-Output "You may now enter the password for $vcuser at ${vcserver}"
                    if ($UpdatePassword) {
                        Write-Output "It will be stored in SecretVault '$Vault' on successful connection."
                    }

                    $cred = Get-Credential -UserName $vcuser -Message "Enter password for $vcuser at $vcserver"
                    if (-not $cred) {
                        Write-Warning "Connection via secret failed (attempt $i): no password was provided at the prompt."
                        continue
                    }

                    if ($UpdatePassword) {
                        # Update / create stored secret
                        try {
                            Write-Output "Connect-VIServerWithSecret -Server $vcserver -Credential **** -Vault $Vault -SaveCredentials"
                            Connect-VIServerWithSecret -Server $vcserver -Credential $cred -Vault $Vault -SaveCredentials `
                                -WarningAction SilentlyContinue -ErrorAction Stop
                            $connectionSucceeded = $true
                        }
                        catch {
                            Write-Warning "Initial connection with SaveCredentials failed: $($_.Exception.Message)"
                        }
                    }
                    else {
                        # One-time connection without changing the stored secret
                        try {
                            Write-Output "Connect-VIServerWithSecret -Server $vcserver -Credential **** -Vault $Vault (one-time, no SaveCredentials)"
                            Connect-VIServerWithSecret -Server $vcserver -Credential $cred -Vault $Vault `
                                -WarningAction SilentlyContinue -ErrorAction Stop
                            $connectionSucceeded = $true
                        }
                        catch {
                            Write-Warning "One-time connection with interactive password failed: $($_.Exception.Message)"
                        }
                    }
                }
                else {
                    Write-Warning "Connection via secret failed (attempt $i): $($_.Exception.Message)"
                }
            }

            if ($connectionSucceeded) {
                break
            }

            if ($i -eq $connRetry) {
                Write-Output "Connection attempts exceeded retry limit."
                Exit 1
            }

            Write-Output "Waiting $connRetryInterval seconds before retry...`r`n"
            Start-Sleep -Seconds $connRetryInterval
        }
    }
}

Function VIConnectLegacy {
    <#
      .SYNOPSIS
        Connects to vCenter using VICredentialStore (or falls back to plain mode if configured).

      .DESCRIPTION
        Legacy connection function for environments that still rely on the
        classic VICredentialStore mechanism (typically on Windows PowerShell 5.1
        without SecretManagement / SecretStore).

        Behavior:
          - If isPlainMode() returns $true (i.e. $vcpasswd is set), the function
            delegates to VIConnectPlain and returns.
          - Otherwise, it tries to connect using existing VICredentialStore
            entries for ($vcserver, $vcuser).
          - On the first failure, it prompts for credentials, tries to connect,
            and if the script global switch parameter 'UpdatePassword' is set and
            the connection succeeds, updates or creates a VICredentialStore item
            for future runs.

        Requirements:
          - the parent script must define at least:
              $vcserver, $vcport, $vcuser, $connRetry, $connRetryInterval
          - PowerCLI must be available (VMware.VimAutomation.Core), including
            VICredentialStore cmdlets such as New-VICredentialStoreItem.
    #>
    PROCESS {
        #---------------------------
        # Basic parameter checks
        #---------------------------
        if (-not $vcserver -or $vcserver.Length -lt 1) {
            Write-Error '$vcserver is not set. Please check the parent script.'
            Exit 30
        }
        if (-not $vcuser -or $vcuser.Length -lt 1) {
            Write-Error '$vcuser is not set. Please specify the vCenter login user in the parent script.'
            Exit 31
        }

        #---------------------------
        # Plain password short-circuit
        #---------------------------
        if (isPlainMode) {
            Write-Verbose "Using plain password mode from the parent script (legacy, delegated to VIConnectPlain)."
            VIConnectPlain
            return
        }

        #---------------------------
        # VICredentialStore mode (no plain password)
        #---------------------------
        Write-Verbose "Using Legacy VICredentialStore mode."

        for ($i = 1; $i -le $connRetry; $i++) {

            $connectionSucceeded = $false

            try {
                if ($i -eq 1) {
                    # First attempt: try to use an existing credential from the VICredentialStore
                    Write-Output "Connect-VIServer $vcserver -Port $vcport -User $vcuser -Force (VICredentialStore)"
                }
                else {
                    Write-Output "Retrying Connect-VIServer $vcserver -Port $vcport -User $vcuser -Force (VICredentialStore, attempt $i)"
                }

                Connect-VIServer $vcserver -Port $vcport -User $vcuser -Force `
                    -WarningAction SilentlyContinue -ErrorAction Stop
                $connectionSucceeded = $true
            }
            catch {
                if ($i -eq 1) {
                    # On the first failure, fall back to interactive credential input
                    Write-Warning "VICredentialStore-based connection as $vcserver for $vcuser failed or no stored credential was found."
                    Write-Output "You may now enter the password for $vcuser at ${vcserver}"
                    if ($UpdatePassword) {
                        Write-Output "If the connection succeeds, it will be stored in the VICredentialStore for future runs."
                    }

                    # Prompt for credentials
                    $cred = Get-Credential -UserName $vcuser -Message "Enter password for $vcuser at $vcserver"
                    if (-not $cred) {
                        Write-Warning "VICredentialStore-based connection failed (attempt $i): no password was provided at the prompt."
                        continue
                    }

                    # Try to connect once with the provided credential
                    try {
                        Write-Output "Connect-VIServer $vcserver -Port $vcport -User $vcuser -Force (interactive credential)"
                        Connect-VIServer $vcserver -Port $vcport -Credential $cred -Force `
                            -WarningAction SilentlyContinue -ErrorAction Stop
                        $connectionSucceeded = $true
                    }
                    catch {
                        Write-Warning "Initial connection with interactive credential failed: $($_.Exception.Message)"
                    }

                    # Only if the interactive connection succeeded, optionally update VICredentialStore
                    if ($connectionSucceeded) {
                        if ($UpdatePassword) {
                            try {
                                Write-Output "Updating VICredentialStore entry for $vcuser / $vcserver"
                                New-VICredentialStoreItem -Host $vcserver -User $vcuser -Password ($cred.GetNetworkCredential().Password) `
                                    -ErrorAction SilentlyContinue | Out-Null
                                Write-Output "VICredentialStore entry for $vcuser / $vcserver has been updated successfully."
                            }
                            catch {
                                Write-Warning "Failed to update VICredentialStore item for $vcuser / ${vcserver}: $($_.Exception.Message)"
                            }
                        }
                        else {
                            Write-Output "Interactive connection succeeded, but VICredentialStore will NOT be updated because -UpdatePassword was not specified."
                        }
                    }
                    else {
                        Write-Warning "Skipping VICredentialStore update because the interactive connection did not succeed."
                    }
                }
                else {
                    Write-Warning "VICredentialStore-based connection failed (attempt $i): $($_.Exception.Message)"
                }
            }

            if ($connectionSucceeded) {
                break
            }

            if ($i -eq $connRetry) {
                Write-Output "Connection attempts exceeded retry limit (legacy mode)."
                Exit 32
            }

            Write-Output "Waiting $connRetryInterval seconds before retry (legacy mode)...`r`n"
            Start-Sleep -Seconds $connRetryInterval
        }
    }
}

Function VIDisconnect {
    <#
      .SYNOPSIS
        Disconnects from vCenter.

      .DESCRIPTION
        Disconnects the current vCenter session for both modern and legacy connection modes.
    #>
    try {
        Disconnect-VIServer -Server $vcserver -Confirm:$false
    }
    catch {
        Write-Warning "Failed to disconnect from ${vcserver}: $($_.Exception.Message)"
    }
}
