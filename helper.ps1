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
  [DllImport("user32.dll")] public static extern bool AttachThreadInput(uint idAttach, uint idAttachTo, bool attach);
  [DllImport("user32.dll")] public static extern bool BringWindowToTop(IntPtr hWnd);
  [DllImport("user32.dll")] public static extern void SwitchToThisWindow(IntPtr hWnd, bool altTab);
  [DllImport("user32.dll")] public static extern bool SetWindowPos(IntPtr hWnd, IntPtr insertAfter, int x, int y, int cx, int cy, uint flags);
  [DllImport("kernel32.dll")] public static extern uint GetCurrentThreadId();
  public struct RECT { public int Left; public int Top; public int Right; public int Bottom; }
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
      $script:snap.form.Hide()
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
    $script:snap.form.Hide()
  })

  $form.Add_KeyDown({
    param($sender, $eventArgs)
    if ($eventArgs.KeyCode -eq [System.Windows.Forms.Keys]::Escape) {
      $script:snap.form.Hide()
    }
  })

  $form.Add_Paint({
    param($sender, $eventArgs)
    if (-not $script:snap.painted) {
      $script:snap.painted = $true
      Write-SnapLog ("first paint {0}ms after show" -f [int]((Get-Date) - $script:snap.shownAt).TotalMilliseconds)
    }
    $g = $eventArgs.Graphics
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
    $zoomed = [SnapDpi]::IsZoomed($target.hwnd)
    # 关掉这个窗口的 DWM 过渡动画，SW_HIDE 才是瞬时的（否则会有 ~200ms 渐隐，
    # 抓屏会抓到半透明的残影）
    $disableTransitions = 1
    $dwmResult = -1
    try { $dwmResult = [SnapDpi]::DwmSetWindowAttribute($target.hwnd, 3, [ref]$disableTransitions, 4) } catch { $dwmResult = -1 }
    $ret = [SnapDpi]::ShowWindow($target.hwnd, 0)   # SW_HIDE
    [void]$Into.Add(@{
      hwnd = $target.hwnd
      zoomed = $zoomed
      title = $target.title
      ret = $ret
      visible = [SnapDpi]::IsWindowVisible($target.hwnd)
      dwm = $dwmResult
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
    if ($entry.zoomed) { [SnapDpi]::ShowWindow($handle, 3) | Out-Null }
    else { [SnapDpi]::ShowWindow($handle, 5) | Out-Null }
    # 提到 Z 序最前：否则窗口虽然显示了，仍可能被同屏幕的其它窗口压住
    [SnapDpi]::SetWindowPos($handle, [IntPtr]::Zero, 0, 0, 0, 0, 0x0003) | Out-Null   # HWND_TOP | SWP_NOMOVE | SWP_NOSIZE
    $enableTransitions = 0
    try { [SnapDpi]::DwmSetWindowAttribute($handle, 3, [ref]$enableTransitions, 4) | Out-Null } catch { }
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

# 隐藏没生效时，把 DSH 窗口矩形涂成深色，保证冻结画面里不会出现 DSH
function Mask-StillVisible {
  param($Hidden)
  $still = @()
  foreach ($entry in $Hidden) {
    if ([SnapDpi]::IsWindowVisible($entry.hwnd)) { $still += $entry }
  }
  if ($still.Count -eq 0) { return $still }
  $brush = New-Object System.Drawing.SolidBrush([System.Drawing.Color]::FromArgb(255, 16, 16, 20))
  $graphics = [System.Drawing.Graphics]::FromImage($script:snap.bitmap)
  try {
    $bounds = [System.Windows.Forms.SystemInformation]::VirtualScreen
    foreach ($entry in $still) {
      $rect = [SnapDpi+RECT]::new()
      [SnapDpi]::GetWindowRect($entry.hwnd, [ref]$rect) | Out-Null
      $w = $rect.Right - $rect.Left
      $h = $rect.Bottom - $rect.Top
      if ($w -gt 0 -and $h -gt 0) {
        $graphics.FillRectangle($brush, ($rect.Left - $bounds.Left), ($rect.Top - $bounds.Top), $w, $h)
      }
    }
  } finally {
    $graphics.Dispose()
    $brush.Dispose()
  }
  return $still
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
    # 还原后要把主窗口抢回前台，否则它会留在其它窗口后面（任务栏看得见、点一下才回来）
    if ($hidden.Count -gt 0) {
      try { $focus = [IntPtr]$hidden[0].hwnd } catch { $focus = [IntPtr]::Zero }
    }
    if ($hidden.Count -gt 0) {
      $detail = ($hidden | ForEach-Object { "{0}[ret={1},visible={2}]" -f $_.title, $_.ret, $_.visible }) -join ' || '
      Write-SnapLog ("hide {0}: {1}" -f $hidden.Count, $detail)
      # 过渡动画关不掉时退回长一点的等待，避免抓到渐隐残影
      $settle = 30
      if (@($hidden | Where-Object { $_.dwm -ne 0 }).Count -gt 0) { $settle = 200 }
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

    if ($hidden.Count -gt 0) {
      $stillVisible = @(Mask-StillVisible -Hidden $hidden)
      if ($stillVisible.Count -gt 0) {
        $maskTitles = ($stillVisible | ForEach-Object { $_.title }) -join ' || '
        Write-SnapLog ("masked {0}: {1}" -f $stillVisible.Count, $maskTitles)
      }
    }

    $form = Ensure-Form
    $form.Bounds = New-Object System.Drawing.Rectangle($bounds.Left, $bounds.Top, $bounds.Width, $bounds.Height)
    $script:snap.painted = $false
    $script:snap.shownAt = Get-Date
    $form.Show()
    $form.Activate()
    [System.Windows.Forms.Application]::DoEvents()
    while ($form.Visible) {
      [System.Windows.Forms.Application]::DoEvents()
      Start-Sleep -Milliseconds 1
    }
    # 先把 DSH 还原并抢回前台，再隐藏冻结窗口：
    # 还原时冻结窗口还占着前台/焦点，系统才会允许我们把焦点交给 DSH，
    # 否则 DSH 会显示在同屏幕其它窗口的下面。
    if ($hidden.Count -gt 0) {
      try {
        $restored = Restore-TargetWindows -Hidden $hidden -Focus $focus
        Write-SnapLog ("restore windows={0} focus={1}" -f $restored, $focus)
        $result.hidden = @()
      } catch {
        Write-SnapLog ("restore error: " + $_.Exception.Message)
      }
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
Write-SnapLog 'helper ready v0.3.2 (hide settle 30ms, restore before overlay hides)'
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
    # 先把结果发回去，再立即还原 DSH
    $stdout.WriteLine("$id|$($result.status)")
    $stdout.Flush()
    if ($result.hidden.Count -gt 0) {
      try {
        $restored = Restore-TargetWindows -Hidden $result.hidden -Focus $result.focus
        Write-SnapLog ("restore windows={0} focus={1}" -f $restored, $result.focus)
      } catch {
        Write-SnapLog ("restore error: " + $_.Exception.Message)
      }
    }
  } catch {
    $message = [System.Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes($_.Exception.Message))
    Write-SnapLog ("request error: " + $_.Exception.Message)
    $stdout.WriteLine("$id|error|$message")
  }
  $stdout.Flush()
}
