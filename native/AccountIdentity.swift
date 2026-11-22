import Cocoa

/// Shared identity DTO. Quota interpretation stays in QuotaPresentation.
struct AccountIdentity {
    let id: String
    let name: String
    let email: String
    let tier: String
    let selectable: Bool

    var displayName: String {
        Self.displayName(name: name, email: email)
    }

    static func normalizeTier(_ raw: String?) -> String {
        let value = (raw ?? "").uppercased()
        if value.contains("ULTRA") { return "ULTRA" }
        if value.contains("ENTERPRISE") { return "ENTERPRISE" }
        if value.contains("TEAM") || value.contains("BUSINESS") || value.contains("WORKSPACE") { return "TEAM" }
        if value.contains("PLUS") { return "PLUS" }
        if value.range(of: "\\bPRO\\b", options: .regularExpression) != nil || value.contains("AI PREMIUM") { return "PRO" }
        if value.contains("FREE") || value.contains("STARTER") || value.contains("TRIAL") { return "FREE" }
        return ""
    }

    static func displayName(name: String?, email: String) -> String {
        let trimmed = (name ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.isEmpty else { return trimmed }
        return email.components(separatedBy: "@").first ?? email
    }

    init(_ raw: [String: Any]) {
        id = raw["id"] as? String ?? ""
        name = (raw["name"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        email = raw["email"] as? String ?? ""
        tier = Self.normalizeTier(raw["subscription_tier"] as? String)
        selectable = raw["disabled"] as? Bool != true
            && raw["validation_blocked"] as? Bool != true
            && (raw["credentialReadiness"] as? [String: Any])?["state"] as? String != "needs_authorization"
    }
}
