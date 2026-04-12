import { Plugin, MarkdownView, PluginSettingTab, App, Setting } from "obsidian";
import { StateField, StateEffect, Transaction, Range } from "@codemirror/state";
import { Decoration, DecorationSet, EditorView, ViewPlugin, ViewUpdate, WidgetType } from "@codemirror/view";
import * as http from "http";

// -- CodeMirror 6 decoration effects --

const setHighlightEffect = StateEffect.define<{ from: number; to: number }>();
const clearHighlightEffect = StateEffect.define<null>();

// Store the current highlight range (1-based line numbers) for the DOM highlighter
let currentHighlightFrom = 0;
let currentHighlightTo = 0;

const highlightField = StateField.define<DecorationSet>({
	create() {
		return Decoration.none;
	},
	update(decorations: DecorationSet, tr: Transaction) {
		decorations = decorations.map(tr.changes);
		for (const effect of tr.effects) {
			if (effect.is(clearHighlightEffect)) {
				decorations = Decoration.none;
				currentHighlightFrom = 0;
				currentHighlightTo = 0;
			}
			if (effect.is(setHighlightEffect)) {
				const { from, to } = effect.value;
				currentHighlightFrom = from;
				currentHighlightTo = to;
				const doc = tr.state.doc;
				const builder: Range<Decoration>[] = [];
				for (let line = from; line <= to && line <= doc.lines; line++) {
					// Skip lines that look like table rows (contain |) — these get
					// highlighted via the widget highlighter on the rendered table instead,
					// avoiding a double-highlight in live preview
					const lineText = doc.line(line).text;
					if (lineText.includes("|")) continue;

					const lineStart = doc.line(line).from;
					builder.push(
						Decoration.line({ class: "murmur-highlight-line" }).range(lineStart)
					);
				}
				decorations = Decoration.set(builder, true);
			}
		}
		return decorations;
	},
	provide: (field) => EditorView.decorations.from(field),
});

// ViewPlugin that highlights rendered widgets (tables, callouts, etc.) in live preview
// Line decorations don't show on rendered widgets, so we add CSS classes to the DOM directly
const widgetHighlighter = ViewPlugin.fromClass(
	class {
		private highlightedElements: HTMLElement[] = [];

		constructor(private view: EditorView) {
			this.updateWidgetHighlights();
		}

		update(update: ViewUpdate) {
			// Check if highlight effects were dispatched
			for (const tr of update.transactions) {
				for (const effect of tr.effects) {
					if (effect.is(setHighlightEffect) || effect.is(clearHighlightEffect)) {
						// Small delay to let Obsidian render widgets first
						setTimeout(() => this.updateWidgetHighlights(), 50);
						return;
					}
				}
			}
		}

		updateWidgetHighlights() {
			// Remove previous highlights
			for (const el of this.highlightedElements) {
				el.classList.remove("murmur-highlight-widget");
			}
			this.highlightedElements = [];

			if (currentHighlightFrom === 0 || currentHighlightTo === 0) return;

			const doc = this.view.state.doc;
			if (currentHighlightFrom > doc.lines) return;

			// Get the character range of the highlighted lines
			const fromPos = doc.line(Math.min(currentHighlightFrom, doc.lines)).from;
			const toPos = doc.line(Math.min(currentHighlightTo, doc.lines)).to;

			// Find the outermost embed/widget containers only (not inner elements like <table>)
			// This avoids double-highlighting when a container wraps a table element
			const editorDom = this.view.dom;
			const containers = editorDom.querySelectorAll(".cm-embed-block");

			for (const container of Array.from(containers)) {
				const el = container as HTMLElement;
				try {
					const pos = this.view.posAtDOM(el);
					if (pos >= fromPos && pos <= toPos) {
						el.classList.add("murmur-highlight-widget");
						this.highlightedElements.push(el);
					}
				} catch {
					// posAtDOM can throw if element is outside editor content
				}
			}
		}

		destroy() {
			for (const el of this.highlightedElements) {
				el.classList.remove("murmur-highlight-widget");
			}
		}
	}
);

// -- Settings --

interface MurmurBridgeSettings {
	port: number;
}

const DEFAULT_SETTINGS: MurmurBridgeSettings = {
	port: 27125,
};

// -- Plugin --

export default class MurmurBridgePlugin extends Plugin {
	settings: MurmurBridgeSettings = DEFAULT_SETTINGS;
	private server: http.Server | null = null;
	serverRunning = false;

