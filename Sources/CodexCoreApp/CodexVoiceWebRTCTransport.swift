import AppKit
import Foundation
@preconcurrency import WebKit

@MainActor
final class CodexVoiceWebRTCTransport: NSObject {
    private let threadID: String
    private let onInputLevel: (Float) -> Void
    private let logSessionID = UUID().uuidString
    private let messageName = "codexVoice"
    private var webView: WKWebView?
    private var containerView: NSView?
    private var offerContinuation: CheckedContinuation<String, Error>?
    private var offerTimeoutTask: Task<Void, Never>?
    private var pendingMicrophoneMuted = false
    private var pendingOutputMuted = false

    init(
        threadID: String,
        onInputLevel: @escaping (Float) -> Void
    ) {
        self.threadID = threadID
        self.onInputLevel = onInputLevel
    }

    func prepareOffer() async throws -> String {
        log("webrtc.prepare.begin", level: .notice)
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.mediaTypesRequiringUserActionForPlayback = []
        configuration.userContentController.add(self, name: messageName)

        let webView = WKWebView(
            frame: NSRect(x: 0, y: 0, width: 2, height: 2),
            configuration: configuration
        )
        webView.uiDelegate = self
        webView.navigationDelegate = self
        self.webView = webView
        attach(webView)
        log("webrtc.page.load.begin")
        webView.loadHTMLString(Self.page, baseURL: URL(string: "https://codex.local/"))

        return try await withCheckedThrowingContinuation { continuation in
            offerContinuation = continuation
            offerTimeoutTask = Task { [weak self] in
                try? await Task.sleep(for: .seconds(20))
                guard !Task.isCancelled else { return }
                self?.log("webrtc.offer.timeout", level: .error)
                self?.finishOffer(.failure(CodexVoiceWebRTCError.offerTimedOut))
            }
        }
    }

    func applyAnswer(_ sdp: String) {
        log(
            "webrtc.answer.apply.requested",
            level: .notice,
            fields: [
                "sdp": sdp,
                "sdpBytes": String(sdp.utf8.count),
            ]
        )
        evaluate("window.codexVoice?.applyAnswer(\(Self.javascriptString(sdp)))")
    }

    func setMicrophoneMuted(_ muted: Bool) {
        log("webrtc.microphone.mute_changed", fields: ["muted": String(muted)])
        pendingMicrophoneMuted = muted
        evaluate("window.codexVoice?.setMicrophoneMuted(\(muted))")
    }

    func setOutputMuted(_ muted: Bool) {
        log("webrtc.output.mute_changed", fields: ["muted": String(muted)])
        pendingOutputMuted = muted
        evaluate("window.codexVoice?.setOutputMuted(\(muted))")
    }

    func stop() {
        log("webrtc.stop.requested", level: .notice)
        offerTimeoutTask?.cancel()
        offerTimeoutTask = nil
        if offerContinuation != nil {
            finishOffer(.failure(CancellationError()))
        }
        evaluate("window.codexVoice?.stop()")
        webView?.configuration.userContentController.removeScriptMessageHandler(
            forName: messageName
        )
        webView?.removeFromSuperview()
        containerView?.removeFromSuperview()
        webView = nil
        containerView = nil
        onInputLevel(0)
        log("webrtc.stop.complete", level: .notice)
    }

    private func attach(_ webView: WKWebView) {
        guard let parent = NSApp.keyWindow?.contentView ?? NSApp.mainWindow?.contentView else {
            log("webrtc.webview.attach.failed", level: .error)
            return
        }
        let container = NSView(frame: NSRect(x: -4, y: -4, width: 2, height: 2))
        container.alphaValue = 0.01
        container.addSubview(webView)
        parent.addSubview(container)
        containerView = container
        log(
            "webrtc.webview.attached",
            fields: [
                "containerAlpha": String(describing: container.alphaValue),
                "window": parent.window?.title ?? "",
            ]
        )
    }

    private func evaluate(_ source: String) {
        webView?.evaluateJavaScript(source) { [weak self] _, error in
            guard let error else { return }
            Task { @MainActor [weak self] in
                self?.log(
                    "webrtc.javascript.evaluate.failed",
                    level: .error,
                    fields: ["error": String(describing: error)]
                )
            }
        }
    }

