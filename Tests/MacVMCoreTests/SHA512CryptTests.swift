import XCTest
@testable import MacVMCore

final class SHA512CryptTests: XCTestCase {
    func testKnownLinuxPasswordVectors() throws {
        XCTAssertEqual(try SHA512Crypt.hash(password: "not-a-real-credential", salt: "macvmtestsalt", rounds: 5000),
            "$6$rounds=5000$macvmtestsalt$dGvapm2g/AkHBl7NrOhFEF3fFHcRPAH3ezsB.dialyBvGu0ViD17nT/PCRAbQoiLnHcf8paqf9qgtIY2Q9mD2/")
        XCTAssertEqual(try SHA512Crypt.hash(password: "Türkçe-test-🔒", salt: "macvmtestsalt", rounds: 10000),
            "$6$rounds=10000$macvmtestsalt$treOUIXJrNT6ZVkhaFJvXQcqJ1xksze0vH1bZMKxRx4b0SQmI8ueZqu9t8J3quL1up9zw1iLmk6qG0vhx0Jqq0")
    }
    func testUniqueSaltsAndMalformedInput() throws {
        let first = try SHA512Crypt.hash(password: "not-a-real-credential", rounds: 1000)
        let second = try SHA512Crypt.hash(password: "not-a-real-credential", rounds: 1000)
        XCTAssertNotEqual(first, second)
        XCTAssertThrowsError(try SHA512Crypt.hash(password: "test", salt: "not$a$salt", rounds: 1000))
        XCTAssertThrowsError(try SHA512Crypt.hash(password: "test", salt: "abcdefghijklmnopq", rounds: 1000))
        XCTAssertThrowsError(try SHA512Crypt.hash(password: "a\0b", rounds: 1000))
        XCTAssertThrowsError(try SHA512Crypt.hash(password: "test", rounds: 1))
    }
}
