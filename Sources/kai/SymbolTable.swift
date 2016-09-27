
class SymbolTable {

  var parent: SymbolTable? = nil
  var table: [Symbol] = []

  /// The top most symbol table. Things exported from file scope are here.
  static var global = SymbolTable()
  static var current = global
}

extension SymbolTable {

  func insert(_ symbol: Symbol) throws {
    guard table.index(where: { symbol.name == $0.name }) == nil else {
      throw Error(.redefinition, message: "Redefinition of \(symbol.name)", filePosition: symbol.position)
    }
    table.append(symbol)
  }

  func lookup(_ name: ByteString) -> Symbol? {

    if let symbol = table.first(where: { $0.name == name }) {
      return symbol
    } else {
      return parent?.lookup(name)
    }
  }
}

extension SymbolTable {

  @discardableResult
  static func push() -> SymbolTable {
    let newTable = SymbolTable()
    newTable.parent = SymbolTable.current
    SymbolTable.current = newTable

    return newTable
  }

  @discardableResult
  static func pop() -> SymbolTable {
    guard let parent = SymbolTable.current.parent else { fatalError("SymbolTable has been over pop'd") }

    defer { SymbolTable.current = parent }

    return SymbolTable.current
  }
}

extension SymbolTable {

  struct Error: CompilerError {
    var reason: Reason
    var message: String?
    var filePosition: FileScanner.Position

    init(_ reason: Reason, message: String, filePosition: FileScanner.Position) {
      self.reason = reason
      self.message = message
      self.filePosition = filePosition
    }

    enum Reason: Swift.Error {
      case redefinition
    }
  }
}

extension SymbolTable: CustomStringConvertible {

  var description: String {

    return "scope"
  }
}
