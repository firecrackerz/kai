
import LLVM

class Entity {
    var kind: Kind
    var flags: Flag
    var location: SourceLocation?
    var scope: Scope

    /// Set in the checker
    var type: Type? = nil
    var identifier: AST.Node?
    var llvm: IRValue?

    init(kind: Kind, flags: Flag = [], scope: Scope, location: SourceLocation?, identifier: AST.Node?) {
        self.kind = kind
        self.flags = flags
        self.scope = scope
        self.location = location
        self.type = nil
        self.identifier = identifier
    }
}

extension Entity: Hashable {

    static func ==(lhs: Entity, rhs: Entity) -> Bool {
        return lhs.kind == rhs.kind &&
            lhs.flags == rhs.flags &&
            lhs.location == rhs.location &&
            lhs.scope === rhs.scope &&
            lhs.type === rhs.type &&
            lhs.identifier?.entityName == rhs.identifier?.entityName
    }

    var hashValue: Int {
        return ObjectIdentifier(self).hashValue
    }
}

extension Entity {

    enum Kind: Equatable {
        case invalid
        case constant
        case variable
        case typeName
        case procedure
        case builtin
        case importName
        case libraryName
        case `nil`

        static func ==(lhs: Kind, rhs: Kind) -> Bool {
            return isMemoryEquivalent(lhs, rhs)
        }
    }

    struct Flag: OptionSet {
        var rawValue: UInt16

        static let visited   = Flag(rawValue: 0b00000001)
        static let used      = Flag(rawValue: 0b00000010)
        static let anonymous = Flag(rawValue: 0b00000100)
        static let field     = Flag(rawValue: 0b00001000)
        static let param     = Flag(rawValue: 0b00010000)
        static let ellipsis  = Flag(rawValue: 0b00100000)
        static let noAlias   = Flag(rawValue: 0b01000000)
        static let typeField = Flag(rawValue: 0b10000000)
    }
}

/*
struct Entity {
    EntityKind kind;
    u32        flags;
    Token      token;
    Scope *    scope;
    Type *     type;
    AstNode *  identifier; // Can be NULL

    // TODO(bill): Cleanup how `using` works for entities
    Entity *   using_parent;
    AstNode *  using_expr;

    union {
    struct {
        ExactValue value;
    } Constant;
    struct {
        i32  field_index;
        i32  field_src_index;
        bool is_immutable;
        bool is_thread_local;
    } Variable;
    i32 TypeName;
    struct {
        bool         is_foreign;
        String       foreign_name;
        Entity *     foreign_library;
        String       link_name;
        u64          tags;
        OverloadKind overload_kind;
    } Procedure;
    struct {
        i32 id;
    } Builtin;
    struct {
        String path;
        String name;
        Scope *scope;
        bool   used;
    } ImportName;
    struct {
        String path;
        String name;
        bool   used;
    } LibraryName;
    i32 Nil;
    };
};
*/
