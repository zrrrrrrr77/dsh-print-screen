/**
 * dsh-print-screen —— 宿主半边
 *
 * 给输入框的「截图」按钮弹一次微信式截图：
 *   POST /api/dsh-print-screen/capture   { hide?: boolean, delayMs?: number }
 *     → 裁剪后的 image/png；用户取消 → 204
 *   GET  /api/dsh-print-screen/health    → 自检（含常驻助手状态）
 *
 * 只有一套截图实现：常驻助手 helper.ps1 —— 只启动一次、常驻读 stdin，
 * 加载 WinForms / P-Invoke / 窗体 / GDI 缓冲都只做一次。之后每次截图只花
 * 「隐藏 DSH + 抓屏 + 显示冻结窗口」，失败就重启助手重试一次。
 *
 * DPI 处理、逐屏拼接都在 helper.ps1 里。
 */
import { spawn } from "node:child_process";
import { mkdtemp, readFile, rm, stat, writeFile } from "node:fs/promises";
import { homedir, tmpdir } from "node:os";
import { join, isAbsolute } from "node:path";
import { fileURLToPath } from "node:url";
import { createHash, randomUUID } from "node:crypto";
import { createInterface } from "node:readline";

export const name = "dsh-print-screen";
export const inject = ["webServer"];

const API_BASE = "/api/dsh-print-screen";
const HELPER_SCRIPT = fileURLToPath(new URL("./helper.ps1", import.meta.url));
const HELPER_READY_TIMEOUT_MS = 10_000;
const HELPER_REQUEST_TIMEOUT_MS = 300_000;

/**
 * 全局热键的推送通道：客户端用 EventSource 挂在 GET /events 上，
 * 助手按下 OS 级热键后（DSH 可能没有焦点，keydown 收不到）由宿主转发。
 */
const hotkeySubscribers = new Set();

function broadcastHotkey() {
	for (const res of [...hotkeySubscribers]) {
		try {
			res.write("event: hotkey\ndata: {}\n\n");
		} catch {
			hotkeySubscribers.delete(res);
		}
	}
}

function sendJson(res, status, payload) {
	if (res.writableEnded || res.destroyed) return;
	const body = Buffer.from(JSON.stringify(payload), "utf8");
	res.writeHead(status, {
		"Content-Type": "application/json; charset=utf-8",
		"Content-Length": String(body.length),
		"Cache-Control": "no-store",
	});
	res.end(body);
}

async function readJsonBody(req, limit = 8 * 1024) {
	if (!String(req.headers["content-type"] ?? "").includes("application/json")) return {};
	let text = "";
	for await (const chunk of req) {
		text += chunk;
		if (text.length > limit) throw new Error("请求体过大");
	}
	text = text.trim();
	if (text === "") return {};
	const parsed = JSON.parse(text);
	return parsed !== null && typeof parsed === "object" && !Array.isArray(parsed) ? parsed : {};
}

/** 只放行同源请求：带 Origin 时必须和 Host 对得上。 */
function isSameOrigin(req) {
	const origin = req.headers.origin;
	if (typeof origin !== "string" || origin === "") return true;
	try {
		return new URL(origin).host === req.headers.host;
	} catch {
		return false;
	}
}

/** 从 PNG 的 IHDR 里读宽高；不是 PNG 就返回 undefined。 */
function pngSize(buffer) {
	if (buffer.length < 24) return undefined;
	const signature = buffer.subarray(0, 8);
	if (signature.toString("hex") !== "89504e470d0a1a0a") return undefined;
	return { width: buffer.readUInt32BE(16), height: buffer.readUInt32BE(20) };
}

/**
 * 把截图另存一份到会话目录（客户端传当前会话的 cwd + 时间戳文件名）。
 * 目录不存在、不是目录、文件名不合法、写入失败都静默跳过——截图本身照常返回。
 * @returns {Promise<string | undefined>} 实际写出的绝对路径
 */
/** 允许的会话目录副本文件名：必须以字母数字/下划线开头，不允许出现 `..`。 */
const SAFE_PNG_NAME = /^[\w-][\w.\- ]{0,118}\.png$/iu;

