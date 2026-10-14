# Install an IPA on the iPhone through iloader's "Import IPA" button, reliably.
# Why: iloader's file picker ignores a typed/SetValue path and installs whatever list item is
# highlighted (it kept installing the stock StikDebug IPA). Invoking the list item itself
# (= double-click) is the only method that installed the right file (2026-10-14).
# Usage: pwsh -File iloader_import.ps1 -IpaName GpsSim-app-62a8cb1
#   - the IPA must be the ONLY .ipa in the folder the picker opens (C:\Tools\Installers\iOS-StikDebug;
#     keep the stock IPA in its stock\ subfolder)
#   - verify afterwards: %TEMP%\<IpaName>.ipa_extracted gets a fresh timestamp, and
#     `python -m pymobiledevice3 apps query com.stik.stikdebug.CJA56ZFU6T` shows the new CFBundleDisplayName (U+5B9A U+4F4D U+5100)
param([Parameter(Mandatory)][string]$IpaName)
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$dismiss = "$([char]0x5FFD)$([char]0x7565)"              # 忽略 (dismiss old result dialog)
$import  = "$([char]0x532F)$([char]0x5165) IPA"          # 匯入 IPA
Add-Type -AssemblyName UIAutomationClient, UIAutomationTypes
& "$here\uia.ps1" -Click $dismiss | Out-Null
$ilPids = (Get-Process iloader).Id
$job = Start-Job -ScriptBlock { param($h, $b) & "$h\uia.ps1" -Click $b } -ArgumentList $here, $import
$root = [System.Windows.Automation.AutomationElement]::RootElement
$dlg = $null
for ($i = 0; $i -lt 30 -and -not $dlg; $i++) {
  Start-Sleep -Milliseconds 500
  foreach ($x in $root.FindAll([System.Windows.Automation.TreeScope]::Descendants,
      (New-Object System.Windows.Automation.PropertyCondition([System.Windows.Automation.AutomationElement]::ClassNameProperty, '#32770')))) {
    if ($ilPids -contains $x.Current.ProcessId) { $dlg = $x }
  }
}
if (-not $dlg) { 'NO PICKER'; exit 1 }
$item = $null
for ($i = 0; $i -lt 10 -and -not $item; $i++) {
  Start-Sleep 1
  $item = $dlg.FindAll([System.Windows.Automation.TreeScope]::Descendants,
      (New-Object System.Windows.Automation.PropertyCondition([System.Windows.Automation.AutomationElement]::ControlTypeProperty, [System.Windows.Automation.ControlType]::ListItem))) |
    Where-Object { $_.Current.Name -eq $IpaName } | Select-Object -First 1
}
if (-not $item) { "FILE NOT IN PICKER: $IpaName"; exit 1 }
$item.GetCurrentPattern([System.Windows.Automation.InvokePattern]::Pattern).Invoke()
"invoked $IpaName at " + (Get-Date -Format HH:mm:ss)
Get-Job | Remove-Job -Force
