
let digits		= Array("1234567890".unicodeScalars)
let opChars     = Array("~!%^&+-*/=<>|?".unicodeScalars)
let identChars  = Array("_abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ".unicodeScalars)
let whitespace  = Array(" \t".unicodeScalars)


typealias SourceRange = Range<SourceLocation>

struct SourceLocation {

    let file: String
    var line: UInt
    var column: UInt

    init(line: UInt, column: UInt, file: String? = nil) {
        self.line = line
        self.column = column
        self.file = file ?? "unknown"
    }

    static let zero = SourceLocation(line: 0, column: 0)
    static let unknown = SourceLocation(line: 0, column: 0)
}

extension SourceLocation: CustomStringConvertible {

    var description: String {
        let baseName = file.characters.split(separator: "/").map(String.init).last!
        return "\(baseName):\(line):\(column)"
    }
}

extension SourceLocation: Equatable, Comparable {

    public static func ==(lhs: SourceLocation, rhs: SourceLocation) -> Bool {
        return lhs.file == rhs.file && lhs.line == rhs.line && lhs.column == rhs.column
    }

    /// - Precondition: both must be in the same file
    static func < (lhs: SourceLocation, rhs: SourceLocation) -> Bool {
        if lhs.file != "unknown" && rhs.file != "unknown" {
            precondition(lhs.file == rhs.file)
        }

        return lhs.line < rhs.line
    }
}

struct Lexer {

	var scanner: FileScanner
	var buffer: [(kind: Token, location: SourceLocation)] = []

    var location: SourceLocation { return scanner.position }
	var lastLocation: SourceLocation
    var lastConsumedRange: SourceRange { return lastLocation ..< location }

	init(_ file: File) {

		self.scanner = FileScanner(file: file)
		self.lastLocation = scanner.position
	}

	mutating func peek(aheadBy n: Int = 0) throws -> (kind: Token, location: SourceLocation)? {
		if n < buffer.count { return buffer[n] }

		for _ in buffer.count...n {
			guard let token = try next() else { return nil }
			buffer.append(token)
		}
		return buffer.last
	}

	@discardableResult
	mutating func pop() throws -> (kind: Token, location: SourceLocation) {
		if buffer.isEmpty {
			let token = try next()!
			lastLocation = token.location
			return token
		}
		else {
			let token = buffer.removeFirst()
			lastLocation = token.location
			return token
		}
	}

	internal mutating func next() throws -> (kind: Token, location: SourceLocation)? {

		skipWhitespace()

		guard let char = scanner.peek() else { return nil }

		let location = scanner.position

		switch char {
		case _ where identChars.contains(char):
			let symbol = consume(with: identChars + digits)

            if let keyword = Token.Keyword(rawValue: symbol) {
                return (.keyword(keyword), location)
            } else {
                return (.ident(symbol), location)
            }

        case _ where scanner.hasPrefix("//") || scanner.hasPrefix("/*"):
            let comment = try consumeComment()
            return (.comment(comment), location)

		case _ where opChars.contains(char):
			let symbol = consume(with: opChars)
			if let keyword = Token.Keyword(rawValue: symbol) { return (.keyword(keyword), location) }
			else if symbol == "=" { return (.equals, location) }
			else { return (.operator(symbol), location) }

		// TODO(vdka): Correctly consume (and validate) number literals (real and integer)
		case _ where digits.contains(char):
			let number = consume(with: digits + ["."])

            if number.contains(".") {
                let dbl = Double(number)!
                return (.float(dbl), location)
            } else {
                let int = Int64(number)!
                return (.integer(int), location)
            }

		case "\"":
			scanner.pop()
            // FIXME(vdka): Currently doesn't handle escapes.
			let string = consume(upTo: "\"")
			guard case "\""? = scanner.peek() else { throw error(.unterminatedString) }
			scanner.pop()
			return (.string(string), location)

		case "(":
			scanner.pop()
			return (.lparen, location)

		case ")":
			scanner.pop()
			return (.rparen, location)

		case "[":
			scanner.pop()
			return (.lbrack, location)

		case "]":
			scanner.pop()
			return (.rbrack, location)

		case "{":
			scanner.pop()
			return (.lbrace, location)

		case "}":
			scanner.pop()
			return (.rbrace, location)

		case ":":
			scanner.pop()
			return (.colon, location)

        case ";":
            scanner.pop()
            return (.semicolon, location)

        case "\n":
            scanner.pop()
            return (.newline, location)

		case ",":
			scanner.pop()
			return (.comma, location)

		case ".":
			scanner.pop()
            if scanner.peek() == "." {
                scanner.pop()
                return (.ellipsis, location)
            }
			return (.dot, location)

		case "#":
			scanner.pop()
			let identifier = consume(upTo: { !whitespace.contains($0) })
			guard let directive = Token.Directive(rawValue: identifier) else {
				throw error(.unknownDirective)
			}

			return (.directive(directive), location)

		default:
			let suspect = consume(upTo: whitespace.contains)

			throw error(.invalidToken(suspect))
		}
	}

	@discardableResult
	private mutating func consume(with chars: [UnicodeScalar]) -> String {

		var str: String = ""
		while let char = scanner.peek(), chars.contains(char) {
			scanner.pop()
			str.append(char)
		}

		return str
	}

	@discardableResult
	private mutating func consume(with chars: String) -> String {

		var str: String = ""
		while let char = scanner.peek(), chars.unicodeScalars.contains(char) {
			scanner.pop()
			str.append(char)
		}

		return str
	}

