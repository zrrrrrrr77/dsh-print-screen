import assert from "node:assert/strict";
import { apply, name, inject } from "./index.js";
import { mkdtemp, readFile, rm, stat } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";

const routes = new Map();
const ledgerDir = await mkdtemp(join(tmpdir(), "dsh-shot-ledger-"));
const fakeSession = { id: "test-session" };

const ctx = {
	logger: () => ({ info: () => {}, warn: () => {} }),
	get(service) {
		if (service === "sessions") return { get: (id) => (id === "test-session" ? fakeSession : undefined) };
		if (service === "workingDirectory") return { get: (session) => (session === fakeSession ? ledgerDir : undefined) };
		return undefined;
	},
	webServer: {
		register(route) {
			routes.set(route.path, route);
		},
	},
};

assert.equal(name, "dsh-print-screen");
assert.deepEqual(inject, ["webServer"]);
apply(ctx);

const health = routes.get("/api/dsh-print-screen/health");
const capture = routes.get("/api/dsh-print-screen/capture");
const record = routes.get("/api/dsh-print-screen/record");
const events = routes.get("/api/dsh-print-screen/events");
assert.ok(health && capture && record, "routes registered");

// 回归测试：所有 .ps1 必须是 UTF-8 带 BOM。
// PowerShell 5.1 对没有 BOM 的脚本按系统 ANSI 代码页解码，冻结画面上的中文提示会变成乱码。
{
	const { readFileSync } = await import("node:fs");
	for (const file of ["helper.ps1", "test-hide.ps1", "test-helper.ps1", "test-drag.ps1"]) {
		const bytes = readFileSync(new URL(`./${file}`, import.meta.url));
		assert.ok(
			bytes[0] === 0xef && bytes[1] === 0xbb && bytes[2] === 0xbf,
			`${file} 缺少 UTF-8 BOM：PowerShell 5.1 会把中文按 GBK 解码`,
		);
	}
	console.log("ok — every .ps1 is UTF-8 with BOM");
}

// 全局热键的推送通道：SSE 长连接 + 跨站/方法拒绝
{
	assert.ok(events, "/events 路由要注册（全局热键靠它推送）");
	const stream = callHandler(events, { method: "GET" });
	stream.run();
	assert.equal(stream.state.status, 200, "GET /events 应该是 200");
	assert.match(String(stream.state.headers["Content-Type"]), /^text\/event-stream/, "应该是 SSE");
	assert.match(Buffer.concat(stream.state.chunks).toString("utf8"), /retry:/, "应先发一条 retry");

	const cross = callHandler(events, { method: "GET", headers: { origin: "http://evil.example" } });
	cross.run();
	assert.equal(cross.state.status, 403, "跨站 GET 要被拒");

	const wrongMethod = callHandler(events, { method: "POST" });
	wrongMethod.run();
	assert.equal(wrongMethod.state.status, 405, "/events 只收 GET");
	console.log("ok — hotkey SSE route (stream + cross-origin + method)");
}

/** 造一个假的 req/res，跑一次 handler。传路由对象或函数都行。 */
function callHandler(route, { body, method = "POST", headers = {} } = {}) {
	const handler = typeof route === "function" ? route : route.handler;
	const chunks = [];
	const state = { status: 0, headers: {}, chunks };
	const req = Object.assign(
		(async function* () {
			if (body !== undefined) yield Buffer.from(JSON.stringify(body));
		})(),
		{
			method,
			headers: { "content-type": "application/json", host: "127.0.0.1:7395", ...headers },
			on() {
				return this;
			},
		},
	);
	const res = {
		writableEnded: false,
		destroyed: false,
		writeHead(code, h) {
			state.status = code;
			state.headers = h ?? {};
		},
		write(chunk) {
			if (chunk) chunks.push(Buffer.from(chunk));
			return true;
		},
		on() {
			return this;
		},
		end(chunk) {
			this.writableEnded = true;
			if (chunk) chunks.push(chunk);
		},
	};
	return { req, res, state, run: () => handler(req, res) };
}

/** 沙箱里 spawn powershell 会被拒（EPERM），这时跳过依赖真实截图的断言。 */
function captureBlocked(state) {
	if (state.status !== 500) return false;
	const text = Buffer.concat(state.chunks).toString("utf8");
	return text.includes("EPERM") || text.includes("spawn");
}

async function readLedger() {
	try {
		return JSON.parse(await readFile(join(ledgerDir, "screenshots.json"), "utf8"));
	} catch {
		return [];
	}
}

// health
{
	const { state, run } = callHandler(health, { method: "GET", body: undefined });
	run();
	assert.equal(state.status, 200);
	assert.equal(JSON.parse(Buffer.concat(state.chunks).toString()).ok, true);
}

// capture：selfTest 跳过全屏拉框窗口，只截一块固定区域
let captureWorks = false;
{
	const { state, run } = callHandler(capture, { body: { hide: false, delayMs: 0, selfTest: true } });
	await run();
	if (captureBlocked(state)) {
		console.log("skip — capture needs to spawn powershell.exe, which this sandbox blocks");
	} else {
		assert.equal(state.status, 200, `capture status ${state.status}`);
		assert.equal(state.headers["Content-Type"], "image/png");
		const buffer = Buffer.concat(state.chunks);
		assert.equal(Number(state.headers["Content-Length"]), buffer.length);
		assert.equal(buffer.subarray(0, 8).toString("hex"), "89504e470d0a1a0a");
		assert.equal(buffer.readUInt32BE(16), 320, "unexpected width");
		assert.equal(buffer.readUInt32BE(20), 200, "unexpected height");
		assert.match(state.headers["X-Screenshot-Sha256"], /^[0-9a-f]{64}$/u, "sha256 header missing");
		captureWorks = true;
		console.log(`ok — self-test crop 320x200, ${buffer.length} bytes`);
	}
}

