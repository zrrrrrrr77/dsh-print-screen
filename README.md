# dsh-Print Screen

[English](#english) | 中文

`dsh-print-screen` 给 DSH 桌面版的输入框加一个剪刀按钮：点一下把整个虚拟桌面（所有显示器）按原位置、原像素冻结，在画面上拖一个矩形，松手后把该区域作为图片附件插入当前提示词框，同时另存一份 PNG 到会话目录。仅 Windows。

```text
输入框左下角：  [+]  [✂]  [工作区内修改]  [计划]
                     │
                     └─ 点剪刀 → 屏幕冻结（原位、原大小）→ 拖框 → 松手 → 缩略图进输入框
```

## 功能

- **一个剪刀按钮**：和普通的输入框按钮一样——透明背景、只有图标，不占额外宽度。
- **冻结屏幕再拉框**：整块虚拟桌面（所有显示器）冻结，每张画面**保持原位、保持原始像素大小**；松手即裁剪并插入。
- **默认隐藏 DSH**：截图前先隐藏 DSH 窗口，截完立即还原（最大化状态也还原），因此能截到被它挡住的窗口。
- **不隐藏的两种方式**：按住 `Shift` 点剪刀，或按 `Ctrl+Shift+Alt+1`。
- **插入提示词框**：走会话自己的附件 API，缩略图出现在输入框下方，回车随消息发出；失败时退回合成粘贴事件，再不行就复制到剪贴板并提示 `Ctrl+V`。
- **文件名带时间戳**：附件名是 `screenshot-2026-10-26_22-31-05.png`（本地时间，精确到秒），多张截图不会重名。
- **同时存一份到会话文件夹**：截图会另存到当前会话的工作目录（`session.cwd`，配合 dsh-session-folder 就是会话自己的文件夹），同一秒内重复则自动加 `-1`、`-2`。目录不可写时静默跳过，不影响插入。

## 交互一览

| 操作 | 行为 |
|---|---|
| 单击剪刀 | 截屏，先隐藏 DSH 窗口 |
| `Shift` + 单击剪刀 | 截屏，不隐藏 DSH（可以连它一起截） |
| `Ctrl+Alt+1` | 同单击：截屏并隐藏 DSH |
| `Ctrl+Shift+Alt+1` | 截屏但不隐藏 DSH |
| 拖框 → 松手 | 裁剪、存一份到会话文件夹，并插入当前输入框（DSH 窗口在裁剪完立即还原） |
| `Esc` / 右键 | 取消 |

> 快捷键用物理键位判断（`event.code`），`Shift+1` 打出 `!` 的布局也能触发；`!` 本身不做兼容。

## 速度

每次截图不再重新起 `powershell.exe`（那要付约 1.2 秒的进程启动 + 程序集加载，火绒还会再扫一遍）。改成 DSH 启动后 2.5 秒（避开启动高峰）在后台拉起一个**常驻截图助手** `helper.ps1`，WinForms / DPI / P-Invoke / 位图缓冲只初始化一次，之后每次只需要：

| 阶段 | 耗时（实测） |
|---|---|
| 助手启动（每次 DSH 启动只一次，后台） | ~1.4s |
| 点击 → 冻结画面出现（热态） | ~0.15s（关掉该窗口的 DWM 过渡后 SW_HIDE 瞬时生效，只等 30ms；画面用 BitBlt 直贴，首次绘制 ~40ms） |
| 第一次请求（含首次绘制 JIT） | ~0.3s |
| 拖框 → 返回裁剪图 | 保存约 0.02s + 传输/插入 |

具体做法：截图走 `BitBlt` 直接拷进常驻的 DIB（比 GDI+ 逐屏 `CopyFromScreen` 快 30–40ms）；隐藏 DSH 用瞬时的 `SW_HIDE`（`SW_MINIMIZE` 有 150–250ms 动画）；窗体、画笔字体、位图缓冲全部跨请求复用，整套流程只有 `helper.ps1` 一个实现。

助手起不来或中途挂掉时，宿主会自动重启它再试一次，而不是维护第二套截图脚本。

## 环境要求

| 项目 | 要求 |
|---|---|
| DSH | `>= 0.2.1-rc.3`（`engines.dsh`） |
| 系统 | **仅 Windows**（10/11，需要系统自带的 Windows PowerShell 5.1 + System.Drawing/WinForms） |
| 其它 | 无 Node 原生模块、无外部服务、无 API Key |

## 安装

目前**没有发布到 npm**，直接用 GitHub 源码安装：

```sh
dsh plugin --profile web add github:zrrrrrrr77/ZR7
```

也可以在 DSH 里打开 **插件 → 发现**，用插件市场安装（市场条目见仓库）。

装完在输入框左侧、「工作区内修改」左边就能看到剪刀；看不到就刷新页面，必要时完全退出 DSH 再打开（宿主半边要重启才加载）。

> `dsh plugin --profile web` 里的 `web` 换成你自己的 profile 名；DSH 桌面版的 profile 由应用管理，建议直接在应用内的插件页安装。

## 实现要点

- **DPI 是关键**：截图脚本必须声明 **Per-Monitor V2 DPI 感知**。不声明时 Windows 会把进程按 250% 虚拟化，冻结画面被整体放大 2.5 倍——用户看到的就是「屏幕被放大、不是原样」。声明后所有坐标都是物理像素，显示与鼠标位置 1:1。
- 抓图用 `BitBlt` 逐屏直拷进常驻的 DIB（比 GDI+ `CopyFromScreen` 快 30–40ms），屏幕尺寸变了才重建缓冲。冻结窗口也在 `Paint` 里用 `BitBlt` 直接把 DIB 贴到窗口 DC，而不是 `BackgroundImage`——后者整屏首次绘制要 ~500ms，拖框时会明显卡住。
- 隐藏 DSH 前先 `DwmSetWindowAttribute(hwnd, DWMWA_TRANSITIONS_FORCEDISABLED, TRUE)` 关掉这个窗口的 DWM 过渡，`SW_HIDE` 就变成瞬时的；再等 **30ms** 让合成器出一帧，然后抓屏（不关过渡时窗口会渐隐 ~200ms，40ms 抓到的还是半透明残影）。窗口匹配取两条线索的并集：**进程名**是 `DeepSeek Harness` 的所有可见顶层窗口，以及**标题以 `DeepSeek Harness` 结尾**的窗口——实测 DSH 主窗口的宿主进程未必叫这个名字，只按进程名会一个窗口都匹配不到，DSH 就留在冻结画面里。截完按各自原状态 `SW_SHOW` / `SW_SHOWMAXIMIZED` 还原。
- 隐藏后再检查一次：如果仍有窗口可见（隐藏没生效），就把它的矩形从冻结画面里涂掉，保证截图里永远不会出现 DSH。
- 隐藏/还原的窗口列表用 `ArrayList` 以参数传入（`Get-TargetWindows -Into`），不让函数直接 `return` 集合——PowerShell 会把单元素集合展开成单个对象，只匹配到主窗口时还原逻辑会整段失效（表现为截图后 DSH 停在任务栏、必须手点图标）。还原后还会 `SwitchToThisWindow` + `SetForegroundWindow` 把主窗口切回前台。
- 框选区域**不压暗、不画阴影**，只描一圈清晰的双色边框（外黑内蓝），任何背景下都能看清边界。
- DSH 桌面版的 Host 是独立的 node 进程，没有 `desktopCapturer`，渲染层又被 `contextIsolation` 隔离且禁用 display media，所以「冻结 + 拉框」交给随包发布的 `helper.ps1` 完成。
- 插入图片的三条通道：`ctx.get('conversation').createDrafts()` + `inputActions.addAttachments()` → 合成 Lexical `paste` 事件 → 剪贴板兜底。
- 落盘：截图先在临时目录收尾，再由宿主按客户端传来的 `session.cwd` + 时间戳文件名复制一份到会话目录（`wx` 排他创建，重名自动 `-1`），响应头 `X-Screenshot-Saved` 把路径带回前端。

## 隐私与安全

- 截图**只在本机流转**：宿主进程调用 `powershell.exe` 起一个 WinForms 全屏窗口，画面只在内存里；选完的裁剪结果会**留一份在会话目录**，临时目录里的中转文件读回浏览器后立即删除。插件没有网络请求。
- 插件会以你的用户权限执行 `powershell.exe -File helper.ps1 -ExecutionPolicy Bypass`（脚本随包发布，可自行审查）；它只隐藏/还原**进程名或窗口标题匹配 DSH** 的窗口，不会碰别的程序。
- 插入图片复用 DSH 自己的附件通道，图片和普通粘贴的图片走同一条上传/落盘路径。

## 自测

```sh
node test.mjs          # 路由注册、跨站拒绝、真实截一张（-SelfTest 固定裁剪，不弹窗）
node test-client.mjs   # 按钮结构、Shift / Ctrl+Alt+1 快捷键判定、时间戳文件名
node test-route.mjs    # 集成：真实路由 + 常驻助手 + 模拟拖框，量冷/热延迟
node --check client.js
node --check index.js
```

```powershell
powershell -ExecutionPolicy Bypass -File test-helper.ps1   # 常驻助手：启动耗时、热态延迟、模拟拖框
powershell -ExecutionPolicy Bypass -File test-hide.ps1     # 用一个替身窗口验证「隐藏 / 还原」
```

助手协议支持自测模式（第 6 个字段为 `1`，不弹窗口、固定裁 320×200），`node test.mjs` 用的就是它。

## 已知限制

- 仅 Windows。
- 冻结窗口是普通 TopMost 窗口，理论上可能被其他 TopMost 窗口盖住一角。
- 截图期间 DSH 会被隐藏；如果助手卡死（5 分钟超时会被杀掉），DSH 需要手动还原。

## License

MIT

---

<a id="english"></a>

## English

`dsh-print-screen` adds one scissors button to the DSH composer. Clicking it freezes the whole virtual desktop (all monitors, at their original position and pixel size); drag a rectangle on the frozen screen and the crop is inserted into the prompt as an image attachment, plus saved as a PNG into the session folder. Windows only.

- **Windows only.** The host process has no Electron `desktopCapturer`, so the freeze-and-drag overlay is a `powershell.exe` + WinForms window shipped in this package. It declares Per-Monitor V2 DPI awareness so the frozen image is 1:1 with the screen instead of being scaled up.
- **One transparent scissors button** next to the composer's `+`, left of the permission chip.
- **Hiding DSH**: the window is hidden for the shot by default and restored right after the crop; hold `Shift` (or press `Ctrl+Shift+Alt+1`) to keep it visible, or press `Ctrl+Alt+1` for the default behavior.

```sh
dsh plugin --profile web add github:zrrrrrrr77/ZR7
```

Requires `dsh >= 0.2.1-rc.3`. Screenshots never leave the machine; the plugin makes no network requests. Insertion reuses DSH's own attachment pipeline (`conversation.createDrafts` + `inputActions.addAttachments`), falling back to a synthetic Lexical `paste` event and finally the clipboard.
