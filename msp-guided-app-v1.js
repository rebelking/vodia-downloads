const GUIDED_UI_URI = "ui://vodia/msp-guided/v0.14.9.55/mcp-app.html";
const GUIDED_UI_HTML = process.env.VODIA_MSP_GUIDED_UI_HTML || "/opt/vodia-mcp/ui/msp-guided-app.html";

function appResult() {
  // The UI is the result. Keep the tool payload empty so hosts do not have
  // useful raw JSON to repeat above/below the rendered app.
  return { content: [] };
}

export function registerMspGuidedApp(server) {
  server.registerResource(
    "Vodia guided setup",
    GUIDED_UI_URI,
    { mimeType: "text/html;profile=mcp-app" },
    async () => {
      try {
        const { readFile } = await import("node:fs/promises");
        const html = await readFile(GUIDED_UI_HTML, "utf8");
        return {
          contents: [{
            uri: GUIDED_UI_URI,
            mimeType: "text/html;profile=mcp-app",
            text: html,
            _meta: {
              ui: {
                prefersBorder: true
              }
            }
          }]
        };
      } catch (error) {
        throw new Error(`MSP_GUIDED_UI_LOAD_FAILED: ${String(error?.message || error)}`);
      }
    }
  );

  // Friendly, model-visible entry point. Keep this name short because some
  // hosts show the raw tool name in the app frame.
  server.registerTool(
    "vodia_setup",
    {
      title: "Vodia Setup",
      description: "Open the Vodia guided setup app. The app is the user-facing result; do not repeat or summarize its contents in chat unless the user asks.",
      inputSchema: {},
      _meta: {
        ui: {
          resourceUri: GUIDED_UI_URI,
          visibility: ["model", "app"]
        },
        "ui/resourceUri": GUIDED_UI_URI
      },
      annotations: {
        readOnlyHint: true,
        destructiveHint: false,
        openWorldHint: false
      }
    },
    async () => appResult()
  );

  // Backward-compatible alias, hidden from the model so it no longer clutters
  // the normal tool picker. The app may still call it if an older UI needs it.
  server.registerTool(
    "msp_open_guided_setup",
    {
      title: "Open Vodia MSP setup",
      description: "Legacy alias for the Vodia guided setup app.",
      inputSchema: {},
      _meta: {
        ui: {
          resourceUri: GUIDED_UI_URI,
          visibility: ["app"]
        },
        "ui/resourceUri": GUIDED_UI_URI
      },
      annotations: {
        readOnlyHint: true,
        destructiveHint: false,
        openWorldHint: false
      }
    },
    async () => appResult()
  );
}