    private func finishOffer(_ result: Result<String, Error>) {
        guard let continuation = offerContinuation else { return }
        offerContinuation = nil
        offerTimeoutTask?.cancel()
        offerTimeoutTask = nil
        switch result {
        case .success(let sdp):
            log(
                "webrtc.offer.ready",
                level: .notice,
                fields: ["sdpBytes": String(sdp.utf8.count)]
            )
        case .failure(let error):
            log(
                "webrtc.offer.failed",
                level: .error,
                fields: ["error": String(describing: error)]
            )
        }
        continuation.resume(with: result)
    }

    private func log(
        _ event: String,
        level: CodexVoiceLog.Level = .info,
        fields: [String: String] = [:]
    ) {
        var enriched = fields
        enriched["webrtcLogSessionID"] = logSessionID
        enriched["threadID"] = threadID
        CodexVoiceLog.write(event, level: level, fields: enriched)
    }

    private static func logField(_ value: Any) -> String {
        if JSONSerialization.isValidJSONObject(value),
           let data = try? JSONSerialization.data(
            withJSONObject: value,
            options: [.sortedKeys]
           ),
           let text = String(data: data, encoding: .utf8) {
            return text
        }
        return String(describing: value)
    }

    private static func javascriptString(_ string: String) -> String {
        guard let data = try? JSONEncoder().encode(string),
              let encoded = String(data: data, encoding: .utf8)
        else {
            return "\"\""
        }
        return encoded
    }

