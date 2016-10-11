

struct Parser {

  var lexer: Lexer

  init(_ lexer: inout Lexer) {
    self.lexer = lexer
  }

  static func parse(_ lexer: inout Lexer) throws -> AST {

    var parser = Parser(&lexer)

    let node = AST.Node(.file(name: lexer.scanner.file.name))

    while true {
      let expr = try parser.expression()
      guard expr.kind != .empty else { return node }

      node.children.append(expr)
    }
  }

  mutating func expression(_ rbp: UInt8 = 0, disallowMultiples: Bool = false) throws -> AST.Node {
    // TODO(vdka): This should probably throw instead of returning an empty node. What does an empty AST.Node even mean.
    guard let (token, location) = try lexer.peek() else { return AST.Node(.empty) }

    guard let nud = try nud(for: token) else { throw error(.expectedExpression, message: "Expected Expression but got \(token)") }

    var left = try nud(&self)
    left.location = location

    // operatorImplementation's need to be skipped too.
    if case .operatorDeclaration = left.kind { return left }
    else if case .declaration(_) = left.kind { return left }
    else if case .comma? = try lexer.peek()?.kind, disallowMultiples { return left }

    while let (nextToken, _) = try lexer.peek(), let lbp = lbp(for: nextToken),
      rbp < lbp
    {
      guard let led = try led(for: nextToken) else { throw error(.nonInfixOperator) }

      left = try led(&self, left)
    }

    return left
  }
}

extension Parser {

  func lbp(for token: Lexer.Token) -> UInt8? {

    switch token {
    case .operator(let symbol):
      return Operator.table.first(where: { $0.symbol == symbol })?.lbp

      // TODO(vdka): what lbp do I want here?
    case .colon, .comma:
      return UInt8.max

    case .equals:
      return 160

    case .lbrack, .lparen:
      return 20

    default:
      return 0
    }
  }

  mutating func nud(for token: Lexer.Token) throws -> ((inout Parser) throws -> AST.Node)? {

    switch token {
    case .operator(let symbol):
      // If the next token is a colon then this should be a declaration
      switch try (lexer.peek(aheadBy: 1)?.kind, lexer.peek(aheadBy: 2)?.kind) {
      case (.colon?, .colon?):
        return Parser.parseOperatorDeclaration

      default:
        return Operator.table.first(where: { $0.symbol == symbol })?.nud
      }

    case .identifier(let symbol):
      try consume()
      return { parser in AST.Node(.identifier(symbol)) }

    case .integer(let literal):
      try consume()
      return { _ in AST.Node(.integer(literal)) }

    case .real(let literal):
      try consume()
      return { _ in AST.Node(.real(literal)) }

    case .string(let literal):
      try consume()
      return { _ in AST.Node(.string(literal)) }

    case .keyword(.true):
      try consume()
      return { _ in AST.Node(.boolean(true)) }

    case .keyword(.false):
      try consume()
      return { _ in AST.Node(.boolean(false)) }

    case .lparen:
      return { parser in
        try parser.consume(.lparen)
        let expr = try parser.expression()
        try parser.consume(.rparen)
        return expr
      }

    case .keyword(.if):
      return { parser in
        let (_, startLocation) = try parser.consume(.keyword(.if))

        let conditionExpression = try parser.expression()
        let thenExpression = try parser.expression()

        guard case .keyword(.else)? = try parser.lexer.peek()?.kind else {
          return AST.Node(.conditional, children: [conditionExpression, thenExpression], location: startLocation)
        }

        try parser.consume(.keyword(.else))
        let elseExpression = try parser.expression()
        return AST.Node(.conditional, children: [conditionExpression, thenExpression, elseExpression], location: startLocation)
      }

    case .lbrace:
      return { parser in
        let (_, startLocation) = try parser.consume(.lbrace)

        let scopeSymbols = SymbolTable.push()
        defer { SymbolTable.pop() }

        let node = AST.Node(.scope(scopeSymbols))
        while let next = try parser.lexer.peek()?.kind, next != .rbrace {
          let expr = try parser.expression()
          node.add(expr)
        }

        let (_, endLocation) = try parser.consume(.rbrace)

        node.sourceRange = startLocation..<endLocation

        return node
      }

    default:
      return nil
    }
  }

