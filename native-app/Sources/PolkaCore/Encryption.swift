import CCommonCrypto
import CryptoKit
import Darwin
import Foundation
import Security

public protocol EncryptionCodec {
  func encode(_ plaintext: Data) throws -> Data
  func decode(_ ciphertext: Data) throws -> Data
}
/// Keychain-backed v10 envelope: PBKDF2-SHA1 (saltysalt, 1003), AES-128-CBC,
/// PKCS#7 padding and sixteen ASCII spaces as IV.
public final class NativeKeychainCodec: EncryptionCodec {
  private let password: () throws -> Data
  private var cachedKey: Data?
  private let lock = NSRecursiveLock()
  public init(password: @escaping () throws -> Data) { self.password = password }
  /// No Keychain access occurs until first encode/decode. Call only after the app's notice.
  public convenience init(
    service: String = "polka Safe Storage", account: String = "polka", allowCreate: Bool = false
  ) {
    self.init {
      try Self.keychainPassword(service: service, account: account, allowCreate: allowCreate)
    }
  }
  private static func keychainPassword(service: String, account: String, allowCreate: Bool) throws
    -> Data
  {
    let query: [String: Any] = [
      kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
      kSecAttrAccount as String: account, kSecReturnData as String: true,
      kSecMatchLimit as String: kSecMatchLimitOne,
    ]
    var result: CFTypeRef?
    let status = SecItemCopyMatching(query as CFDictionary, &result)
    if status == errSecSuccess, let data = result as? Data, !data.isEmpty { return data }
    guard status == errSecItemNotFound && allowCreate else {
      throw PolkaCoreError.storage(
        "Не удалось получить ключ шифрования из Связки ключей (\(status))")
    }
    var bytes = [UInt8](repeating: 0, count: 16)
    guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else {
      throw PolkaCoreError.storage("Не удалось создать ключ шифрования")
    }
    let data = Data(Data(bytes).base64EncodedString().utf8)
    let add: [String: Any] = [
      kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
      kSecAttrAccount as String: account, kSecValueData as String: data,
    ]
    let saved = SecItemAdd(add as CFDictionary, nil)
    if saved == errSecDuplicateItem {
      return try keychainPassword(service: service, account: account, allowCreate: false)
    }
    guard saved == errSecSuccess else {
      throw PolkaCoreError.storage("Не удалось сохранить ключ шифрования (\(saved))")
    }
    return data
  }
  private func key() throws -> Data {
    if let cachedKey { return cachedKey }
    let password = try password()
    guard !password.isEmpty else { throw PolkaCoreError.storage("Ключ шифрования недоступен") }
    let salt = Data("saltysalt".utf8)
    var bytes = [UInt8](repeating: 0, count: 16)
    let status = password.withUnsafeBytes { passwordBytes in
      salt.withUnsafeBytes { saltBytes in
        CCKeyDerivationPBKDF(
          CCPBKDFAlgorithm(kCCPBKDF2),
          passwordBytes.baseAddress!.assumingMemoryBound(to: Int8.self), password.count,
          saltBytes.baseAddress!.assumingMemoryBound(to: UInt8.self), salt.count,
          CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA1), 1003, &bytes, bytes.count)
      }
    }
    guard status == kCCSuccess else {
      throw PolkaCoreError.storage("Не удалось получить ключ шифрования")
    }
    let key = Data(bytes)
    cachedKey = key
    return key
  }
  private func crypt(_ input: Data, operation: CCOperation) throws -> Data {
    let key = try key()
    let iv = [UInt8](repeating: 32, count: 16)
    let capacity = input.count + kCCBlockSizeAES128
    var output = [UInt8](repeating: 0, count: capacity)
    var count = 0
    let status = key.withUnsafeBytes { keyBytes in
      input.withUnsafeBytes { inputBytes in
        CCCrypt(
          operation, CCAlgorithm(kCCAlgorithmAES), CCOptions(kCCOptionPKCS7Padding),
          keyBytes.baseAddress, key.count, iv, inputBytes.baseAddress, input.count, &output,
          capacity, &count)
      }
    }
    guard status == kCCSuccess else {
      throw PolkaCoreError.storage("Не удалось расшифровать данные")
    }
    return Data(output.prefix(count))
  }
  public func encode(_ plaintext: Data) throws -> Data {
    lock.lock()
    defer { lock.unlock() }
    return Data("v10".utf8) + (try crypt(plaintext, operation: CCOperation(kCCEncrypt)))
  }
  public func decode(_ ciphertext: Data) throws -> Data {
    lock.lock()
    defer { lock.unlock() }
    guard ciphertext.prefix(3) == Data("v10".utf8), ciphertext.count > 3,
      (ciphertext.count - 3) % 16 == 0
    else { throw PolkaCoreError.storage("Неизвестный формат зашифрованного файла") }
    let plaintext = try crypt(Data(ciphertext.dropFirst(3)), operation: CCOperation(kCCDecrypt))
    guard String(data: plaintext, encoding: .utf8) != nil else {
      throw PolkaCoreError.storage("Некорректные зашифрованные данные")
    }
    return plaintext
  }
}
/// Authenticated codec for isolated synthetic profiles. Never uses the user's Keychain.
public struct SyntheticEncryptionCodec: EncryptionCodec {
  private let key: SymmetricKey
  public init(key: Data) { self.key = SymmetricKey(data: key) }
  public func encode(_ plaintext: Data) throws -> Data {
    try AES.GCM.seal(plaintext, using: key).combined!
  }
  public func decode(_ ciphertext: Data) throws -> Data {
    try AES.GCM.open(AES.GCM.SealedBox(combined: ciphertext), using: key)
  }
}

/// Only a genuinely absent file starts a new store; permission and other read failures remain fatal.
public func readEncryptedFile(_ path: URL, maximumBytes: Int) throws -> Data? {
  var info = stat()
  let status = path.path.withCString { fstatat(AT_FDCWD, $0, &info, 0) }
  if status != 0 {
    if errno == ENOENT { return nil }
    throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
  }
  guard info.st_size >= 0, info.st_size <= Int64(maximumBytes) else {
    throw PolkaCoreError.invalid("Файл истории слишком большой")
  }
  return try Data(contentsOf: path)
}
