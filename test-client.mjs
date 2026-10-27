import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import vm from "node:vm";

const source = await readFile(new URL("./client.js", import.meta.url), "utf8");

function makeElement(tag) {
	return {
		tagName: String(tag).toUpperCase(),
		style: {},
		dataset: {},
		children: [],
		id: "",
		className: "",
		textContent: "",
		appendChild(child) { this.children.push(child); return child; },
		append(...nodes) { this.children.push(...nodes); },
		remove() {},
		addEventListener() {},
		removeEventListener() {},
		setAttribute() {},
		closest: () => null,
		querySelector: () => null,
		getBoundingClientRect: () => ({ left: 0, top: 0, width: 100, height: 100 }),
		focus() {},
	};
}

const document = {
	getElementById: () => null,
	querySelector: () => null,
	createElement: (tag) => makeElement(tag),
	addEventListener() {},
	removeEventListener() {},
	head: { appendChild() {} },
	body: { appendChild() {} },
};

const React = {
	useState: (initial) => [initial, () => {}],
	useEffect: () => {},
	useRef: () => ({ current: null }),
	createElement: (type, props, ...children) => ({ type, props, children }),
};

let definition;
const windowStub = {
	__ModuleLoader__: { load: (def) => { definition = def; } },
	addEventListener() {},
	removeEventListener() {},
};

const context = {
	window: windowStub,
	document,
	console,
	setTimeout,
	clearTimeout,
	fetch: async () => ({ ok: true, status: 200, blob: async () => ({ size: 1 }) }),
	navigator: { clipboard: { write: async () => {} } },
	DataTransfer: class { items = { add() {} }; },
	ClipboardEvent: class { constructor(type, init) { this.type = type; Object.assign(this, init); } },
	File: class { constructor(parts, name, options) { this.name = name; this.type = options?.type; } },
	ClipboardItem: class { constructor(items) { this.items = items; } },
	Element: class {},
};

vm.createContext(context);
vm.runInContext(source, context, { filename: "client.js" });

assert.ok(definition, "module loader received a definition");
assert.equal(definition.id, "dsh-print-screen");

const exports = definition.factory((name) => {
	if (name === "react") return React;
	throw new Error(`unexpected require: ${name}`);
});

assert.equal(exports.name, "dsh-print-screen");
assert.equal(JSON.stringify(exports.inject), JSON.stringify(["slots"]));
assert.equal(typeof exports.apply, "function");

// 快捷键：Ctrl+Alt+1 隐藏窗口，多按每个 Shift 就不隐藏
const { shortcutIntent } = exports.__test;
const base = { key: "1", code: "Digit1", ctrlKey: true, altKey: true, shiftKey: false, metaKey: false };
assert.deepEqual({ ...shortcutIntent(base) }, { hide: true });
assert.deepEqual({ ...shortcutIntent({ ...base, shiftKey: true }) }, { hide: false });
assert.equal(shortcutIntent({ ...base, ctrlKey: false }), null);
assert.equal(shortcutIntent({ ...base, altKey: false }), null);
assert.equal(shortcutIntent({ ...base, key: "2", code: "Digit2" }), null);
assert.equal(shortcutIntent({ ...base, metaKey: true }), null);
assert.equal(shortcutIntent({ ...base, defaultPrevented: true }), null);
// 只认物理键位；Shift+1 的 key 是 "!"，不再兼容
assert.deepEqual({ ...shortcutIntent({ ...base, code: "Digit1" }) }, { hide: true });
assert.deepEqual({ ...shortcutIntent({ ...base, key: "!", shiftKey: true, code: "Digit1" }) }, { hide: false });
assert.equal(shortcutIntent({ ...base, key: "!", shiftKey: true, code: undefined }), null);
assert.equal(shortcutIntent({ ...base, key: "!", shiftKey: true, ctrlKey: false }), null);

// 文件名是精确到秒的时间戳
const { timestampName } = exports.__test;
assert.match(timestampName(), /^screenshot-\d{4}-\d{2}-\d{2}_\d{2}-\d{2}-\d{2}\.png$/);

// apply() 注册插槽
const registrations = [];
const ctx = {
	slots: {
		inject(name, factory) {
			assert.equal(name, "conversation.input.left");
			factory();
		},
		register(options, component) {
			registrations.push({ options, component });
			return () => {};
		},
	},
};

exports.apply(ctx);
assert.equal(registrations.length, 1);
assert.equal(registrations[0].options.name, "conversation.input.left");
assert.equal(registrations[0].options.id, "screenshot");
assert.equal(typeof registrations[0].component, "function");

// 组件就是一个透明的剪刀按钮（没有背景、没有下拉箭头）
const { component } = registrations[0];
const props = { ...registrations[0].options.inject("session-1"), inputActions: { addAttachments: () => true } };
const tree = component(props);
assert.equal(tree.type, "button");
assert.equal(tree.props.type, "button");
assert.equal(tree.props.className, "dshs-btn");
assert.equal(tree.props["aria-label"], "截图");
assert.ok(!("aria-haspopup" in tree.props), "no dropdown any more");
const icon = tree.children[0];
assert.equal(typeof icon.type, "function", "scissors icon component");
assert.equal(icon.type({}).type, "svg", "scissors icon renders an svg");
assert.equal(icon.type({}).children.length, 4, "two circles + two blades");

console.log("ok — single scissors button, Shift and Ctrl+Alt+1 shortcuts");
