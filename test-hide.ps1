param([string]$OutPath = "$env:TEMP\dsh-hide-verify.png")

# 验证「隐藏 / 还原」逻辑：
# 开一个标题里带 “DeepSeek Harness” 的替身窗口（进程名是 powershell，不是 DSH），
# 助手应当靠“标题”这条线索认出它并隐藏，截完再还原。
# 只用于本地排查（会闪一下全屏冻结窗口；真实 DSH 窗口也会被一并隐藏/还原）。
$ErrorActionPreference = 'Stop'

Add-Type -TypeDefinition @"
using System;
using System.Text;
using System.Collections.Generic;
using System.Runtime.InteropServices;
public static class HideProbe4 {
  public delegate bool EnumProc(IntPtr hWnd, IntPtr lParam);
  [DllImport("user32.dll")] public static extern bool EnumWindows(EnumProc cb, IntPtr lParam);
  [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr hWnd, out uint pid);
  [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr hWnd);
  [DllImport("user32.dll")] public static extern bool PostMessage(IntPtr hWnd, uint msg, IntPtr wParam, IntPtr lParam);
  [DllImport("user32.dll", CharSet=CharSet.Unicode)] public static extern int GetClassName(IntPtr h, StringBuilder sb, int max);
  [DllImport("user32.dll", CharSet=CharSet.Unicode)] public static extern int GetWindowText(IntPtr h, StringBuilder sb, int max);
  public static List<IntPtr> VisibleOf(uint target) {
    var list = new List<IntPtr>();
    EnumWindows((h, l) => {
      uint pid; GetWindowThreadProcessId(h, out pid);
      if (pid == target && IsWindowVisible(h)) list.Add(h);
      return true;
    }, IntPtr.Zero);
    return list;
  }
  public static IntPtr FormOf(uint target) {
    IntPtr found = IntPtr.Zero;
    EnumWindows((h, l) => {
      uint pid; GetWindowThreadProcessId(h, out pid);
      if (pid != target || !IsWindowVisible(h)) return true;
      var c = new StringBuilder(256); GetClassName(h, c, 256);
      if (c.ToString().StartsWith("WindowsForms10")) { found = h; return false; }
      return true;
    }, IntPtr.Zero);
    return found;
  }
  public static string TitleOf(IntPtr h) {
    var t = new StringBuilder(512); GetWindowText(h, t, 512); return t.ToString();
  }
  public static IntPtr Point(int x, int y) { return (IntPtr)((y << 16) | (x & 0xFFFF)); }
}
"@

$fakeScript = @'
Add-Type -TypeDefinition 'using System; using System.Runtime.InteropServices; public static class W { [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr h, int n); }'
Add-Type -AssemblyName System.Windows.Forms
$form = New-Object System.Windows.Forms.Form
$form.Text = 'Fake - DeepSeek Harness'
$form.Width = 420
$form.Height = 320
$form.Show()
[W]::ShowWindow($form.Handle, 5) | Out-Null
[System.Windows.Forms.Application]::Run($form)
'@
$encoded = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($fakeScript))
$fake = Start-Process powershell.exe -ArgumentList @('-NoProfile', '-EncodedCommand', $encoded) -PassThru -WindowStyle Hidden

$targets = @()
$swWait = [Diagnostics.Stopwatch]::StartNew()
while ($swWait.ElapsedMilliseconds -lt 8000) {
  $targets = @([HideProbe4]::VisibleOf([uint32]$fake.Id))
  if ($targets.Count -gt 0) { break }
  Start-Sleep -Milliseconds 100
}
"stand-in pid=$($fake.Id) visible windows=$($targets.Count) title='$([HideProbe4]::TitleOf($targets[0]))'"
if ($targets.Count -eq 0) { if (-not $fake.HasExited) { $fake.Kill() }; throw "替身窗口没找到" }

$dir = Split-Path -Parent $MyInvocation.MyCommand.Path
$psi = New-Object System.Diagnostics.ProcessStartInfo
$psi.FileName = 'powershell.exe'
$psi.Arguments = "-NoProfile -NonInteractive -ExecutionPolicy Bypass -File `"$dir\helper.ps1`""
$psi.UseShellExecute = $false
$psi.RedirectStandardInput = $true
$psi.RedirectStandardOutput = $true
$psi.CreateNoWindow = $true
$helper = [System.Diagnostics.Process]::Start($psi)
$null = $helper.StandardOutput.ReadLine()   # ready

$b64Out = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($OutPath))
$helper.StandardInput.WriteLine("1|1|0|$b64Out")
$helper.StandardInput.Flush()

$form = [IntPtr]::Zero
$sw = [Diagnostics.Stopwatch]::StartNew()
while ($sw.ElapsedMilliseconds -lt 8000) {
  $form = [HideProbe4]::FormOf([uint32]$helper.Id)
  if ($form -ne [IntPtr]::Zero) { break }
  Start-Sleep -Milliseconds 25
}
$visibleDuring = @([HideProbe4]::VisibleOf([uint32]$fake.Id)).Count
"overlay after $($sw.ElapsedMilliseconds)ms; stand-in visible during overlay: $visibleDuring"
if ($visibleDuring -ne 0) { "隐藏失败" } else { "隐藏成功" }

if ($form -ne [IntPtr]::Zero) {
  [HideProbe4]::PostMessage($form, 0x0201, [IntPtr]::Zero, [HideProbe4]::Point(10, 10)) | Out-Null
  Start-Sleep -Milliseconds 60
  [HideProbe4]::PostMessage($form, 0x0200, [IntPtr]::Zero, [HideProbe4]::Point(110, 80)) | Out-Null
  Start-Sleep -Milliseconds 60
  [HideProbe4]::PostMessage($form, 0x0202, [IntPtr]::Zero, [HideProbe4]::Point(110, 80)) | Out-Null
}
$response = $helper.StandardOutput.ReadLine()
"helper response: $response"

Start-Sleep -Milliseconds 1200
$restored = @([HideProbe4]::VisibleOf([uint32]$fake.Id)).Count
"stand-in visible after restore: $restored"
if ($restored -gt 0) { "还原成功" } else { "还原失败" }

$helper.StandardInput.WriteLine('exit')
$helper.StandardInput.Flush()
if (-not $helper.WaitForExit(3000)) { $helper.Kill() }
if (-not $fake.HasExited) { $fake.Kill() }
