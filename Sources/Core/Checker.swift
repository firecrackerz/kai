
// sourcery:noinit
struct Checker {
    var file: SourceFile

    var context: Context

    init(file: SourceFile) {
        self.file = file
        context = Context(scope: file.scope, previous: nil)
    }

    // sourcery:noinit
    class Context {

        var scope: Scope
        var previous: Context?

        var function: Entity?
        var nearestFunction: Entity? {
            return function ?? previous?.nearestFunction
        }

        var expectedReturnType: ty.Tuple? = nil
        var nearestExpectedReturnType: ty.Tuple? {
            return expectedReturnType ?? previous?.nearestExpectedReturnType
        }
        var specializationCallNode: Call? = nil
        var nearestSpecializationCallNode: Call? {
            return specializationCallNode ?? previous?.nearestSpecializationCallNode
        }

        var nextCase: CaseClause?
        var nearestNextCase: CaseClause? {
            return nextCase ?? previous?.nearestNextCase
        }

        var switchLabel: Entity?
        var nearestSwitchLabel: Entity? {
            return switchLabel ?? previous?.nearestSwitchLabel
        }
        var inSwitch: Bool {
            return nearestSwitchLabel != nil
        }

        var loopBreakLabel: Entity?
        var nearestLoopBreakLabel: Entity? {
            return loopBreakLabel ?? previous?.nearestLoopBreakLabel
        }
        var inLoop: Bool {
            return nearestLoopBreakLabel != nil
        }

        var loopContinueLabel: Entity?
        var nearestLoopContinueLabel: Entity? {
            return loopContinueLabel ?? previous?.nearestLoopContinueLabel
        }

        var nearestLabel: Entity? {
            assert(loopBreakLabel == nil || switchLabel == nil)
            return loopBreakLabel ?? switchLabel ?? previous?.nearestLabel
        }

        init(scope: Scope, previous: Context?) {
            self.scope = scope
            self.previous = previous
        }
    }

    mutating func pushContext(owningNode: Node? = nil) {
        let newScope = Scope(parent: context.scope, owningNode: owningNode)
        context = Context(scope: newScope, previous: context)
    }

    mutating func popContext() {
        context = context.previous!
    }

    func declare(_ entity: Entity, scopeOwnsEntity: Bool = true) {
        let previous = context.scope.insert(entity, scopeOwnsEntity: scopeOwnsEntity)
        if let previous = previous, entity.file !== previous.file, !(entity.isFile && previous.isFile) {
            reportError("Invalid redeclaration of '\(previous.name)'", at: entity.ident.start,
                        attachNotes: "Previous declaration here: \(file.position(for: previous.ident.start).description)")
        }
    }
}

extension Checker {

    mutating func checkFile() {
        // Before we begin checking this file we import the entities from our imports where applicable
        // We can't guarentee collecting happens in any sort of order because that is where we establish an ordering
        //  because of this importing entities into our scope is only possible now that all of the entities for
        //  the imported files exist
        for i in file.imports {
            if i.importSymbolsIntoScope {
                for member in i.scope.members.values {
                    guard !member.isFile && !member.isLibrary else {
                        continue
                    }

                    declare(member, scopeOwnsEntity: i.exportSymbolsOutOfScope)
                }
            }
        }

        for node in file.nodes {
            check(topLevelStmt: node)
        }
    }

    mutating func collectFile() {
        for node in file.nodes {
            collect(topLevelStmt: node)
        }
    }

    mutating func collect(topLevelStmt stmt: TopLevelStmt) {
        switch stmt {
        case let i as Import:
            collect(import: i)
        case let l as Library:
            collect(library: l)
        case let f as Foreign:
            collect(foreignDecl: f.decl as! Declaration)
        case let d as DeclBlock:
            collect(declBlock: d)
        case let d as Declaration:
            collect(decl: d)
        case let using as Using:
            check(using: using)
        case is TestCase:
            break
        default:
            print("Warning: statement '\(stmt)' passed through without getting checked")
        }
    }

    mutating func collect(declBlock b: DeclBlock) {
        for decl in b.decls {
            if b.isForeign {
                collect(foreignDecl: decl)
            } else {
                collect(decl: decl)
            }
        }
    }

    mutating func collect(import i: Import) {
        guard i.scope != nil else {
            // assume we had an error somewhere and return to prevent crashes down
            // below
            return assert(file.errors.count > 0)
        }
        var fileEntity: Entity?
        if let alias = i.alias {
            fileEntity = newEntity(ident: alias, flags: .file)
        } else if !i.importSymbolsIntoScope {
            guard let name = i.resolvedName else {
                reportError("Cannot infer an import name for '\(i.path)'", at: i.path.start,
                            attachNotes: "You will need to manually specify one")
                return
            }
            let ident = Ident(start: noPos, name: name)
            fileEntity = newEntity(ident: ident, flags: .file)
        }

        // NOTE: If i.importSymbolsIntoScope we leave the import of entities until the file containing the import
        //   statement is starting to be checked. Only then do we know that all of the entities for the imported file
        //   have been created.
        if let fileEntity = fileEntity {
            fileEntity.memberScope = i.scope
            fileEntity.type = ty.File(memberScope: i.scope)
            declare(fileEntity)
        }
    }

    mutating func collect(library l: Library) {

        guard let lit = l.path as? BasicLit, lit.token == .string else {
            reportError("Library path must be a string literal value", at: l.path.start)
            return
        }

        let path = lit.constant as! String

        l.resolvedName = l.alias?.name ?? pathToEntityName(path)

        // TODO: Use the Value system to resolve any string value.
        guard let name = l.resolvedName else {
            reportError("Cannot infer an import name for '\(path)'", at: l.path.start,
                        attachNotes: "You will need to manually specify one")
            return
        }
        let ident = l.alias ?? Ident(start: noPos, name: name)
        let entity = newEntity(ident: ident, flags: .library)
        // NOTE: At least while we don't do anything to match foreigns to libraries we ignore redeclarations.
        // To reenable warnings about duplicate library entities use `declare(entity)`
        _ = context.scope.insert(entity, scopeOwnsEntity: true)

        if path != "libc" && path != "llvm" {
            // NOTE: On macOS, libs are more likely to be a `dylib`, but on Linux
            // they're more likely to be an `so`.
        #if os(macOS)
            let extensions = [
                "",
                ".dylib",
                ".so",
                ".a"
            ]
        #else
            let extensions = [
                "",
                ".so",
                ".a",
                ".dylib",
            ]
            #endif

            let p = extensions.flatMap { exten in
                return resolveLibraryPath(path+exten, for: file.fullpath)
            }.first

            guard let linkpath = p else {
                reportError("Failed to resolve path for '\(path)'", at: l.path.start)
                return

            }

            file.package.linkedLibraries.insert(linkpath)
        }
    }

    mutating func collect(decl: Declaration) {
        var entities: [Entity] = []

        for ident in decl.names {
            if ident.name == "_" {
                entities.append(Entity.anonymous)
                continue
            }

            let entity = newEntity(ident: ident)
            entity.declaration = decl
            ident.entity = entity
            entities.append(entity)
            declare(entity)
        }

        decl.entities = entities
        decl.declaringScope = context.scope
    }

    mutating func collect(foreignDecl d: Declaration) {
        // NOTE: Foreign declarations inforce singular names.
        let ident = d.names[0]
        if ident.name == "_" {
            return
        }

        let entity = newEntity(ident: ident, flags: d.isConstant ? [.constant, .foreign] : .foreign)
        entity.declaration = d
        ident.entity = entity
        declare(entity)
        d.entities = [entity]
    }
}


// MARK: Top Level Statements

extension Checker {

    mutating func check(topLevelStmt stmt: TopLevelStmt) {
        switch stmt {
        case is Using,
             is Import,
             is Library:
        break // we check these during collection.
        case let f as Foreign:
            let dependencies = check(foreignDecl: f.decl as! Declaration)
            f.dependsOn = dependencies
        case let d as Declaration:
            guard !d.checked else {
                return
            }

            let dependencies = check(decl: d)
            d.dependsOn = dependencies
            d.checked = true
        case let block as DeclBlock:
            let dependencies = check(declBlock: block)
            block.dependsOn = dependencies
        case let test as TestCase:
            guard compiler.options.isTestMode else {
                return
            }

            pushContext()
            context.expectedReturnType = ty.Tuple.make([ty.void])
            for stmt in test.body.stmts {
                _ = check(stmt: stmt)
            }
            popContext()
        default:
            print("Warning: statement '\(stmt)' passed through without getting checked")
        }
    }

    /// - returns: The entities references by the statement
    mutating func check(stmt: Stmt) -> Set<Entity> {

        switch stmt {
        case is Empty:
            return []

        case let stmt as ExprStmt:
            let operand = check(expr: stmt.expr)
            switch stmt.expr {
            case let call as Call:
                switch call.checked {
                case .call, .specializedCall:
                    guard let fnNode = (call.fun.type as? ty.Function)?.node, fnNode.isDiscardable || operand.type is ty.Void else {
                        fallthrough
                    }
                    // TODO: Report unused returns on non discardables
                case .builtinCall: fallthrough
                case .invalid:
                    break
                }

            default:
                if !(operand.type is ty.Invalid) {
                    reportError("Expression \(operand) is unused", at: stmt.start)
                }
            }
            return operand.dependencies
        case let decl as Declaration:
            return check(decl: decl)
        case let block as DeclBlock:
            return check(declBlock: block)
        case let assign as Assign:
            return check(assign: assign)
        case let block as Block:
            var dependencies: Set<Entity> = []
            pushContext()
            for stmt in block.stmts {
                let deps = check(stmt: stmt)
                dependencies.formUnion(deps)
            }
            popContext()
            return dependencies
        case let using as Using:
            check(using: using)
            return []

        case let ret as Return:
            return check(return: ret)

        case let d as Defer:
            return check(defer: d)

        case let fór as For:
            return check(for: fór)

        case let forIn as ForIn:
            return check(forIn: forIn)

        case let íf as If:
            return check(if: íf)

        case let íf as DirectiveIf:
            return check(directiveIf: íf)

        case let s as Switch:
            return check(switch: s)

        case let b as Branch:
            check(branch: b)
            return []
        case let a as InlineAsm:
            let operand = check(inlineAsm: a, desiredType: nil)
            return operand.dependencies
        default:
            print("Warning: statement '\(stmt)' passed through without getting checked")
            return []
        }
    }

    mutating func check(decl: Declaration) -> Set<Entity> {
        let dependencies: Set<Entity>

        // only has an effect if there is a declaring scope
        // Set the scope to the one the declaration occured in, this way if,
        //   we are forced to check something declared later in the file it's
        //   declared in the correct scope.
        let prevScope = context.scope
        defer {
            context.scope = prevScope
        }
        if let declaringScope = decl.declaringScope {
            context.scope = declaringScope
        }

        // Create the entities for the declaration
        if decl.entities == nil {
            var entities: [Entity] = []
            entities.reserveCapacity(decl.names.count)
            for ident in decl.names {
                if ident.name == "_" {
                    ident.entity = Entity.anonymous
                } else {
                    ident.entity = newEntity(ident: ident)
                    declare(ident.entity)
                }
                entities.append(ident.entity)
            }
            decl.entities = entities
        }

        if decl.isConstant {
            dependencies = check(constantDecl: decl)
        } else {
            dependencies = check(variableDecl: decl)
        }
        decl.checked = true
        return dependencies
    }

