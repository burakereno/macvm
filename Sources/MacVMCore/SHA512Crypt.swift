import Foundation
import CryptoKit

/// Linux SHA-512-crypt, implemented locally so accounts need no host dependency.
/// Specification: https://www.akkadia.org/drepper/SHA-crypt.txt
public enum SHA512Crypt {
    private static let alphabet = Array("./0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz".utf8)

    public static func hash(password: String, salt: String? = nil, rounds: Int = 500_000) throws -> String {
        let passwordBytes = Array(password.utf8)
        guard !passwordBytes.isEmpty, passwordBytes.count <= 1024, !passwordBytes.contains(0),
              (1_000...1_000_000).contains(rounds) else { throw VMError.message("Choose a password between 1 and 1024 bytes.") }
        var random = SystemRandomNumberGenerator()
        let salt = salt ?? String(bytes: (0..<16).map { _ in alphabet.randomElement(using: &random)! }, encoding: .utf8)!
        let saltBytes = Array(salt.utf8)
        guard !saltBytes.isEmpty, saltBytes.count <= 16, saltBytes.allSatisfy({ alphabet.contains($0) }) else {
            throw VMError.message("Invalid account salt.")
        }
        func digest(_ bytes: [UInt8]) -> [UInt8] { Array(SHA512.hash(data: Data(bytes))) }
        func repeated(_ bytes: [UInt8], count: Int) -> [UInt8] {
            (0..<count).map { bytes[$0 % bytes.count] }
        }
        let alternate = digest(passwordBytes + saltBytes + passwordBytes)
        var initial = passwordBytes + saltBytes + repeated(alternate, count: passwordBytes.count)
        var bits = passwordBytes.count
        while bits > 0 { initial += bits & 1 == 1 ? alternate : passwordBytes; bits >>= 1 }
        var result = digest(initial)
        let p = repeated(digest(repeated(passwordBytes, count: passwordBytes.count * passwordBytes.count)), count: passwordBytes.count)
        let s = repeated(digest(repeated(saltBytes, count: saltBytes.count * (16 + Int(result[0])))), count: saltBytes.count)
        var block = [UInt8](); block.reserveCapacity(128 + p.count * 2 + s.count)
        for round in 0..<rounds {
            if round % 1024 == 0 { try Task.checkCancellation() }
            block.removeAll(keepingCapacity: true)
            block += round & 1 == 1 ? p : result
            if round % 3 != 0 { block += s }
            if round % 7 != 0 { block += p }
            block += round & 1 == 1 ? result : p
            result = digest(block)
        }
        var encoded = [UInt8]()
        func append(_ first: UInt8, _ second: UInt8, _ third: UInt8, count: Int) {
            var value = UInt32(first) << 16 | UInt32(second) << 8 | UInt32(third)
            for _ in 0..<count { encoded.append(alphabet[Int(value & 63)]); value >>= 6 }
        }
        for index in stride(from: 0, through: 18, by: 3) {
            append(result[index], result[index + 21], result[index + 42], count: 4)
            append(result[index + 22], result[index + 43], result[index + 1], count: 4)
            append(result[index + 44], result[index + 2], result[index + 23], count: 4)
        }
        append(0, 0, result[63], count: 2)
        return "$6$rounds=\(rounds)$\(salt)$" + String(bytes: encoded, encoding: .utf8)!
    }
}
