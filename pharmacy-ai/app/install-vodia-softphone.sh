#!/usr/bin/env bash
set -euo pipefail

# ============================================================
# Vodia Phase 2 Softphone Installer
# Installs a native browser WebRTC softphone into vodia-pharmacy-ai
#
# Run from:
#   cd ~/vodia-pharmacy-ai
#   bash install-vodia-softphone.sh
# ============================================================

APP_DIR="${APP_DIR:-$(pwd)}"
BACKUP_DIR="$APP_DIR/backups/vodia-softphone-$(date +%Y%m%d-%H%M%S)"

echo "============================================================"
echo " Vodia Phase 2 Browser Softphone Installer"
echo "============================================================"
echo "Working folder: $APP_DIR"
echo ""

if [ ! -f "$APP_DIR/server.js" ]; then
  echo "ERROR: server.js was not found in this folder."
  echo "Go to your app folder first:"
  echo "  cd ~/vodia-pharmacy-ai"
  exit 1
fi

if [ ! -f "$APP_DIR/package.json" ]; then
  echo "ERROR: package.json was not found in this folder."
  echo "This does not look like your Node app folder."
  exit 1
fi

mkdir -p "$APP_DIR/public/js" "$APP_DIR/routes" "$BACKUP_DIR"

backup_file() {
  local file="$1"
  if [ -f "$file" ]; then
    cp "$file" "$BACKUP_DIR/$(basename "$file").bak"
    echo "Backup: $file"
  fi
}

echo "==> Backing up existing files"
backup_file "$APP_DIR/server.js"
backup_file "$APP_DIR/.env"
backup_file "$APP_DIR/routes/vodia-softphone.js"
backup_file "$APP_DIR/public/js/vodia-softphone.js"
backup_file "$APP_DIR/public/agent-softphone.html"
echo ""

echo "==> Creating backend route: routes/vodia-softphone.js"
cat > "$APP_DIR/routes/vodia-softphone.js" <<'EOF'
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
EOF

echo "==> Creating frontend WebRTC library: public/js/vodia-softphone.js"
cat > "$APP_DIR/public/js/vodia-softphone.js" <<'EOF'
"use strict";

class VodiaSoftphone {
  constructor(options = {}) {
    this.sessionEndpoint = options.sessionEndpoint || "/api/vodia/softphone/session";
    this.remoteAudio = options.remoteAudio || null;

    this.onStatus = options.onStatus || function () {};
    this.onIncoming = options.onIncoming || function () {};
    this.onCallState = options.onCallState || function () {};
    this.onLog = options.onLog || function () {};

    this.socket = null;
    this.peer = null;
    this.localStream = null;
    this.currentCallId = "";
    this.currentCseq = "";
    this.extension = "";
    this.tenantDomain = "";
    this.pbxHost = "";
    this.registerTimer = null;
    this.pendingCandidates = {};
    this.incomingInvite = null;
    this.muted = false;
    this.held = false;
    this.recording = false;
    this.ackSent = false;
  }

  log(...args) {
    const line = args.map(v => {
      if (typeof v === "string") return v;
      try { return JSON.stringify(v); } catch { return String(v); }
    }).join(" ");
    console.log("[VodiaSoftphone]", ...args);
    this.onLog(line);
  }

  setStatus(status, detail) {
    this.onStatus(status, detail || status);
  }

  createCallId() {
    const bytes = new Uint8Array(4);
    crypto.getRandomValues(bytes);
    const hex = Array.from(bytes).map(b => b.toString(16).padStart(2, "0")).join("");
    return `${hex}@app`;
  }

  send(payload) {
    if (!this.socket || this.socket.readyState !== WebSocket.OPEN) {
      throw new Error("Vodia WebSocket is not connected");
    }
    this.log("SEND", payload);
    this.socket.send(JSON.stringify(payload));
  }

