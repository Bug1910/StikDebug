# One-click re-sign of the GpsSim phone app (StikDebug fork) before the free-account profile expires.
# Why: free Apple ID profiles last 7 days. iloader re-installs the newest GpsSim-app-*.ipa, which
# renews the app's profile. SideStore is NOT reinstalled here (that could change its version);
# it is refreshed on the phone itself via SideStore "Refresh All".
# Steps: 1) phone reachable  2) real internet (HEAD request, adapter state is not enough on a hotspot)
#        3) read expiry  4) start iloader  5) run iloader_import.ps1  6) read expiry again.
# Usage: pwsh -File resign.ps1            (full run, reinstalls the app on the phone)
#        pwsh -File resign.ps1 -CheckOnly (steps 1-3 only, changes nothing)
# Log: C:\Tools\GpsSimPhone\logs\resign.log (one line per run)
param([switch]$CheckOnly)
$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [System.Text.UTF8Encoding]::new()
$env:PYTHONIOENCODING = 'utf-8'
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$logDir = 'C:\Tools\GpsSimPhone\logs'
$ipaDir = 'C:\Tools\Installers\iOS-StikDebug'
$iloaderExe = Join-Path $env:LOCALAPPDATA 'iloader\iloader.exe'
$appId = 'com.stik.stikdebug.CJA56ZFU6T'
$null = New-Item -ItemType Directory -Force $logDir
$loginHint = "$([char]0x767B)$([char]0x5165)"  # "login"
$loginFail = "$([char]0x767B)$([char]0x5165)$([char]0x5931)$([char]0x6557)"  # "login failed"

function Write-Log($status, $msg) {
  $line = "{0} | {1} | {2}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $status, $msg
  Add-Content -Path (Join-Path $logDir 'resign.log') -Value $line
}
function Fail($msg, $hint = '') {
  Write-Host "FAIL: $msg" -ForegroundColor Red
  if ($hint) { Write-Host $hint -ForegroundColor Yellow }
  Write-Log 'FAIL' $msg
  exit 1
}
# Returns local expiry (DateTime) of the newest profile whose app id matches $pattern, or $null.
function Get-Expiry($pattern) {
  try {
    $raw = (python -m pymobiledevice3 provision list 2>$null) -join "`n"
    if (-not $raw) { throw 'provision list returned nothing' }
    $list = $raw | ConvertFrom-Json
    $best = $null
    foreach ($p in $list) {
      $id = [string]$p.Entitlements.'application-identifier'
      if ($id -like $pattern) {
        # ConvertFrom-Json already yields a DateTime (Kind Unspecified, value is UTC): just mark it Utc.
        $utc = [DateTime]::SpecifyKind([DateTime]$p.ExpirationDate, 'Utc')
        if (-not $best -or $utc -gt $best) { $best = $utc }
      }
    }
    if ($best) { $best.ToLocalTime() } else { $null }
  } catch { Fail "cannot read profiles (provision list / JSON): $($_.Exception.Message)" 'Is the iPhone unlocked and trusted? Try again.' }
}
function Show-Expiry($label, $dt) {
  if ($dt) { "{0}: {1:yyyy-MM-dd HH:mm} local, {2:N1} days left" -f $label, $dt, ($dt - (Get-Date)).TotalDays }
  else { "${label}: profile not found" }
}

# 1) phone reachable
$mux = (python -m pymobiledevice3 usbmux list 2>$null) -join "`n"
$devs = @(); try { if ($mux) { $devs = @($mux | ConvertFrom-Json) } } catch {}
if ($devs.Count -eq 0) { Fail 'iPhone not found (usbmux list empty)' 'Plug in the iPhone by USB, unlock it, tap Trust, then run again.' }
"1) iPhone found: $($devs[0].DeviceName) iOS $($devs[0].ProductVersion) via $((($devs | ForEach-Object ConnectionType) | Select-Object -Unique) -join '/')"