    mutating func check(constantDecl decl: Declaration) -> Set<Entity> {
        var dependencies: Set<Entity> = []

        guard decl.names.count == 1 else {
            reportError("Constant declarations must declare at most a single Entity", at: decl.names[1].start)
            decl.entities.forEach({ $0.type = ty.invalid })
            return dependencies
        }

        var expectedType: Type?
        if let explicitType = decl.explicitType {
            let operand = check(expr: explicitType)
            dependencies.formUnion(operand.dependencies)
            expectedType = lowerFromMetatype(operand.type, atNode: explicitType)
        }

        let value = decl.values[0]
        let ident = decl.names[0]

        defer {
            context.function = nil
        }
        if let value = value as? FuncLit, !value.explicitType.isPolymorphic {
            // setup a stub function so that recursive functions check properly
            context.function = ident.entity
            let operand = check(funcType: value.explicitType)
            ident.entity.type = operand.type.lower()
        } else if value is StructType || value is PolyStructType || value is UnionType || value is EnumType { // FIXME: Use `isStruct` etc
            // declare a stub type, collect all member declarations
            let stub = ty.Named(entity: ident.entity, base: nil)
            ident.entity.type = ty.Metatype(instanceType: stub)
        }
        let operand = check(expr: value, desiredType: expectedType)
        dependencies.formUnion(operand.dependencies)

        ident.entity.constant = operand.constant
        ident.constant = operand.constant
        ident.entity.linkname = decl.linkname

        ident.entity.flags.insert(.constant)
        ident.entity.flags.insert(.checked)

        var type = operand.type!
        if let expectedType = expectedType, !convert(type, to: expectedType, at: value) {
            reportError("Cannot convert \(operand) to specified type '\(expectedType)'", at: value.start)
            return dependencies
        }

        if type is ty.Tuple {
            assert((type as! ty.Tuple).types.count != 1)
            reportError("Multiple value \(value) where single value was expected", at: value.start)
            return dependencies
        }

        if var metatype = type as? ty.Metatype {
            ident.entity.flags.insert(.type)
            guard let baseType = baseType(metatype.instanceType) as? NamableType else {
                reportError("The type '\(metatype.instanceType)' is not aliasable", at: value.start)
                return dependencies
            }

            if let existing = (ident.entity.type as? ty.Metatype)?.instanceType as? ty.Named {
                // For Structs we have previously defined a 'stub' named version, here we want to 'fulfill' that stub
                //  by setting the base type for that named typed
                existing.base = baseType
            }
            metatype.instanceType = ty.Named(entity: ident.entity, base: baseType)
            type = metatype
        }

        ident.entity.type = type

        return dependencies
    }

    mutating func check(variableDecl decl: Declaration) -> Set<Entity> {
        var dependencies: Set<Entity> = []

        var expectedType: Type?
        if let explicitType = decl.explicitType {
            let operand = check(expr: explicitType)
            dependencies.formUnion(operand.dependencies)
            expectedType = lowerFromMetatype(operand.type, atNode: explicitType)
        }

        // Handle linkname directive
        if let linkname = decl.linkname {
            decl.names[0].entity.linkname = linkname
            if decl.names.count > 1 {
                reportError("Linkname cannot be used on a declaration of multiple entities", at: decl.start)
            }
        }

        // handle uninitialized variable declaration `x, y: i32`
        if decl.values.isEmpty {
            assert(expectedType != nil)
            for ident in decl.names {
                ident.entity.flags.insert(.checked)
                ident.entity.type = expectedType
            }

            // Because we must have types set for later, we use the expected type even if it is illegal
            if let type = expectedType as? ty.Array, type.length == nil {
                reportError("Implicit-length array must have an initial value", at: decl.explicitType!.start)
                return dependencies
            }
            if let type = expectedType as? ty.Function {
                reportError("Variables of a function type must be initialized", at: decl.start,
                            attachNotes: "If you want an uninitialized function pointer use *\(type) instead")
                return dependencies
            }
            return dependencies
        }

        // handle multi-value call variable expressions
        if decl.names.count != decl.values.count {
            guard decl.values.count == 1, let call = decl.values[0] as? Call else {
                reportError("Assigment count mismatch \(decl.names.count) = \(decl.values.count)", at: decl.start)
                return dependencies
            }
            guard expectedType == nil else {
                reportError("Explicit types are prohibited when calling a multiple-value function", at: decl.explicitType!.start)
                return dependencies
            }
            let operand = check(call: call, desiredType: expectedType)
            dependencies.formUnion(operand.dependencies)
            if let tuple = operand.type as? ty.Tuple {
                guard decl.names.count == tuple.types.count else {
                    reportError("Assignment count mismatch \(decl.names.count) = \(tuple.types.count)", at: decl.start)
                    return dependencies
                }
                for (ident, type) in zip(decl.names, tuple.types) {
                    if ident.entity === Entity.anonymous {
                        continue
                    }
                    ident.entity.flags.insert(.checked)
                    ident.entity.type = type
                }
                return dependencies
            } else {
                // The rhs is not a tuple and so we must invalidate all values
                for entity in decl.entities {
                    entity.flags.insert(.checked)
                    entity.type = operand.type
                }
            }
            return dependencies
        }

        // At this point we have a simple declaration of 1 or more entities with matching values
        for (ident, value) in zip(decl.names, decl.values) {
            let operand = check(expr: value, desiredType: expectedType)
            dependencies.formUnion(operand.dependencies)

            if let expectedType = expectedType, !convert(operand.type, to: expectedType, at: value) {
                reportError("Cannot convert \(operand) to specified type '\(expectedType)'", at: value.start)
            }

            if ident.entity === Entity.anonymous {
                continue
            }

            guard !isMetatype(operand.type) else {
                reportError("\(operand) is not an expression", at: value.start)
                continue
            }

            ident.entity.flags.insert(.checked)
            ident.entity.type = expectedType ?? operand.type
        }

        return dependencies
    }

    /// - returns: The entities this declaration depends on (not the entities declared)
    mutating func check(declBlock b: DeclBlock) -> Set<Entity> {
        var dependencies: Set<Entity> = []
        for decl in b.decls {
            guard decl.names.count == 1 else {
                reportError("Grouped declarations must be singular", at: decl.names[1].start)
                continue
            }
            decl.callconv = decl.callconv ?? b.callconv

            if b.isForeign {
                let deps = check(foreignDecl: decl)
                dependencies.formUnion(deps)

                let entity = decl.entities[0]
                entity.linkname = decl.linkname ?? (b.linkprefix ?? "") + entity.name
            } else {
                let deps = check(decl: decl)
                dependencies.formUnion(deps)

                let entity = decl.entities[0]
                if decl.linkname != nil || b.linkprefix != nil {
                    entity.linkname = decl.linkname ?? (b.linkprefix ?? "") + entity.name
                }
            }
        }
        return dependencies
    }

    /// - returns: The entities this declaration depends on (not the entities declared)
    mutating func check(foreignDecl d: Declaration) -> Set<Entity> {
        let ident = d.names[0]

        if d.callconv == nil {
            d.callconv = "c"
        }

        if !context.scope.isFile && !context.scope.isPackage {
            if ident.name == "_" {
                ident.entity = Entity.anonymous
                // throws error below
            } else {
                let entity = newEntity(ident: ident, flags: d.isConstant ? [.constant, .foreign] : .foreign)
                ident.entity = entity
                declare(entity)
                d.entities = [entity]
            }
        }

        if ident.entity === Entity.anonymous {
            reportError("The dispose identifer is not a permitted name in foreign declarations", at: ident.start)
            return []
        }

        // only 2 forms allowed by the parser `i: ty` or `i :: ty`
        //  these represent a foreign variable and a foreign constant respectively.
        // In both cases these are no values, just an explicitType is set. No values.
        let operand = check(expr: d.explicitType!)
        var type = lowerFromMetatype(operand.type, atNode: d.explicitType!)

        if d.isConstant {
            if let pointer = type as? ty.Pointer, pointer.pointeeType is ty.Function {
                type = pointer.pointeeType
            }
        }
        ident.entity.flags.insert(.checked)
        ident.entity.type = type

        return operand.dependencies
    }

    /// - returns: The entities this declaration depends on
    mutating func check(assign: Assign) -> Set<Entity> {
        var dependencies: Set<Entity> = []

        if assign.rhs.count == 1 && assign.lhs.count > 1, let call = assign.rhs[0] as? Call {
            let operand = check(call: call)
            dependencies.formUnion(operand.dependencies)

            let types = (operand.type as! ty.Tuple).types

            for (lhs, type) in zip(assign.lhs, types) {
                let lhsOperand = check(expr: lhs)
                dependencies.formUnion(lhsOperand.dependencies)

                guard lhsOperand.mode == .addressable || lhsOperand.mode == .assignable else {
                    reportError("Cannot assign to \(lhsOperand)", at: lhs.start)
                    continue
                }
                guard type == lhsOperand.type else {
                    reportError("Cannot assign \(operand) to \(lhsOperand)", at: call.start)
                    continue
                }
            }
        } else {

            for (lhs, rhs) in zip(assign.lhs, assign.rhs) {
                let lhsOperand = check(expr: lhs)
                let rhsOperand = check(expr: rhs, desiredType: lhsOperand.type)
                dependencies.formUnion(lhsOperand.dependencies)
                dependencies.formUnion(rhsOperand.dependencies)

                guard lhsOperand.mode == .assignable || lhsOperand.mode == .addressable else {
                    reportError("Cannot assign to \(lhsOperand)", at: lhs.start)
                    continue
                }
                guard convert(rhsOperand.type, to: lhsOperand.type, at: rhs) else {
                    reportError("Cannot assign \(rhsOperand) to \(lhsOperand)", at: rhs.start)
                    continue
                }
            }

            if assign.lhs.count != assign.rhs.count {
                reportError("Assignment count missmatch \(assign.lhs.count) = \(assign.rhs.count)", at: assign.start)
            }
        }
        return dependencies
    }

    mutating func check(using: Using) {
        func declare(_ entity: Entity) {
            let previous = context.scope.insert(entity, scopeOwnsEntity: false)
            if let previous = previous {
                reportError("Use of 'using' resulted in name collision for the name '\(previous.name)'", at: entity.ident.start,
                            attachNotes: "Previously declared here: \(previous.ident.start)")
            }
        }

        for expr in using.exprs {
            let operand = check(expr: expr)

            switch baseType(operand.type) {
            case let type as ty.File:
                for entity in type.memberScope.members.values {
                    declare(entity)
                }
            case let type as ty.Struct:
                for field in type.fields.orderedValues {
                    let entity = newEntity(ident: field.ident, type: field.type, flags: .field, owningScope: context.scope)
                    declare(entity)
                }
            case let meta as ty.Metatype:
                guard let type = baseType(lowerFromMetatype(meta, atNode: expr)) as? ty.Enum else {
                    fallthrough
                }

                for c in type.cases.orderedValues {
                    let entity = newEntity(ident: c.ident, type: type, flags: [.field, .constant], owningScope: context.scope)
                    entity.constant = c.constant
                    declare(entity)
                }
            default:
                reportError("using is invalid on \(operand)", at: expr.start)
            }
        }
    }

    mutating func check(defer d: Defer) -> Set<Entity> {
        pushContext(owningNode: d); defer {
            popContext()
        }
        return check(stmt: d.stmt)
    }
}


// MARK: Statements

extension Checker {

    mutating func check(branch: Branch) {
        switch branch.token {
        case .break:
            let target: Entity
            if let label = branch.label {
                guard let entity = context.scope.lookup(label.name) else {
                    reportError("Use of undefined identifer '\(label)'", at: label.start)
                    return
                }
                target = entity
            } else {
                guard let entity = context.nearestLabel else {
                    reportError("break outside of loop or switch", at: branch.start)
                    return
                }
                target = entity
            }
            branch.target = target
        case .continue:
            let target: Entity
            if let label = branch.label {
                guard let entity = context.scope.lookup(label.name) else {
                    reportError("Use of undefined identifer '\(label)'", at: label.start)
                    return
                }
                target = entity
            } else {
                guard let entity = context.nearestLoopContinueLabel else {
                    reportError("break outside of loop", at: branch.start)
                    return
                }
                target = entity
            }
            branch.target = target
        case .fallthrough:
            guard context.inSwitch else {
                reportError("fallthrough outside of switch", at: branch.start)
                return
            }
            guard let target = context.nearestNextCase?.label else {
                reportError("fallthrough cannot be used without a next case", at: branch.start)
                return
            }
            branch.target = target
        default:
            fatalError()
        }
    }

    mutating func check(return ret: Return) -> Set<Entity> {
        let expectedReturn = context.nearestExpectedReturnType!

        let isVoidReturn = isVoid(splatTuple(expectedReturn))

        var dependencies: Set<Entity> = []
        for (value, expected) in zip(ret.results, expectedReturn.types) {
            let operand = check(expr: value, desiredType: expected)
            dependencies.formUnion(operand.dependencies)

            if !convert(operand.type, to: expected, at: value) {
                if isVoidReturn {
                    reportError("Void function should not return a value", at: value.start)
                    return dependencies
                } else {
                    reportError("Cannot convert \(operand) to expected type '\(expected)'", at: value.start)
                }
            }
        }

        if ret.results.count < expectedReturn.types.count, let first = expectedReturn.types.first, !isVoid(first) {
            reportError("Not enough arguments to return", at: ret.start)
        } else if ret.results.count > expectedReturn.types.count {
            reportError("Too many arguments to return", at: ret.start)
        }
        return dependencies
    }