    private static let page = """
    <!doctype html>
    <html>
    <body>
      <audio id="remoteAudio" autoplay playsinline></audio>
      <script>
        (() => {
          const bridge = window.webkit.messageHandlers.codexVoice;
          const post = (value) => bridge.postMessage(value);
          const log = (event, fields = {}) => post({type: "log", event, fields});
          let peer = null;
          let dataChannel = null;
          let inputStream = null;
          let audioContext = null;
          let levelTimer = null;
          let statsTimer = null;
          let outputMuted = false;
          const remoteAudio = document.getElementById("remoteAudio");

          const trackSummary = (track) => track ? {
            id: track.id,
            kind: track.kind,
            label: track.label,
            enabled: track.enabled,
            muted: track.muted,
            readyState: track.readyState,
            settings: typeof track.getSettings === "function" ? track.getSettings() : {}
          } : null;

          const audioElementSummary = () => ({
            autoplay: remoteAudio.autoplay,
            currentTime: remoteAudio.currentTime,
            duration: remoteAudio.duration,
            ended: remoteAudio.ended,
            error: remoteAudio.error ? {
              code: remoteAudio.error.code,
              message: remoteAudio.error.message
            } : null,
            muted: remoteAudio.muted,
            networkState: remoteAudio.networkState,
            paused: remoteAudio.paused,
            readyState: remoteAudio.readyState,
            sinkId: remoteAudio.sinkId || "",
            srcObjectTracks: remoteAudio.srcObject
              ? remoteAudio.srcObject.getTracks().map(trackSummary)
              : [],
            volume: remoteAudio.volume
          });

          const fail = (error, context = "") => {
            const message = error && error.message ? error.message : String(error);
            log("error", {
              context,
              message,
              name: error && error.name ? error.name : "",
              stack: error && error.stack ? error.stack : ""
            });
            post({type: "error", message});
          };

          for (const eventName of [
            "abort", "canplay", "canplaythrough", "emptied", "ended", "error",
            "loadeddata", "loadedmetadata", "loadstart", "pause", "play",
            "playing", "stalled", "suspend", "volumechange", "waiting"
          ]) {
            remoteAudio.addEventListener(eventName, () => {
              log(`audio.element.${eventName}`, audioElementSummary());
            });
          }

          async function playRemoteAudio(reason) {
            remoteAudio.muted = outputMuted;
            remoteAudio.volume = 1;
            log("audio.play.requested", {
              reason,
              ...audioElementSummary()
            });
            try {
              await remoteAudio.play();
              log("audio.play.resolved", {
                reason,
                ...audioElementSummary()
              });
            } catch (error) {
              fail(error, `audio.play:${reason}`);
            }
          }

          async function reportStats() {
            if (!peer) return;
            try {
              const reports = [];
              const stats = await peer.getStats();
              for (const report of stats.values()) {
                if (report.type === "inbound-rtp" && report.kind === "audio") {
                  reports.push({
                    type: report.type,
                    kind: report.kind,
                    audioLevel: report.audioLevel,
                    bytesReceived: report.bytesReceived,
                    concealedSamples: report.concealedSamples,
                    jitter: report.jitter,
                    jitterBufferDelay: report.jitterBufferDelay,
                    jitterBufferEmittedCount: report.jitterBufferEmittedCount,
                    packetsLost: report.packetsLost,
                    packetsReceived: report.packetsReceived,
                    silentConcealedSamples: report.silentConcealedSamples,
                    totalAudioEnergy: report.totalAudioEnergy,
                    totalSamplesDuration: report.totalSamplesDuration
                  });
                } else if (
                  report.type === "candidate-pair" &&
                  (report.nominated || report.state === "succeeded")
                ) {
                  reports.push({
                    type: report.type,
                    availableIncomingBitrate: report.availableIncomingBitrate,
                    bytesReceived: report.bytesReceived,
                    bytesSent: report.bytesSent,
                    currentRoundTripTime: report.currentRoundTripTime,
                    nominated: report.nominated,
                    state: report.state
                  });
                } else if (
                  report.type === "remote-inbound-rtp" &&
                  report.kind === "audio"
                ) {
                  reports.push({
                    type: report.type,
                    kind: report.kind,
                    jitter: report.jitter,
                    packetsLost: report.packetsLost,
                    roundTripTime: report.roundTripTime
                  });
                }
              }
              log("stats", {
                audio: audioElementSummary(),
                connectionState: peer.connectionState,
                iceConnectionState: peer.iceConnectionState,
                iceGatheringState: peer.iceGatheringState,
                reports,
                signalingState: peer.signalingState
              });
            } catch (error) {
              fail(error, "getStats");
            }
          }

          async function prepare() {
            log("page.ready", {
              audioContextAvailable: typeof AudioContext !== "undefined",
              documentVisibility: document.visibilityState,
              mediaDevicesAvailable: Boolean(navigator.mediaDevices),
              secureContext: window.isSecureContext,
              userAgent: navigator.userAgent
            });
            log("microphone.getUserMedia.begin");
            inputStream = await navigator.mediaDevices.getUserMedia({
              audio: {
                echoCancellation: true,
                noiseSuppression: true,
                autoGainControl: true
              }
            });
            log("microphone.getUserMedia.complete", {
              tracks: inputStream.getTracks().map(trackSummary)
            });

            peer = new RTCPeerConnection();
            log("peer.created", {
              configuration: peer.getConfiguration()
            });
            for (const track of inputStream.getAudioTracks()) {
              peer.addTrack(track, inputStream);
              log("peer.local_track.added", {
                track: trackSummary(track)
              });
            }
            dataChannel = peer.createDataChannel("oai-events");
            dataChannel.onopen = () => log("data_channel.open", {
              bufferedAmount: dataChannel.bufferedAmount,
              id: dataChannel.id,
              label: dataChannel.label,
              protocol: dataChannel.protocol
            });
            dataChannel.onclose = () => log("data_channel.close");
            dataChannel.onerror = (event) => log("data_channel.error", {
              error: event.error ? String(event.error) : ""
            });
            dataChannel.onmessage = (event) => log("data_channel.message", {
              bytes: typeof event.data === "string"
                ? event.data.length
                : event.data && event.data.byteLength
                  ? event.data.byteLength
                  : 0,
              data: typeof event.data === "string" ? event.data : "<binary>"
            });
            peer.ontrack = (event) => {
              const stream = event.streams[0] || new MediaStream([event.track]);
              log("peer.remote_track", {
                receiverTrack: trackSummary(event.receiver.track),
                streams: event.streams.map(value => ({
                  id: value.id,
                  tracks: value.getTracks().map(trackSummary)
                })),
                track: trackSummary(event.track),
                transceiver: {
                  currentDirection: event.transceiver.currentDirection,
                  direction: event.transceiver.direction,
                  mid: event.transceiver.mid
                }
              });
              event.track.onmute = () => log("peer.remote_track.mute", {
                track: trackSummary(event.track)
              });
              event.track.onunmute = () => {
                log("peer.remote_track.unmute", {
                  track: trackSummary(event.track)
                });
                playRemoteAudio("track-unmute");
              };
              event.track.onended = () => log("peer.remote_track.ended", {
                track: trackSummary(event.track)
              });
              remoteAudio.srcObject = stream;
              playRemoteAudio("ontrack");
            };
            peer.onconnectionstatechange = () => {
              log("peer.connection_state", {value: peer.connectionState});
              post({type: "state", value: peer.connectionState});
              if (peer.connectionState === "failed") {
                fail(new Error("WebRTC connection failed"), "connectionstatechange");
              }
            };
            peer.oniceconnectionstatechange = () => log(
              "peer.ice_connection_state",
              {value: peer.iceConnectionState}
            );
            peer.onicegatheringstatechange = () => log(
              "peer.ice_gathering_state",
              {value: peer.iceGatheringState}
            );
            peer.onsignalingstatechange = () => log(
              "peer.signaling_state",
              {value: peer.signalingState}
            );
            peer.onicecandidate = (event) => log("peer.ice_candidate", {
              candidate: event.candidate ? event.candidate.candidate : "",
              complete: event.candidate == null,
              sdpMid: event.candidate ? event.candidate.sdpMid : "",
              sdpMLineIndex: event.candidate
                ? event.candidate.sdpMLineIndex
                : null
            });
            peer.onnegotiationneeded = () => log("peer.negotiation_needed");

            audioContext = new AudioContext();
            log("input_audio_context.created", {state: audioContext.state});
            if (audioContext.state === "suspended") {
              await audioContext.resume();
              log("input_audio_context.resumed", {state: audioContext.state});
            }
            const source = audioContext.createMediaStreamSource(inputStream);
            const analyser = audioContext.createAnalyser();
            analyser.fftSize = 256;
            source.connect(analyser);
            const samples = new Uint8Array(analyser.fftSize);
            levelTimer = setInterval(() => {
              analyser.getByteTimeDomainData(samples);
              let energy = 0;
              for (const sample of samples) {
                const normalized = (sample - 128) / 128;
                energy += normalized * normalized;
              }
              post({
                type: "level",
                value: Math.min(1, Math.sqrt(energy / samples.length) * 5)
              });
            }, 50);
            statsTimer = setInterval(reportStats, 1000);

            log("offer.create.begin");
            const offer = await peer.createOffer();
            log("offer.create.complete", {
              sdp: offer.sdp,
              sdpBytes: offer.sdp.length,
              type: offer.type
            });
            await peer.setLocalDescription(offer);
            log("offer.local_description.set", {
              sdp: peer.localDescription ? peer.localDescription.sdp : "",
              signalingState: peer.signalingState
            });
            post({type: "offer", sdp: offer.sdp});
          }

          window.codexVoice = {
            async applyAnswer(sdp) {
              try {
                log("answer.apply.begin", {
                  sdp,
                  sdpBytes: sdp.length,
                  signalingState: peer ? peer.signalingState : ""
                });
                await peer.setRemoteDescription({type: "answer", sdp});
                log("answer.apply.complete", {
                  receivers: peer.getReceivers().map(receiver => ({
                    track: trackSummary(receiver.track)
                  })),
                  signalingState: peer.signalingState,
                  transceivers: peer.getTransceivers().map(transceiver => ({
                    currentDirection: transceiver.currentDirection,
                    direction: transceiver.direction,
                    mid: transceiver.mid,
                    receiverTrack: trackSummary(transceiver.receiver.track),
                    senderTrack: trackSummary(transceiver.sender.track)
                  }))
                });
                if (remoteAudio.srcObject) {
                  await playRemoteAudio("answer-applied");
                }
              } catch (error) {
                fail(error, "applyAnswer");
              }
            },
            setMicrophoneMuted(muted) {
              log("microphone.mute_changed", {muted});
              if (!inputStream) return;
              for (const track of inputStream.getAudioTracks()) {
                track.enabled = !muted;
              }
            },
            setOutputMuted(muted) {
              outputMuted = muted;
              remoteAudio.muted = muted;
              log("audio.output_mute_changed", {
                muted,
                ...audioElementSummary()
              });
              if (!muted && remoteAudio.srcObject) {
                playRemoteAudio("output-unmuted");
              }
            },
            stop() {
              log("stop.begin");
              if (levelTimer) clearInterval(levelTimer);
              if (statsTimer) clearInterval(statsTimer);
              if (inputStream) {
                for (const track of inputStream.getTracks()) track.stop();
              }
              if (peer) peer.close();
              if (audioContext) audioContext.close().catch(() => {});
              remoteAudio.pause();
              remoteAudio.srcObject = null;
              log("stop.complete");
            }
          };

          prepare().catch(error => fail(error, "prepare"));
        })();
      </script>
    </body>
    </html>
    """
}

