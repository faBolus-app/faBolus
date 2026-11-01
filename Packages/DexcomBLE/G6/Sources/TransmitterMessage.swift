//
//  TransmitterCommand.swift
//  xDrip5
//
//  Created by Nathan Racklyeft on 11/22/15.
//  Copyright © 2015 Nathan Racklyeft. All rights reserved.
//

import Foundation

// faBolus: passive mode never writes to the transmitter, so the Tx protocols are omitted.

/// A data sequence received by the transmitter
protocol TransmitterRxMessage {

    init?(data: Data)

}