    mutating func check(for fór: For) -> Set<Entity> {
        var dependencies: Set<Entity> = []
        pushContext()
        defer {
            popContext()
        }

        let breakLabel = Entity.makeAnonLabel()
        let continueLabel = Entity.makeAnonLabel()
        fór.breakLabel = breakLabel
        fór.continueLabel = continueLabel
        context.loopBreakLabel = breakLabel
        context.loopContinueLabel = continueLabel

        if let initializer = fór.initializer {
            let deps = check(stmt: initializer)
            dependencies.formUnion(deps)
        }

        if let cond = fór.cond {
            check(condition: cond)
        }

        if let step = fór.step {
            let deps = check(stmt: step)
            dependencies.formUnion(deps)
        }

        let deps = check(stmt: fór.body)
        dependencies.formUnion(deps)
        return dependencies
    }

    mutating func check(forIn: ForIn) -> Set<Entity> {
        var dependencies: Set<Entity> = []
        pushContext()
        defer {
            popContext()
        }

        let breakLabel = Entity.makeAnonLabel()
        let continueLabel = Entity.makeAnonLabel()
        forIn.breakLabel =  breakLabel
        forIn.continueLabel = continueLabel
        context.loopBreakLabel = breakLabel
        context.loopContinueLabel = continueLabel

        if forIn.names.count > 2 {
            reportError("A `for in` statement can only have 1 or 2 declarations", at: forIn.names.last!.start)
        }

        let operand = check(expr: forIn.aggregate)
        dependencies.formUnion(operand.dependencies)
        guard canSequence(operand.type) else {
            forIn.aggregate.type = ty.invalid
            reportError("Cannot create a sequence for \(operand)", at: forIn.aggregate.start)
            return dependencies
        }

        let elementType: Type
        switch baseType(operand.type) {
        case let array as ty.Array:
            elementType = array.elementType
            forIn.checked = .array(array.length)
        case let slice as ty.Slice:
            elementType = slice.elementType
            forIn.checked = .slice
        default:
            preconditionFailure()
        }

        let element = forIn.names[0]
        let elEntity = newEntity(ident: element, type: elementType)
        declare(elEntity)
        forIn.element = elEntity

        if let index = forIn.names[safe: 1] {
            let iEntity = newEntity(ident: index, type: ty.i64)
            declare(iEntity)
            forIn.index = iEntity
        }

        let deps = check(stmt: forIn.body)
        dependencies.formUnion(deps)
        return dependencies
    }

    @discardableResult
    mutating func check(condition: Expr) -> Operand {
        var operand = check(expr: condition, desiredType: ty.bool)
        if isNilable(operand.type) {
            // NOTE: Pointer as condition is allowed in statement conditions
            assert(condition is Convertable)
            (condition as! Convertable).conversion = (operand.type, ty.bool)
            operand.type = ty.bool
            return operand
        }
        if !convert(operand.type, to: ty.bool, at: condition) {
            reportError("Cannot convert \(operand) to expected type '\(ty.bool)'", at: condition.start)
            return Operand.invalid
        }
        return operand
    }

    mutating func check(if iff: If) -> Set<Entity> {
        var dependencies: Set<Entity> = []

        pushContext()
        let operand = check(condition: iff.cond)
        dependencies.formUnion(operand.dependencies)

        let deps = check(stmt: iff.body)
        popContext()
        dependencies.formUnion(deps)
        if let els = iff.els {
            pushContext()
            let deps = check(stmt: els)
            popContext()
            dependencies.formUnion(deps)
        }
        return dependencies
    }

    mutating func check(directiveIf iff: DirectiveIf) -> Set<Entity> {
        let operand = check(expr: iff.cond)
        var dependencies = operand.dependencies

        guard let constant = operand.constant else {
            reportError("Expression must evaluate to a compile-time constant", at: iff.cond.start)
            return dependencies
        }

        let cond = isConstantTrue(constant)
        var node: Stmt?
        if cond {
            node = iff.body
        } else if let els = iff.els {
            node = els
        }

        iff.nodeToCodegen = node
        if let node = node {
            guard let body = node as? Block else {
                reportError("Expected a block", at: iff.body.start)
                return dependencies
            }

            // NOTE: we're not throwing the block at the checker because we don't
            // want it to create a new scope
            for stmt in body.stmts {
                dependencies.formUnion(check(stmt: stmt))
            }
        }

        return dependencies
    }

    mutating func check(switch sw: Switch) -> Set<Entity> {
        var dependencies: Set<Entity> = []
        pushContext()
        defer {
            popContext()
        }

        let label = Entity.makeAnonLabel()
        sw.label = label
        context.switchLabel = label

        var type: Type?
        if let match = sw.match {
            let operand = check(expr: match)
            dependencies.formUnion(operand.dependencies)

            type = operand.type
            guard isInteger(type!) || isEnum(type!) || isUnion(type!) || isAnyy(type!) else {
                reportError("Cannot switch on type '\(type!)'. Can only switch on integer and enum types", at: match.start)
                return dependencies
            }

            if isMetatype(type!) {
                sw.flags.insert(.type)
            }
            if isUnion(type!) {
                sw.flags.insert(.union)
            }
            if isAnyy(type!) {
                sw.flags.insert(.any)
            }
            if (sw.isAny || sw.isUnion) && sw.binding == nil {
                // if binding is unspecified and switch subject is an identifier shadow using it
                sw.binding = sw.match as? Ident
            }

            if sw.isUsing {
                guard let type = baseType(match.type) as? ty.Enum else {
                    reportError("using is invalid on \(operand)", at: match.start)
                    return dependencies
                }

                for c in type.cases.orderedValues {
                    let entity = newEntity(ident: c.ident, type: type, flags: [.field, .constant], owningScope: context.scope)
                    entity.constant = c.constant
                    declare(entity)
                }
            }
        } else if sw.isUsing {
            reportError("Using expects an entity", at: sw.start)
        }

        var seenDefault = false

        for c in sw.cases {
            c.label = Entity.makeAnonLabel()
        }

        for (c, nextCase) in sw.cases.enumerated().map({ ($0.element, sw.cases[safe: $0.offset + 1]) }) {
            if !c.match.isEmpty, let union = type.map(baseType) as? ty.Union {
                assert(sw.isUnion)
                if c.match.count > 1 {
                    reportError("Cannot match multiple union members", at: c.match[1].start)
                }

                guard let ident = c.match[0] as? Ident else {
                    continue
                }
                guard let unionCase = union.cases[ident.name] else {
                    reportError("Union '\(type!)' has no member \(ident)", at: ident.start)
                    continue
                }

                if let binding = sw.binding {
                    c.binding = newEntity(ident: binding, type: unionCase.type, flags: .none)
                }

                ident.constant = UInt64(unionCase.tag)

            } else if sw.isAny {
                if c.match.count == 1, let binding = sw.binding {
                    // set in the loop below
                    c.binding = newEntity(ident: binding, type: nil, flags: .none)
                }
                for match in c.match {
                    let operand = check(expr: match)
                    dependencies.formUnion(operand.dependencies)

                    c.binding?.type = lowerFromMetatype(operand.type, atNode: match)
                }


            } else if !c.match.isEmpty {
                for match in c.match {
                    if let desiredType = type {
                        let operand = check(expr: match, desiredType: desiredType)
                        dependencies.formUnion(operand.dependencies)

                        guard convert(operand.type, to: desiredType, at: match) else {
                            reportError("Cannot convert \(operand) to expected type '\(desiredType)'", at: match.start)
                            continue
                        }
                    } else {
                        let operand = check(expr: match, desiredType: ty.bool)
                        dependencies.formUnion(operand.dependencies)

                        guard convert(operand.type, to: ty.bool, at: match) else {
                            reportError("Cannot convert \(operand) to expected type '\(ty.bool)'", at: match.start)
                            continue
                        }
                    }
                }
            } else if seenDefault {
                reportError("Duplicate default cases", at: c.start)
            } else {
                seenDefault = true
            }

            context.nextCase = nextCase
            pushContext()
            c.binding.map({ declare($0) })
            let deps = check(stmt: c.block)
            popContext()
            dependencies.formUnion(deps)
        }

        context.nextCase = nil
        return dependencies
    }
}


// MARK: Expressions

extension Checker {

    mutating func check(expr: Expr, desiredType: Type? = nil) -> Operand {

        switch expr {
        case let expr as Nil:
            return check(nil: expr, desiredType: desiredType)

        case let ident as Ident:
            return check(ident: ident, desiredType: desiredType)

        case let lit as BasicLit:
            return check(basicLit: lit, desiredType: desiredType)

        case let lit as CompositeLit:
            return check(compositeLit: lit, desiredType: desiredType)

        case let fn as FuncLit:
            return check(funcLit: fn)

        case let fn as FuncType:
            return check(funcType: fn)

        case let polyType as PolyType:
            let type = check(polyType: polyType)
            return Operand(mode: .type, expr: expr, type: type, constant: nil, dependencies: [])

        case let variadic as VariadicType:
            var operand = check(expr: variadic.explicitType)
            operand.type = ty.Metatype(instanceType: ty.Slice(lowerFromMetatype(operand.type, atNode: expr)))
            expr.type = operand.type
            return operand

        case let pointer as PointerType:
            let operand = check(expr: pointer.explicitType)
            let pointee = lowerFromMetatype(operand.type, atNode: pointer.explicitType)
            // TODO: If this cannot be lowered we should not that `<` is used for deref
            let type = ty.Pointer(pointee)
            pointer.type = ty.Metatype(instanceType: type)
            return Operand(mode: .type, expr: expr, type: pointer.type, constant: nil, dependencies: operand.dependencies)

        case let array as ArrayType:
            let elementOperand = check(expr: array.explicitType)
            let elementType = lowerFromMetatype(elementOperand.type, atNode: array)
            var dependencies: Set<Entity> = []
            var length: Int?
            if let lengthExpr = array.length {
                let lengthOperand = check(expr: lengthExpr)
                guard let len = lengthOperand.constant as? UInt64 else {
                    reportError("Currently, only integer literals are allowed for array length", at: lengthExpr.start)
                    return Operand.invalid
                }

                length = Int(len)

                dependencies = elementOperand.dependencies.union(lengthOperand.dependencies)
            }

            let type = ty.Array(length: length, elementType: elementType)
            array.type = ty.Metatype(instanceType: type)
            return Operand(mode: .type, expr: expr, type: array.type, constant: nil, dependencies: dependencies)

        case let array as SliceType:
            let elementOperand = check(expr: array.explicitType)
            let elementType = lowerFromMetatype(elementOperand.type, atNode: array)

            let type = ty.Slice(elementType)
            array.type = ty.Metatype(instanceType: type)
            return Operand(mode: .type, expr: expr, type: array.type, constant: nil, dependencies: elementOperand.dependencies)

        case let vector as VectorType:
            let elementOperand = check(expr: vector.explicitType)
            let elementType = lowerFromMetatype(elementOperand.type, atNode: vector)

            guard canVector(elementType) else {
                reportError("Vector only supports primitive data types", at: vector.explicitType.start)
                vector.type = ty.invalid
                return Operand.invalid
            }

            let sizeOperand = check(expr: vector.size)
            guard let size = sizeOperand.constant as? UInt64 else {
                reportError("Cannot convert '\(sizeOperand)' to a constant Integer", at: vector.size.start)
                vector.type = ty.invalid
                return Operand.invalid
            }
            let type = ty.Vector(size: Int(size), elementType: elementType)
            vector.type = ty.Metatype(instanceType: type)

            let dependencies = elementOperand.dependencies.union(sizeOperand.dependencies)
            return Operand(mode: .type, expr: expr, type: vector.type, constant: nil, dependencies: dependencies)

        case let s as StructType:
            return check(struct: s)

        case let s as PolyStructType:
            return check(polyStruct: s)

        case let u as UnionType:
            return check(union: u)

        case let e as EnumType:
            return check(enumType: e)

        case let paren as Paren:
            return check(expr: paren.element, desiredType: desiredType)

        case let unary as Unary:
            return check(unary: unary, desiredType: desiredType)

        case let binary as Binary:
            return check(binary: binary, desiredType: desiredType)

        case let ternary as Ternary:
            return check(ternary: ternary, desiredType: desiredType)

        case let selector as Selector:
            return check(selector: selector, desiredType: desiredType)

        case let s as Subscript:
            return check(subscript: s)

        case let s as Slice:
            return check(slice: s)

        case let call as Call:
            return check(call: call, desiredType: desiredType)

        case let cast as Cast:
            return check(cast: cast, desiredType: desiredType)

        case let l as LocationDirective:
            return check(locationDirective: l, desiredType: desiredType)
        case let a as InlineAsm:
            return check(inlineAsm: a, desiredType: desiredType)
        default:
            print("Warning: expression '\(expr)' passed through without getting checked")
            expr.type = ty.invalid
            return Operand.invalid
        }
    }

