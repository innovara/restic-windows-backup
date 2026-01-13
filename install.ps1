#
# Restic Windows Backup - Installation Script
#

# =========== start configuration =========== #

# load restic environment variables with credentials
$VaultFile = Join-Path $PSScriptRoot "secrets.vault"  # New
$SecretsScript = Join-Path $PSScriptRoot "secrets.ps1"  # Legacy
$VaultManagerPath = Join-Path $PSScriptRoot "VaultManager.ps1"

# load configuration variables
$ConfigScript = Join-Path $PSScriptRoot "config.ps1"

# initialize secrets if the file exists
if (Test-Path $SecretsScript) { . $SecretsScript }

# initialize config
if (Test-Path $ConfigScript) { 
    . $ConfigScript 
}
else {
    Write-Error "[[Error]] config.ps1 not found. Please create it from the template before running install."
    exit 1
}

# apply global configuration
$ResticExe = Join-Path $InstallPath $ExeName
$LogPath = Join-Path $InstallPath "logs"

# make LASTEXITCODE global to enable error checking for Invoke-Expression commands
$global:LASTEXITCODE=0

# assume the repository is not initialized
$RepoExists = $false

# =========== end configuration =========== #

# download restic
if(-not (Test-Path $ResticExe)) {
    $url = $null
    if([Environment]::Is64BitOperatingSystem){
        $url = "https://github.com/restic/restic/releases/download/v0.17.3/restic_0.17.3_windows_amd64.zip"
    }
    else {
        $url = "https://github.com/restic/restic/releases/download/v0.17.3/restic_0.17.3_windows_386.zip"
    }
    try {
        $output = Join-Path $InstallPath "restic.zip"
        Invoke-WebRequest -Uri $url -OutFile $output
        Expand-Archive -LiteralPath $output $InstallPath
        Remove-Item $output
        Get-ChildItem *.exe | Rename-Item -NewName $ExeName
    }
    catch {
        Write-Error "[[Install]] restic.exe download failed. Check errors and resolve: $_"
        exit 1
    }
}

# Apply global paramters to $ResticExe, after the $ResticExe has been downloaded/confirmed to exist
if(-not [String]::IsNullOrEmpty($GlobalParameters)) {
    $ResticExe = "$ResticExe $GlobalParameters"
}

# Invoke restic self-update to check for a newer version
# This is enabled by default unless configuration disables self-update
if ([String]::IsNullOrEmpty($SelfUpdateEnabled) -or ($SelfUpdateEnabled -eq $true)) {
    Invoke-Expression "$ResticExe self-update"
    if($LASTEXITCODE) {
        Write-Warning "[[Update]] Restic self-update failed. Check errors and resolve."
    }
}

# Create log directory if it doesn't exit
if(-not (Test-Path $LogPath)) {
    New-Item -ItemType Directory -Force -Path $LogPath | Out-Null
    Write-Output "[[Init]] Created log directory: $LogPath"
}

# Create the local exclude file
if(-not (Test-Path $LocalExcludeFile)) {
    New-Item -Type File -Path $LocalExcludeFile | Out-Null
}

# Setup secure credentials if they aren't already provided by secrets.ps1
# Ask the repository question FIRST for everyone to set the $RepoExists state
$RepoExists = (Read-Host "Is your restic repository already initialized? (Y/n)").ToLower() -ne 'n'
# Handle the credentials
if ([String]::IsNullOrEmpty($Env:RESTIC_PASSWORD)) {
    if (-not (Test-Path $VaultFile)) {
        if (Test-Path $VaultManagerPath) {
            if (-not $RepoExists) {
                Write-Host ("`n" + ("!" * 60)) -ForegroundColor Red 
                Write-Host "                    IMPORTANT WARNING" -ForegroundColor Red 
                Write-Host ("!" * 60) -ForegroundColor Red 
                Write-Host " You are about to choose a password for the new repository." 
                Write-Host " Remembering your password is important! If you lose it, you" 
                Write-Host " won't be able to access data stored in the repository." 
                Write-Host " Choose a STRONG password." 
                Write-Host ("-" * 60) -ForegroundColor Red 
            }
            & {
                # Create the vault
                . $VaultManagerPath
                New-ResticVault -VaultFile $VaultFile
            }
        } else {
            Write-Error "[[Error]] VaultManager.ps1 not found. It is required to create a secure vault."
            exit 1
        }
    } else {
        # Situation: Vault file exists.
        Write-Host "[[Vault]] Secure vault found. Using existing credentials."
    }
} else {
    # Legacy path: They already have a password in secrets.ps1, so we just use it.
    Write-Host "[[Secrets]] Legacy secrets.ps1 found. Using existing credentials."
}

