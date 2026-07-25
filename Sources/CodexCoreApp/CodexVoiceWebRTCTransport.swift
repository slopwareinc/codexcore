import AppKit
import Foundation
@preconcurrency import WebKit

@MainActor
final class CodexVoiceWebRTCTransport: NSObject {
    private let onInputLevel: (Float) -> Void
    private let messageName = "codexVoice"
    private var webView: WKWebView?
    private var containerView: NSView?
    private var offerContinuation: CheckedContinuation<String, Error>?
    private var offerTimeoutTask: Task<Void, Never>?
    private var pendingMicrophoneMuted = false
    private var pendingOutputMuted = false

    init(onInputLevel: @escaping (Float) -> Void) {
        self.onInputLevel = onInputLevel
    }

    func prepareOffer() async throws -> String {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.mediaTypesRequiringUserActionForPlayback = []
        configuration.userContentController.add(self, name: messageName)

        let webView = WKWebView(
            frame: NSRect(x: 0, y: 0, width: 2, height: 2),
            configuration: configuration
        )
        webView.uiDelegate = self
        self.webView = webView
        attach(webView)
        webView.loadHTMLString(Self.page, baseURL: URL(string: "https://codex.local/"))

        return try await withCheckedThrowingContinuation { continuation in
            offerContinuation = continuation
            offerTimeoutTask = Task { [weak self] in
                try? await Task.sleep(for: .seconds(20))
                guard !Task.isCancelled else { return }
                self?.finishOffer(.failure(CodexVoiceWebRTCError.offerTimedOut))
            }
        }
    }

    func applyAnswer(_ sdp: String) {
        evaluate("window.codexVoice?.applyAnswer(\(Self.javascriptString(sdp)))")
    }

    func setMicrophoneMuted(_ muted: Bool) {
        pendingMicrophoneMuted = muted
        evaluate("window.codexVoice?.setMicrophoneMuted(\(muted))")
    }

    func setOutputMuted(_ muted: Bool) {
        pendingOutputMuted = muted
        evaluate("window.codexVoice?.setOutputMuted(\(muted))")
    }

    func stop() {
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
    }

    private func attach(_ webView: WKWebView) {
        guard let parent = NSApp.keyWindow?.contentView ?? NSApp.mainWindow?.contentView else {
            return
        }
        let container = NSView(frame: NSRect(x: -4, y: -4, width: 2, height: 2))
        container.alphaValue = 0.01
        container.addSubview(webView)
        parent.addSubview(container)
        containerView = container
    }

    private func evaluate(_ source: String) {
        webView?.evaluateJavaScript(source)
    }

    private func finishOffer(_ result: Result<String, Error>) {
        guard let continuation = offerContinuation else { return }
        offerContinuation = nil
        offerTimeoutTask?.cancel()
        offerTimeoutTask = nil
        continuation.resume(with: result)
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
          let peer = null;
          let inputStream = null;
          let audioContext = null;
          let levelTimer = null;

          const fail = (error) => post({
            type: "error",
            message: error && error.message ? error.message : String(error)
          });

          async function prepare() {
            inputStream = await navigator.mediaDevices.getUserMedia({
              audio: {
                echoCancellation: true,
                noiseSuppression: true,
                autoGainControl: true
              }
            });

            peer = new RTCPeerConnection();
            for (const track of inputStream.getAudioTracks()) {
              peer.addTrack(track, inputStream);
            }
            peer.createDataChannel("oai-events");
            peer.ontrack = (event) => {
              const audio = document.getElementById("remoteAudio");
              audio.srcObject = event.streams[0];
              audio.play().catch(() => {});
            };
            peer.onconnectionstatechange = () => {
              post({type: "state", value: peer.connectionState});
              if (peer.connectionState === "failed") {
                fail(new Error("WebRTC connection failed"));
              }
            };

            audioContext = new AudioContext();
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

            const offer = await peer.createOffer();
            await peer.setLocalDescription(offer);
            post({type: "offer", sdp: offer.sdp});
          }

          window.codexVoice = {
            async applyAnswer(sdp) {
              try {
                await peer.setRemoteDescription({type: "answer", sdp});
              } catch (error) {
                fail(error);
              }
            },
            setMicrophoneMuted(muted) {
              if (!inputStream) return;
              for (const track of inputStream.getAudioTracks()) {
                track.enabled = !muted;
              }
            },
            setOutputMuted(muted) {
              document.getElementById("remoteAudio").muted = muted;
            },
            stop() {
              if (levelTimer) clearInterval(levelTimer);
              if (inputStream) {
                for (const track of inputStream.getTracks()) track.stop();
              }
              if (peer) peer.close();
              if (audioContext) audioContext.close().catch(() => {});
            }
          };

          prepare().catch(fail);
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
        case "error":
            let detail = body["message"] as? String ?? "Unknown WebRTC error"
            if offerContinuation != nil {
                finishOffer(.failure(CodexVoiceWebRTCError.javascript(detail)))
            }
        default:
            break
        }
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