    @discardableResult
    mutating func check(ident: Ident, desiredType: Type? = nil) -> Operand {
        guard let entity = context.scope.lookup(ident.name) else {
            reportError("Use of undefined identifier '\(ident)'", at: ident.start)
            ident.entity = Entity.invalid
            ident.type = ty.invalid
            return Operand.invalid
        }
        guard !entity.isLibrary else {
            reportError("Cannot use library as expression", at: ident.start)
            ident.entity = Entity.invalid
            ident.type = ty.invalid
            return Operand.invalid
        }
        ident.entity = entity
        if entity.isConstant {
            ident.constant = entity.constant
        }

        assert(entity.type != nil || !entity.isChecked, "Either we have a type or the entity is yet to be checked")
        var type = entity.type
        if entity.type == nil {
            check(topLevelStmt: entity.declaration!)
            assert(entity.isChecked && entity.type != nil)
            type = entity.type
        }

        if let desiredType = desiredType, isUntypedNumber(entity.type!) {
            if constrainUntyped(type!, to: desiredType) {
                ident.conversion = (from: entity.type!, to: desiredType)
                ident.type = desiredType
                return Operand(mode: entity.isType ? .type : .addressable, expr: ident, type: desiredType, constant: entity.constant, dependencies: [entity])
            }
        }
        ident.type = type!

        let mode: Operand.Mode
        if entity.isFile {
            mode = .file
        } else if entity.isLabel {
            mode = .computed
        } else if entity.isType {
            mode = .type
        } else if entity.isBuiltin && (entity.name == "true" || entity.name == "false") {
            mode = .computed
        } else {
            mode = .addressable
        }

        return Operand(mode: mode, expr: ident, type: type, constant: entity.constant, dependencies: [entity])
    }

    @discardableResult
    mutating func check(nil lit: Nil, desiredType: Type?) -> Operand {
        lit.type = desiredType ?? ty.invalid

        guard let desiredType = desiredType else {
            // NOTE: Callee will report an invalid type or handle the nil mode
            return Operand(mode: .nil, expr: lit, type: ty.invalid, constant: lit, dependencies: [])
        }

        guard isNilable(desiredType) else {
            reportError("'nil' is not convertable to '\(desiredType)'", at: lit.start)
            return Operand.invalid
        }

        lit.type = desiredType
        return Operand(mode: .computed, expr: lit, type: desiredType, constant: lit, dependencies: [])
    }

    @discardableResult
    mutating func check(basicLit lit: BasicLit, desiredType: Type?) -> Operand {
        switch lit.token {
        case .int:
            switch lit.text.prefix(2) {
            case "0x":
                let text = String(lit.text.dropFirst(2))
                lit.constant = UInt64(text, radix: 16)!
            case "0o":
                let text = String(lit.text.dropFirst(2))
                lit.constant = UInt64(text, radix: 8)!
            case "0b":
                let text = String(lit.text.dropFirst(2))
                lit.constant = UInt64(text, radix: 2)!
            default:
                lit.constant = UInt64(lit.text, radix: 10)!
            }
            if let desiredType = desiredType, isInteger(desiredType) {
                lit.type = desiredType
            } else if let desiredType = desiredType, isFloat(desiredType) {
                lit.type = desiredType
                lit.constant = Double(lit.constant as! UInt64)
            } else {
                lit.type = ty.untypedInteger
            }
        case .float:
            lit.constant = Double(lit.text)!
            if let desiredType = desiredType, isFloat(desiredType) {
                lit.type = desiredType
            } else {
                lit.type = ty.untypedFloat
            }
        case .string:
            lit.type = ty.string
        default:
            lit.type = ty.invalid
        }
        return Operand(mode: .computed, expr: lit, type: lit.type, constant: lit.constant, dependencies: [])
    }

    @discardableResult
    mutating func check(compositeLit lit: CompositeLit, desiredType: Type?) -> Operand {
        var dependencies: Set<Entity> = []
        let operand: Operand?
        let type: Type?
        if let explicitType = lit.explicitType {
            operand = check(expr: explicitType)
            dependencies.formUnion(operand!.dependencies)
            type = lowerFromMetatype(operand!.type, atNode: explicitType)
            lit.type = type!
        } else if let desiredType = desiredType {
            operand = nil
            type = desiredType
        } else {
            lit.type = ty.invalid
            reportError("Unable to determine type for composite literal", at: lit.start)
            return Operand.invalid
        }

        switch baseType(type!) {
        case let s as ty.Struct:
            if lit.elements.count > s.fields.count {
                reportError("Too many values in struct initializer", at: lit.elements[s.fields.count].start)
            }
            for (el, field) in zip(lit.elements, s.fields.orderedValues) {

                if let key = el.key {
                    guard let ident = key as? Ident else {
                        reportError("Expected identifier for key in composite literal for struct", at: key.start)
                        // bail, likely everything is wrong
                        return Operand(mode: .invalid, expr: lit, type: type, constant: nil, dependencies: operand?.dependencies ?? [])
                    }
                    guard let field = s.fields[ident.name] else {
                        reportError("Unknown field '\(ident)' for struct '\(type!)'", at: ident.start)
                        continue
                    }

                    el.checked = .structField(field)
                    let operand = check(expr: el.value, desiredType: field.type)
                    dependencies.formUnion(operand.dependencies)

                    el.type = operand.type
                    guard convert(el.type, to: field.type, at: el.value) else {
                        reportError("Cannot convert element \(operand) to expected type '\(field.type)'", at: el.value.start)
                        continue
                    }
                } else {
                    el.checked = .structField(field)
                    let operand = check(expr: el.value, desiredType: field.type)
                    dependencies.formUnion(operand.dependencies)

                    el.type = operand.type
                    guard convert(el.type, to: field.type, at: el.value) else {
                        reportError("Cannot convert element \(operand) to expected type '\(field.type)'", at: el.value.start)
                        continue
                    }
                }
            }
            lit.type = type!
            return Operand(mode: .computed, expr: lit, type: type, constant: nil, dependencies: dependencies)

        case let type as ty.Union:
            guard lit.elements.count == 1, let key = lit.elements[0].key as? Ident else {
                reportError("Union literals require exactly 1 named member", at: lit.start)
                // TODO: Return a correct union type anyway?
                return Operand.invalid
            }
            guard let unionCase = type.cases[key.name] else {
                reportError("Case \(key.name) not found in union", at: key.start)
                // TODO: Return a correct union type anyway?
                return Operand.invalid
            }

            let value = check(expr: lit.elements[0].value, desiredType: unionCase.type)

            guard convert(value.type, to: unionCase.type, at: lit.elements[0].value) else {
                reportError("Cannot convert \(value) to expected type \(unionCase.type)", at: lit.elements[0].value.start)
                // TODO: Return a correct union type anyway?
                return Operand.invalid
            }
            lit.elements[0].checked = .unionCase(unionCase)
            lit.type = type
            return Operand(mode: .computed, expr: lit, type: type, constant: nil, dependencies: dependencies)

        case var type as ty.Array:
            if type.length != nil {
                if lit.elements.count != type.length && lit.elements.count != 0 {
                    reportError("Element count (\(lit.elements.count)) does not match array length (\(type.length!))", at: lit.start)
                }
            } else {
                // NOTE: implicit array length
                type.length = lit.elements.count
            }

            for el in lit.elements {
                let operand = check(expr: el.value, desiredType: type.elementType)
                dependencies.formUnion(operand.dependencies)

                el.type = operand.type
                guard convert(el.type, to: type.elementType, at: el.value) else {
                    reportError("Cannot convert element \(operand) to expected type '\(type.elementType)'", at: el.value.start)
                    continue
                }
            }

            lit.type = type
            return Operand(mode: .computed, expr: lit, type: type, constant: nil, dependencies: dependencies)

        case let slice as ty.Slice:
            for el in lit.elements {
                let operand = check(expr: el.value, desiredType: slice.elementType)
                dependencies.formUnion(operand.dependencies)

                el.type = operand.type
                guard convert(el.type, to: slice.elementType, at: el.value) else {
                    reportError("Cannot convert element \(operand) to expected type '\(slice.elementType)'", at: el.value.start)
                    continue
                }
            }

            lit.type = slice
            return Operand(mode: .computed, expr: lit, type: slice, constant: nil, dependencies: dependencies)

        case let type as ty.Vector:
            if lit.elements.count != type.size {
                reportError("Element count (\(lit.elements.count)) does not match vector size (\(type.size))", at: lit.start)
            }

            for el in lit.elements {
                let operand = check(expr: el.value, desiredType: type.elementType)
                dependencies.formUnion(operand.dependencies)

                el.type = operand.type
                guard convert(el.type, to: type.elementType, at: el.value) else {
                    reportError("Cannot convert element \(operand) to expected type '\(type.elementType)'", at: el.value.start)
                    continue
                }
            }

            lit.type = type
            return Operand(mode: .computed, expr: lit, type: type, constant: nil, dependencies: dependencies)

        default:
            reportError("Invalid type for composite literal", at: lit.start)
            lit.type = ty.invalid
            return Operand.invalid
        }
    }

    @discardableResult
    mutating func check(polyType: PolyType) -> Type {
        if !isInvalid(polyType.type) {
            // Do not redeclare any poly types which have been checked before.
            return polyType.type
        }
        switch polyType.explicitType {
        case let ident as Ident:
            let entity = newEntity(ident: ident, type: ty.invalid, flags: .implicitType)
            declare(entity)
            var type: Type
            type = ty.Polymorphic(entity: entity, specialization: Ref(nil))
            type = ty.Metatype(instanceType: type)
            entity.type = type
            polyType.type = type
            return type
        case is ArrayType, is SliceType:
            fatalError("TODO")
        default:
            reportError("Unsupported polytype", at: polyType.start)
            // TODO: Better error for unhandled types here.
            polyType.type = ty.invalid
            return ty.invalid
        }
    }

    @discardableResult
    mutating func check(funcLit fn: FuncLit) -> Operand {
        var dependencies: Set<Entity> = []

        var needsSpecialization = false
        var typeFlags: ty.Function.Flags = .none
        var inputs: [Type] = []
        var outputs: [Type] = []

        if !fn.isSpecialization {
            var params: [Entity] = []
            pushContext()

            // FIXME: @unimplemented
            assert(fn.explicitType.labels != nil, "Currently function literals without argument names are disallowed")

            for (label, param) in zip(fn.explicitType.labels!, fn.explicitType.params) {
                if fn.isSpecialization && !isInvalid(param.type) && !isPolymorphic(param.type) {
                    // The polymorphic parameters type has been set by the callee
                    inputs.append(param.type)
                    continue
                }

                needsSpecialization = needsSpecialization || param.isPolymorphic

                let operand = check(expr: param)
                let type = lowerFromMetatype(operand.type, atNode: param)

                if let paramType = param as? VariadicType {
                    fn.flags.insert(paramType.isCvargs ? .cVariadic : .variadic)
                    typeFlags.insert(paramType.isCvargs ? .cVariadic : .variadic) // NOTE: Not sure this is useful on the type?
                }

                let entity = newEntity(ident: label, type: type, flags: param.isPolymorphic ? .polyParameter : .parameter)
                declare(entity)
                params.append(entity)
                dependencies.formUnion(operand.dependencies)

                inputs.append(type)
            }
            fn.params = params

            for result in fn.explicitType.results {
                let operand = check(expr: result)
                dependencies.formUnion(operand.dependencies)

                let type = lowerFromMetatype(operand.type, atNode: result)

                outputs.append(type)
            }
        } else { // fn.isSpecialization
            inputs = fn.explicitType.params
                .map({ lowerFromMetatype($0.type, atNode: $0) })
                .map(lowerSpecializedPolymorphics)
            outputs = fn.explicitType.results
                .map({ lowerFromMetatype($0.type, atNode: $0) })
                .map(lowerSpecializedPolymorphics)
        }

        let result = ty.Tuple.make(outputs)

        let prevReturnType = context.expectedReturnType
        context.expectedReturnType = result
        if !needsSpecialization { // FIXME: We need to partially check polymorphics to determine dependencies, Do we?
            let deps = check(stmt: fn.body)
            dependencies.formUnion(deps)
        }
        context.expectedReturnType = prevReturnType

        // TODO: Only allow single void return
        if isVoid(splatTuple(result)) {
            if fn.isDiscardable {
                reportError("#discardable on void returning function is superflous", at: fn.start)
            }
        } else {
            if !allBranchesRet(fn.body.stmts) {
                reportError("function missing return", at: fn.start)
            }
        }

        if needsSpecialization && !fn.isSpecialization {
            typeFlags.insert(.polymorphic)
            fn.type = ty.Function(node: fn, labels: fn.labels, params: inputs, returnType: result, flags: typeFlags)
            fn.checked = .polymorphic(declaringScope: context.scope.parent!, specializations: [])
        } else {
            fn.type = ty.Function(node: fn, labels: fn.labels, params: inputs, returnType: result, flags: typeFlags)
            fn.checked = .regular(context.scope)
        }

        if !fn.isSpecialization {
            popContext()
        }
        return Operand(mode: .computed, expr: fn, type: fn.type, constant: nil, dependencies: dependencies)
    }

