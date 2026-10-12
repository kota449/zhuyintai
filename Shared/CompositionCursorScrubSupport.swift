// SPDX-License-Identifier: Apache-2.0
import Foundation

struct CompositionCursorMovementPlan: Equatable {
    let consumedOffset: Int
    let remainingOffset: Int

    static func plan(
        requestedOffset: Int,
        cursor: Int,
        compositionLength: Int
    ) -> CompositionCursorMovementPlan {
        let clampedCursor = max(0, min(cursor, compositionLength))
        let targetCursor = max(0, min(clampedCursor + requestedOffset, compositionLength))
        let consumedOffset = targetCursor - clampedCursor
        return CompositionCursorMovementPlan(
            consumedOffset: consumedOffset,
            remainingOffset: requestedOffset - consumedOffset
        )
    }
}

struct MarkedTextSelectionMapper {
    static func insertionLocation(
        for units: [String],
        cursor: Int,
        separatorLength: Int = 1
    ) -> Int {
        guard !units.isEmpty else { return 0 }
        let clampedCursor = max(0, min(cursor, units.count))
        guard clampedCursor > 0 else { return 0 }

        let precedingUnits = units.prefix(clampedCursor)
        let contentLength = precedingUnits.reduce(0) { $0 + $1.count }
        let separatorCount = min(clampedCursor, units.count - 1)
        return contentLength + separatorCount * max(0, separatorLength)
    }
}
