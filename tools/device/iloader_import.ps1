# Install an IPA on the iPhone through iloader's "Import IPA" button, reliably.
# Why: iloader's file picker ignores a typed/SetValue path and installs whatever list item is
# highlighted (it kept installing the stock StikDebug IPA). Invoking the list item itself
# (= double-click) is the only method that installed the right file (2026-10-14).
# 2026-10-16: iloader v2.3.x (Tauri) has a hidden "Tao Thread Event Target" window as
# MainWindowHandle, so we find the real window (class "Tauri Window") among the desktop's children.
# Invoke() on the button blocks while the modal picker is open, so it runs in a background job.
# Usage: pwsh -File iloader_import.ps1 -IpaName GpsSim-app-62a8cb1 [-DryRun]
#   -DryRun: only reports the window and button found, clicks nothing, installs nothing
#   - the IPA must be the ONLY .ipa in the folder the picker opens (C:\Tools\Installers\iOS-StikDebug;
#     keep the stock IPA in its stock\ subfolder)
#   - iloader shows an update prompt at start: we keep clicking its dismiss button, never update
#   - an expired Apple ID session shows a login error (-90010): we print it and exit 1
#   - verify afterwards: %TEMP%\<IpaName>.ipa_extracted gets a fresh timestamp, and
#     `python -m pymobiledevice3 apps query com.stik.stikdebug.CJA56ZFU6T` shows the new CFBundleDisplayName (U+5B9A U+4F4D U+5100)
param([Parameter(Mandatory)][string]$IpaName, [switch]$DryRun)
$dismiss = "$([char]0x5FFD)$([char]0x7565)"  # "dismiss" button label
$import  = "$([char]0x532F)$([char]0x5165) IPA"  # "Import IPA" button label
$errPat  = "$([char]0x767B)$([char]0x5165)$([char]0x5931)$([char]0x6557)|$([char]0x932F)$([char]0x8AA4)"  # login failed | error
Add-Type -AssemblyName UIAutomationClient, UIAutomationTypes
$A = [System.Windows.Automation.AutomationElement]
$TS = [System.Windows.Automation.TreeScope]
$root = $A::RootElement
$ilPids = @((Get-Process iloader -ErrorAction Stop).Id)

$donePat = "$([char]0x64CD)$([char]0x4F5C)$([char]0x5B8C)$([char]0x6210)"  # "operation complete"
$closeNames = @("$([char]0x95DC)$([char]0x9589)", [string][char]0x2715)  # close / X button labels
function Get-Win {
  $ws = @($root.FindAll($TS::Children, [System.Windows.Automation.Condition]::TrueCondition) |
    Where-Object { ($ilPids -contains $_.Current.ProcessId) -and $_.Current.ClassName -eq 'Tauri Window' })
  if ($ws.Count -gt 1) { Write-Warning "$($ws.Count) 'Tauri Window' windows found; using the first" }
  $ws | Select-Object -First 1
}
function Get-Texts($win) {
  @($win.FindAll($TS::Descendants, (New-Object System.Windows.Automation.PropertyCondition($A::ControlTypeProperty, [System.Windows.Automation.ControlType]::Text))) |
    ForEach-Object { $_.Current.Name } | Where-Object { $_ })
}
function Find-Button($win, $name) {
  $win.FindAll($TS::Descendants, (New-Object System.Windows.Automation.PropertyCondition($A::NameProperty, $name))) |
    Where-Object { $_.Current.ControlType.ProgrammaticName -match 'Button' } | Select-Object -First 1
}
# Error text that was NOT already visible before we clicked (stale modals must not count).
function Get-ErrText($win) {
  Get-Texts $win | Where-Object { $_ -match $errPat -and ($before -notcontains $_) } | Select-Object -First 1
}
$before = @()