# Initialize the restic repository
$ResticRepo = $Env:RESTIC_REPOSITORY
$InitTask = "ResticRepoInit"
$Timestamp = Get-Date -Format "yyyyMMddTHHmmssffff"
$InitLog = Join-Path $LogPath "$Timestamp.init.log.txt"
# Determine how to load secrets for the SYSTEM task
if ((Test-Path $VaultFile) -and [String]::IsNullOrEmpty($Env:RESTIC_PASSWORD)) {
    # Path A: use the secure vault
    $SecretLoader = @"
        . '$VaultManagerPath'
        Export-VaultToEnv -VaultFile '$VaultFile'
"@
} elseif (-not [String]::IsNullOrEmpty($Env:RESTIC_PASSWORD)) {
    # Path B: legacy secrets.ps1
    $SecretLoader = if (Test-Path $SecretsScript) { ". '$SecretsScript'" } else { "" }
} else {
    Write-Error "[[Init]] Error: No credentials found. Please provide secrets.ps1 or secrets.vault."
    exit 1
}
# Use the RepoExists flag set prior the vault / secrets logic
$InitCmd = if ($RepoExists) { @("cat", "config") } else { @("init") }
$InitScript = Join-Path $PSScriptRoot "init_script.ps1"
[System.IO.File]::WriteAllText($InitScript, @"
    try {
        $SecretLoader
        
        `$resticArgs = @(
            "-o", "sftp.args=-o BatchMode=yes",
            $( ($InitCmd | ForEach-Object { "'$_'" }) -join ", "),
            "-r", "$ResticRepo",
            "--verbose"
        )

        & '$ResticExe' @resticArgs 2>&1 | Out-File -FilePath '$InitLog' -Encoding utf8
    } 
    finally {
        # Capture the exit code of the last command (restic)
        `$Code = if (`$null -eq `$LastExitCode) { 1 } else { `$LastExitCode }
        # Explicitly terminate the session with that code
        exit `$Code
    }
"@)
if (Get-ScheduledTask -TaskName $InitTask -ErrorAction SilentlyContinue) {
    Unregister-ScheduledTask -TaskName $InitTask -Confirm:$false
}
$InitArgs = "-ExecutionPolicy Bypass -NonInteractive -NoLogo -NoProfile -File `"$InitScript`""
$InitAction = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument $InitArgs
Register-ScheduledTask -TaskName $InitTask -Action $InitAction -User "NT AUTHORITY\SYSTEM" | Out-Null
try {
    Start-ScheduledTask -TaskName $InitTask | Out-Null
    $Timeout = 30; $Elapsed = 0
    while ((Get-ScheduledTask -TaskName $InitTask).State -eq 'Running' -and $Elapsed++ -lt $Timeout) { Start-Sleep 1 }
    if (Test-Path $InitLog) {
        $RawOutput = Get-Content $InitLog -Raw
        $InitResult = (Get-ScheduledTask -TaskName $InitTask | Get-ScheduledTaskInfo).LastTaskResult
        # Successful creation (Exit 0)
        $Success = ($InitResult -eq 0) 
        # Already exists (Exit 1 + specific error string)
        $AlreadyExists = ($InitResult -ne 0 -and $RawOutput -match "already exists")
        # Verified existing (Exit 0 from 'cat config')
        $Verified = ($InitResult -eq 0 -and $RawOutput -match "chunker_polynomial")
        if ($Success -or $AlreadyExists -or $Verified) {
            Write-Host "[[Init]] Success: Repository is ready."
        } else {
            Write-Warning "[[Init]] Fatal Error. Restic reported (Exit Code: $InitResult):"
            Write-Host $RawOutput.Trim() -ForegroundColor Yellow
            exit 1
        }
    }
}
finally {
    Unregister-ScheduledTask -TaskName $InitTask -Confirm:$false -ErrorAction SilentlyContinue
    if (Test-Path $InitScript) { Remove-Item $InitScript -ErrorAction SilentlyContinue }
    Write-Host "[[Init]] Notice: Initialization log preserved at $InitLog"
}

# Scheduled Windows Task Scheduler to run the backup
$backup_task_name = "Restic Backup"
$backup_task = Get-ScheduledTask $backup_task_name -ErrorAction SilentlyContinue
if($null -eq $backup_task) {
    try {
        $task_action = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument '-ExecutionPolicy Bypass -NonInteractive -NoLogo -NoProfile -Command ".\backup.ps1; exit $LASTEXITCODE"' -WorkingDirectory $InstallPath
        $task_user = New-ScheduledTaskPrincipal -UserId "NT AUTHORITY\SYSTEM" -LogonType ServiceAccount -RunLevel Highest
        $task_settings = New-ScheduledTaskSettingsSet -RestartCount 4 -RestartInterval (New-TimeSpan -Minutes 15) -ExecutionTimeLimit (New-TimeSpan -Days 3) -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -DontStopOnIdleEnd -MultipleInstances IgnoreNew -IdleDuration 0 -IdleWaitTimeout 0 -StartWhenAvailable -RestartOnIdle
        $task_trigger = New-ScheduledTaskTrigger -Daily -At 4:00am
        Register-ScheduledTask $backup_task_name -Action $task_action -Principal $task_user -Settings $task_settings -Trigger $task_trigger | Out-Null
        Write-Output "[[Scheduler]] Backup task scheduled."
    }
    catch {
        Write-Error "[[Scheduler]] Setting up backup task schedule failed: $_"
    }
}
else {
    Write-Warning "[[Scheduler]] Backup task not scheduled: there is already a task with the name '$backup_task_name'."
}

# Install NuGet and Send-MailKitMessage module (by force)
if ($PSVersionTable.PSVersion.Major -eq 5) {
    Install-PackageProvider -Name NuGet -Force
}
Install-Module Send-MailKitMessage -Repository PSGallery -Scope AllUsers -Force
