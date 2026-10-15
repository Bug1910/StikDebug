# UI Automation helper for the iloader desktop app: list or click its controls.
# Why: iloader v2.3.x is a Tauri app; (Get-Process iloader).MainWindowHandle points at a hidden
# "Tao Thread Event Target" window, so FromHandle(MainWindowHandle) saw nothing (2026-10-16).
# The real UI is the top-level window of class "Tauri Window" owned by an iloader process,
# so we look it up among the desktop's children instead (falls back to MainWindowHandle).
# Usage: pwsh -File uia.ps1 -List
#        pwsh -File uia.ps1 -Click <button name>
param([string]$Click = '', [switch]$List)
Add-Type -AssemblyName UIAutomationClient, UIAutomationTypes
$A = [System.Windows.Automation.AutomationElement]
$ids = @((Get-Process iloader -ErrorAction Stop).Id)
$root = $null
foreach ($w in $A::RootElement.FindAll([System.Windows.Automation.TreeScope]::Children, [System.Windows.Automation.Condition]::TrueCondition)) {
  if (($ids -contains $w.Current.ProcessId) -and $w.Current.ClassName -eq 'Tauri Window') { $root = $w; break }
}
if (-not $root) {
  $p = Get-Process iloader | Where-Object { $_.MainWindowHandle -ne 0 } | Select-Object -First 1
  if ($p) { $root = $A::FromHandle($p.MainWindowHandle) }
}
if (-not $root) { 'NO ILOADER WINDOW'; exit 1 }
$all = $root.FindAll([System.Windows.Automation.TreeScope]::Descendants, [System.Windows.Automation.Condition]::TrueCondition)
if ($List) {
  foreach ($e in $all) {
    $n = $e.Current.Name; $t = $e.Current.ControlType.ProgrammaticName
    if ($n -and ($t -match 'Button|Text|Edit|ListItem|Hyperlink')) { "{0} | {1}" -f $t, $n }
  }
}
if ($Click) {
  $hit = $null
  foreach ($e in $all) { if ($e.Current.Name -eq $Click -and $e.Current.ControlType.ProgrammaticName -match 'Button') { $hit = $e; break } }
  if (-not $hit) { "NOT FOUND: $Click"; exit 1 }
  $ip = $hit.GetCurrentPattern([System.Windows.Automation.InvokePattern]::Pattern)
  $ip.Invoke(); "CLICKED: $Click"
}
