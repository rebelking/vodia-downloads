"use strict";

const express = require("express");
const router = express.Router();

const PBX_BASE_URL = (process.env.PBX_BASE_URL || "").replace(/\/+$/, "");
const PBX_TENANT = process.env.PBX_TENANT || "";
const PBX_ADMIN_USER = process.env.PBX_ADMIN_USER || "";
const PBX_ADMIN_PASS = process.env.PBX_ADMIN_PASS || "";
const PBX_DEFAULT_EXTENSION = process.env.PBX_DEFAULT_EXTENSION || "";

/**
 * Creates a temporary Vodia user session for the browser softphone.
 *
 * POST /api/vodia/softphone/session
 * Body: { "extension": "501" }
 *
 * IMPORTANT:
 * Keep this endpoint protected behind your agent login in production.
 * Do NOT expose PBX admin credentials to the browser.
 */
router.post("/api/vodia/softphone/session", express.json(), async (req, res) => {
  try {
    if (!PBX_BASE_URL || !PBX_TENANT || !PBX_ADMIN_USER || !PBX_ADMIN_PASS) {
      return res.status(500).json({
        success: false,
        error: "Missing PBX_BASE_URL, PBX_TENANT, PBX_ADMIN_USER, or PBX_ADMIN_PASS in .env"
      });
    }

    const extension = String(
      req.body.extension ||
      req.user?.extension ||
      PBX_DEFAULT_EXTENSION ||
      ""
    ).trim();

    if (!/^[A-Za-z0-9_.@-]{1,80}$/.test(extension)) {
      return res.status(400).json({
        success: false,
        error: "Invalid or missing extension"
      });
    }

    const token = Buffer
      .from(`${PBX_ADMIN_USER}:${PBX_ADMIN_PASS}`)
      .toString("base64");

    const pbxResponse = await fetch(`${PBX_BASE_URL}/rest/system/session`, {
      method: "POST",
      headers: {
        "Authorization": `Basic ${token}`,
        "Content-Type": "application/json"
      },
      body: JSON.stringify({
        name: "3rd",
        username: extension,
        domain: PBX_TENANT
      })
    });

    const raw = (await pbxResponse.text()).trim();
    const session = raw.replace(/^"|"$/g, "");

    if (!pbxResponse.ok || !session || session === "false") {
      return res.status(502).json({
        success: false,
        error: "Vodia did not return a valid third-party session",
        status: pbxResponse.status,
        pbxReply: raw
      });
    }

    const pbxHost = new URL(PBX_BASE_URL).host;

    return res.json({
      success: true,
      pbxHost,
      tenantDomain: PBX_TENANT,
      extension,
      session
    });
  } catch (err) {
    console.error("Vodia softphone session error:", err);
    return res.status(500).json({
      success: false,
      error: err.message || "Unknown server error"
    });
  }
});

module.exports = router;
