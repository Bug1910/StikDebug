param([string]$Click = '', [switch]$List)
Add-Type -AssemblyName UIAutomationClient, UIAutomationTypes
$p = Get-Process iloader -ErrorAction Stop | Select-Object -First 1
$root = [System.Windows.Automation.AutomationElement]::FromHandle($p.MainWindowHandle)
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
