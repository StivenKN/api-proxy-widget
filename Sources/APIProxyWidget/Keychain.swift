import Foundation

/// Keeps each hub's management key in the login keychain, through `/usr/bin/security`.
///
/// Going through Apple's tool, the way `gh` and Claude Code do, is what lets a rebuilt widget
/// read the key it saved before. A keychain item only opens silently for the program that
/// created it, and every build of an unsigned app counts as a new program: saving the key from
/// the app itself made macOS ask for the login password after each update, and held the menu
/// bar item back until the answer.
///
/// The key is filed under the hub's address, so pointing the widget at another hub never sends
/// it the first hub's key.
enum Keychain {
    private static let service = "io.github.stivenkn.api-proxy-widget"
    private static let tool = URL(filePath: "/usr/bin/security")

    static func key(for hub: URL) async -> String? {
        let result = await run(["find-generic-password", "-s", service, "-a", hub.absoluteString, "-w"])
        guard result.status == 0 else { return nil }
        return decode(result.output.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    static func setKey(_ key: String, for hub: URL) async -> Bool {
        let account = hub.absoluteString
        // The command goes through stdin so the key never shows up in the process list. The
        // account sits inside double quotes there, so it must not be able to close them.
        guard !key.isEmpty, !account.contains(where: { "\"\\\n".contains($0) }) else { return false }
        let command = "add-generic-password -U -s \"\(service)\" -a \"\(account)\" -w \(encode(key))\n"
        return await run(["-i"], input: command).status == 0
    }

    /// Stored as hex text: it needs no quoting on the way in, and `security` prints it back
    /// unchanged, which it does not do for every byte sequence.
    private static func encode(_ key: String) -> String {
        key.utf8.map { String(format: "%02x", $0) }.joined()
    }

    private static func decode(_ hex: String) -> String? {
        guard !hex.isEmpty, hex.count.isMultiple(of: 2) else { return nil }
        var bytes: [UInt8] = []
        var index = hex.startIndex
        while index < hex.endIndex {
            let next = hex.index(index, offsetBy: 2)
            guard let byte = UInt8(hex[index..<next], radix: 16) else { return nil }
            bytes.append(byte)
            index = next
        }
        return String(bytes: bytes, encoding: .utf8)
    }

    private static func run(_ arguments: [String], input: String? = nil) async -> (status: Int32, output: String) {
        // Detached: waiting for the tool must never hold up the main thread.
        await Task.detached {
            let process = Process()
            process.executableURL = tool
            process.arguments = arguments
            let stdout = Pipe()
            let stdin = Pipe()
            process.standardOutput = stdout
            process.standardError = FileHandle.nullDevice
            process.standardInput = stdin
            do {
                try process.run()
            } catch {
                return (-1, "")
            }
            if let input {
                stdin.fileHandleForWriting.write(Data(input.utf8))
            }
            try? stdin.fileHandleForWriting.close()
            let data = stdout.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            return (process.terminationStatus, String(decoding: data, as: UTF8.self))
        }.value
    }
}