async function saveToSession(buffer, dir, fileName) {
	if (typeof dir !== "string" || dir === "" || !isAbsolute(dir)) return undefined;
	if (typeof fileName !== "string" || !SAFE_PNG_NAME.test(fileName) || fileName.includes("..")) return undefined;
	try {
		const info = await stat(dir);
		if (!info.isDirectory()) return undefined;
	} catch {
		return undefined;
	}

	const base = fileName.replace(/\.png$/iu, "");
	let target = join(dir, `${base}.png`);
	for (let attempt = 1; attempt < 50; attempt += 1) {
		try {
			await writeFile(target, buffer, { flag: "wx" });
			return target;
		} catch (error) {
			if (error?.code !== "EEXIST") return undefined;
			target = join(dir, `${base}-${attempt}.png`);
		}
	}
	return undefined;
}

/**
 * 会话当前目录：和 dsh-session-folder 同一口径，读宿主 workingDirectory 的投影。
 * 会话 header.cwd 是不可变的工作区根，只有投影反映“当前真正在用的目录”。
 * 取不到返回 undefined，由前端传来的 saveDir 兜底。
 */
function workingDirectoryService(ctx) {
	try {
		const direct = ctx.get?.("workingDirectory");
		if (direct !== undefined && direct !== null) return direct;
	} catch {
		/* 服务没注册就退回属性访问 */
	}
	return ctx.workingDirectory;
}

function resolveSessionDir(ctx, sessionId) {
	if (typeof sessionId !== "string" || sessionId === "") return undefined;
	try {
		const sessions = ctx.get?.("sessions");
		const session = sessions?.get?.(sessionId);
		if (session === undefined || session === null) return undefined;
		const dir = workingDirectoryService(ctx)?.get?.(session);
		return typeof dir === "string" && dir !== "" ? dir : undefined;
	} catch {
		return undefined;
	}
}

/** 内容哈希：附件库按它命名，索引里记它就能反查文件。 */
function sha256Hex(buffer) {
	return createHash("sha256").update(buffer).digest("hex");
}

/** 会话标题（取不到就算了，索引里这一项为 null）。 */
function resolveSessionTitle(ctx, sessionId) {
	try {
		const session = ctx.get?.("sessions")?.get?.(sessionId);
		if (session === undefined || session === null) return undefined;
		const title = ctx.get?.("sessionTitle")?.get?.(session);
		return typeof title?.title === "string" ? title.title : undefined;
	} catch {
		return undefined;
	}
}

/**
 * 把一条截图记录追加到 <会话目录>\screenshots.json。
 * 图片本体只存在于附件库（内容寻址、无扩展名），这个文件只记“谁拍的、什么时候、哈希是什么”，
 * 用来回答“这张图是哪个对话的”。任何失败都静默忽略，不影响截图本身。
 */
/**
 * 账本写入串行化：读-改-写不是原子的，两次截图几乎同时落盘时后写的会覆盖先写的，
 * 丢一条记录。这里用一个进程内的 promise 队列把写入排成单行。
 */
let ledgerQueue = Promise.resolve();

function appendShotIndex(dir, entry) {
	if (typeof dir !== "string" || dir === "") return Promise.resolve();
	const next = ledgerQueue.then(
		() => writeLedgerEntry(dir, entry),
		() => writeLedgerEntry(dir, entry),
	);
	ledgerQueue = next.then(
		() => undefined,
		() => undefined,
	);
	return next;
}

async function writeLedgerEntry(dir, entry) {
	try {
		const file = join(dir, "screenshots.json");
		let list = [];
		try {
			const parsed = JSON.parse(await readFile(file, "utf8"));
			if (Array.isArray(parsed)) list = parsed;
		} catch {
			/* 首次或文件损坏：重建 */
		}
		list.push(entry);
		await writeFile(file, `${JSON.stringify(list, null, 2)}\n`, "utf8");
	} catch {
		/* 记账失败不影响截图 */
	}
}

// ------------------------------------------------------------ 常驻助手

/** @type {{ child: import("node:child_process").ChildProcess, pending: Map<string, {resolve: Function, reject: Function}>, ready: Promise<boolean>, dead: boolean } | null} */
let helper = null;
let helperSeq = 0;

