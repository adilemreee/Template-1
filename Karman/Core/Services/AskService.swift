import Foundation
import Observation
import Security
import StoreKit

/// Conversation with the planetary-science assistant, authenticated by the app purchase.
@MainActor
@Observable
final class AskService {
    struct Message: Identifiable, Equatable {
        enum Role { case user, assistant }
        let id = UUID()
        var role: Role
        var text: String
        var streaming = false
        var failed = false
        /// Places the answer is about, shown as chips that fly the globe there.
        var focus: [APIClient.GlobeFocus] = []
    }

    private(set) var messages: [Message] = []
    private(set) var isStreaming = false
    private(set) var remaining: Int?
    private(set) var enabled = true
    /// What the user was looking at when they tapped "Ask about this"; sent with every question
    /// until cleared or the conversation is reset.
    private(set) var context: APIClient.AskAbout?
    @ObservationIgnored private var task: Task<Void, Never>?

    func setContext(_ about: APIClient.AskAbout?) {
        if about != context, !messages.isEmpty { reset() }
        context = about
    }

    func send(_ question: String, model: AppModel) {
        let q = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty, !isStreaming else { return }
        messages.append(Message(role: .user, text: q))
        messages.append(Message(role: .assistant, text: "", streaming: true))
        isStreaming = true
        let history = messages.dropLast(2).filter { !$0.failed }.suffix(6).map { APIClient.AskTurn(role: $0.role == .user ? "user" : "assistant", text: $0.text) }
        let loc = model.location.point
        let body = APIClient.AskBody(question: q, language: "en",
                                     lat: loc.map { ($0.lat * 2).rounded() / 2 }, lon: loc.map { ($0.lon * 2).rounded() / 2 },
                                     history: Array(history), about: context)
        task = Task {
            defer { isStreaming = false; finishLast() }
            do {
                let token = try await AuthToken.shared.token()
                for try await event in APIClient.shared.ask(body, token: token) {
                    switch event {
                    case .delta(let t): appendToLast(t)
                    case .focus(let items):
                        setFocusOnLast(items)
                        model.showAskFocus(items)
                    case .done(let left): remaining = left
                    case .failure(let msg): fail(msg)
                    }
                }
            } catch APIClient.APIError.http(let code, _) where code == 429 {
                fail(String(localized: "You've reached today's question limit. It resets at midnight UTC."))
                remaining = 0
            } catch APIClient.APIError.http(let code, _) where code == 503 {
                enabled = false
                fail(String(localized: "Ask Kármán is resting right now. Please try again later."))
            } catch APIClient.APIError.http(let code, _) where code == 401 {
                AuthToken.shared.reset()
                fail(String(localized: "Couldn't verify your purchase. Please try again."))
            } catch {
                fail(String(localized: "Couldn't reach Kármán's servers. Check your connection and try again."))
            }
        }
    }

    func stop() {
        task?.cancel()
        task = nil
        isStreaming = false
        finishLast()
    }

    func reset() {
        stop()
        messages.removeAll()
        context = nil
    }

    func refreshQuota() async {
        guard let token = try? await AuthToken.shared.token(),
              let q = try? await APIClient.shared.askQuota(token: token) else { return }
        remaining = q.remaining
        enabled = q.enabled
    }

    private func setFocusOnLast(_ items: [APIClient.GlobeFocus]) {
        guard let i = messages.indices.last, messages[i].role == .assistant else { return }
        messages[i].focus = items
    }

    private func appendToLast(_ t: String) {
        guard let i = messages.indices.last else { return }
        messages[i].text += t
    }

    private func finishLast() {
        guard let i = messages.indices.last else { return }
        messages[i].streaming = false
        if messages[i].role == .assistant, messages[i].text.isEmpty, !messages[i].failed {
            messages[i].text = String(localized: "…")
        }
    }

    private func fail(_ msg: String) {
        guard let i = messages.indices.last else { return }
        messages[i].text = msg
        messages[i].failed = true
        messages[i].streaming = false
    }
}

/// Exchanges StoreKit's signed AppTransaction for a short-lived API token (stored in the Keychain).
@MainActor
final class AuthToken {
    static let shared = AuthToken()
    private let account = "karman.api.token"
    private var cached: (token: String, expires: Date)?

    func token() async throws -> String? {
        if let c = cached ?? loadKeychain(), c.expires > Date().addingTimeInterval(3600) {
            cached = c
            return c.token
        }
        #if DEBUG
        if !APIClient.shared.devToken.isEmpty { return nil } // the client sends the dev header instead
        #endif
        let result = try await AppTransaction.shared
        let jws: String
        switch result {
        case .verified(let tx): jws = result.jwsRepresentation; _ = tx
        case .unverified: jws = result.jwsRepresentation
        }
        let response = try await APIClient.shared.authenticate(appTransactionJWS: jws)
        cached = (response.token, response.expiresAt)
        saveKeychain(response.token, expires: response.expiresAt)
        return response.token
    }

    func reset() {
        cached = nil
        let q: [CFString: Any] = [kSecClass: kSecClassGenericPassword, kSecAttrAccount: account]
        SecItemDelete(q as CFDictionary)
    }

    private func saveKeychain(_ token: String, expires: Date) {
        reset()
        let payload = "\(Int(expires.timeIntervalSince1970))|\(token)"
        let q: [CFString: Any] = [kSecClass: kSecClassGenericPassword, kSecAttrAccount: account,
                                  kSecValueData: Data(payload.utf8), kSecAttrAccessible: kSecAttrAccessibleAfterFirstUnlock]
        SecItemAdd(q as CFDictionary, nil)
    }

    private func loadKeychain() -> (token: String, expires: Date)? {
        let q: [CFString: Any] = [kSecClass: kSecClassGenericPassword, kSecAttrAccount: account, kSecReturnData: true, kSecMatchLimit: kSecMatchLimitOne]
        var out: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let data = out as? Data,
              let s = String(data: data, encoding: .utf8), let bar = s.firstIndex(of: "|"),
              let ts = Double(s[..<bar]) else { return nil }
        return (String(s[s.index(after: bar)...]), Date(timeIntervalSince1970: ts))
    }
}
