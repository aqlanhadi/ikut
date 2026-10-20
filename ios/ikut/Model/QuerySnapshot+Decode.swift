import FirebaseFirestore

extension QuerySnapshot {
    /// Every document that decodes as `T`; ones that don't are skipped, so one bad doc never blanks a list.
    func decoded<T: Decodable>(_ type: T.Type) -> [T] {
        documents.compactMap { try? $0.data(as: type) }
    }
}
