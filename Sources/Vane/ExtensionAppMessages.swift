import AppKit
import WebKit

/// Answers native messages that Safari builds of extensions send to the app they ship in,
/// for the commands Vane can carry out itself.
///
/// Safari hands `runtime.sendNativeMessage` to the app extension's handler. Only Safari may
/// load another developer's handler (PlugInKit requires a private entitlement), so in Vane
/// those messages would otherwise fail and take features with them that never needed the
/// app: copying a password, opening the popup, saving an export.
///
/// Keyed by the application identifier the extension addresses, then its `command`. That
/// identifier is only what the extension *claims* to talk to, so every command is limited to
/// what the extension could already do or what the user does explicitly.
@MainActor final class ExtensionAppMessages {
    enum Answer { case reply(Any?), unsupported }

    /// Bitwarden's Safari app, `SafariApp.sendMessageToApp` in its extension.
    static let bitwarden = "com.bitwarden.desktop"

    /// What Bitwarden's other builds wait between vault-timeout checks; its Safari build
    /// loops on `sleep` instead of a timer.
    static let sleepInterval: Duration = .seconds(10)

    private struct Copy { let text: String; let changeCount: Int }
    private var copies: [ObjectIdentifier: Copy] = [:]
    private let pasteboard: NSPasteboard
    private let sleep: Duration
    private var saving = false

    init(pasteboard: NSPasteboard = .general, sleep: Duration = sleepInterval) {
        self.pasteboard = pasteboard
        self.sleep = sleep
    }

    /// What the browser supplies for one message: who sent it, where a sheet may attach,
    /// whether the extension is still enabled once the user has answered, and its popup.
    struct Host {
        let name: String
        let window: () -> NSWindow?
        let isActive: () -> Bool
        let showPopup: () -> Void
    }

    func answer(_ message: Any, to application: String?, from context: WKWebExtensionContext,
                host: Host) async throws -> Answer {
        guard application == Self.bitwarden, let message = message as? [String: Any],
              let command = message["command"] as? String else { return .unsupported }
        let data = message["data"]
        switch command {
        case "sleep":
            try await Task.sleep(for: sleep)
            return .reply(nil)
        case "copyToClipboard":
            guard context.hasPermission(.clipboardWrite), let text = data as? String else { return .unsupported }
            // Concealed, as for Vane's own passwords: clipboard managers skip the entry.
            copies[ObjectIdentifier(context)] = Copy(text: text, changeCount: PasswordClipboard.write(text, to: pasteboard))
            return .reply(nil)
        case "readFromClipboard":
            // Bitwarden reads only to clear the clipboard if it still holds what it copied.
            // Answer with that copy while nothing else has replaced it, and never with
            // anything another app put there: Vane has no clipboard-read permission to grant.
            let copy = copies[ObjectIdentifier(context)]
            return .reply(copy?.changeCount == pasteboard.changeCount ? copy?.text : "")
        case "showPopover":
            host.showPopup()
            return .reply(nil)
        case "downloadFile":
            // One sheet at a time: a second request while one is open is refused rather than
            // stacking panels the user has to work through.
            guard !saving, let json = data as? String, let file = Self.download(json) else { return .unsupported }
            saving = true
            defer { saving = false }
            await save(file, for: host)
            return .reply(nil)
        default:
            return .unsupported
        }
    }

    func forget(_ context: WKWebExtensionContext) { copies[ObjectIdentifier(context)] = nil }

    /// `{"blobData": text or base64, "blobOptions": {"type": …}, "fileName": …}`.
    static func download(_ json: String) -> (name: String, contents: Data)? {
        guard let object = try? JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any],
              let blob = object["blobData"] as? String else { return nil }
        let type = (object["blobOptions"] as? [String: Any])?["type"] as? String
        let contents = type == "text/plain" ? Data(blob.utf8) : Data(base64Encoded: blob)
        guard let contents else { return nil }
        // A name only, never a path; URL(fileURLWithPath:) would resolve "" to the current directory.
        let name = ((object["fileName"] as? String ?? "") as NSString).lastPathComponent
        return (["", ".", "..", "/"].contains(name) ? "Download" : name, contents)
    }

    /// The user picks where an export goes, on a sheet naming the extension that asked; an
    /// extension never writes a file on its own.
    private func save(_ file: (name: String, contents: Data), for host: Host) async {
        guard let window = host.window() else { return }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = file.name
        panel.message = "“\(host.name)” wants to save “\(file.name)”."
        let response = await withCheckedContinuation { continuation in
            panel.beginSheetModal(for: window) { continuation.resume(returning: $0) }
        }
        guard response == .OK, host.isActive(), let url = panel.url else { return }
        do { try file.contents.write(to: url, options: .atomic) }
        catch { NSLog("Vane: could not save an extension download: \(error.localizedDescription)") }
    }
}
