import Foundation

/// Keeps the calls that switch macOS's secure keyboard input on and off
/// balanced. Foundation only, so the bookkeeping is checked off a Mac;
/// `SecureKeyboardEntry` makes the calls.
///
/// The system switch counts: enabling twice needs two disables, and an enable
/// that is never undone leaves other apps unable to read the keyboard after
/// this one has quit. So the state records whether *this* app has an enable
/// outstanding, and only ever asks for the call that changes that.
struct SecureInputState: Equatable {
    enum Action: Equatable {
        case enable
        case disable
    }

    /// Whether this app has an enable that it has not yet undone.
    private(set) var engaged = false

    /// Makes secure input match `wanted`, calling `apply` with the one action
    /// that gets there — or not at all when it already does. `apply` returns
    /// whether the call worked; a failed enable leaves nothing outstanding, and
    /// a failed disable is kept so it is tried again.
    mutating func update(wanted: Bool, apply: (Action) -> Bool) {
        if wanted, !engaged {
            engaged = apply(.enable)
        } else if !wanted, engaged {
            if apply(.disable) { engaged = false }
        }
    }
}
