$ErrorActionPreference='Stop'
if(-not $env:GITHUB_ACTIONS){throw 'Ephemeral GitHub Actions only'}
Add-Type @'
using System;
using System.Runtime.InteropServices;
public class NativeDisplay {
 [StructLayout(LayoutKind.Sequential, CharSet=CharSet.Unicode)]
 public struct DEVMODE {
  [MarshalAs(UnmanagedType.ByValTStr,SizeConst=32)] public string dmDeviceName;
  public ushort dmSpecVersion,dmDriverVersion,dmSize,dmDriverExtra;
  public uint dmFields;
  public int dmPositionX,dmPositionY;
  public uint dmDisplayOrientation,dmDisplayFixedOutput;
  public short dmColor,dmDuplex,dmYResolution,dmTTOption,dmCollate;
  [MarshalAs(UnmanagedType.ByValTStr,SizeConst=32)] public string dmFormName;
  public ushort dmLogPixels;
  public uint dmBitsPerPel,dmPelsWidth,dmPelsHeight,dmDisplayFlags,dmDisplayFrequency;
  public uint dmICMMethod,dmICMIntent,dmMediaType,dmDitherType,dmReserved1,dmReserved2,dmPanningWidth,dmPanningHeight;
 }
 [DllImport("user32.dll",CharSet=CharSet.Unicode)] public static extern bool EnumDisplaySettings(string device,int mode,ref DEVMODE devmode);
 [DllImport("user32.dll",CharSet=CharSet.Unicode)] public static extern int ChangeDisplaySettings(ref DEVMODE devmode,uint flags);
}
'@
$mode=New-Object NativeDisplay+DEVMODE
$mode.dmSize=[Runtime.InteropServices.Marshal]::SizeOf($mode)
if(-not [NativeDisplay]::EnumDisplaySettings($null,-1,[ref]$mode)){throw 'No display device; cannot create real native screenshots'}
Write-Host "Initial desktop: $($mode.dmPelsWidth)x$($mode.dmPelsHeight)"
if($mode.dmPelsWidth -lt 1440 -or $mode.dmPelsHeight -lt 900){
 $mode.dmPelsWidth=1920;$mode.dmPelsHeight=1080;$mode.dmFields=0x180000
 $result=[NativeDisplay]::ChangeDisplaySettings([ref]$mode,0)
 if($result -ne 0){throw "Desktop resize unavailable: $result. No fake screenshot will be generated"}
}
