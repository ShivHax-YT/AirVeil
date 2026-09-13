import Foundation
import Security

// Dedicated development identity only. Passwords are read privately, never
// passed on command lines. No trust anchors or system keychains are modified.
func check(_ status: OSStatus, _ operation: String) {
    guard status == errSecSuccess else {
        fputs("\(operation) failed (\(status)): \(SecCopyErrorMessageString(status, nil) as String? ?? "Security error")\n", stderr)
        exit(1)
    }
}
guard CommandLine.arguments.count >= 3 else { exit(2) }
let action = CommandLine.arguments[1]
let directory = URL(fileURLWithPath: CommandLine.arguments[2], isDirectory: true)
let password = try Data(contentsOf: directory.appendingPathComponent("keychain-password"))
let path = directory.appendingPathComponent("AirVeil.keychain-db").path
var keychain: SecKeychain?
if action == "create" {
    // SecKeychainCreate may add its result to the search list. Restore the
    // original list: builds always specify this private keychain explicitly.
    var originalSearchList: CFArray?
    check(SecKeychainCopySearchList(&originalSearchList), "Read keychain search list")
    let result = password.withUnsafeBytes {
        SecKeychainCreate(path, UInt32(password.count), $0.baseAddress, false, nil, &keychain)
    }
    if let originalSearchList { check(SecKeychainSetSearchList(originalSearchList), "Restore keychain search list") }
    check(result, "Create development keychain")
    var trustedApp: SecTrustedApplication?
    check(SecTrustedApplicationCreateFromPath("/usr/bin/codesign", &trustedApp), "Locate codesign")
    var access: SecAccess?
    check(SecAccessCreate("AirVeil local development signing" as CFString, [trustedApp!] as CFArray, &access), "Restrict signing key access")
    var parameters = SecItemImportExportKeyParameters()
    parameters.version = UInt32(SEC_KEY_IMPORT_EXPORT_PARAMS_VERSION)
    parameters.accessRef = Unmanaged.passUnretained(access!)
    let usage = [kSecAttrCanSign] as CFArray
    let attributes = [kSecAttrIsPermanent, kSecAttrIsSensitive] as CFArray
    parameters.keyUsage = Unmanaged.passUnretained(usage)
    parameters.keyAttributes = Unmanaged.passUnretained(attributes)
    let contents = try Data(contentsOf: directory.appendingPathComponent("identity.p12"))
    var format = SecExternalFormat.formatPKCS12
    var type = SecExternalItemType.itemTypeAggregate
    // Keep the bridged password alive for the complete import call.
    let passphrase = String(decoding: password, as: UTF8.self) as CFString
    parameters.passphrase = Unmanaged.passUnretained(passphrase)
    check(withExtendedLifetime((passphrase, access, usage, attributes)) {
        SecItemImport(contents as CFData, "p12" as CFString, &format, &type, [], &parameters, keychain, nil)
    }, "Import development identity")
} else if action == "unlock" || action == "sign" {
    check(SecKeychainOpen(path, &keychain), "Open development keychain")
    check(password.withUnsafeBytes {
        SecKeychainUnlock(keychain, UInt32(password.count), $0.baseAddress, true)
    }, "Unlock development keychain")
} else { exit(2) }

if action == "sign" {
    guard CommandLine.arguments.count == 4 else { exit(2) }
    let fingerprint = try String(contentsOf: directory.appendingPathComponent("identity-sha1"), encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
    guard fingerprint.count == 40, fingerprint.allSatisfy({ $0.isHexDigit }) else { exit(2) }
    var originalSearchList: CFArray?
    check(SecKeychainCopySearchList(&originalSearchList), "Read keychain search list")
    let original = (originalSearchList as? [SecKeychain]) ?? []
    // codesign also uses the search list to locate the certificate chain, even
    // when --keychain explicitly selects the private signing identity.
    check(SecKeychainSetSearchList((original + [keychain!]) as CFArray), "Temporarily locate signing certificate")
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
    process.arguments = ["--force", "--sign", fingerprint, "--keychain", path, "--timestamp=none", CommandLine.arguments[3]]
    var signingStatus: Int32 = 1
    do {
        try process.run()
        process.waitUntilExit()
        signingStatus = process.terminationStatus
    } catch { fputs("Could not launch codesign.\n", stderr) }
    if let originalSearchList { check(SecKeychainSetSearchList(originalSearchList), "Restore keychain search list") }
    check(SecKeychainLock(keychain), "Lock development keychain")
    exit(signingStatus)
}
