# Windows UI Automation helper for the OrunDocs desktop E2E (Windows PowerShell 5.1).
# All non-ASCII strings arrive in -ArgsB64 (base64 UTF-8 JSON) so this file stays ASCII.
# Actions:
#   click : wait for a #32770 dialog of the given processes whose text matches textRegex, take a
#           screenshot, invoke the first button matching one of buttonRegexes.
#   save  : wait for the native Save dialog (titleRegex), set the file name edit to cfg.path, press Save.
#   shot  : full-screen screenshot to cfg.path.
param([Parameter(Mandatory=$true)][string]$Action,[string]$ArgsB64='')
$ErrorActionPreference='Stop'
[Console]::OutputEncoding=[Text.Encoding]::UTF8
Add-Type -AssemblyName UIAutomationClient
Add-Type -AssemblyName UIAutomationTypes
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
$cfg=New-Object PSObject
if($ArgsB64){ $cfg=[Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($ArgsB64)) | ConvertFrom-Json }
$AE=[System.Windows.Automation.AutomationElement]
$TS=[System.Windows.Automation.TreeScope]
$CT=[System.Windows.Automation.ControlType]
$TrueC=[System.Windows.Automation.Condition]::TrueCondition
$log=New-Object System.Collections.ArrayList
function W([string]$m){ $s=(Get-Date).ToString('HH:mm:ss.fff')+' '+$m; [void]$log.Add($s); [Console]::Error.WriteLine($s) }
function Shot([string]$p){
  if(-not $p){ return $null }
  try{
    $b=[System.Windows.Forms.SystemInformation]::VirtualScreen
    $bmp=New-Object System.Drawing.Bitmap($b.Width,$b.Height)
    $g=[System.Drawing.Graphics]::FromImage($bmp)
    $g.CopyFromScreen($b.Left,$b.Top,0,0,$bmp.Size)
    $bmp.Save($p,[System.Drawing.Imaging.ImageFormat]::Png); $g.Dispose(); $bmp.Dispose(); return $p
  }catch{ W ("screenshot failed: "+$_.Exception.Message); return $null }
}
function Get-Pids{
  $ids=@()
  foreach($n in @($cfg.processNames)){ $ids+=@(Get-Process -Name $n -ErrorAction SilentlyContinue | ForEach-Object { $_.Id }) }
  return ,$ids
}
function Get-Dialogs{
  $pids=Get-Pids; $res=New-Object System.Collections.ArrayList
  $winCond=New-Object System.Windows.Automation.PropertyCondition($AE::ControlTypeProperty,$CT::Window)
  try{ $tops=$AE::RootElement.FindAll($TS::Children,$TrueC) }catch{ return ,$res }
  foreach($t in $tops){
    try{
      if($pids -contains $t.Current.ProcessId){
        [void]$res.Add($t)
        foreach($k in $t.FindAll($TS::Children,$winCond)){ [void]$res.Add($k) }
      }
    }catch{}
  }
  return ,$res
}
function All-Text($w){
  $parts=@()
  try{ foreach($e in $w.FindAll($TS::Descendants,$TrueC)){ try{ if($e.Current.Name){ $parts+=$e.Current.Name } }catch{} } }catch{}
  return ($parts -join ' | ')
}
function Buttons($w){
  $c=New-Object System.Windows.Automation.PropertyCondition($AE::ControlTypeProperty,$CT::Button)
  try{ return @($w.FindAll($TS::Descendants,$c)) }catch{ return @() }
}
Add-Type @"
using System; using System.Runtime.InteropServices;
public static class E2EMouse {
  [DllImport("user32.dll")] public static extern bool SetCursorPos(int x,int y);
  [DllImport("user32.dll")] public static extern void mouse_event(uint f,uint x,uint y,uint d,UIntPtr e);
  [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr h);
  [DllImport("user32.dll")] public static extern void keybd_event(byte vk,byte scan,uint flags,UIntPtr extra);
}
"@
function Has-Pattern($el,$pat){ try{ [void]$el.GetCurrentPattern($pat); return $true }catch{ return $false } }
function Describe-All($w){
  $rows=@()
  try{ foreach($e in $w.FindAll($TS::Descendants,$TrueC)){ try{ $c=$e.Current; $rows+=@{el=$e;name=$c.Name;type=$c.ControlType.ProgrammaticName;cls=$c.ClassName;aid=$c.AutomationId;invoke=(Has-Pattern $e ([System.Windows.Automation.InvokePattern]::Pattern))} }catch{} } }catch{}
  return ,$rows
}
function Click-Mouse($el,$w){
  try{ $h=[IntPtr]$w.Current.NativeWindowHandle; if($h -ne [IntPtr]::Zero){ [void][E2EMouse]::SetForegroundWindow($h) } }catch{}
  $r=$el.Current.BoundingRectangle
  if($r.IsEmpty -or $r.Width -le 0){ return 'mouse: empty rect' }
  $x=[int]($r.X+$r.Width/2); $y=[int]($r.Y+$r.Height/2)
  [void][E2EMouse]::SetCursorPos($x,$y); Start-Sleep -Milliseconds 150
  [E2EMouse]::mouse_event(2,0,0,0,[UIntPtr]::Zero); Start-Sleep -Milliseconds 80; [E2EMouse]::mouse_event(4,0,0,0,[UIntPtr]::Zero)
  return "mouse click at $x,$y"
}
function Focus-Window($w){
  try{ $h=[IntPtr]$w.Current.NativeWindowHandle; $ok=[E2EMouse]::SetForegroundWindow($h); try{ $w.SetFocus() }catch{}; return $ok }catch{ return $false }
}
function Invoke-El($el){
  try{ $p=$el.GetCurrentPattern([System.Windows.Automation.InvokePattern]::Pattern); $p.Invoke(); return 'InvokePattern' }catch{ W ("invoke failed: "+$_.Exception.Message) }
  return 'no-pattern'
}
function Dialog-Open($w){ try{ $null=$w.Current.Name; $h=$w.Current.NativeWindowHandle; foreach($x in (Get-Dialogs)){ try{ if($x.Current.NativeWindowHandle -eq $h){ return $true } }catch{} }; return $false }catch{ return $false } }
function Out-Result($o){ $o.log=@($log); Write-Output ($o | ConvertTo-Json -Depth 6 -Compress) }

