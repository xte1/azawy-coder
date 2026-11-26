import Foundation
import Security
import SwiftUI

// MARK: - Certificate model

struct SigningCertificate: Codable, Identifiable, Hashable {
    var id = UUID()
    var name: String
    var subject: String
    var teamName: String
    var profileName: String
    var profileAppID: String
    var expiresAt: Date?
    var deviceCount: Int?
    var createdAt = Date()

    var isExpired: Bool { (expiresAt ?? .distantFuture) < Date() }

    /// Bundle identifier fixed by the provisioning profile ("*" for wildcard profiles).
    var profileBundleID: String {
        guard let dot = profileAppID.firstIndex(of: ".") else { return profileAppID }
        return String(profileAppID[profileAppID.index(after: dot)...])
    }
}

struct ProvisioningInfo {
    let name: String
    let teamName: String
    let appID: String
    let expiresAt: Date?
    let deviceCount: Int?
    let certificates: [Data]
}

enum SigningError: LocalizedError {
    case wrongPassword
    case invalidP12
    case invalidProfile

    var errorDescription: String? {
        switch self {
        case .wrongPassword: return "كلمة مرور ملف الشهادة (.p12) غير صحيحة."
        case .invalidP12: return "تعذر قراءة ملف الشهادة. تأكد أنه ملف .p12 صالح."
        case .invalidProfile: return "تعذر قراءة ملف الـ Provisioning Profile. تأكد أنه ملف .mobileprovision."
        }
    }
}

enum SigningParser {
    /// Validates a .p12 file and returns the certificate's subject summary and DER data.
    static func inspectP12(_ data: Data, password: String) throws -> (subject: String, der: Data) {
        var items: CFArray?
        let status = SecPKCS12Import(
            data as CFData,
            [kSecImportExportPassphrase as String: password] as CFDictionary,
            &items
        )
        if status == errSecAuthFailed { throw SigningError.wrongPassword }
        guard status == errSecSuccess,
              let array = items as? [[String: Any]],
              let first = array.first,
              let identityAny = first[kSecImportItemIdentity as String] else {
            throw SigningError.invalidP12
        }
        let identity = identityAny as! SecIdentity
        var certificate: SecCertificate?
        SecIdentityCopyCertificate(identity, &certificate)
        guard let certificate else { throw SigningError.invalidP12 }
        let subject = SecCertificateCopySubjectSummary(certificate) as String? ?? "Certificate"
        return (subject, SecCertificateCopyData(certificate) as Data)
    }

    /// Reads the XML plist embedded inside a CMS-signed .mobileprovision file.
    static func inspectProfile(_ data: Data) throws -> ProvisioningInfo {
        guard let start = data.range(of: Data("<?xml".utf8)),
              let end = data.range(of: Data("</plist>".utf8)) else {
            throw SigningError.invalidProfile
        }
        let plistData = data.subdata(in: start.lowerBound..<end.upperBound)
        guard let plist = try? PropertyListSerialization.propertyList(from: plistData, options: [], format: nil) as? [String: Any] else {
            throw SigningError.invalidProfile
        }
        let entitlements = plist["Entitlements"] as? [String: Any] ?? [:]
        let appID = entitlements["application-identifier"] as? String ?? ""
        return ProvisioningInfo(
            name: plist["Name"] as? String ?? "Profile",
            teamName: plist["TeamName"] as? String ?? "",
            appID: appID,
            expiresAt: plist["ExpirationDate"] as? Date,
            deviceCount: (plist["ProvisionedDevices"] as? [String])?.count,
            certificates: plist["DeveloperCertificates"] as? [Data] ?? []
        )
    }
}

// MARK: - Certificate store (metadata in UserDefaults, secrets in Keychain)

@MainActor
final class CertificateStore: ObservableObject {
    @Published private(set) var certificates: [SigningCertificate] = []
    private let defaultsKey = "signingCertificates"

    init() {
        if let data = UserDefaults.standard.data(forKey: defaultsKey),
           let decoded = try? JSONDecoder().decode([SigningCertificate].self, from: data) {
            certificates = decoded
        }
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(certificates) {
            UserDefaults.standard.set(data, forKey: defaultsKey)
        }
    }

    func add(name: String, p12: Data, password: String, profile: Data) throws -> (SigningCertificate, warning: String?) {
        let p12Info = try SigningParser.inspectP12(p12, password: password)
        let profileInfo = try SigningParser.inspectProfile(profile)

        var warning: String?
        if !profileInfo.certificates.isEmpty && !profileInfo.certificates.contains(p12Info.der) {
            warning = "تنبيه: الشهادة داخل ملف p12 ليست ضمن الشهادات المرتبطة بملف الـ Provisioning Profile. قد يفشل التوقيع."
        }
        if let expiry = profileInfo.expiresAt, expiry < Date() {
            warning = "تنبيه: ملف الـ Provisioning Profile منتهي الصلاحية."
        }

        let cert = SigningCertificate(
            name: name.isEmpty ? p12Info.subject : name,
            subject: p12Info.subject,
            teamName: profileInfo.teamName,
            profileName: profileInfo.name,
            profileAppID: profileInfo.appID,
            expiresAt: profileInfo.expiresAt,
            deviceCount: profileInfo.deviceCount
        )

        try KeychainStore.save(p12, account: "cert-p12-\(cert.id)")
        try KeychainStore.saveString(password, account: "cert-pass-\(cert.id)")
        try KeychainStore.save(profile, account: "cert-profile-\(cert.id)")

        certificates.append(cert)
        persist()
        return (cert, warning)
    }

    func remove(_ cert: SigningCertificate) {
        KeychainStore.delete(account: "cert-p12-\(cert.id)")
        KeychainStore.delete(account: "cert-pass-\(cert.id)")
        KeychainStore.delete(account: "cert-profile-\(cert.id)")
        certificates.removeAll { $0.id == cert.id }
        persist()
    }

    func secrets(for cert: SigningCertificate) -> (p12: Data, password: String, profile: Data)? {
        guard let p12 = KeychainStore.load(account: "cert-p12-\(cert.id)"),
              let password = KeychainStore.loadString(account: "cert-pass-\(cert.id)"),
              let profile = KeychainStore.load(account: "cert-profile-\(cert.id)") else { return nil }
        return (p12, password, profile)
    }
}
