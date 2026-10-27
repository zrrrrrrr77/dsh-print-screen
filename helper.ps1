param()

# dsh-print-screen 常驻截图助手（唯一的截图实现）。
#
# 启动一次，之后常驻读 stdin；每次截图只做「隐藏 DSH → 抓屏 → 显示冻结窗口」。
# 窗体、GDI 缓冲、画笔字体都只创建一次，跨请求复用。
#
# 行协议（ASCII，避免控制台编码问题）：
#   请求：<id>|<hide 0/1>|<delayMs>|<base64(outPath)>[|<base64(processName)>][|<selftest 0/1>]
#   应答：<id>|ok / <id>|cancel / <id>|error|<base64(message)>
#   启动完成：ready
#   stdin 关闭或收到 exit：退出
$ErrorActionPreference = 'Stop'

Add-Type -TypeDefinition @"
using System;
using System.Runtime.InteropServices;
public static class SnapDpi {
  [DllImport("user32.dll")] public static extern bool SetProcessDpiAwarenessContext(IntPtr ctx);
  [DllImport("shcore.dll")] public static extern int SetProcessDpiAwareness(int value);
  [DllImport("user32.dll")] public static extern bool SetProcessDPIAware();
  [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr hWnd, int nCmdShow);
  [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr hWnd);
  [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
  [DllImport("user32.dll")] public static extern bool IsZoomed(IntPtr hWnd);
  [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr hWnd);
  [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr hWnd, out uint lpdwProcessId);
  [DllImport("user32.dll", CharSet = CharSet.Unicode)] public static extern int GetWindowText(IntPtr hWnd, System.Text.StringBuilder sb, int max);
  [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr hWnd, out RECT rect);
  public delegate bool EnumProc(IntPtr hWnd, IntPtr lParam);
  [DllImport("user32.dll")] public static extern bool EnumWindows(EnumProc callback, IntPtr lParam);
  [DllImport("dwmapi.dll")] public static extern int DwmSetWindowAttribute(IntPtr hwnd, int attr, ref int value, int size);
  [DllImport("dwmapi.dll")] public static extern int DwmFlush();
  [DllImport("user32.dll")] public static extern bool AttachThreadInput(uint idAttach, uint idAttachTo, bool attach);
  [DllImport("user32.dll")] public static extern bool BringWindowToTop(IntPtr hWnd);
  [DllImport("user32.dll")] public static extern void SwitchToThisWindow(IntPtr hWnd, bool altTab);
  [DllImport("user32.dll")] public static extern bool SetWindowPos(IntPtr hWnd, IntPtr insertAfter, int x, int y, int cx, int cy, uint flags);
  [DllImport("user32.dll")] public static extern bool RedrawWindow(IntPtr hWnd, IntPtr rect, IntPtr region, uint flags);
  [DllImport("user32.dll")] public static extern int GetWindowLong(IntPtr hWnd, int index);
  [DllImport("user32.dll")] public static extern int SetWindowLong(IntPtr hWnd, int index, int value);
  [DllImport("user32.dll")] public static extern bool SetLayeredWindowAttributes(IntPtr hWnd, uint colorKey, byte alpha, uint flags);
  [DllImport("kernel32.dll")] public static extern uint GetCurrentThreadId();
  public struct RECT { public int Left; public int Top; public int Right; public int Bottom; }
  public struct POINT { public int X; public int Y; }
}
public static class SnapBlit {
  [DllImport("user32.dll")] public static extern IntPtr GetDC(IntPtr hWnd);
  [DllImport("user32.dll")] public static extern int ReleaseDC(IntPtr hWnd, IntPtr hDC);
  [DllImport("gdi32.dll")] public static extern IntPtr CreateCompatibleDC(IntPtr hdc);
  [DllImport("gdi32.dll")] public static extern bool DeleteDC(IntPtr hdc);
  [DllImport("gdi32.dll")] public static extern IntPtr SelectObject(IntPtr hdc, IntPtr obj);
  [DllImport("gdi32.dll")] public static extern bool BitBlt(IntPtr hdcDest, int x, int y, int w, int h, IntPtr hdcSrc, int sx, int sy, int rop);
  [DllImport("gdi32.dll")] public static extern IntPtr CreateDIBSection(IntPtr hdc, ref BITMAPINFO bmi, uint usage, out IntPtr bits, IntPtr hSection, uint offset);
  [DllImport("gdi32.dll")] public static extern bool DeleteObject(IntPtr obj);
  public struct BITMAPINFOHEADER {
    public uint biSize; public int biWidth; public int biHeight;
    public ushort biPlanes; public ushort biBitCount; public uint biCompression;
    public uint biSizeImage; public int biXPelsPerMeter; public int biYPelsPerMeter;
    public uint biClrUsed; public uint biClrImportant;
  }
  public struct BITMAPINFO { public BITMAPINFOHEADER bmiHeader; public uint bmiColors; }
  public const int SRCCOPY = 0x00CC0020;
  public static IntPtr CreateDib(int w, int h, out IntPtr bits) {
    var bmi = new BITMAPINFO();
    bmi.bmiHeader.biSize = (uint)Marshal.SizeOf(typeof(BITMAPINFOHEADER));
    bmi.bmiHeader.biWidth = w;
    bmi.bmiHeader.biHeight = -h;
    bmi.bmiHeader.biPlanes = 1;
    bmi.bmiHeader.biBitCount = 32;
    bmi.bmiHeader.biCompression = 0;
    IntPtr dc = GetDC(IntPtr.Zero);
    IntPtr dib = CreateDIBSection(dc, ref bmi, 0, out bits, IntPtr.Zero, 0);
    ReleaseDC(IntPtr.Zero, dc);
    return dib;
  }
}
"@

$dpiReady = $false
try { $dpiReady = [SnapDpi]::SetProcessDpiAwarenessContext([IntPtr](-4)) } catch { $dpiReady = $false }
if (-not $dpiReady) {
  try { [SnapDpi]::SetProcessDpiAwareness(2) | Out-Null; $dpiReady = $true } catch { $dpiReady = $false }
}
if (-not $dpiReady) {
  try { [SnapDpi]::SetProcessDPIAware() | Out-Null } catch { }
}

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
[System.Windows.Forms.Application]::EnableVisualStyles()

function Write-SnapLog {
  param([string]$Text)
  try {
    $path = Join-Path $env:TEMP 'dsh-print-screen-helper.log'
    $info = Get-Item -LiteralPath $path -ErrorAction SilentlyContinue
    if ($info -ne $null -and $info.Length -gt 262144) { Remove-Item -LiteralPath $path -Force -ErrorAction SilentlyContinue }
    Add-Content -LiteralPath $path -Value ((Get-Date -Format 'yyyy-MM-dd HH:mm:ss') + ' ' + $Text) -Encoding UTF8
  } catch { }
}

# 跨请求复用的状态
$script:snap = @{
  bitmap = $null
  dib = [IntPtr]::Zero
  screenDc = [IntPtr]::Zero
  memDc = [IntPtr]::Zero
  oldObj = [IntPtr]::Zero
  form = $null
  outPath = ''
  saved = $false
  dragging = $false
  firstMove = $false
  origin = [System.Drawing.Point]::Empty
  rect = [System.Drawing.Rectangle]::Empty
  hidden = @()
  focus = [IntPtr]::Zero
}
$script:ui = $null

function Ensure-Surface {
  $bounds = [System.Windows.Forms.SystemInformation]::VirtualScreen
  if ($null -ne $script:snap.bitmap -and $script:snap.bitmap.Width -eq $bounds.Width -and $script:snap.bitmap.Height -eq $bounds.Height) {
    return $bounds
  }
  if ($null -ne $script:snap.bitmap) { $script:snap.bitmap.Dispose() }
  if ($script:snap.dib -ne [IntPtr]::Zero) {
    [SnapBlit]::SelectObject($script:snap.memDc, $script:snap.oldObj) | Out-Null
    [SnapBlit]::DeleteDC($script:snap.memDc) | Out-Null
    [SnapBlit]::ReleaseDC([IntPtr]::Zero, $script:snap.screenDc) | Out-Null
    [SnapBlit]::DeleteObject($script:snap.dib) | Out-Null
  }
  $bits = [IntPtr]::Zero
  $script:snap.dib = [SnapBlit]::CreateDib($bounds.Width, $bounds.Height, [ref]$bits)
  $script:snap.screenDc = [SnapBlit]::GetDC([IntPtr]::Zero)
  $script:snap.memDc = [SnapBlit]::CreateCompatibleDC($script:snap.screenDc)
  $script:snap.oldObj = [SnapBlit]::SelectObject($script:snap.memDc, $script:snap.dib)
  $script:snap.bitmap = New-Object System.Drawing.Bitmap(
    $bounds.Width,
    $bounds.Height,
    ($bounds.Width * 4),
    [System.Drawing.Imaging.PixelFormat]::Format32bppRgb,
    $bits
  )
  if ($null -ne $script:snap.form) {
    $script:snap.form.Bounds = New-Object System.Drawing.Rectangle($bounds.Left, $bounds.Top, $bounds.Width, $bounds.Height)
  }
  return $bounds
}

# 关闭冻结窗口：直接隐藏。DSH 全程没有被 SW_HIDE，
# 画面一直由它自己保持着，所以隐藏后不会再闪出白色首帧。
function Close-SnapForm {
  if ($null -eq $script:snap.form) { return }
  try { $script:snap.form.Hide() } catch { }
}

function Ensure-Form {
  if ($null -ne $script:snap.form) { return $script:snap.form }

  $edgePen = New-Object System.Drawing.Pen([System.Drawing.Color]::FromArgb(200, 0, 0, 0), 1)
  $linePen = New-Object System.Drawing.Pen([System.Drawing.Color]::FromArgb(255, 76, 154, 255), 1)
  $hintFont = New-Object System.Drawing.Font('Microsoft YaHei UI', 11)
  $hintBrush = New-Object System.Drawing.SolidBrush([System.Drawing.Color]::White)
  $hintShadow = New-Object System.Drawing.SolidBrush([System.Drawing.Color]::FromArgb(160, 0, 0, 0))
  $script:ui = @{
    edgePen = $edgePen
    linePen = $linePen
    hintFont = $hintFont
    hintBrush = $hintBrush
    hintShadow = $hintShadow
  }

  $bounds = [System.Windows.Forms.SystemInformation]::VirtualScreen
  $form = New-Object System.Windows.Forms.Form
  $form.AutoScaleMode = [System.Windows.Forms.AutoScaleMode]::None
  $form.FormBorderStyle = [System.Windows.Forms.FormBorderStyle]::None
  $form.StartPosition = [System.Windows.Forms.FormStartPosition]::Manual
  $form.Bounds = New-Object System.Drawing.Rectangle($bounds.Left, $bounds.Top, $bounds.Width, $bounds.Height)
  $form.TopMost = $true
  $form.ShowInTaskbar = $false
  $form.Cursor = [System.Windows.Forms.Cursors]::Cross
  $form.BackColor = [System.Drawing.Color]::Black
  $form.BackgroundImageLayout = [System.Windows.Forms.ImageLayout]::None
  $form.KeyPreview = $true
  $doubleBuffered = [System.Windows.Forms.Control].GetProperty(
    'DoubleBuffered',
    [System.Reflection.BindingFlags]::Instance -bor [System.Reflection.BindingFlags]::NonPublic
  )
  if ($doubleBuffered -ne $null) { $doubleBuffered.SetValue($form, $true) }

  $form.Add_MouseDown({
    param($sender, $eventArgs)
    if ($eventArgs.Button -ne [System.Windows.Forms.MouseButtons]::Left) {
      Close-SnapForm
      return
    }
    $script:snap.dragging = $true
    $script:snap.firstMove = $true
    $script:snap.origin = $eventArgs.Location
    $script:snap.rect = New-Object System.Drawing.Rectangle($eventArgs.X, $eventArgs.Y, 0, 0)
    $script:snap.form.Invalidate()
  })

  $form.Add_MouseMove({
    param($sender, $eventArgs)
    if (-not $script:snap.dragging) { return }
    $oldRect = $script:snap.rect
    $left = [Math]::Min($script:snap.origin.X, $eventArgs.X)
    $top = [Math]::Min($script:snap.origin.Y, $eventArgs.Y)
    $right = [Math]::Max($script:snap.origin.X, $eventArgs.X)
    $bottom = [Math]::Max($script:snap.origin.Y, $eventArgs.Y)
    $script:snap.rect = [System.Drawing.Rectangle]::FromLTRB($left, $top, $right, $bottom)
    if ($script:snap.firstMove) {
      $script:snap.firstMove = $false
      $script:snap.form.Invalidate()
    } else {
      $dirty = [System.Drawing.Rectangle]::Union($oldRect, $script:snap.rect)
      $dirty.Inflate(12, 40)
      $script:snap.form.Invalidate($dirty)
    }
  })

  $form.Add_MouseUp({
    param($sender, $eventArgs)
    if (-not $script:snap.dragging) { return }
    $script:snap.dragging = $false
    $rect = $script:snap.rect
    if ($rect.Width -ge 4 -and $rect.Height -ge 4) {
      $bitmap = $script:snap.bitmap
      $safeLeft = [Math]::Max(0, [Math]::Min($rect.Left, $bitmap.Width - 1))
      $safeTop = [Math]::Max(0, [Math]::Min($rect.Top, $bitmap.Height - 1))
      $safeRight = [Math]::Max($safeLeft + 1, [Math]::Min($rect.Right, $bitmap.Width))
      $safeBottom = [Math]::Max($safeTop + 1, [Math]::Min($rect.Bottom, $bitmap.Height))
      $cropRect = New-Object System.Drawing.Rectangle($safeLeft, $safeTop, ($safeRight - $safeLeft), ($safeBottom - $safeTop))
      $crop = $bitmap.Clone($cropRect, $bitmap.PixelFormat)
      try {
        $crop.Save($script:snap.outPath, [System.Drawing.Imaging.ImageFormat]::Png)
        $script:snap.saved = $true
      } finally {
        $crop.Dispose()
      }
    }
    Close-SnapForm
  })

  $form.Add_KeyDown({
    param($sender, $eventArgs)
    if ($eventArgs.KeyCode -eq [System.Windows.Forms.Keys]::Escape) {
      Close-SnapForm
    }
  })

  $form.Add_Paint({
    param($sender, $eventArgs)
    if (-not $script:snap.painted) {
      $script:snap.painted = $true
      Write-SnapLog ("first paint {0}ms after show" -f [int]((Get-Date) - $script:snap.shownAt).TotalMilliseconds)
    }
    $g = $eventArgs.Graphics
    # 关闭时整屏刷黑（盖住 DSH 的首帧白色），其余时候贴冻结画面。
    # 用 GDI 的 BitBlt 把冻结画面直接贴到窗口 DC 上：比 WinForms 画 BackgroundImage
    # 快一个数量级（整屏 7680×2160 的 BackgroundImage 首次绘制要 ~500ms）
    $clip = $eventArgs.ClipRectangle
    if ($clip.Width -gt 0 -and $clip.Height -gt 0 -and $script:snap.memDc -ne [IntPtr]::Zero) {
      $hdc = $g.GetHdc()
      try {
        [SnapBlit]::BitBlt(
          $hdc, $clip.X, $clip.Y, $clip.Width, $clip.Height,
          $script:snap.memDc, $clip.X, $clip.Y, [SnapBlit]::SRCCOPY
        ) | Out-Null
      } finally {
        $g.ReleaseHdc($hdc)
      }
    }
    $r = $script:snap.rect
    if ($script:snap.dragging -and $r.Width -gt 1 -and $r.Height -gt 1) {
      $g.DrawRectangle($script:ui.edgePen, $r.Left, $r.Top, [Math]::Max(1, $r.Width - 1), [Math]::Max(1, $r.Height - 1))
      if ($r.Width -ge 4 -and $r.Height -ge 4) {
        $g.DrawRectangle($script:ui.linePen, ($r.Left + 1), ($r.Top + 1), [Math]::Max(1, $r.Width - 3), [Math]::Max(1, $r.Height - 3))
      }
      $text = "$($r.Width) × $($r.Height)"
      if ($r.Top -ge 32) { $textY = $r.Top - 28 } else { $textY = $r.Bottom + 6 }
      $g.DrawString($text, $script:ui.hintFont, $script:ui.hintShadow, ($r.Left + 1), ($textY + 1))
      $g.DrawString($text, $script:ui.hintFont, $script:ui.hintBrush, $r.Left, $textY)
    }
    $hint = '拖动框选区域 · Esc 取消'
    $g.DrawString($hint, $script:ui.hintFont, $script:ui.hintShadow, 41, 25)
    $g.DrawString($hint, $script:ui.hintFont, $script:ui.hintBrush, 40, 24)
  })

  $script:snap.form = $form
  return $form
}

function Get-TargetWindows {
  param([string]$OnlyProcess, $Into)
  $pids = New-Object System.Collections.ArrayList
  foreach ($proc in @(Get-Process -Name $OnlyProcess -ErrorAction SilentlyContinue)) {
    if ($null -ne $proc) { [void]$pids.Add([uint32]$proc.Id) }
  }
  $callback = [SnapDpi+EnumProc]{
    param($hWnd, $lParam)
    if (-not [SnapDpi]::IsWindowVisible($hWnd)) { return $true }
    $windowPid = 0
    [SnapDpi]::GetWindowThreadProcessId($hWnd, [ref]$windowPid) | Out-Null
    $buffer = New-Object System.Text.StringBuilder 512
    [void][SnapDpi]::GetWindowText($hWnd, $buffer, 512)
    $title = $buffer.ToString()
    $matched = $pids -contains $windowPid
    if (-not $matched) {
      # DSH 窗口标题以 “DeepSeek Harness” 结尾；宿主进程名未必叫这个，所以标题也算一条线索
      $matched = $title.TrimEnd().EndsWith($OnlyProcess, [System.StringComparison]::OrdinalIgnoreCase)
    }
    if ($matched) { [void]$Into.Add(@{ hwnd = $hWnd; title = $title }) }
    return $true
  }
  [SnapDpi]::EnumWindows($callback, [IntPtr]::Zero) | Out-Null
}

function Hide-TargetWindows {
  param($Targets, $Into)
  foreach ($target in $Targets) {
    # 不隐藏窗口，而是把它变成“全透明”（WS_EX_LAYERED + alpha=0）：
    # 窗口状态、Z 序、焦点、GPU 画面都不变，所以恢复时不会重绘出白帧；
    # 画面上它消失了，抓屏就能拍到后面的内容。
    $style = 0
    try { $style = [SnapDpi]::GetWindowLong($target.hwnd, -20) } catch { $style = 0 }
    $applied = $false
    try {
      [SnapDpi]::SetWindowLong($target.hwnd, -20, ($style -bor 0x80000)) | Out-Null
      $applied = [SnapDpi]::SetLayeredWindowAttributes($target.hwnd, 0, 0, 0x2)
    } catch { $applied = $false }
    $fallback = $false
    if (-not $applied) {
      # 个别窗口不接受分层样式，退回 SW_HIDE（会有白帧，但总比把 DSH 截进去好）
      try {
        [SnapDpi]::ShowWindow($target.hwnd, 0) | Out-Null
        $fallback = $true
      } catch { }
    }
    [void]$Into.Add(@{
      hwnd = $target.hwnd
      title = $target.title
      style = $style
      ret = $applied
      fallback = $fallback
      zoomed = [SnapDpi]::IsZoomed($target.hwnd)
    })
  }
}

function Restore-TargetWindows {
  param($Hidden, $Focus)
  $focusHwnd = [IntPtr]::Zero
  if ($null -ne $Focus) {
    try { $focusHwnd = [IntPtr]$Focus } catch { $focusHwnd = [IntPtr]::Zero }
  }
  $restored = 0
  foreach ($entry in $Hidden) {
    $handle = [IntPtr]::Zero
    try { $handle = [IntPtr]$entry.hwnd } catch { $handle = [IntPtr]::Zero }
    if ($handle -eq [IntPtr]::Zero) { continue }
    if ($entry.fallback) {
      if ($entry.zoomed) { [SnapDpi]::ShowWindow($handle, 3) | Out-Null }
      else { [SnapDpi]::ShowWindow($handle, 5) | Out-Null }
    } else {
      # 恢复不透明并去掉分层样式（窗口从未被隐藏，画面不用重绘）
      try { [SnapDpi]::SetLayeredWindowAttributes($handle, 0, 255, 0x2) | Out-Null } catch { }
      try { [SnapDpi]::SetWindowLong($handle, -20, [int]$entry.style) | Out-Null } catch { }
    }
    # 提到 Z 序最前：否则窗口虽然回到原位，仍可能被同屏幕的其它窗口压住
    [SnapDpi]::SetWindowPos($handle, [IntPtr]::Zero, 0, 0, 0, 0, 0x0003) | Out-Null   # HWND_TOP | SWP_NOMOVE | SWP_NOSIZE
    $restored++
  }
  if ($focusHwnd -eq [IntPtr]::Zero -and $Hidden.Count -gt 0) {
    try { $focusHwnd = [IntPtr]$Hidden[0].hwnd } catch { $focusHwnd = [IntPtr]::Zero }
  }
  if ($focusHwnd -ne [IntPtr]::Zero) {
    # 还原后把主窗口抢回前台：不这样做窗口会留在别的窗口后面，
    # 表现就是「任务栏有图标、点一下才出来」
    $foreground = [SnapDpi]::GetForegroundWindow()
    if ($foreground -ne $focusHwnd) {
      $foregroundPid = 0
      $foregroundThread = [SnapDpi]::GetWindowThreadProcessId($foreground, [ref]$foregroundPid)
      $myThread = [SnapDpi]::GetCurrentThreadId()
      $attached = $false
      try {
        if ($foregroundThread -ne 0 -and $foregroundThread -ne $myThread) {
          $attached = [SnapDpi]::AttachThreadInput($myThread, $foregroundThread, $true)
        }
        [SnapDpi]::BringWindowToTop($focusHwnd) | Out-Null
        [SnapDpi]::SwitchToThisWindow($focusHwnd, $false)
        [SnapDpi]::SetForegroundWindow($focusHwnd) | Out-Null
      } finally {
        if ($attached) { [SnapDpi]::AttachThreadInput($myThread, $foregroundThread, $false) | Out-Null }
      }
    }
    Write-SnapLog ("restore focus hwnd={0} fgBefore={1} fgAfter={2}" -f $focusHwnd, $foreground, [SnapDpi]::GetForegroundWindow())
  }
  return $restored
}

# 当前前台窗口标题，写日志用
function Get-ForegroundTitle {
  try {
    $handle = [SnapDpi]::GetForegroundWindow()
    if ($handle -eq [IntPtr]::Zero) { return '(none)' }
    $buffer = New-Object System.Text.StringBuilder 512
    [void][SnapDpi]::GetWindowText($handle, $buffer, 512)
    return $buffer.ToString()
  } catch {
    return '(unknown)'
  }
}

function Copy-ScreenToBuffer {
  $bounds = Ensure-Surface
  $ok = $false
  foreach ($screen in [System.Windows.Forms.Screen]::AllScreens) {
    $b = $screen.Bounds
    $ok = [SnapBlit]::BitBlt(
      $script:snap.memDc, ($b.X - $bounds.Left), ($b.Y - $bounds.Top), $b.Width, $b.Height,
      $script:snap.screenDc, $b.X, $b.Y, [SnapBlit]::SRCCOPY
    ) -or $ok
  }
  if (-not $ok) {
    # 兜底：GDI+ 逐屏拷贝
    $graphics = [System.Drawing.Graphics]::FromImage($script:snap.bitmap)
    try {
      foreach ($screen in [System.Windows.Forms.Screen]::AllScreens) {
        $b = $screen.Bounds
        $graphics.CopyFromScreen($b.X, $b.Y, ($b.X - $bounds.Left), ($b.Y - $bounds.Top), $b.Size)
      }
    } finally {
      $graphics.Dispose()
    }
  }
  return $bounds
}

function Invoke-Capture {
  param(
    [Parameter(Mandatory = $true)][string]$OutPath,
    [bool]$Hide = $true,
    [int]$DelayMs = 30,
    [string]$OnlyProcess = 'DeepSeek Harness',
    [bool]$SelfTest = $false
  )

  $script:snap.saved = $false
  $script:snap.outPath = $OutPath
  $script:snap.dragging = $false
  $script:snap.firstMove = $false
  $script:snap.rect = [System.Drawing.Rectangle]::Empty

  $hidden = New-Object System.Collections.ArrayList
  $focus = [IntPtr]::Zero
  if ($Hide) {
    $targets = New-Object System.Collections.ArrayList
    Get-TargetWindows -OnlyProcess $OnlyProcess -Into $targets
    Hide-TargetWindows -Targets $targets -Into $hidden
    # 还原后要把主窗口抢回前台，否则它会留在其它窗口后面（任务栏看得见、点一下才回来）。
    # 匹配到的可能不止一个窗口（弹出层、提示框），挑面积最大的那个当主窗口。
    if ($hidden.Count -gt 0) {
      $bestArea = 0
      foreach ($entry in $hidden) {
        try {
          $rect = [SnapDpi+RECT]::new()
          [SnapDpi]::GetWindowRect([IntPtr]$entry.hwnd, [ref]$rect) | Out-Null
          $area = ([int64]($rect.Right - $rect.Left)) * ([int64]($rect.Bottom - $rect.Top))
          if ($area -gt $bestArea) { $bestArea = $area; $focus = [IntPtr]$entry.hwnd }
        } catch { }
      }
      if ($focus -eq [IntPtr]::Zero) {
        try { $focus = [IntPtr]$hidden[0].hwnd } catch { $focus = [IntPtr]::Zero }
      }
    }
    if ($hidden.Count -gt 0) {
      $detail = ($hidden | ForEach-Object { "{0}[alpha={1},fallback={2}]" -f $_.title, $_.ret, $_.fallback }) -join ' || '
      Write-SnapLog ("hide {0}: {1}" -f $hidden.Count, $detail)
      # 过渡动画关不掉时退回长一点的等待，避免抓到渐隐残影
      $settle = 60
      if (@($hidden | Where-Object { $_.fallback }).Count -gt 0) { $settle = 200 }
      Start-Sleep -Milliseconds $settle
    } elseif ($DelayMs -gt 0) { Start-Sleep -Milliseconds $DelayMs }
  } elseif ($DelayMs -gt 0) {
    Start-Sleep -Milliseconds $DelayMs
  }

  $result = @{ status = 'cancel'; hidden = $hidden; focus = $focus }

  try {
    $captureWatch = [System.Diagnostics.Stopwatch]::StartNew()
    $bounds = Copy-ScreenToBuffer
    $captureWatch.Stop()
    Write-SnapLog ("capture {0}ms" -f $captureWatch.ElapsedMilliseconds)

    if ($SelfTest) {
      $cropRect = New-Object System.Drawing.Rectangle(10, 10, 320, 200)
      $crop = $script:snap.bitmap.Clone($cropRect, $script:snap.bitmap.PixelFormat)
      try {
        $crop.Save($OutPath, [System.Drawing.Imaging.ImageFormat]::Png)
        $script:snap.saved = $true
      } finally {
        $crop.Dispose()
      }
      if ($script:snap.saved) { $result.status = 'ok' }
      return $result
    }

    $form = Ensure-Form
    $form.Bounds = New-Object System.Drawing.Rectangle($bounds.Left, $bounds.Top, $bounds.Width, $bounds.Height)
    $script:snap.painted = $false
    $script:snap.shownAt = Get-Date
    $form.Show()
    $form.Activate()
    [System.Windows.Forms.Application]::DoEvents()

    # 等冻结画面真正画出来再还原 DSH，否则会看到 DSH 闪一下
    $paintDeadline = [DateTime]::Now.AddMilliseconds(500)
    while (-not $script:snap.painted -and [DateTime]::Now -lt $paintDeadline) {
      [System.Windows.Forms.Application]::DoEvents()
      Start-Sleep -Milliseconds 2
    }

    # 冻结画面已经盖住屏幕，这时再还原 DSH 就看不到它闪一下。
    # 还原后把焦点交回冻结窗口：这样“上一个前台窗口”是 DSH，
    # 冻结窗口关闭时系统会把焦点自然还给 DSH，不需要事后抢焦点。
    if ($hidden.Count -gt 0) {
      try {
        $restored = Restore-TargetWindows -Hidden $hidden -Focus $focus
        Write-SnapLog ("restore windows={0} focus={1}" -f $restored, $focus)
        # 趁冻结画面还盖着屏幕，强制 DSH 立刻重绘一遍：
        # Electron 窗口重新显示后第一帧常常是白的，不在这里画掉，画面一关就是白闪。
        foreach ($entry in $hidden) {
          try {
            [SnapDpi]::RedrawWindow([IntPtr]$entry.hwnd, [IntPtr]::Zero, [IntPtr]::Zero, 0x0181) | Out-Null
          } catch { }
        }
        # 等 DWM 把还原后的窗口合成完，否则冻结画面一关会露出白色首帧。
        # 这里必须继续跑消息循环，否则这 200ms 内用户的拖框会卡住。
        try { [SnapDpi]::DwmFlush() | Out-Null } catch { }
        $settleDeadline = [DateTime]::Now.AddMilliseconds(200)
        while ([DateTime]::Now -lt $settleDeadline) {
          [System.Windows.Forms.Application]::DoEvents()
          Start-Sleep -Milliseconds 4
        }
        $result.hidden = @()
      } catch {
        Write-SnapLog ("restore error: " + $_.Exception.Message)
      }
      $form.Activate()
      [System.Windows.Forms.Application]::DoEvents()
    }

    while ($form.Visible) {
      [System.Windows.Forms.Application]::DoEvents()
      Start-Sleep -Milliseconds 1
    }
    $form.Hide()

    # 取消时可选地把整张冻结画面存下来，排查「DSH 有没有被截进去」。
    # 默认关闭：存 16MB PNG 要 ~200ms，会拖慢取消的响应。
    if (-not $script:snap.saved -and $hidden.Count -gt 0 -and $env:DSH_SCREENSHOT_FRAME_DUMP -eq '1') {
      try {
        $dump = Join-Path $env:TEMP 'dsh-print-screen-last-frame.png'
        $script:snap.bitmap.Save($dump, [System.Drawing.Imaging.ImageFormat]::Png)
        Write-SnapLog ("frame dumped: " + $dump)
      } catch {
        Write-SnapLog ("frame dump failed: " + $_.Exception.Message)
      }
    }

    if ($script:snap.saved) { $result.status = 'ok' }
    return $result
  } catch {
    # 出错也要把窗口还原，避免 DSH 一直处于隐藏状态
    if ($hidden.Count -gt 0) { Restore-TargetWindows -Hidden $hidden -Focus $focus }
    throw
  }
}

$stdin = [Console]::In
$stdout = [Console]::Out
Write-SnapLog 'helper ready v0.4.4 (transparent hide, cleanup)'
$stdout.WriteLine('ready')
$stdout.Flush()

while ($true) {
  $line = $stdin.ReadLine()
  if ($null -eq $line) { break }
  $line = $line.Trim()
  if ($line -eq '') { continue }
  if ($line -eq 'exit') { break }

  $parts = $line.Split('|')
  if ($parts.Length -lt 4) { continue }
  $id = $parts[0]
  try {
    $hide = $parts[1] -eq '1'
    $delay = [int]$parts[2]
    $outPath = [System.Text.Encoding]::UTF8.GetString([System.Convert]::FromBase64String($parts[3]))
    $processName = 'DeepSeek Harness'
    if ($parts.Length -ge 5 -and $parts[4] -ne '') {
      $processName = [System.Text.Encoding]::UTF8.GetString([System.Convert]::FromBase64String($parts[4]))
    }
    $selfTest = $parts.Length -ge 6 -and $parts[5] -eq '1'
    $result = Invoke-Capture -OutPath $outPath -Hide $hide -DelayMs $delay -OnlyProcess $processName -SelfTest $selfTest
    Write-SnapLog ("request status={0} hide={1}" -f $result.status, $hide)
    # 窗口在抓屏后就已经还原并切回前台了；这里只记录一下，不做任何抢占，
    # 以免影响用户之后正常切换到别的窗口。
    $stdout.WriteLine("$id|$($result.status)")
    $stdout.Flush()
    if ($result.focus -ne [IntPtr]::Zero) {
      $foreground = Get-ForegroundTitle
      Write-SnapLog ("after close fg='{0}'" -f $foreground)
    }
  } catch {
    $message = [System.Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes($_.Exception.Message))
    Write-SnapLog ("request error: " + $_.Exception.Message)
    $stdout.WriteLine("$id|error|$message")
  }
  $stdout.Flush()
}
