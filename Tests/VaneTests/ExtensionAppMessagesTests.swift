import AppKit
import WebKit
import XCTest
@testable import vane

@MainActor final class ExtensionAppMessagesTests: XCTestCase {
    private var folder: URL!
    private var pasteboard: NSPasteboard!

    override func setUp() async throws {
        TestEnvironment.prepare()
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("app-messages-\(UUID())")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        // Never the general pasteboard: these tests must not touch the user's clipboard.
        pasteboard = NSPasteboard(name: NSPasteboard.Name("vane-app-messages-\(UUID())"))
    }

    override func tearDown() async throws {
        pasteboard.releaseGlobally()
        try? FileManager.default.removeItem(at: folder)
    }

    private func context(permissions: [String]) async throws -> WKWebExtensionContext {
        try JSONSerialization.data(withJSONObject: ["manifest_version": 3, "name": "App Messages Fixture",
            "version": "1.0", "permissions": permissions]).write(to: folder.appendingPathComponent("manifest.json"))
        let context = WKWebExtensionContext(for: try await WKWebExtension(resourceBaseURL: folder))
        for permission in context.webExtension.requestedPermissions {
            context.setPermissionStatus(.grantedExplicitly, for: permission)
        }
        return context
    }

    private func send(_ messages: ExtensionAppMessages, _ command: String, data: Any? = nil,
                      to application: String = ExtensionAppMessages.bitwarden,
                      from context: WKWebExtensionContext, showPopup: @escaping () -> Void = {}) async throws -> ExtensionAppMessages.Answer {
        var message: [String: Any] = ["id": "1", "command": command, "responseData": NSNull()]
        message["data"] = data ?? NSNull()
        let host = ExtensionAppMessages.Host(name: "Fixture", window: { nil }, isActive: { true }, showPopup: showPopup)
        return try await messages.answer(message, to: application, from: context, host: host)
    }

    private func reply(_ answer: ExtensionAppMessages.Answer) -> Any?? {
        if case .reply(let value) = answer { return .some(value) }
        return nil
    }

    func testCopyIsReadBackOnlyUntilSomethingElseReplacesIt() async throws {
        let messages = ExtensionAppMessages(pasteboard: pasteboard)
        let context = try await context(permissions: ["clipboardWrite"])
        _ = try await send(messages, "copyToClipboard", data: "hunter2", from: context)
        XCTAssertEqual(pasteboard.string(forType: .string), "hunter2")
        XCTAssertTrue(pasteboard.types?.contains(PasswordClipboard.concealed) == true, "Clipboard managers must skip the copy")
        let own = reply(try await send(messages, "readFromClipboard", from: context))
        XCTAssertEqual(own as? String, "hunter2")
        pasteboard.clearContents()
        pasteboard.setString("copied in another app", forType: .string)
        let replaced = reply(try await send(messages, "readFromClipboard", from: context))
        XCTAssertEqual(replaced as? String, "", "Another app's clipboard contents must never reach an extension")
        let other = try await self.context(permissions: ["clipboardWrite"])
        let foreign = reply(try await send(messages, "readFromClipboard", from: other))
        XCTAssertEqual(foreign as? String, "")
    }

    func testCopyNeedsClipboardWriteAndUnknownMessagesAreUnsupported() async throws {
        let messages = ExtensionAppMessages(pasteboard: pasteboard)
        let context = try await context(permissions: [])
        let copied = reply(try await send(messages, "copyToClipboard", data: "secret", from: context))
        XCTAssertTrue(copied == nil, "unsupported")
        XCTAssertNil(pasteboard.string(forType: .string))
        let biometric = reply(try await send(messages, "biometricUnlock", from: context))
        XCTAssertTrue(biometric == nil, "unsupported")
        let otherApp = reply(try await send(messages, "showPopover", to: "com.example.other", from: context))
        XCTAssertTrue(otherApp == nil, "unsupported")
    }

    func testSleepAnswersAfterItsIntervalAndShowPopoverOpensThePopup() async throws {
        let messages = ExtensionAppMessages(pasteboard: pasteboard, sleep: .milliseconds(200))
        let context = try await context(permissions: [])
        let started = ContinuousClock.now
        let slept = reply(try await send(messages, "sleep", from: context))
        XCTAssertTrue(slept != nil, "answered")
        XCTAssertGreaterThanOrEqual(ContinuousClock.now - started, .milliseconds(200))
        nonisolated(unsafe) var shown = 0
        let popover = reply(try await send(messages, "showPopover", from: context) { shown += 1 })
        XCTAssertTrue(popover != nil, "answered")
        XCTAssertEqual(shown, 1)
    }

    func testDownloadDecodesTextAndBase64AndKeepsOnlyTheFileName() throws {
        let text = try XCTUnwrap(ExtensionAppMessages.download(#"{"blobData":"a,b\n1,2","blobOptions":{"type":"text/plain"},"fileName":"../../export.csv"}"#))
        XCTAssertEqual(text.name, "export.csv")
        XCTAssertEqual(String(decoding: text.contents, as: UTF8.self), "a,b\n1,2")
        let binary = try XCTUnwrap(ExtensionAppMessages.download(#"{"blobData":"AAEC","blobOptions":{"type":"application/zip"},"fileName":""}"#))
        XCTAssertEqual(binary.name, "Download")
        XCTAssertEqual(binary.contents, Data([0, 1, 2]))
        XCTAssertNil(ExtensionAppMessages.download(#"{"blobData":"not base64!","blobOptions":{"type":"application/zip"}}"#))
    }
}