    @discardableResult
    mutating func check(funcType fn: FuncType) -> Operand {
        var dependencies: Set<Entity> = []

        var typeFlags: ty.Function.Flags = .none
        var params: [Type] = []
        for param in fn.params {
            let operand = check(expr: param)
            dependencies.formUnion(operand.dependencies)

            let type = lowerFromMetatype(operand.type, atNode: param)

            if let param = param as? VariadicType {
                fn.flags.insert(param.isCvargs ? .cVariadic : .variadic)
                typeFlags.insert(param.isCvargs ? .cVariadic : .variadic)
            }
            params.append(type)
        }

        var returnTypes: [Type] = []
        for returnType in fn.results {
            let operand = check(expr: returnType)
            dependencies.formUnion(operand.dependencies)

            let type = lowerFromMetatype(operand.type, atNode: returnType)
            returnTypes.append(type)
        }

        let returnType = ty.Tuple.make(returnTypes)

        if isVoid(splatTuple(returnType)) && fn.isDiscardable {
            reportError("#discardable on void returning function is superflous", at: fn.start)
        }

        var type: Type
        type = ty.Function(node: nil, labels: fn.labels, params: params, returnType: returnType, flags: typeFlags)
        type = ty.Metatype(instanceType: type)
        fn.type = type
        return Operand(mode: .type, expr: fn, type: type, constant: nil, dependencies: dependencies)
    }

    @discardableResult
    mutating func check(field: StructField) -> Operand {
        let operand = check(expr: field.explicitType)

        let type = lowerFromMetatype(operand.type, atNode: field.explicitType)
        field.type = type
        return Operand(mode: .computed, expr: nil, type: type, constant: nil, dependencies: operand.dependencies)
    }

    @discardableResult
    mutating func check(struct s: StructType) -> Operand {
        var dependencies: Set<Entity> = []

        var width = 0
        var index = 0
        var fields: [ty.Struct.Field] = []
        for x in s.fields {
            let operand = check(field: x)
            dependencies.formUnion(operand.dependencies)

            for name in x.names {
                let field = ty.Struct.Field(ident: name, type: operand.type, index: index, offset: width)
                fields.append(field)

                if let named = x.type as? ty.Named, named.base == nil {
                    reportError("Invalid recursive type \(named)", at: name.start)
                    continue
                }
                // FIXME: This will align fields to bytes, maybe not best default?
                width = (width + x.type.width!).round(upToNearest: 8)
                index += 1
            }
        }
        var type: Type
        var flags: ty.Struct.Flags = .none
        if s.directives.contains(.packed) {
            flags.insert(.packed)
            s.directives.remove(.packed)
        }
        type = ty.Struct(width: width, flags: flags, node: s, fields: fields, isPolymorphic: false)
        type = ty.Metatype(instanceType: type)
        s.type = type
        for directive in s.directives {
            reportError("Directive \(directive) not valid on type of kind struct", at: s.keyword)
        }
        return Operand(mode: .type, expr: s, type: type, constant: nil, dependencies: dependencies)
    }

    @discardableResult
    mutating func check(polyStruct: PolyStructType) -> Operand {
        var dependencies: Set<Entity> = []

        var width = 0
        var index = 0
        var fields: [ty.Struct.Field] = []

        for x in polyStruct.polyTypes.list {
            check(polyType: x)
        }

        for x in polyStruct.fields {
            let operand = check(field: x)
            dependencies.formUnion(operand.dependencies)

            for name in x.names {
                let field = ty.Struct.Field(ident: name, type: operand.type, index: index, offset: width)
                fields.append(field)

                if let named = x.type as? ty.Named, named.base == nil {
                    reportError("Invalid recursive type \(named)", at: name.start)
                    continue
                }
                // FIXME: This will align fields to bytes, maybe not best default?
                width = (width + x.type.width!).round(upToNearest: 8)
                index += 1
            }
        }
        var type: Type
        type = ty.Struct(width: width, flags: .none, node: polyStruct, fields: fields, isPolymorphic: true)
        type = ty.Metatype(instanceType: type)
        polyStruct.type = type
        return Operand(mode: .type, expr: polyStruct, type: type, constant: nil, dependencies: dependencies)
    }

    mutating func check(union u: UnionType) -> Operand {
        var dependencies: Set<Entity> = []

        var largestWidth = 0
        var cases: [ty.Union.Case] = []
        for (i, x) in u.fields.enumerated() {
            let operand = check(field: x)
            dependencies.formUnion(operand.dependencies)

            for name in x.names {
                let casé = ty.Union.Case(ident: name, type: operand.type, tag: i)
                cases.append(casé)
                let width = operand.type.width!.round(upToNearest: 8)
                if width > largestWidth {
                    largestWidth = width
                }
            }
        }

        if let tag = u.tag {
            let operand = check(field: tag)
            if maxValueForInteger(width: operand.type.width!, signed: false) < cases.count {
                reportError("Tag specifies a width of \(operand.type!.width!) bits but the union has \(cases.count) cases, requiring \(positionOfHighestBit(cases.count) as Int) bits for inferred tagging", at: tag.start)
            }
        }

        var type: Type
        var flags: ty.Union.Flags = .none
        if u.directives.contains(.inlineTag) {
            flags.insert(.inlineTag)
            u.directives.remove(.inlineTag)
        }
        type = ty.Union(width: largestWidth, flags: flags, cases: cases)
        type = ty.Metatype(instanceType: type)
        u.type = type
        for directive in u.directives {
            reportError("Directive \(directive) not valid on type of kind union", at: u.keyword)
        }
        return Operand(mode: .type, expr: u, type: type, constant: nil, dependencies: dependencies)
    }

    @discardableResult
    mutating func check(enumType e: EnumType) -> Operand {
        var dependencies: Set<Entity> = []

        var backingType: ty.Integer?
        if let explicitType = e.explicitType {
            let operand = check(expr: explicitType)
            dependencies.formUnion(operand.dependencies)

            let type = lowerFromMetatype(operand.type, atNode: explicitType)
            if !isInteger(type) {
                reportError("Enum backing type must be an integer. We got \(operand)", at: explicitType.start)
            } else {
                backingType = baseType(type) as? ty.Integer
            }
        }

        assert(backingType != nil, implies: !isSigned(backingType!), "For now only unsigned integer values are supported for enum backingTypes")

        var minValue: IntegerConstant?
        var maxValue: IntegerConstant?
        if let backingType = backingType {
            if e.isFlags {
                minValue = 0
                maxValue = highestBitForValue(backingType.width!)
            } else {
                minValue = backingType.isSigned ? minValueForSignedInterger(width: backingType.width!) : 0
                maxValue = maxValueForInteger(width: backingType.width!, signed: backingType.isSigned)
            }
        }

        var currentValue: IntegerConstant = e.isFlags ? 1 : 0
        var largestValue: IntegerConstant = 0

        var firstCase = true

        var cases: [ty.Enum.Case] = []
        for caseNode in e.cases {
            if let caseValue = caseNode.value {
                let operand = check(expr: caseValue, desiredType: backingType)
                dependencies.formUnion(operand.dependencies)

                guard let constant = operand.constant else {
                    reportError("Expected constant value", at: caseValue.start)
                    continue
                }

                if let backingtype = backingType, !convert(operand.type, to: backingtype, at: caseValue) {
                    reportError("Cannot convert value \(operand) to expected type \(backingtype)", at: caseValue.start)
                    continue
                }

                guard let value = constant as? IntegerConstant else {
                    fatalError("Expected a constant integer not \(constant)")
                }

                if let minValue = minValue, value < minValue {
                    reportError("Value is less than the minimum value of type \(backingType!)", at: caseValue.start)
                    continue
                }

                currentValue = value
                largestValue = max(numericCast(value), largestValue)
            } else if !firstCase {
                // increment the currentValue if a value is not specified and it's not the first case

                // FIXME: Check for overflow?
                if e.isFlags {
                    guard isPowerOfTwo(currentValue) else {
                        reportError("Cannot infer next value in enum #flags sequence; previous value was not a power of 2.", at: caseNode.start)
                        continue
                    }
                    currentValue <<= 1
                } else {
                    currentValue += 1
                }
                largestValue = max(currentValue, largestValue)
            }

            firstCase = false
            if let maxValue = maxValue, currentValue > maxValue {
                reportError("Enum case value exceeds the maximum value for the enum type \(backingType!)", at: caseNode.start)
                continue
            }

            let `case` = ty.Enum.Case(ident: caseNode.name, value: caseNode.value, constant: currentValue)
            cases.append(`case`)
        }

        let width = backingType?.width ?? positionOfHighestBit(largestValue)
        var type: Type
        type = ty.Enum(width: width, backingType: backingType, isFlags: e.isFlags, cases: cases)
        type = ty.Metatype(instanceType: type)
        e.type = type
        return Operand(mode: .type, expr: e, type: type, constant: nil, dependencies: dependencies)
    }

    static let unaryOpPredicates: [Token: (Type) -> Bool] = [
        .add: isNumber,
        .sub: isNumber,
        .bnot: isInteger,
        .not: { isBoolean($0) || isPointer($0) },
        .lss: isPointer,
    ]


    @discardableResult
    mutating func check(unary: Unary, desiredType: Type?) -> Operand {
        let operand = check(expr: unary.element, desiredType: desiredType)

        switch unary.op {
        case .and: // addressOf
            guard operand.mode == .addressable else {
                reportError("Cannot take address of \(operand)", at: unary.start)
                return Operand.invalid
            }

            // TODO: Constant address of?
            unary.type = ty.Pointer(operand.type)
            return Operand(mode: .computed, expr: unary, type: unary.type, constant: nil, dependencies: operand.dependencies)

        default:
            break
        }

        if !Checker.unaryOpPredicates[unary.op]!(operand.type) {
            reportError("Operation '\(unary.op)' undefined for \(operand)", at: unary.start)
            return Operand.invalid
        }

        if unary.op == .not {
            assert(unary.element is Convertable)
            (unary.element as! Convertable).conversion = (operand.type, ty.bool)
            unary.type = ty.bool
        } else if unary.op == .lss {
            unary.type = (operand.type as! ty.Pointer).pointeeType
            return Operand(mode: .assignable, expr: unary, type: unary.type, constant: nil, dependencies: operand.dependencies)
        } else {
            unary.type = operand.type
        }

        let constant = apply(operand.constant, op: unary.op)
        return Operand(mode: .computed, expr: unary, type: unary.type, constant: constant, dependencies: operand.dependencies)
    }

    static let binaryOpPredicates: [Token: (Type) -> Bool] = [
        .add: isNumber,
        .sub: isNumber,
        .mul: isNumber,
        .quo: isNumber,
        .rem: isInteger,

        .and: { isInteger($0) || isEnumFlags($0) },
        .or:  { isInteger($0) || isEnumFlags($0) },
        .xor: { isInteger($0) || isEnumFlags($0) },
        .shl: { isInteger($0) || isEnumFlags($0) },
        .shr: { isInteger($0) || isEnumFlags($0) },

        .eql: isEquatable,
        .neq: isEquatable,

        .lss: { isComparable($0) || isEnum($0) },
        .gtr: { isComparable($0) || isEnum($0) },
        .leq: { isComparable($0) || isEnum($0) },
        .geq: { isComparable($0) || isEnum($0) },

        .land: isBoolean,
        .lor:  isBoolean,
    ]

