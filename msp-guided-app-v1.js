const GUIDED_UI_URI = "ui://vodia/msp-guided/mcp-app.html";
const GUIDED_UI_HTML = process.env.VODIA_MSP_GUIDED_UI_HTML || "/opt/vodia-mcp/ui/msp-guided-app.html";

export function registerMspGuidedApp(server, ctx) {
  const { toolOutputSchema, scopedSuccess, failure } = ctx;

  server.registerResource(
    "Vodia MSP guided setup",
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
            _meta: { ui: { prefersBorder: true } }
          }]
        };
      } catch (error) {
        throw new Error(`MSP_GUIDED_UI_LOAD_FAILED: ${String(error?.message || error)}`);
      }
    }
  );

  server.registerTool(
    "msp_open_guided_setup",
    {
      title: "Open Vodia MSP setup",
      description: "Opens a guided visual setup for organizations and customers so users do not need to type raw UUIDs or tool arguments.",
      inputSchema: {},
      outputSchema: toolOutputSchema,
      _meta: {
        ui: { resourceUri: GUIDED_UI_URI },
        "ui/resourceUri": GUIDED_UI_URI
      },
      annotations: {
        readOnlyHint: true,
        destructiveHint: false,
        openWorldHint: false
      }
    },
    async () => {
      try {
        return scopedSuccess(
          {
            guidedSetup: {
              resourceUri: GUIDED_UI_URI,
              capabilities: [
                "identity",
                "list-organizations",
                "create-organization",
                "list-customers",
                "create-customer",
                "check-customer-aws"
              ]
            },
            changesMade: false
          },
          { operation: "MSP_GUIDED_SETUP_OPEN", readOnly: true },
          "Vodia MSP guided setup is ready."
        );
      } catch (error) {
        return failure(error, "MSP guided setup");
      }
    }
  );
}
