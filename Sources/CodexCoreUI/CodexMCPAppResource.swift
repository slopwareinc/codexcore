import Foundation
import CodexCore

/// Validated resource content. Remote HTML never receives a native bridge directly.
struct CodexMCPAppResource: Sendable, Equatable {
    static let maximumBytes = 2 * 1_024 * 1_024
    let html: String
    let csp: CodexMCPAppCSP

    init(response: CodexJSONValue, uri: String) throws {
        guard URL(string: uri)?.scheme?.lowercased() == "ui" else {
            throw CodexIntegrationControlPlaneError("MCP app resources must use a ui:// URI.")
        }
        let typed = try JSONDecoder().decode(CodexSchemaMCPResourceReadResponse.self, from: JSONEncoder().encode(response))
        guard let content = typed.contents.first(where: { $0.rawValue.objectValue?["uri"] == .string(uri) })?.rawValue.objectValue else {
            throw CodexIntegrationControlPlaneError("The server did not return the requested MCP app resource.")
        }
        guard case .string(let mime)? = content["mimeType"],
              mime.lowercased().replacingOccurrences(of: " ", with: "") == "text/html;profile=mcp-app" else {
            throw CodexIntegrationControlPlaneError("The resource is not an MCP app HTML document.")
        }
        let data: Data
        if case .string(let text)? = content["text"] {
            data = Data(text.utf8)
        } else if case .string(let blob)? = content["blob"], blob.utf8.count <= Self.maximumBytes * 2,
                  let decoded = Data(base64Encoded: blob) { data = decoded }
        else { throw CodexIntegrationControlPlaneError("The MCP app resource has no valid HTML content.") }
        guard data.count <= Self.maximumBytes, let html = String(data: data, encoding: .utf8) else {
            throw CodexIntegrationControlPlaneError("The MCP app resource exceeds the size limit or is not UTF-8.")
        }
        self.html = html
        csp = try .init(metadata: content["_meta"])
    }

    /// An opaque-origin sandbox prevents app code from reaching the wrapper's native handler.
    /// Only messages from this exact iframe are forwarded; native code also rejects subframe handlers.
    func wrapperHTML() -> String {
        let policy = csp.policy.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "\"", with: "&quot;")
        let document = "<!doctype html><meta http-equiv=\"Content-Security-Policy\" content=\"\(policy)\">" + html
        let encoded = Data(document.utf8).base64EncodedString()
        return """
        <!doctype html><html><head><meta name="viewport" content="width=device-width,initial-scale=1">
        <style>html,body,iframe{margin:0;width:100%;height:100%;border:0;background:transparent}body{overflow:hidden}</style></head><body>
        <iframe id="app" sandbox="allow-scripts" referrerpolicy="no-referrer"></iframe>
        <script>
        (()=>{const frame=document.getElementById('app');
          window.addEventListener('message',e=>{
            if(e.source!==frame.contentWindow||!e.data||typeof e.data!=='object'||e.data.jsonrpc!=='2.0')return;
            try{if(JSON.stringify(e.data).length>262144)return;window.webkit.messageHandlers.codexMCPApp.postMessage(e.data);}catch(_){}
          });
          window.codexDeliver=message=>frame.contentWindow.postMessage(message,'*');
          frame.srcdoc=new TextDecoder().decode(Uint8Array.from(atob('\(encoded)'),c=>c.charCodeAt(0)));
        })();
        </script></body></html>
        """
    }
}

struct CodexMCPAppCSP: Sendable, Equatable {
    let connectDomains: [String]
    let resourceDomains: [String]
    let frameDomains: [String]
    let baseURIDomains: [String]

    init(metadata: CodexJSONValue?) throws {
        let fields = metadata?.objectValue?["ui"]?.objectValue?["csp"]?.objectValue ?? [:]
        func domains(_ key: String, webSockets: Bool = false) throws -> [String] {
            guard let value = fields[key] else { return [] }
            guard case .array(let values) = value, values.count <= 64 else {
                throw CodexIntegrationControlPlaneError("Invalid MCP app CSP domain list.")
            }
            return try values.map { value in
                guard case .string(let domain) = value, let components = URLComponents(string: domain),
                      let scheme = components.scheme?.lowercased(), (scheme == "https" || (webSockets && scheme == "wss")),
                      let host = components.host, !host.isEmpty, !host.contains("*"),
                      components.user == nil, components.password == nil,
                      (components.path.isEmpty || components.path == "/"), components.query == nil, components.fragment == nil,
                      !domain.contains(where: { $0.isWhitespace || $0 == ";" || $0 == "'" || $0 == "\"" }) else {
                    throw CodexIntegrationControlPlaneError("MCP app CSP domains must be explicit HTTPS origins.")
                }
                return "\(scheme)://\(host)" + (components.port.map { ":\($0)" } ?? "")
            }
        }
        connectDomains = try domains("connectDomains", webSockets: true)
        resourceDomains = try domains("resourceDomains")
        frameDomains = try domains("frameDomains")
        baseURIDomains = try domains("baseUriDomains")
    }

    var policy: String {
        func source(_ values: [String]) -> String { values.isEmpty ? "'none'" : values.joined(separator: " ") }
        let resources = resourceDomains.joined(separator: " ")
        return "default-src 'none'; script-src 'unsafe-inline' \(resources); style-src 'unsafe-inline' \(resources); "
            + "img-src data: \(resources); media-src data: \(resources); font-src \(source(resourceDomains)); "
            + "connect-src \(source(connectDomains)); frame-src \(source(frameDomains)); base-uri \(source(baseURIDomains)); object-src 'none'; form-action 'none'"
    }

    var capabilityValue: CodexJSONValue {
        .dictionary(["connectDomains": .array(connectDomains.map(CodexJSONValue.string)),
                     "resourceDomains": .array(resourceDomains.map(CodexJSONValue.string)),
                     "frameDomains": .array(frameDomains.map(CodexJSONValue.string)),
                     "baseUriDomains": .array(baseURIDomains.map(CodexJSONValue.string))])
    }
}