  mutating func led(for token: Lexer.Token) throws -> ((inout Parser, AST.Node) throws -> AST.Node)? {

    switch token {
    case .operator(let symbol):
      return Operator.table.first(where: { $0.symbol == symbol })?.led

    case .comma:
      try consume()
      return { parser, lvalue in

        let rhs = try parser.expression(UInt8.max)

        if case .multiple = lvalue.kind { lvalue.children.append(rhs) }
        else { return AST.Node(.multiple, children: [lvalue, rhs]) }

        return lvalue
      }

    case .lbrack:
      return { parser, lvalue in
        let (_, startLocation) = try parser.consume(.lbrack)
        let expr = try parser.expression()
        try parser.consume(.rbrack)

        return AST.Node(.subscript, children: [lvalue, expr], location: startLocation)
      }

    case .lparen:
      // @correctness
      // TODO(vdka): Do I need to ensure my lvalue is a identifier here to be sure this is a call?
      // Probably
      return Parser.parseProcedureCall

    case .equals:

      return { parser, lvalue in
        let (_, location) = try parser.consume(.equals)

        // @understand
        // TODO(vdka): I don't recall why I have the rbp set to 9 here
        let rhs = try parser.expression(9)

        return AST.Node(.assignment("="), children: [lvalue, rhs], location: location)
      }

    case .colon:

      if case .colon? = try lexer.peek(aheadBy: 1)?.kind { return Parser.parseCompileTimeDeclaration } // '::'
      return { parser, lvalue in
        // ':' 'id' | ':' '=' 'expr'

        try parser.consume(.colon)

        switch lvalue.kind {
        case .identifier(let id):
          // single
          let symbol = Symbol(id, location: lvalue.location!)
          try SymbolTable.current.insert(symbol)

          switch try parser.lexer.peek()?.kind {
          case .equals?: // type infered
            try parser.consume()
            let rhs = try parser.expression()
            return AST.Node(.declaration(symbol), children: [rhs], location: lvalue.location)

          default: // type provided
            let type = try parser.parseType()
            symbol.type = type

            try parser.consume(.equals)
            let rhs = try parser.expression()
            return AST.Node(.declaration(symbol), children: [rhs])
          }

        case .multiple:
          let symbols: [Symbol] = try lvalue.children.map { node in
            guard case .identifier(let id) = node.kind else { throw parser.error(.badlvalue) }
            let symbol = Symbol(id, location: node.location!)
            try SymbolTable.current.insert(symbol)

            return symbol
          }

          switch try parser.lexer.peek()?.kind {
          case .equals?:
            // We will need to infer the type. The AST returned will have 2 child nodes.
            try parser.consume()
            let rvalue = try parser.expression()
            // TODO(vdka): Pull the rvalue's children onto the generated node assuming it is a multiple node.

            let lvalue = AST.Node(.multiple, children: symbols.map({ AST.Node(.declaration($0), location: $0.location) }))

            return AST.Node(.multipleDeclaration, children: [lvalue, rvalue], location: symbols.first?.location)

          case .identifier?:
            unimplemented("Explicit types in multiple declaration's is not yet implemented")

          default:
            throw parser.error(.syntaxError)
          }

        case .operator(_):
          unimplemented()

        default:
          fatalError("bad lvalue?")
        }

        unimplemented()
      }

    default:
      return nil
    }
  }
}


// - MARK: Helpers

extension Parser {

  @discardableResult
  mutating func consume(_ expected: Lexer.Token? = nil) throws -> (kind: Lexer.Token, location: SourceLocation) {
    guard let expected = expected else {
      // Seems we exhausted the token stream
      // TODO(vdka): Fix this up with a nice error message
      guard try lexer.peek() != nil else { fatalError() }
      return try lexer.pop()
    }

    guard try lexer.peek()?.kind == expected else {
      let message: String
      switch expected {
      case .identifier(let val): message = val.description

      default: message = String(describing: expected)
      }
      throw error(.expected(expected), message: "expected \(message)", location: try lexer.peek()!.location)
    }

    return try lexer.pop()
  }

  func error(_ reason: Error.Reason, message: String? = nil, location: SourceLocation? = nil) -> Swift.Error {
    return Error(reason: reason, message: message, location: location ?? lexer.lastLocation)
  }
}

extension Parser {

  struct Error: CompilerError {

    var reason: Reason
    var message: String?
    var location: SourceLocation

    enum Reason: Swift.Error {
      case expected(Lexer.Token)
      case undefinedIdentifier(ByteString)
      case operatorRedefinition
      case unaryOperatorBodyForbidden
      case ambigiousOperatorUse
      case expectedBody
      case expectedPrecedence
      case expectedOperator
      case expectedExpression
      case nonInfixOperator
      case invalidDeclaration
      case syntaxError
      case badlvalue
    }
  }
}

extension Parser.Error.Reason: Equatable {

  static func == (lhs: Parser.Error.Reason, rhs: Parser.Error.Reason) -> Bool {

    switch (lhs, rhs) {
    case (.expected(let l), .expected(let r)): return l == r
    case (.undefinedIdentifier(let l), .undefinedIdentifier(let r)): return l == r
    default: return isMemoryEquivalent(lhs, rhs)
    }
  }
}
