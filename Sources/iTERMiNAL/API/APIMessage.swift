import Foundation

/// One newline-delimited JSON request:
/// `{"id":"1","token":"…","command":"terminal.send","params":{"text":"ls\n"}}`
struct APIRequest {
    let id: String?
    let command: String
    let params: [String: Any]
    let token: String?

    enum DecodingFailure: LocalizedError {
        case malformedJSON
        case missingCommand

        var errorDescription: String? {
            switch self {
            case .malformedJSON: return "Request was not valid JSON."
            case .missingCommand: return "Request is missing a \"command\"."
            }
        }
    }

    init(jsonLine: Data) throws {
        guard let object = try? JSONSerialization.jsonObject(with: jsonLine),
              let dictionary = object as? [String: Any] else {
            throw DecodingFailure.malformedJSON
        }
        guard let command = dictionary["command"] as? String, !command.isEmpty else {
            throw DecodingFailure.missingCommand
        }
        self.command = command
        self.params = dictionary["params"] as? [String: Any] ?? [:]
        self.token = dictionary["token"] as? String
        if let id = dictionary["id"] as? String {
            self.id = id
        } else if let number = dictionary["id"] as? NSNumber {
            self.id = number.stringValue
        } else {
            self.id = nil
        }
    }

    func string(_ key: String) -> String? {
        if let value = params[key] as? String { return value }
        if let value = params[key] as? NSNumber { return value.stringValue }
        return nil
    }

    func bool(_ key: String, default fallback: Bool) -> Bool {
        (params[key] as? Bool) ?? (params[key] as? NSNumber)?.boolValue ?? fallback
    }

    func double(_ key: String, default fallback: Double) -> Double {
        (params[key] as? NSNumber)?.doubleValue ?? fallback
    }
}

/// The reply envelope: `{"id":…,"ok":true,"result":{…}}` or
/// `{"id":…,"ok":false,"error":"…"}`.
struct APIResponse {
    let id: String?
    let ok: Bool
    let result: [String: Any]?
    let error: String?

    static func success(id: String?, _ result: [String: Any] = [:]) -> APIResponse {
        APIResponse(id: id, ok: true, result: result, error: nil)
    }

    static func failure(id: String?, message: String) -> APIResponse {
        APIResponse(id: id, ok: false, result: nil, error: message)
    }

    func jsonLine() -> Data {
        var payload: [String: Any] = ["ok": ok]
        if let id { payload["id"] = id }
        if let result { payload["result"] = result }
        if let error { payload["error"] = error }
        if let data = try? JSONSerialization.data(withJSONObject: payload) {
            return data
        }
        return Data(#"{"ok":false,"error":"Failed to encode response."}"#.utf8)
    }
}
