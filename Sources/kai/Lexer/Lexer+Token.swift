
extension Lexer {

    // TODO(vdka): Change into `Token.Kind` add to `Token` a location and an optional kind
    enum Token {
        case directive(Directive)
        case keyword(Keyword)
        case identifier(ByteString)
        case `operator`(ByteString)

        case string(ByteString)
        case integer(ByteString)
        case real(ByteString)

        case lparen
        case rparen
        case lbrace
        case rbrace
        case lbrack
        case rbrack

        case underscore
        case equals
        case colon
        case comma
        case dot

        enum Keyword: ByteString {
            case `struct`
            case `enum`

            case `true`
            case `false`

            case `if`
            case `else`
            case `return`

            case `defer`

            case `for`
            case `break`
            case `continue`

            case type
            case alias

            case returnArrow = "->"
        }

        enum Directive: ByteString {
            case file
            case line
            case `import`
            case foreign = "foreign"
            case foreignLLVM = "foreign(LLVM)"
        }
    }
}

extension Lexer.Token {

    var isLiteral: Bool {
        switch self {
        case .integer(_), .real(_), .string(_):
            return true

        default:
            return false
        }
    }
}

extension Lexer.Token: Equatable {

    static func == (lhs: Lexer.Token, rhs: Lexer.Token) -> Bool {
        switch (lhs, rhs) {
        case (.keyword(let l), .keyword(let r)): return l == r
        case (.identifier(let l), .identifier(let r)): return l == r
        case (.operator(let l), .operator(let r)): return l == r
        case (.string(let l), .string(let r)): return l == r
        case (.integer(let l), .identifier(let r)): return l == r
        case (.real(let l), .real(let r)): return l == r

        default: return isMemoryEquivalent(lhs, rhs)
        }
    }
}
