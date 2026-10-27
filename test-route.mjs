import assert from "node:assert/strict";
import { spawn } from "node:child_process";
import { fileURLToPath } from "node:url";
import { apply } from "./index.js";

// 集成测试：走真实的 capture 路由 + 常驻助手，由 test-drag.ps1 模拟拖框。
const DIR = fileURLToPath(new URL(".", import.meta.url));
const routes = new Map();
const logs = [];
apply({
	logger: () => ({
		info: (message) => logs.push(`info: ${message}`),
		warn: (message) => logs.push(`warn: ${message}`),
	}),
	webServer: { register: (route) => routes.set(route.path, route) },
});

const route = routes.get("/api/dsh-print-screen/capture");
assert.ok(route, "capture route registered");

function fakeRequest(body) {
	return Object.assign(
		(async function* () {
			yield Buffer.from(JSON.stringify(body));
		})(),
		{ method: "POST", headers: { "content-type": "application/json", host: "127.0.0.1:1234" } },
	);
}

function fakeResponse() {
	const state = { status: 0, headers: {}, chunks: [] };
	state.done = new Promise((resolve) => {
		state.finish = resolve;
	});
	state.res = {
		writableEnded: false,
		destroyed: false,
		writeHead(code, headers) {
			state.status = code;
			state.headers = headers ?? {};
		},
		end(chunk) {
			state.writableEnded = true;
			if (chunk) state.chunks.push(chunk);
			state.finish();
		},
	};
	return state;
}

function runProbe() {
	return new Promise((resolve, reject) => {
		const child = spawn(
			"powershell.exe",
			["-NoProfile", "-ExecutionPolicy", "Bypass", "-File", `${DIR}test-drag.ps1`, String(process.pid)],
			{ stdio: ["ignore", "pipe", "pipe"] },
		);
		let out = "";
		let err = "";
		child.stdout.on("data", (chunk) => {
			out += chunk;
		});
		child.stderr.on("data", (chunk) => {
			err += chunk;
		});
		child.on("exit", (code) => (code === 0 ? resolve(out.trim()) : reject(new Error(`probe exit ${code}: ${err.trim()}`))));
	});
}

const sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms));

async function probeUntilWindow(timeoutMs) {
	let lastError;
	const deadline = Date.now() + timeoutMs;
	while (Date.now() < deadline) {
		try {
			return await runProbe();
		} catch (error) {
			lastError = error;
			await sleep(300);
		}
	}
	throw lastError ?? new Error("probe timed out");
}

// 第一次请求：等助手就绪后去拖框
const first = fakeResponse();
const firstStart = Date.now();
const pending = route.handler(fakeRequest({ hide: false, delayMs: 0 }), first.res);
await sleep(1600);
const probeOut = await probeUntilWindow(6000);
await pending;
await first.done;
const firstMs = Date.now() - firstStart;

assert.equal(first.status, 200, `status ${first.status}`);
const buffer = Buffer.concat(first.chunks);
assert.equal(buffer.subarray(0, 8).toString("hex"), "89504e470d0a1a0a");
const width = buffer.readUInt32BE(16);
const height = buffer.readUInt32BE(20);
assert.ok(width > 100 && height > 100, `crop too small: ${width}x${height}`);

// 第二次请求：助手已经热了，直接拖框
const second = fakeResponse();
const secondStart = Date.now();
const pendingSecond = route.handler(fakeRequest({ hide: false, delayMs: 0 }), second.res);
await sleep(500);
await probeUntilWindow(4000);
await pendingSecond;
await second.done;
const secondMs = Date.now() - secondStart;
assert.equal(second.status, 200);

console.log(`ok — helper capture ${width}x${height}; first ${firstMs}ms, warm ${secondMs}ms (${probeOut})`);
// 常驻助手是子进程，会让 node 的事件循环一直活着；测试跑完直接退出
process.exit(0);
