

/*
  Miscelaneous methods extensions and other tidbits of useful functionality
  that is general enough to not belong in other files.
*/

extension Set {

  init<S: Sequence>(_ sequences: S...)
    where S.Iterator.Element: Hashable, S.Iterator.Element == Element
  {

    self.init()

    for element in sequences.joined() {
      insert(element)
    }
  }
}

// Combats Boilerplate
extension ExpressibleByStringLiteral where StringLiteralType == StaticString {

  public init(unicodeScalarLiteral value: StaticString) {
    self.init(stringLiteral: value)
  }

  public init(extendedGraphemeClusterLiteral value: StaticString) {
    self.init(stringLiteral: value)
  }
}
