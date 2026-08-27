import Foundation
import Darwin

// Command-line client for iTERMiNAL's local socket API.
//
//   iterminalctl ping
//   iterminalctl terminal.send text="ls -la" newline=true
//   iterminalctl browser.open url=localhost:3000
//   iterminalctl browser.click selector="#submit"
//   iterminalctl browser.screenshot path=~/shot.png
//
// The app must have the API enabled (Settings → Security). Authentication
// uses the token file the app writes alongside the socket, readable only by
// this user.

let supportDirectory = FileManager.default
    .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
    .appendingPathComponent("iTERMiNAL", isDirectory: true)

var socketPath = supportDirectory.appendingPathComponent("api.sock").path
var tokenPath = supportDirectory.appendingPathComponent("api.token").path
var rawOutput = false

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(1)
}

func usage() -> Never {
    print("""
    iterminalctl — control a running iTERMiNAL

    Usage:
      iterminalctl <command> [key=value ...] [--raw] [--socket PATH] [--token VALUE]

    Examples:
      iterminalctl help
      iterminalctl tab.create directory=~/code
      iterminalctl terminal.send text="git status" newline=true
      iterminalctl browser.open url=localhost:3000
      iterminalctl browser.fill selector="#email" value=me@example.com
      iterminalctl browser.screenshot path=~/shot.png

    Run "iterminalctl help" against a running app for the full command list.
    """)
    exit(0)
}

// MARK: - Argument parsing

var arguments = Array(CommandLine.arguments.dropFirst())
guard !arguments.isEmpty else { usage() }

var command: String?
var params: [String: Any] = [:]
var explicitToken: String?

var index = 0
while index < arguments.count {
    let argument = arguments[index]
    switch argument {
    case "--help", "-h":
        usage()
    case "--raw":
        rawOutput = true
    case "--socket":
        index += 1
        guard index < arguments.count else { fail("--socket needs a path") }
        socketPath = arguments[index]
    case "--token":
        index += 1
        guard index < arguments.count else { fail("--token needs a value") }
        explicitToken = arguments[index]
    default:
        if command == nil {
            command = argument
        } else if let separator = argument.firstIndex(of: "=") {
            let key = String(argument[argument.startIndex..<separator])
            let value = String(argument[argument.index(after: separator)...])
            // Light coercion so "newline=true" and "timeout=5" arrive typed.
            if value == "true" {
                params[key] = true
            } else if value == "false" {
                params[key] = false
            } else if let number = Double(value) {
                params[key] = number
            } else if value.hasPrefix("~") {
                // Expand here: the app resolves paths relative to its own
                // home, which may not be what the caller meant.
                params[key] = (value as NSString).expandingTildeInPath
            } else {
                params[key] = value
            }
        } else {
            fail("Unexpected argument \"\(argument)\" — parameters look like key=value")
        }
    }
    index += 1
}

guard let command else { usage() }

// MARK: - Token

let token: String
if let explicitToken {
    token = explicitToken
} else if let stored = try? String(contentsOfFile: tokenPath, encoding: .utf8) {
    token = stored.trimmingCharacters(in: .whitespacesAndNewlines)
} else {
    fail("""
    Could not read the API token at \(tokenPath).
    Enable the local API in iTERMiNAL → Settings → Security, or pass --token.
    """)
}

// MARK: - Connect

func connectToSocket(_ path: String) -> Int32 {
    let descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
    guard descriptor >= 0 else { fail("Could not create a socket (errno \(errno))") }

    var address = sockaddr_un()
    address.sun_family = sa_family_t(AF_UNIX)
    let pathBytes = Array(path.utf8)
    let capacity = MemoryLayout.size(ofValue: address.sun_path)
    guard pathBytes.count < capacity else { fail("Socket path is too long: \(path)") }
    withUnsafeMutablePointer(to: &address.sun_path) { pointer in
        pointer.withMemoryRebound(to: UInt8.self, capacity: capacity) { destination in
            for (offset, byte) in pathBytes.enumerated() {
                destination[offset] = byte
            }
            destination[pathBytes.count] = 0
        }
    }

    let size = socklen_t(MemoryLayout<sockaddr_un>.size)
    let connected = withUnsafePointer(to: &address) { pointer in
        pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPointer in
            Darwin.connect(descriptor, sockaddrPointer, size)
        }
    }
    guard connected == 0 else {
        Darwin.close(descriptor)
        fail("""
        Could not reach iTERMiNAL at \(path).
        Is the app running with the local API enabled (Settings → Security)?
        """)
    }
    return descriptor
}

let descriptor = connectToSocket(socketPath)
defer { Darwin.close(descriptor) }

// MARK: - Request / response

var payload: [String: Any] = ["id": "cli", "command": command, "token": token]
if !params.isEmpty { payload["params"] = params }

guard var requestData = try? JSONSerialization.data(withJSONObject: payload) else {
    fail("Could not encode the request")
}
requestData.append(0x0A)

requestData.withUnsafeBytes { buffer in
    guard var base = buffer.baseAddress else { return }
    var remaining = buffer.count
    while remaining > 0 {
        let written = Darwin.write(descriptor, base, remaining)
        if written <= 0 { fail("Could not send the request") }
        remaining -= written
        base = base.advanced(by: written)
    }
}

var responseData = Data()
var chunk = [UInt8](repeating: 0, count: 4096)
while !responseData.contains(0x0A) {
    let count = chunk.withUnsafeMutableBytes { pointer -> Int in
        guard let base = pointer.baseAddress else { return -1 }
        return Darwin.read(descriptor, base, pointer.count)
    }
    if count <= 0 { break }
    responseData.append(contentsOf: chunk[0..<count])
}

guard let newline = responseData.firstIndex(of: 0x0A) else {
    fail("The app closed the connection without replying")
}
let line = responseData.subdata(in: responseData.startIndex..<newline)

guard let object = try? JSONSerialization.jsonObject(with: line),
      let response = object as? [String: Any] else {
    fail("Could not parse the reply: \(String(data: line, encoding: .utf8) ?? "")")
}

if rawOutput {
    print(String(data: line, encoding: .utf8) ?? "")
    exit((response["ok"] as? Bool) == true ? 0 : 1)
}

if (response["ok"] as? Bool) == true {
    let result = response["result"] as? [String: Any] ?? [:]
    if result.isEmpty {
        print("ok")
    } else if let text = result["text"] as? String, result.count == 1 {
        print(text)
    } else if let value = result["value"] as? String, result.count == 1 {
        print(value)
    } else if let pretty = try? JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys]),
              let rendered = String(data: pretty, encoding: .utf8) {
        print(rendered)
    } else {
        print("ok")
    }
    exit(0)
} else {
    fail(response["error"] as? String ?? "The command failed")
}
