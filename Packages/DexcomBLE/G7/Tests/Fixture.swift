import DexcomBLE
import Foundation
import Testing

/// A recorded session from this target's Fixtures folder.
func fixture(_ name: String) throws -> DexcomSessionLog {
    let url = try #require(Bundle.module.url(forResource: name, withExtension: "log", subdirectory: "Fixtures"))
    return try DexcomSessionLog(parsing: String(contentsOf: url, encoding: .utf8))
}

func hex(_ string: String) -> Data {
    Data(hexadecimalString: string) ?? Data()
}
