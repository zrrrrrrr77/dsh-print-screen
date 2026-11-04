param([int]$ParentPid = 0)

# 在集成测试里模拟“用户在冻结画面上拖框”：
# 找屏幕上面积最大的那个 WinForms 无边框窗口（就是截图助手的冻结窗口），
# PostMessage 一次从 (10,10) 到 (110,80) 的拖拽。
$ErrorActionPreference = 'Stop'

Add-Type -TypeDefinition @"
using System;
using System.Text;
using System.Runtime.InteropServices;
public static class SnapProbe {
  public delegate bool EnumProc(IntPtr hWnd, IntPtr lParam);
  [DllImport("user32.dll")] public static extern bool EnumWindows(EnumProc cb, IntPtr lParam);
  [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr hWnd, out uint pid);
  [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr hWnd);
  [DllImport("user32.dll", CharSet=CharSet.Unicode)] public static extern int GetClassName(IntPtr hWnd, StringBuilder sb, int max);
  [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr hWnd, out RECT rect);
  [DllImport("user32.dll")] public static extern bool PostMessage(IntPtr hWnd, uint msg, IntPtr wParam, IntPtr lParam);
  public struct RECT { public int Left, Top, Right, Bottom; }
  public static IntPtr LargestForm() {
    IntPtr best = IntPtr.Zero;
    long bestArea = 0;
    EnumWindows((h, l) => {
      if (!IsWindowVisible(h)) return true;
      var c = new StringBuilder(256); GetClassName(h, c, 256);
      if (!c.ToString().StartsWith("WindowsForms10")) return true;
      RECT r; GetWindowRect(h, out r);
      long area = (long)(r.Right - r.Left) * (r.Bottom - r.Top);
      if (area > bestArea) { bestArea = area; best = h; }
      return true;
    }, IntPtr.Zero);
    return best;
  }
  public static IntPtr Point(int x, int y) { return (IntPtr)((y << 16) | (x & 0xFFFF)); }
}
"@

$hwnd = [SnapProbe]::LargestForm()
if ($hwnd -eq [IntPtr]::Zero) {
  Write-Output "no WinForms window found"
  exit 1
}

[SnapProbe]::PostMessage($hwnd, 0x0201, [IntPtr]::Zero, [SnapProbe]::Point(10, 10)) | Out-Null
Start-Sleep -Milliseconds 60
[SnapProbe]::PostMessage($hwnd, 0x0200, [IntPtr]::Zero, [SnapProbe]::Point(60, 40)) | Out-Null
Start-Sleep -Milliseconds 60
[SnapProbe]::PostMessage($hwnd, 0x0200, [IntPtr]::Zero, [SnapProbe]::Point(110, 80)) | Out-Null
Start-Sleep -Milliseconds 60
[SnapProbe]::PostMessage($hwnd, 0x0202, [IntPtr]::Zero, [SnapProbe]::Point(110, 80)) | Out-Null
Write-Output "dragged on $hwnd"
exit 0