extension CodexVoiceWebRTCTransport: WKScriptMessageHandler {
    nonisolated func userContentController(
        _ userContentController: WKUserContentController,
        didReceive message: WKScriptMessage
    ) {
        MainActor.assumeIsolated { [weak self] in
            self?.receiveScriptMessage(message.body)
        }
    }

    private func receiveScriptMessage(_ value: Any) {
        guard let body = value as? [String: Any],
              let type = body["type"] as? String
        else { return }

        switch type {
        case "offer":
            guard let sdp = body["sdp"] as? String, !sdp.isEmpty else {
                finishOffer(.failure(CodexVoiceWebRTCError.invalidOffer))
                return
            }
            finishOffer(.success(sdp))
            setMicrophoneMuted(pendingMicrophoneMuted)
            setOutputMuted(pendingOutputMuted)
        case "level":
            if let value = body["value"] as? Double {
                onInputLevel(Float(value))
            }
        case "state":
            log(
                "webrtc.peer.state",
                fields: ["value": body["value"] as? String ?? ""]
            )
        case "log":
            let event = body["event"] as? String ?? "unknown"
            let rawFields = body["fields"] as? [String: Any] ?? [:]
            let fields = rawFields.mapValues { Self.logField($0) }
            log("webrtc.js.\(event)", fields: fields)
        case "error":
            let detail = body["message"] as? String ?? "Unknown WebRTC error"
            log(
                "webrtc.javascript.error",
                level: .error,
                fields: ["message": detail]
            )
            if offerContinuation != nil {
                finishOffer(.failure(CodexVoiceWebRTCError.javascript(detail)))
            }
        default:
            break
        }
    }
}

