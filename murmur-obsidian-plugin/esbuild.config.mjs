import esbuild from "esbuild";

esbuild.build({
	entryPoints: ["main.ts"],
	bundle: true,
	external: ["obsidian", "electron", "@codemirror/state", "@codemirror/view"],
	format: "cjs",
	target: "es2018",
	logLevel: "info",
	sourcemap: "inline",
	outfile: "main.js",
	platform: "node",
}).catch(() => process.exit(1));