    @discardableResult
    mutating func check(binary: Binary, desiredType: Type?) -> Operand {
        let lhs = check(expr: binary.lhs)
        let rhs = check(expr: binary.rhs)

        var lhsType = baseType(lhs.type)
        var rhsType = baseType(rhs.type)

        if lhs.mode == .nil {
            guard isNilable(rhs.type) else {
                reportError("Cannot infer type for \(lhs)", at: binary.lhs.start)
                return Operand.invalid
            }
            binary.lhs.type = binary.rhs.type
            lhsType = rhsType
        } else if rhs.mode == .nil {
            guard isNilable(lhs.type) else {
                reportError("Cannot infer type for \(rhs)", at: binary.rhs.start)
                return Operand.invalid
            }
            binary.rhs.type = binary.lhs.type
            rhsType = lhsType
        }

        if lhs.mode == .invalid || rhs.mode == .invalid {
            return Operand.invalid
        }

        if constrainUntyped(lhsType, to: rhsType) {
            binary.lhs.type = rhsType
        }
        if constrainUntyped(rhsType, to: lhsType) {
            binary.rhs.type = lhsType
        }

        if convert(lhsType, to: rhsType, at: binary.lhs) {
            lhsType = rhsType
        } else if convert(rhsType, to: lhsType, at: binary.rhs) {
            rhsType = lhsType
        }

        if lhsType != rhsType {
            if !isInvalid(lhsType) && !isInvalid(rhsType) {
                reportError("Mismatched types \(lhs) and \(rhs)", at: binary.start)
                return Operand.invalid
            }
            return Operand.invalid
        }

        if !Checker.binaryOpPredicates[binary.op]!(lhsType.unwrappingVector()) {
            reportError("Operation '\(binary.op)' undefined for type \(binary.lhs.type)", at: binary.opPos)
            return Operand.invalid
        }

        if binary.op == .eql || binary.op == .neq || binary.op == .leq || binary.op == .geq || binary.op == .lss || binary.op == .gtr || binary.op == .lor || binary.op == .land {
            if let desiredType = desiredType, isBoolean(desiredType), convert(lhs.type, to: desiredType, at: binary.lhs) {
                binary.type = desiredType
            } else {
                binary.type = ty.bool
            }
        } else {
            binary.type = lhsType
        }

        // TODO: We can check for div by 0 here for constants
        if (binary.op == .quo || binary.op == .rem) && isConstantZero(rhs.constant) {
            reportError("Division by zero", at: binary.rhs.start)
        }

        let constant = apply(lhs.constant, rhs.constant, op: binary.op)
        return Operand(mode: .computed, expr: binary, type: binary.type, constant: constant, dependencies: lhs.dependencies.union(rhs.dependencies))
    }

    @discardableResult
    mutating func check(ternary: Ternary, desiredType: Type?) -> Operand {
        var dependencies: Set<Entity> = []

        let condOperand = check(expr: ternary.cond, desiredType: ty.bool)
        dependencies.formUnion(condOperand.dependencies)

        guard isBoolean(condOperand.type) || isPointer(condOperand.type) || isNumber(condOperand.type) else {
            reportError("Expected a conditional value", at: ternary.cond.start)
            ternary.type = ty.invalid
            return Operand.invalid
        }
        var thenOperand: Operand?
        if let then = ternary.then {
            thenOperand = check(expr: then, desiredType: desiredType)
            dependencies.formUnion(thenOperand!.dependencies)
        }

        let elseOperand = check(expr: ternary.els, desiredType: thenOperand?.type)
        dependencies.formUnion(elseOperand.dependencies)
        
        if let thenType = thenOperand?.type, !convert(elseOperand.type, to: thenType, at: ternary.els) {
            reportError("Expected matching types", at: ternary.start)
        }
        ternary.type = elseOperand.type
        var constant: Value?
        if let cond = condOperand.constant as? UInt64 {
            constant = cond != 0 ? (thenOperand?.constant ?? cond) : elseOperand.constant
        }
        return Operand(mode: .computed, expr: ternary, type: ternary.type, constant: constant, dependencies: dependencies)
    }

    @discardableResult
    mutating func check(selector: Selector, desiredType: Type? = nil) -> Operand {
        var dependencies: Set<Entity> = []

        let operand = check(expr: selector.rec)
        dependencies.formUnion(operand.dependencies)

        let (underlyingType, levelsOfIndirection) = lowerPointer(baseType(operand.type))
        selector.levelsOfIndirection = levelsOfIndirection
        switch baseType(underlyingType) {
        case let file as ty.File:
            guard let member = file.memberScope.lookup(selector.sel.name) else {
                reportError("Member '\(selector.sel)' not found in scope of \(operand)", at: selector.sel.start)
                selector.checked = .invalid
                selector.type = ty.invalid
                return Operand.invalid
            }

            dependencies.insert(member)

            if member.type == nil {
                check(topLevelStmt: member.declaration!)
                assert(member.isChecked && member.type != nil)
            }

            selector.checked = .file(member)
            if member.isConstant {
                selector.constant = member.constant
            }
            selector.sel.entity = member
            if let desiredType = desiredType, isUntypedNumber(member.type!) {
                if constrainUntyped(member.type!, to: desiredType) {
                    selector.conversion = (member.type!, desiredType)
                    selector.type = desiredType
                    // TODO: Check for safe constant conversion
                    return Operand(mode: .addressable, expr: selector, type: desiredType, constant: member.constant, dependencies: dependencies)
                }
            }
            selector.type = member.type!
            return Operand(mode: .addressable, expr: selector, type: member.type, constant: member.constant, dependencies: dependencies)

        case let strućt as ty.Struct:
            guard let field = strućt.fields[selector.sel.name] else {
                reportError("Member '\(selector.sel)' not found in scope of \(operand)", at: selector.sel.start)
                selector.checked = .invalid
                selector.type = ty.invalid
                return Operand.invalid
            }
            selector.checked = .struct(field)
            selector.type = field.type
            return Operand(mode: .addressable, expr: selector, type: field.type, constant: nil, dependencies: dependencies)

        case let array as ty.Array:
            switch selector.sel.name {
            case "len":
                selector.checked = .staticLength(array.length)
                selector.type = ty.u64
            default:
                reportError("Member '\(selector.sel)' not found in scope of \(operand)", at: selector.sel.start)
                selector.checked = .invalid
                selector.type = ty.invalid
                return Operand.invalid
            }
            return Operand(mode: .addressable, expr: selector, type: selector.type, constant: nil, dependencies: dependencies)

        case let slice as ty.Slice:
            switch selector.sel.name {
            case "raw":
                selector.checked = .array(.raw)
                selector.type = ty.Pointer(slice.elementType)
            case "len":
                selector.checked = .array(.length)
                selector.type = ty.u64
            case "cap":
                selector.checked = .array(.capacity)
                selector.type = ty.u64
            default:
                reportError("Member '\(selector.sel)' not found in scope of \(operand)", at: selector.sel.start)
                selector.checked = .invalid
                selector.type = ty.invalid
            }
            return Operand(mode: .addressable, expr: selector, type: selector.type, constant: nil, dependencies: dependencies)

        case let vector as ty.Vector:
            var indices: [Int] = []
            let name = selector.sel.name

            for char in name {
                switch char {
                case "x", "r":
                    indices.append(0)
                case "y" where vector.size >= 2, "g" where vector.size >= 2:
                    indices.append(1)
                case "z" where vector.size >= 3, "b" where vector.size >= 3:
                    indices.append(2)
                case "w" where vector.size >= 4, "a" where vector.size >= 4:
                    indices.append(3)
                default:
                    reportError("'\(name)' is not a component of \(operand)'", at: selector.sel.start)
                    selector.checked = .invalid
                    selector.type = ty.invalid
                    return Operand(mode: .addressable, expr: selector, type: selector.type, constant: nil, dependencies: dependencies)
                }
            }

            if indices.count == 1 {
                selector.checked = .scalar(indices[0])
                selector.type = vector.elementType
            } else {
                selector.checked = .swizzle(indices)
                selector.type = ty.Vector(size: indices.count, elementType: vector.elementType)
            }

            return Operand(mode: .assignable, expr: selector, type: selector.type, constant: nil, dependencies: dependencies)

        case is ty.Anyy:
            switch selector.sel.name {
            case "type":
                selector.checked = .anyType
                selector.type = builtin.types.typeInfoType

            case "data":
                selector.checked = .anyData
                selector.type = ty.rawptr

            default:
                reportError("Member '\(selector.sel)' not found in scope of \(operand)", at: selector.sel.start)
                selector.checked = .invalid
                selector.type = ty.invalid
            }
            return Operand(mode: .addressable, expr: selector, type: selector.type, constant: nil, dependencies: dependencies)

        case let union as ty.Union:
            if selector.sel.name == "Tag" {
                selector.checked = .unionTag
                selector.type = union.tagType
                return Operand(mode: .addressable, expr: selector, type: union.tagType, constant: nil, dependencies: dependencies)
            }
            guard let casé = union.cases[selector.sel.name] else {
                reportError("Member '\(selector.sel)' not found in scope of \(operand)", at: selector.sel.start)
                selector.checked = .invalid
                selector.type = ty.invalid
                return Operand.invalid
            }
            selector.checked = .union(union, casé)
            selector.type = casé.type
            return Operand(mode: .addressable, expr: selector, type: casé.type, constant: nil, dependencies: dependencies)

        case let meta as ty.Metatype:
            switch baseType(meta.instanceType) {
            case let e as ty.Enum:
                guard let c = e.cases[selector.sel.name] else {
                    reportError("Case '\(selector.sel)' not found on enum \(operand)", at: selector.sel.start)
                    selector.type = ty.invalid
                    return Operand.invalid
                }
                selector.checked = .enum(c)
                selector.type = meta.instanceType
                return Operand(mode: .computed, expr: selector, type: selector.type, constant: c.constant, dependencies: dependencies)

            // NOTE: Should we support accessing union tags as constant members on their metatype?

            case let u as ty.Union:
                guard let c = u.cases[selector.sel.name] else {
                    reportError("Case '\(selector.sel)' not found on union \(operand)", at: selector.sel.start)
                    selector.type = ty.invalid
                    return Operand.invalid
                }
                selector.checked = .unionTagConstant(c)
                selector.type = u.tagType
                return Operand(mode: .computed, expr: selector, type: selector.type, constant: UInt64(c.tag), dependencies: dependencies)
            default:
                break
            }
            fallthrough

        default:
            // Don't spam diagnostics if the type is already invalid
            if !(baseType(operand.type) is ty.Invalid) {
                reportError("\(operand) does not have a member scope", at: selector.start)
            }

            selector.checked = .invalid
            selector.type = ty.invalid
            return Operand.invalid
        }
    }

    @discardableResult
    mutating func check(subscript sub: Subscript) -> Operand {
        var dependencies: Set<Entity> = []

        let receiver = check(expr: sub.rec)
        let index = check(expr: sub.index, desiredType: ty.i64)

        dependencies.formUnion(receiver.dependencies)
        dependencies.formUnion(index.dependencies)

        guard receiver.mode != .invalid && index.mode != .invalid else {
            sub.type = ty.invalid
            return Operand.invalid
        }

        if !isInteger(index.type) {
            reportError("Cannot subscript with non-integer type '\(index.type!)'", at: sub.index.start)
        }

        let type: Type
        switch baseType(lowerSpecializedPolymorphics(receiver.type)) {
        case let array as ty.Array:
            sub.type = array.elementType
            type = array.elementType

            // TODO: support compile time constants. Compile time constant support
            // will allows us to guard against negative indices as well
            if let lit = sub.index as? BasicLit, let value = lit.constant as? UInt64 {
                if value >= array.length {
                    reportError("Index \(value) is past the end of the array (\(array.length) elements)", at: sub.index.start)
                }
            }

        case let slice as ty.Slice:
            sub.type = slice.elementType
            type = slice.elementType

        case let pointer as ty.Pointer:
            sub.type = pointer.pointeeType
            type = pointer.pointeeType

        default:
            if !(receiver.type is ty.Invalid) {
                reportError("Unable to subscript \(receiver)", at: sub.start)
            }
            return Operand.invalid
        }

        return Operand(mode: .addressable, expr: sub, type: type, constant: nil, dependencies: dependencies)
    }