  async connect({ extension }) {
    if (!extension) throw new Error("Missing extension");
    this.setStatus("connecting", "Requesting PBX session...");

    const sessRes = await fetch(this.sessionEndpoint, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      credentials: "include",
      body: JSON.stringify({ extension })
    });

    const sess = await sessRes.json();

    if (!sessRes.ok || !sess.success) {
      throw new Error(sess.error || "Could not get Vodia session");
    }

    this.pbxHost = sess.pbxHost;
    this.tenantDomain = sess.tenantDomain;
    this.extension = sess.extension;

    this.setStatus("connecting", "Opening PBX session...");

    await fetch(`https://${this.pbxHost}/rest/system/session`, {
      method: "POST",
      credentials: "include",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({
        name: "session",
        value: sess.session
      })
    }).catch(err => {
      this.log("PBX session POST warning:", err.message);
    });

    const wsUrl =
      `wss://${this.pbxHost}/websocket?domain=${encodeURIComponent(this.tenantDomain)}` +
      `&user=${encodeURIComponent(this.extension)}`;

    this.setStatus("connecting", "Connecting WebSocket...");
    this.socket = new WebSocket(wsUrl);

    this.socket.onopen = () => this.handleSocketOpen();
    this.socket.onmessage = evt => this.handleSocketMessage(evt);
    this.socket.onerror = evt => {
      this.log("WebSocket error", evt);
      this.setStatus("error", "WebSocket error");
    };
    this.socket.onclose = evt => {
      this.log("WebSocket closed", { code: evt.code, reason: evt.reason });
      this.setStatus("disconnected", "Disconnected");
      this.clearRegisterTimer();
    };
  }

  disconnect() {
    this.clearRegisterTimer();
    this.cleanupCall(false);

    if (this.socket) {
      try { this.socket.close(); } catch {}
      this.socket = null;
    }

    this.setStatus("disconnected", "Disconnected");
  }

  handleSocketOpen() {
    this.setStatus("connecting", "Bootstrapping softphone...");

    this.send({ action: "own-calls", subscribe: true });
    this.send({ action: "orbit-calls", subscribe: true });
    this.send({ action: "blf", add: [this.extension] });
    this.send({ action: "ringtones" });
    this.send({ action: "domain-calls", subscribe: true });
    this.registerWebPhone();
  }

  registerWebPhone() {
    this.send({
      action: "sip-register",
      useragent: navigator.userAgent
    });
  }

  clearRegisterTimer() {
    if (this.registerTimer) clearTimeout(this.registerTimer);
    this.registerTimer = null;
  }

  scheduleRegisterRefresh(expires) {
    this.clearRegisterTimer();

    const seconds = Number(expires || 3600);
    const refreshAt = Math.max(30, Math.min(seconds / 2, seconds - 15));

    this.registerTimer = setTimeout(() => {
      if (this.socket && this.socket.readyState === WebSocket.OPEN) {
        this.log("Refreshing Vodia WebRTC registration");
        this.registerWebPhone();
      }
    }, refreshAt * 1000);
  }

  async handleSocketMessage(evt) {
    let msg;

    try {
      msg = JSON.parse(evt.data);
    } catch {
      this.log("Invalid JSON from PBX", evt.data);
      return;
    }

    this.log("RECV", msg);

    if (msg.sdp) {
      await this.handleRemoteSdp(msg);
      return;
    }

    if (msg.invitesdp) {
      this.handleIncomingInvite(msg);
      return;
    }

    if (msg.candidate) {
      await this.handleRemoteCandidate(msg);
      return;
    }

    if (msg.bye) {
      this.handleRemoteBye(msg);
      return;
    }

    switch (msg.action) {
      case "sip-register":
        this.setStatus("registered", `Registered ${msg.add || ""}`.trim());
        this.scheduleRegisterRefresh(msg.expires);
        break;

      case "call-state":
        this.handleCallState(msg);
        break;

      case "callerid":
        this.onCallState({
          callid: msg.callid || this.currentCallId,
          state: "callerid",
          remote: msg.name || msg.number || "-"
        });
        break;

      case "rec-start":
        this.recording = true;
        this.log("Recording started");
        break;

      case "rec-stop":
        this.recording = false;
        this.log("Recording stopped");
        break;

      default:
        break;
    }
  }

  async buildPeer(callid) {
    this.currentCallId = callid;
    this.ackSent = false;

    this.peer = new RTCPeerConnection({
      iceServers: [{ urls: "stun:stun.l.google.com:19302" }]
    });

    this.peer.onicecandidate = evt => {
      if (!evt.candidate) return;

      this.send({
        action: "ice-candidate",
        callid: this.currentCallId,
        candidate: evt.candidate.toJSON()
      });
    };

    this.peer.ontrack = evt => {
      if (this.remoteAudio && evt.streams && evt.streams[0]) {
        this.remoteAudio.srcObject = evt.streams[0];
        this.remoteAudio.play().catch(err => {
          this.log("Audio play warning:", err.message);
        });
      }
    };

    this.peer.onconnectionstatechange = () => {
      this.log("Peer connection state", this.peer.connectionState);

      if (["failed", "closed", "disconnected"].includes(this.peer.connectionState)) {
        this.onCallState({
          callid: this.currentCallId,
          state: this.peer.connectionState,
          remote: "-"
        });
      }
    };

    return this.peer;
  }

  async ensureMicrophone() {
    if (this.localStream) return this.localStream;

    this.localStream = await navigator.mediaDevices.getUserMedia({
      audio: true,
      video: false
    });

    return this.localStream;
  }

  async addLocalTracks() {
    const stream = await this.ensureMicrophone();

    stream.getTracks().forEach(track => {
      this.peer.addTrack(track, stream);
    });
  }

  async makeCall(destination) {
    if (!destination) throw new Error("Missing destination number");

    if (!this.socket || this.socket.readyState !== WebSocket.OPEN) {
      throw new Error("Connect the softphone first");
    }

    const callid = this.createCallId();

    await this.buildPeer(callid);
    await this.addLocalTracks();

    const offer = await this.peer.createOffer({
      offerToReceiveAudio: true,
      offerToReceiveVideo: false
    });

    await this.peer.setLocalDescription(offer);

    this.send({
      action: "sdp-packet",
      callid,
      to: destination,
      sdp: offer
    });

    this.onCallState({
      callid,
      state: "calling",
      remote: destination
    });
  }

  async handleRemoteSdp(msg) {
    if (!this.peer) {
      this.log("Remote SDP arrived but no peer exists yet");
      return;
    }

    await this.peer.setRemoteDescription({
      type: "answer",
      sdp: msg.sdp
    });

    this.currentCseq = msg.cseq || this.currentCseq;

    this.onCallState({
      callid: msg.callid || this.currentCallId,
      state: msg.code === 200 ? "answered" : `progress ${msg.code || ""}`.trim(),
      remote: msg["to-display"] || msg["to-user"] || "-"
    });

    await this.flushPendingCandidates(msg.callid || this.currentCallId);
  }

  handleIncomingInvite(msg) {
    this.incomingInvite = msg;
    this.currentCallId = msg.callid;
    this.currentCseq = msg.cseq;

    this.send({
      action: "sip-ringing",
      callid: msg.callid,
      cseq: msg.cseq
    });

    this.onIncoming({
      callid: msg.callid,
      from: msg.from,
      fromUser: msg["from-user"],
      fromDisplay: msg["from-display"],
      group: msg.group,
      alertinfo: msg.alertinfo
    });

    this.onCallState({
      callid: msg.callid,
      state: "incoming",
      remote: msg["from-display"] || msg["from-user"] || msg.from || "-"
    });
  }

  async acceptIncoming() {
    const invite = this.incomingInvite;
    if (!invite) return;

    await this.buildPeer(invite.callid);

    await this.peer.setRemoteDescription({
      type: "offer",
      sdp: invite.invitesdp
    });

    await this.addLocalTracks();

    const answer = await this.peer.createAnswer();
    await this.peer.setLocalDescription(answer);

    this.send({
      action: "sdp-200ok",
      callid: invite.callid,
      cseq: invite.cseq,
      sdp: answer
    });

    await this.flushPendingCandidates(invite.callid);

    this.onCallState({
      callid: invite.callid,
      state: "answered",
      remote: invite["from-display"] || invite["from-user"] || "-"
    });

    this.incomingInvite = null;
  }

  rejectIncoming() {
    if (!this.incomingInvite) return;

    this.send({
      action: "sip-bye",
      callid: this.incomingInvite.callid
    });

    this.incomingInvite = null;
    this.cleanupCall(false);
  }

  async handleRemoteCandidate(msg) {
    const callid = msg.callid || this.currentCallId;

    if (!this.peer || !this.peer.remoteDescription) {
      if (!this.pendingCandidates[callid]) this.pendingCandidates[callid] = [];
      this.pendingCandidates[callid].push(msg.candidate);
      return;
    }

    await this.peer.addIceCandidate(new RTCIceCandidate({
      candidate: msg.candidate,
      sdpMid: "",
      sdpMLineIndex: 0
    }));
  }

  async flushPendingCandidates(callid) {
    const list = this.pendingCandidates[callid] || [];
    delete this.pendingCandidates[callid];

    for (const candidate of list) {
      try {
        await this.peer.addIceCandidate(new RTCIceCandidate({
          candidate,
          sdpMid: "",
          sdpMLineIndex: 0
        }));
      } catch (err) {
        this.log("Candidate flush failed", err.message);
      }
    }
  }

  handleRemoteBye(msg) {
    this.send({
      action: "bye-response",
      callid: msg.callid,
      cseq: msg.cseq
    });

    this.cleanupCall(false);

    this.onCallState({
      callid: "",
      state: "ended",
      remote: "-"
    });
  }

  handleCallState(msg) {
    const calls = Array.isArray(msg.calls) ? msg.calls : [];
    const active = calls[0];

    if (!active) {
      this.onCallState({
        callid: this.currentCallId,
        state: "idle",
        remote: "-"
      });
      return;
    }

    const state = active.state || active.callstate || "active";
    const remote =
      active["to-name"] ||
      active["to-number"] ||
      active["from-name"] ||
      active["from-number"] ||
      "-";

    this.onCallState({
      callid: this.currentCallId,
      state,
      remote
    });

    if (!this.ackSent && this.currentCallId && String(state).toLowerCase() === "connected") {
      this.send({
        action: "sip-ack",
        callid: this.currentCallId
      });

      this.ackSent = true;
    }
  }

  hangup() {
    if (!this.currentCallId) return;

    this.send({
      action: "sip-bye",
      callid: this.currentCallId
    });

    this.cleanupCall(false);
  }

  cleanupCall(stopSocket) {
    if (this.localStream) {
      this.localStream.getTracks().forEach(track => track.stop());
    }

    if (this.peer) {
      try { this.peer.close(); } catch {}
    }

    this.peer = null;
    this.localStream = null;
    this.currentCallId = "";
    this.currentCseq = "";
    this.incomingInvite = null;
    this.pendingCandidates = {};
    this.muted = false;
    this.held = false;
    this.ackSent = false;

    if (stopSocket && this.socket) {
      try { this.socket.close(); } catch {}
    }

    this.onCallState({
      callid: "",
      state: "idle",
      remote: "-"
    });
  }

  async toggleMute() {
    if (!this.currentCallId) return this.muted;

    this.muted = !this.muted;

    if (this.localStream) {
      this.localStream.getAudioTracks().forEach(track => {
        track.enabled = !this.muted;
      });
    }

    this.send({
      action: "mute",
      callid: this.currentCallId,
      muted: this.muted
    });

    return this.muted;
  }

  async toggleHold() {
    if (!this.currentCallId) return this.held;

    this.held = !this.held;

    this.send({
      action: "wrtc-hold",
      callid: this.currentCallId,
      holdcmd: this.held ? "sendonly" : "sendrecv"
    });

    return this.held;
  }

  toggleRecord() {
    if (!this.currentCallId) return this.recording;

    this.recording = !this.recording;

    this.send({
      action: "rec-call",
      id: this.currentCallId,
      startstop: this.recording ? "on" : "off"
    });

    return this.recording;
  }
}