	async onload() {
		await this.loadSettings();

		// Register the CodeMirror extensions for line highlighting + widget highlighting
		this.registerEditorExtension([highlightField, widgetHighlighter]);

		// Add settings tab
		this.addSettingTab(new MurmurBridgeSettingTab(this.app, this));

		// Start the HTTP server
		this.startServer();
		console.log(`[Murmur Bridge] Plugin loaded, HTTP server on port ${this.settings.port}`);
	}

	onunload() {
		if (this.server) {
			this.server.close();
			this.server = null;
			this.serverRunning = false;
		}
		console.log("[Murmur Bridge] Plugin unloaded");
	}

	async loadSettings() {
		this.settings = Object.assign({}, DEFAULT_SETTINGS, await this.loadData());
	}

	async saveSettings() {
		await this.saveData(this.settings);
	}

	restartServer() {
		if (this.server) {
			this.server.close();
			this.server = null;
			this.serverRunning = false;
		}
		this.startServer();
	}

	private startServer() {
		const port = this.settings.port;
		this.server = http.createServer((req, res) => {
			res.setHeader("Access-Control-Allow-Origin", "*");
			res.setHeader("Content-Type", "application/json");

			if (req.method === "OPTIONS") {
				res.setHeader("Access-Control-Allow-Methods", "GET, POST, OPTIONS");
				res.setHeader("Access-Control-Allow-Headers", "Content-Type");
				res.writeHead(200);
				res.end();
				return;
			}

			const url = req.url || "/";

			if (req.method === "GET" && url === "/cursor") {
				this.handleGetCursor(res);
			} else if (req.method === "POST" && url === "/highlight") {
				this.readBody(req, (body) => this.handleHighlight(body, res));
			} else if (req.method === "POST" && url === "/clear-highlight") {
				this.handleClearHighlight(res);
			} else if (req.method === "POST" && url === "/navigate") {
				this.readBody(req, (body) => this.handleNavigate(body, res));
			} else {
				res.writeHead(404);
				res.end(JSON.stringify({ error: "Not found" }));
			}
		});

		this.server.listen(port, "127.0.0.1", () => {
			this.serverRunning = true;
			console.log(`[Murmur Bridge] HTTP server listening on 127.0.0.1:${port}`);
		});

		this.server.on("error", (err: any) => {
			this.serverRunning = false;
			console.error(`[Murmur Bridge] Server error: ${err.message}`);
			if (err.code === "EADDRINUSE") {
				console.error(`[Murmur Bridge] Port ${port} already in use`);
			}
		});
	}

	private readBody(req: http.IncomingMessage, callback: (body: any) => void) {
		let data = "";
		req.on("data", (chunk: string) => (data += chunk));
		req.on("end", () => {
			try {
				callback(JSON.parse(data));
			} catch {
				callback({});
			}
		});
	}

	// -- Handlers --

	private handleGetCursor(res: http.ServerResponse) {
		const view = this.app.workspace.getActiveViewOfType(MarkdownView);
		if (!view || !view.editor) {
			res.writeHead(404);
			res.end(JSON.stringify({ error: "No active editor" }));
			return;
		}

		const cursor = view.editor.getCursor();
		const file = view.file;
		const vaultPath = (this.app.vault.adapter as any).getBasePath?.() || "";
		const absolutePath = file ? `${vaultPath}/${file.path}` : "";

		res.writeHead(200);
		res.end(
			JSON.stringify({
				line: cursor.line + 1,
				ch: cursor.ch + 1,
				file: absolutePath,
			})
		);
	}

	private handleHighlight(body: any, res: http.ServerResponse) {
		const startLine = body.startLine as number;
		const endLine = body.endLine as number;

		if (!startLine || !endLine) {
			res.writeHead(400);
			res.end(JSON.stringify({ error: "Missing startLine or endLine" }));
			return;
		}

		const view = this.app.workspace.getActiveViewOfType(MarkdownView);
		if (!view) {
			res.writeHead(404);
			res.end(JSON.stringify({ error: "No active editor" }));
			return;
		}

		const cmEditor = (view.editor as any).cm as EditorView;
		if (!cmEditor) {
			res.writeHead(500);
			res.end(JSON.stringify({ error: "Cannot access CodeMirror editor" }));
			return;
		}

		// Combine highlight + scroll into a single dispatch
		try {
			const lineInfo = cmEditor.state.doc.line(startLine);
			console.log(`[Murmur Bridge] Highlighting lines ${startLine}-${endLine - 1}, scrolling to line ${startLine} (pos ${lineInfo.from})`);
			cmEditor.dispatch({
				effects: [
					setHighlightEffect.of({ from: startLine, to: endLine - 1 }),
					EditorView.scrollIntoView(lineInfo.from, { y: "center" }),
				],
			});
		} catch (e) {
			console.log(`[Murmur Bridge] Scroll failed, highlight only: ${e}`);
			cmEditor.dispatch({
				effects: setHighlightEffect.of({ from: startLine, to: endLine - 1 }),
			});
		}

		res.writeHead(200);
		res.end(JSON.stringify({ ok: true }));
	}

