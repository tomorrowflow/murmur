var __create = Object.create;
var __defProp = Object.defineProperty;
var __getOwnPropDesc = Object.getOwnPropertyDescriptor;
var __getOwnPropNames = Object.getOwnPropertyNames;
var __getProtoOf = Object.getPrototypeOf;
var __hasOwnProp = Object.prototype.hasOwnProperty;
var __export = (target, all) => {
  for (var name in all)
    __defProp(target, name, { get: all[name], enumerable: true });
};
var __copyProps = (to, from, except, desc) => {
  if (from && typeof from === "object" || typeof from === "function") {
    for (let key of __getOwnPropNames(from))
      if (!__hasOwnProp.call(to, key) && key !== except)
        __defProp(to, key, { get: () => from[key], enumerable: !(desc = __getOwnPropDesc(from, key)) || desc.enumerable });
  }
  return to;
};
var __toESM = (mod, isNodeMode, target) => (target = mod != null ? __create(__getProtoOf(mod)) : {}, __copyProps(
  // If the importer is in node compatibility mode or this is not an ESM
  // file that has been converted to a CommonJS file using a Babel-
  // compatible transform (i.e. "__esModule" has not been set), then set
  // "default" to the CommonJS "module.exports" for node compatibility.
  isNodeMode || !mod || !mod.__esModule ? __defProp(target, "default", { value: mod, enumerable: true }) : target,
  mod
));
var __toCommonJS = (mod) => __copyProps(__defProp({}, "__esModule", { value: true }), mod);