    @discardableResult
    mutating func check(slice: Slice) -> Operand {
        var dependencies: Set<Entity> = []

        let receiver = check(expr: slice.rec)
        let lo = slice.lo.map { check(expr: $0, desiredType: ty.i64) }
        let hi = slice.hi.map { check(expr: $0, desiredType: ty.i64) }

        dependencies.formUnion(receiver.dependencies)
        if let lo = lo {
            dependencies.formUnion(lo.dependencies)
            if  !isInteger(lo.type) {
                reportError("Cannot subscript with non-integer type", at: slice.lo!.start)
            }
        }
        if let hi = hi {
            dependencies.formUnion(hi.dependencies)
            if !isInteger(hi.type) {
                reportError("Cannot subscript with non-integer type", at: slice.lo!.start)
            }
        }

        switch baseType(receiver.type) {
        case let x as ty.Array:
            slice.type = ty.Slice(x.elementType)
            // TODO: Check for invalid hi & lo's when constant

        case let x as ty.Slice:
            slice.type = x
            // TODO: Check for invalid hi & lo's when constant

        default:
            if receiver.mode != .invalid {
                reportError("Unable to slice \(receiver)", at: slice.start)
            }
            slice.type = ty.invalid
            return Operand.invalid
        }

        return Operand(mode: .addressable, expr: slice, type: slice.type, constant: nil, dependencies: dependencies)
    }

    @discardableResult
    mutating func check(call: Call, desiredType: Type? = nil) -> Operand {
        var dependencies: Set<Entity> = []

        let callee = check(expr: call.fun)
        dependencies.formUnion(callee.dependencies)

        if callee.type is ty.Metatype {
            let lowered = callee.type.lower()
            if let strućt = lowered as? ty.Struct, strućt.isPolymorphic {
                return check(polymorphicCall: call, calleeType: strućt)
            }
            reportError("Cannot call \(callee)", at: call.start)
            return Operand.invalid
        }
        call.checked = .call

        var calleeType = baseType(callee.type!)
        if let pointer = calleeType as? ty.Pointer, isFunction(pointer.pointeeType) {
            calleeType = pointer.pointeeType
        }

        guard let calleeFn = calleeType as? ty.Function else {
            reportError("Cannot call non-funtion value '\(callee)'", at: call.start)
            call.type = ty.Tuple.make([ty.invalid])
            call.checked = .call
            return Operand.invalid
        }

        var builtin: BuiltinFunction?
        let funEntity = entity(from: call.fun)
        if calleeFn.isBuiltin, let b = builtinFunctions.first(where: { $0.entity === funEntity }) {
            if let customCheck = b.onCallCheck {

                let operand = customCheck(&self, call)
                var returnType = operand.type!
                if let tuple = returnType as? ty.Tuple {
                    returnType = splatTuple(tuple)
                }

                call.type = returnType
                call.checked = .builtinCall(b)

                return Operand(mode: .computed, expr: call, type: returnType, constant: operand.constant, dependencies: dependencies)
            }
            builtin = b
        }

        if call.args.count > calleeFn.params.count && !calleeFn.isVariadic {
            reportError("Too many arguments in call to \(callee)", at: call.args[calleeFn.params.count].start)
            call.type = calleeFn.returnType
            return Operand(mode: .computed, expr: call, type: calleeFn.returnType, constant: nil, dependencies: dependencies)
        }

        let requiredArgs = calleeFn.isVariadic ? calleeFn.params.count - 1 : calleeFn.params.count
        if call.args.count < requiredArgs {
            // Less arguments then parameters
            guard calleeFn.isVariadic, call.args.count + 1 == calleeFn.params.count else {
                reportError("Not enough arguments in call to '\(callee)'", at: call.start)
                return Operand(mode: .computed, expr: call, type: ty.invalid, constant: nil, dependencies: dependencies)
            }
        }

        if isPolymorphic(calleeFn) || calleeFn.isPolymorphic {
            return check(polymorphicCall: call, calleeType: calleeType as! ty.Function, desiredType: desiredType)
        }

        var paramArgPairs = AnySequence(zip(call.args, calleeFn.params))
        if calleeFn.isVariadic && call.args.count > requiredArgs {
            paramArgPairs = paramArgPairs.dropLast()
        }
        for (arg, expectedType) in paramArgPairs {
            let argument = check(expr: arg, desiredType: expectedType)
            dependencies.formUnion(argument.dependencies)

            guard convert(argument.type, to: expectedType, at: arg) else {
                reportError("Cannot convert value '\(argument)' to expected argument type '\(expectedType)'", at: arg.start,
                            attachNotes: "In call to \(callee)")
                continue
            }
        }

        if calleeFn.isVariadic {
            let excessArgs = call.args[requiredArgs...]
            let expectedType = (calleeFn.params.last as! ty.Slice).elementType

            if excessArgs.count == 1, let varg = excessArgs[excessArgs.startIndex] as? VariadicType {
                let expectedType = ty.Slice(expectedType)
                let arg = check(expr: varg.explicitType, desiredType: expectedType)
                dependencies.formUnion(arg.dependencies)
                if !convert(arg.type, to: expectedType, at: varg.explicitType) {
                    reportError("Cannot convert \(arg) to expected argument type '\(expectedType)'", at: varg.start)
                }
            } else {
                for arg in excessArgs {
                    guard !(arg is VariadicType) else {
                        // FIXME(Brett): express this error in a non-garbage way @cleanup
                        reportError("Variadic argument expansion only valid on final argument", at: arg.start)
                        break
                    }

                    let argument = check(expr: arg, desiredType: expectedType)
                    dependencies.formUnion(argument.dependencies)

                    // Only perform conversions if the variadics are not C style
                    guard calleeFn.isCVariadic || convert(argument.type, to: expectedType, at: arg) else {
                        reportError("Cannot convert \(argument) to expected argument type '\(expectedType)'", at: arg.start,
                                    attachNotes: "In call to '\(callee)'")
                        continue
                    }
                }
            }
        }

        if let labels = calleeFn.labels {
            for (label, parameter) in zip(call.labels, labels) {
                if let label = label, label.name != parameter.name {
                    reportError("Argument label '\(label.name)' does not match expected label: '\(parameter.name)'", at: label.start)
                }
            }
        }

        if let builtin = builtin {
            call.checked = .builtinCall(builtin)
        } else {
            call.checked = .call
        }

        let returnType = splatTuple(calleeFn.returnType)
        call.type = returnType
        return Operand(mode: .computed, expr: call, type: returnType, constant: nil, dependencies: dependencies)
    }

    @discardableResult
    mutating func check(cast: Cast, desiredType: Type?) -> Operand {
        var dependencies: Set<Entity> = []

        var operand: Operand
        var targetType = desiredType ?? ty.invalid


        if let explicitType = cast.explicitType {
            operand = check(expr: explicitType)
            targetType = lowerFromMetatype(operand.type, atNode: explicitType)

            dependencies.formUnion(operand.dependencies)
        }

        if let poly = targetType as? ty.Polymorphic, let val = poly.specialization.val {
            targetType = val
        }

        // pretend it works for all future statements
        cast.type = targetType

        operand = check(expr: cast.expr, desiredType: targetType)
        dependencies.formUnion(operand.dependencies)

        let exprType = operand.type!

        /*
        // NOTE: This is disabled because we would often cast in polymorphic functions and get the same type cast error.
        //  because we throw away their polymorphic type status we can't just use that to check, we should revisit this sometime.
        if exprType == targetType {
            reportError("Unnecissary cast \(operand) to same type", at: cast.start)
            return Operand(mode: .computed, expr: cast, type: targetType, constant: nil, dependencies: dependencies)
        }
        */

        switch cast.kind {
        case .autocast:
            if desiredType == nil {
                reportError("Unabled to infer type for autocast", at: cast.keyword)
            }
            fallthrough

        case .cast:
            guard canCast(exprType, to: targetType) else {
                reportError("Cannot cast \(operand) to unrelated type '\(targetType)'", at: cast.start)
                return Operand(mode: .computed, expr: cast, type: targetType, constant: nil, dependencies: dependencies)
            }

        case .bitcast:
            guard exprType.width == targetType.width else {
                reportError("Cannot bitcast \(operand) with width of \(operand.type.width!) to type of different size (\(targetType)) with width of \(targetType.width!)", at: cast.keyword)
                return Operand(mode: .computed, expr: cast, type: targetType, constant: nil, dependencies: dependencies)
            }

        default:
            fatalError()
        }

        return Operand(mode: .computed, expr: cast, type: targetType, constant: nil, dependencies: dependencies)
    }

    mutating func check(locationDirective l: LocationDirective, desiredType: Type? = nil) -> Operand {
        switch l.kind {
        case .file:
            l.type = ty.string
            l.constant = file.pathFirstImportedAs
        case .line:
            l.type = (desiredType as? ty.Integer) ?? ty.untypedInteger
            l.constant = UInt64(file.position(for: l.directive).line)
        case .location:
            // TODO: We need to support complex constants first.
            fatalError()
        case .function:
            guard context.nearestFunction != nil else {
                reportError("#function cannot be used outside of a function", at: l.start)
                l.type = ty.invalid
                return Operand.invalid
            }
            l.type = ty.string
            l.constant = context.nearestFunction?.name ?? "<anonymous fn>"
        default:
            preconditionFailure()
        }

        return Operand(mode: .computed, expr: l, type: l.type, constant: l.constant, dependencies: [])
    }

    mutating func check(inlineAsm asm: InlineAsm, desiredType: Type?) -> Operand {
        let returnType = desiredType ?? ty.void
        asm.type = returnType

        let asmString = check(basicLit: asm.asm, desiredType: ty.string)
        if asmString.type != ty.string {
            reportError("asm constant must be a string", at: asm.asm.start)
        }

        let constraints = check(basicLit: asm.constraints, desiredType: ty.string)
        if constraints.type != ty.string {
            reportError("asm constraints must be a comma-separated string", at: asm.constraints.start)
        }

        var dependencies: Set<Entity> = []

        var parameters: [Type] = []
        for arg in asm.arguments {
            let op = check(expr: arg)
            dependencies.formUnion(op.dependencies)
            parameters.append(op.type)
        }

        return Operand(
            mode: .computed,
            expr: asm,
            type: returnType,
            constant: nil,
            dependencies: dependencies
        )
    }

