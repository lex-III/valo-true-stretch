<#
.SYNOPSIS
    Toggle: disable the active display in Device Manager AND switch its
    resolution, in a single command. Run again to re-enable and restore.

.DESCRIPTION
    A stateful toggle for Windows.

        First run  (OFF -> ON):  save current resolution, switch to the target
                                 resolution, disable the Monitor device(s).
        Second run (ON -> OFF):  re-enable the monitor(s), restore the saved
                                 resolution.

    The target display is discovered dynamically (the display attached to the
    desktop, i.e. the one your GPU is actually driving) — nothing is hardcoded.

    --- No UAC prompt every time ---
    Disabling PnP devices needs Administrator. Rather than approving a UAC
    prompt on every run, install once:

        .\Toggle-MonitorAndResolution.ps1 -Install

    That registers a Scheduled Task (highest privileges, on-demand). Afterwards,
    running the script normally — or the desktop shortcut it creates — triggers
    that task and toggles WITHOUT any prompt.

    --- Easy defaults, set once ---
    Store your preferred resolution once; every later run uses it:

        .\Toggle-MonitorAndResolution.ps1 -SetDefault -Resolution 1280x1024

    All your settings live in a single, editable config.txt next to the script.
    Toggle state and logs live in %LOCALAPPDATA%\ToggleMonitorResolution.

.PARAMETER Resolution
    Target resolution as "WxH" (e.g. 1280x1024). Overrides the saved default for
    this run. If omitted, the saved default is used (falls back to 1280x1024).

.PARAMETER SetDefault
    Save -Resolution as the persistent default, then exit.

.PARAMETER Install
    Register the elevated Scheduled Task + desktop shortcut (one-time UAC prompt).

.PARAMETER Uninstall
    Remove the Scheduled Task and desktop shortcut.

.PARAMETER Status
    Show current default resolution, install state, and toggle state; then exit.

.EXAMPLE
    .\Toggle-MonitorAndResolution.ps1
    Toggle using the saved default resolution.

.EXAMPLE
    .\Toggle-MonitorAndResolution.ps1 -Resolution 1920x1080
    Toggle using a one-off resolution.

.NOTES
    MIT-licensed. Disabling the Monitor node does NOT blank the screen — Windows
    keeps driving the panel through the graphics adapter.
#>

[CmdletBinding()]
param(
    [ValidatePattern('^\d{3,5}x\d{3,5}$')]
    [string]$Resolution,

    [switch]$SetDefault,
    [switch]$Install,
    [switch]$Uninstall,
    [switch]$Status,

    # Apply the display profile, launch Valorant, and auto-revert on game exit.
    [switch]$Play,

    # Internal: set on the first auto-elevated run so it also registers the
    # no-prompt task. Users never pass this by hand.
    [switch]$AutoSetup
)

$ErrorActionPreference = 'Stop'

# --- Constants & paths ------------------------------------------------------
$TaskName    = 'ToggleMonitorAndResolution'
$ShortcutName = 'Toggle Monitor.lnk'
$DataDir     = Join-Path $env:LOCALAPPDATA 'ToggleMonitorResolution'
$ConfigPath  = Join-Path $DataDir 'config.json'
$StatePath   = Join-Path $DataDir 'state.json'
$LogPath     = Join-Path $DataDir 'last-run.log'
$ConfigTxtPath = Join-Path $PSScriptRoot 'config.txt'     # single, user-editable settings file
$GameProcess   = 'VALORANT-Win64-Shipping'               # the actual game process name
$BuiltInDefaultResolution = '1280x1024'

if (-not (Test-Path $DataDir)) { New-Item -ItemType Directory -Path $DataDir -Force | Out-Null }

