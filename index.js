/**
 * dsh-screenshot —— 宿主半边
 *
 * 给输入框的「截图」按钮弹一次微信式截图：
 *   POST /api/dsh-screenshot/capture   { hide?: boolean, delayMs?: number }
 *     → 裁剪后的 image/png；用户取消 → 204
 *   GET  /api/dsh-screenshot/health    → 自检（含常驻助手状态）
 *
 * 只有一套截图实现：常驻助手 helper.ps1 —— 只启动一次、常驻读 stdin，
 * 加载 WinForms / P-Invoke / 窗体 / GDI 缓冲都只做一次。之后每次截图只花
 * 「隐藏 DSH + 抓屏 + 显示冻结窗口」，失败就重启助手重试一次。
 *
 * DPI 处理、逐屏拼接都在 helper.ps1 里。
 */
import { spawn } from "node:child_process";
import { mkdtemp, readFile, rm, stat, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join, isAbsolute } from "node:path";
import { fileURLToPath } from "node:url";
import { randomUUID } from "node:crypto";
import { createInterface } from "node:readline";

export const name = "dsh-screenshot";
export const inject = ["webServer"];

const API_BASE = "/api/dsh-screenshot";
const HELPER_SCRIPT = fileURLToPath(new URL("./helper.ps1", import.meta.url));
const HELPER_READY_TIMEOUT_MS = 10_000;
const HELPER_REQUEST_TIMEOUT_MS = 300_000;

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
async function saveToSession(buffer, dir, fileName) {
	if (typeof dir !== "string" || dir === "" || !isAbsolute(dir)) return undefined;
	if (typeof fileName !== "string" || !/^[\w.\- ]{1,120}\.png$/iu.test(fileName)) return undefined;
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
	const dir = await mkdtemp(join(tmpdir(), "dsh-screenshot-"));
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

	ctx.effect?.(() => () => stopHelper(), "dsh-screenshot helper");

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
				// 另存一份到当前会话目录（客户端传 cwd + 时间戳文件名）；失败不影响插入
				const savedPath = await saveToSession(shot.buffer, body.saveDir, body.fileName);
				const headers = {
					"Content-Type": "image/png",
					"Content-Length": String(shot.buffer.length),
					"Cache-Control": "no-store",
					"X-Screenshot-Width": String(shot.width),
					"X-Screenshot-Height": String(shot.height),
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

	logger.info(`ready — routes POST ${API_BASE}/capture, GET ${API_BASE}/health`);
}