$timeout=60; if($cfg.timeoutSec){ $timeout=[int]$cfg.timeoutSec }
$deadline=(Get-Date).AddSeconds($timeout)
$seen=@{}
$started=Get-Date
$progressShotDone=$false
$firstMatch=$null

if($Action -eq 'shot'){ Out-Result @{ok=[bool](Shot $cfg.path); path=$cfg.path}; exit 0 }

if($Action -eq 'click'){
  while((Get-Date) -lt $deadline){
    if($cfg.progressShot -and -not $progressShotDone -and ((Get-Date)-$started).TotalSeconds -gt [int]$cfg.progressShotAfterSec){ Shot $cfg.progressShot | Out-Null; $progressShotDone=$true; W 'progress screenshot taken' }
    foreach($w in (Get-Dialogs)){
      try{ $nm=$w.Current.Name; $cls=$w.Current.ClassName; $wpid=$w.Current.ProcessId }catch{ continue }
      $key="$cls|$nm|$wpid"; if(-not $seen.ContainsKey($key)){ $seen[$key]=1; W ("window: "+$key) }
      if($cls -ne '#32770'){ continue }
      $text=All-Text $w
      if($cfg.textRegex -and ($text -notmatch $cfg.textRegex)){ continue }
      $rows=Describe-All $w
      $names=@($rows | Where-Object { $_.name } | ForEach-Object { $_.type.Replace('ControlType.','')+':'+$_.name+'#'+$_.aid+'/'+$_.cls+'/inv='+$_.invoke })
      if(-not $seen.ContainsKey("dump|$key")){ $seen["dump|$key"]=1; W ("dialog '"+$nm+"' elements: "+($names -join ' || ')) }
      $target=$null
      foreach($rx in @($cfg.buttonRegexes)){
        $m=@($rows | Where-Object { $_.name -and ($_.name -match $rx) -and ($_.type -ne 'ControlType.Window') -and ($_.type -ne 'ControlType.TitleBar') })
        $pref=@($m | Where-Object { $_.type -eq 'ControlType.Button' -and $_.invoke }) + @($m | Where-Object { $_.invoke }) + @($m)
        if($pref.Count -gt 0){ $target=$pref[0]; break }
      }
      if(-not $firstMatch){ $firstMatch=Get-Date }
      if(-not $target -and $cfg.keys -and ((Get-Date)-$firstMatch).TotalSeconds -gt 8){
        $sb=Shot $cfg.shotBefore
        $fg=Focus-Window $w; Start-Sleep -Milliseconds 400
        [System.Windows.Forms.SendKeys]::SendWait([string]$cfg.keys)
        W ("no invokable element; keyboard fallback '"+$cfg.keys+"' foreground="+$fg)
        $closed=$false; for($i=0;$i -lt 20;$i++){ Start-Sleep -Milliseconds 250; if(-not (Dialog-Open $w)){ $closed=$true; break } }
        Start-Sleep -Milliseconds 1200; $sa=Shot $cfg.shotAfter
        Out-Result @{ok=$closed; window=$nm; windowClass=$cls; pid=$wpid; text=$text; elements=$names; clicked=$null; method=('keyboard '+$cfg.keys+' (foreground='+$fg+')'); dialogClosed=$closed; shotBefore=$sb; shotAfter=$sa}
        exit 0
      }
      if(-not $target){ W 'no matching element yet'; Start-Sleep -Milliseconds 700; continue }
      Start-Sleep -Milliseconds 700
      $sb=Shot $cfg.shotBefore
      $tn=$target.name+' ['+$target.type+']'
      $closed=$false; $how=''
      if($target.invoke){ $how=Invoke-El $target.el; W ("invoked '"+$tn+"' via "+$how); for($i=0;$i -lt 12;$i++){ Start-Sleep -Milliseconds 250; if(-not (Dialog-Open $w)){ $closed=$true; break } } }
      if(-not $closed){ $how2=Click-Mouse $target.el $w; $how=$how+'; '+$how2; W $how2; for($i=0;$i -lt 16;$i++){ Start-Sleep -Milliseconds 250; if(-not (Dialog-Open $w)){ $closed=$true; break } } }
      if(-not $closed -and $cfg.keys){ $fg=Focus-Window $w; Start-Sleep -Milliseconds 300; [System.Windows.Forms.SendKeys]::SendWait([string]$cfg.keys); $how=$how+'; keys '+$cfg.keys+' fg='+$fg; W $how; for($i=0;$i -lt 16;$i++){ Start-Sleep -Milliseconds 250; if(-not (Dialog-Open $w)){ $closed=$true; break } } }
      Start-Sleep -Milliseconds 1200
      $sa=Shot $cfg.shotAfter
      Out-Result @{ok=$closed; window=$nm; windowClass=$cls; pid=$wpid; text=$text; elements=$names; clicked=$tn; method=$how; dialogClosed=$closed; shotBefore=$sb; shotAfter=$sa}
      exit 0
    }
    Start-Sleep -Milliseconds 500
  }
  $fs=Shot $cfg.shotOnTimeout
  Out-Result @{ok=$false; error='timeout'; seen=@($seen.Keys); shot=$fs}
  exit 1
}