# --- Small helpers ----------------------------------------------------------
function Test-Admin {
    ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
    ).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Invoke-Self([string[]]$extraArgs) {
    # Re-launch this script elevated (UAC), forwarding the given arguments.
    $a = @('-NoProfile','-ExecutionPolicy','Bypass','-File',"`"$PSCommandPath`"") + $extraArgs
    Start-Process powershell.exe -Verb RunAs -ArgumentList $a
}

function Get-ConfigValue([string]$key) {
    # Reads "key = value" from the single config.txt (ignoring blanks and
    # lines starting with '#'). Returns $null if missing.
    if (-not (Test-Path $ConfigTxtPath)) { return $null }
    foreach ($line in (Get-Content -Path $ConfigTxtPath)) {
        $t = $line.Trim()
        if ($t -eq '' -or $t.StartsWith('#')) { continue }
        $eq = $t.IndexOf('=')
        if ($eq -lt 1) { continue }
        if (($t.Substring(0, $eq).Trim()) -ieq $key) {
            return $t.Substring($eq + 1).Trim().Trim('"')
        }
    }
    return $null
}

function Set-ConfigValue([string]$key, [string]$value) {
    # Updates (or appends) a "key = value" line, preserving the rest of the
    # file. Seeds a template if config.txt doesn't exist yet.
    if (-not (Test-Path $ConfigTxtPath)) {
        Set-Content -Path $ConfigTxtPath -Encoding UTF8 -Value @(
            '# Toggle Monitor & Resolution - settings.',
            '# Edit the values, save, then run. Lines starting with # are ignored.',
            '',
            '# Resolution to switch to when you toggle (WIDTHxHEIGHT), e.g. 1920x1080',
            'resolution = 1280x1024',
            '',
            '# OPTIONAL: full path to Riot Client if Valorant is not found',
            '# automatically. Leave blank for auto-detect.',
            'valorant ='
        )
    }
    $out  = New-Object System.Collections.Generic.List[string]
    $done = $false
    foreach ($line in (Get-Content -Path $ConfigTxtPath)) {
        $t = $line.Trim()
        if ($t -ne '' -and -not $t.StartsWith('#')) {
            $eq = $t.IndexOf('=')
            if ($eq -ge 1 -and (($t.Substring(0, $eq).Trim()) -ieq $key)) {
                $out.Add("$key = $value"); $done = $true; continue
            }
        }
        $out.Add($line)
    }
    if (-not $done) { $out.Add("$key = $value") }
    Set-Content -Path $ConfigTxtPath -Value $out -Encoding UTF8
}

function Get-DefaultResolution {
    # Priority: config.txt next to the script, then the LOCALAPPDATA fallback,
    # then the built-in default.
    $r = Get-ConfigValue 'resolution'
    if ($r) {
        $r = ($r.ToLower() -replace '\s', '')
        if ($r -match '^\d{3,5}x\d{3,5}$') { return $r }
    }
    if (Test-Path $ConfigPath) {
        try {
            $c = Get-Content $ConfigPath -Raw | ConvertFrom-Json
            if ($c.Resolution) { return [string]$c.Resolution }
        } catch { }
    }
    return $BuiltInDefaultResolution
}

function Test-TaskInstalled {
    [bool](Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue)
}

function Get-ShortcutPath { Join-Path ([Environment]::GetFolderPath('Desktop')) $ShortcutName }

function New-ToggleShortcut {
    $lnk = Get-ShortcutPath
    $ws  = New-Object -ComObject WScript.Shell
    $s   = $ws.CreateShortcut($lnk)
    # Non-elevated launcher that starts the elevated task -> no UAC prompt.
    $s.TargetPath   = (Get-Command powershell.exe).Source
    $s.Arguments    = "-NoProfile -WindowStyle Hidden -Command ""Start-ScheduledTask -TaskName $TaskName"""
    $s.IconLocation = 'imageres.dll,109'
    $s.Description   = 'Toggle monitor + resolution'
    $s.Save()
    return $lnk
}

function Remove-ToggleShortcut {
    $lnk = Get-ShortcutPath
    if (Test-Path $lnk) { Remove-Item $lnk -Force }
}

function Install-Task {
    # Registers the elevated on-demand task + desktop shortcut. Must be admin.
    $action = New-ScheduledTaskAction -Execute 'powershell.exe' `
        -Argument "-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File ""$PSCommandPath"""
    $principal = New-ScheduledTaskPrincipal -UserId "$env:USERDOMAIN\$env:USERNAME" `
        -LogonType Interactive -RunLevel Highest
    $settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries
    Register-ScheduledTask -TaskName $TaskName -Action $action -Principal $principal `
        -Settings $settings -Description 'Toggle monitor + resolution (elevated, no UAC prompt).' -Force | Out-Null
    return (New-ToggleShortcut)
}

# --- Helpers for the -Play (Valorant) flow ----------------------------------
function Get-ToggleState { if (Test-Path $StatePath) { 'ON' } else { 'OFF' } }

function Wait-ForState([string]$want, [int]$timeoutSec = 60) {
    $deadline = (Get-Date).AddSeconds($timeoutSec)
    while ((Get-ToggleState) -ne $want -and (Get-Date) -lt $deadline) { Start-Sleep -Milliseconds 500 }
    return ((Get-ToggleState) -eq $want)
}

function Invoke-ToggleOnce {
    # Fire ONE toggle (flip) using the no-prompt task when available, else
    # self-elevate (which also auto-installs the task the first time).
    if (Test-TaskInstalled) { Start-ScheduledTask -TaskName $TaskName }
    else { Invoke-Self @('-AutoSetup', '-Resolution', (Get-DefaultResolution)) }
}

function Set-ToggleOn  { if ((Get-ToggleState) -eq 'OFF') { Invoke-ToggleOnce; [void](Wait-ForState 'ON'  60) } }
function Set-ToggleOff { if ((Get-ToggleState) -eq 'ON')  { Invoke-ToggleOnce; [void](Wait-ForState 'OFF' 60) } }

function Find-ValorantLaunch {
    # Returns @{ Path; Args } for launching Valorant, or $null if not found.
    $valArgs = '--launch-product=valorant --launch-patchline=live'

    # 1) Explicit override from config.txt (path to RiotClientServices.exe or VALORANT.exe).
    $override = Get-ConfigValue 'valorant'
    if ($override -and (Test-Path $override)) {
        if ($override -match 'RiotClientServices\.exe$') { return @{ Path = $override; Args = $valArgs } }
        return @{ Path = $override; Args = '' }
    }

    # 2) Riot's own install manifest (authoritative path to the client).
    $manifest = Join-Path $env:ProgramData 'Riot Games\RiotClientInstalls.json'
    if (Test-Path $manifest) {
        try {
            $j  = Get-Content $manifest -Raw | ConvertFrom-Json
            $rc = if ($j.rc_live) { $j.rc_live } else { $j.rc_default }
            if ($rc -and (Test-Path $rc)) { return @{ Path = $rc; Args = $valArgs } }
        } catch { }
    }

    # 3) Common fallback locations.
    foreach ($p in @(
        'C:\Riot Games\Riot Client\RiotClientServices.exe',
        (Join-Path $env:ProgramFiles 'Riot Games\Riot Client\RiotClientServices.exe'),
        (Join-Path ${env:ProgramFiles(x86)} 'Riot Games\Riot Client\RiotClientServices.exe')
    )) {
        if ($p -and (Test-Path $p)) { return @{ Path = $p; Args = $valArgs } }
    }
    return $null
}

# ============================================================================
# COMMAND: -Status
# ============================================================================
if ($Status) {
    $state = if (Test-Path $StatePath) { 'ON  (monitor disabled, resolution changed)' } else { 'OFF (normal)' }
    $resSource = if (Get-ConfigValue 'resolution') { 'config.txt' }
                 elseif (Test-Path $ConfigPath)    { 'config.json (fallback)' }
                 else                              { 'built-in default' }
    Write-Host "Toggle-MonitorAndResolution status" -ForegroundColor Cyan
    Write-Host "  Default resolution : $(Get-DefaultResolution)   (from $resSource)"
    Write-Host "  Task installed     : $(Test-TaskInstalled)   (no-prompt toggling)"
    Write-Host "  Desktop shortcut   : $(Test-Path (Get-ShortcutPath))"
    Write-Host "  Current toggle     : $state"
    Write-Host "  Data folder        : $DataDir"
    return
}

# ============================================================================
# COMMAND: -SetDefault
# ============================================================================
if ($SetDefault) {
    if (-not $Resolution) {
        Write-Error "Provide -Resolution WxH, e.g.  -SetDefault -Resolution 1280x1024"
        return
    }
    try {
        Set-ConfigValue 'resolution' $Resolution
        Write-Host "Saved default resolution: $Resolution" -ForegroundColor Green
        Write-Host "  ($ConfigTxtPath)"
    } catch {
        # Script folder is read-only (e.g. Program Files) -> fall back to LOCALAPPDATA.
        [pscustomobject]@{ Resolution = $Resolution } | ConvertTo-Json | Set-Content -Path $ConfigPath -Encoding UTF8
        Write-Host "Saved default resolution: $Resolution" -ForegroundColor Green
        Write-Host "  ($ConfigPath)"
    }
    return
}

# ============================================================================
# COMMAND: -Install
# ============================================================================
if ($Install) {
    if (-not (Test-Admin)) {
        Write-Host "Installing the elevated task requires admin approval once..." -ForegroundColor Yellow
        Invoke-Self @('-Install')
        return
    }
    $lnk = Install-Task

    Write-Host "Installed." -ForegroundColor Green
    Write-Host "  From now on, toggle WITHOUT a UAC prompt via any of:"
    Write-Host "    * the desktop shortcut:  $lnk"
    Write-Host "    * a command:             schtasks /run /tn $TaskName"
    Write-Host "    * this script (it auto-triggers the task when not elevated)"
    return
}

# ============================================================================
# COMMAND: -Uninstall
# ============================================================================
if ($Uninstall) {
    if (-not (Test-Admin)) {
        Write-Host "Removing the task requires admin approval once..." -ForegroundColor Yellow
        Invoke-Self @('-Uninstall')
        return
    }
    if (Test-TaskInstalled) { Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false }
    Remove-ToggleShortcut
    Write-Host "Uninstalled scheduled task and shortcut." -ForegroundColor Green
    Write-Host "  (Config/state in $DataDir were left intact.)"
    return
}

# ============================================================================
# COMMAND: -Play  (apply profile -> launch Valorant -> revert on game exit)
# ============================================================================
if ($Play) {
    Write-Host "Play Valorant" -ForegroundColor Cyan
    Write-Host "  Applying display profile ($(Get-DefaultResolution) + monitor off)..."
    Set-ToggleOn
    if ((Get-ToggleState) -ne 'ON') {
        Write-Warning "Could not apply the display profile; aborting so your screen is untouched."
        return
    }

    if (Get-Process -Name $GameProcess -ErrorAction SilentlyContinue) {
        # Already running - don't launch a second copy; go straight to waiting.
        Write-Host "  Valorant is already running - not launching again." -ForegroundColor Green
    } else {
        $launch = Find-ValorantLaunch
        if ($launch) {
            Write-Host "  Launching Valorant..."
            try {
                if ($launch.Args) { Start-Process -FilePath $launch.Path -ArgumentList $launch.Args }
                else              { Start-Process -FilePath $launch.Path }
            } catch { Write-Warning "  Failed to launch Valorant: $($_.Exception.Message)" }
        } else {
            Write-Warning "  Couldn't find Valorant automatically."
            Write-Host   "  Add this line to $ConfigTxtPath :"
            Write-Host   "    valorant = C:\Path\To\RiotClientServices.exe"
            Write-Host   "  ...or just start Valorant yourself now - I'll revert when it closes."
        }

        Write-Host "  Waiting for the game to start (up to 3 min)..."
        $deadline = (Get-Date).AddSeconds(180)
        while (-not (Get-Process -Name $GameProcess -ErrorAction SilentlyContinue) -and (Get-Date) -lt $deadline) {
            Start-Sleep -Seconds 2
        }
    }

    if (Get-Process -Name $GameProcess -ErrorAction SilentlyContinue) {
        Write-Host "  Valorant is running. Your display reverts automatically when you quit." -ForegroundColor Green
        while (Get-Process -Name $GameProcess -ErrorAction SilentlyContinue) { Start-Sleep -Seconds 3 }
        Write-Host "  Valorant closed."
    } else {
        Write-Warning "  Valorant didn't start within 3 minutes; restoring your display now."
    }

    Write-Host "  Restoring display..."
    Set-ToggleOff
    Write-Host "Done - display restored." -ForegroundColor Green
    return
}

# ============================================================================
# DEFAULT COMMAND: toggle
# ============================================================================
$targetResolution = if ($Resolution) { $Resolution } else { Get-DefaultResolution }

if (-not (Test-Admin)) {
    if (Test-TaskInstalled) {
        # No-prompt path: fire the elevated task (it reads the saved default).
        Start-ScheduledTask -TaskName $TaskName
        Write-Host "Done - display toggled (no prompt needed)." -ForegroundColor Green
        return
    }
    # First ever run: elevate once (one Windows approval) and, while elevated,
    # set up the no-prompt task so this is the ONLY time you'll be asked.
    Write-Host "First run - Windows will ask for approval once." -ForegroundColor Yellow
    Write-Host "After you click Yes, future double-clicks need no approval." -ForegroundColor Yellow
    Invoke-Self @('-AutoSetup', '-Resolution', $targetResolution)
    return
}

# --- Elevated from here: perform the actual toggle --------------------------
try { Start-Transcript -Path $LogPath -Force | Out-Null } catch { }

# On the first auto-elevated run, register the no-prompt task + shortcut so the
# user is never asked to approve again.
if ($AutoSetup -and -not (Test-TaskInstalled)) {
    try {
        $lnk = Install-Task
        Write-Host "  Set up no-prompt toggling for next time (shortcut: $lnk)." -ForegroundColor Green
    } catch {
        Write-Warning "  Could not set up the no-prompt task: $($_.Exception.Message)"
    }
}

$Width, $Height = $targetResolution.ToLower().Split('x') | ForEach-Object { [int]$_ }

# --- Display-mode P/Invoke --------------------------------------------------
if (-not ([System.Management.Automation.PSTypeName]'Display').Type) {
    Add-Type -TypeDefinition @"
using System;
using System.Runtime.InteropServices;

public class Display
{
    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Ansi)]
    public struct DEVMODE
    {
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 32)] public string dmDeviceName;
        public short dmSpecVersion;
        public short dmDriverVersion;
        public short dmSize;
        public short dmDriverExtra;
        public int   dmFields;
        public int   dmPositionX;
        public int   dmPositionY;
        public int   dmDisplayOrientation;
        public int   dmDisplayFixedOutput;
        public short dmColor;
        public short dmDuplex;
        public short dmYResolution;
        public short dmTTOption;
        public short dmCollate;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 32)] public string dmFormName;
        public short dmLogPixels;
        public int   dmBitsPerPel;
        public int   dmPelsWidth;
        public int   dmPelsHeight;
        public int   dmDisplayFlags;
        public int   dmDisplayFrequency;
        public int   dmICMMethod;
        public int   dmICMIntent;
        public int   dmMediaType;
        public int   dmDitherType;
        public int   dmReserved1;
        public int   dmReserved2;
        public int   dmPanningWidth;
        public int   dmPanningHeight;
    }

    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Ansi)]
    public struct DISPLAY_DEVICE
    {
        public int cb;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 32)]  public string DeviceName;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 128)] public string DeviceString;
        public int StateFlags;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 128)] public string DeviceID;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 128)] public string DeviceKey;
    }

    [DllImport("user32.dll", CharSet = CharSet.Ansi)]
    [return: MarshalAs(UnmanagedType.Bool)]
    public static extern bool EnumDisplayDevices(string device, int iDevNum, ref DISPLAY_DEVICE lpDD, int flags);

    [DllImport("user32.dll", CharSet = CharSet.Ansi)]
    public static extern int EnumDisplaySettings(string deviceName, int modeNum, ref DEVMODE devMode);

    [DllImport("user32.dll", CharSet = CharSet.Ansi)]
    public static extern int ChangeDisplaySettingsEx(string deviceName, ref DEVMODE devMode, IntPtr hwnd, int flags, IntPtr lParam);

    public const int  ENUM_CURRENT_SETTINGS   = -1;
    public const int  CDS_UPDATEREGISTRY      = 0x00000001;
    public const int  DM_PELSWIDTH            = 0x00080000;
    public const int  DM_PELSHEIGHT           = 0x00100000;
    public const int  DISP_CHANGE_SUCCESSFUL  = 0;
    public const int  DISPLAY_DEVICE_ATTACHED = 0x00000001; // ATTACHED_TO_DESKTOP
    public const int  DISPLAY_DEVICE_PRIMARY  = 0x00000004;
}
"@
}

