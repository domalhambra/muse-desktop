extension String {
  /// The longest start of this text within `limit` UTF-16 units, cut between characters.
  /// The backend counts its limits as JavaScript's `length` does, in UTF-16 units.
  public func prefix(utf16Units limit: Int) -> String {
    var count = 0
    var end = startIndex
    for index in indices {
      count += self[index].utf16.count
      if count > limit { break }
      end = self.index(after: index)
    }
    return String(self[..<end])
  }
}