	@discardableResult
	private mutating func consume(upTo predicate: (UnicodeScalar) -> Bool) -> String {

		var str: String = ""
		while let char = scanner.peek(), predicate(char) {
			scanner.pop()
			str.append(char)
		}
		return str
	}

	@discardableResult
	private mutating func consume(upTo target: UnicodeScalar) -> String {

		var str: String = ""
		while let char = scanner.peek(), char != target {
			scanner.pop()
			str.append(char)
		}
		return str
	}

}

extension Lexer {

    /// - Returns: `true` if a newline was passed
    fileprivate mutating func skipWhitespace() {

        while let char = scanner.peek() {
            switch char {
            case _ where whitespace.contains(char):
                scanner.pop()

            default:
                return
            }
        }
    }

    /// Skips whitespace until encountering a comment reinserting a newline if any were passed.
    /// sequential line comments are packaged up into a single return.
    fileprivate mutating func consumeComment() throws -> String {

        if scanner.hasPrefix("//") {

            let lines = try consumeLineComments()

            assert(!lines.isEmpty)
            return lines.joined(separator: "\n")
        } else if scanner.hasPrefix("/*") {

            return try consumeBlockComment()
        }

        preconditionFailure()
    }

	private mutating func consumeBlockComment() throws -> String {
		assert(scanner.hasPrefix("/*"))

        var scalars: [UnicodeScalar] = []

		scanner.pop(2)

		var depth: UInt = 1
		repeat {

			guard scanner.peek() != nil else {
				throw error(.unmatchedBlockComment)
			}

			if scanner.hasPrefix("*/") { depth -= 1 }
			else if scanner.hasPrefix("/*") { depth += 1 }

			let scalar = scanner.pop()
            scalars.append(scalar)

			if depth == 0 { break }
		} while depth > 0
		scanner.pop()

        // Remove the `/` from the `*/`
        scalars.removeLast()

        return String(scalars)
	}

    /// - Returns: An array of the line comments passed (with `//` and leading whitespace cut off)
	private mutating func consumeLineComments() throws -> [String] {
		assert(scanner.hasPrefix("//"))

        scanner.pop()
        scanner.pop()

        var lines: [String] = []
        var scalars: [UnicodeScalar] = []

        //
        // What this does is consume all consecutive lines starting in `//` and removes them in a single call.
        // The final state is one where the scanner head is in a position where there is no whitespace or line comment
        //   on the next line, but there may be a block comment.
        //

		while let char = scanner.peek() {
            if char == "\n" {
                let line = String(scalars)
                lines.append(line)
                scalars.removeAll(keepingCapacity: true)
                if !scanner.hasPrefix("//") {
                    return lines
                } else {
                    scanner.pop() // pop newline
                    skipWhitespace()
                    scanner.pop()
                    scanner.pop()
                }
            }
            let scalar = scanner.pop()
            scalars.append(scalar)
        }
        return lines
	}
}

extension Lexer {

	func error(_ reason: Error.Reason, message: String? = nil) -> Swift.Error {
		return Error(message: reason.description, location: scanner.position, highlights: [])
	}

    struct Error: Swift.Error {

		var message: String?
		var location: SourceLocation
		var highlights: [SourceRange]

		enum Reason: Swift.Error, CustomStringConvertible {
			case unterminatedString
			case unknownDirective
			case unmatchedBlockComment
			case invalidToken(String)

			var description: String {

				switch self {
				case .unterminatedString: return "Unterminated string"
				case .unknownDirective: return "Unknown directive"
				case .unmatchedBlockComment: return "Unmatched block comment"
				case .invalidToken(let culprit): return "The token '\(culprit)' is unrecognized"
				}
			}
		}
	}
}

extension Lexer {

    enum Token {
        case directive(Directive)
        case keyword(Keyword)

        case comment(String)

        case ident(String)
        case `operator`(String)

        case string(String)
        case integer(Int64)
        case float(Double)

        case lparen
        case rparen
        case lbrace
        case rbrace
        case lbrack
        case rbrack

        case equals
        case colon
        case comma
        case dot

        case ellipsis

        /// Hard line terminator
        case semicolon

        /// Soft line terminator
        case newline

        enum Keyword: String {
            case `struct`
            case `enum`

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

        enum Directive: String {
            case file
            case line
            case `import`
            case library
            case foreign = "foreign"
            case foreignLLVM = "foreign(LLVM)"
        }
    }
}

extension Lexer.Token: Equatable {

    static func == (lhs: Lexer.Token, rhs: Lexer.Token) -> Bool {
        switch (lhs, rhs) {
        case (.directive(let l), .directive(let r)):
            return l == r

        case (.keyword(let l), .keyword(let r)):
            return l == r

        case (.comment(let l), .comment(let r)): // Don't compare comments though ... that'd be weird.
            return l == r

        case (.ident(let l), .ident(let r)):
            return l == r

        case (.operator(let l), .operator(let r)):
            return l == r

        case (.string(let l), .string(let r)):
            return l == r

        case (.integer(let l), .integer(let r)):
            return l == r

        case (.float(let l), .float(let r)):
            return l == r

        case (.semicolon, .semicolon),
             (.ellipsis, .ellipsis),
             (.newline, .newline),
             (.lparen, .lparen),
             (.rparen, .rparen),
             (.lbrace, .lbrace),
             (.rbrace, .rbrace),
             (.lbrack, .lbrack),
             (.rbrack, .rbrack),
             (.equals, .equals),
             (.colon, .colon),
             (.comma, .comma),
             (.dot, .dot):
            return true
            
        default:
            return false
        }
    }
}
