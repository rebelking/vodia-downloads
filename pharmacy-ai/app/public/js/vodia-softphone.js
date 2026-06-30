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