# NOTE: PowerShell marshals $null as an empty string "" for native string
# parameters, which is an INVALID device name. To pass a real NULL (required to
# enumerate adapters) we must use [NullString]::Value.
function Get-ActiveDisplayName {
    $null2       = [NullString]::Value
    $primary     = $null
    $anyAttached = $null
    $i = 0
    do {
        $dd = New-Object Display+DISPLAY_DEVICE
        $dd.cb = [System.Runtime.InteropServices.Marshal]::SizeOf([type]'Display+DISPLAY_DEVICE')
        $ok = [Display]::EnumDisplayDevices($null2, $i, [ref]$dd, 0)
        if ($ok -and (($dd.StateFlags -band [Display]::DISPLAY_DEVICE_ATTACHED) -ne 0)) {
            if (-not $anyAttached) { $anyAttached = $dd.DeviceName }
            if (($dd.StateFlags -band [Display]::DISPLAY_DEVICE_PRIMARY) -ne 0) { $primary = $dd.DeviceName }
        }
        $i++
    } while ($ok -and $i -lt 32)

    if ($primary) { return $primary }
    return $anyAttached
}

function Get-CurrentResolution([string]$device) {
    $dm = New-Object Display+DEVMODE
    $dm.dmSize = [System.Runtime.InteropServices.Marshal]::SizeOf([type]'Display+DEVMODE')
    if ([Display]::EnumDisplaySettings($device, [Display]::ENUM_CURRENT_SETTINGS, [ref]$dm) -ne 0) {
        return [PSCustomObject]@{ Width = $dm.dmPelsWidth; Height = $dm.dmPelsHeight }
    }
    return $null
}

