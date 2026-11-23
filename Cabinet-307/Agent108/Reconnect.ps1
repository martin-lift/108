param([string]$Profile = '', [switch]$CheckOnly)
$ErrorActionPreference = 'Stop'
if (-not $Profile -and -not $CheckOnly) { $Profile = [string](Get-Content -LiteralPath (Join-Path $PSScriptRoot 'Settings.json') -Raw | ConvertFrom-Json).profile }
if (-not ('Classroom108.Wifi' -as [type])) {
Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
namespace Classroom108 {
 public static class Wifi {
  [StructLayout(LayoutKind.Sequential, CharSet=CharSet.Unicode)]
  struct Interface { public Guid Id; [MarshalAs(UnmanagedType.ByValTStr,SizeConst=256)] public string Name; public int State; }
  [StructLayout(LayoutKind.Sequential, CharSet=CharSet.Unicode)]
  struct ProfileInfo { [MarshalAs(UnmanagedType.ByValTStr,SizeConst=256)] public string Name; public uint Flags; }
  [StructLayout(LayoutKind.Sequential, CharSet=CharSet.Unicode)]
  struct Connection { public int Mode; [MarshalAs(UnmanagedType.LPWStr)] public string Profile; public IntPtr Ssid; public IntPtr Bssid; public int BssType; public uint Flags; }
  [DllImport("wlanapi.dll")] static extern uint WlanOpenHandle(uint v,IntPtr r,out uint n,out IntPtr h);
  [DllImport("wlanapi.dll")] static extern uint WlanCloseHandle(IntPtr h,IntPtr r);
  [DllImport("wlanapi.dll")] static extern uint WlanEnumInterfaces(IntPtr h,IntPtr r,out IntPtr p);
  [DllImport("wlanapi.dll")] static extern uint WlanGetProfileList(IntPtr h,ref Guid g,IntPtr r,out IntPtr p);
  [DllImport("wlanapi.dll")] static extern uint WlanConnect(IntPtr h,ref Guid g,ref Connection c,IntPtr r);
  [DllImport("wlanapi.dll")] static extern void WlanFreeMemory(IntPtr p);
  [StructLayout(LayoutKind.Sequential)]
  struct Radio { public uint Index; public int Software; public int Hardware; }
  [DllImport("wlanapi.dll")] static extern uint WlanQueryInterface(IntPtr h,ref Guid g,int op,IntPtr r,out uint size,out IntPtr data,out int source);
  [DllImport("wlanapi.dll")] static extern uint WlanSetInterface(IntPtr h,ref Guid g,int op,uint size,ref Radio radio,IntPtr r);
  static bool EnableSoftwareRadio(IntPtr h,ref Guid id) {
   IntPtr data=IntPtr.Zero; uint size; int source; bool changed=false;
   Check(WlanQueryInterface(h,ref id,4,IntPtr.Zero,out size,out data,out source));
   try {
    if(size<4) throw new InvalidOperationException("Invalid radio state.");
    int count=Marshal.ReadInt32(data), stride=Marshal.SizeOf(typeof(Radio));
    if(count<0 || count>64 || size<4+count*stride) throw new InvalidOperationException("Invalid PHY count.");
    for(int i=0;i<count;i++) {
     Radio radio=(Radio)Marshal.PtrToStructure(IntPtr.Add(data,4+i*stride),typeof(Radio));
     if(radio.Software==2 && radio.Hardware==1) {
      radio.Software=1;
      Check(WlanSetInterface(h,ref id,4,(uint)stride,ref radio,IntPtr.Zero));
      changed=true;
     }
    }
   } finally { if(data!=IntPtr.Zero) WlanFreeMemory(data); }
   return changed;
  }
  static void Check(uint code) { if(code!=0) throw new System.ComponentModel.Win32Exception((int)code); }
  public static int Run(string profile,bool checkOnly) {
   IntPtr h=IntPtr.Zero, list=IntPtr.Zero; uint version; int found=0;
   Check(WlanOpenHandle(2,IntPtr.Zero,out version,out h));
   try {
    Check(WlanEnumInterfaces(h,IntPtr.Zero,out list));
    int count=Marshal.ReadInt32(list);
    for(int i=0;i<count;i++) {
     Interface item=(Interface)Marshal.PtrToStructure(IntPtr.Add(list,8+i*Marshal.SizeOf(typeof(Interface))),typeof(Interface));
     IntPtr profiles=IntPtr.Zero;
     try {
      Check(WlanGetProfileList(h,ref item.Id,IntPtr.Zero,out profiles));
      for(int j=0;j<Marshal.ReadInt32(profiles);j++) {
       ProfileInfo p=(ProfileInfo)Marshal.PtrToStructure(IntPtr.Add(profiles,8+j*Marshal.SizeOf(typeof(ProfileInfo))),typeof(ProfileInfo));
       if(p.Name==profile && (p.Flags & 2)==0) {
        found++;
        // Only disconnected interfaces. Never interrupt connected/connecting interfaces.
        if(!checkOnly && item.State==4) {
         // Allow the driver to finish powering up before the next scheduled connection attempt.
         if(EnableSoftwareRadio(h,ref item.Id)) break;
         Connection c=new Connection {Mode=0,Profile=profile,BssType=1};
         Check(WlanConnect(h,ref item.Id,ref c,IntPtr.Zero));
        }
        break;
       }
      }
     } finally { if(profiles!=IntPtr.Zero) WlanFreeMemory(profiles); }
    }
   } finally {if(list!=IntPtr.Zero) WlanFreeMemory(list); WlanCloseHandle(h,IntPtr.Zero);}
   return found;
  }
 }
}
'@
}
if ([string]::IsNullOrWhiteSpace($Profile) -or $Profile.Length -gt 32) { throw 'Invalid Wi-Fi profile.' }
$count = [Classroom108.Wifi]::Run($Profile, $CheckOnly.IsPresent)
if ($CheckOnly) { $count } elseif ($count -eq 0) { exit 2 }
