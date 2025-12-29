//
//  Item.swift
//  Gentle Nudge
//
//  Created by Horia Galatanu on 12/28/25.
//

import Foundation
import SwiftData

@Model
final class Item {
    var timestamp: Date
    
    init(timestamp: Date) {
        self.timestamp = timestamp
    }
}
