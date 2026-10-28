# Candidate only. Run on an isolated Windows CI desktop, never on the user's Mac.
param(
  [Parameter(Mandatory=$true)][string]$PackagePath,
  [Parameter(Mandatory=$true)][string]$OutputDirectory,
  [string]$ExpectedPackageSha256='4e5c0de235a1ed7ca027c9e3988927741e9bcb91f09a7f2ff2adec38cb3ace6c',
  [string]$ExpectedExeSha256='1ee45570f2581e50382c099d40acd861f8c58b33d6108fe948e167ce68f74694'
)
$ErrorActionPreference='Stop'
if(-not $env:GITHUB_ACTIONS -or -not $env:RUNNER_TEMP){throw 'This candidate is restricted to an ephemeral GitHub Actions runner'}
if($env:OS -ne 'Windows_NT'){throw 'A real Windows runner is required'}
if(Test-Path $OutputDirectory){throw 'Use a new evidence directory; existing files will not be changed'}
if((Get-FileHash $PackagePath -Algorithm SHA256).Hash.ToLower() -ne $ExpectedPackageSha256){throw 'MSIX hash mismatch'}
New-Item -ItemType Directory -Path $OutputDirectory|Out-Null
$root=(Resolve-Path $OutputDirectory).Path
$work=Join-Path $env:RUNNER_TEMP ('timer-native-payload-'+[guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $work|Out-Null
$zip=Join-Path $work 'package.zip'
Copy-Item $PackagePath $zip
Expand-Archive $zip (Join-Path $work 'payload')
$exe=Join-Path $work 'payload/Timer PRO.exe'
if((Get-FileHash $exe -Algorithm SHA256).Hash.ToLower() -ne $ExpectedExeSha256){throw 'EXE hash mismatch'}
Add-Type -AssemblyName System.Drawing,System.Windows.Forms
Add-Type @'
using System;
using System.Runtime.InteropServices;
public class NativeTimerCapture {
 [StructLayout(LayoutKind.Sequential)] public struct RECT { public int Left,Top,Right,Bottom; }
 [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr hWnd,out RECT rect);
 [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr hWnd);
 [DllImport("user32.dll")] public static extern bool MoveWindow(IntPtr hWnd,int X,int Y,int W,int H,bool repaint);
 [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr hWnd,int command);
}
'@
$process=$null
$profile=Join-Path $env:LOCALAPPDATA 'EventsPRO/Timer Studio/WebView2'
if(Test-Path $profile){throw 'Unexpected existing Timer profile on runner: do not overwrite private data'}
try {
 if(-not [Environment]::UserInteractive){throw 'No interactive desktop. Do not replace this evidence with a browser screenshot'}
 $screen=[Windows.Forms.Screen]::PrimaryScreen.Bounds
 if($screen.Width -lt 1440 -or $screen.Height -lt 900){throw 'Desktop too small for Store evidence'}
 $process=Start-Process -FilePath $exe -WorkingDirectory (Split-Path $exe) -PassThru
 $deadline=(Get-Date).AddSeconds(45)
 do {Start-Sleep -Milliseconds 500;$process.Refresh();if($process.HasExited){throw 'Native Timer exited before its window was ready'}} while($process.MainWindowHandle -eq 0 -and (Get-Date) -lt $deadline)
 if($process.MainWindowHandle -eq 0){throw 'No native Timer window'}
 $h=$process.MainWindowHandle
 [NativeTimerCapture]::ShowWindow($h,9)|Out-Null
 [NativeTimerCapture]::MoveWindow($h,0,0,1440,900,$true)|Out-Null
 [NativeTimerCapture]::SetForegroundWindow($h)|Out-Null
 Start-Sleep -Seconds 5
 $rect=New-Object NativeTimerCapture+RECT
 if(-not [NativeTimerCapture]::GetWindowRect($h,[ref]$rect)){throw 'Cannot read native window bounds'}
 $width=$rect.Right-$rect.Left;$height=$rect.Bottom-$rect.Top
 if($width -lt 1366 -or $height -lt 768){throw 'Unexpected native window size'}
 $bitmap=New-Object Drawing.Bitmap($width,$height)
 $graphics=[Drawing.Graphics]::FromImage($bitmap)
 try {
  $graphics.CopyFromScreen($rect.Left,$rect.Top,0,0,$bitmap.Size)
  $colors=New-Object 'System.Collections.Generic.HashSet[int]'
  for($x=0;$x -lt $width;$x+=16){for($y=0;$y -lt $height;$y+=16){[void]$colors.Add($bitmap.GetPixel($x,$y).ToArgb())}}
  if($colors.Count -lt 32){throw 'Blank or unavailable desktop capture; no screenshot accepted'}
  $image=Join-Path $root 'Timer-PRO-Windows-native.png'
  $bitmap.Save($image,[Drawing.Imaging.ImageFormat]::Png)
 } finally {$graphics.Dispose();$bitmap.Dispose()}
 $receipt=@{os=[Environment]::OSVersion.VersionString;nativeProcess=$process.Id;processPath=$process.Path;windowTitle=$process.MainWindowTitle;session=$process.SessionId;packageSha256=$ExpectedPackageSha256;exeSha256=$ExpectedExeSha256;imageSha256=(Get-FileHash $image -Algorithm SHA256).Hash.ToLower();width=$width;height=$height;distinctSampledColors=$colors.Count;source='Real Win32 window pixels on Windows; no browser rendering or mockup';packageIdentityTested=$false;physicalWindowsAcceptance=$false}
 $receipt|ConvertTo-Json -Depth 5|Set-Content (Join-Path $root 'capture-receipt.json') -Encoding utf8
} finally {if($process -and -not $process.HasExited){Stop-Process -Id $process.Id}}
