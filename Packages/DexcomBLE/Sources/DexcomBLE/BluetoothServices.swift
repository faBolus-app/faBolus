//
//  BluetoothServices.swift
//  xDripG5
//
//  Created by Nathan Racklyeft on 10/16/15.
//  Copyright © 2015 Nathan Racklyeft. All rights reserved.
//

import CoreBluetooth

/*
G5 BLE attributes, retrieved using LightBlue on 2015-10-01

These are the G4 details, for reference:
https://github.com/StephenBlackWasAlreadyTaken/xDrip/blob/af20e32652d19aa40becc1a39f6276cad187fdce/app/src/main/java/com/eveningoutpost/dexdrip/UtilityModels/DexShareAttributes.java
*/

package protocol CBUUIDRawValue: RawRepresentable {}
extension CBUUIDRawValue where RawValue == String {
    package var cbUUID: CBUUID {
        return CBUUID(string: rawValue)
    }
}


package enum TransmitterServiceUUID: String, CBUUIDRawValue {
    case deviceInfo = "180A"
    case advertisement = "FEBC"
    case cgmService = "F8083532-849E-531C-C594-30F1F86A4EA5"

    case serviceB = "F8084532-849E-531C-C594-30F1F86A4EA5"
}


package enum CGMServiceCharacteristicUUID: String, CBUUIDRawValue {

    // Read/Notify
    case communication = "F8083533-849E-531C-C594-30F1F86A4EA5"

    // Write/Indicate
    case control = "F8083534-849E-531C-C594-30F1F86A4EA5"

    // Write/Indicate
    case authentication = "F8083535-849E-531C-C594-30F1F86A4EA5"

    // Read/Write/Notify
    case backfill = "F8083536-849E-531C-C594-30F1F86A4EA5"

    //    // Unknown attribute present on older G6 transmitters
    //    case unknown1 = "F8083537-849E-531C-C594-30F1F86A4EA5"
    //
    //    // Updated G6 characteristic (read/notify)
    //    case unknown2 = "F8083538-849E-531C-C594-30F1F86A4EA5"
}
