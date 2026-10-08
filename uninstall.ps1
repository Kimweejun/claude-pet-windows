# Removes the clawdex hooks from ~\.claude\settings.json, the desktop shortcut and stops the pet.
param([string]$DesktopDir = [Environment]::GetFolderPath('Desktop'))
$Root = Join-Path $env:USERPROFILE '.clawdex'
& powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $Root 'clawdex.ps1') -Command tuck
$settingsPath = Join-Path $env:USERPROFILE '.claude\settings.json'
if (Test-Path $settingsPath) {
    $settings = Get-Content $settingsPath -Raw | ConvertFrom-Json
    if ($settings.PSObject.Properties['hooks']) {
        foreach ($p in @($settings.hooks.PSObject.Properties)) {
            $keep = @()
            foreach ($entry in @($p.Value)) {
                $isOurs = $false
                foreach ($h in @($entry.hooks)) { if ($h.command -like '*clawdex-hook*') { $isOurs = $true } }
                if (-not $isOurs) { $keep += $entry }
            }
            if ($keep.Count -gt 0) { $settings.hooks | Add-Member -NotePropertyName $p.Name -NotePropertyValue ([object[]]$keep) -Force }
            else { $settings.hooks.PSObject.Properties.Remove($p.Name) }
        }
        if (@($settings.hooks.PSObject.Properties).Count -eq 0) { $settings.PSObject.Properties.Remove('hooks') }
    }
    [IO.File]::WriteAllText($settingsPath, ($settings | ConvertTo-Json -Depth 20), (New-Object Text.UTF8Encoding($false)))
}
Remove-Item (Join-Path $DesktopDir 'Clawdex Pet.lnk') -ErrorAction SilentlyContinue
Write-Host 'clawdex hooks and shortcut removed. Delete ~\.clawdex yourself to remove the files.'