extension CodexVoiceWebRTCTransport: WKNavigationDelegate {
    func webView(
        _ webView: WKWebView,
        didFinish navigation: WKNavigation!
    ) {
        log("webrtc.page.load.complete", level: .notice)
    }

    func webView(
        _ webView: WKWebView,
        didFail navigation: WKNavigation!,
        withError error: Error
    ) {
        log(
            "webrtc.page.load.failed",
            level: .error,
            fields: ["error": String(describing: error)]
        )
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        log("webrtc.page.process_terminated", level: .error)
    }
}

extension CodexVoiceWebRTCTransport: WKUIDelegate {
    func webView(
        _ webView: WKWebView,
        requestMediaCapturePermissionFor origin: WKSecurityOrigin,
        initiatedByFrame frame: WKFrameInfo,
        type: WKMediaCaptureType,
        decisionHandler: @escaping @MainActor @Sendable (WKPermissionDecision) -> Void
    ) {
        log(
            "webrtc.media_permission.requested",
            fields: [
                "host": origin.host,
                "type": String(describing: type),
            ]
        )
        decisionHandler(.grant)
    }
}

private enum CodexVoiceWebRTCError: LocalizedError {
    case invalidOffer
    case javascript(String)
    case offerTimedOut

    var errorDescription: String? {
        switch self {
        case .invalidOffer:
            "Voice could not create a WebRTC offer."
        case .javascript(let detail):
            "Voice WebRTC failed: \(detail)"
        case .offerTimedOut:
            "Voice WebRTC setup timed out."
        }
    }
}