# 2) real internet
try { $null = Invoke-WebRequest -Method Head https://developer.apple.com -TimeoutSec 10 -UseBasicParsing; '2) internet OK (developer.apple.com answered)' }
catch { Fail "no internet: $($_.Exception.Message)" 'Check the phone hotspot / Wi-Fi, then run again.' }

# 3) expiry before
$before = Get-Expiry "*$appId*"
Show-Expiry '3) GpsSim app (StikDebug)' $before
Show-Expiry '   SideStore (not touched here; refresh it on the phone with Refresh All)' (Get-Expiry '*com.SideStore.SideStore.*' )
if ($CheckOnly) { Write-Log 'CHECK' "ok; app expiry=$before"; 'CheckOnly: done, nothing changed.'; exit 0 }

# 4) iloader up
if (-not (Get-Process iloader -ErrorAction SilentlyContinue)) {
  if (-not (Test-Path $iloaderExe)) { Fail "iloader not found: $iloaderExe" }
  Start-Process $iloaderExe
}
Add-Type -AssemblyName UIAutomationClient, UIAutomationTypes
$ready = $false
for ($i = 0; $i -lt 40 -and -not $ready; $i++) {
  Start-Sleep 1
  $ids = @(Get-Process iloader -ErrorAction SilentlyContinue | ForEach-Object Id)
  $ready = [bool]([System.Windows.Automation.AutomationElement]::RootElement.FindAll('Children', [System.Windows.Automation.Condition]::TrueCondition) |
    Where-Object { ($ids -contains $_.Current.ProcessId) -and $_.Current.ClassName -eq 'Tauri Window' })
}
if (-not $ready) { Fail 'iloader window did not appear within 40 s' }
Start-Sleep 3
# Device area: wait for a button marked selected (label has the "selected" word); prefer the USB entry.
$A = [System.Windows.Automation.AutomationElement]
$selWord = "$([char]0x5DF2)$([char]0x9078)$([char]0x64C7)"  # "selected"
function Get-DevButtons {
  $ws = $A::RootElement.FindAll('Children', [System.Windows.Automation.Condition]::TrueCondition) |
    Where-Object { (@(Get-Process iloader -ErrorAction SilentlyContinue | ForEach-Object Id) -contains $_.Current.ProcessId) -and $_.Current.ClassName -eq 'Tauri Window' } | Select-Object -First 1
  if (-not $ws) { return @() }
  @($ws.FindAll('Descendants', (New-Object System.Windows.Automation.PropertyCondition($A::ControlTypeProperty, [System.Windows.Automation.ControlType]::Button))) |
    Where-Object { $_.Current.Name -match ' (USB|Network)( |$)' })
}
$sel = $false
for ($i = 0; $i -lt 30 -and -not $sel; $i++) {
  $btns = Get-DevButtons
  $usb = $btns | Where-Object { $_.Current.Name -match ' USB( |$)' } | Select-Object -First 1
  if ($usb -and $usb.Current.Name -notmatch $selWord) {
    $usb.GetCurrentPattern([System.Windows.Automation.InvokePattern]::Pattern).Invoke(); Start-Sleep 2
    $btns = Get-DevButtons
  }
  $sel = [bool]($btns | Where-Object { $_.Current.Name -match $selWord })
  if (-not $sel) { Start-Sleep 1 }
}
if (-not $sel) { Fail 'iloader shows no selected device after 30 s' 'Open iloader and press the device refresh button, then run again.' }
'4) iloader is up, device selected: ' + (($btns | Where-Object { $_.Current.Name -match $selWord } | ForEach-Object { $_.Current.Name }) -join ',')

# 5) install newest IPA
$ipas = @(Get-ChildItem $ipaDir -Filter 'GpsSim-app-*.ipa' -File | Sort-Object LastWriteTime -Descending)
if ($ipas.Count -eq 0) { Fail "no GpsSim-app-*.ipa in $ipaDir" }
if ($ipas.Count -gt 1) { Write-Warning "$($ipas.Count) IPAs found; picker may confuse them. Using newest: $($ipas[0].Name)" }
$name = $ipas[0].BaseName
"5) installing $name (about 1 minute)..."
$out = & pwsh -NoProfile -File (Join-Path $here 'iloader_import.ps1') -IpaName $name 2>&1 | ForEach-Object { "$_" }
$out | ForEach-Object { "   $_" }
if ($LASTEXITCODE -ne 0) {
  $txt = $out -join ' '
  if ($txt -match 'ILOADER ERROR' -and $txt -match "$loginFail|-90010") {
    Fail "login failed in iloader: $txt" "$([char]0x767B)$([char]0x5165)$([char]0x5931)$([char]0x6557)$([char]0xFF1A)$([char]0x8ACB)$([char]0x5728) iloader $([char]0x91CD)$([char]0x65B0)$([char]0x767B)$([char]0x5165) Apple ID$([char]0xFF0C)$([char]0x518D)$([char]0x6309)$([char]0x4E00)$([char]0x6B21)$([char]0x300C)$([char]0x5B9A)$([char]0x4F4D)$([char]0x5100)$([char]0x7E8C)$([char]0x7C3D)$([char]0x300D)$([char]0x3002)"
  }
  if ($txt -match 'FILE NOT IN PICKER') {
    Fail "iloader_import failed: $txt" "Hint: iloader's file dialog must open in $ipaDir (the IPA must be listed there, stock IPA in its stock\ subfolder)."
  }
  Fail "iloader_import failed: $txt"
}

# 6) expiry after
Start-Sleep 5
$after = Get-Expiry "*$appId*"
Show-Expiry '6) before' $before
Show-Expiry '   after ' $after
if ($after -and (-not $before -or $after -gt $before)) { Write-Log 'OK' "installed $name; expiry $before -> $after"; 'DONE: re-signed.' }
else { Fail "installed but expiry did not move (before=$before after=$after)" 'Give the phone a few seconds and run resign.ps1 -CheckOnly to re-read.' }
