<#
.SYNOPSIS
    Initializes and hardens SSH keys for the NT AUTHORITY\SYSTEM account.

.DESCRIPTION
    Ensures an Ed25519 key pair exists in the SYSTEM profile and applies strict ACLs.
    Requires an ELEVATED PowerShell session (Run as Administrator).

.EXAMPLE
    .\InitializeSSH.ps1 (Standalone)
    $Key = . .\InitializeSSH.ps1 (Orchestration)
#>

# Fast-fail if not Administrator
if (-not ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Write-Error "[[SSH]] This script must be run as an Administrator."
    if ($MyInvocation.InvocationName -eq '.') { return } else { exit 1 }
}

# Hardening logic to be reused in temporary SYSTEM tasks
$script:HardenSshScriptBlock = {
    param([string]$FolderPath)

    $SystemSid   = New-Object System.Security.Principal.SecurityIdentifier("S-1-5-18")
    $AdminSid    = New-Object System.Security.Principal.SecurityIdentifier("S-1-5-32-544")
    $FullControl = [System.Security.AccessControl.FileSystemRights]::FullControl
    $Allow       = [System.Security.AccessControl.AccessControlType]::Allow
    $Propagate   = [System.Security.AccessControl.PropagationFlags]::None

    function Apply-StrictAcl {
        param($Target)
        if (-not (Test-Path $Target)) { return }

        $Acl = Get-Acl -Path $Target
        $Acl.SetOwner($SystemSid)
        $Acl.SetAccessRuleProtection($true, $false)
        $Acl.Access | ForEach-Object { $Acl.RemoveAccessRule($_) } | Out-Null

        if (Test-Path $Target -PathType Container) {
            $Inherit = [System.Security.AccessControl.InheritanceFlags]"ContainerInherit, ObjectInherit"
        } else {
            $Inherit = [System.Security.AccessControl.InheritanceFlags]"None"
        }

        $SystemRule = New-Object System.Security.AccessControl.FileSystemAccessRule($SystemSid, $FullControl, $Inherit, $Propagate, $Allow)
        $AdminRule  = New-Object System.Security.AccessControl.FileSystemAccessRule($AdminSid, $FullControl, $Inherit, $Propagate, $Allow)

        $Acl.SetAccessRule($SystemRule)
        $Acl.AddAccessRule($AdminRule)

        Set-Acl -Path $Target -AclObject $Acl
    }

    if (Test-Path $FolderPath) {
        Apply-StrictAcl -Target $FolderPath
        Get-ChildItem -Path $FolderPath -Recurse | ForEach-Object {
            Apply-StrictAcl -Target $_.FullName
        }
    }
}.ToString()