function startHelper() {
	const child = spawn(
		"powershell.exe",
		["-NoProfile", "-NonInteractive", "-ExecutionPolicy", "Bypass", "-File", HELPER_SCRIPT],
		{ stdio: ["pipe", "pipe", "ignore"], windowsHide: true },
	);
	const pending = new Map();
	let readyResolve;
	const ready = new Promise((resolve) => {
		readyResolve = resolve;
	});
	const state = {
		child,
		pending,
		ready,
		dead: false,
		send(line) {
			child.stdin.write(`${line}\n`);
		},
	};

	const fail = (error) => {
		if (state.dead) return;
		state.dead = true;
		readyResolve(false);
		for (const [, entry] of pending) entry.reject(error);
		pending.clear();
		if (helper === state) helper = null;
	};

	const lines = createInterface({ input: child.stdout });
	lines.on("line", (line) => {
		const trimmed = line.trim();
		if (trimmed === "ready") {
			readyResolve(true);
			return;
		}
		// 助手主动上报：用户按了全局热键（不是某次请求的应答）。
		// 没有前端在听（DSH 窗口关了）就别往下走，否则会弹一个没人接收的冻结画面。
		if (trimmed.startsWith("hotkey")) {
			if (hotkeySubscribers.size > 0) broadcastHotkey();
			return;
		}
		const split = trimmed.indexOf("|");
		if (split <= 0) return;
		const id = trimmed.slice(0, split);
		const rest = trimmed.slice(split + 1).split("|");
		const entry = pending.get(id);
		if (entry === undefined) return;
		pending.delete(id);
		entry.resolve({
			status: rest[0],
			message: rest[1] === undefined ? undefined : Buffer.from(rest[1], "base64").toString("utf8"),
		});
	});

	child.stdio[1]?.on("error", () => {});
	child.on("error", fail);
	child.on("exit", () => fail(new Error("截图助手进程退出")));
	return state;
}

function ensureHelper() {
	if (helper !== null && helper.dead !== true) return helper;
	helper = startHelper();
	return helper;
}

function stopHelper() {
	if (helper === null) return;
	const current = helper;
	helper = null;
	try {
		current.child.stdin.end("exit\n");
	} catch {
		/* 管道可能已断 */
	}
	const timer = setTimeout(() => {
		try {
			current.child.kill();
		} catch {
			/* 已退出 */
		}
	}, 1500);
	timer.unref?.();
}

/** 通过常驻助手截一次图；返回 { status: 'ok' | 'cancel' | 'error', message? }。 */
async function helperCapture({ hide, delayMs, outPath, selfTest = false }) {
	const state = ensureHelper();
	const ready = await Promise.race([
		state.ready,
		new Promise((resolve) => {
			const timer = setTimeout(() => resolve(false), HELPER_READY_TIMEOUT_MS);
			timer.unref?.();
		}),
	]);
	if (ready !== true) throw new Error("截图助手启动超时");

	const id = String(++helperSeq);
	return new Promise((resolve, reject) => {
		const timer = setTimeout(() => {
			state.pending.delete(id);
			// 卡死就杀掉助手，下一次请求会重新拉起
			try {
				state.child.kill();
			} catch {
				/* 已退出 */
			}
			if (helper === state) helper = null;
			reject(new Error("截图超时"));
		}, HELPER_REQUEST_TIMEOUT_MS);
		timer.unref?.();
		state.pending.set(id, {
			resolve: (value) => {
				clearTimeout(timer);
				resolve(value);
			},
			reject: (error) => {
				clearTimeout(timer);
				reject(error);
			},
		});
		try {
			state.send(
				`${id}|${hide ? 1 : 0}|${delayMs}|${Buffer.from(outPath, "utf8").toString("base64")}||${selfTest ? 1 : 0}`,
			);
		} catch (error) {
			clearTimeout(timer);
			state.pending.delete(id);
			reject(error);
		}
	});
}

// ---------------------------------------------------------------- capture

/** 弹一次微信式截图（冻结屏幕 → 拖框）。取消时返回 { cancelled: true }。 */
async function capture({ hide = true, delayMs = 30, selfTest = false } = {}, logger) {
	if (process.platform !== "win32") throw new Error("截图目前只支持 Windows");
	const delay = Math.max(0, Math.min(2000, Number(delayMs) || 0));
	const dir = await mkdtemp(join(tmpdir(), "dsh-print-screen-"));
	const file = join(dir, `${randomUUID()}.png`);
	try {
		let lastError;
		for (let attempt = 0; attempt < 2; attempt += 1) {
			try {
				const result = await helperCapture({ hide, delayMs: delay, outPath: file, selfTest });
				if (result.status === "cancel") return { cancelled: true };
				if (result.status !== "ok") throw new Error(result.message ?? `截图助手返回 ${result.status}`);
				const buffer = await readFile(file);
				const size = pngSize(buffer);
				if (size === undefined) throw new Error("截图助手没有产出有效 PNG");
				return { buffer, ...size };
			} catch (error) {
				lastError = error;
				logger?.warn(`截图助手失败，重启后再试一次：${error?.message ?? error}`);
				// 只有一套截图实现：失败就重启助手重试，不再维护第二份脚本
				stopHelper();
			}
		}
		throw lastError ?? new Error("截图失败");
	} finally {
		await rm(dir, { recursive: true, force: true }).catch(() => {});
	}
}

