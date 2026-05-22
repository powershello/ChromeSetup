param (
  [switch]$Silent,
  [switch]$Force,
  [switch]$SearXNG,
  [switch]$Uninstall
)

if (!(Get-Item -LiteralPath 'Registry::HKEY_USERS\S-1-5-19' -EA 0)) {
  $psArgs = $PSBoundParameters.Keys | ForEach-Object { "-$_" }
  Start-Process powershell ("-ep Bypass -File `"{0}`" {1}" -f $PSCommandPath, ($psArgs -join ' ')) -Verb RunAs
  exit
}

$ProgressPreference = 'SilentlyContinue'
$tmpDir = (New-Item "$env:Temp\$([guid]::NewGuid().ToString())" -ItemType Directory -force).FullName

#region FUNCTIONS
function Write-Log {
  param(
    [Parameter(Mandatory)]
    [string]$Message,
    [ValidateSet('INFO', 'OK', 'FAIL', 'WARN')]
    [string]$Level = 'INFO'
  )
  $symbol, $color, $logLevel = switch ($Level) {
    'OK' { ' + ', 'Green', 'SUCCESS' }
    'FAIL' { ' x ', 'Red', 'ERROR' }
    'WARN' { ' ! ', 'Yellow', 'WARNING' }
    default { ' * ', $null, 'INFO' }
  }
  if ($color) { Write-Host "[$symbol] $Message" -f $color }
  else { Write-Host "[$symbol] $Message" }
  
  if ($tmpDir -and (Test-Path $tmpDir)) {
    $logFile = Join-Path $tmpDir 'ChromeLog.txt'
    $timestamp = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
    try { [IO.File]::AppendAllText($logFile, "[$timestamp] [$logLevel] $Message`r`n") } catch {}
  }
}

function Stop-Script {
  if ($tmpDir -and (Test-Path $tmpDir)) {
    $log = Join-Path $tmpDir 'ChromeLog.txt'
    if (Test-Path $log) { Start-Process notepad.exe $log -win max -wait }
    Remove-Item $tmpDir -r -force -EA 0
  }
  exit 1
}

function Remove-Tasks {
  param([string]$Name)
  $tasks = @(Get-ScheduledTask -EA 0 | Where-Object { $_.TaskPath -match $Name -or $_.TaskName -match $Name })
  if ($tasks) {
    Write-Log "Removing $Name scheduled tasks..."
    foreach ($task in $tasks) {
      $task | Unregister-ScheduledTask -Confirm:$false
      Write-Log "Successfully removed $($task.TaskName)" OK
    }

    $scheduler = New-Object -ComObject Schedule.Service
    $scheduler.Connect()
    $root = $scheduler.GetFolder('\')

    function Remove-TaskFolder($folder, $MatchName) {
      foreach ($subFolder in @($folder.GetFolders(0))) {
        Remove-TaskFolder $subFolder $MatchName
        if ($subFolder.Name -match $MatchName) {
          try {
            $folder.DeleteFolder($subFolder.Name, 0)
            Write-Log "Successfully removed $($subFolder.Name)" OK
          }
          catch { Write-Log "Removal of $($subFolder.Name) failed with error: $($_.Exception.Message)" FAIL }
        }
      }
    }

    Remove-TaskFolder $root $Name
  }
}

function Import-Reg {
  param([string]$RegContent)
  $reg = "$tmpDir\chrome.reg"
  try {
    Set-Content $reg -Value $RegContent -Encoding Unicode -force
    reg.exe import $reg 2>$null
    if ($LASTEXITCODE -ne 0) { Write-Log "Registry import of $reg failed with exit code: $LASTEXITCODE" FAIL }
    else { Write-Log "Successfully imported $reg" OK }
  }
  finally { Remove-Item $reg -force }
}

# https://github.com/rapid-community/RapidOS/blob/main/RapidOS%20Sources/Executables/Software.ps1#L553
function Merge-JsonObject ([PSCustomObject]$Target, [PSCustomObject]$Source) {
  foreach ($prop in $Source.PSObject.Properties) {
    $existing = $Target.PSObject.Properties[$prop.Name]
    if ($existing -and $existing.Value -is [PSCustomObject] -and $prop.Value -is [PSCustomObject]) { Merge-JsonObject $existing.Value $prop.Value }
    elseif ($existing) { $existing.Value = $prop.Value }
    else { $Target | Add-Member -NotePropertyName $prop.Name -NotePropertyValue $prop.Value }
  }
}

function Format-Bytes {
  param([long]$Bytes)
  switch ($Bytes) {
    { $_ -ge 1TB } { return "$([math]::Round($_ / 1TB, 2)) TB" }
    { $_ -ge 1GB } { return "$([math]::Round($_ / 1GB, 2)) GB" }
    { $_ -ge 1MB } { return "$([math]::Round($_ / 1MB, 2)) MB" }
    { $_ -ge 1KB } { return "$([math]::Round($_ / 1KB, 2)) KB" }
    default { return "$_ B" }
  }
}

#region UNINSTALLATION

if ($Uninstall) {
  Get-Process | Where-Object { $_.Description -match 'Google' } | Stop-Process -force

  $uninstalled = $false

  # MSI Uninstall
  $msiUninstallPath = 'Registry::HKEY_LOCAL_MACHINE\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall'
  $ChromeMSI = Get-ChildItem $msiUninstallPath | Get-ItemProperty -EA 0 | Where-Object { $_.DisplayName -match 'Google Chrome' -and $_.UninstallString -match 'msiexec' } | Select-Object -First 1

  if ($ChromeMSI) {
    Write-Log "Uninstalling $($ChromeMSI.DisplayName)..."
    Start-Process cmd.exe -ArgumentList "/c $($ChromeMSI.UninstallString) /qn /norestart" -wait -NoNewWindow
    $uninstalled = $true
  }

  # EXE Uninstall
  $exeUninstallPath = 'Registry::HKEY_LOCAL_MACHINE\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall'
  $ChromeEXE = Get-ChildItem $exeUninstallPath |
  Get-ItemProperty -EA 0 | Where-Object { $_.DisplayName -match 'Google Chrome' -and $_.UninstallString -match 'setup\.exe' } | Select-Object -First 1

  if ($ChromeEXE) {
    Write-Log "Uninstalling $($ChromeEXE.DisplayName)..."
    Start-Process cmd.exe -ArgumentList "/c $($ChromeEXE.UninstallString) --force-uninstall --delete-profile" -wait -NoNewWindow
    $uninstalled = $true
  }

  # Cleanup
  $localAppDataGoogle = "$env:LOCALAPPDATA\Google"
  if (Test-Path $localAppDataGoogle) { Remove-Item $localAppDataGoogle -r -force }

  @('Registry::HKEY_LOCAL_MACHINE\SOFTWARE\Policies\Google',
    'Registry::HKEY_LOCAL_MACHINE\SOFTWARE\WOW6432Node\Google') | Where-Object { Test-Path $_ } | ForEach-Object {
    Remove-Item $_ -Recurse -Force -EA 0
    Write-Log "Successfully removed $_" OK
  }

  @("$env:PUBLIC\Desktop\Google Chrome.lnk",
    "$env:USERPROFILE\Desktop\Google Chrome.lnk",
    "$env:APPDATA\Microsoft\Internet Explorer\Quick Launch\Google Chrome.lnk",
    "$env:SystemRoot\System32\config\systemprofile\AppData\Roaming\Microsoft\Internet Explorer\Quick Launch\Google Chrome.lnk",
    "$env:ProgramData\Microsoft\Windows\Start Menu\Programs\Google Chrome.lnk",
    "$env:APPDATA\Microsoft\Windows\Start Menu\Programs\Google Chrome.lnk"
  ) | Where-Object { Test-Path $_ } | ForEach-Object {
    Remove-Item $_ -Force -EA 0
    Write-Log "Successfully removed $_" OK
  }

  Remove-Tasks 'Google'

  if ($uninstalled) { Write-Log 'successfully uninstalled Google Chrome.' OK }
  else { Write-Log 'No Google Chrome installation was found.' WARN }

  Remove-Item $tmpDir -r -force
  Write-Host 'Press any key to continue . . . ' -NoNewline
  $null = [Console]::ReadKey($true)
  exit
}

#region INSTALLATION

$chrome = "$env:ProgramFiles\Google\Chrome\Application\chrome.exe"
if ($Force -or !(Test-Path $chrome)) {
  Write-Log 'Downloading Chrome installer...'
  $chromeSetup = Join-Path $tmpDir 'ChromeSetup.exe'
  curl.exe -#fSLo $chromeSetup 'https://dl.google.com/chrome/install/latest/chrome_installer.exe'

  if (!(Test-Path $chromeSetup) -or (Get-Item $chromeSetup).Length -eq 0) {
    Write-Log "Chrome installer download failed with exit code: $LASTEXITCODE" FAIL
    Stop-Script
  }
  Write-Log "Successfully downloaded to: $chromeSetup" OK

  Write-Log 'Installing Chrome. Please wait...'
  $exe = Start-Process $chromeSetup '/SILENT /INSTALL' -wait -PassThru
  if (!(Test-Path $chrome)) {
    Write-Log "Chrome installation failed with exit code: $($exe.ExitCode)" FAIL
    Stop-Script
  }

  Write-Log "Successfully installed $chrome" OK
}
else {
  Write-Log "Google Chrome is already installed at: $chrome" WARN

  Get-Process | Where-Object { $_.Description -match 'Google' } | Stop-Process -force

  $cacheFolders = @(Get-ChildItem -Path "$env:LOCALAPPDATA\Google\Chrome\User Data" -Directory -Recurse -Filter '*cache*' -EA 0)
  if ($cacheFolders) {
    Write-Log 'Cleaning Chrome cache...'
    $cachePaths = $cacheFolders.FullName
    $topLevel = $cacheFolders | Where-Object {
      $parent = $_.Parent.FullName
      -not ($cachePaths | Where-Object { $parent -eq $_ -or $parent.StartsWith($_ + '\', [System.StringComparison]::OrdinalIgnoreCase) })
    }
    $cacheBytes = 0L
    foreach ($folder in $topLevel) {
      $folderBytes = 0L
      foreach ($file in [System.IO.Directory]::EnumerateFiles($folder.FullName, '*', [System.IO.SearchOption]::AllDirectories)) {
        try { $folderBytes += [System.IO.FileInfo]::new($file).Length } catch {}
      }
      $cacheBytes += $folderBytes
      Remove-Item $folder.FullName -Recurse -Force -EA 0
    }
    Write-Log "Successfully cleaned $(Format-Bytes $cacheBytes)" OK
  }
}

#region SHORTCUTS

@("$env:PUBLIC\Desktop\Google Chrome.lnk", "$env:LOCALAPPDATA\Programs\Google Chrome.lnk") | Where-Object { Test-Path $_ } | Remove-Item -force -EA 0

# create google chrome shortcuts
$chromeFlags = '--disable-features=ExtensionManifestV2Unsupported,ExtensionManifestV2Disabled --disable-search-engine-choice-screen'
$desktopDir = [Environment]::GetFolderPath('Desktop')
$desktopLnk = Join-Path $desktopDir 'Google Chrome.lnk'

# C# helper: modify .lnk arguments via IShellLink COM while preserving AUMID via IPropertyStore
if (-not ('ShortcutEditor' -as [Type])) {
  Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
using System.Runtime.InteropServices.ComTypes;
using System.Text;
using System.Threading;

public static class ShortcutEditor {
    [DllImport("ole32.dll")] static extern int CoCreateInstance(ref Guid rclsid, IntPtr pUnk, uint ctx, ref Guid riid, out IntPtr ppv);
    [DllImport("ole32.dll")] static extern int PropVariantClear(IntPtr pvar);

    static readonly Guid CLSID_ShellLink   = new Guid("00021401-0000-0000-C000-000000000046");
    static readonly Guid IID_IShellLinkW   = new Guid("000214F9-0000-0000-C000-000000000046");
    static readonly Guid IID_IPersistFile  = new Guid("0000010B-0000-0000-C000-000000000046");
    static readonly Guid IID_IPropertyStore= new Guid("886D8EEB-8CF2-4446-8D02-CDBA1DBDCF99");
    static readonly Guid PKEY_AppUserModel_ID_fmtid = new Guid("9F4C2855-9F79-4B39-A8D0-E1D42DE1D5F3");
    const int PKEY_AppUserModel_ID_pid = 5;

    // IShellLinkW vtable slots
    // 0=QI 1=AddRef 2=Release 3=GetPath 4=GetIDList 5=SetIDList 6=GetDescription
    // 7=SetDescription 8=GetWorkingDirectory 9=SetWorkingDirectory 10=GetArguments
    // 11=SetArguments 12=GetHotkey 13=SetHotkey 14=GetShowCmd 15=SetShowCmd
    // 16=GetIconLocation 17=SetIconLocation 18=SetRelativePath 19=Resolve 20=SetPath
    [UnmanagedFunctionPointer(CallingConvention.StdCall)] delegate int FnQI(IntPtr p, ref Guid riid, out IntPtr ppv);
    [UnmanagedFunctionPointer(CallingConvention.StdCall)] delegate uint FnRelease(IntPtr p);
    [UnmanagedFunctionPointer(CallingConvention.StdCall)] delegate int FnSetArguments(IntPtr p, [MarshalAs(UnmanagedType.LPWStr)] string args);

    // IPersistFile: 0=QI 1=AddRef 2=Release 3=GetClassID 4=IsDirty 5=Load 6=Save
    [UnmanagedFunctionPointer(CallingConvention.StdCall)] delegate int FnLoad(IntPtr p, [MarshalAs(UnmanagedType.LPWStr)] string pszFileName, uint dwMode);
    [UnmanagedFunctionPointer(CallingConvention.StdCall)] delegate int FnSave(IntPtr p, [MarshalAs(UnmanagedType.LPWStr)] string pszFileName, [MarshalAs(UnmanagedType.Bool)] bool fRemember);

    // IPropertyStore: 0=QI 1=AddRef 2=Release 3=GetCount 4=GetAt 5=GetValue 6=SetValue 7=Commit
    [UnmanagedFunctionPointer(CallingConvention.StdCall)] delegate int FnGetValue(IntPtr p, IntPtr key, IntPtr propvar);
    [UnmanagedFunctionPointer(CallingConvention.StdCall)] delegate int FnSetValue(IntPtr p, IntPtr key, IntPtr propvar);
    [UnmanagedFunctionPointer(CallingConvention.StdCall)] delegate int FnCommit(IntPtr p);

    static T Vtbl<T>(IntPtr pUnk, int slot) where T : class {
        IntPtr vt = Marshal.ReadIntPtr(pUnk);
        return (T)(object)Marshal.GetDelegateForFunctionPointer(Marshal.ReadIntPtr(vt, slot * IntPtr.Size), typeof(T));
    }

    static IntPtr AllocPKEY() {
        byte[] pk = new byte[20];
        Array.Copy(PKEY_AppUserModel_ID_fmtid.ToByteArray(), 0, pk, 0, 16);
        BitConverter.GetBytes(PKEY_AppUserModel_ID_pid).CopyTo(pk, 16);
        IntPtr ptr = Marshal.AllocCoTaskMem(20);
        Marshal.Copy(pk, 0, ptr, 20);
        return ptr;
    }

    // VT_LPWSTR = 31
    static IntPtr AllocPropVariantString(string val) {
        IntPtr pv = Marshal.AllocCoTaskMem(24);
        for (int i = 0; i < 24; i++) Marshal.WriteByte(pv, i, 0);
        Marshal.WriteInt16(pv, 0, 31); // VT_LPWSTR
        IntPtr bstr = Marshal.StringToCoTaskMemUni(val);
        Marshal.WriteIntPtr(pv, 8, bstr);
        return pv;
    }

    static string ReadPropVariantString(IntPtr pv) {
        short vt = Marshal.ReadInt16(pv);
        if (vt != 31) return null;
        IntPtr sp = Marshal.ReadIntPtr(pv, 8);
        if (sp == IntPtr.Zero) return null;
        return Marshal.PtrToStringUni(sp);
    }

    delegate string StaFunc();
    static string RunOnSTA(StaFunc fn) {
        if (Thread.CurrentThread.GetApartmentState() == ApartmentState.STA) return fn();
        string r = null; Thread t = new Thread(delegate() { r = fn(); });
        t.SetApartmentState(ApartmentState.STA); t.Start(); t.Join(); return r;
    }

    /// <summary>
    /// Sets arguments and explicitly sets the AUMID on a .lnk file.
    /// </summary>
    public static void SetArgumentsAndAumid(string lnkPath, string arguments, string targetAumid) {
        RunOnSTA(delegate() {
            Guid cls = CLSID_ShellLink; Guid iid = IID_IShellLinkW; IntPtr psl;
            if (CoCreateInstance(ref cls, IntPtr.Zero, 1, ref iid, out psl) != 0) return null;
            try {
                // QI for IPersistFile and load with STGM_READWRITE (2)
                Guid iidPF = IID_IPersistFile; IntPtr ppf;
                if (Vtbl<FnQI>(psl, 0)(psl, ref iidPF, out ppf) != 0) return null;
                try {
                    if (Vtbl<FnLoad>(ppf, 5)(ppf, lnkPath, 2) != 0) return null;

                    // Set arguments via IShellLinkW::SetArguments
                    Vtbl<FnSetArguments>(psl, 11)(psl, arguments);

                    // QI for IPropertyStore — write AUMID
                    Guid iidPS = IID_IPropertyStore; IntPtr pps;
                    if (Vtbl<FnQI>(psl, 0)(psl, ref iidPS, out pps) == 0) {
                        IntPtr pkPtr = AllocPKEY();
                        IntPtr pvPtr = AllocPropVariantString(targetAumid);
                        try {
                            int hr = Vtbl<FnSetValue>(pps, 6)(pps, pkPtr, pvPtr);
                            if (hr >= 0) {
                                Vtbl<FnCommit>(pps, 7)(pps);
                            }
                        } finally { PropVariantClear(pvPtr); Marshal.FreeCoTaskMem(pvPtr); Marshal.FreeCoTaskMem(pkPtr); }
                        Vtbl<FnRelease>(pps, 2)(pps);
                    }

                    // Save via IPersistFile
                    Vtbl<FnSave>(ppf, 6)(ppf, lnkPath, true);
                    return null;
                } finally { Vtbl<FnRelease>(ppf, 2)(ppf); }
            } finally { Vtbl<FnRelease>(psl, 2)(psl); }
        });
    }
}
'@
}

$startMenuLnkAll = "$env:ProgramData\Microsoft\Windows\Start Menu\Programs\Google Chrome.lnk"
$startMenuLnkUser = "$env:APPDATA\Microsoft\Windows\Start Menu\Programs\Google Chrome.lnk"

$patchedExisting = $false
foreach ($lnk in @($startMenuLnkAll, $startMenuLnkUser)) {
  if (Test-Path $lnk) {
    [ShortcutEditor]::SetArgumentsAndAumid($lnk, $chromeFlags, 'Chrome')
    Copy-Item $lnk $desktopLnk -Force
    $patchedExisting = $true
  }
}

if (-not $patchedExisting) {
  # Fallback if the official shortcut is missing
  $WshShell = New-Object -ComObject WScript.Shell
  $Shortcut1 = $WshShell.CreateShortcut($desktopLnk)
  $Shortcut1.TargetPath = $chrome
  $Shortcut1.Arguments = $chromeFlags
  $Shortcut1.Save()
  [void][Runtime.InteropServices.Marshal]::ReleaseComObject($WshShell)
  [ShortcutEditor]::SetArgumentsAndAumid($desktopLnk, $chromeFlags, 'Chrome')
}

# Patch Chrome's file/protocol handler registry so MV2 flags apply when opening links/files.
$mv2Cmd = "`"$chrome`" $chromeFlags --single-argument %1"

Get-ChildItem 'Registry::HKEY_LOCAL_MACHINE\SOFTWARE\Classes' -EA 0 | Where-Object { $_.PSChildName -like 'Chrome*' } | ForEach-Object {
  $cmdKey = Join-Path $_.PSPath 'shell\open\command'
  if (Test-Path $cmdKey) {
    $current = (Get-ItemProperty $cmdKey).'(default)'
    if ($current -and $current -notlike "*$chromeFlags*") {
      Set-ItemProperty $cmdKey -Name '(default)' -Value $mv2Cmd
    }
  }
}

#region TASKBAR PIN

# https://github.com/Freenitial/Pin-Taskbar
$LnkPath = $desktopLnk

#region ENVIRONMENT
$RoamingAppDataPath = [Environment]::GetFolderPath('ApplicationData')
$TaskBarPinnedDirectory = [IO.Path]::Combine($RoamingAppDataPath, 'Microsoft\Internet Explorer\Quick Launch\User Pinned\TaskBar')
$TaskBandRegistrySubKey = 'Software\Microsoft\Windows\CurrentVersion\Explorer\Taskband'
$DoNotExpandRegistryOption = [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames
$BinaryRegistryValueKind = [Microsoft.Win32.RegistryValueKind]::Binary
$DwordRegistryValueKind = [Microsoft.Win32.RegistryValueKind]::DWord

& {
  if (-not [IO.Directory]::Exists($TaskBarPinnedDirectory)) { return }
  $RegistryProbeHandle = [Microsoft.Win32.Registry]::CurrentUser.OpenSubKey($TaskBandRegistrySubKey, $false)
  if (-not $RegistryProbeHandle) { return }
  $RegistryProbeHandle.Close()

  #region C# HELPER
  if (-not ('TaskbarPin' -as [Type])) {
    Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
using System.Threading;
public class TaskbarPin {
    [DllImport("shell32.dll", CharSet = CharSet.Unicode)]static extern int SHParseDisplayName(string pszName, IntPtr pbc, out IntPtr ppidl, uint sfgaoIn, out uint psfgaoOut);
    [DllImport("shell32.dll")]static extern void ILFree(IntPtr pidl);
    [DllImport("shell32.dll")]static extern IntPtr ILFindLastID(IntPtr pidl);
    [DllImport("shell32.dll")]static extern void SHChangeNotify(int wEventId, uint uFlags, IntPtr dwItem1, IntPtr dwItem2);
    [DllImport("ole32.dll")]static extern int CoCreateInstance(ref Guid rclsid, IntPtr pUnk, uint ctx, ref Guid riid, out IntPtr ppv);
    [DllImport("ole32.dll")]static extern int PropVariantClear(IntPtr pvar);
    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]static extern IntPtr CreateMutexExW(IntPtr lpMutexAttributes, string lpName, uint dwFlags, uint dwDesiredAccess);
    [DllImport("kernel32.dll", SetLastError = true)]static extern uint WaitForSingleObject(IntPtr hHandle, uint dwMilliseconds);
    [DllImport("kernel32.dll", SetLastError = true)]static extern bool ReleaseMutex(IntPtr hMutex);
    [DllImport("kernel32.dll", SetLastError = true)]static extern bool CloseHandle(IntPtr hObject);
    [UnmanagedFunctionPointer(CallingConvention.StdCall)] delegate uint FnRelease(IntPtr p);
    [UnmanagedFunctionPointer(CallingConvention.StdCall)] delegate int FnQueryInterface(IntPtr p, ref Guid riid, out IntPtr ppv);
    [UnmanagedFunctionPointer(CallingConvention.StdCall)] delegate int FnGetValue(IntPtr p, IntPtr key, IntPtr propvar);
    [UnmanagedFunctionPointer(CallingConvention.StdCall)] delegate int FnLoadFile(IntPtr p, IntPtr pszFileName, uint dwMode);
    static readonly Guid CLSID_ShellLink = new Guid("00021401-0000-0000-C000-000000000046");
    static readonly Guid IID_IShellLinkW = new Guid("000214F9-0000-0000-C000-000000000046");
    static readonly Guid IID_IPropertyStore = new Guid("886D8EEB-8CF2-4446-8D02-CDBA1DBDCF99");
    static readonly Guid IID_IPersistFile = new Guid("0000010B-0000-0000-C000-000000000046");
    static readonly Guid FMTID_AppUserModel = new Guid("9F4C2855-9F79-4B39-A8D0-E1D42DE1D5F3");
    delegate T StaFunc<T>(); static T RunOnSTA<T>(StaFunc<T> fn) { if (Thread.CurrentThread.GetApartmentState() == ApartmentState.STA) return fn(); T r = default(T); Thread t = new Thread(delegate() { r = fn(); }); t.SetApartmentState(ApartmentState.STA); t.Start(); t.Join(); return r; }
    static T Vtbl<T>(IntPtr vtbl, int slot) where T : class { return (T)(object)Marshal.GetDelegateForFunctionPointer(Marshal.ReadIntPtr(vtbl, slot * IntPtr.Size), typeof(T)); }
    static void Release(IntPtr ppv) { Vtbl<FnRelease>(Marshal.ReadIntPtr(ppv), 2)(ppv); }
    static void Release(IntPtr ppv, IntPtr vtbl) { Vtbl<FnRelease>(vtbl, 2)(ppv); }
    static IntPtr AllocPropertyKey() { byte[] pk = new byte[20]; Array.Copy(FMTID_AppUserModel.ToByteArray(), 0, pk, 0, 16); pk[16] = 5; IntPtr ptr = Marshal.AllocCoTaskMem(20); Marshal.Copy(pk, 0, ptr, 20); return ptr; }
    static byte[] InjectBeef001D(byte[] item, string displayName) {
        ushort cb = BitConverter.ToUInt16(item, 0); if (cb < 4) return null;
        byte[] nameBytes = System.Text.Encoding.Unicode.GetBytes(displayName + "\0");
        int blockCb = 2 + 2 + 4 + 2 + nameBytes.Length;
        byte[] block = new byte[blockCb];
        Array.Copy(BitConverter.GetBytes((ushort)blockCb), 0, block, 0, 2);
        block[2] = 0; block[3] = 0; block[4] = 0x1D; block[5] = 0x00; block[6] = 0xEF; block[7] = 0xBE; block[8] = 0x02; block[9] = 0x00;
        Array.Copy(nameBytes, 0, block, 10, nameBytes.Length);
        ushort extOffset = BitConverter.ToUInt16(item, cb - 2);
        int insertPos;
        if (extOffset > 4 && extOffset < cb - 4) {
            int epos = extOffset;
            while (epos + 8 <= cb) { ushort ecb = BitConverter.ToUInt16(item, epos); if (ecb < 8 || epos + ecb > cb) break; uint esig = BitConverter.ToUInt32(item, epos + 4); if ((esig & 0xFFFF0000) != 0xBEEF0000) break; epos += ecb; }
            insertPos = epos;
        } else { insertPos = cb - 2; extOffset = (ushort)insertPos; }
        int newCb = insertPos + blockCb + 2;
        byte[] result = new byte[newCb];
        Array.Copy(item, 0, result, 0, insertPos);
        Array.Copy(block, 0, result, insertPos, blockCb);
        Array.Copy(BitConverter.GetBytes(extOffset), 0, result, newCb - 2, 2);
        Array.Copy(BitConverter.GetBytes((ushort)newCb), 0, result, 0, 2);
        return result;
    }
    static byte[] BuildBlobEntry(IntPtr pidl, string beef001dContent) {
        IntPtr lastPtr = ILFindLastID(pidl);
        if (lastPtr == IntPtr.Zero) return null;
        int prefixLen = (int)((long)lastPtr - (long)pidl);
        ushort lastCb = (ushort)Marshal.ReadInt16(lastPtr);
        if (lastCb < 4) return null;
        byte[] lastItem = new byte[lastCb]; Marshal.Copy(lastPtr, lastItem, 0, lastCb);
        byte[] patched = InjectBeef001D(lastItem, beef001dContent);
        if (patched == null) return null;
        int newPidlLen = prefixLen + patched.Length + 2;
        byte[] result = new byte[1 + 4 + newPidlLen];
        result[0] = 0x00;
        Array.Copy(BitConverter.GetBytes((uint)newPidlLen), 0, result, 1, 4);
        Marshal.Copy(pidl, result, 5, prefixLen);
        Array.Copy(patched, 0, result, 5 + prefixLen, patched.Length);
        return result;
    }
    static byte[] GetBlobEntryInternal(string path, string beef001dContent) {
        IntPtr pidl; uint sfgao; if (SHParseDisplayName(path, IntPtr.Zero, out pidl, 0, out sfgao) != 0) pidl = IntPtr.Zero;
        if (pidl == IntPtr.Zero) return null;
        try { return BuildBlobEntry(pidl, beef001dContent); } finally { ILFree(pidl); }
    }
    public static byte[] GetBlobEntryEx(string lnkFullPath, string beef001dContent) { return RunOnSTA<byte[]>(delegate() { return GetBlobEntryInternal(lnkFullPath, beef001dContent); }); }
    public static string GetAumid(string lnkPath) {
        return RunOnSTA<string>(delegate() {
            Guid cls = CLSID_ShellLink; Guid iid = IID_IShellLinkW; IntPtr psl;
            if (CoCreateInstance(ref cls, IntPtr.Zero, 1, ref iid, out psl) != 0) return "";
            IntPtr vtLink = Marshal.ReadIntPtr(psl);
            try {
                FnQueryInterface qi = Vtbl<FnQueryInterface>(vtLink, 0);
                Guid iidFile = IID_IPersistFile; IntPtr ppf;
                if (qi(psl, ref iidFile, out ppf) != 0) return "";
                try { IntPtr p = Marshal.StringToCoTaskMemUni(lnkPath); try { if (Vtbl<FnLoadFile>(Marshal.ReadIntPtr(ppf), 5)(ppf, p, 0) != 0) return ""; } finally { Marshal.FreeCoTaskMem(p); } } finally { Release(ppf); }
                Guid iidStore = IID_IPropertyStore; IntPtr pps;
                if (qi(psl, ref iidStore, out pps) != 0) return "";
                try {
                    IntPtr pkPtr = AllocPropertyKey(); IntPtr pvPtr = Marshal.AllocCoTaskMem(24); for (int i = 0; i < 24; i++) Marshal.WriteByte(pvPtr, i, 0);
                    try { if (Vtbl<FnGetValue>(Marshal.ReadIntPtr(pps), 5)(pps, pkPtr, pvPtr) != 0) return ""; short vt = Marshal.ReadInt16(pvPtr); if (vt != 31) return ""; IntPtr sp = Marshal.ReadIntPtr(pvPtr, 8); if (sp == IntPtr.Zero) return ""; return Marshal.PtrToStringUni(sp) ?? ""; }
                    finally { PropVariantClear(pvPtr); Marshal.FreeCoTaskMem(pvPtr); Marshal.FreeCoTaskMem(pkPtr); }
                } finally { Release(pps); }
            } finally { Release(psl, vtLink); }
        });
    }
    public static void SendPinNotify() {
        byte[] payload = new byte[12]; payload[0] = 0x0A; payload[1] = 0x00; payload[2] = 0x0D; payload[3] = 0x00;
        IntPtr ptr = Marshal.AllocHGlobal(12);
        try { Marshal.Copy(payload, 0, ptr, 12); SHChangeNotify(0x04000000, 0x3000, ptr, IntPtr.Zero); } finally { Marshal.FreeHGlobal(ptr); }
    }
    static IntPtr _mutexHandle = IntPtr.Zero;
    public static bool AcquirePinMutex(int timeoutMs) {
        IntPtr h = CreateMutexExW(IntPtr.Zero, "TaskbarPinListMutex", 0, 0x001F0001); if (h == IntPtr.Zero) return false;
        uint r = WaitForSingleObject(h, (uint)timeoutMs);
        if (r == 0 || r == 0x80) { _mutexHandle = h; return true; } CloseHandle(h); return false;
    }
    public static void ReleasePinMutex() { if (_mutexHandle != IntPtr.Zero) { ReleaseMutex(_mutexHandle); CloseHandle(_mutexHandle); _mutexHandle = IntPtr.Zero; } }
    public static int FindBlobEntry(byte[] blob, string filename) {
        byte[] needle = System.Text.Encoding.Unicode.GetBytes(filename); int pos = 0; int idx = 0;
        while (pos < blob.Length && blob[pos] != 0xFF) {
            if (pos + 5 > blob.Length) break; uint pidlSize = BitConverter.ToUInt32(blob, pos + 1);
            int pidlStart = pos + 5; int pidlEnd = pidlStart + (int)pidlSize; if (pidlEnd > blob.Length) break;
            for (int b = pidlStart; b + needle.Length <= pidlEnd; b++) { bool match = true; for (int c = 0; c < needle.Length; c++) { if (blob[b + c] != needle[c]) { match = false; break; } } if (match) return idx; }
            pos = pidlEnd; idx++;
        } return -1;
    }
}
'@
  }

  #region TARGET SHORTCUT

  $WshShell = New-Object -ComObject WScript.Shell
  $ShortcutObject = $WshShell.CreateShortcut($LnkPath)
  $Beef001dContent = 'Chrome'
  [void][Runtime.InteropServices.Marshal]::ReleaseComObject($ShortcutObject)
  [void][Runtime.InteropServices.Marshal]::ReleaseComObject($WshShell)

  # Source .lnk is the pin target itself, always force-copy to TaskBar directory to ensure the pinned shortcut has the latest arguments and AUMID
  $ShortcutFileName = [IO.Path]::GetFileName($LnkPath)
  $DestinationLnkPath = [IO.Path]::Combine($TaskBarPinnedDirectory, $ShortcutFileName)
  try {
    [IO.File]::Copy($LnkPath, $DestinationLnkPath, $true)
  }
  catch {
    # If Explorer locks the existing pinned .lnk, try modifying it directly in-place
    Write-Log 'Taskbar shortcut locked by Explorer, updating in-place...' WARN
    try { [ShortcutEditor]::SetArgumentsAndAumid($DestinationLnkPath, $chromeFlags, 'Chrome') } catch {}
  }

  #region BLOB INJECTION

  $SerializedBlobEntry = $null
  if ($Beef001dContent) { $SerializedBlobEntry = [TaskbarPin]::GetBlobEntryEx($DestinationLnkPath, $Beef001dContent) }
  if (-not $SerializedBlobEntry) { return }

  $BlobEntry = New-Object PSObject -Property @{
    DestinationLnkPath  = $DestinationLnkPath
    SerializedBlobEntry = $SerializedBlobEntry
  }

  $MutexWasAcquired = [TaskbarPin]::AcquirePinMutex(5000)
  try {
    $TaskBandKey = [Microsoft.Win32.Registry]::CurrentUser.OpenSubKey($TaskBandRegistrySubKey, $true)
    try {
      $ExistingFavoritesBlob = $TaskBandKey.GetValue('Favorites', $null, $DoNotExpandRegistryOption)
      if (-not $ExistingFavoritesBlob -or $ExistingFavoritesBlob.Length -lt 2) { $ExistingFavoritesBlob = [byte[]]@(0xFF) }

      # Check if already pinned. if so, remove the stale entry and re-pin with fresh data
      $existingIdx = [TaskbarPin]::FindBlobEntry($ExistingFavoritesBlob, $ShortcutFileName)
      if ($existingIdx -ge 0) {
        # Walk the blob and strip the old entry
        $cleanStream = New-Object System.IO.MemoryStream
        $bpos = 0; $bidx = 0
        while ($bpos -lt $ExistingFavoritesBlob.Length -and $ExistingFavoritesBlob[$bpos] -ne 0xFF) {
          if ($bpos + 5 -gt $ExistingFavoritesBlob.Length) { break }
          $epSize = [BitConverter]::ToUInt32($ExistingFavoritesBlob, $bpos + 1)
          $entryLen = 1 + 4 + [int]$epSize
          if ($bidx -ne $existingIdx) { $cleanStream.Write($ExistingFavoritesBlob, $bpos, $entryLen) }
          $bpos += $entryLen; $bidx++
        }
        $cleanStream.WriteByte(0xFF)
        $ExistingFavoritesBlob = $cleanStream.ToArray(); $cleanStream.Dispose()
      }

      # Find insertion offset (end of existing entries, before 0xFF terminator)
      $BlobInsertionOffset = 0
      while ($BlobInsertionOffset -lt $ExistingFavoritesBlob.Length -and $ExistingFavoritesBlob[$BlobInsertionOffset] -ne 0xFF) {
        if ($BlobInsertionOffset + 5 -gt $ExistingFavoritesBlob.Length) { break }
        $CurrentEntryPidlSize = [BitConverter]::ToUInt32($ExistingFavoritesBlob, $BlobInsertionOffset + 1)
        $BlobInsertionOffset += 1 + 4 + $CurrentEntryPidlSize
      }

      # Build final blob
      $OutputBlobStream = New-Object System.IO.MemoryStream
      if ($BlobInsertionOffset -gt 0) { $OutputBlobStream.Write($ExistingFavoritesBlob, 0, $BlobInsertionOffset) }
      $OutputBlobStream.Write($BlobEntry.SerializedBlobEntry, 0, $BlobEntry.SerializedBlobEntry.Length)
      $OutputBlobStream.WriteByte(0xFF)
      $FinalBlobBytes = $OutputBlobStream.ToArray(); $OutputBlobStream.Dispose()

      # Write to registry
      $CurrentFavoritesChangesCounter = [int]$TaskBandKey.GetValue('FavoritesChanges', 0, $DoNotExpandRegistryOption)
      $TaskBandKey.SetValue('Favorites', $FinalBlobBytes, $BinaryRegistryValueKind)
      $TaskBandKey.SetValue('FavoritesVersion', 3, $DwordRegistryValueKind)
      $TaskBandKey.SetValue('FavoritesChanges', ($CurrentFavoritesChangesCounter + 1), $DwordRegistryValueKind)
    }
    finally { $TaskBandKey.Close() }
  }
  finally { if ($MutexWasAcquired) { [TaskbarPin]::ReleasePinMutex() } }

  [TaskbarPin]::SendPinNotify()
}

#region DEFAULT BROWSER

$defaultBrowser = (Get-ItemProperty -Path 'Registry::HKEY_CURRENT_USER\Software\Microsoft\Windows\Shell\Associations\UrlAssociations\http\UserChoice').ProgId
if ($defaultBrowser -ne 'ChromeHTML') {

  #region UCPD

  # Disable User Choice Protection Driver
  # ensures Windows won't snap the default browser back to Edge
  $ucpd = Get-Service 'UCPD' -EA 0
  if ($ucpd -and $ucpd.StartType -ne 'Disabled') { Set-Service -Name 'UCPD' -StartupType Disabled }
  $ucpdTask = Get-ScheduledTask -TaskPath '\Microsoft\Windows\AppxDeploymentClient\' -TaskName 'UCPD velocity' -EA 0
  if ($ucpdTask -and $ucpdTask.State -ne 'Disabled') { Disable-ScheduledTask -TaskPath '\Microsoft\Windows\AppxDeploymentClient\' -TaskName 'UCPD velocity' | Out-Null }

  #region WMIC

  $wmicInstalledByScript = $false
  if (!(Get-Command wmic -EA 0) -and -not (Test-Path "$env:SystemRoot\System32\wbem\wmic.exe")) {
    $wmicInstalledByScript = $true
    curl.exe -#fSLo $tmpDir\WMIC.zip 'https://github.com/powershello/WMIC/releases/download/wmic/WMIC.zip'
    Expand-Archive $tmpDir\WMIC.zip $tmpDir -force
    & $tmpDir\WMIC\WMIC.cmd -Silent
  }

  #region SETUSERFTA

  # https://kolbi.cz/blog/2024/04/03/userchoice-protection-driver-ucpd-sys/
  $suftaDir = Join-Path $tmpDir 'SUFTA'
  $suftaZIP = Join-Path $suftaDir 'SetUserFTA.zip'
  $suftaEXE = Join-Path $suftaDir 'SetUserFTA.exe'
  $suftaTXT = Join-Path $suftaDir 'suftaConfig.txt'
  New-Item -ItemType Directory $suftaDir -force | Out-Null
  Write-Log 'Downloading https://setuserfta.com/SetUserFTA_v1.8.3.zip...'
  curl.exe -#fSLo $suftaZIP 'https://setuserfta.com/SetUserFTA_v1.8.3.zip'
  if ($LASTEXITCODE -eq 0 -and (Test-Path $suftaZIP) -and (Get-Item $suftaZIP).Length -gt 0) {
    Expand-Archive $suftaZIP $suftaDir -force
    if (Test-Path $suftaEXE) {
      Write-Log "Successfully downloaded $suftaZIP" OK
      $suftaConfig = @'
http,ChromeHTML
https,ChromeHTML
.htm,ChromeHTML
.html,ChromeHTML
.xhtml,ChromeHTML
.mhtml,ChromeHTML
.shtml,ChromeHTML
.svg,ChromeHTML
.webp,ChromeHTML
.xht,ChromeHTML
.pdf,ChromePDF
'@

      Set-Content $suftaTXT -Value $suftaConfig
      $regPath = 'Registry::HKEY_CURRENT_USER\Software\Kolbicz IT\SetUserFTA'
      if (-not (Test-Path $regPath)) { New-Item $regPath -force | Out-Null }
      Set-ItemProperty $regPath 'RunCount' -Value 1 -Type DWord -force
      Write-Log 'Setting Google Chrome as default browser...'
      & $suftaEXE $suftaTXT
    }
    else {
      Write-Log 'SetUserFTA.exe extraction failed' FAIL
    }
  }
  else {
    Write-Log 'SetUserFTA download failed' FAIL
  }

  $newDefaultBrowser = (Get-ItemProperty 'Registry::HKEY_CURRENT_USER\Software\Microsoft\Windows\Shell\Associations\UrlAssociations\http\UserChoice' -EA 0).ProgId
  if ($newDefaultBrowser -eq 'ChromeHTML') { Write-Log "Successfully set default browser $newDefaultBrowser" OK }
  else { Write-Log 'Setting default browser failed' FAIL }

  if ($wmicInstalledByScript) {
    & $tmpDir\WMIC\WMIC.cmd -Silent -Uninstall
  }
}

#region SERVICES

$googleServices = @(Get-Service -Name *Google* -EA 0)
if ($googleServices) {
  Write-Log 'Stopping Google services...'
  foreach ($svc in $googleServices) {
    if ($svc.Status -eq 'Running') { $svc | Stop-Service -force }
    $svc | Set-Service -StartupType Manual
    Write-Log "Successfully stopped $($svc.Name)" OK
  }
}

#region TASKS

Remove-Tasks 'Google'


#region PREFERENCES

$prefs = "$env:LOCALAPPDATA\Google\Chrome\User Data\Default\Preferences"

#"countryid_at_install": 21843 - spoof Chrome into thinking the browser was first installed in the United States.
# https://source.chromium.org/chromium/chromium/src/+/main:components/country_codes/
$prefsJson = @'
{
  "countryid_at_install": 21843,
  "apps": {
    "shortcuts_arch": "",
    "shortcuts_version": 1
  },
  "omnibox": {
    "dismissed_history_scope_promo": true
  },
  "accessibility": {
    "captions": {
      "headless_caption_enabled": false,
      "live_caption_enabled": false,
      "live_translate_enabled": false
    }
  },
  "auto_pin_new_tab_groups": false,
  "autofill": {
    "profile_enabled": false,
    "credit_card_enabled": false,
    "payment_card_benefits": false,
    "payment_cvc_storage": false
  },
  "bookmark_bar": {
    "show_on_all_tabs": false,
    "show_tab_groups": false
  },
  "browser": {
    "custom_chrome_frame":  true,
    "enable_spellchecking": false,
    "split_view_drag_and_drop_enabled": false,
    "custom_chrome_frame": true,
    "has_seen_welcome_page": true,
    "clear_data": {
      "form_data": true,
      "hosted_apps_data": true,
      "site_settings": true,
      "time_period": 4
    },
    "__theme": {
      "color_variant2": 1,
      "follows_system_colors": false,
      "color_scheme2": 0,
      "user_color2": -674816
    }
  },
  "homepage_is_newtabpage": true,
  "credentials_enable_automatic_passkey_upgrades": false,  
  "credentials_enable_autosignin": false,
  "credentials_enable_service": false,
  "custom_links": {
    "initialized": true
  },
  "default_search_provider":  {
    "reset_occurred":  false
  },
  "default_search_provider_data": {
    "mirrored_template_url_data": {
      "is_active": 1,
      "keyword": "searx",
      "logo_url": "https://cdn.jsdelivr.net/gh/homarr-labs/dashboard-icons/svg/searxng.svg",
      "new_tab_url": "",
      "originating_url": "",
      "policy_origin":  1,
      "preconnect_to_search_url": false,
      "prefetch_likely_navigations": false,
      "safe_for_autoreplace": false,
      "search_url_post_params": "",
      "short_name": "SearXNG",
      "suggestions_url": "https://seek.fyi/autocompleter?q={searchTerms}",
      "suggestions_url_post_params": "",
      "url": "https://seek.fyi/search?q={searchTerms}"
    }
  },
  "download": {
    "prompt_for_download": false
  },
  "download_bubble": {
    "partial_view_enabled": false
  },
  "enable_do_not_track": true,
  "https_only_mode_enabled": true,
  "net": {
    "network_prediction_options": 2
  },
  "ntp": {
    "custom_background_inspiration": false,
    "num_personal_suggestions": 0,
    "shortcust_visible": false
  },
  "payments": {
    "can_make_payment_enabled": false
  },
  "plugins": {
    "always_open_pdf_externally": false
  },
  "privacy_guide": {
    "viewed": true
  },
  "privacy_sandbox": {
    "first_party_sets_data_access_allowed_initialized": false,
    "first_party_sets_enabled": false,
    "m1": {
      "ad_measurement_enabled": false,
      "fledge_enabled": false,
      "row_notice_acknowledged": true,
      "topics_enabled": false
    }
  },
  "profile": {
    "cookie_controls_mode": 1,
    "default_content_setting_values": {
      "geolocation": 2,
      "media_stream_camera": 3,
      "media_stream_mic": 3,
      "notifications": 2,
      "storage_access": 2
    },
    "exit_type": "Normal",
    "family_member_role": "not_in_family",
    "name": "Your Chrome",
    "password_manager_leak_detection": false
  },
  "safebrowsing": {
    "enabled": false,
    "enhanced": false,
    "scout_reporting_enabled_when_deprecated": false
  },
  "safety_hub": {
    "unused_site_permissions_revocation": {
      "enabled": false,
      "migration_completed": true
    }
  },
  "search": {
    "suggest_enabled": false
  },
  "settings": {
    "a11y": {
      "caretbrowsing": {
        "enabled": false
      },
      "focus_highlight": false
    },
    "force_google_safesearch": false
  },
  "side_panel": {
    "is_right_aligned": false
  },
  "signin": {
    "allowed": false,
    "allowed_on_next_startup": false
  },
  "spellcheck": {
    "use_spelling_service": false
  },
  "syncing_theme_prefs_migrated_to_non_syncing": true,
  "tab_search": {
    "pinned_to_tabstrip": false,
    "pinned_to_tabstrip_migration_complete_2": true
  },
  "toolbar": {
    "pinned_actions": ["kActionShowChromeLabs"],
    "pinned_cast_migration_complete": true,
    "pinned_chrome_labs_migration_complete": true,
    "tab_search_migration_complete": true
  },
  "extensions": {
    "pinned_extensions": ["cjpalhdlnbpafiamejdnhcphjbkeiagm"]
  },
  "translate": {
    "enabled": false
  }
}
'@

$profileDir = Split-Path $prefs
if (!(Test-Path $profileDir)) {
  Write-Log 'Creating Chrome Profile folder...'
  New-Item $profileDir -ItemType Dir -force | Out-Null
  Write-Log "Successfully created $profileDir" OK
}
else {
  Write-Log "Chrome Profile folder already exists at: $profileDir" WARN
}

$prefsObj = $prefsJson | ConvertFrom-Json
if (-not $SearXNG) {
  $prefsObj.PSObject.Properties.Remove('default_search_provider_data')
}

if (!(Test-Path $prefs)) {
  Write-Log 'Creating Chrome Preferences file...'
  [System.IO.File]::WriteAllText($prefs, ($prefsObj | ConvertTo-Json -Depth 20 -Compress))
  Write-Log "Successfully created $prefs" OK
}
else {
  $existingPrefs = try { Get-Content $prefs -Raw -EA 1 | ConvertFrom-Json } catch { $null }
  if ($existingPrefs) {
    Write-Log 'Merging existing Chrome Preferences file...'
    Merge-JsonObject $existingPrefs $prefsObj
    [System.IO.File]::WriteAllText($prefs, ($existingPrefs | ConvertTo-Json -Depth 20 -Compress))
    Write-Log "Successfully merged $prefs" OK
  }
  else {
    [System.IO.File]::WriteAllText($prefs, ($prefsObj | ConvertTo-Json -Depth 20 -Compress))
    Write-Log 'Existing profile was corrupt. Privacy preferences deployed fresh.' WARN
  }
}

$chromeAppDir = Split-Path $chrome
$initPref = Join-Path $chromeAppDir 'initial_preferences'
if (Test-Path $initPref) { 
  Write-Log 'Removing initial_preferences file...'
  Remove-Item $initPref -force | Out-Null
  Write-Log "Successfully removed $initPref" OK 
}

#region LOCAL STATE

$localState = "$env:LOCALAPPDATA\Google\Chrome\User Data\Local State"

$localStateJson = @'
{
  "background_mode": {
    "enabled": false
  },
  "breadcrumbs": {
    "enabled": false
  },
  "browser": {
    "hovercard": {
      "image_previews_enabled": false,
      "memory_usage_enabled": false
    },
    "enabled_labs_experiments": [
      "optimization-guide-on-device-model@4",
      "extensions-menu-access-control@1",
      "enable-tab-audio-muting@1",
      "enable-parallel-downloading@1",
      "smooth-scrolling@1",
      "disable-accelerated-2d-canvas",
      "disable-accelerated-video-decode",
      "disable-accelerated-video-encode",
      "ai-mode-omnibox-entry-point@5",
      "aim-entry-point-direct-navigation@2",
      "hide-aim-omnibox-entrypoint-on-user-input@2",
      "omnibox-allow-ai-mode-matches@2"
    ],
    "first_run_finished": true
  },
  "dns_over_https": {
    "mode": "off"
  },
  "feature_notifications_enabled": false,
  "hardware_acceleration_mode": {
    "enabled": false
  },
  "hardware_acceleration_mode_previous": false,
  "performance_tuning": {
    "discard_ring_treatment": {
      "enabled": false
    },
    "high_efficiency_mode": {
      "aggressiveness": 2,
      "state": 2
    },
    "intervention_notification": {
      "enabled": false
    }
  },
  "settings": {
    "a11y": {
      "overscroll_history_navigation": false
    },
    "toast": {
      "alert_level": 1
    }
  },
  "user_experience_metrics": {
    "reporting_enabled": false
  }
}
'@

$lsPatch = $localStateJson | ConvertFrom-Json

if (!(Test-Path $localState)) {
  Write-Log 'Creating Chrome Local State file...'
  New-Item -Path (Split-Path $localState) -ItemType Directory -Force | Out-Null
  [System.IO.File]::WriteAllText($localState, ($lsPatch | ConvertTo-Json -Depth 10 -Compress))
  Write-Log "Successfully created $localState" OK
}
else {
  $state = try { Get-Content $localState -Raw | ConvertFrom-Json } catch { $null }
  if ($state) {
    Write-Log 'Merging existing Chrome Local State file...'
    $targetExps = if ($null -ne $state.browser) { @($state.browser.enabled_labs_experiments) } else { @() }
    Merge-JsonObject $state $lsPatch
    if ($null -ne $state.browser) {
      $patchExps = @(
        'optimization-guide-on-device-model@4',
        'extensions-menu-access-control@1',
        'enable-tab-audio-muting@1',
        'enable-parallel-downloading@1',
        'smooth-scrolling@1',
        'disable-accelerated-2d-canvas',
        'disable-accelerated-video-decode',
        'disable-accelerated-video-encode',
        'ai-mode-omnibox-entry-point@5',
        'aim-entry-point-direct-navigation@2',
        'hide-aim-omnibox-entrypoint-on-user-input@2',
        'omnibox-allow-ai-mode-matches@2'
      )
      $patchNames = $patchExps | ForEach-Object { ($_ -split '@')[0] }
      $merged = @(@($targetExps | Where-Object {
            $name = ($_ -split '@')[0]
            $patchNames -notcontains $name
          }) + $patchExps) | Select-Object -Unique
      $state.browser.enabled_labs_experiments = $merged
    }
    [System.IO.File]::WriteAllText($localState, ($state | ConvertTo-Json -Depth 10 -Compress))
    Write-Log "Successfully merged $localState" OK
  }
  else {
    [System.IO.File]::WriteAllText($localState, ($lsPatch | ConvertTo-Json -Depth 10 -Compress))
    Write-Log 'Existing Local State was corrupt. Local State deployed fresh.' WARN
  }
}

# https://www.thatprivacyguy.com/blog/chrome-silent-nano-install/
$aiModelPath = "$env:LOCALAPPDATA\Google\Chrome\User Data\OptGuideOnDeviceModel"
if (Test-Path $aiModelPath) {
  $sizeBytes = (Get-ChildItem $aiModelPath -Recurse | Measure-Object -Property Length -Sum).Sum
  $sizeGB = if ($sizeBytes) { $sizeBytes / 1GB } else { 0 }
  Remove-Item $aiModelPath -r -force
  Write-Log "Successfully removed Gemini AI Nano model $aiModelPath ($([math]::Round($sizeGB,2)) GB)" OK
}

#region REGISTRY

$chromeReg = @'
Windows Registry Editor Version 5.00

; https://chromeenterprise.google/policies/

; https://www.chromium.org/administrators/policy-templates/

[-HKEY_CURRENT_USER\SOFTWARE\Policies\Google\Chrome]

[-HKEY_LOCAL_MACHINE\SOFTWARE\Policies\Google\Chrome]

[HKEY_LOCAL_MACHINE\SOFTWARE\Policies\Google\Chrome]
; --- AI ---
"GoogleSearchSidePanelEnabled"=dword:00000000
"BuiltInAIAPIsEnabled"=dword:00000000
"AIModeSettings"=dword:00000001
"GenAILocalFoundationalModelSettings"=dword:00000001
"SearchContentSharingSettings"=dword:00000001 ; Search by image
"GeminiSettings"=dword:00000001
"GeminiActOnWebSettings"=dword:00000001
"TabCompareSettings"=dword:00000002
"HistorySearchSettings"=dword:00000002
"CreateThemesSettings"=dword:00000002
"HelpMeWriteSettings"=dword:00000002
"DevToolsGenAiSettings"=dword:00000002
; --- TELEMETRY ---
"PrivacySandboxPromptEnabled"=dword:00000000
"WebRtcEventLogCollectionAllowed"=dword:00000000
"UserFeedbackAllowed"=dword:00000000
"FeedbackSurveysEnabled"=dword:00000000
"ChromeVariations"=dword:00000000
"ReportMachineIDData"=dword:00000000
"ReportUserIDData"=dword:00000000
"ReportVersionData"=dword:00000000
"ReportPolicyData"=dword:00000000
"ReportExtensionsAndPluginsData"=dword:00000000
; --- BLOAT & ANNOYANCES ---
; "DefaultBrowserSettingEnabled"=dword:00000000
"HideWebStoreIcon"=dword:00000001
"AllowDinosaurEasterEgg"=dword:00000000
"ComponentUpdatesEnabled"=dword:00000000
"SideSearchEnabled"=dword:00000000
"DesktopSharingHubEnabled"=dword:00000000
"EnableMediaRouter"=dword:00000000
"QRCodeGeneratorEnabled"=dword:00000000
"ShoppingListEnabled"=dword:00000000
; --- MISC ---
"WebRtcIPHandling"="disable_non_proxied_udp"
"PromotionsEnabled"=dword:00000000
"TranslatorAPIAllowed"=dword:00000000
"UrlKeyedMetricsAllowed"=dword:00000000
"RemoteAccessHostRequireCurtain"=dword:00000001
"RemoteAccessHostFirewallTraversal"=dword:00000000
"SafeBrowsingSurveysEnabled"=dword:00000000
"RemoteAccessHostAllowClientPairing"=dword:00000000
"DisableSafeBrowsingProceedAnyway"=dword:00000001
"AdvancedProtectionAllowed"=dword:00000000
"SavingBrowserHistoryDisabled"=dword:00000001
"SafeSitesFilterBehavior"=dword:00000000
"IntensiveWakeUpThrottlingEnabled"=dword:00000000
"NTPMiddleSlotAnnouncementVisible"=dword:00000000
"AutomatedPasswordChangeSettings"=dword:00000000
"BoundSessionCredentialsEnabled"=dword:00000000
"BasicAuthOverHttpEnabled"=dword:00000000
"BrowserNetworkTimeQueriesEnabled"=dword:00000000
"CACertificateManagementAllowed"=dword:00000000
"CAPlatformIntegrationEnabled"=dword:00000000
"RemoteDebuggingAllowed"=dword:00000000
"WebRtcTextLogCollectionAllowed"=dword:00000000
"RestrictCoreSharingOnRenderer"=dword:00000001
"DomainReliabilityAllowed"=dword:00000000
"ShowCastSessionsStartedByOtherDevices"=dword:00000000

[HKEY_LOCAL_MACHINE\SOFTWARE\Policies\Google\Chrome\Recommended]
"RestoreOnStartup"=dword:00000001

[HKEY_LOCAL_MACHINE\SOFTWARE\Policies\Google\Chrome\ClearBrowsingDataOnExitList]
"1"="browsing_history"
"2"="download_history"
"3"="cached_images_and_files"
"4"="password_signin"
"5"="autofill"
"6"="site_settings"
"7"="hosted_app_data"

[HKEY_LOCAL_MACHINE\SOFTWARE\Policies\Google\Chrome\GeminiActOnWebAllowedForURLs]

[HKEY_LOCAL_MACHINE\SOFTWARE\Policies\Google\Chrome\GeminiActOnWebBlockedForURLs]

; block google docs offline extension from installing
[HKEY_LOCAL_MACHINE\SOFTWARE\Policies\Google\Chrome\ExtensionInstallBlocklist]
"1"="ghbmnnjooekpmoecnnnilnnbdlolhkhi"

; disable chrome automatic updates
[HKEY_LOCAL_MACHINE\SOFTWARE\Policies\Google\Update]
"AutoUpdateCheckPeriodMinutes"=dword:00000000
"UpdateDefault"=dword:00000002
"Update{8A69D345-D564-463C-AFF1-A69D9E530F96}"=dword:00000002

; delete chrome per user logon
[-HKEY_LOCAL_MACHINE\SOFTWARE\Microsoft\Active Setup\Installed Components\{8A69D345-D564-463c-AFF1-A69D9E530F96}]

; fix blocked policies
; https://imgur.com/a/aMuinZw
; https://hitco.at/blog/apply-edge-policies-for-non-domain-joined-devices/

; # Fake MDM-Enrollment - Key 1 of 2 - let a Windows Machine "feel" MDM-Managed
[HKEY_LOCAL_MACHINE\SOFTWARE\Microsoft\Enrollments\FFFFFFFF-FFFF-FFFF-FFFF-FFFFFFFFFFFF] 
"EnrollmentState"=dword:00000001
"EnrollmentType"=dword:00000000
"IsFederated"=dword:00000000

; # Starting with Edge v147 in 04/2026 a UPN is needed, otherwise the MDM-Provider is not accepted
"UPN"="user@Fake-MDM-Provider.local"

; # Fake MDM-Enrollment - Key 2 of 2 - let a Windows Machine "feel" MDM-Managed
[HKEY_LOCAL_MACHINE\SOFTWARE\Microsoft\Provisioning\OMADM\Accounts\FFFFFFFF-FFFF-FFFF-FFFF-FFFFFFFFFFFF]
"Flags"=dword:00d6fb7f
"AcctUId"="0x000000000000000000000000000000000000000000000000000000000000000000000000"
"RoamingCount"=dword:00000000
"SslClientCertReference"="MY;User;0000000000000000000000000000000000000000"
"ProtoVer"="1.2"

; https://github.com/gorhill/ublock
[HKEY_LOCAL_MACHINE\SOFTWARE\WOW6432Node\Google\Chrome\Extensions\cjpalhdlnbpafiamejdnhcphjbkeiagm]
"update_url"="https://clients2.google.com/service/update2/crx"
'@

Write-Log 'Importing Chrome policy settings...'
Import-Reg $chromeReg

if ($SearXNG) {
  # https://searx.space/
  # https://odysee.com/@RobBraxmanTech:6?view=about
  $Path = 'Registry::HKEY_LOCAL_MACHINE\SOFTWARE\Policies\Google\Chrome\Recommended'
  Set-ItemProperty $Path 'DefaultSearchProviderEnabled' -Value 1 -Type DWord
  Set-ItemProperty $Path 'DefaultSearchProviderName' -Value 'SearXNG' -Type String
  Set-ItemProperty $Path 'DefaultSearchProviderKeyword' -Value 'seek.fyi' -Type String
  Set-ItemProperty $Path 'DefaultSearchProviderSearchURL' -Value 'https://seek.fyi/search?q={searchTerms}' -Type String
  Set-ItemProperty $Path 'DefaultSearchProviderSuggestURL' -Value 'https://seek.fyi/autocompleter?q={searchTerms}' -Type String
}

#region UBLOCK ORIGIN

$extId = 'cjpalhdlnbpafiamejdnhcphjbkeiagm'
$levelDbDir = "$env:LOCALAPPDATA\Google\Chrome\User Data\Default\Local Extension Settings\$extId"
if ($Force -or !(Test-Path $levelDbDir)) {
  if (Test-Path $levelDbDir) { Remove-Item $levelDbDir -Recurse -Force }
  New-Item $levelDbDir -ItemType Directory -Force | Out-Null


  $seedB64 = 'UEsDBBQAAAAAAIQQr1wAAAAAAAAAAAAAAAAKAAAAMDAwMDAyLmxvZ1BLAwQUAAAACACEEK9cvnLqkA8AAAAQAAAABwAAAENVUlJFTlTzdfTzdHMNDtE1AAFDLgBQSwMEFAAAAAAAhBCvXAAAAAAAAAAAAAAAAAQAAABMT0NLUEsDBBQAAAAIAIQQr1y4ytqxKwAAACkAAAAPAAAATUFOSUZFU1QtMDAwMDAxC1b7F63EwMgolZNalpqTkqTnVFmSWp5ZnOqcn1uQWJRYkl/ExMTMzMIAAFBLAQIUABQAAAAAAIQQr1wAAAAAAAAAAAAAAAAKAAAAAAAAAAAAAAAAAAAAAAAwMDAwMDIubG9nUEsBAhQAFAAAAAgAhBCvXL5y6pAPAAAAEAAAAAcAAAAAAAAAAAAAAAAAKAAAAENVUlJFTlRQSwECFAAUAAAAAACEEK9cAAAAAAAAAAAAAAAABAAAAAAAAAAAAAAAAABcAAAATE9DS1BLAQIUABQAAAAIAIQQr1y4ytqxKwAAACkAAAAPAAAAAAAAAAAAAAAAAH4AAABNQU5JRkVTVC0wMDAwMDFQSwUGAAAAAAQABADcAAAA1gAAAAAA'
  Add-Type -AssemblyName System.IO.Compression
  $zipBytes = [Convert]::FromBase64String($seedB64)
  $ms = New-Object System.IO.MemoryStream(, $zipBytes)
  $zip = New-Object System.IO.Compression.ZipArchive($ms, [System.IO.Compression.ZipArchiveMode]::Read)
  foreach ($entry in $zip.Entries) {
    $dest = Join-Path $levelDbDir $entry.Name
    $entryStream = $entry.Open()
    $fileStream = [System.IO.File]::Create($dest)
    $entryStream.CopyTo($fileStream)
    $fileStream.Close()
    $entryStream.Close()
  }
  $zip.Dispose()
  $ms.Dispose()

  $backupJson = @'
{
  "userSettings": {
    "externalLists": "https://raw.githubusercontent.com/DandelionSprout/adfilt/master/LegitimateURLShortener.txt",
    "importedLists": [
      "https://raw.githubusercontent.com/DandelionSprout/adfilt/master/LegitimateURLShortener.txt"
    ]
  },
  "selectedFilterLists": [
    "user-filters",
    "ublock-filters",
    "ublock-badware",
    "ublock-privacy",
    "ublock-quick-fixes",
    "ublock-unbreak",
    "easylist",
    "easyprivacy",
    "urlhaus-1",
    "plowe-0",
    "fanboy-cookiemonster",
    "ublock-cookies-easylist",
    "adguard-cookies",
    "ublock-cookies-adguard",
    "https://raw.githubusercontent.com/DandelionSprout/adfilt/master/LegitimateURLShortener.txt"
  ],
  "hiddenSettings": {},
  "whitelist": [
    "chrome-extension-scheme",
    "moz-extension-scheme"
  ],
  "dynamicFilteringString": "behind-the-scene * * noop\nbehind-the-scene * inline-script noop\nbehind-the-scene * 1p-script noop\nbehind-the-scene * 3p-script noop\nbehind-the-scene * 3p-frame noop\nbehind-the-scene * image noop\nbehind-the-scene * 3p noop",
  "urlFilteringString": "",
  "hostnameSwitchesString": "no-large-media: behind-the-scene false",
  "userFilters": "twitch.tv##+js(vaft-ublock-origin)\ntwitch.tv##+js(no-fetch-if, edge.ads.twitch.tv)"
}
'@

  Add-Type -TypeDefinition @'
using System;
using System.IO;
using System.Text;
using System.Collections.Generic;

public static class LevelDbWriter {
    private static readonly uint[] CrcTable;
    static LevelDbWriter() {
        CrcTable = new uint[256];
        for (uint i = 0; i < 256; i++) {
            uint c = i;
            for (int j = 0; j < 8; j++) c = (c & 1) != 0 ? (c >> 1) ^ 0x82F63B78u : c >> 1;
            CrcTable[i] = c;
        }
    }

    static uint Crc32C(byte[] data, int off, int len) {
        uint crc = 0xFFFFFFFF;
        for (int i = off; i < off + len; i++) crc = (crc >> 8) ^ CrcTable[(crc ^ data[i]) & 0xFF];
        return crc ^ 0xFFFFFFFF;
    }

    static uint MaskCrc(uint crc) { return unchecked(((crc >> 15) | (crc << 17)) + 0xa282ead8u); }

    static void PutVarint32(List<byte> buf, uint v) {
        while (v >= 0x80) { buf.Add((byte)(v | 0x80)); v >>= 7; }
        buf.Add((byte)v);
    }

    public static byte[] BuildBatch(long sequence, string[][] puts, string[] deletes) {
        var batch = new List<byte>();
        int count = puts.Length + deletes.Length;
        batch.AddRange(BitConverter.GetBytes(sequence));
        batch.AddRange(BitConverter.GetBytes(count));
        foreach (var kv in puts) {
            byte[] key = Encoding.UTF8.GetBytes(kv[0]);
            byte[] val = Encoding.UTF8.GetBytes(kv[1]);
            batch.Add(0x01);
            PutVarint32(batch, (uint)key.Length);
            batch.AddRange(key);
            PutVarint32(batch, (uint)val.Length);
            batch.AddRange(val);
        }
        foreach (var k in deletes) {
            byte[] key = Encoding.UTF8.GetBytes(k);
            batch.Add(0x00);
            PutVarint32(batch, (uint)key.Length);
            batch.AddRange(key);
        }
        return batch.ToArray();
    }

    public static byte[] WrapAsLogRecords(byte[] payload, long existingFileSize) {
        const int kBlockSize = 32768;
        const int kHeaderSize = 7;
        var result = new List<byte>();
        int offset = 0;
        bool begun = false;

        while (offset < payload.Length) {
            long filePos = existingFileSize + result.Count;
            int blockRemain = kBlockSize - (int)(filePos % kBlockSize);
            if (blockRemain < kHeaderSize) {
                for (int i = 0; i < blockRemain; i++) result.Add(0);
                blockRemain = kBlockSize;
            }

            int avail = blockRemain - kHeaderSize;
            int fragLen = Math.Min(avail, payload.Length - offset);
            bool isEnd = (offset + fragLen) == payload.Length;

            byte type;
            if (!begun && isEnd) type = 1;
            else if (!begun)     type = 2;
            else if (isEnd)      type = 4;
            else                 type = 3;

            byte[] crcBuf = new byte[1 + fragLen];
            crcBuf[0] = type;
            Array.Copy(payload, offset, crcBuf, 1, fragLen);
            uint crc = MaskCrc(Crc32C(crcBuf, 0, crcBuf.Length));

            result.AddRange(BitConverter.GetBytes(crc));
            result.AddRange(BitConverter.GetBytes((ushort)fragLen));
            result.Add(type);
            for (int i = 0; i < fragLen; i++) result.Add(payload[offset + i]);

            offset += fragLen;
            begun = true;
        }

        return result.ToArray();
    }
    
    public static long GetMaxSequenceFromLog(byte[] log) {
        const int kBlockSize = 32768;
        const int kHeaderSize = 7;
        long maxSeq = -1;
        int pos = 0;
        while (pos + kHeaderSize <= log.Length) {
            int blockRemain = kBlockSize - (pos % kBlockSize);
            if (blockRemain < kHeaderSize) { pos += blockRemain; continue; }
            ushort len = BitConverter.ToUInt16(log, pos + 4);
            byte type = log[pos + 6];
            if (len == 0 && type == 0) { pos += blockRemain; continue; }
            if (pos + kHeaderSize + len > log.Length) break;
            if (type == 1 || type == 2) {
                if (len >= 12) {
                    long seq = BitConverter.ToInt64(log, pos + kHeaderSize);
                    int cnt = BitConverter.ToInt32(log, pos + kHeaderSize + 8);
                    long endSeq = seq + (cnt > 0 ? cnt - 1 : 0);
                    if (endSeq > maxSeq) maxSeq = endSeq;
                }
            }
            pos += kHeaderSize + len;
        }
        return maxSeq;
    }

    public static long GetLastSequenceFromManifest(byte[] manifest) {
        long maxSeq = -1;
        int pos = 0;
        while (pos + 7 <= manifest.Length) {
            ushort len = BitConverter.ToUInt16(manifest, pos + 4);
            byte rtype = manifest[pos + 6];
            if (len == 0 && rtype == 0) break;
            if (pos + 7 + len > manifest.Length) break;
            int dStart = pos + 7;
            int dEnd = dStart + len;
            int d = dStart;
            while (d < dEnd) {
                int tag = manifest[d]; d++;
                if (tag == 1) {
                    if (d >= dEnd) break;
                    int slen = manifest[d]; d++;
                    d += slen;
                } else if (tag == 2 || tag == 3 || tag == 4 || tag == 9) {
                    long val = 0; int shift = 0;
                    while (d < dEnd) {
                        byte b = manifest[d]; d++;
                        val |= ((long)(b & 0x7F)) << shift; shift += 7;
                        if ((b & 0x80) == 0) break;
                    }
                    if (tag == 4 && val > maxSeq) maxSeq = val;
                } else if (tag == 5 || tag == 6 || tag == 7) {
                    break;
                } else { break; }
            }
            pos += 7 + len;
        }
        return maxSeq;
    }
}
'@

  $backup = $backupJson | ConvertFrom-Json -EA 1
  $logFile = Get-ChildItem $levelDbDir -Filter '*.log' -File | Sort-Object Name | Select-Object -Last 1
  if (!$logFile) {
    Write-Log 'uBlock injection failed: No LevelDB log file found in seed' FAIL
    return
  }

  try {
    $fs = [System.IO.FileStream]::new($logFile.FullName, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::ReadWrite)
    $logBytes = New-Object byte[] $fs.Length
    [void]$fs.Read($logBytes, 0, $logBytes.Length)
    $fs.Dispose()
  }
  catch {
    Write-Log "Failed to read LevelDB log with error: $($_.Exception.Message)" FAIL
    return
  }
  $logSeq = [LevelDbWriter]::GetMaxSequenceFromLog($logBytes)

  $manifestFile = Get-ChildItem $levelDbDir -Filter 'MANIFEST-*' -File | Sort-Object Name | Select-Object -Last 1
  $manifestSeq = -1
  if ($manifestFile) {
    try {
      $mfs = [System.IO.FileStream]::new($manifestFile.FullName, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::ReadWrite)
      $manifestBytes = New-Object byte[] $mfs.Length
      [void]$mfs.Read($manifestBytes, 0, $manifestBytes.Length)
      $mfs.Dispose()
      $manifestSeq = [LevelDbWriter]::GetLastSequenceFromManifest($manifestBytes)
    }
    catch { Write-Log "Manifest parse skipped, using log sequence: $($_.Exception.Message)" WARN }
  }

  $maxSeq = [Math]::Max($logSeq, $manifestSeq)
  if ($maxSeq -lt 0) { $maxSeq = 0 }
  $nextSeq = $maxSeq + 1

  function ConvertTo-JsonArray($arr) {
    $wrapper = [PSCustomObject]@{ v = @($arr) }
    $json = $wrapper | ConvertTo-Json -Depth 5 -Compress
    $json.Substring(5, $json.Length - 6)
  }

  $puts = @(
    @('selectedFilterLists', (ConvertTo-JsonArray $backup.selectedFilterLists)),
    @('netWhitelist', (ConvertTo-JsonArray $backup.whitelist)),
    @('dynamicFilteringString', ($backup.dynamicFilteringString | ConvertTo-Json -Compress)),
    @('urlFilteringString', ($backup.urlFilteringString | ConvertTo-Json -Compress)),
    @('hostnameSwitchesString', ($backup.hostnameSwitchesString | ConvertTo-Json -Compress)),
    @('user-filters', ($backup.userFilters | ConvertTo-Json -Compress))
  )

  if ($backup.userSettings) {
    foreach ($prop in $backup.userSettings.PSObject.Properties) {
      if ($prop.Value -is [System.Array]) { $jsonVal = ConvertTo-JsonArray $prop.Value }
      else { $jsonVal = $prop.Value | ConvertTo-Json -Depth 5 -Compress }
      $puts += , @($prop.Name, $jsonVal)
    }
  }

  if ($backup.hiddenSettings) {
    $puts += , @('hiddenSettings', ($backup.hiddenSettings | ConvertTo-Json -Depth 5 -Compress))
  }

  $nowMs = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
  $puts += , @('lastRestoreTime', $nowMs.ToString())
  $puts += , @('lastRestoreFile', '""')
  $puts += , @('lastBackupFile', '""')
  $puts += , @('lastBackupTime', '0')

  $deletes = @(
    'cache/selfie/staticMain',
    'cache/selfie/staticExtFilteringEngine',
    'cache/selfie/staticNetFilteringEngine',
    'cache/compiled/user-filters'
  )

  [string[][]]$putArray = @()
  foreach ($kv in $puts) { $putArray += , @($kv[0], $kv[1]) }
  [string[]]$deleteArray = $deletes

  $batchPayload = [LevelDbWriter]::BuildBatch($nextSeq, $putArray, $deleteArray)
  $logRecords = [LevelDbWriter]::WrapAsLogRecords($batchPayload, $logBytes.Length)

  $fs = $null
  try {
    $fs = [System.IO.FileStream]::new($logFile.FullName, [System.IO.FileMode]::Append, [System.IO.FileAccess]::Write, [System.IO.FileShare]::None)
    $fs.Write($logRecords, 0, $logRecords.Length)
    $fs.Flush()
  }
  catch {
    Write-Log "Failed to write uBlock LevelDB data with error: $($_.Exception.Message)" FAIL
  }
  finally {
    if ($fs) { $fs.Dispose() }
  }
}
<#
#region WEB DATA
# explorer /select,"$env:LOCALAPPDATA\Google\Chrome\User Data\Default\Web Data"

$webDataGzB64 = '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'
$webDataPath = "$env:LOCALAPPDATA\Google\Chrome\User Data\Default\Web Data"
$gzBytes = [Convert]::FromBase64String($webDataGzB64)
$ms = New-Object System.IO.MemoryStream(, $gzBytes)
$gs = New-Object System.IO.Compression.GZipStream($ms, [System.IO.Compression.CompressionMode]::Decompress)
$out = New-Object System.IO.MemoryStream
$gs.CopyTo($out); $gs.Dispose(); $ms.Dispose()
[System.IO.File]::WriteAllBytes($webDataPath, $out.ToArray())
$sizeKB = [math]::Round($out.Length / 1KB, 1); $out.Dispose()
Write-Log "Web Data deployed ($sizeKB KB SQLite)." OK
#>
#region END

Remove-Item $tmpDir -r -force
if ($Silent) { exit }
if ($SearXNG) {
  Start-Process $chrome -args "$chromeFlags", 'https://seek.fyi'
}
else {
  Start-Process $chrome -args "$chromeFlags"
}
Write-Host 'Press any key to continue . . . ' -NoNewline
$null = [Console]::ReadKey($true)
exit
# SIG # Begin signature block
# MIIFhgYJKoZIhvcNAQcCoIIFdzCCBXMCAQExDzANBglghkgBZQMEAgEFADB5Bgor
# BgEEAYI3AgEEoGswaTA0BgorBgEEAYI3AgEeMCYCAwEAAAQQH8w7YFlLCE63JNLG
# KX7zUQIBAAIBAAIBAAIBAAIBADAxMA0GCWCGSAFlAwQCAQUABCAp+KQmrLg8vHQm
# l0G8o/9MTUm2bhYTiotiW+Sxw1y8EqCCAwAwggL8MIIB5KADAgECAhA4javxMBrB
# gUIz2JIluuyNMA0GCSqGSIb3DQEBCwUAMBYxFDASBgNVBAMMC1Bvd2Vyc2hlbGxv
# MB4XDTI2MDUwNjEzNDQxOVoXDTI3MDUwNjE0MDQxOVowFjEUMBIGA1UEAwwLUG93
# ZXJzaGVsbG8wggEiMA0GCSqGSIb3DQEBAQUAA4IBDwAwggEKAoIBAQCjPdqC0lkV
# oH9HnxgI3MOh5uewEnWyU3umpEfhdv3u9Eo/7rhk3XlmGbQy9zh3vKzh/FL5P+8a
# OVC9Hz3PukiyEuVGiOXkfeLIUPEQUttISylYTsZvpbgLRYoq9QHbxe2/L5EDaqTL
# izibxjRU2+JFRKGCHvXxwF45JQCjn+mwpIX3l0gtenEklOMQgMlyyL9EF3K69KCE
# 55f2xrBPWZOE94rHMr655geKvxCYRv19gUssk17mHkWYVWNkr7wLbjmjZgC88XX7
# ftEqWquYKJ3DxLTItdrg2ePzzTrnOUeswKgplUBSnD+hNT9jSA+6jxmLIra2s/gH
# OA8YBaY9SzvVAgMBAAGjRjBEMA4GA1UdDwEB/wQEAwIHgDATBgNVHSUEDDAKBggr
# BgEFBQcDAzAdBgNVHQ4EFgQUIUguv0bb4pmgM8OcB9QLrAl1jQcwDQYJKoZIhvcN
# AQELBQADggEBAFKrSLyqnAfOfzkijUsUg06om4YWLg3kVL+VJc0txcKocPvz6oQb
# pGqUc1xuyAQCWDbo1Ufj9F+ubYsRakDu+NdaZI008ArGGbI4VFhpfwu9r5pUaiLj
# SU4l5f1IIhKjPVMS6i83oGGexlCh6mbVYMd4Saxxy2rpzRbfxCC6mSpf7ngPIJME
# 2ToR+C8MD4XYe8M4H0rKdM2lSqH48lsWQFFi3pP7H1vayopTEt9t6eNa8/k9b2Kl
# rFaYlgfiXM0aQi9eBDgrWpmmJmaQzjrxyEq7GWxmjgY6Z4VQsPmAMTFw3I98pCOe
# V8WAzgUIiBGkqq4LcxeADC7K0z7FxofWfMExggHcMIIB2AIBATAqMBYxFDASBgNV
# BAMMC1Bvd2Vyc2hlbGxvAhA4javxMBrBgUIz2JIluuyNMA0GCWCGSAFlAwQCAQUA
# oIGEMBgGCisGAQQBgjcCAQwxCjAIoAKAAKECgAAwGQYJKoZIhvcNAQkDMQwGCisG
# AQQBgjcCAQQwHAYKKwYBBAGCNwIBCzEOMAwGCisGAQQBgjcCARUwLwYJKoZIhvcN
# AQkEMSIEIIAjJVcQq55auyDwBZxHtK5diQbv5k+NsXl4JzAsbWbcMA0GCSqGSIb3
# DQEBAQUABIIBAGT2t2rDu5SQzJ8oY+BKscrhLvYQN7xHnLOY+TZRM/XMmuOYK3Ih
# GJTgthViVpgNeZ0tyud++Yib20KnlB+TjIMZ3v1+Lypd4VhjAoOTGgc8AsQTXEuB
# ML8/GYUbk3FYxDbGY6Aiw2LLGW6wxXN1xwE2QlghXFaGS/pB579t2nZju0phG2sC
# Ez+lM18u0P+FEFmeKfDHenNMxNTg+RCD7lcGa2a9eOv/0p24SLulIJvpQcTjkQK0
# +zvhWxR2m+NzmDgpWVUMQJFZGxOGFtyHFdamnI3ZMLL8i0GBRN/SCTo2Ak8kNA27
# GqH9RF2WhcdOpO4MnnQjBaQfI+wIDVSrrWE=
# SIG # End signature block