$win = Get-Win
if (-not $win) { 'NO ILOADER WINDOW (class Tauri Window)'; exit 1 }
$d = Find-Button $win $dismiss
if ($d -and -not $DryRun) { $d.GetCurrentPattern([System.Windows.Automation.InvokePattern]::Pattern).Invoke(); Start-Sleep -Milliseconds 700 }
# Close a leftover modal (finished/failed earlier run) so it cannot be mistaken for this run's result.
if (-not $DryRun) {
  foreach ($cn in $closeNames) {
    $c = Find-Button $win $cn
    if ($c) { $c.GetCurrentPattern([System.Windows.Automation.InvokePattern]::Pattern).Invoke(); Start-Sleep -Milliseconds 700; break }
  }
}
$before = Get-Texts $win   # snapshot: only texts appearing after the pick count
$btn = Find-Button $win $import
if ($DryRun) {
  "DRYRUN window handle=$($win.Current.NativeWindowHandle) pid=$($win.Current.ProcessId); update-prompt dismiss button: $([bool]$d); import button: $([bool]$btn)"
  $e = Get-ErrText $win; if ($e) { "visible error text: $e" }
  exit 0
}
if (-not $btn) { 'IMPORT BUTTON NOT FOUND'; exit 1 }

$job = Start-Job -ScriptBlock {
  param($h, $n)
  Add-Type -AssemblyName UIAutomationClient, UIAutomationTypes
  $w = [System.Windows.Automation.AutomationElement]::FromHandle([IntPtr]$h)
  $b = $w.FindAll('Descendants', (New-Object System.Windows.Automation.PropertyCondition([System.Windows.Automation.AutomationElement]::NameProperty, $n))) |
    Where-Object { $_.Current.ControlType.ProgrammaticName -match 'Button' } | Select-Object -First 1
  $b.GetCurrentPattern([System.Windows.Automation.InvokePattern]::Pattern).Invoke()
} -ArgumentList $win.Current.NativeWindowHandle, $import

$dlg = $null
for ($i = 0; $i -lt 30 -and -not $dlg; $i++) {
  Start-Sleep -Milliseconds 500
  $dlg = $root.FindAll($TS::Descendants, (New-Object System.Windows.Automation.PropertyCondition($A::ClassNameProperty, '#32770'))) |
    Where-Object { $ilPids -contains $_.Current.ProcessId } | Select-Object -First 1
  if (-not $dlg -and $i -ge 4) {
    $e = Get-ErrText $win
    if ($e) { "ILOADER ERROR: $e"; Remove-Job $job -Force; exit 1 }
  }
}
if (-not $dlg) { 'NO PICKER'; Remove-Job $job -Force; exit 1 }
$item = $null; $all = @()
for ($i = 0; $i -lt 10 -and -not $item; $i++) {
  Start-Sleep 1
  $all = @($dlg.FindAll($TS::Descendants, (New-Object System.Windows.Automation.PropertyCondition($A::ControlTypeProperty, [System.Windows.Automation.ControlType]::ListItem))))
  $item = $all | Where-Object { $_.Current.Name -eq $IpaName -or $_.Current.Name -eq "$IpaName.ipa" } | Select-Object -First 1
}
if (-not $item) {
  "FILE NOT IN PICKER: $IpaName"
  'ITEMS: ' + (($all | ForEach-Object { $_.Current.Name }) -join ', ')
  Remove-Job $job -Force; exit 1
}
$item.GetCurrentPattern([System.Windows.Automation.InvokePattern]::Pattern).Invoke()
"invoked $IpaName at " + (Get-Date -Format HH:mm:ss)
# Wait up to 120 s for a success signal (new "done" text); error text or timeout = exit 1.
for ($i = 0; $i -lt 120; $i++) {
  Start-Sleep 1
  $w2 = Get-Win
  if ($w2) {
    $e = Get-ErrText $w2
    if ($e) { "ILOADER ERROR: $e"; Remove-Job $job -Force; exit 1 }
    $ok = Get-Texts $w2 | Where-Object { $_ -match $donePat -and ($before -notcontains $_) } | Select-Object -First 1
    if ($ok) { "DONE: $ok"; Remove-Job $job -Force; exit 0 }
  }
}
'TIMEOUT: no success signal within 120 s'
Remove-Job $job -Force
exit 1
