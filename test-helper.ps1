param(
  [string]$OutPath = "$env:TEMP\dsh-print-screen-helper-test.png"
)

# 常驻助手的手动自测：
#   1. 起 helper.ps1，量「ready」耗时
#   2. 发一次截图请求，量「冻结窗口出现」耗时，模拟拖框，等 ok
#   3. 再发一次（热态），量耗时；用 WM_CLOSE 取消
# 只用于本地排查，不参与插件运行。
$ErrorActionPreference = 'Stop'

Add-Type -TypeDefinition @"
using System;
using System.Text;
using System.Runtime.InteropServices;
public static class Probe {
  public delegate bool EnumProc(IntPtr hWnd, IntPtr lParam);
  [DllImport("user32.dll")] public static extern bool EnumWindows(EnumProc cb, IntPtr lParam);
  [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr hWnd, out uint pid);
  [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr hWnd);
  [DllImport("user32.dll", CharSet=CharSet.Unicode)] public static extern int GetClassName(IntPtr hWnd, StringBuilder sb, int max);
  [DllImport("user32.dll")] public static extern bool PostMessage(IntPtr hWnd, uint msg, IntPtr wParam, IntPtr lParam);
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
  public static IntPtr Point(int x, int y) { return (IntPtr)((y << 16) | (x & 0xFFFF)); }
}
"@

$dir = Split-Path -Parent $MyInvocation.MyCommand.Path
$psi = New-Object System.Diagnostics.ProcessStartInfo
$psi.FileName = 'powershell.exe'
$psi.Arguments = "-NoProfile -NonInteractive -ExecutionPolicy Bypass -File `"$dir\helper.ps1`""
$psi.UseShellExecute = $false
$psi.RedirectStandardInput = $true
$psi.RedirectStandardOutput = $true
$psi.CreateNoWindow = $true

$total = [Diagnostics.Stopwatch]::StartNew()
$p = [System.Diagnostics.Process]::Start($psi)
$ready = $p.StandardOutput.ReadLine()
"ready='$ready' 启动耗时: $($total.ElapsedMilliseconds)ms"

if (Test-Path $OutPath) { Remove-Item $OutPath -Force }
$b64 = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($OutPath))
$first = [Diagnostics.Stopwatch]::StartNew()
$p.StandardInput.WriteLine("1|0|60|$b64")
$p.StandardInput.Flush()
$hwnd = [IntPtr]::Zero
while ($first.ElapsedMilliseconds -lt 8000) {
  $hwnd = [Probe]::FormOf([uint32]$p.Id)
  if ($hwnd -ne [IntPtr]::Zero) { break }
  Start-Sleep -Milliseconds 15
}
"冻结窗口出现: $($first.ElapsedMilliseconds)ms"
if ($hwnd -ne [IntPtr]::Zero) {
  [Probe]::PostMessage($hwnd, 0x0201, [IntPtr]::Zero, [Probe]::Point(10, 10)) | Out-Null
  Start-Sleep -Milliseconds 80
  [Probe]::PostMessage($hwnd, 0x0200, [IntPtr]::Zero, [Probe]::Point(60, 40)) | Out-Null
  Start-Sleep -Milliseconds 80
  [Probe]::PostMessage($hwnd, 0x0200, [IntPtr]::Zero, [Probe]::Point(110, 80)) | Out-Null
  Start-Sleep -Milliseconds 80
  [Probe]::PostMessage($hwnd, 0x0202, [IntPtr]::Zero, [Probe]::Point(110, 80)) | Out-Null
}
$response = $p.StandardOutput.ReadLine()
"第一次结果: $response  总耗时: $($first.ElapsedMilliseconds)ms"

$secondPath = [IO.Path]::ChangeExtension($OutPath, ".2.png")
$b64b = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($secondPath))
$second = [Diagnostics.Stopwatch]::StartNew()
$p.StandardInput.WriteLine("2|0|60|$b64b")
$p.StandardInput.Flush()
$hwnd2 = [IntPtr]::Zero
while ($second.ElapsedMilliseconds -lt 8000) {
  $hwnd2 = [Probe]::FormOf([uint32]$p.Id)
  if ($hwnd2 -ne [IntPtr]::Zero) { break }
  Start-Sleep -Milliseconds 15
}
"第二次冻结窗口出现: $($second.ElapsedMilliseconds)ms"
if ($hwnd2 -ne [IntPtr]::Zero) {
  # 第二次也真的拖一次，验证复用了 DIB 的位图没有被上一次的窗体释放掉
  [Probe]::PostMessage($hwnd2, 0x0201, [IntPtr]::Zero, [Probe]::Point(20, 20)) | Out-Null
  Start-Sleep -Milliseconds 60
  [Probe]::PostMessage($hwnd2, 0x0200, [IntPtr]::Zero, [Probe]::Point(80, 60)) | Out-Null
  Start-Sleep -Milliseconds 60
  [Probe]::PostMessage($hwnd2, 0x0202, [IntPtr]::Zero, [Probe]::Point(120, 90)) | Out-Null
}
$response2 = $p.StandardOutput.ReadLine()
"第二次结果: $response2  总耗时: $($second.ElapsedMilliseconds)ms"

Add-Type -AssemblyName System.Drawing
foreach ($file in @($OutPath, $secondPath)) {
  if (Test-Path $file) {
    $img = [System.Drawing.Image]::FromFile($file)
    "$file : $($img.Width)x$($img.Height)"
    $img.Dispose()
  } else {
    "$file : 不存在（取消或未保存）"
  }
}

$p.StandardInput.WriteLine("exit")
$p.StandardInput.Flush()
$p.WaitForExit(4000) | Out-Null
if (-not $p.HasExited) { $p.Kill() }
"助手已退出: $($p.HasExited)"
