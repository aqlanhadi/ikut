import FirebaseFirestore

extension QuerySnapshot {
    /// Every document that decodes as `T`; ones that don't are skipped, so one bad doc never blanks a list.
    func decoded<T: Decodable>(_ type: T.Type) -> [T] {
        documents.compactMap { try? $0.data(as: type) }
    }
}

extension Sequence where Element: Identifiable, Element.ID == String? {
    /// The elements by their document id; ones without an id are left out.
    func keyedByID() -> [String: Element] {
        keyedByID { $0 }
    }

    /// `value(element)` by the element's document id; ones without an id are left out.
    func keyedByID<V>(_ value: (Element) -> V) -> [String: V] {
        Dictionary(compactMap { e in e.id.map { ($0, value(e)) } }, uniquingKeysWith: { first, _ in first })
    }
}
