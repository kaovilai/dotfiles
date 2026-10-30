# Windows side of a headless WSL2 T3 Code host: start the distro at boot with
# nobody signed in and keep it running, so systemd inside it starts
# t3code.service (lingering) and the fleet-sync timer. Also stops the machine
# sleeping or hibernating on AC power. Untested on real Windows.
#
# From an elevated PowerShell (Terminal (Admin)):
#   powershell -ExecutionPolicy Bypass -File \\wsl.localhost\<distro>\home\<you>\git\dotfiles\scripts\wsl-keepalive.ps1
#   ... -Distro FedoraLinux-43     # default: your default WSL distro
#   ... -Remove                    # delete the task (power settings stay)
#
# "Run whether user is logged on or not" stores your Windows password with the
# task: for a Microsoft account that is the account password, not the PIN.
param(
    [string]$Distro,
    [switch]$Remove
)
$ErrorActionPreference = 'Stop'
$TaskName = 'WSL keepalive'

$admin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
    [Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $admin) { throw 'Run this from an elevated PowerShell (Terminal (Admin)).' }

if ($Remove) {
    Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false -ErrorAction SilentlyContinue
    Write-Host "Removed scheduled task '$TaskName'"
    return
}

# Default distro from the registry: `wsl -l` prints UTF-16, awkward to parse.
$lxss = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Lxss'
if (-not $Distro) {
    $default = (Get-ItemProperty $lxss -ErrorAction SilentlyContinue).DefaultDistribution
    if ($default) { $Distro = (Get-ItemProperty "$lxss\$default").DistributionName }
    if (-not $Distro) { throw 'No default WSL distro; pass -Distro <name> (see: wsl --list).' }
}
$known = Get-ChildItem $lxss -ErrorAction SilentlyContinue | ForEach-Object { (Get-ItemProperty $_.PSPath).DistributionName }
if ($known -notcontains $Distro) { throw "No WSL distro named '$Distro'. Installed: $($known -join ', ')" }

# A process held open keeps the WSL VM, and with it systemd, running.
$action = New-ScheduledTaskAction -Execute 'wsl.exe' -Argument "-d $Distro --exec /bin/sleep infinity"
$trigger = New-ScheduledTaskTrigger -AtStartup
$settings = New-ScheduledTaskSettingsSet -ExecutionTimeLimit ([TimeSpan]::Zero) `
    -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries `
    -RestartCount 999 -RestartInterval (New-TimeSpan -Minutes 1)
$user = "$env:USERDOMAIN\$env:USERNAME"
$secure = Read-Host "Windows password for $user (stored with the task)" -AsSecureString
$password = [Net.NetworkCredential]::new('', $secure).Password

Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false -ErrorAction SilentlyContinue
Register-ScheduledTask -TaskName $TaskName -Action $action -Trigger $trigger -Settings $settings `
    -User $user -Password $password | Out-Null
Write-Host "Registered '$TaskName': wsl -d $Distro at startup, nobody signed in"

powercfg /change standby-timeout-ac 0
powercfg /change hibernate-timeout-ac 0
Write-Host 'No sleep or hibernate on AC power'

Start-ScheduledTask -TaskName $TaskName
Write-Host "Started it now. Reboot, then from the phone or: wsl -d $Distro -- zsh -ic verify-t3-headless"