// main.ts
var main_exports = {};
__export(main_exports, {
  default: () => MurmurBridgePlugin
});
module.exports = __toCommonJS(main_exports);
var import_obsidian = require("obsidian");
var import_state = require("@codemirror/state");
var import_view = require("@codemirror/view");
var http = __toESM(require("http"));
var setHighlightEffect = import_state.StateEffect.define();
var clearHighlightEffect = import_state.StateEffect.define();
var currentHighlightFrom = 0;
var currentHighlightTo = 0;
var highlightField = import_state.StateField.define({
  create() {
    return import_view.Decoration.none;
  },
  update(decorations, tr) {
    decorations = decorations.map(tr.changes);
    for (const effect of tr.effects) {
      if (effect.is(clearHighlightEffect)) {
        decorations = import_view.Decoration.none;
        currentHighlightFrom = 0;
        currentHighlightTo = 0;
      }
      if (effect.is(setHighlightEffect)) {
        const { from, to } = effect.value;
        currentHighlightFrom = from;
        currentHighlightTo = to;
        const doc = tr.state.doc;
        const builder = [];
        for (let line = from; line <= to && line <= doc.lines; line++) {
          const lineText = doc.line(line).text;
          if (lineText.includes("|"))
            continue;
          const lineStart = doc.line(line).from;
          builder.push(
            import_view.Decoration.line({ class: "murmur-highlight-line" }).range(lineStart)
          );
        }
        decorations = import_view.Decoration.set(builder, true);
      }
    }
    return decorations;
  },
  provide: (field) => import_view.EditorView.decorations.from(field)
});
var widgetHighlighter = import_view.ViewPlugin.fromClass(
  class {
    constructor(view) {
      this.view = view;
      this.highlightedElements = [];
      this.updateWidgetHighlights();
    }
    update(update) {
      for (const tr of update.transactions) {
        for (const effect of tr.effects) {
          if (effect.is(setHighlightEffect) || effect.is(clearHighlightEffect)) {
            setTimeout(() => this.updateWidgetHighlights(), 50);
            return;
          }
        }
      }
    }
    updateWidgetHighlights() {
      for (const el of this.highlightedElements) {
        el.classList.remove("murmur-highlight-widget");
      }
      this.highlightedElements = [];
      if (currentHighlightFrom === 0 || currentHighlightTo === 0)
        return;
      const doc = this.view.state.doc;
      if (currentHighlightFrom > doc.lines)
        return;
      const fromPos = doc.line(Math.min(currentHighlightFrom, doc.lines)).from;
      const toPos = doc.line(Math.min(currentHighlightTo, doc.lines)).to;
      const editorDom = this.view.dom;
      const containers = editorDom.querySelectorAll(".cm-embed-block");
      for (const container of Array.from(containers)) {
        const el = container;
        try {
          const pos = this.view.posAtDOM(el);
          if (pos >= fromPos && pos <= toPos) {
            el.classList.add("murmur-highlight-widget");
            this.highlightedElements.push(el);
          }
        } catch (e) {
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
var DEFAULT_SETTINGS = {
  port: 27125
};
var MurmurBridgePlugin = class extends import_obsidian.Plugin {
  constructor() {
    super(...arguments);
    this.settings = DEFAULT_SETTINGS;
    this.server = null;
    this.serverRunning = false;
  }
  async onload() {
    await this.loadSettings();
    this.registerEditorExtension([highlightField, widgetHighlighter]);
    this.addSettingTab(new MurmurBridgeSettingTab(this.app, this));
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
  startServer() {
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
    this.server.on("error", (err) => {
      this.serverRunning = false;
      console.error(`[Murmur Bridge] Server error: ${err.message}`);
      if (err.code === "EADDRINUSE") {
        console.error(`[Murmur Bridge] Port ${port} already in use`);
      }
    });
  }
  readBody(req, callback) {
    let data = "";
    req.on("data", (chunk) => data += chunk);
    req.on("end", () => {
      try {
        callback(JSON.parse(data));
      } catch (e) {
        callback({});
      }
    });
  }
  // -- Handlers --
  handleGetCursor(res) {
    var _a, _b;
    const view = this.app.workspace.getActiveViewOfType(import_obsidian.MarkdownView);
    if (!view || !view.editor) {
      res.writeHead(404);
      res.end(JSON.stringify({ error: "No active editor" }));
      return;
    }
    const cursor = view.editor.getCursor();
    const file = view.file;
    const vaultPath = ((_b = (_a = this.app.vault.adapter).getBasePath) == null ? void 0 : _b.call(_a)) || "";
    const absolutePath = file ? `${vaultPath}/${file.path}` : "";
    res.writeHead(200);
    res.end(
      JSON.stringify({
        line: cursor.line + 1,
        ch: cursor.ch + 1,
        file: absolutePath
      })
    );
  }
  handleHighlight(body, res) {
    const startLine = body.startLine;
    const endLine = body.endLine;
    if (!startLine || !endLine) {
      res.writeHead(400);
      res.end(JSON.stringify({ error: "Missing startLine or endLine" }));
      return;
    }
    const view = this.app.workspace.getActiveViewOfType(import_obsidian.MarkdownView);
    if (!view) {
      res.writeHead(404);
      res.end(JSON.stringify({ error: "No active editor" }));
      return;
    }
    const cmEditor = view.editor.cm;
    if (!cmEditor) {
      res.writeHead(500);
      res.end(JSON.stringify({ error: "Cannot access CodeMirror editor" }));
      return;
    }
    try {
      const lineInfo = cmEditor.state.doc.line(startLine);
      console.log(`[Murmur Bridge] Highlighting lines ${startLine}-${endLine - 1}, scrolling to line ${startLine} (pos ${lineInfo.from})`);
      cmEditor.dispatch({
        effects: [
          setHighlightEffect.of({ from: startLine, to: endLine - 1 }),
          import_view.EditorView.scrollIntoView(lineInfo.from, { y: "center" })
        ]
      });
    } catch (e) {
      console.log(`[Murmur Bridge] Scroll failed, highlight only: ${e}`);
      cmEditor.dispatch({
        effects: setHighlightEffect.of({ from: startLine, to: endLine - 1 })
      });
    }
    res.writeHead(200);
    res.end(JSON.stringify({ ok: true }));
  }
  handleClearHighlight(res) {
    const view = this.app.workspace.getActiveViewOfType(import_obsidian.MarkdownView);
    if (view) {
      const cmEditor = view.editor.cm;
      if (cmEditor) {
        cmEditor.dispatch({
          effects: clearHighlightEffect.of(null)
        });
      }
    }
    res.writeHead(200);
    res.end(JSON.stringify({ ok: true }));
  }
  handleNavigate(body, res) {
    const line = body.line;
    if (!line) {
      res.writeHead(400);
      res.end(JSON.stringify({ error: "Missing line" }));
      return;
    }
    const view = this.app.workspace.getActiveViewOfType(import_obsidian.MarkdownView);
    if (!view || !view.editor) {
      res.writeHead(404);
      res.end(JSON.stringify({ error: "No active editor" }));
      return;
    }
    view.editor.setCursor({ line: line - 1, ch: 0 });
    const cmEditor = view.editor.cm;
    if (cmEditor) {
      try {
        const lineInfo = cmEditor.state.doc.line(line);
        console.log(`[Murmur Bridge] Navigate to line ${line} (pos ${lineInfo.from})`);
        cmEditor.dispatch({
          effects: import_view.EditorView.scrollIntoView(lineInfo.from, { y: "center" })
        });
      } catch (e) {
        console.log(`[Murmur Bridge] Navigate scroll failed: ${e}`);
      }
    }
    res.writeHead(200);
    res.end(JSON.stringify({ ok: true }));
  }
};
var MurmurBridgeSettingTab = class extends import_obsidian.PluginSettingTab {
  constructor(app, plugin) {
    super(app, plugin);
    this.plugin = plugin;
  }
  display() {
    const { containerEl } = this;
    containerEl.empty();
    containerEl.createEl("h2", { text: "Murmur Bridge" });
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
      text: this.plugin.serverRunning ? `Running on 127.0.0.1:${this.plugin.settings.port}` : "Not running"
    });
    new import_obsidian.Setting(containerEl).setName("Port").setDesc("HTTP server port for Murmur communication. Restart required after change.").addText(
      (text) => text.setPlaceholder("27125").setValue(String(this.plugin.settings.port)).onChange(async (value) => {
        const port = parseInt(value);
        if (!isNaN(port) && port > 0 && port < 65536) {
          this.plugin.settings.port = port;
          await this.plugin.saveSettings();
        }
      })
    );
    new import_obsidian.Setting(containerEl).setName("Restart Server").setDesc("Restart the HTTP server with the current port setting.").addButton(
      (button) => button.setButtonText("Restart").onClick(() => {
        this.plugin.restartServer();
        setTimeout(() => this.display(), 500);
      })
    );
    containerEl.createEl("h3", { text: "Endpoints" });
    const infoEl = containerEl.createEl("div", { cls: "setting-item-description" });
    infoEl.style.fontSize = "12px";
    infoEl.innerHTML = `
			<p>The Murmur Bridge plugin exposes these local HTTP endpoints for the Murmur macOS app:</p>
			<ul>
				<li><code>GET /cursor</code> \u2014 Current cursor position and file path</li>
				<li><code>POST /highlight</code> \u2014 Highlight a range of lines</li>
				<li><code>POST /clear-highlight</code> \u2014 Clear all highlights</li>
				<li><code>POST /navigate</code> \u2014 Navigate to a specific line</li>
			</ul>
			<p>Use <strong>Cmd+Opt+D</strong> in the Murmur app to start draft editing with the active note.</p>
		`;
  }
};
//# sourceMappingURL=data:application/json;base64,ewogICJ2ZXJzaW9uIjogMywKICAic291cmNlcyI6IFsibWFpbi50cyJdLAogICJzb3VyY2VzQ29udGVudCI6IFsiaW1wb3J0IHsgUGx1Z2luLCBNYXJrZG93blZpZXcsIFBsdWdpblNldHRpbmdUYWIsIEFwcCwgU2V0dGluZyB9IGZyb20gXCJvYnNpZGlhblwiO1xuaW1wb3J0IHsgU3RhdGVGaWVsZCwgU3RhdGVFZmZlY3QsIFRyYW5zYWN0aW9uLCBSYW5nZSB9IGZyb20gXCJAY29kZW1pcnJvci9zdGF0ZVwiO1xuaW1wb3J0IHsgRGVjb3JhdGlvbiwgRGVjb3JhdGlvblNldCwgRWRpdG9yVmlldywgVmlld1BsdWdpbiwgVmlld1VwZGF0ZSwgV2lkZ2V0VHlwZSB9IGZyb20gXCJAY29kZW1pcnJvci92aWV3XCI7XG5pbXBvcnQgKiBhcyBodHRwIGZyb20gXCJodHRwXCI7XG5cbi8vIC0tIENvZGVNaXJyb3IgNiBkZWNvcmF0aW9uIGVmZmVjdHMgLS1cblxuY29uc3Qgc2V0SGlnaGxpZ2h0RWZmZWN0ID0gU3RhdGVFZmZlY3QuZGVmaW5lPHsgZnJvbTogbnVtYmVyOyB0bzogbnVtYmVyIH0+KCk7XG5jb25zdCBjbGVhckhpZ2hsaWdodEVmZmVjdCA9IFN0YXRlRWZmZWN0LmRlZmluZTxudWxsPigpO1xuXG4vLyBTdG9yZSB0aGUgY3VycmVudCBoaWdobGlnaHQgcmFuZ2UgKDEtYmFzZWQgbGluZSBudW1iZXJzKSBmb3IgdGhlIERPTSBoaWdobGlnaHRlclxubGV0IGN1cnJlbnRIaWdobGlnaHRGcm9tID0gMDtcbmxldCBjdXJyZW50SGlnaGxpZ2h0VG8gPSAwO1xuXG5jb25zdCBoaWdobGlnaHRGaWVsZCA9IFN0YXRlRmllbGQuZGVmaW5lPERlY29yYXRpb25TZXQ+KHtcblx0Y3JlYXRlKCkge1xuXHRcdHJldHVybiBEZWNvcmF0aW9uLm5vbmU7XG5cdH0sXG5cdHVwZGF0ZShkZWNvcmF0aW9uczogRGVjb3JhdGlvblNldCwgdHI6IFRyYW5zYWN0aW9uKSB7XG5cdFx0ZGVjb3JhdGlvbnMgPSBkZWNvcmF0aW9ucy5tYXAodHIuY2hhbmdlcyk7XG5cdFx0Zm9yIChjb25zdCBlZmZlY3Qgb2YgdHIuZWZmZWN0cykge1xuXHRcdFx0aWYgKGVmZmVjdC5pcyhjbGVhckhpZ2hsaWdodEVmZmVjdCkpIHtcblx0XHRcdFx0ZGVjb3JhdGlvbnMgPSBEZWNvcmF0aW9uLm5vbmU7XG5cdFx0XHRcdGN1cnJlbnRIaWdobGlnaHRGcm9tID0gMDtcblx0XHRcdFx0Y3VycmVudEhpZ2hsaWdodFRvID0gMDtcblx0XHRcdH1cblx0XHRcdGlmIChlZmZlY3QuaXMoc2V0SGlnaGxpZ2h0RWZmZWN0KSkge1xuXHRcdFx0XHRjb25zdCB7IGZyb20sIHRvIH0gPSBlZmZlY3QudmFsdWU7XG5cdFx0XHRcdGN1cnJlbnRIaWdobGlnaHRGcm9tID0gZnJvbTtcblx0XHRcdFx0Y3VycmVudEhpZ2hsaWdodFRvID0gdG87XG5cdFx0XHRcdGNvbnN0IGRvYyA9IHRyLnN0YXRlLmRvYztcblx0XHRcdFx0Y29uc3QgYnVpbGRlcjogUmFuZ2U8RGVjb3JhdGlvbj5bXSA9IFtdO1xuXHRcdFx0XHRmb3IgKGxldCBsaW5lID0gZnJvbTsgbGluZSA8PSB0byAmJiBsaW5lIDw9IGRvYy5saW5lczsgbGluZSsrKSB7XG5cdFx0XHRcdFx0Ly8gU2tpcCBsaW5lcyB0aGF0IGxvb2sgbGlrZSB0YWJsZSByb3dzIChjb250YWluIHwpIFx1MjAxNCB0aGVzZSBnZXRcblx0XHRcdFx0XHQvLyBoaWdobGlnaHRlZCB2aWEgdGhlIHdpZGdldCBoaWdobGlnaHRlciBvbiB0aGUgcmVuZGVyZWQgdGFibGUgaW5zdGVhZCxcblx0XHRcdFx0XHQvLyBhdm9pZGluZyBhIGRvdWJsZS1oaWdobGlnaHQgaW4gbGl2ZSBwcmV2aWV3XG5cdFx0XHRcdFx0Y29uc3QgbGluZVRleHQgPSBkb2MubGluZShsaW5lKS50ZXh0O1xuXHRcdFx0XHRcdGlmIChsaW5lVGV4dC5pbmNsdWRlcyhcInxcIikpIGNvbnRpbnVlO1xuXG5cdFx0XHRcdFx0Y29uc3QgbGluZVN0YXJ0ID0gZG9jLmxpbmUobGluZSkuZnJvbTtcblx0XHRcdFx0XHRidWlsZGVyLnB1c2goXG5cdFx0XHRcdFx0XHREZWNvcmF0aW9uLmxpbmUoeyBjbGFzczogXCJtdXJtdXItaGlnaGxpZ2h0LWxpbmVcIiB9KS5yYW5nZShsaW5lU3RhcnQpXG5cdFx0XHRcdFx0KTtcblx0XHRcdFx0fVxuXHRcdFx0XHRkZWNvcmF0aW9ucyA9IERlY29yYXRpb24uc2V0KGJ1aWxkZXIsIHRydWUpO1xuXHRcdFx0fVxuXHRcdH1cblx0XHRyZXR1cm4gZGVjb3JhdGlvbnM7XG5cdH0sXG5cdHByb3ZpZGU6IChmaWVsZCkgPT4gRWRpdG9yVmlldy5kZWNvcmF0aW9ucy5mcm9tKGZpZWxkKSxcbn0pO1xuXG4vLyBWaWV3UGx1Z2luIHRoYXQgaGlnaGxpZ2h0cyByZW5kZXJlZCB3aWRnZXRzICh0YWJsZXMsIGNhbGxvdXRzLCBldGMuKSBpbiBsaXZlIHByZXZpZXdcbi8vIExpbmUgZGVjb3JhdGlvbnMgZG9uJ3Qgc2hvdyBvbiByZW5kZXJlZCB3aWRnZXRzLCBzbyB3ZSBhZGQgQ1NTIGNsYXNzZXMgdG8gdGhlIERPTSBkaXJlY3RseVxuY29uc3Qgd2lkZ2V0SGlnaGxpZ2h0ZXIgPSBWaWV3UGx1Z2luLmZyb21DbGFzcyhcblx0Y2xhc3Mge1xuXHRcdHByaXZhdGUgaGlnaGxpZ2h0ZWRFbGVtZW50czogSFRNTEVsZW1lbnRbXSA9IFtdO1xuXG5cdFx0Y29uc3RydWN0b3IocHJpdmF0ZSB2aWV3OiBFZGl0b3JWaWV3KSB7XG5cdFx0XHR0aGlzLnVwZGF0ZVdpZGdldEhpZ2hsaWdodHMoKTtcblx0XHR9XG5cblx0XHR1cGRhdGUodXBkYXRlOiBWaWV3VXBkYXRlKSB7XG5cdFx0XHQvLyBDaGVjayBpZiBoaWdobGlnaHQgZWZmZWN0cyB3ZXJlIGRpc3BhdGNoZWRcblx0XHRcdGZvciAoY29uc3QgdHIgb2YgdXBkYXRlLnRyYW5zYWN0aW9ucykge1xuXHRcdFx0XHRmb3IgKGNvbnN0IGVmZmVjdCBvZiB0ci5lZmZlY3RzKSB7XG5cdFx0XHRcdFx0aWYgKGVmZmVjdC5pcyhzZXRIaWdobGlnaHRFZmZlY3QpIHx8IGVmZmVjdC5pcyhjbGVhckhpZ2hsaWdodEVmZmVjdCkpIHtcblx0XHRcdFx0XHRcdC8vIFNtYWxsIGRlbGF5IHRvIGxldCBPYnNpZGlhbiByZW5kZXIgd2lkZ2V0cyBmaXJzdFxuXHRcdFx0XHRcdFx0c2V0VGltZW91dCgoKSA9PiB0aGlzLnVwZGF0ZVdpZGdldEhpZ2hsaWdodHMoKSwgNTApO1xuXHRcdFx0XHRcdFx0cmV0dXJuO1xuXHRcdFx0XHRcdH1cblx0XHRcdFx0fVxuXHRcdFx0fVxuXHRcdH1cblxuXHRcdHVwZGF0ZVdpZGdldEhpZ2hsaWdodHMoKSB7XG5cdFx0XHQvLyBSZW1vdmUgcHJldmlvdXMgaGlnaGxpZ2h0c1xuXHRcdFx0Zm9yIChjb25zdCBlbCBvZiB0aGlzLmhpZ2hsaWdodGVkRWxlbWVudHMpIHtcblx0XHRcdFx0ZWwuY2xhc3NMaXN0LnJlbW92ZShcIm11cm11ci1oaWdobGlnaHQtd2lkZ2V0XCIpO1xuXHRcdFx0fVxuXHRcdFx0dGhpcy5oaWdobGlnaHRlZEVsZW1lbnRzID0gW107XG5cblx0XHRcdGlmIChjdXJyZW50SGlnaGxpZ2h0RnJvbSA9PT0gMCB8fCBjdXJyZW50SGlnaGxpZ2h0VG8gPT09IDApIHJldHVybjtcblxuXHRcdFx0Y29uc3QgZG9jID0gdGhpcy52aWV3LnN0YXRlLmRvYztcblx0XHRcdGlmIChjdXJyZW50SGlnaGxpZ2h0RnJvbSA+IGRvYy5saW5lcykgcmV0dXJuO1xuXG5cdFx0XHQvLyBHZXQgdGhlIGNoYXJhY3RlciByYW5nZSBvZiB0aGUgaGlnaGxpZ2h0ZWQgbGluZXNcblx0XHRcdGNvbnN0IGZyb21Qb3MgPSBkb2MubGluZShNYXRoLm1pbihjdXJyZW50SGlnaGxpZ2h0RnJvbSwgZG9jLmxpbmVzKSkuZnJvbTtcblx0XHRcdGNvbnN0IHRvUG9zID0gZG9jLmxpbmUoTWF0aC5taW4oY3VycmVudEhpZ2hsaWdodFRvLCBkb2MubGluZXMpKS50bztcblxuXHRcdFx0Ly8gRmluZCB0aGUgb3V0ZXJtb3N0IGVtYmVkL3dpZGdldCBjb250YWluZXJzIG9ubHkgKG5vdCBpbm5lciBlbGVtZW50cyBsaWtlIDx0YWJsZT4pXG5cdFx0XHQvLyBUaGlzIGF2b2lkcyBkb3VibGUtaGlnaGxpZ2h0aW5nIHdoZW4gYSBjb250YWluZXIgd3JhcHMgYSB0YWJsZSBlbGVtZW50XG5cdFx0XHRjb25zdCBlZGl0b3JEb20gPSB0aGlzLnZpZXcuZG9tO1xuXHRcdFx0Y29uc3QgY29udGFpbmVycyA9IGVkaXRvckRvbS5xdWVyeVNlbGVjdG9yQWxsKFwiLmNtLWVtYmVkLWJsb2NrXCIpO1xuXG5cdFx0XHRmb3IgKGNvbnN0IGNvbnRhaW5lciBvZiBBcnJheS5mcm9tKGNvbnRhaW5lcnMpKSB7XG5cdFx0XHRcdGNvbnN0IGVsID0gY29udGFpbmVyIGFzIEhUTUxFbGVtZW50O1xuXHRcdFx0XHR0cnkge1xuXHRcdFx0XHRcdGNvbnN0IHBvcyA9IHRoaXMudmlldy5wb3NBdERPTShlbCk7XG5cdFx0XHRcdFx0aWYgKHBvcyA+PSBmcm9tUG9zICYmIHBvcyA8PSB0b1Bvcykge1xuXHRcdFx0XHRcdFx0ZWwuY2xhc3NMaXN0LmFkZChcIm11cm11ci1oaWdobGlnaHQtd2lkZ2V0XCIpO1xuXHRcdFx0XHRcdFx0dGhpcy5oaWdobGlnaHRlZEVsZW1lbnRzLnB1c2goZWwpO1xuXHRcdFx0XHRcdH1cblx0XHRcdFx0fSBjYXRjaCB7XG5cdFx0XHRcdFx0Ly8gcG9zQXRET00gY2FuIHRocm93IGlmIGVsZW1lbnQgaXMgb3V0c2lkZSBlZGl0b3IgY29udGVudFxuXHRcdFx0XHR9XG5cdFx0XHR9XG5cdFx0fVxuXG5cdFx0ZGVzdHJveSgpIHtcblx0XHRcdGZvciAoY29uc3QgZWwgb2YgdGhpcy5oaWdobGlnaHRlZEVsZW1lbnRzKSB7XG5cdFx0XHRcdGVsLmNsYXNzTGlzdC5yZW1vdmUoXCJtdXJtdXItaGlnaGxpZ2h0LXdpZGdldFwiKTtcblx0XHRcdH1cblx0XHR9XG5cdH1cbik7XG5cbi8vIC0tIFNldHRpbmdzIC0tXG5cbmludGVyZmFjZSBNdXJtdXJCcmlkZ2VTZXR0aW5ncyB7XG5cdHBvcnQ6IG51bWJlcjtcbn1cblxuY29uc3QgREVGQVVMVF9TRVRUSU5HUzogTXVybXVyQnJpZGdlU2V0dGluZ3MgPSB7XG5cdHBvcnQ6IDI3MTI1LFxufTtcblxuLy8gLS0gUGx1Z2luIC0tXG5cbmV4cG9ydCBkZWZhdWx0IGNsYXNzIE11cm11ckJyaWRnZVBsdWdpbiBleHRlbmRzIFBsdWdpbiB7XG5cdHNldHRpbmdzOiBNdXJtdXJCcmlkZ2VTZXR0aW5ncyA9IERFRkFVTFRfU0VUVElOR1M7XG5cdHByaXZhdGUgc2VydmVyOiBodHRwLlNlcnZlciB8IG51bGwgPSBudWxsO1xuXHRzZXJ2ZXJSdW5uaW5nID0gZmFsc2U7XG5cblx0YXN5bmMgb25sb2FkKCkge1xuXHRcdGF3YWl0IHRoaXMubG9hZFNldHRpbmdzKCk7XG5cblx0XHQvLyBSZWdpc3RlciB0aGUgQ29kZU1pcnJvciBleHRlbnNpb25zIGZvciBsaW5lIGhpZ2hsaWdodGluZyArIHdpZGdldCBoaWdobGlnaHRpbmdcblx0XHR0aGlzLnJlZ2lzdGVyRWRpdG9yRXh0ZW5zaW9uKFtoaWdobGlnaHRGaWVsZCwgd2lkZ2V0SGlnaGxpZ2h0ZXJdKTtcblxuXHRcdC8vIEFkZCBzZXR0aW5ncyB0YWJcblx0XHR0aGlzLmFkZFNldHRpbmdUYWIobmV3IE11cm11ckJyaWRnZVNldHRpbmdUYWIodGhpcy5hcHAsIHRoaXMpKTtcblxuXHRcdC8vIFN0YXJ0IHRoZSBIVFRQIHNlcnZlclxuXHRcdHRoaXMuc3RhcnRTZXJ2ZXIoKTtcblx0XHRjb25zb2xlLmxvZyhgW011cm11ciBCcmlkZ2VdIFBsdWdpbiBsb2FkZWQsIEhUVFAgc2VydmVyIG9uIHBvcnQgJHt0aGlzLnNldHRpbmdzLnBvcnR9YCk7XG5cdH1cblxuXHRvbnVubG9hZCgpIHtcblx0XHRpZiAodGhpcy5zZXJ2ZXIpIHtcblx0XHRcdHRoaXMuc2VydmVyLmNsb3NlKCk7XG5cdFx0XHR0aGlzLnNlcnZlciA9IG51bGw7XG5cdFx0XHR0aGlzLnNlcnZlclJ1bm5pbmcgPSBmYWxzZTtcblx0XHR9XG5cdFx0Y29uc29sZS5sb2coXCJbTXVybXVyIEJyaWRnZV0gUGx1Z2luIHVubG9hZGVkXCIpO1xuXHR9XG5cblx0YXN5bmMgbG9hZFNldHRpbmdzKCkge1xuXHRcdHRoaXMuc2V0dGluZ3MgPSBPYmplY3QuYXNzaWduKHt9LCBERUZBVUxUX1NFVFRJTkdTLCBhd2FpdCB0aGlzLmxvYWREYXRhKCkpO1xuXHR9XG5cblx0YXN5bmMgc2F2ZVNldHRpbmdzKCkge1xuXHRcdGF3YWl0IHRoaXMuc2F2ZURhdGEodGhpcy5zZXR0aW5ncyk7XG5cdH1cblxuXHRyZXN0YXJ0U2VydmVyKCkge1xuXHRcdGlmICh0aGlzLnNlcnZlcikge1xuXHRcdFx0dGhpcy5zZXJ2ZXIuY2xvc2UoKTtcblx0XHRcdHRoaXMuc2VydmVyID0gbnVsbDtcblx0XHRcdHRoaXMuc2VydmVyUnVubmluZyA9IGZhbHNlO1xuXHRcdH1cblx0XHR0aGlzLnN0YXJ0U2VydmVyKCk7XG5cdH1cblxuXHRwcml2YXRlIHN0YXJ0U2VydmVyKCkge1xuXHRcdGNvbnN0IHBvcnQgPSB0aGlzLnNldHRpbmdzLnBvcnQ7XG5cdFx0dGhpcy5zZXJ2ZXIgPSBodHRwLmNyZWF0ZVNlcnZlcigocmVxLCByZXMpID0+IHtcblx0XHRcdHJlcy5zZXRIZWFkZXIoXCJBY2Nlc3MtQ29udHJvbC1BbGxvdy1PcmlnaW5cIiwgXCIqXCIpO1xuXHRcdFx0cmVzLnNldEhlYWRlcihcIkNvbnRlbnQtVHlwZVwiLCBcImFwcGxpY2F0aW9uL2pzb25cIik7XG5cblx0XHRcdGlmIChyZXEubWV0aG9kID09PSBcIk9QVElPTlNcIikge1xuXHRcdFx0XHRyZXMuc2V0SGVhZGVyKFwiQWNjZXNzLUNvbnRyb2wtQWxsb3ctTWV0aG9kc1wiLCBcIkdFVCwgUE9TVCwgT1BUSU9OU1wiKTtcblx0XHRcdFx0cmVzLnNldEhlYWRlcihcIkFjY2Vzcy1Db250cm9sLUFsbG93LUhlYWRlcnNcIiwgXCJDb250ZW50LVR5cGVcIik7XG5cdFx0XHRcdHJlcy53cml0ZUhlYWQoMjAwKTtcblx0XHRcdFx0cmVzLmVuZCgpO1xuXHRcdFx0XHRyZXR1cm47XG5cdFx0XHR9XG5cblx0XHRcdGNvbnN0IHVybCA9IHJlcS51cmwgfHwgXCIvXCI7XG5cblx0XHRcdGlmIChyZXEubWV0aG9kID09PSBcIkdFVFwiICYmIHVybCA9PT0gXCIvY3Vyc29yXCIpIHtcblx0XHRcdFx0dGhpcy5oYW5kbGVHZXRDdXJzb3IocmVzKTtcblx0XHRcdH0gZWxzZSBpZiAocmVxLm1ldGhvZCA9PT0gXCJQT1NUXCIgJiYgdXJsID09PSBcIi9oaWdobGlnaHRcIikge1xuXHRcdFx0XHR0aGlzLnJlYWRCb2R5KHJlcSwgKGJvZHkpID0+IHRoaXMuaGFuZGxlSGlnaGxpZ2h0KGJvZHksIHJlcykpO1xuXHRcdFx0fSBlbHNlIGlmIChyZXEubWV0aG9kID09PSBcIlBPU1RcIiAmJiB1cmwgPT09IFwiL2NsZWFyLWhpZ2hsaWdodFwiKSB7XG5cdFx0XHRcdHRoaXMuaGFuZGxlQ2xlYXJIaWdobGlnaHQocmVzKTtcblx0XHRcdH0gZWxzZSBpZiAocmVxLm1ldGhvZCA9PT0gXCJQT1NUXCIgJiYgdXJsID09PSBcIi9uYXZpZ2F0ZVwiKSB7XG5cdFx0XHRcdHRoaXMucmVhZEJvZHkocmVxLCAoYm9keSkgPT4gdGhpcy5oYW5kbGVOYXZpZ2F0ZShib2R5LCByZXMpKTtcblx0XHRcdH0gZWxzZSB7XG5cdFx0XHRcdHJlcy53cml0ZUhlYWQoNDA0KTtcblx0XHRcdFx0cmVzLmVuZChKU09OLnN0cmluZ2lmeSh7IGVycm9yOiBcIk5vdCBmb3VuZFwiIH0pKTtcblx0XHRcdH1cblx0XHR9KTtcblxuXHRcdHRoaXMuc2VydmVyLmxpc3Rlbihwb3J0LCBcIjEyNy4wLjAuMVwiLCAoKSA9PiB7XG5cdFx0XHR0aGlzLnNlcnZlclJ1bm5pbmcgPSB0cnVlO1xuXHRcdFx0Y29uc29sZS5sb2coYFtNdXJtdXIgQnJpZGdlXSBIVFRQIHNlcnZlciBsaXN0ZW5pbmcgb24gMTI3LjAuMC4xOiR7cG9ydH1gKTtcblx0XHR9KTtcblxuXHRcdHRoaXMuc2VydmVyLm9uKFwiZXJyb3JcIiwgKGVycjogYW55KSA9PiB7XG5cdFx0XHR0aGlzLnNlcnZlclJ1bm5pbmcgPSBmYWxzZTtcblx0XHRcdGNvbnNvbGUuZXJyb3IoYFtNdXJtdXIgQnJpZGdlXSBTZXJ2ZXIgZXJyb3I6ICR7ZXJyLm1lc3NhZ2V9YCk7XG5cdFx0XHRpZiAoZXJyLmNvZGUgPT09IFwiRUFERFJJTlVTRVwiKSB7XG5cdFx0XHRcdGNvbnNvbGUuZXJyb3IoYFtNdXJtdXIgQnJpZGdlXSBQb3J0ICR7cG9ydH0gYWxyZWFkeSBpbiB1c2VgKTtcblx0XHRcdH1cblx0XHR9KTtcblx0fVxuXG5cdHByaXZhdGUgcmVhZEJvZHkocmVxOiBodHRwLkluY29taW5nTWVzc2FnZSwgY2FsbGJhY2s6IChib2R5OiBhbnkpID0+IHZvaWQpIHtcblx0XHRsZXQgZGF0YSA9IFwiXCI7XG5cdFx0cmVxLm9uKFwiZGF0YVwiLCAoY2h1bms6IHN0cmluZykgPT4gKGRhdGEgKz0gY2h1bmspKTtcblx0XHRyZXEub24oXCJlbmRcIiwgKCkgPT4ge1xuXHRcdFx0dHJ5IHtcblx0XHRcdFx0Y2FsbGJhY2soSlNPTi5wYXJzZShkYXRhKSk7XG5cdFx0XHR9IGNhdGNoIHtcblx0XHRcdFx0Y2FsbGJhY2soe30pO1xuXHRcdFx0fVxuXHRcdH0pO1xuXHR9XG5cblx0Ly8gLS0gSGFuZGxlcnMgLS1cblxuXHRwcml2YXRlIGhhbmRsZUdldEN1cnNvcihyZXM6IGh0dHAuU2VydmVyUmVzcG9uc2UpIHtcblx0XHRjb25zdCB2aWV3ID0gdGhpcy5hcHAud29ya3NwYWNlLmdldEFjdGl2ZVZpZXdPZlR5cGUoTWFya2Rvd25WaWV3KTtcblx0XHRpZiAoIXZpZXcgfHwgIXZpZXcuZWRpdG9yKSB7XG5cdFx0XHRyZXMud3JpdGVIZWFkKDQwNCk7XG5cdFx0XHRyZXMuZW5kKEpTT04uc3RyaW5naWZ5KHsgZXJyb3I6IFwiTm8gYWN0aXZlIGVkaXRvclwiIH0pKTtcblx0XHRcdHJldHVybjtcblx0XHR9XG5cblx0XHRjb25zdCBjdXJzb3IgPSB2aWV3LmVkaXRvci5nZXRDdXJzb3IoKTtcblx0XHRjb25zdCBmaWxlID0gdmlldy5maWxlO1xuXHRcdGNvbnN0IHZhdWx0UGF0aCA9ICh0aGlzLmFwcC52YXVsdC5hZGFwdGVyIGFzIGFueSkuZ2V0QmFzZVBhdGg/LigpIHx8IFwiXCI7XG5cdFx0Y29uc3QgYWJzb2x1dGVQYXRoID0gZmlsZSA/IGAke3ZhdWx0UGF0aH0vJHtmaWxlLnBhdGh9YCA6IFwiXCI7XG5cblx0XHRyZXMud3JpdGVIZWFkKDIwMCk7XG5cdFx0cmVzLmVuZChcblx0XHRcdEpTT04uc3RyaW5naWZ5KHtcblx0XHRcdFx0bGluZTogY3Vyc29yLmxpbmUgKyAxLFxuXHRcdFx0XHRjaDogY3Vyc29yLmNoICsgMSxcblx0XHRcdFx0ZmlsZTogYWJzb2x1dGVQYXRoLFxuXHRcdFx0fSlcblx0XHQpO1xuXHR9XG5cblx0cHJpdmF0ZSBoYW5kbGVIaWdobGlnaHQoYm9keTogYW55LCByZXM6IGh0dHAuU2VydmVyUmVzcG9uc2UpIHtcblx0XHRjb25zdCBzdGFydExpbmUgPSBib2R5LnN0YXJ0TGluZSBhcyBudW1iZXI7XG5cdFx0Y29uc3QgZW5kTGluZSA9IGJvZHkuZW5kTGluZSBhcyBudW1iZXI7XG5cblx0XHRpZiAoIXN0YXJ0TGluZSB8fCAhZW5kTGluZSkge1xuXHRcdFx0cmVzLndyaXRlSGVhZCg0MDApO1xuXHRcdFx0cmVzLmVuZChKU09OLnN0cmluZ2lmeSh7IGVycm9yOiBcIk1pc3Npbmcgc3RhcnRMaW5lIG9yIGVuZExpbmVcIiB9KSk7XG5cdFx0XHRyZXR1cm47XG5cdFx0fVxuXG5cdFx0Y29uc3QgdmlldyA9IHRoaXMuYXBwLndvcmtzcGFjZS5nZXRBY3RpdmVWaWV3T2ZUeXBlKE1hcmtkb3duVmlldyk7XG5cdFx0aWYgKCF2aWV3KSB7XG5cdFx0XHRyZXMud3JpdGVIZWFkKDQwNCk7XG5cdFx0XHRyZXMuZW5kKEpTT04uc3RyaW5naWZ5KHsgZXJyb3I6IFwiTm8gYWN0aXZlIGVkaXRvclwiIH0pKTtcblx0XHRcdHJldHVybjtcblx0XHR9XG5cblx0XHRjb25zdCBjbUVkaXRvciA9ICh2aWV3LmVkaXRvciBhcyBhbnkpLmNtIGFzIEVkaXRvclZpZXc7XG5cdFx0aWYgKCFjbUVkaXRvcikge1xuXHRcdFx0cmVzLndyaXRlSGVhZCg1MDApO1xuXHRcdFx0cmVzLmVuZChKU09OLnN0cmluZ2lmeSh7IGVycm9yOiBcIkNhbm5vdCBhY2Nlc3MgQ29kZU1pcnJvciBlZGl0b3JcIiB9KSk7XG5cdFx0XHRyZXR1cm47XG5cdFx0fVxuXG5cdFx0Ly8gQ29tYmluZSBoaWdobGlnaHQgKyBzY3JvbGwgaW50byBhIHNpbmdsZSBkaXNwYXRjaFxuXHRcdHRyeSB7XG5cdFx0XHRjb25zdCBsaW5lSW5mbyA9IGNtRWRpdG9yLnN0YXRlLmRvYy5saW5lKHN0YXJ0TGluZSk7XG5cdFx0XHRjb25zb2xlLmxvZyhgW011cm11ciBCcmlkZ2VdIEhpZ2hsaWdodGluZyBsaW5lcyAke3N0YXJ0TGluZX0tJHtlbmRMaW5lIC0gMX0sIHNjcm9sbGluZyB0byBsaW5lICR7c3RhcnRMaW5lfSAocG9zICR7bGluZUluZm8uZnJvbX0pYCk7XG5cdFx0XHRjbUVkaXRvci5kaXNwYXRjaCh7XG5cdFx0XHRcdGVmZmVjdHM6IFtcblx0XHRcdFx0XHRzZXRIaWdobGlnaHRFZmZlY3Qub2YoeyBmcm9tOiBzdGFydExpbmUsIHRvOiBlbmRMaW5lIC0gMSB9KSxcblx0XHRcdFx0XHRFZGl0b3JWaWV3LnNjcm9sbEludG9WaWV3KGxpbmVJbmZvLmZyb20sIHsgeTogXCJjZW50ZXJcIiB9KSxcblx0XHRcdFx0XSxcblx0XHRcdH0pO1xuXHRcdH0gY2F0Y2ggKGUpIHtcblx0XHRcdGNvbnNvbGUubG9nKGBbTXVybXVyIEJyaWRnZV0gU2Nyb2xsIGZhaWxlZCwgaGlnaGxpZ2h0IG9ubHk6ICR7ZX1gKTtcblx0XHRcdGNtRWRpdG9yLmRpc3BhdGNoKHtcblx0XHRcdFx0ZWZmZWN0czogc2V0SGlnaGxpZ2h0RWZmZWN0Lm9mKHsgZnJvbTogc3RhcnRMaW5lLCB0bzogZW5kTGluZSAtIDEgfSksXG5cdFx0XHR9KTtcblx0XHR9XG5cblx0XHRyZXMud3JpdGVIZWFkKDIwMCk7XG5cdFx0cmVzLmVuZChKU09OLnN0cmluZ2lmeSh7IG9rOiB0cnVlIH0pKTtcblx0fVxuXG5cdHByaXZhdGUgaGFuZGxlQ2xlYXJIaWdobGlnaHQocmVzOiBodHRwLlNlcnZlclJlc3BvbnNlKSB7XG5cdFx0Y29uc3QgdmlldyA9IHRoaXMuYXBwLndvcmtzcGFjZS5nZXRBY3RpdmVWaWV3T2ZUeXBlKE1hcmtkb3duVmlldyk7XG5cdFx0aWYgKHZpZXcpIHtcblx0XHRcdGNvbnN0IGNtRWRpdG9yID0gKHZpZXcuZWRpdG9yIGFzIGFueSkuY20gYXMgRWRpdG9yVmlldztcblx0XHRcdGlmIChjbUVkaXRvcikge1xuXHRcdFx0XHRjbUVkaXRvci5kaXNwYXRjaCh7XG5cdFx0XHRcdFx0ZWZmZWN0czogY2xlYXJIaWdobGlnaHRFZmZlY3Qub2YobnVsbCksXG5cdFx0XHRcdH0pO1xuXHRcdFx0fVxuXHRcdH1cblx0XHRyZXMud3JpdGVIZWFkKDIwMCk7XG5cdFx0cmVzLmVuZChKU09OLnN0cmluZ2lmeSh7IG9rOiB0cnVlIH0pKTtcblx0fVxuXG5cdHByaXZhdGUgaGFuZGxlTmF2aWdhdGUoYm9keTogYW55LCByZXM6IGh0dHAuU2VydmVyUmVzcG9uc2UpIHtcblx0XHRjb25zdCBsaW5lID0gYm9keS5saW5lIGFzIG51bWJlcjtcblx0XHRpZiAoIWxpbmUpIHtcblx0XHRcdHJlcy53cml0ZUhlYWQoNDAwKTtcblx0XHRcdHJlcy5lbmQoSlNPTi5zdHJpbmdpZnkoeyBlcnJvcjogXCJNaXNzaW5nIGxpbmVcIiB9KSk7XG5cdFx0XHRyZXR1cm47XG5cdFx0fVxuXG5cdFx0Y29uc3QgdmlldyA9IHRoaXMuYXBwLndvcmtzcGFjZS5nZXRBY3RpdmVWaWV3T2ZUeXBlKE1hcmtkb3duVmlldyk7XG5cdFx0aWYgKCF2aWV3IHx8ICF2aWV3LmVkaXRvcikge1xuXHRcdFx0cmVzLndyaXRlSGVhZCg0MDQpO1xuXHRcdFx0cmVzLmVuZChKU09OLnN0cmluZ2lmeSh7IGVycm9yOiBcIk5vIGFjdGl2ZSBlZGl0b3JcIiB9KSk7XG5cdFx0XHRyZXR1cm47XG5cdFx0fVxuXG5cdFx0dmlldy5lZGl0b3Iuc2V0Q3Vyc29yKHsgbGluZTogbGluZSAtIDEsIGNoOiAwIH0pO1xuXG5cdFx0Y29uc3QgY21FZGl0b3IgPSAodmlldy5lZGl0b3IgYXMgYW55KS5jbSBhcyBFZGl0b3JWaWV3O1xuXHRcdGlmIChjbUVkaXRvcikge1xuXHRcdFx0dHJ5IHtcblx0XHRcdFx0Y29uc3QgbGluZUluZm8gPSBjbUVkaXRvci5zdGF0ZS5kb2MubGluZShsaW5lKTtcblx0XHRcdFx0Y29uc29sZS5sb2coYFtNdXJtdXIgQnJpZGdlXSBOYXZpZ2F0ZSB0byBsaW5lICR7bGluZX0gKHBvcyAke2xpbmVJbmZvLmZyb219KWApO1xuXHRcdFx0XHRjbUVkaXRvci5kaXNwYXRjaCh7XG5cdFx0XHRcdFx0ZWZmZWN0czogRWRpdG9yVmlldy5zY3JvbGxJbnRvVmlldyhsaW5lSW5mby5mcm9tLCB7IHk6IFwiY2VudGVyXCIgfSksXG5cdFx0XHRcdH0pO1xuXHRcdFx0fSBjYXRjaCAoZSkge1xuXHRcdFx0XHRjb25zb2xlLmxvZyhgW011cm11ciBCcmlkZ2VdIE5hdmlnYXRlIHNjcm9sbCBmYWlsZWQ6ICR7ZX1gKTtcblx0XHRcdH1cblx0XHR9XG5cblx0XHRyZXMud3JpdGVIZWFkKDIwMCk7XG5cdFx0cmVzLmVuZChKU09OLnN0cmluZ2lmeSh7IG9rOiB0cnVlIH0pKTtcblx0fVxufVxuXG4vLyAtLSBTZXR0aW5ncyBUYWIgLS1cblxuY2xhc3MgTXVybXVyQnJpZGdlU2V0dGluZ1RhYiBleHRlbmRzIFBsdWdpblNldHRpbmdUYWIge1xuXHRwbHVnaW46IE11cm11ckJyaWRnZVBsdWdpbjtcblxuXHRjb25zdHJ1Y3RvcihhcHA6IEFwcCwgcGx1Z2luOiBNdXJtdXJCcmlkZ2VQbHVnaW4pIHtcblx0XHRzdXBlcihhcHAsIHBsdWdpbik7XG5cdFx0dGhpcy5wbHVnaW4gPSBwbHVnaW47XG5cdH1cblxuXHRkaXNwbGF5KCk6IHZvaWQge1xuXHRcdGNvbnN0IHsgY29udGFpbmVyRWwgfSA9IHRoaXM7XG5cdFx0Y29udGFpbmVyRWwuZW1wdHkoKTtcblxuXHRcdGNvbnRhaW5lckVsLmNyZWF0ZUVsKFwiaDJcIiwgeyB0ZXh0OiBcIk11cm11ciBCcmlkZ2VcIiB9KTtcblxuXHRcdC8vIFN0YXR1cyBpbmRpY2F0b3Jcblx0XHRjb25zdCBzdGF0dXNFbCA9IGNvbnRhaW5lckVsLmNyZWF0ZURpdih7IGNsczogXCJzZXR0aW5nLWl0ZW1cIiB9KTtcblx0XHRjb25zdCBzdGF0dXNJbmZvID0gc3RhdHVzRWwuY3JlYXRlRGl2KHsgY2xzOiBcInNldHRpbmctaXRlbS1pbmZvXCIgfSk7XG5cdFx0c3RhdHVzSW5mby5jcmVhdGVEaXYoeyBjbHM6IFwic2V0dGluZy1pdGVtLW5hbWVcIiwgdGV4dDogXCJTZXJ2ZXIgU3RhdHVzXCIgfSk7XG5cdFx0Y29uc3Qgc3RhdHVzRGVzYyA9IHN0YXR1c0luZm8uY3JlYXRlRGl2KHsgY2xzOiBcInNldHRpbmctaXRlbS1kZXNjcmlwdGlvblwiIH0pO1xuXHRcdGNvbnN0IGRvdCA9IHN0YXR1c0Rlc2MuY3JlYXRlU3BhbigpO1xuXHRcdGRvdC5zdHlsZS5kaXNwbGF5ID0gXCJpbmxpbmUtYmxvY2tcIjtcblx0XHRkb3Quc3R5bGUud2lkdGggPSBcIjhweFwiO1xuXHRcdGRvdC5zdHlsZS5oZWlnaHQgPSBcIjhweFwiO1xuXHRcdGRvdC5zdHlsZS5ib3JkZXJSYWRpdXMgPSBcIjUwJVwiO1xuXHRcdGRvdC5zdHlsZS5tYXJnaW5SaWdodCA9IFwiNnB4XCI7XG5cdFx0ZG90LnN0eWxlLmJhY2tncm91bmRDb2xvciA9IHRoaXMucGx1Z2luLnNlcnZlclJ1bm5pbmcgPyBcIiM0YWRlODBcIiA6IFwiI2Y4NzE3MVwiO1xuXHRcdHN0YXR1c0Rlc2MuY3JlYXRlU3Bhbih7XG5cdFx0XHR0ZXh0OiB0aGlzLnBsdWdpbi5zZXJ2ZXJSdW5uaW5nXG5cdFx0XHRcdD8gYFJ1bm5pbmcgb24gMTI3LjAuMC4xOiR7dGhpcy5wbHVnaW4uc2V0dGluZ3MucG9ydH1gXG5cdFx0XHRcdDogXCJOb3QgcnVubmluZ1wiLFxuXHRcdH0pO1xuXG5cdFx0Ly8gUG9ydCBzZXR0aW5nXG5cdFx0bmV3IFNldHRpbmcoY29udGFpbmVyRWwpXG5cdFx0XHQuc2V0TmFtZShcIlBvcnRcIilcblx0XHRcdC5zZXREZXNjKFwiSFRUUCBzZXJ2ZXIgcG9ydCBmb3IgTXVybXVyIGNvbW11bmljYXRpb24uIFJlc3RhcnQgcmVxdWlyZWQgYWZ0ZXIgY2hhbmdlLlwiKVxuXHRcdFx0LmFkZFRleHQoKHRleHQpID0+XG5cdFx0XHRcdHRleHRcblx0XHRcdFx0XHQuc2V0UGxhY2Vob2xkZXIoXCIyNzEyNVwiKVxuXHRcdFx0XHRcdC5zZXRWYWx1ZShTdHJpbmcodGhpcy5wbHVnaW4uc2V0dGluZ3MucG9ydCkpXG5cdFx0XHRcdFx0Lm9uQ2hhbmdlKGFzeW5jICh2YWx1ZSkgPT4ge1xuXHRcdFx0XHRcdFx0Y29uc3QgcG9ydCA9IHBhcnNlSW50KHZhbHVlKTtcblx0XHRcdFx0XHRcdGlmICghaXNOYU4ocG9ydCkgJiYgcG9ydCA+IDAgJiYgcG9ydCA8IDY1NTM2KSB7XG5cdFx0XHRcdFx0XHRcdHRoaXMucGx1Z2luLnNldHRpbmdzLnBvcnQgPSBwb3J0O1xuXHRcdFx0XHRcdFx0XHRhd2FpdCB0aGlzLnBsdWdpbi5zYXZlU2V0dGluZ3MoKTtcblx0XHRcdFx0XHRcdH1cblx0XHRcdFx0XHR9KVxuXHRcdFx0KTtcblxuXHRcdC8vIFJlc3RhcnQgYnV0dG9uXG5cdFx0bmV3IFNldHRpbmcoY29udGFpbmVyRWwpXG5cdFx0XHQuc2V0TmFtZShcIlJlc3RhcnQgU2VydmVyXCIpXG5cdFx0XHQuc2V0RGVzYyhcIlJlc3RhcnQgdGhlIEhUVFAgc2VydmVyIHdpdGggdGhlIGN1cnJlbnQgcG9ydCBzZXR0aW5nLlwiKVxuXHRcdFx0LmFkZEJ1dHRvbigoYnV0dG9uKSA9PlxuXHRcdFx0XHRidXR0b24uc2V0QnV0dG9uVGV4dChcIlJlc3RhcnRcIikub25DbGljaygoKSA9PiB7XG5cdFx0XHRcdFx0dGhpcy5wbHVnaW4ucmVzdGFydFNlcnZlcigpO1xuXHRcdFx0XHRcdC8vIFJlZnJlc2ggdGhlIGRpc3BsYXkgYWZ0ZXIgYSBtb21lbnRcblx0XHRcdFx0XHRzZXRUaW1lb3V0KCgpID0+IHRoaXMuZGlzcGxheSgpLCA1MDApO1xuXHRcdFx0XHR9KVxuXHRcdFx0KTtcblxuXHRcdC8vIEluZm8gc2VjdGlvblxuXHRcdGNvbnRhaW5lckVsLmNyZWF0ZUVsKFwiaDNcIiwgeyB0ZXh0OiBcIkVuZHBvaW50c1wiIH0pO1xuXHRcdGNvbnN0IGluZm9FbCA9IGNvbnRhaW5lckVsLmNyZWF0ZUVsKFwiZGl2XCIsIHsgY2xzOiBcInNldHRpbmctaXRlbS1kZXNjcmlwdGlvblwiIH0pO1xuXHRcdGluZm9FbC5zdHlsZS5mb250U2l6ZSA9IFwiMTJweFwiO1xuXHRcdGluZm9FbC5pbm5lckhUTUwgPSBgXG5cdFx0XHQ8cD5UaGUgTXVybXVyIEJyaWRnZSBwbHVnaW4gZXhwb3NlcyB0aGVzZSBsb2NhbCBIVFRQIGVuZHBvaW50cyBmb3IgdGhlIE11cm11ciBtYWNPUyBhcHA6PC9wPlxuXHRcdFx0PHVsPlxuXHRcdFx0XHQ8bGk+PGNvZGU+R0VUIC9jdXJzb3I8L2NvZGU+IFx1MjAxNCBDdXJyZW50IGN1cnNvciBwb3NpdGlvbiBhbmQgZmlsZSBwYXRoPC9saT5cblx0XHRcdFx0PGxpPjxjb2RlPlBPU1QgL2hpZ2hsaWdodDwvY29kZT4gXHUyMDE0IEhpZ2hsaWdodCBhIHJhbmdlIG9mIGxpbmVzPC9saT5cblx0XHRcdFx0PGxpPjxjb2RlPlBPU1QgL2NsZWFyLWhpZ2hsaWdodDwvY29kZT4gXHUyMDE0IENsZWFyIGFsbCBoaWdobGlnaHRzPC9saT5cblx0XHRcdFx0PGxpPjxjb2RlPlBPU1QgL25hdmlnYXRlPC9jb2RlPiBcdTIwMTQgTmF2aWdhdGUgdG8gYSBzcGVjaWZpYyBsaW5lPC9saT5cblx0XHRcdDwvdWw+XG5cdFx0XHQ8cD5Vc2UgPHN0cm9uZz5DbWQrT3B0K0Q8L3N0cm9uZz4gaW4gdGhlIE11cm11ciBhcHAgdG8gc3RhcnQgZHJhZnQgZWRpdGluZyB3aXRoIHRoZSBhY3RpdmUgbm90ZS48L3A+XG5cdFx0YDtcblx0fVxufVxuIl0sCiAgIm1hcHBpbmdzIjogIjs7Ozs7Ozs7Ozs7Ozs7Ozs7Ozs7Ozs7Ozs7Ozs7QUFBQTtBQUFBO0FBQUE7QUFBQTtBQUFBO0FBQUEsc0JBQXFFO0FBQ3JFLG1CQUE0RDtBQUM1RCxrQkFBMEY7QUFDMUYsV0FBc0I7QUFJdEIsSUFBTSxxQkFBcUIseUJBQVksT0FBcUM7QUFDNUUsSUFBTSx1QkFBdUIseUJBQVksT0FBYTtBQUd0RCxJQUFJLHVCQUF1QjtBQUMzQixJQUFJLHFCQUFxQjtBQUV6QixJQUFNLGlCQUFpQix3QkFBVyxPQUFzQjtBQUFBLEVBQ3ZELFNBQVM7QUFDUixXQUFPLHVCQUFXO0FBQUEsRUFDbkI7QUFBQSxFQUNBLE9BQU8sYUFBNEIsSUFBaUI7QUFDbkQsa0JBQWMsWUFBWSxJQUFJLEdBQUcsT0FBTztBQUN4QyxlQUFXLFVBQVUsR0FBRyxTQUFTO0FBQ2hDLFVBQUksT0FBTyxHQUFHLG9CQUFvQixHQUFHO0FBQ3BDLHNCQUFjLHVCQUFXO0FBQ3pCLCtCQUF1QjtBQUN2Qiw2QkFBcUI7QUFBQSxNQUN0QjtBQUNBLFVBQUksT0FBTyxHQUFHLGtCQUFrQixHQUFHO0FBQ2xDLGNBQU0sRUFBRSxNQUFNLEdBQUcsSUFBSSxPQUFPO0FBQzVCLCtCQUF1QjtBQUN2Qiw2QkFBcUI7QUFDckIsY0FBTSxNQUFNLEdBQUcsTUFBTTtBQUNyQixjQUFNLFVBQStCLENBQUM7QUFDdEMsaUJBQVMsT0FBTyxNQUFNLFFBQVEsTUFBTSxRQUFRLElBQUksT0FBTyxRQUFRO0FBSTlELGdCQUFNLFdBQVcsSUFBSSxLQUFLLElBQUksRUFBRTtBQUNoQyxjQUFJLFNBQVMsU0FBUyxHQUFHO0FBQUc7QUFFNUIsZ0JB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