function Harden-SystemSSH {
    <#
    .SYNOPSIS
        Triggers a SYSTEM task to apply strict ACLs to the SYSTEM SSH directory.
    #>
    $SshPath = Join-Path $Env:SystemRoot "System32\config\systemprofile\.ssh"
    $HardenScript = Join-Path $PSScriptRoot "temp_ssh_harden.ps1"
    [System.IO.File]::WriteAllText($HardenScript, @"
    function Invoke-HardenSsh { $($script:HardenSshScriptBlock) }
    Invoke-HardenSsh -FolderPath '$SshPath'
"@)

    $Action = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument "-ExecutionPolicy Bypass -File `"$HardenScript`""
    $Principal = New-ScheduledTaskPrincipal -UserId "NT AUTHORITY\SYSTEM" -LogonType ServiceAccount

    Register-ScheduledTask -TaskName "SSHHardenSystem" -Action $Action -Principal $Principal | Out-Null
    Start-ScheduledTask -TaskName "SSHHardenSystem" | Out-Null
    
    # Brief wait for ACL application
    $Timeout = 0
    while ((Get-ScheduledTask -TaskName "SSHHardenSystem").State -eq 'Running' -and $Timeout++ -lt 10) { 
        Start-Sleep -Seconds 1 
    }
    Unregister-ScheduledTask -TaskName "SSHHardenSystem" -Confirm:$false -ErrorAction SilentlyContinue
    if (Test-Path $HardenScript) { Remove-Item $HardenScript -Force }
}

function Get-SystemSSHKey {
    <#
    .SYNOPSIS
        Ensures SYSTEM SSH keys exist and returns the public key string.
    #>
    $SshPath = Join-Path $Env:SystemRoot "System32\config\systemprofile\.ssh"
    $KeyPath = Join-Path $SshPath "id_ed25519"
    $PubKeyPath = "$KeyPath.pub"

    # Generate Key Pair if the PRIVATE key is missing
    if (-not (Test-Path $KeyPath)) {
        $GenScript = Join-Path $PSScriptRoot "temp_ssh_gen.ps1"
        [System.IO.File]::WriteAllText($GenScript, @"
        # Define the hardening function inside the task
        function Invoke-HardenSsh { $($script:HardenSshScriptBlock) }

        if (-not (Test-Path '$SshPath')) {
            New-Item -ItemType Directory -Path '$SshPath' -Force | Out-Null
        }

        # Generate keys
        & ssh-keygen -t ed25519 -f "$KeyPath" -q -N '""'

        # Run the greedy hardening loop
        Invoke-HardenSsh -FolderPath '$SshPath'
"@)

        $Action = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument "-ExecutionPolicy Bypass -File `"$GenScript`""
        $Principal = New-ScheduledTaskPrincipal -UserId "NT AUTHORITY\SYSTEM" -LogonType ServiceAccount

        Register-ScheduledTask -TaskName "SSHInitSystem" -Action $Action -Principal $Principal | Out-Null
        Start-ScheduledTask -TaskName "SSHInitSystem" | Out-Null

        $Timeout = 0
        while (-not (Test-Path $KeyPath) -and $Timeout -lt 10) { Start-Sleep -Seconds 1; $Timeout++ }
        Unregister-ScheduledTask -TaskName "SSHInitSystem" -Confirm:$false -ErrorAction SilentlyContinue
        if (Test-Path $GenScript) { Remove-Item $GenScript -Force }
    }

    # If PRIVATE key exists but PUBLIC key is missing, reconstruct it
    if ((Test-Path $KeyPath) -and -not (Test-Path $PubKeyPath)) {
        Write-Host "[[SSH]] Public key missing. Reconstructing..."
        $RecoverScript = Join-Path $PSScriptRoot "temp_ssh_recover.ps1"
        [System.IO.File]::WriteAllText($RecoverScript, @"
        function Invoke-HardenSsh { $($script:HardenSshScriptBlock) }

        # Reconstruct pubkey from private key
        & ssh-keygen -y -f "$KeyPath" | Out-File "$PubKeyPath" -Encoding ascii

        # Run greedy hardening (ensures reconstructed file and existing folder are correct)
        Invoke-HardenSsh -FolderPath '$SshPath'
"@)

        $Action = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument "-ExecutionPolicy Bypass -File `"$RecoverScript`""
        $Principal = New-ScheduledTaskPrincipal -UserId "NT AUTHORITY\SYSTEM" -LogonType ServiceAccount

        Register-ScheduledTask -TaskName "SSHRecoverSystem" -Action $Action -Principal $Principal | Out-Null
        Start-ScheduledTask -TaskName "SSHRecoverSystem" | Out-Null

        $Timeout = 0
        while (-not (Test-Path $PubKeyPath) -and $Timeout -lt 5) { Start-Sleep -Seconds 1; $Timeout++ }
        Unregister-ScheduledTask -TaskName "SSHRecoverSystem" -Confirm:$false -ErrorAction SilentlyContinue
        if (Test-Path $RecoverScript) { Remove-Item $RecoverScript -Force }
    }
    
    # Return for use in scripts or standalone output
    if (Test-Path $PubKeyPath) {
        return (Get-Content $PubKeyPath -Raw).Trim()
    }
}

$IsStandalone = ($MyInvocation.InvocationName -ne '.') -and ($MyInvocation.Line -ne $null)

if ($IsStandalone) {
    $PubKey = Get-SystemSSHKey
    if ($null -ne $PubKey) {
        Write-Host "`n[[SSH]] Public Key for SYSTEM account:" -ForegroundColor Yellow
        Write-Host $PubKey -ForegroundColor Green
        Write-Host ""
    } else {
        Write-Error "[[SSH]] Failed to retrieve or generate the SYSTEM SSH key."
    }
}
