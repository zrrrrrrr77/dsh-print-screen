import assert from "node:assert/strict";
import { apply, name, inject } from "./index.js";
import { mkdtemp, readFile, rm, stat } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";

const routes = new Map();
const ctx = {
	logger: () => ({ info: () => {}, warn: () => {} }),
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
assert.ok(health && capture, "routes registered");

// health
{
	let status = 0;
	let body = "";
	const res = {
		writableEnded: false,
		destroyed: false,
		writeHead(code) { status = code; },
		end(chunk) { this.writableEnded = true; body += chunk?.toString?.() ?? ""; },
	};
	health.handler({ headers: {} }, res);
	assert.equal(status, 200);
	assert.equal(JSON.parse(body).ok, true);
}

// capture：selfTest 跳过全屏拉框窗口，只截一块固定区域，方便无头自测
{
	const req = Object.assign(
		(async function* () {
			yield Buffer.from(JSON.stringify({ hide: false, delayMs: 0, selfTest: true }));
		})(),
		{ method: "POST", headers: { "content-type": "application/json", host: "127.0.0.1:7395" } },
	);
	let status = 0;
	let headers = {};
	const chunks = [];
	const res = {
		writableEnded: false,
		destroyed: false,
		writeHead(code, h) { status = code; headers = h ?? {}; },
		end(chunk) { this.writableEnded = true; if (chunk) chunks.push(chunk); },
	};
	await capture.handler(req, res);
	assert.equal(status, 200, `capture status ${status}`);
	assert.equal(headers["Content-Type"], "image/png");
	const buffer = Buffer.concat(chunks);
	assert.equal(Number(headers["Content-Length"]), buffer.length);
	assert.equal(buffer.subarray(0, 8).toString("hex"), "89504e470d0a1a0a");
	const width = buffer.readUInt32BE(16);
	const height = buffer.readUInt32BE(20);
	assert.equal(width, 320, `unexpected width ${width}`);
	assert.equal(height, 200, `unexpected height ${height}`);
	console.log(`ok — self-test crop ${width}x${height}, ${buffer.length} bytes`);
}

// 另存到会话目录：带 saveDir + fileName 时，除了返回图片还要落盘一份
{
	const dir = await mkdtemp(join(tmpdir(), "dsh-shot-save-"));
	const fileName = "screenshot-2026-10-26_22-45-00.png";
	const call = async (body) => {
		const req = Object.assign(
			(async function* () {
				yield Buffer.from(JSON.stringify({ hide: false, delayMs: 0, selfTest: true, ...body }));
			})(),
			{ method: "POST", headers: { "content-type": "application/json", host: "127.0.0.1:7395" } },
		);
		const state = { status: 0, headers: {}, chunks: [] };
		state.res = {
			writableEnded: false,
			destroyed: false,
			writeHead(code, h) { state.status = code; state.headers = h ?? {}; },
			end(chunk) { this.writableEnded = true; if (chunk) state.chunks.push(chunk); },
		};
		await capture.handler(req, state.res);
		return state;
	};

	const first = await call({ saveDir: dir, fileName });
	assert.equal(first.status, 200);
	assert.ok(first.headers["X-Screenshot-Saved"], "saved header present");
	const savedPath = decodeURIComponent(first.headers["X-Screenshot-Saved"]);
	assert.equal(savedPath, join(dir, fileName));
	const savedBytes = await readFile(savedPath);
	assert.equal(savedBytes.subarray(0, 8).toString("hex"), "89504e470d0a1a0a");
	assert.equal((await stat(savedPath)).size, savedBytes.length);

	// 同一秒再来一张：不覆盖，自动加 -1
	const second = await call({ saveDir: dir, fileName });
	const secondPath = decodeURIComponent(second.headers["X-Screenshot-Saved"]);
	assert.equal(secondPath, join(dir, fileName.replace(/\.png$/u, "-1.png")));

	// 目录不存在：静默跳过，不影响返回图片
	const missing = await call({ saveDir: join(dir, "nope"), fileName });
	assert.equal(missing.status, 200);
	assert.equal(missing.headers["X-Screenshot-Saved"], undefined);

	await rm(dir, { recursive: true, force: true });
	console.log("ok — screenshot also saved into the session folder");
}

// 跨站请求要被拒
{
	const req = Object.assign(
		(async function* () {
			yield Buffer.from("{}");
		})(),
		{ method: "POST", headers: { "content-type": "application/json", host: "127.0.0.1:7395", origin: "https://evil.example" } },
	);
	let status = 0;
	const res = {
		writableEnded: false,
		destroyed: false,
		writeHead(code) { status = code; },
		end() { this.writableEnded = true; },
	};
	await capture.handler(req, res);
	assert.equal(status, 403);
	console.log("ok — cross-origin rejected");
}

// 常驻助手是子进程，会让 node 的事件循环一直活着；测试跑完直接退出
process.exit(0);