function Set-Resolution([string]$device, [int]$w, [int]$h) {
    $dm = New-Object Display+DEVMODE
    $dm.dmSize = [System.Runtime.InteropServices.Marshal]::SizeOf([type]'Display+DEVMODE')

    if ([Display]::EnumDisplaySettings($device, [Display]::ENUM_CURRENT_SETTINGS, [ref]$dm) -eq 0) {
        Write-Warning "  Could not read current settings for display '$device'."
        return $false
    }

    $dm.dmPelsWidth  = $w
    $dm.dmPelsHeight = $h
    $dm.dmFields     = [Display]::DM_PELSWIDTH -bor [Display]::DM_PELSHEIGHT

    $result = [Display]::ChangeDisplaySettingsEx($device, [ref]$dm, [IntPtr]::Zero,
                                                 [Display]::CDS_UPDATEREGISTRY, [IntPtr]::Zero)
    if ($result -eq [Display]::DISP_CHANGE_SUCCESSFUL) {
        Write-Host "  Resolution set to ${w}x${h} on $device." -ForegroundColor Green
        return $true
    }
    Write-Warning "  Resolution change to ${w}x${h} failed (code $result). Is that mode supported by the display?"
    return $false
}

function Get-EnabledMonitors {
    # Discovered fresh at runtime from the "Monitor" device class — no IDs are
    # baked in, so it adapts to whatever monitors this machine has. Only ones
    # currently enabled (Status 'OK'); disabled devices report 'Error'.
    $found = @(Get-PnpDevice -Class Monitor -ErrorAction SilentlyContinue)
    Write-Host ("  Found {0} monitor device(s) in Device Manager." -f $found.Count)
    $found | Where-Object { $_.Status -eq 'OK' }
}

