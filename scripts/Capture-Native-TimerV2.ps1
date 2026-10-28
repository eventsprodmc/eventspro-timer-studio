param(
 [Parameter(Mandatory=$true)][string]$PackagePath,
 [Parameter(Mandatory=$true)][string]$OutputDirectory,
 [string]$ExpectedPackageSha256='3db52383f2909cec1601d284903b0167e566951c62f55d7701a255cfa82d2a6e',
 [string]$ExpectedExeSha256='20d2974d1f4054dbc2074d9f08e4d93fdcd13602c80bdba02c94056f243a2d0a'
)
$ErrorActionPreference='Stop'
if($env:OS -ne 'Windows_NT' -or -not $env:GITHUB_ACTIONS -or -not $env:RUNNER_TEMP){throw 'Ephemeral Windows GitHub Actions only'}
if(Test-Path $OutputDirectory){throw 'Use a new evidence directory'}
if((Get-FileHash $PackagePath -Algorithm SHA256).Hash.ToLower() -ne $ExpectedPackageSha256){throw 'MSIX hash mismatch'}
New-Item -ItemType Directory -Path $OutputDirectory|Out-Null
$root=(Resolve-Path $OutputDirectory).Path
$work=Join-Path $env:RUNNER_TEMP ('timer-native-v2-'+[guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $work|Out-Null
Copy-Item $PackagePath (Join-Path $work 'package.zip')
Expand-Archive (Join-Path $work 'package.zip') (Join-Path $work 'payload')
$exe=Join-Path $work 'payload/Timer PRO.exe'
if((Get-FileHash $exe -Algorithm SHA256).Hash.ToLower() -ne $ExpectedExeSha256){throw 'EXE hash mismatch'}
if(Test-Path (Join-Path $env:LOCALAPPDATA 'EventsPRO/Timer Studio/WebView2')){throw 'Existing Timer profile: refuse to overwrite'}
Add-Type @'
using System;
using System.Runtime.InteropServices;
public class NativeTimerV2 {
 [StructLayout(LayoutKind.Sequential)] public struct RECT { public int Left,Top,Right,Bottom; }
 [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr hwnd,out RECT rect);
 [DllImport("user32.dll")] public static extern bool MoveWindow(IntPtr hwnd,int x,int y,int w,int h,bool repaint);
}
'@
$listener=New-Object Net.Sockets.TcpListener([Net.IPAddress]::Loopback,0)
$listener.Start();$port=$listener.LocalEndpoint.Port;$listener.Stop()
$process=$null
try {
 $info=New-Object Diagnostics.ProcessStartInfo
 $info.FileName=$exe;$info.WorkingDirectory=Split-Path $exe;$info.UseShellExecute=$false
 # Microsoft-documented override, inherited only by this app and its WebView2 children.
 $info.Environment['WEBVIEW2_ADDITIONAL_BROWSER_ARGUMENTS']="--remote-debugging-port=$port --remote-debugging-address=127.0.0.1"
 $process=[Diagnostics.Process]::Start($info)
 $deadline=(Get-Date).AddSeconds(60)
 do {Start-Sleep -Milliseconds 500;$process.Refresh();if($process.HasExited){throw 'Timer exited before HWND creation'}} while($process.MainWindowHandle -eq 0 -and (Get-Date) -lt $deadline)
 if($process.MainWindowHandle -eq 0){throw 'No native Timer HWND; stop without alternate screenshots'}
 if($process.MainWindowTitle -notmatch 'Timer'){throw 'Unexpected native window title'}
 if(-not [NativeTimerV2]::MoveWindow($process.MainWindowHandle,0,0,1440,1000,$true)){throw 'MoveWindow failed'}
 $rect=New-Object NativeTimerV2+RECT
 if(-not [NativeTimerV2]::GetWindowRect($process.MainWindowHandle,[ref]$rect)){throw 'GetWindowRect failed'}
 if(($rect.Right-$rect.Left) -lt 1366 -or ($rect.Bottom-$rect.Top) -lt 768){throw 'Real native HWND too small'}
 $deadline=(Get-Date).AddSeconds(45);$connections=@()
 do {$connections=@(Get-NetTCPConnection -LocalPort $port -State Listen -ErrorAction SilentlyContinue);if(-not $connections.Count){Start-Sleep -Milliseconds 500}} while(-not $connections.Count -and (Get-Date) -lt $deadline)
 if(-not $connections.Count){throw 'No WebView2 debug listener'}
 if(@($connections|Where-Object {$_.LocalAddress -notin @('127.0.0.1','::1')}).Count){throw 'Debug listener is not loopback-only'}
 $owners=@($connections.OwningProcess|Select-Object -Unique)
 if($owners.Count -ne 1){throw 'Ambiguous WebView2 listener owner'}
 $owner=Get-CimInstance Win32_Process -Filter "ProcessId=$($owners[0])"
 if($owner.Name -ne 'msedgewebview2.exe'){throw 'CDP owner is not Microsoft WebView2'}
 $ancestor=$owner;$chain=@();$found=$false
 for($n=0;$n -lt 24 -and $ancestor;$n++){
  $chain+=@{id=[int]$ancestor.ProcessId;parent=[int]$ancestor.ParentProcessId;name=$ancestor.Name}
  if($ancestor.ProcessId -eq $process.Id){$found=$true;break}
  $ancestor=Get-CimInstance Win32_Process -Filter "ProcessId=$($ancestor.ParentProcessId)" -ErrorAction SilentlyContinue
 }
 if(-not $found){throw 'WebView2 listener does not descend from the exact Timer EXE'}
 $provenance=@{packageSha256=$ExpectedPackageSha256;exeSha256=$ExpectedExeSha256;exePath=$exe;timerPid=$process.Id;hwnd=$process.MainWindowHandle.ToInt64();windowTitle=$process.MainWindowTitle;windowWidth=$rect.Right-$rect.Left;windowHeight=$rect.Bottom-$rect.Top;cdpPort=$port;listenerAddresses=@($connections.LocalAddress);processChain=$chain;expectedTargetUrl='http://127.0.0.1:9140/timer.html';source='Actual WebView2 content surface created by exact Windows Timer executable; no Win32 frame';physicalWindowsAcceptance=$false;storeIdentityInstallationTested=$false}
 $provenance|ConvertTo-Json -Depth 8|Set-Content (Join-Path $root 'native-provenance.json') -Encoding utf8
 & node (Join-Path $PSScriptRoot 'capture-webview-content.mjs') $port $root
 if($LASTEXITCODE -ne 0){throw "Actual WebView2 capture failed: $LASTEXITCODE"}
 Add-Type -AssemblyName System.Drawing
 $image=Join-Path $root 'Timer-PRO-Windows-WebView2-content.png'
 $bitmap=[Drawing.Bitmap]::FromFile($image)
 try {
  $colors=New-Object 'System.Collections.Generic.HashSet[int]'
  for($x=0;$x -lt $bitmap.Width;$x+=16){for($y=0;$y -lt $bitmap.Height;$y+=16){[void]$colors.Add($bitmap.GetPixel($x,$y).ToArgb())}}
  if($colors.Count -lt 32){throw 'Renderer screenshot is empty or visually unavailable; no substitute accepted'}
 } finally {$bitmap.Dispose()}
 Write-Host "Real renderer capture accepted structurally: $($colors.Count) sampled colors; visual review remains required"

} finally {
 # No parent environment variable or registry setting was changed.
 if($info){$info.Environment.Remove('WEBVIEW2_ADDITIONAL_BROWSER_ARGUMENTS')|Out-Null}
 if($process -and -not $process.HasExited){Stop-Process -Id $process.Id}
}
