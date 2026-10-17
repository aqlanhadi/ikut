import FirebaseFirestore

// `DocumentID` only wraps an optional value type, so it is safe to share across isolation domains.
extension DocumentID: @retroactive @unchecked Sendable {}
