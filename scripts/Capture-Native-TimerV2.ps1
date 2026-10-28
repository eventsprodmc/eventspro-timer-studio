param(
 [Parameter(Mandatory=$true)][string]$PackagePath,
 [Parameter(Mandatory=$true)][string]$OutputDirectory,
 [string]$ExpectedPackageSha256='3db52383f2909cec1601d284903b0167e566951c62f55d7701a255cfa82d2a6e',
 [string]$ExpectedExeSha256='20d2974d1f4054dbc2074d9f08e4d93fdcd13602c80bdba02c94056f243a2d0a'
)
$ErrorActionPreference='Stop'
$diagnostics=@{stage='preflight';rectObservations=@()}
trap {
 $diagnostics.error=$_.Exception.Message;$diagnostics.stack=$_.ScriptStackTrace;$diagnostics.utc=(Get-Date).ToUniversalTime().ToString('o')
 try {if(-not (Test-Path $OutputDirectory)){New-Item -ItemType Directory -Path $OutputDirectory -Force|Out-Null};$diagnostics|ConvertTo-Json -Depth 12|Set-Content (Join-Path $OutputDirectory 'failure-diagnostic.json') -Encoding utf8} catch {Write-Host "Could not write diagnostic JSON: $($_.Exception.Message)"}
 throw
}
if($env:OS -ne 'Windows_NT' -or -not $env:GITHUB_ACTIONS -or -not $env:RUNNER_TEMP){throw 'Ephemeral Windows GitHub Actions only'}
if(Test-Path $OutputDirectory){throw 'Use a new evidence directory'}
if((Get-FileHash $PackagePath -Algorithm SHA256).Hash.ToLower() -ne $ExpectedPackageSha256){throw 'MSIX hash mismatch'}
New-Item -ItemType Directory -Path $OutputDirectory|Out-Null
$root=(Resolve-Path $OutputDirectory).Path
$work=Join-Path $env:RUNNER_TEMP ('timer-native-v2-'+[guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $work|Out-Null
# MSIX uses OPC URI-encoded names. Use the Windows SDK unpacker, not a generic ZIP extractor.
$kits=Join-Path ${env:ProgramFiles(x86)} 'Windows Kits/10/bin'
$makeAppx=@(Get-ChildItem $kits -Filter MakeAppx.exe -Recurse -ErrorAction SilentlyContinue | Where-Object {$_.Directory.Name -eq 'x64'} | Sort-Object FullName -Descending | Select-Object -First 1)
if($makeAppx.Count -ne 1){throw 'Official Windows SDK x64 MakeAppx.exe was not found'}
$payload=Join-Path $work 'payload'
if(Test-Path $payload){throw 'Unpack directory must be new'}
& ($makeAppx[0].FullName) unpack /p (Resolve-Path $PackagePath).Path /d $payload
if($LASTEXITCODE -ne 0){throw "Windows SDK MakeAppx unpack failed: $LASTEXITCODE"}
$exe=Join-Path $work 'payload/Timer PRO.exe'
if((Get-FileHash $exe -Algorithm SHA256).Hash.ToLower() -ne $ExpectedExeSha256){throw 'EXE hash mismatch'}
if(Test-Path (Join-Path $env:LOCALAPPDATA 'EventsPRO/Timer Studio/WebView2')){throw 'Existing Timer profile: refuse to overwrite'}
Add-Type @'
using System;
using System.Runtime.InteropServices;
public class NativeTimerV2 {
 [StructLayout(LayoutKind.Sequential)] public struct RECT { public int Left,Top,Right,Bottom; }
 public class Measurement { public bool WindowOk,ClientOk,DpiOverride; public int Width,Height,ClientWidth,ClientHeight,Error; public uint Dpi; public long PreviousDpiContext; }
 [DllImport("user32.dll",SetLastError=true)] public static extern bool GetWindowRect(IntPtr hwnd,out RECT rect);
 [DllImport("user32.dll",SetLastError=true)] public static extern bool GetClientRect(IntPtr hwnd,out RECT rect);
 [DllImport("user32.dll",SetLastError=true)] public static extern bool MoveWindow(IntPtr hwnd,int x,int y,int w,int h,bool repaint);
 [DllImport("user32.dll",SetLastError=true)] public static extern IntPtr SetThreadDpiAwarenessContext(IntPtr context);
 [DllImport("user32.dll")] public static extern uint GetDpiForWindow(IntPtr hwnd);
 public static Measurement Measure(IntPtr hwnd) {
  IntPtr previous=IntPtr.Zero;var m=new Measurement();
  try {
   try {previous=SetThreadDpiAwarenessContext(new IntPtr(-4));m.DpiOverride=previous!=IntPtr.Zero;m.PreviousDpiContext=previous.ToInt64();} catch(EntryPointNotFoundException){}
   RECT r,c;m.WindowOk=GetWindowRect(hwnd,out r);m.Error=Marshal.GetLastWin32Error();m.Width=r.Right-r.Left;m.Height=r.Bottom-r.Top;
   m.ClientOk=GetClientRect(hwnd,out c);m.ClientWidth=c.Right-c.Left;m.ClientHeight=c.Bottom-c.Top;
   try {m.Dpi=GetDpiForWindow(hwnd);}catch(EntryPointNotFoundException){}
   return m;
  } finally {if(previous!=IntPtr.Zero)SetThreadDpiAwarenessContext(previous);}
 }
 public static int Resize(IntPtr hwnd,int width,int height) {
  IntPtr previous=IntPtr.Zero;
  try {try{previous=SetThreadDpiAwarenessContext(new IntPtr(-4));}catch(EntryPointNotFoundException){}
   bool ok=MoveWindow(hwnd,0,0,width,height,true);int error=Marshal.GetLastWin32Error();return ok?0:(error==0?-1:error);
  } finally {if(previous!=IntPtr.Zero)SetThreadDpiAwarenessContext(previous);}
 }
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
 $diagnostics.stage='wait-title';$diagnostics.timerPid=$process.Id
 $deadline=(Get-Date).AddSeconds(60)
 $observedTitles=@();$previousObserved=$null;$nativeReady=$false
 do {
  Start-Sleep -Milliseconds 500;$process.Refresh()
  if($process.HasExited){
   @{timerPid=$process.Id;exited=$true;exitCode=$process.ExitCode;observedTitles=$observedTitles}|ConvertTo-Json -Depth 6|Set-Content (Join-Path $root 'startup-diagnostic.json') -Encoding utf8
   throw "Timer exited before expected HWND/title; ExitCode=$($process.ExitCode)"
  }
  $caption=[string]$process.MainWindowTitle
  $observation="$($process.MainWindowHandle.ToInt64()):$caption"
  if($observation -ne $previousObserved){
   $observedTitles+=@{utc=(Get-Date).ToUniversalTime().ToString('o');hwnd=$process.MainWindowHandle.ToInt64();title=$caption}
   Write-Host "Own Timer PID=$($process.Id), HWND=$($process.MainWindowHandle.ToInt64()), observed title=[$caption]"
   $previousObserved=$observation
  }
  $diagnostics.observedTitles=$observedTitles
  $nativeReady=$process.MainWindowHandle -ne 0 -and $caption -match '^Timer PRO'
 } while(-not $nativeReady -and (Get-Date) -lt $deadline)
 @{timerPid=$process.Id;exited=$false;ready=$nativeReady;expectedTitlePattern='^Timer PRO';observedTitles=$observedTitles}|ConvertTo-Json -Depth 6|Set-Content (Join-Path $root 'startup-diagnostic.json') -Encoding utf8
 if(-not $nativeReady){throw "Expected own Timer HWND/title was not ready within 60 seconds; last HWND=$($process.MainWindowHandle.ToInt64()), title=[$caption]"}
 $diagnostics.stage='wait-initial-size';$stable=0;$lastSize='';$sizeDeadline=(Get-Date).AddSeconds(12)
 do {
  $measurement=[NativeTimerV2]::Measure($process.MainWindowHandle)
  $observation=@{utc=(Get-Date).ToUniversalTime().ToString('o');phase='before-resize';windowOk=$measurement.WindowOk;width=$measurement.Width;height=$measurement.Height;clientWidth=$measurement.ClientWidth;clientHeight=$measurement.ClientHeight;dpi=$measurement.Dpi;dpiOverride=$measurement.DpiOverride;win32Error=$measurement.Error}
  $diagnostics.rectObservations+=,$observation
  $size="$($measurement.Width)x$($measurement.Height)/$($measurement.ClientWidth)x$($measurement.ClientHeight)"
  if($size -eq $lastSize){$stable++}else{$stable=0;Write-Host "Own native bounds before resize=$size DPI=$($measurement.Dpi) aware=$($measurement.DpiOverride) GetWindowRect=$($measurement.WindowOk) error=$($measurement.Error)"}
  $lastSize=$size;Start-Sleep -Milliseconds 500
 } while($stable -lt 3 -and (Get-Date) -lt $sizeDeadline)
 $diagnostics.stage='resize';$resizeError=[NativeTimerV2]::Resize($process.MainWindowHandle,1440,1000);$diagnostics.resizeWin32Error=$resizeError
 Write-Host "MoveWindow requested real 1440x1000; error=$resizeError"
 if($resizeError -ne 0){throw "MoveWindow failed with Win32Error=$resizeError; prior bounds=$lastSize DPI=$($measurement.Dpi)"}
 $stable=0;$lastSize='';$sizeDeadline=(Get-Date).AddSeconds(12)
 do {
  $measurement=[NativeTimerV2]::Measure($process.MainWindowHandle)
  $diagnostics.rectObservations+=,@{utc=(Get-Date).ToUniversalTime().ToString('o');phase='after-resize';windowOk=$measurement.WindowOk;width=$measurement.Width;height=$measurement.Height;clientWidth=$measurement.ClientWidth;clientHeight=$measurement.ClientHeight;dpi=$measurement.Dpi;dpiOverride=$measurement.DpiOverride;win32Error=$measurement.Error}
  $size="$($measurement.Width)x$($measurement.Height)/$($measurement.ClientWidth)x$($measurement.ClientHeight)"
  if($size -eq $lastSize){$stable++}else{$stable=0;Write-Host "Own native bounds after resize=$size DPI=$($measurement.Dpi) aware=$($measurement.DpiOverride) GetWindowRect=$($measurement.WindowOk) error=$($measurement.Error)"}
  $lastSize=$size;Start-Sleep -Milliseconds 500
 } while($stable -lt 3 -and (Get-Date) -lt $sizeDeadline)
 # Bounds are diagnostic, not a substitute for actual renderer metrics. The unchanged CDP helper enforces viewport and PNG >=1366x768.
 $diagnostics|ConvertTo-Json -Depth 12|Set-Content (Join-Path $root 'window-diagnostic.json') -Encoding utf8
 $diagnostics.stage='cdp-listener'
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
 $provenance=@{packageSha256=$ExpectedPackageSha256;exeSha256=$ExpectedExeSha256;exePath=$exe;timerPid=$process.Id;hwnd=$process.MainWindowHandle.ToInt64();windowTitle=$process.MainWindowTitle;windowWidth=$measurement.Width;windowHeight=$measurement.Height;clientWidth=$measurement.ClientWidth;clientHeight=$measurement.ClientHeight;windowDpi=$measurement.Dpi;cdpPort=$port;listenerAddresses=@($connections.LocalAddress);processChain=$chain;expectedTargetUrl='http://127.0.0.1:9140/timer.html';source='Actual WebView2 content surface created by exact Windows Timer executable; no Win32 frame';physicalWindowsAcceptance=$false;storeIdentityInstallationTested=$false}
 $provenance|ConvertTo-Json -Depth 8|Set-Content (Join-Path $root 'native-provenance.json') -Encoding utf8
 $diagnostics.stage='renderer-capture'
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
