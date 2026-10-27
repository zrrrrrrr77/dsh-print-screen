/**
 * dsh-print-screen —— 浏览器半
 *
 * 输入框左边一个剪刀按钮（和最初那个相机按钮一样：透明背景、只有图标）：
 *   单击              → 截屏（默认先隐藏 DSH 窗口，截完立即还原）
 *   Shift+单击        → 截屏但不隐藏 DSH 窗口
 *   Ctrl+Alt+1        → 截屏并隐藏 DSH 窗口
 *   Ctrl+Shift+Alt+1  → 截屏但不隐藏 DSH 窗口
 *
 * 截图由宿主弹一个覆盖整个桌面的冻结画面，用户直接在“屏幕”上拉框，
 * 松手即裁剪并插入提示词框。没有设置项、没有下拉菜单。
 */

window.__ModuleLoader__.load({
	id: 'dsh-print-screen',
	factory: (require) => {
		var module = { exports: {} }
		var exports = module.exports
		Object.defineProperty(exports, Symbol.toStringTag, { value: 'Module' })

		const React = require('react')

		const ENDPOINT = '/api/dsh-print-screen/capture'
		const STYLE_ID = 'dsh-print-screen/style'

		/** apply() 里的 ctx，组件里要用它去拿 conversation 服务。 */
		let pluginCtx

		// ---------------------------------------------------------------- styles

		function installStyle() {
			if (document.getElementById(STYLE_ID) !== null) return
			const style = document.createElement('style')
			style.id = STYLE_ID
			style.textContent = `
.dshs-btn {
  display: inline-flex; align-items: center; justify-content: center;
  width: 28px; height: 28px; padding: 0; margin: 0;
  border: none; border-radius: 8px; background: transparent;
  color: var(--dsw-alias-label-secondary, #81858c); cursor: pointer;
  transition: background-color .12s ease, color .12s ease;
}
.dshs-btn:hover:not(:disabled) { background: var(--dsw-alias-interactive-bg-hover, rgba(127,127,127,.14)); color: var(--dsw-alias-label-primary, #e6e8eb); }
.dshs-btn:disabled { cursor: progress; opacity: .55; }
.dshs-btn[data-busy="true"] svg { animation: dshs-spin 1s linear infinite; }
@keyframes dshs-spin { to { transform: rotate(360deg); } }

/* 把左侧插槽整体挪到「工作区内修改」前面；加号仍然排第一个 */
div:has(> [data-slot="conversation.input.left"]):has(> button[aria-haspopup="listbox"]) > button[aria-haspopup="listbox"] { order: -2; }
div:has(> [data-slot="conversation.input.left"]):has(> button[aria-haspopup="listbox"]) > [data-slot="conversation.input.left"] { order: -1; }

.dshs-toast {
  position: fixed; left: 50%; bottom: 42px; transform: translateX(-50%);
  z-index: 2147483001; padding: 8px 16px; border-radius: 10px;
  background: rgba(28, 30, 36, .95); color: #e6e8eb; font-size: 13px;
  border: 1px solid rgba(255,255,255,.12); box-shadow: 0 8px 28px rgba(0,0,0,.45);
  pointer-events: none; opacity: 0; transition: opacity .15s ease;
}
.dshs-toast[data-show="true"] { opacity: 1; }
.dshs-toast[data-tone="error"] { border-color: rgba(255, 96, 96, .5); color: #ffd6d6; }
`
			document.head.appendChild(style)
		}

		// ---------------------------------------------------------------- toast

		let toastEl
		let toastTimer

		function toast(message, tone = 'info') {
			if (toastEl === undefined || !toastEl.isConnected) {
				toastEl = document.createElement('div')
				toastEl.className = 'dshs-toast'
				document.body.appendChild(toastEl)
			}
			toastEl.textContent = message
			toastEl.dataset.tone = tone
			toastEl.dataset.show = 'true'
			clearTimeout(toastTimer)
			toastTimer = setTimeout(() => {
				if (toastEl !== undefined) toastEl.dataset.show = 'false'
			}, 2600)
		}

		// -------------------------------------------------------------- captures

		const mountPoints = new Map()
		let activeSessionId

		/** 当前会话的工作目录（装了 dsh-session-folder 时就是会话自己的文件夹）。 */
		function sessionCwd(sessionId) {
			try {
				const sessions = pluginCtx?.sessions ?? pluginCtx?.get?.('sessions')
				const snapshot = sessions?.list?.getSnapshot?.()
				const cwd = snapshot?.byId?.[sessionId]?.cwd
				return typeof cwd === 'string' && cwd !== '' ? cwd : undefined
			} catch {
				return undefined
			}
		}

		async function requestCapture(hide, fileName, saveDir) {
			// 助手卡住时不要让按钮一直转：120 秒后主动放弃
			const controller = new AbortController()
			const timer = setTimeout(() => controller.abort(), 120_000)
			try {
				const response = await fetch(ENDPOINT, {
					method: 'POST',
					headers: { 'Content-Type': 'application/json' },
					body: JSON.stringify({ hide: hide !== false, fileName, saveDir }),
					signal: controller.signal,
				})
				if (response.status === 204) return null
				if (!response.ok) {
					let message = `截图失败（HTTP ${response.status}）`
					try {
						const data = await response.json()
						if (typeof data?.message === 'string' && data.message !== '') message = data.message
					} catch {
						/* 响应不是 JSON 就保留默认文案 */
					}
					throw new Error(message)
				}
				const blob = await response.blob()
				if (blob.size === 0) throw new Error('截图返回了空图片')
				const savedHeader = response.headers.get('X-Screenshot-Saved')
				let savedPath
				if (savedHeader !== null && savedHeader !== '') {
					try {
						savedPath = decodeURIComponent(savedHeader)
					} catch {
						savedPath = savedHeader
					}
				}
				return { blob, savedPath }
			} catch (error) {
				if (error?.name === 'AbortError') throw new Error('截图超时了，请重试')
				throw error
			} finally {
				clearTimeout(timer)
			}
		}

		function installActivityTracking() {
			const track = (event) => {
				const target = event.target
				if (!(target instanceof Element)) return
				for (const [sessionId, mount] of mountPoints) {
					if (mount.root !== undefined && mount.root.contains(target)) {
						activeSessionId = sessionId
						return
					}
				}
			}
			document.addEventListener('pointerdown', track, true)
			document.addEventListener('focusin', track, true)
		}

		// ------------------------------------------------------------ insertion

		function conversationService(sessionId) {
			const ctx = pluginCtx
			if (ctx === undefined) return undefined
			try {
				const direct = ctx.get?.('conversation')
				if (direct !== undefined && direct !== null) return direct
			} catch {
				/* 服务不在当前作用域，继续找会话作用域 */
			}
			try {
				const scoped = ctx.sessions?.scope?.(sessionId)?.get?.('conversation')
				if (scoped !== undefined && scoped !== null) return scoped
			} catch {
				/* 没有 scoped 服务 */
			}
			return undefined
		}

		function editorElement() {
			return document.querySelector('[data-lexical-editor="true"]') ?? document.querySelector('[contenteditable="true"]')
		}

		function focusComposer() {
			editorElement()?.focus?.()
		}

		/**
		 * 尽力把图片放进当前输入框的附件区。
		 * @returns {'attached'|'pasted'|'clipboard'|'failed'}
		 */
		async function insertImage(file, sessionId, inputActions) {
			// 1) 官方附件通道：conversation.createDrafts + inputActions.addAttachments
			try {
				if (typeof sessionId === 'string' && sessionId !== '' && typeof inputActions?.addAttachments === 'function') {
					const conversation = conversationService(sessionId)
					if (conversation !== undefined && typeof conversation.createDrafts === 'function') {
						const drafts = conversation.createDrafts(sessionId, [file])
						const ids = (Array.isArray(drafts) ? drafts : []).map((draft) => draft?.id).filter((id) => typeof id === 'string')
						if (ids.length > 0) {
							if (inputActions.addAttachments(ids) === true) {
								focusComposer()
								return 'attached'
							}
							conversation.releaseDraftAttachments?.(drafts)
						}
					}
				}
			} catch (error) {
				console.warn('[screenshot] 附件通道失败，改用粘贴事件:', error)
			}

			// 2) 合成 paste 事件：输入框的粘贴口子是 Lexical 的 PASTE_COMMAND，只认 clipboardData
			try {
				const editor = editorElement()
				if (editor !== null) {
					editor.focus?.()
					const clipboard = new DataTransfer()
					clipboard.items.add(file)
					const event = new ClipboardEvent('paste', { clipboardData: clipboard, bubbles: true, cancelable: true })
					if (!editor.dispatchEvent(event)) {
						focusComposer()
						return 'pasted'
					}
				}
			} catch (error) {
				console.warn('[screenshot] 合成粘贴事件失败:', error)
			}

			// 3) 兜底：复制到剪贴板，让用户自己按 Ctrl+V
			try {
				await navigator.clipboard.write([new ClipboardItem({ [file.type]: file })])
				return 'clipboard'
			} catch (error) {
				console.warn('[screenshot] 写剪贴板失败:', error)
				return 'failed'
			}
		}

		// ---------------------------------------------------------------- run

		/** 文件名用当时的时间戳，精确到秒：screenshot-2026-10-26_22-31-05.png */
		function timestampName() {
			const now = new Date()
			const pad = (value) => String(value).padStart(2, '0')
			const stamp =
				`${now.getFullYear()}-${pad(now.getMonth() + 1)}-${pad(now.getDate())}` +
				`_${pad(now.getHours())}-${pad(now.getMinutes())}-${pad(now.getSeconds())}`
			return `screenshot-${stamp}.png`
		}

		/** 同一时间只允许一次截图（按钮和快捷键共用一个闸门，避免连按弹出多个冻结窗口）。 */
		let capturing = false

		async function runCapture(sessionId, inputActions, hide) {
			if (capturing) return
			capturing = true
			const mount = mountPoints.get(sessionId)
			const setBusy = mount?.setBusy
			if (typeof setBusy === 'function') setBusy(true)
			try {
				const fileName = timestampName()
				const result = await requestCapture(hide, fileName, sessionCwd(sessionId))
				if (result === null) return
				const file = new File([result.blob], fileName, { type: 'image/png' })
				const outcome = await insertImage(file, sessionId, inputActions ?? mount?.inputActions)
				const saved = result.savedPath === undefined ? '' : '（已存到会话文件夹）'
				// 成功插入时不打扰用户，不弹提示；只有需要用户动手或失败才提示
				if (outcome === 'clipboard') toast(`已复制到剪贴板，按 Ctrl+V 粘贴${saved}`)
				else if (outcome === 'failed') toast('没能插入输入框，截图也没有复制成功', 'error')
			} catch (error) {
				toast(error?.message ?? String(error), 'error')
			} finally {
				capturing = false
				if (typeof setBusy === 'function') setBusy(false)
			}
		}

		// ----------------------------------------------------------------- icons

		function ScissorsIcon() {
			return React.createElement(
				'svg',
				{
					width: 16,
					height: 16,
					viewBox: '0 0 24 24',
					fill: 'none',
					'aria-hidden': 'true',
					stroke: 'currentColor',
					strokeWidth: 1.6,
					strokeLinecap: 'round',
					strokeLinejoin: 'round',
				},
				React.createElement('circle', { cx: 6.5, cy: 18, r: 2.4 }),
				React.createElement('circle', { cx: 17.5, cy: 18, r: 2.4 }),
				React.createElement('path', { d: 'M8.3 16.2 16.8 4.2' }),
				React.createElement('path', { d: 'M15.7 16.2 7.2 4.2' }),
			)
		}

		// ------------------------------------------------------------- component

		function composerRootOf(slot) {
			let node = slot
			for (let depth = 0; node !== null && depth < 10; depth += 1) {
				const found = node.querySelector?.('[data-lexical-editor="true"], [contenteditable="true"]')
				if (found !== null && found !== undefined) return node
				node = node.parentElement
			}
			return slot
		}

		function ScreenshotButton(props) {
			const sessionId = props.screenshotSessionId
			const inputActions = props.inputActions
			const [busy, setBusy] = React.useState(false)
			const holder = React.useRef(null)

			React.useEffect(() => {
				const element = holder.current
				if (element === null || typeof sessionId !== 'string' || sessionId === '') return undefined
				const slot = element.closest?.('[data-slot="conversation.input.left"]') ?? element.parentElement
				mountPoints.set(sessionId, { root: composerRootOf(slot ?? element), slot, setBusy, inputActions })
				return () => {
					mountPoints.delete(sessionId)
				}
			}, [sessionId, inputActions])

			return React.createElement(
				'button',
				{
					ref: holder,
					type: 'button',
					className: 'dshs-btn',
					title: '截图（Shift+点击不隐藏 DSH 窗口 · Ctrl+Alt+1）',
					'aria-label': '截图',
					'data-busy': busy ? 'true' : 'false',
					disabled: busy,
					onClick: (event) => {
						activeSessionId = sessionId
						runCapture(sessionId, inputActions, !event.shiftKey)
					},
				},
				React.createElement(ScissorsIcon),
			)
		}

		// ------------------------------------------------------------- shortcuts

		/**
		 * 是不是「数字 1」。只看物理键位 event.code（Shift+1 的 event.key 是 "!"，
		 * 这里不做兼容，避免把别的键误判成快捷键）。
		 */
		function isOneKey(event) {
			const code = String(event.code ?? '')
			if (code === 'Digit1' || code === 'Numpad1') return true
			return String(event.key ?? '') === '1' && event.shiftKey !== true
		}

		/** Ctrl+Alt+1（按住 Shift 则不隐藏 DSH 窗口）。 */
		function shortcutIntent(event) {
			if (event.defaultPrevented || event.isComposing || event.repeat) return null
			if (!event.ctrlKey || !event.altKey || event.metaKey) return null
			if (!isOneKey(event)) return null
			return { hide: !event.shiftKey }
		}

		function installShortcut() {
			window.addEventListener(
				'keydown',
				(event) => {
					const intent = shortcutIntent(event)
					if (intent === null) return
					const sessionId = activeSessionId
					if (typeof sessionId !== 'string') {
						toast('先打开一个会话再截图', 'error')
						return
					}
					const mount = mountPoints.get(sessionId)
					if (mount === undefined) return
					event.preventDefault()
					event.stopPropagation()
					runCapture(sessionId, mount.inputActions, intent.hide)
				},
				true,
			)
		}

		// ----------------------------------------------------------------- apply

		const inject = ['slots']

		function apply(ctx) {
			pluginCtx = ctx
			installStyle()
			installShortcut()
			installActivityTracking()

			ctx.slots.inject('conversation.input.left', () => {
				try {
					return ctx.slots.register(
						{
							name: 'conversation.input.left',
							id: 'screenshot',
							order: 30,
							inject: (sessionId) => ({ screenshotSessionId: sessionId }),
						},
						ScreenshotButton,
					)
				} catch (error) {
					console.warn('[screenshot] 注册输入框按钮失败:', error)
					return () => {}
				}
			})
		}

		exports.name = 'dsh-print-screen'
		exports.inject = inject
		exports.apply = apply
		exports.__test = { shortcutIntent, timestampName }
		return module.exports
	},
})
