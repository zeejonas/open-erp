import Foundation

/// A stage is complete when its approvers can be assigned to its slots, one slot per approver.
func stageIsComplete(approvers: [Set<UUID>], slots: [(groupID: UUID, required: Int)]) -> Bool {
    var seats: [UUID] = []
    for slot in slots {
        for _ in 0..<max(slot.required, 0) {
            seats.append(slot.groupID)
        }
    }
    if seats.isEmpty {
        return true
    }
    var assigned = Array(repeating: -1, count: seats.count)
    var matched = 0
    for approver in approvers.indices {
        var seen = Array(repeating: false, count: seats.count)
        if assign(approver, approvers: approvers, seats: seats, assigned: &assigned, seen: &seen) {
            matched += 1
        }
    }
    return matched == seats.count
}

private func assign(
    _ approver: Int,
    approvers: [Set<UUID>],
    seats: [UUID],
    assigned: inout [Int],
    seen: inout [Bool]
) -> Bool {
    for seat in seats.indices where approvers[approver].contains(seats[seat]) && !seen[seat] {
        seen[seat] = true
        let occupant = assigned[seat]
        if occupant == -1 || assign(occupant, approvers: approvers, seats: seats, assigned: &assigned, seen: &seen) {
            assigned[seat] = approver
            return true
        }
    }
    return false
}