if($Action -eq 'save'){
  while((Get-Date) -lt $deadline){
    foreach($w in (Get-Dialogs)){
      try{ $nm=$w.Current.Name; $cls=$w.Current.ClassName }catch{ continue }
      $key="$cls|$nm"; if(-not $seen.ContainsKey($key)){ $seen[$key]=1; W ("window: "+$key) }
      if($cls -ne '#32770'){ continue }
      if($cfg.titleRegex -and ($nm -notmatch $cfg.titleRegex)){ continue }
      if(-not $firstMatch){ $firstMatch=Get-Date }
      $rows=Describe-All $w
      if(-not $seen.ContainsKey("dump|$key")){ $seen["dump|$key"]=1; W ("save dialog elements: "+((@($rows | Where-Object { $_.type -match 'Edit|ComboBox|Button' } | ForEach-Object { $_.type.Replace('ControlType.','')+':'+$_.name+'#'+$_.aid+'/'+$_.cls })) -join ' || ')) }
      $cands=@($rows | Where-Object { $_.type -eq 'ControlType.Edit' -and (Has-Pattern $_.el ([System.Windows.Automation.ValuePattern]::Pattern)) })
      $edit=$null
      foreach($r in $cands){ if($r.aid -eq '1001'){ $edit=$r.el; break } }
      if(-not $edit){ foreach($r in $cands){ if($r.name -match 'File name|파일 이름'){ $edit=$r.el; break } } }
      if(-not $edit -and ((Get-Date)-$firstMatch).TotalSeconds -lt 6){ W 'save dialog found, file name edit not identified yet'; Start-Sleep -Milliseconds 500; continue }
      Start-Sleep -Milliseconds 700
      $sb=Shot $cfg.shotBefore
      $before=''; $how=''
      if($edit){
        try{ $before=$edit.GetCurrentPattern([System.Windows.Automation.ValuePattern]::Pattern).Current.Value }catch{}
        if($cfg.acceptDefault){ W ("accepting default file name '"+$before+"' (user just presses Save)") }
        else { $edit.GetCurrentPattern([System.Windows.Automation.ValuePattern]::Pattern).SetValue([string]$cfg.path); W ("default file name was '"+$before+"'; set to "+$cfg.path) }
        Start-Sleep -Milliseconds 400
        $btn=$null; foreach($r in $rows){ if($r.aid -eq '1' -and $r.type -eq 'ControlType.Button'){ $btn=$r; break } }
        if($btn -and $btn.invoke){ $how=(Invoke-El $btn.el)+" on '"+$btn.name+"'" } elseif($btn){ $how=Click-Mouse $btn.el $w } else { $fg=Focus-Window $w; [System.Windows.Forms.SendKeys]::SendWait('{ENTER}'); $how='Enter fg='+$fg }
      } else {
        # Fallback: the file-name box has focus when the dialog opens; type the full path and press Enter.
        $fg=Focus-Window $w; Start-Sleep -Milliseconds 300
        $esc=([string]$cfg.path) -replace '([+^%~(){}\[\]])','{$1}'
        if($cfg.acceptDefault){ [System.Windows.Forms.SendKeys]::SendWait('{ENTER}'); $how='keyboard: Enter on the default name/location (fg='+$fg+')' }
        else { [System.Windows.Forms.SendKeys]::SendWait('^a'); [System.Windows.Forms.SendKeys]::SendWait($esc); Start-Sleep -Milliseconds 300; [System.Windows.Forms.SendKeys]::SendWait('{ENTER}'); $how='keyboard: typed full path + Enter (fg='+$fg+')' }
      }
      W ("save invoked: "+$how)
      $gone=$false; for($i=0;$i -lt 40;$i++){ Start-Sleep -Milliseconds 250; $still=$false; foreach($x in (Get-Dialogs)){ try{ if($x.Current.ClassName -eq '#32770' -and $x.Current.Name -eq $nm){ $still=$true } }catch{} }; if(-not $still){ $gone=$true; break } }
      Out-Result @{ok=$gone; dialogTitle=$nm; defaultFileName=$before; acceptDefault=[bool]$cfg.acceptDefault; savedPath=$cfg.path; method=$how; dialogClosed=$gone; shot=$sb}
      exit 0
    }
    Start-Sleep -Milliseconds 400
  }
  $fs=Shot $cfg.shotOnTimeout
  Out-Result @{ok=$false; error='timeout waiting for save dialog'; seen=@($seen.Keys); shot=$fs}
  exit 1
}
Out-Result @{ok=$false; error="unknown action $Action"}
exit 2