export function apply(ctx) {
	const logger = ctx.logger(name);

	// 预热：启动后等 2.5 秒再拉助手，避开 DSH 自己的启动高峰；
	// 每次 DSH 启动只会拉这一次（约 1.5s），之后常驻待命。
	if (process.platform === "win32") {
		const timer = setTimeout(() => {
			try {
				ensureHelper()
					.ready.then((ok) => {
						if (ok) logger.info("截图助手已就绪");
						else logger.warn("截图助手启动失败，截图时会重启重试");
					})
					.catch(() => {});
			} catch (error) {
				logger.warn(`截图助手启动异常：${error?.message ?? error}`);
			}
		}, 2500);
		timer.unref?.();
	}

	ctx.effect?.(() => () => stopHelper(), "dsh-print-screen helper");

	ctx.effect?.(
		() => () => {
			for (const res of [...hotkeySubscribers]) {
				try {
					res.end();
				} catch {
					/* 连接已断 */
				}
			}
			hotkeySubscribers.clear();
		},
		"dsh-print-screen hotkey",
	);

	// 全局热键推送：客户端用 EventSource 长连接挂在这里。
	// DSH 窗口没有焦点时渲染层收不到 keydown，只能由常驻助手抢 OS 热键再推过来。
	ctx.webServer.register({
		kind: "exact",
		path: `${API_BASE}/events`,
		handler: (req, res) => {
			if (!isSameOrigin(req)) {
				sendJson(res, 403, { ok: false, code: "cross-origin", message: "已拒绝跨站请求" });
				return;
			}
			if (req.method !== "GET") {
				sendJson(res, 405, { ok: false, code: "method", message: "请用 GET" });
				return;
			}
			res.writeHead(200, {
				"Content-Type": "text/event-stream; charset=utf-8",
				"Cache-Control": "no-store",
				Connection: "keep-alive",
				"X-Accel-Buffering": "no",
			});
			res.write("retry: 2000\n\n");
			hotkeySubscribers.add(res);
			// 心跳：空闲长连接容易被中间层掐掉
			const keepAlive = setInterval(() => {
				try {
					res.write(": ping\n\n");
				} catch {
					hotkeySubscribers.delete(res);
				}
			}, 25_000);
			keepAlive.unref?.();
			const cleanup = () => {
				clearInterval(keepAlive);
				hotkeySubscribers.delete(res);
			};
			// 只在响应侧清理：req 的 "close" 在请求收完时就可能触发，
			// 用它清理会把长连接刚建立就摘掉，热键推送全部丢失。
			res.on("close", cleanup);
			res.on("error", cleanup);
		},
	});

	ctx.webServer.register({
		kind: "exact",
		path: `${API_BASE}/health`,
		handler: (_req, res) => {
			sendJson(res, 200, {
				ok: true,
				plugin: name,
				platform: process.platform,
				helper: HELPER_SCRIPT,
				helperAlive: helper !== null && helper.dead !== true,
				powershell: process.platform === "win32",
			});
		},
	});

	ctx.webServer.register({
		kind: "exact",
		path: `${API_BASE}/capture`,
		handler: async (req, res) => {
			if (!isSameOrigin(req)) {
				sendJson(res, 403, { ok: false, code: "cross-origin", message: "已拒绝跨站请求" });
				return;
			}
			if (req.method !== "POST") {
				sendJson(res, 405, { ok: false, code: "method", message: "请用 POST" });
				return;
			}

			let body = {};
			try {
				body = await readJsonBody(req);
			} catch (error) {
				sendJson(res, 400, { ok: false, code: "bad-request", message: error.message });
				return;
			}

			try {
				const shot = await capture(
					{
						hide: body.hide !== false,
						delayMs: body.delayMs,
						selfTest: body.selfTest === true,
					},
					logger,
				);
				if (res.writableEnded || res.destroyed) return;
				if (shot.cancelled) {
					res.writeHead(204, { "Cache-Control": "no-store" });
					res.end();
					return;
				}
				// 另存一份：只有客户端显式给了 saveDir 才会写（SAVE_TO_SESSION=true 时才给）
				const savedPath = await saveToSession(shot.buffer, body.saveDir, body.fileName);
				// 记账不在这里做：截图成功 ≠ 图片进了对话。客户端插入成功后才会回调 /record，
				// 否则插入失败/用户放弃时会留下一条指向不存在对象的假记录。
				const sha = sha256Hex(shot.buffer);
				const headers = {
					"Content-Type": "image/png",
					"Content-Length": String(shot.buffer.length),
					"Cache-Control": "no-store",
					"X-Screenshot-Width": String(shot.width),
					"X-Screenshot-Height": String(shot.height),
					"X-Screenshot-Sha256": sha,
				};
				if (savedPath !== undefined) {
					// 路径里可能有中文，HTTP 头只能是 latin-1，用百分号编码
					headers["X-Screenshot-Saved"] = encodeURIComponent(savedPath);
				}
				res.writeHead(200, headers);
				res.end(shot.buffer);
				logger.info(
					`captured ${shot.width}x${shot.height} (${shot.buffer.length} bytes)` +
						(savedPath === undefined ? "" : `, saved to ${savedPath}`),
				);
			} catch (error) {
				logger.warn(`capture failed: ${error?.message ?? error}`);
				sendJson(res, 500, { ok: false, code: "capture-failed", message: error?.message ?? String(error) });
			}
		},
	});

	// 记账回调：客户端确认图片真的进了消息之后才写 screenshots.json。
	// 这样账本里的每一条都对应一条能看见的附件，不会出现“记了但对象不存在”的假记录。
	ctx.webServer.register({
		kind: "exact",
		path: `${API_BASE}/record`,
		handler: async (req, res) => {
			if (!isSameOrigin(req)) {
				sendJson(res, 403, { ok: false, code: "cross-origin", message: "已拒绝跨站请求" });
				return;
			}
			if (req.method !== "POST") {
				sendJson(res, 405, { ok: false, code: "method", message: "请用 POST" });
				return;
			}
			let body = {};
			try {
				body = await readJsonBody(req);
			} catch (error) {
				sendJson(res, 400, { ok: false, code: "bad-request", message: error.message });
				return;
			}

			const sha =
				typeof body.sha256 === "string" && /^[0-9a-f]{64}$/u.test(body.sha256) ? body.sha256 : undefined;
			if (sha === undefined) {
				sendJson(res, 400, { ok: false, code: "bad-request", message: "sha256 缺失或格式非法" });
				return;
			}
			if (body.inserted !== true) {
				// 没进消息就不记：账本只描述“这个对话里有哪些图”
				sendJson(res, 200, { ok: true, recorded: false, reason: "not-inserted" });
				return;
			}

			const sessionDir = resolveSessionDir(ctx, body.sessionId);
			const objectPath = join(homedir(), ".dsh", "attachments", "v1", "objects", sha.slice(0, 2), sha);
			const present = await stat(objectPath).then(
				() => true,
				() => false,
			);
			const entry = {
				at: new Date().toISOString(),
				file:
					typeof body.fileName === "string" && SAFE_PNG_NAME.test(body.fileName) && !body.fileName.includes("..")
						? body.fileName
						: null,
				sha256: sha,
				bytes: Number.isFinite(body.bytes) ? body.bytes : null,
				width: Number.isFinite(body.width) ? body.width : null,
				height: Number.isFinite(body.height) ? body.height : null,
				sessionId: typeof body.sessionId === "string" ? body.sessionId : null,
				title: resolveSessionTitle(ctx, body.sessionId) ?? null,
				// 附件库对象路径由哈希推算，但只有文件真的存在时才算事实
				object: present ? objectPath : null,
				objectPresent: present,
				// attached = 走了官方附件通道（确定进了消息）；pasted = 合成的粘贴事件（大概率进了）
				via: body.via === "attached" || body.via === "pasted" ? body.via : null,
			};
			await appendShotIndex(sessionDir, entry);
			sendJson(res, 200, { ok: true, recorded: sessionDir !== undefined, objectPresent: present });
		},
	});

	logger.info(`ready — routes POST ${API_BASE}/capture, POST ${API_BASE}/record, GET ${API_BASE}/health`);
}
