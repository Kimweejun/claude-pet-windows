# clawdex for Windows - installer. Safe to re-run.
#   1) copies the files to ~\.clawdex      2) compiles bin\clawdex-hook.exe
#   3) wires Claude Code hooks into ~\.claude\settings.json
#   4) creates the desktop shortcut         5) starts the pet
param([string]$DesktopDir = [Environment]::GetFolderPath('Desktop'))
$ErrorActionPreference = 'Stop'
$Repo = $PSScriptRoot
$Root = Join-Path $env:USERPROFILE '.clawdex'
$Bin  = Join-Path $Root 'bin'

# stop a running pet so its files can be replaced
$mainScript = Join-Path $Root 'clawdex.ps1'
if (Test-Path $mainScript) { & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $mainScript -Command tuck | Out-Null; Start-Sleep 2 }

# 1) copy files (+ bundled pets) into ~\.clawdex
$null = New-Item -ItemType Directory -Force $Root, $Bin, (Join-Path $Root 'src'), (Join-Path $Root 'pets')
if ($Repo -ne $Root) {
    foreach ($f in 'clawdex.ps1', 'clawdex-launch.vbs', 'uninstall.ps1', 'install.ps1') { Copy-Item (Join-Path $Repo $f) $Root -Force }
    Copy-Item (Join-Path $Repo 'src\ClawdexHook.cs') (Join-Path $Root 'src') -Force
    if (Test-Path (Join-Path $Repo 'pets')) { Copy-Item (Join-Path $Repo 'pets\*') (Join-Path $Root 'pets') -Recurse -Force }
}
Write-Host "files copied to $Root"

# 2) hook exe (csc ships with .NET Framework on every Windows)
$csc = Join-Path ([Runtime.InteropServices.RuntimeEnvironment]::GetRuntimeDirectory()) 'csc.exe'
$exe = Join-Path $Bin 'clawdex-hook.exe'
& $csc /nologo /target:winexe /optimize+ "/out:$exe" (Join-Path $Root 'src\ClawdexHook.cs')
if (-not (Test-Path $exe)) { throw 'hook compile failed' }
Write-Host "compiled $exe"

# 3) Claude Code hooks (user scope). Existing settings are preserved; our old entries are replaced.
$claudeDir = Join-Path $env:USERPROFILE '.claude'
$null = New-Item -ItemType Directory -Force $claudeDir
$settingsPath = Join-Path $claudeDir 'settings.json'
if (Test-Path $settingsPath) {
    Copy-Item $settingsPath "$settingsPath.clawdex-backup" -Force
    $settings = Get-Content $settingsPath -Raw | ConvertFrom-Json
} else { $settings = [pscustomobject]@{} }
if (-not $settings.PSObject.Properties['hooks']) {
    $settings | Add-Member -NotePropertyName hooks -NotePropertyValue ([pscustomobject]@{})
}
$cmd = ($exe -replace '\\', '/')
$events = 'SessionStart', 'SessionEnd', 'UserPromptSubmit', 'PreToolUse', 'PostToolUse', 'Notification', 'Stop', 'SubagentStop', 'PreCompact'
foreach ($ev in $events) {
    $keep = @()
    if ($settings.hooks.PSObject.Properties[$ev]) {
        foreach ($entry in @($settings.hooks.$ev)) {
            $isOurs = $false
            foreach ($h in @($entry.hooks)) { if ($h.command -like '*clawdex-hook*') { $isOurs = $true } }
            if (-not $isOurs) { $keep += $entry }
        }
    }
    $ours = [pscustomobject]@{ hooks = @([pscustomobject]@{ type = 'command'; command = $cmd; timeout = 5 }) }
    $settings.hooks | Add-Member -NotePropertyName $ev -NotePropertyValue ([object[]](@($keep) + $ours)) -Force
}
[IO.File]::WriteAllText($settingsPath, ($settings | ConvertTo-Json -Depth 20), (New-Object Text.UTF8Encoding($false)))
Write-Host "hooks wired into $settingsPath (backup: settings.json.clawdex-backup)"

# 4) desktop shortcut (icon = the pet itself)
& powershell.exe -NoProfile -ExecutionPolicy Bypass -STA -File $mainScript -Command icon
$lnkPath = Join-Path $DesktopDir 'Clawdex Pet.lnk'
$ws = New-Object -ComObject WScript.Shell
$lnk = $ws.CreateShortcut($lnkPath)
$lnk.TargetPath = Join-Path $env:SystemRoot 'System32\wscript.exe'
$lnk.Arguments = '//B //Nologo "' + (Join-Path $Root 'clawdex-launch.vbs') + '"'
$lnk.WorkingDirectory = $Root
$lnk.Description = 'Start the clawdex pet (Claude Code desktop pet)'
$ico = Join-Path $Root 'clawdex.ico'
if (Test-Path $ico) { $lnk.IconLocation = $ico }
$lnk.Save()
Write-Host "shortcut: $lnkPath"

# 5) go
Start-Process wscript.exe -ArgumentList '//B', '//Nologo', ('"' + (Join-Path $Root 'clawdex-launch.vbs') + '"')
Write-Host 'done.'