# ----------------------------------------------------------------------------
if (Test-Path $StatePath) {
    # -------- Currently ON  ->  revert -------------------------------------
    Write-Host "State: ON  ->  reverting (enable monitors + restore resolution)" -ForegroundColor Cyan
    $state = Get-Content $StatePath -Raw | ConvertFrom-Json

    foreach ($id in $state.DisabledMonitors) {
        try {
            Enable-PnpDevice -InstanceId $id -Confirm:$false -ErrorAction Stop
            Write-Host "  Enabled monitor: $id" -ForegroundColor Green
        } catch {
            Write-Warning "  Failed to enable ${id}: $($_.Exception.Message)"
        }
    }

    if ($state.PrevWidth -and $state.PrevHeight) {
        $device = if ($state.Device) { $state.Device } else { Get-ActiveDisplayName }
        if ($device) { Set-Resolution -device $device -w $state.PrevWidth -h $state.PrevHeight | Out-Null }
    }

    Remove-Item $StatePath -Force
    Write-Host "Done. Monitors re-enabled, resolution restored." -ForegroundColor Cyan
}
else {
    # -------- Currently OFF  ->  apply -------------------------------------
    Write-Host "State: OFF  ->  applying (set ${Width}x${Height} + disable monitors)" -ForegroundColor Cyan

    $device  = Get-ActiveDisplayName
    if ($device) { Write-Host "  Active display: $device" }
    $current = if ($device) { Get-CurrentResolution -device $device } else { $null }
    $monitors = Get-EnabledMonitors

    if (-not $monitors) { Write-Warning "No enabled Monitor-class devices found. Nothing to disable." }

    # 1) Change resolution first (while the monitor node is still present).
    if ($device) {
        Set-Resolution -device $device -w $Width -h $Height | Out-Null
    } else {
        Write-Warning "  Could not identify an active display; skipping resolution change."
    }

    # 2) Disable the monitor device(s).
    $disabled = @()
    foreach ($m in $monitors) {
        try {
            Disable-PnpDevice -InstanceId $m.InstanceId -Confirm:$false -ErrorAction Stop
            Write-Host "  Disabled monitor: $($m.FriendlyName) [$($m.InstanceId)]" -ForegroundColor Green
            $disabled += $m.InstanceId
        } catch {
            Write-Warning "  Failed to disable $($m.InstanceId): $($_.Exception.Message)"
        }
    }

    # 3) Persist state for the next (revert) run.
    [PSCustomObject]@{
        Device           = $device
        PrevWidth        = if ($current) { $current.Width }  else { $null }
        PrevHeight       = if ($current) { $current.Height } else { $null }
        DisabledMonitors = $disabled
        AppliedAt        = (Get-Date).ToString('s')
    } | ConvertTo-Json | Set-Content -Path $StatePath -Encoding UTF8

    Write-Host "Done. Resolution applied, monitors disabled. Run again to revert." -ForegroundColor Cyan
}

try { Stop-Transcript | Out-Null } catch { }
