<#
.SYNOPSIS
    Manages secure restic credential vaults for the SYSTEM account.

.DESCRIPTION
    Creates a DPAPI-encrypted vault file that only the NT AUTHORITY\SYSTEM 
    account can decrypt. This replaces plain-text secrets with secure 
    identity-bound storage.
    Requires an ELEVATED PowerShell session (Run as Administrator).

.EXAMPLE
    .\VaultManager.ps1 (Standalone creation flow)
    . .\VaultManager.ps1; Export-VaultToEnv (Orchestration/Usage)
#>

param (
    [Parameter(HelpMessage="Enter the filename or path for the vault.")]
    [string]$VaultFile = "secrets.vault"
)

# Fast-fail if not Administrator
if (-not ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Write-Error "[[Vault]] This script must be run as an Administrator."
    if ($MyInvocation.InvocationName -eq '.') { return } else { exit 1 }
}

function New-ResticVault {
    <#
    .SYNOPSIS
        Collects restic secrets and triggers a SYSTEM task to encrypt them into a vault.
    #>
    param (
        [string]$VaultFile = (Join-Path $PSScriptRoot "secrets.vault")
    )

    $VaultFile = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($VaultFile)

    $VaultData = @{}
    Write-Host "[[Vault]] Creating secure vault for SYSTEM..."

    # restic repo password (mandatory)
    $PasswordsMatch = $false
    while (-not $PasswordsMatch) {
        $PasswordInput = Read-Host "Enter restic repository password" -AsSecureString
        if ($null -eq $PasswordInput) { 
            Write-Host "[[Error]] Restic Password is required." -ForegroundColor Yellow
            continue 
        }

        $ConfirmInput = Read-Host "Confirm restic repository password" -AsSecureString

        # Unwrap to compare
        $Ptr1 = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($PasswordInput)
        $Ptr2 = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($ConfirmInput)
        try {
            $Plain1 = [Runtime.InteropServices.Marshal]::PtrToStringAuto($Ptr1)
            $Plain2 = [Runtime.InteropServices.Marshal]::PtrToStringAuto($Ptr2)

            if ($Plain1 -eq $Plain2) {
                $VaultData["RESTIC_PASSWORD"] = $Plain1
                $PasswordsMatch = $true
            } else {
                Write-Host "[[Error]] Passwords do not match. Please try again." -ForegroundColor Yellow
            }
        } finally {
            [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($Ptr1)
            [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($Ptr2)
        }
    }

    # Email password (optional)
    $EmailPassInput = Read-Host "Enter Email/SMTP Password (Optional - Press Enter to skip)" -AsSecureString
    if ($EmailPassInput -and $EmailPassInput.Length -gt 0) {
        $BSTR = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($EmailPassInput)
        $VaultData["RESTIC_EMAIL_PASSWORD"] = [Runtime.InteropServices.Marshal]::PtrToStringAuto($BSTR)
    }

    # Other restic environment variable-secret pairs (optional)
    Write-Host "Add other variables (e.g. AWS_ACCESS_KEY_ID, AZURE_ACCOUNT_KEY, etc.)"
    while ($true) {
        $VarName = Read-Host "Variable Name [Press Enter to finish]"
        if ([string]::IsNullOrWhiteSpace($VarName)) { break }

        $VarSecret = Read-Host "Value for $VarName" -AsSecureString
        $BSTR = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($VarSecret)
        $VaultData[$VarName] = [Runtime.InteropServices.Marshal]::PtrToStringAuto($BSTR)
    }

    # Save a TEMPORARY plain-text transfer file
    $TempTransferFile = Join-Path $env:TEMP "vault_transfer.tmp"
    $VaultData | Export-Clixml -Path $TempTransferFile

    # Define the SYSTEM bridge command with a safety finally block
    $BridgeScript = Join-Path $env:TEMP "vault_bridge.ps1"
    [System.IO.File]::WriteAllText($BridgeScript, @"
try {
    `$Data = Import-Clixml -Path '$TempTransferFile'
    `$EncryptedData = @{}
    foreach(`$Key in `$Data.Keys) { 
        `$EncryptedData[`$Key] = `$Data[`$Key] | ConvertTo-SecureString -AsPlainText -Force 
    }
    `$EncryptedData | Export-Clixml -Path '$VaultFile'
} finally {
    if (Test-Path '$TempTransferFile') { Remove-Item '$TempTransferFile' -Force }
}
"@)

    # Execute via Scheduled Task with user-side cleanup safety
    try {
        $TaskName = "ResticVaultSync"
        $TaskArgs = "-NoProfile -NonInteractive -ExecutionPolicy Bypass -File `"$BridgeScript`""
        $TaskAction = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument $TaskArgs

        Write-Host "[[Vault]] Elevating to SYSTEM to lock the vault..." -ForegroundColor Gray
        Register-ScheduledTask -TaskName $TaskName -Action $TaskAction -User "NT AUTHORITY\SYSTEM" -RunLevel Highest | Out-Null
        Start-ScheduledTask -TaskName $TaskName | Out-Null

        # Wait for the file to appear
        $Timeout = 0
        while (-not (Test-Path $VaultFile) -and $Timeout++ -lt 15) { Start-Sleep 1 }
    }
    finally {
        # Cleanup task and temp file if they still exist
        Unregister-ScheduledTask -TaskName "ResticVaultSync" -Confirm:$false -ErrorAction SilentlyContinue
        if (Test-Path $TempTransferFile) { Remove-Item $TempTransferFile -Force -ErrorAction SilentlyContinue }
        if (Test-Path $BridgeScript) { Remove-Item $BridgeScript -Force -ErrorAction SilentlyContinue }
    }

    if (Test-Path $VaultFile) {
        Write-Host "[[Vault]] Success: Vault created and locked to SYSTEM account."
    } else {
        Write-Error "[[Vault]] Vault creation failed. Check Scheduled Task logs."
    }
}

function Export-VaultToEnv {
    <#
    .SYNOPSIS
        Loads vault secrets into the current process environment.
        Must be run by the account that encrypted the vault.
    #>
    param (
        [string]$VaultFile = (Join-Path $PSScriptRoot "secrets.vault")
    )

    $VaultFile = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($VaultFile)
    
    if (-not (Test-Path $VaultFile)) { return $null }

    $Vault = Import-Clixml -Path $VaultFile
    $SecretMap = @{}

    foreach ($Key in $Vault.Keys) {
        $BSTR = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($Vault[$Key])
        $PlainValue = [Runtime.InteropServices.Marshal]::PtrToStringAuto($BSTR)

        Set-Content -Path "Env:\$Key" -Value $PlainValue
        $SecretMap[$Key] = $PlainValue
    }
    return $SecretMap
}

$IsStandalone = ($MyInvocation.InvocationName -ne '.') -and ($MyInvocation.Line -ne $null)

if ($IsStandalone) {
    # Path resolution
    $FullVaultPath = if ([System.IO.Path]::IsPathRooted($VaultFile)) { 
        $VaultFile 
    } else { 
        Join-Path $PSScriptRoot $VaultFile 
    }

    # Check for existing vault and backup
    if (Test-Path $FullVaultPath) {
        $Timestamp = Get-Date -Format "yyyyMMddTHHmmssffff"
        $LeafName = Split-Path $FullVaultPath -Leaf
        $BackupName = "$LeafName.$Timestamp.bak"
        
        Write-Host "[[Warning]] Vault file exists at: $FullVaultPath" -ForegroundColor Yellow
        Write-Host "[[Vault]] Backing up existing vault to: $BackupName"
        
        try {
            Rename-Item -Path $FullVaultPath -NewName $BackupName -Force -ErrorAction Stop
        } catch {
            Write-Error "[[Error]] Failed to backup existing vault. Aborting."
            return
        }
    }

    # Run the interactive creation flow
    New-ResticVault -VaultFile $FullVaultPath
}
