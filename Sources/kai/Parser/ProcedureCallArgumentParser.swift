
extension Parser {

  /*
   '(' arg: expr, arg
  */
  mutating func parseProcedureCall(_ lvalue: AstNode) throws -> AstNode {

    push(context: .procedureCall)
    defer { popContext() }

    try consume(.lparen)

    var args: [AstNode] = []

    var wasComma = false

    while let (token, location) = try lexer.peek(), token != .rparen {

        switch token {
        case .comma:
            try consume(.comma)

            if wasComma && args.count < 1 {
                reportError("Unexpected comma", at: location)
                continue
            }

            wasComma = true

        case .ident(let ident) where try lexer.peek()?.kind == .colon: // arg label 'foo:'
            let (_, location) = try consume() // .ident(_)

            let labelNode = AstNode.ident(ident, location)
            try consume(.colon)
            let val = try expression()
            let arg = AstNode.argument(label: labelNode, value: val, location)
            args.append(arg)

            wasComma = false

        default:

            let val = try expression()
            let arg = AstNode.argument(label: nil, value: val, val.location.lowerBound)
            args.append(arg)

            wasComma = false
        }


    }
    
    let (_, endLocation) = try consume(.rparen)

    return AstNode.expr(.call(receiver: lvalue, args: args, lvalue.location.lowerBound ..< endLocation))
  }
}