// capture 不再自己写账本：截完就该是空的
{
	assert.deepEqual(await readLedger(), [], "capture must not write the ledger any more");
	console.log("ok — capture no longer writes the ledger");
}

// 另存到会话目录：带 saveDir + fileName 时，除了返回图片还要落盘一份
if (captureWorks) {
	const dir = await mkdtemp(join(tmpdir(), "dsh-shot-save-"));
	const fileName = "screenshot-2026-10-26_22-45-00.png";
	const shot = async (extra) =>
		callHandler(capture, { body: { hide: false, delayMs: 0, selfTest: true, saveDir: dir, fileName, ...extra } });

	const first = await shot({});
	await first.run();
	assert.equal(first.state.status, 200);
	const savedPath = decodeURIComponent(first.state.headers["X-Screenshot-Saved"]);
	assert.equal(savedPath, join(dir, fileName));
	const savedBytes = await readFile(savedPath);
	assert.equal(savedBytes.subarray(0, 8).toString("hex"), "89504e470d0a1a0a");

	// 同一秒再来一张：不覆盖，自动加 -1
	const second = await shot({});
	await second.run();
	assert.equal(decodeURIComponent(second.state.headers["X-Screenshot-Saved"]), join(dir, fileName.replace(/\.png$/u, "-1.png")));

	// 目录不存在：静默跳过，不影响返回图片
	const missing = await shot({ saveDir: join(dir, "nope") });
	await missing.run();
	assert.equal(missing.state.status, 200);
	assert.equal(missing.state.headers["X-Screenshot-Saved"], undefined);

	// 怪名字：以点开头 / 带 .. 都拒绝，不落盘也不报错
	for (const bad of ["..png", ".hidden.png", "..\\evil.png"]) {
		const rejected = await shot({ fileName: bad });
		await rejected.run();
		assert.equal(rejected.state.status, 200);
		assert.equal(rejected.state.headers["X-Screenshot-Saved"], undefined, `should reject ${bad}`);
	}

	await rm(dir, { recursive: true, force: true });
	console.log("ok — screenshot also saved into the session folder");
} else {
	console.log("skip — session-folder copy tests need a working capture");
}

// 跨站请求要被拒
{
	const { state, run } = callHandler(capture, { body: {}, headers: { origin: "https://evil.example" } });
	await run();
	assert.equal(state.status, 403);
	console.log("ok — cross-origin rejected");
}

// record：没进消息就不记账
{
	const { state, run } = callHandler(record, {
		body: { sessionId: "test-session", sha256: "a".repeat(64), inserted: false },
	});
	await run();
	assert.equal(state.status, 200);
	assert.equal(JSON.parse(Buffer.concat(state.chunks).toString()).recorded, false);
	assert.deepEqual(await readLedger(), []);
	console.log("ok — record skips captures that never reached a message");
}

// record：进了消息才记账，且 object 只有文件真存在时才是路径
{
	const sha = "b".repeat(64);
	const { state, run } = callHandler(record, {
		body: { sessionId: "test-session", sha256: sha, fileName: "screenshot-2026-11-01_07-30-00.png", bytes: 1234, width: 800, height: 600, inserted: true },
	});
	await run();
	assert.equal(state.status, 200);
	const ledger = await readLedger();
	assert.equal(ledger.length, 1);
	assert.equal(ledger[0].sha256, sha);
	assert.equal(ledger[0].object, null, "object must be null when the attachment file is absent");
	assert.equal(ledger[0].objectPresent, false);
	assert.equal(ledger[0].width, 800);
	console.log("ok — record writes one truthful entry");
}

// record：并发十次不漏条目（读-改-写串行化）
{
	const before = (await readLedger()).length;
	const calls = [];
	for (let i = 0; i < 10; i += 1) {
		const { state, run } = callHandler(record, {
			body: { sessionId: "test-session", sha256: String(i).padStart(64, "c"), inserted: true },
		});
		calls.push(run().then(() => assert.equal(state.status, 200)));
	}
	await Promise.all(calls);
	const after = await readLedger();
	assert.equal(after.length, before + 10, `expected ${before + 10} entries, got ${after.length}`);
	console.log("ok — 10 concurrent records all landed");
}

// record：坏请求被拒
{
	for (const body of [{}, { sha256: "not-a-hash", inserted: true }, { sessionId: "test-session", sha256: "d".repeat(64) }]) {
		const { state, run } = callHandler(record, { body });
		await run();
		assert.ok(state.status === 400 || state.status === 200, "bad record must not 500");
	}
	console.log("ok — malformed record requests rejected cleanly");
}

await rm(ledgerDir, { recursive: true, force: true });
console.log("all tests passed");

// 常驻助手是子进程，会让 node 的事件循环一直活着；测试跑完直接退出
process.exit(0);