	private handleClearHighlight(res: http.ServerResponse) {
		const view = this.app.workspace.getActiveViewOfType(MarkdownView);
		if (view) {
			const cmEditor = (view.editor as any).cm as EditorView;
			if (cmEditor) {
				cmEditor.dispatch({
					effects: clearHighlightEffect.of(null),
				});
			}
		}
		res.writeHead(200);
		res.end(JSON.stringify({ ok: true }));
	}

	private handleNavigate(body: any, res: http.ServerResponse) {
		const line = body.line as number;
		if (!line) {
			res.writeHead(400);
			res.end(JSON.stringify({ error: "Missing line" }));
			return;
		}

		const view = this.app.workspace.getActiveViewOfType(MarkdownView);
		if (!view || !view.editor) {
			res.writeHead(404);
			res.end(JSON.stringify({ error: "No active editor" }));
			return;
		}

		view.editor.setCursor({ line: line - 1, ch: 0 });

		const cmEditor = (view.editor as any).cm as EditorView;
		if (cmEditor) {
			try {
				const lineInfo = cmEditor.state.doc.line(line);
				console.log(`[Murmur Bridge] Navigate to line ${line} (pos ${lineInfo.from})`);
				cmEditor.dispatch({
					effects: EditorView.scrollIntoView(lineInfo.from, { y: "center" }),
				});
			} catch (e) {
				console.log(`[Murmur Bridge] Navigate scroll failed: ${e}`);
			}
		}

		res.writeHead(200);
		res.end(JSON.stringify({ ok: true }));
	}
}

// -- Settings Tab --

class MurmurBridgeSettingTab extends PluginSettingTab {
	plugin: MurmurBridgePlugin;

	constructor(app: App, plugin: MurmurBridgePlugin) {
		super(app, plugin);
		this.plugin = plugin;
	}

	display(): void {
		const { containerEl } = this;
		containerEl.empty();

		containerEl.createEl("h2", { text: "Murmur Bridge" });

		// Status indicator
		const statusEl = containerEl.createDiv({ cls: "setting-item" });
		const statusInfo = statusEl.createDiv({ cls: "setting-item-info" });
		statusInfo.createDiv({ cls: "setting-item-name", text: "Server Status" });
		const statusDesc = statusInfo.createDiv({ cls: "setting-item-description" });
		const dot = statusDesc.createSpan();
		dot.style.display = "inline-block";
		dot.style.width = "8px";
		dot.style.height = "8px";
		dot.style.borderRadius = "50%";
		dot.style.marginRight = "6px";
		dot.style.backgroundColor = this.plugin.serverRunning ? "#4ade80" : "#f87171";
		statusDesc.createSpan({
			text: this.plugin.serverRunning
				? `Running on 127.0.0.1:${this.plugin.settings.port}`
				: "Not running",
		});

		// Port setting
		new Setting(containerEl)
			.setName("Port")
			.setDesc("HTTP server port for Murmur communication. Restart required after change.")
			.addText((text) =>
				text
					.setPlaceholder("27125")
					.setValue(String(this.plugin.settings.port))
					.onChange(async (value) => {
						const port = parseInt(value);
						if (!isNaN(port) && port > 0 && port < 65536) {
							this.plugin.settings.port = port;
							await this.plugin.saveSettings();
						}
					})
			);

		// Restart button
		new Setting(containerEl)
			.setName("Restart Server")
			.setDesc("Restart the HTTP server with the current port setting.")
			.addButton((button) =>
				button.setButtonText("Restart").onClick(() => {
					this.plugin.restartServer();
					// Refresh the display after a moment
					setTimeout(() => this.display(), 500);
				})
			);

		// Info section
		containerEl.createEl("h3", { text: "Endpoints" });
		const infoEl = containerEl.createEl("div", { cls: "setting-item-description" });
		infoEl.style.fontSize = "12px";
		infoEl.innerHTML = `
			<p>The Murmur Bridge plugin exposes these local HTTP endpoints for the Murmur macOS app:</p>
			<ul>
				<li><code>GET /cursor</code> — Current cursor position and file path</li>
				<li><code>POST /highlight</code> — Highlight a range of lines</li>
				<li><code>POST /clear-highlight</code> — Clear all highlights</li>
				<li><code>POST /navigate</code> — Navigate to a specific line</li>
			</ul>
			<p>Use <strong>Cmd+Opt+D</strong> in the Murmur app to start draft editing with the active note.</p>
		`;
	}
}