window.VodiaSoftphone = VodiaSoftphone;
EOF

echo "==> Creating test page: public/agent-softphone.html"
cat > "$APP_DIR/public/agent-softphone.html" <<'EOF'
<!doctype html>
<html lang="en">
<head>
  <meta charset="utf-8" />
  <title>Vodia Agent Softphone</title>
  <meta name="viewport" content="width=device-width, initial-scale=1" />

  <style>
    :root {
      --bg: #0f172a;
      --panel: #111827;
      --card: #1f2937;
      --text: #f9fafb;
      --muted: #9ca3af;
      --line: #374151;
      --good: #22c55e;
      --bad: #ef4444;
      --warn: #f59e0b;
      --blue: #2563eb;
    }

    body {
      margin: 0;
      background: var(--bg);
      color: var(--text);
      font-family: Arial, Helvetica, sans-serif;
    }

    .softphone {
      width: 360px;
      max-width: calc(100vw - 32px);
      margin: 24px auto;
      background: var(--panel);
      border: 1px solid var(--line);
      border-radius: 18px;
      box-shadow: 0 18px 60px rgba(0,0,0,.35);
      overflow: hidden;
    }

    .softphone-header {
      padding: 18px;
      background: linear-gradient(135deg, #111827, #1e3a8a);
      border-bottom: 1px solid var(--line);
    }

    .softphone-title {
      margin: 0;
      font-size: 18px;
      font-weight: 800;
    }

    .softphone-status {
      display: flex;
      gap: 8px;
      align-items: center;
      margin-top: 8px;
      color: var(--muted);
      font-size: 13px;
    }

    .dot {
      width: 10px;
      height: 10px;
      border-radius: 999px;
      background: var(--bad);
    }

    .dot.connected { background: var(--good); }
    .dot.warning { background: var(--warn); }

    .softphone-body { padding: 18px; }

    label {
      display: block;
      font-size: 12px;
      color: var(--muted);
      margin-bottom: 6px;
    }

    input {
      width: 100%;
      box-sizing: border-box;
      background: #030712;
      color: var(--text);
      border: 1px solid var(--line);
      border-radius: 12px;
      padding: 12px;
      font-size: 16px;
      outline: none;
    }

    .row {
      display: flex;
      gap: 10px;
      margin-top: 12px;
    }

    button {
      flex: 1;
      border: 0;
      border-radius: 12px;
      padding: 12px 10px;
      color: white;
      font-weight: 800;
      cursor: pointer;
      background: #374151;
    }

    button:disabled {
      opacity: .45;
      cursor: not-allowed;
    }

    .btn-connect { background: var(--blue); }
    .btn-call { background: var(--good); }
    .btn-hangup { background: var(--bad); }
    .btn-warn { background: var(--warn); color: #111827; }

    .call-card {
      margin-top: 16px;
      padding: 14px;
      background: var(--card);
      border: 1px solid var(--line);
      border-radius: 14px;
      min-height: 74px;
    }

    .call-line {
      display: flex;
      justify-content: space-between;
      gap: 12px;
      font-size: 13px;
      color: var(--muted);
      margin-bottom: 6px;
    }

    .call-line strong { color: var(--text); }

    .incoming {
      display: none;
      margin-top: 14px;
      padding: 14px;
      border: 1px solid var(--warn);
      border-radius: 14px;
      background: rgba(245, 158, 11, .1);
    }

    .incoming.show { display: block; }

    .log {
      margin-top: 14px;
      height: 130px;
      overflow: auto;
      background: #030712;
      border: 1px solid var(--line);
      border-radius: 12px;
      padding: 10px;
      color: var(--muted);
      font-size: 12px;
      white-space: pre-wrap;
    }
  </style>
</head>

<body>
  <div class="softphone">
    <div class="softphone-header">
      <h1 class="softphone-title">Vodia Agent Softphone</h1>
      <div class="softphone-status">
        <span id="statusDot" class="dot"></span>
        <span id="statusText">Disconnected</span>
      </div>
    </div>

    <div class="softphone-body">
      <label for="agentExtension">Agent extension</label>
      <input id="agentExtension" value="501" />

      <div class="row">
        <button id="connectBtn" class="btn-connect">Connect</button>
        <button id="disconnectBtn">Disconnect</button>
      </div>

      <div style="height:14px"></div>

      <label for="destinationNumber">Destination</label>
      <input id="destinationNumber" placeholder="+15555550199 or 500" />

      <div class="row">
        <button id="callBtn" class="btn-call">Call</button>
        <button id="hangupBtn" class="btn-hangup">Hang Up</button>
      </div>

      <div class="row">
        <button id="muteBtn">Mute</button>
        <button id="holdBtn">Hold</button>
        <button id="recordBtn" class="btn-warn">Record</button>
      </div>

      <div id="incomingBox" class="incoming">
        <div class="call-line"><span>Incoming</span><strong id="incomingFrom">Unknown</strong></div>
        <div class="row">
          <button id="answerBtn" class="btn-call">Answer</button>
          <button id="rejectBtn" class="btn-hangup">Reject</button>
        </div>
      </div>

      <div class="call-card">
        <div class="call-line"><span>Call ID</span><strong id="callIdLabel">-</strong></div>
        <div class="call-line"><span>State</span><strong id="callStateLabel">idle</strong></div>
        <div class="call-line"><span>Remote</span><strong id="remoteLabel">-</strong></div>
      </div>

      <div id="log" class="log"></div>

      <audio id="remoteAudio" autoplay></audio>
    </div>
  </div>

  <script src="/js/vodia-softphone.js"></script>
  <script>
    const ui = {
      statusDot: document.getElementById("statusDot"),
      statusText: document.getElementById("statusText"),
      connectBtn: document.getElementById("connectBtn"),
      disconnectBtn: document.getElementById("disconnectBtn"),
      callBtn: document.getElementById("callBtn"),
      hangupBtn: document.getElementById("hangupBtn"),
      muteBtn: document.getElementById("muteBtn"),
      holdBtn: document.getElementById("holdBtn"),
      recordBtn: document.getElementById("recordBtn"),
      answerBtn: document.getElementById("answerBtn"),
      rejectBtn: document.getElementById("rejectBtn"),
      agentExtension: document.getElementById("agentExtension"),
      destinationNumber: document.getElementById("destinationNumber"),
      incomingBox: document.getElementById("incomingBox"),
      incomingFrom: document.getElementById("incomingFrom"),
      callIdLabel: document.getElementById("callIdLabel"),
      callStateLabel: document.getElementById("callStateLabel"),
      remoteLabel: document.getElementById("remoteLabel"),
      log: document.getElementById("log"),
      remoteAudio: document.getElementById("remoteAudio")
    };

    const phone = new VodiaSoftphone({
      sessionEndpoint: "/api/vodia/softphone/session",
      remoteAudio: ui.remoteAudio,
      onStatus: (status, detail) => {
        ui.statusText.textContent = detail || status;
        ui.statusDot.className = "dot" + (
          status === "registered" ? " connected" :
          status === "connecting" ? " warning" : ""
        );
      },
      onIncoming: (call) => {
        ui.incomingBox.classList.add("show");
        ui.incomingFrom.textContent = call.fromDisplay || call.fromUser || call.from || "Unknown";
      },
      onCallState: (state) => {
        ui.callIdLabel.textContent = state.callid || "-";
        ui.callStateLabel.textContent = state.state || "idle";
        ui.remoteLabel.textContent = state.remote || "-";
      },
      onLog: (line) => {
        ui.log.textContent += line + "\n";
        ui.log.scrollTop = ui.log.scrollHeight;
      }
    });

    ui.connectBtn.onclick = () => {
      phone.connect({
        extension: ui.agentExtension.value.trim()
      }).catch(err => alert(err.message));
    };

    ui.disconnectBtn.onclick = () => phone.disconnect();

    ui.callBtn.onclick = () => {
      phone.makeCall(ui.destinationNumber.value.trim()).catch(err => alert(err.message));
    };

    ui.hangupBtn.onclick = () => phone.hangup();

    ui.muteBtn.onclick = async () => {
      const muted = await phone.toggleMute();
      ui.muteBtn.textContent = muted ? "Unmute" : "Mute";
    };

    ui.holdBtn.onclick = async () => {
      const held = await phone.toggleHold();
      ui.holdBtn.textContent = held ? "Resume" : "Hold";
    };

    ui.recordBtn.onclick = () => phone.toggleRecord();

    ui.answerBtn.onclick = async () => {
      ui.incomingBox.classList.remove("show");
      await phone.acceptIncoming();
    };

    ui.rejectBtn.onclick = () => {
      ui.incomingBox.classList.remove("show");
      phone.rejectIncoming();
    };
  </script>
</body>
</html>
EOF

echo "==> Updating .env with softphone keys if missing"
touch "$APP_DIR/.env"

add_env_if_missing() {
  local key="$1"
  local value="$2"

  if ! grep -q "^${key}=" "$APP_DIR/.env"; then
    printf "\n%s=%s\n" "$key" "$value" >> "$APP_DIR/.env"
    echo "Added $key"
  else
    echo "$key already exists"
  fi
}

add_env_if_missing "PBX_BASE_URL" "https://vodiatech.audiomercy.com"
add_env_if_missing "PBX_TENANT" "CHANGE_ME_TENANT_DOMAIN"
add_env_if_missing "PBX_ADMIN_USER" "admin"
add_env_if_missing "PBX_ADMIN_PASS" "CHANGE_ME"
add_env_if_missing "PBX_DEFAULT_EXTENSION" "501"

echo ""
echo "==> Patching server.js safely"

if grep -q 'routes/vodia-softphone' "$APP_DIR/server.js"; then
  echo "server.js already has the Vodia softphone route."
else
  cat >> "$APP_DIR/server.js" <<'EOF'

// Vodia Phase 2 browser softphone route
app.use(require("./routes/vodia-softphone"));

// Make sure public files are available
app.use(express.static("public"));
EOF
  echo "Added softphone route and static public serving to server.js"
fi

echo ""
echo "==> Syntax check"
node -c "$APP_DIR/routes/vodia-softphone.js"
node -c "$APP_DIR/server.js"

echo ""
echo "============================================================"
echo " Install complete"
echo "============================================================"
echo "Backups saved to:"
echo "  $BACKUP_DIR"
echo ""
echo "NOW DO THIS:"
echo ""
echo "1) Edit .env:"
echo "   nano .env"
echo ""
echo "2) Set these values:"
echo "   PBX_BASE_URL=https://vodiatech.audiomercy.com"
echo "   PBX_TENANT=your-vodia-tenant-domain"
echo "   PBX_ADMIN_USER=admin"
echo "   PBX_ADMIN_PASS=your-real-admin-password"
echo "   PBX_DEFAULT_EXTENSION=501"
echo ""
echo "3) Restart the correct PM2 app:"
echo "   pm2 restart vodia-pharmacy-ai"
echo ""
echo "4) Watch logs:"
echo "   pm2 logs vodia-pharmacy-ai --lines 100"
echo ""
echo "5) Test in browser:"
echo "   https://YOUR-PORTAL-DOMAIN/agent-softphone.html"
echo ""
echo "Test extension-to-extension first. Do not start with a customer PSTN call."
echo "============================================================"