    mutating func check(polymorphicCall call: Call, calleeType: ty.Function, desiredType: Type? = nil) -> Operand {
        let fnLitNode = calleeType.node!

        // In the parameter scope we want to set T.specialization.val to the argument type.

        guard case .polymorphic(let declaringScope, var specializations) = fnLitNode.checked else {
            preconditionFailure()
        }

        // Find the polymorphic parameters and determine their types using the arguments provided

        var specializationTypes: [Type] = []
        for (arg, param) in zip(call.args, fnLitNode.params)
            where param.isPolyParameter // FIXME: We don't want the polymorphic type we want the polymorphic Node
        {
            guard !(arg is Nil) else {
                reportError("'nil' requires a contextual type", at: arg.start)
                return Operand.invalid
            }

            let argument = check(expr: arg)
            let type = constrainUntypedToDefault(argument.type!)
            // Use the constrained type for the argument
            arg.type = type

            var paramType = param.type!
            if calleeType.isVariadic {
                paramType = (paramType as! ty.Slice).elementType
            }

            guard specialize(polyType: paramType, with: type) else {
                reportError("Failed to specialize parameter \(param.name) (type \(param.type!)) with \(argument)", at: arg.start)
                return Operand.invalid
            }

            let specializationType = findPolymorphic(param.type!)
                .map(baseType)
                .map(lowerSpecializedPolymorphics)!

            specializationTypes.append(specializationType)
        }

        // Determine if the types used match any existing specializations
        if let specialization = specializations.first(matching: specializationTypes) {

            // check the remaining arguments
            for (arg, expectedType) in zip(call.args, specialization.strippedType.params)
                where isInvalid(arg.type)
            {
                let argument = check(expr: arg, desiredType: expectedType)

                guard convert(argument.type, to: expectedType, at: arg) else {
                    reportError("Cannot convert \(argument) to expected type '\(expectedType)'", at: arg.start)
                    continue
                }
            }

            let generated = specialization.generatedFunctionNode
            if generated.isVariadic {
                // Check the remaining arguments
                let requiredArgs = generated.isVariadic ? generated.params.count - 1 : generated.params.count
                var excessArgs = call.args[requiredArgs...]
                let expectedType = lowerSpecializedPolymorphics((generated.params.last?.type as! ty.Slice).elementType)
                if isPolymorphic(calleeType.params.last!) {
                    // If the variadic type is polymoprphic then we will have checked the first variadic argument already
                    excessArgs = excessArgs.dropFirst()
                }
                for arg in excessArgs {
                    let argument = check(expr: arg, desiredType: expectedType)
                    //                dependencies.formUnion(argument.dependencies)

                    // Only perform conversions if the variadics are not C style
                    guard generated.isCVariadic || convert(argument.type, to: expectedType, at: arg) else {
                        reportError("Cannot convert value '\(argument)' to expected argument type '\(expectedType)'", at: arg.start,
                                    attachNotes: "In call to '\(call.fun)'")
                        continue
                    }
                }
            }

            var returnType = splatTuple(specialization.strippedType.returnType)
            returnType = lowerSpecializedPolymorphics(returnType)

            call.type = returnType
            call.checked = .specializedCall(specialization)
            if let desiredType = desiredType, desiredType == returnType {
                // NOTE: This is used for changing `[]u8` (unamed) to `string` (named) when needed
                call.type = desiredType
            }
            return Operand(mode: .computed, expr: call, type: call.type, constant: nil, dependencies: [])
        }

        // generate a copy of the original FnLit to specialize with.
        let generated = copy(fnLitNode)
        generated.flags.insert(.specialization)

        // There must be 1 param for a function to be polymorphic.
        let originalFile = fnLitNode.params.first!.file!

        // create the specialization it's own scope
        let functionScope = Scope(parent: declaringScope)

        // Change to the scope of the generated function
        let callingScope = context.scope
        let prevNode = context.specializationCallNode
        context.scope = functionScope
        context.specializationCallNode = call

        var params: [Entity] = []

        // Declare polymorphic types for all polymorphic parameters
        for (arg, var param) in zip(call.args, generated.params) {
            // create a unique entity for every parameter
            param = copy(param)
            if param.isPolyParameter {
                // Firstly find the polymorphic type and it's specialization
                let type = findPolymorphic(param.type!)!

                // Create a unique entity for each specialization of each polymorphic type
                let entity = copy(type.entity)

                // Lower any polymorphic types within
                entity.type = lowerSpecializedPolymorphics(entity.type!)

                declare(entity)

            } else {
                assert(isInvalid(arg.type))
                let paramType = lowerSpecializedPolymorphics(param.type!)

                // Go back to the calling scope for checking

                context.scope = callingScope

                let argument = check(expr: arg, desiredType: paramType)

                context.scope = functionScope

                guard convert(argument.type, to: param.type!, at: arg) else {
                    reportError("Cannot convert \(argument) to expected type '\(paramType)'", at: arg.start)
                    return Operand.invalid // We want to early exit if we encounter issues.
                }
            }

            // declare the parameter for and check if there is any previous declaration of T
            declare(param)

            params.append(param)

            param.type = lowerSpecializedPolymorphics(param.type!)
            assert(!isPolymorphic(param.type!))
        }

        if generated.isVariadic {
            // Check the remaining arguments
            let requiredArgs = generated.params.count - 1
            var excessArgs = call.args[requiredArgs...]
            guard !excessArgs.isEmpty else {
                reportError("Failed to specialize '\(call)' (type \(calleeType))", at: call.start,
                            attachNotes: "Unable to find type for specializing '\(findPolymorphic(generated.params.last!.type!)!.entity.name)'")
                return Operand.invalid
            }
            let expectedType = lowerSpecializedPolymorphics((generated.params.last?.type as! ty.Slice).elementType)
            if isPolymorphic(calleeType.params.last!) {
                // If the variadic type is polymoprphic then we will have checked the first variadic argument already
                excessArgs = excessArgs.dropFirst()
            }
            for arg in excessArgs {
                let argument = check(expr: arg, desiredType: expectedType)
//                dependencies.formUnion(argument.dependencies)

                // Only perform conversions if the variadics are not C style
                guard generated.isCVariadic || convert(argument.type, to: expectedType, at: arg) else {
                    reportError("Cannot convert value '\(argument)' to expected argument type '\(expectedType)'", at: arg.start,
                                attachNotes: "In call to '\(call.fun)'")
                    continue
                }
            }
        }

        // TODO: How do we handle invalid types
        var type = check(funcType: generated.explicitType).type.lower() as! ty.Function
        type = lowerSpecializedPolymorphics(type) as! ty.Function

        // Find the entity we are calling with
        let callee = entity(from: call.fun)!
        // FIXME: No "." if the mangledNamePrefix is empty @mangling
        let prefix = callee.file!.irContext.mangledNamePrefix + "." + callee.name
        let suffix = specializationTypes
            .reduce("", { $0 + "$" + $1.description })
        let mangledName = prefix + suffix

        let specialization = FunctionSpecialization(file: originalFile, specializedTypes: specializationTypes, strippedType: type, generatedFunctionNode: generated, mangledName: mangledName)

        // TODO: @threadsafety
        compiler.specializations.append(specialization)
        specializations.append(specialization)
        fnLitNode.checked = .polymorphic(declaringScope: declaringScope, specializations: specializations)

        generated.params = params

        assert(functionScope.members.count > generated.explicitType.params.count, "There had to be at least 1 polymorphic type declared")

        _ = check(funcLit: generated)

        context.scope = callingScope
        context.specializationCallNode = prevNode

        /// Remove specializations from the result type for the callee to check with
        var calleeType = calleeType
        // FIXME: It looks like we are lowering Specialized Polymorphics at least twice (But likely more since we have probably done it prior also)
        calleeType.returnType.types = calleeType.returnType.types.map(lowerSpecializedPolymorphics)

        var returnType = splatTuple(calleeType.returnType)
        returnType = lowerSpecializedPolymorphics(returnType)

        call.type = returnType
        call.checked = .specializedCall(specialization)
        if let desiredType = desiredType, desiredType == returnType {
            // NOTE: This is used for changing `[]u8` (unamed) to `string` (named) when needed
            call.type = desiredType
        }

        return Operand(mode: .computed, expr: call, type: returnType, constant: nil, dependencies: [])
    }

    mutating func check(polymorphicCall call: Call, calleeType: ty.Struct) -> Operand {
        fatalError("TODO")
    }
}

extension Checker {

    // TODO: Version that takes an operand for better error message
    func lowerFromMetatype(_ type: Type, atNode node: Node, function: StaticString = #function, line: UInt = #line) -> Type {

        if let type = type as? ty.Metatype {
            return type.instanceType
        }

        reportError("'\(type)' cannot be used as a type", at: node.start, function: function, line: line)
        return ty.invalid
    }

    func lowerPointer(_ type: Type, levelsOfIndirection: Int = 0) -> (Type, levelsOfIndirection: Int) {
        switch type {
        case let type as ty.Pointer:
            return lowerPointer(type.pointeeType, levelsOfIndirection: levelsOfIndirection + 1)

        default:
            return (type, levelsOfIndirection)
        }
    }

    func newEntity(ident: Ident, type: Type? = nil, flags: Entity.Flag = .none, memberScope: Scope? = nil, owningScope: Scope? = nil, constant: Value? = nil) -> Entity {
        return Entity(ident: ident, type: type, flags: flags, constant: constant, file: file, memberScope: memberScope, owningScope: owningScope)
    }
}

extension Checker {

    func reportError(_ message: String, at pos: Pos, function: StaticString = #function, line: UInt = #line, attachNotes notes: String...) {

        // FIXME: this obviously isn't ideal, but it is possible that the pos is invalid in which case we need to do something
        let file = self.file.package.file(for: pos.fileno) ?? self.file
        file.addError(message, pos)
        if let currentSpecializationCall = context.specializationCallNode {
            // FIXME: This produces correct locations but the error added to the file above may be attached to the wrong file.
            file.attachNote("Called from: " + file.position(for: currentSpecializationCall.start).description)
        }
        #if DEBUG
            file.attachNote("During Checking, \(function), line \(line)")
            file.attachNote("At an offset of \(pos.offset) in the file")
        #endif

        for note in notes {
            file.attachNote(note)
        }
    }
}

extension Node {
    var isPolymorphic: Bool {
        switch self {
        case let array as ArrayType:
            return array.explicitType.isPolymorphic
        case let darray as SliceType:
            return darray.explicitType.isPolymorphic
        case let pointer as PointerType:
            return pointer.explicitType.isPolymorphic
        case let vector as VectorType:
            return vector.explicitType.isPolymorphic
        case let variadic as VariadicType:
            return variadic.explicitType.isPolymorphic
        case let fnType as FuncType:
            return fnType.params.reduce(false, { $0 || $1.isPolymorphic })
        case is PolyType, is PolyStructType, is PolyParameterList:
            return true
        default:
            return false
        }
    }
}

extension Array where Element == FunctionSpecialization {

    func first(matching specializationTypes: [Type]) -> FunctionSpecialization? {

        outer: for specialization in self {

            for (theirs, ours) in zip(specialization.specializedTypes, specializationTypes) {
                if theirs != ours {
                    continue outer
                }
            }
            return specialization
        }
        return nil
    }
}

func canSequence(_ type: Type) -> Bool {
    switch baseType(type) {
    case is ty.Array, is ty.Slice:
        return true
    default:
        return false
    }
}

func canVector(_ type: Type) -> Bool {
    switch baseType(type) {
    case is ty.Integer, is ty.Float, is ty.Polymorphic:
        return true
    default:
        return false
    }
}

func collectBranches(_ stmt: Stmt) -> [Stmt] {
    switch stmt {
    case is Return:
        return [stmt]
    case let b as Block:
        var branches: [Stmt] = []
        for s in b.stmts {
            branches.append(contentsOf: collectBranches(s))
        }
        return branches

    case let i as If:
        var branches = collectBranches(i.body)
        if let e = i.els {
            branches.append(contentsOf: collectBranches(e))
        }
        return branches

    default:
        return []
    }
}

func allBranchesRet(_ stmts: [Stmt]) -> Bool {
    var hasReturn = false
    var allChildrenRet: Bool?

    for stmt in stmts {
        var allRet = false

        switch stmt {
        case is Return:
            hasReturn = true
        case let i as If:
            var children = [i.body]
            if let e = i.els {
                children.append(e)
            }

            if allBranchesRet(children) {
                allRet = true
            }
        case let b as Block:
            allRet = allBranchesRet(b.stmts)
        case let s as Switch:
            allRet = allBranchesRet(s.cases)
        case let c as CaseClause:
            allRet = allBranchesRet(c.block.stmts)
        case let f as For:
            allRet = allBranchesRet(f.body.stmts)
        case let f as ForIn:
            allRet = allBranchesRet(f.body.stmts)
        case let stmt as ExprStmt:
            if let c = stmt.expr as? Call, isNoReturn(c.type) {
                allRet = true
            } else {
                continue
            }
        default:
            continue
        }

        if let a = allChildrenRet {
            allChildrenRet = a && allRet
        } else {
            allChildrenRet = allRet
        }
    }

    return hasReturn || (allChildrenRet ?? false)
}

let identChars  = Array("_abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ".unicodeScalars)
let digits      = Array("1234567890".unicodeScalars)
func pathToEntityName(_ path: String) -> String? {
    assert(!path.isEmpty)

    func isValidIdentifier(_ str: String) -> Bool {

        if !identChars.contains(str.unicodeScalars.first!) {
            return false
        }

        return str.unicodeScalars.reduce(true, { $0 && (identChars.contains($1) || digits.contains($1)) })
    }

    let filename = String(path
        .split(separator: "/").last!
        .split(separator: ".").first!)

    guard isValidIdentifier(filename) else {
        return nil
    }

    return filename
}

func resolveLibraryPath(_ name: String, for currentFilePath: String) -> String? {

    if name.hasSuffix(".framework") {
        // FIXME(vdka): We need to support non system frameworks
        return name
    }

    if let fullpath = absolutePath(for: name) {
        return fullpath
    }

    if let fullpath = absolutePath(for: name, relativeTo: currentFilePath) {
        return fullpath
    }

    // If the library does not exist at a relative path, check system library locations
    if let fullpath = absolutePath(for: name, relativeTo: "/usr/lib/") {
        return fullpath
    }

    // If the library does not exist at a relative path, check local library locations
    if let fullpath = absolutePath(for: name, relativeTo: "/usr/local/lib/") {
        return fullpath
    }


    return nil
}
