import SwiftUI

extension Binding {
    /// A binding to the element of this collection that has the same id as
    /// `row`, for a list that iterates by value:
    ///
    ///     ForEach(settings.profiles) { profile in
    ///         Editor(profile: $settings.profiles.element(matching: profile))
    ///     }
    ///
    /// Not `ForEach($settings.profiles) { $profile in … }`. Its per-row
    /// bindings read `array[index]`, and when a row's own Remove button deletes
    /// the element, that row's binding is still evaluated during layout and
    /// traps on an out-of-range index (SIGILL, `Array._checkSubscript`).
    ///
    /// This one looks the element up by id on every read and write of the
    /// collection, so nothing here is tied to a position. A row that has just
    /// been removed reads back its value at render time, and a write to it is
    /// dropped.
    func element<Row: Identifiable>(matching row: Row) -> Binding<Row>
    where Value == [Row] {
        let id = row.id
        let fallback = row
        let collection = self
        return Binding<Row>(
            get: { collection.wrappedValue.first(where: { $0.id == id }) ?? fallback },
            set: { newValue in
                if let index = collection.wrappedValue.firstIndex(where: { $0.id == id }) {
                    collection.wrappedValue[index] = newValue
                }
            }
        )
    }
}
