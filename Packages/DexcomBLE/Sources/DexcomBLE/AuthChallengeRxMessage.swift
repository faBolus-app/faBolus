//
//  AuthChallengeRxMessage.swift
//  xDrip5
//
//  Created by Nathan Racklyeft on 11/22/15.
//  Copyright © 2015 Nathan Racklyeft. All rights reserved.
//

import Foundation

// faBolus: shared by G6 and G7, whose copies upstream are identical apart from the protocol they
// conform to. Read-only here: the Dexcom app's own authentication result, observed on the shared link.
package struct AuthChallengeRxMessage: Sendable {
    /// The `authChallengeRx` opcode, the same on G6 and G7.
    static let opcode: UInt8 = 0x05

    package let isAuthenticated: Bool
    package let isBonded: Bool

    package init?(data: Data) {
        guard data.count >= 3 else {
            return nil
        }

        guard data[data.startIndex] == Self.opcode else {
            return nil
        }

        isAuthenticated = data[data.startIndex + 1] == 0x1
        isBonded = data[data.startIndex + 2] == 0x1
    }
}
