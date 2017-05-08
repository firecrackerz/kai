import LLVM

class IRGenerator {

    var file: ASTFile
    var context = Context()

    var checker: Checker
    var llvmPointers:   [Entity: IRValue]  = [:]
    
    let module: Module
    let builder: IRBuilder

    class Context {

        var currentProcedure: Procedure?

        var scope: Scope = .universal

        var escapePoints: EscapePoints?

        struct EscapePoints {
            var `break`: IRValue
            var `continue`: IRValue
        }
    }
    
    init(_ file: ASTFile, checker: Checker) throws {
        self.checker = checker
        self.file = file
        module = Module(name: file.name)
        builder = IRBuilder(module: module)
    }
    
    static func build(for file: ASTFile, checker: Checker) throws -> Module {
        let generator = try IRGenerator(file, checker: checker)
        generator.emitIntrinsics()
        generator.emitImported()
        generator.emitGlobals()

        return generator.module
    }
}

class Procedure {
    let scope: Scope
    let llvm: Function
    var type: FunctionType
    var returnValue: IRValue?
    var deferBlock: BasicBlock?
    var returnBlock: BasicBlock

    init(scope: Scope, llvm: Function, type: FunctionType, returnBlock: BasicBlock, returnValue: IRValue?) {
        self.scope = scope
        self.llvm = llvm
        self.type = type
        self.returnBlock = returnBlock
        self.returnValue = returnValue
    }
}





// MARK: Code Generation

extension IRGenerator {

    func emitIntrinsics() {

        for entity in Scope.universal.elements.orderedValues {
            guard case .proc? = entity.type?.kind else {
                continue
            }

            llvmPointers[entity] = builtinProcedures
                .first(where: { $0.0 === entity  })!
                .irGen(self)(entity)
        }
    }

    func emitImported() {
        for entity in file.importedEntities {
            let global = builder.addGlobal(entity.mangledName!, type: canonicalize(entity.type!))
            llvmPointers[entity] = global
        }
    }
    
    func emitGlobals() {
        for node in file.nodes {
            switch node {
            case .comment:
                break

            case .declValue:
                emitStmtDeclaration(node)

            case .declImport, .declLibrary:
                break
                
            default:
                print("unsupported type for: \(node.shortName)")
                break
            }
        }
    }
}

extension IRGenerator {

    func emitStmt(_ node: AstNode) {

        guard !node.isExpr else {
            _ = emitExpr(node)
            return
        }

        switch node {
        case .comment:
            break

        case .declValue:
            emitStmtDeclaration(node)
            
        case .stmtDefer:
            emitStmtDefer(node)        case .stmtExpr(let expr):
            // these are just expressions which do not have their values used
            emitStmt(expr)

        case .stmtAssign:
            emitStmtAssignment(node)

        case .stmtBlock(let stmts, _):
            pushScope(for: node)
            defer { popScope() }

            for stmt in stmts {
                emitStmt(stmt)
            }
            
        case .stmtReturn:
            emitStmtReturn(node)

        case .stmtIf:
            emitStmtIf(node)

        case .stmtFor:
            emitStmtFor(node)

        case .stmtBreak:
            builder.buildBr(context.escapePoints!.break as! BasicBlock)

        case .stmtContinue:
            builder.buildBr(context.escapePoints!.continue as! BasicBlock)
            
        default:
            fatalError()
        }
    }

    func emitStmtIf(_ node: AstNode) {

        guard case .stmtIf(let cond, let thenStmt, let elseStmt, _) = node else {
            panic()
        }

        let curFunction = builder.currentFunction!
        let thenBlock: BasicBlock = curFunction.appendBasicBlock(named: "if.then")
        var elseBlock: BasicBlock?
        let postBlock: BasicBlock

        if elseStmt != nil {
            elseBlock = curFunction.appendBasicBlock(named: "if.else")
        }

        postBlock = curFunction.appendBasicBlock(named: "if.post")

        //
        // Emit the conditional branch
        //

        let condVal = emitExprConditional(cond)

        builder.buildCondBr(condition: condVal, then: thenBlock, else: elseBlock ?? postBlock)

        //
        // Emit the `then` block
        //

        builder.positionAtEnd(of: thenBlock)

        emitStmt(thenStmt)

        if !thenBlock.hasTerminatingInstruction {
            builder.buildBr(postBlock)
        }

        //
        // Fixes the following code: `if a { if b { } } else { }`
        // Without the following `br` instruction inserted the post block for `if b` has no terminator and is therefore invalid.
        //

        if let insertBlock = builder.insertBlock, !insertBlock.hasTerminatingInstruction {
            builder.buildBr(postBlock)
        }

        if let elseBlock = elseBlock, let elseStmt = elseStmt {

            if (elseStmt.children.last?.isReturn ?? false || elseStmt.isReturn) &&
                (thenStmt.children.last?.isReturn ?? false || thenStmt.isReturn) {

                // If both the if and the else return then there is no need for a post block
                postBlock.removeFromParent()
            }

            //
            // Emit the `else` block
            //

            builder.positionAtEnd(of: elseBlock)

            emitStmt(elseStmt)

            // TODO(vdka): Does this always work correctly?
            if !elseBlock.hasTerminatingInstruction {
                builder.buildBr(postBlock)
            }
        }

        //
        // Set builder position to the end of the `if.post` block
        //

        if let insertBlock = builder.insertBlock, !insertBlock.hasTerminatingInstruction {
            builder.buildBr(postBlock)

            // NOTE(vkda): This is done for cosmetic beauty in the IR generated. Not actually meaningful.
            postBlock.moveAfter(insertBlock)
        }

        builder.positionAtEnd(of: postBlock)
    }

    func emitStmtDeclaration(_ node: AstNode) {
        guard case .declValue(_, let names, _, let values, _) = node else {
            panic(node)
        }
        // TODO(vdka): isRuntime? Is that in emission or just checking?

        let decl = checker.info.decls[node]!

        /// This should be a proc call.
        if names.count > 1, values.count == 1, let value = values.first {

            let procRetType = checker.info.types[value]!

            assert(procRetType.isTuple)

            let procRetValue = emitExpr(value)
            let retValue = builder.buildAlloca(type: procRetValue.type)
            builder.buildStore(procRetValue, to: retValue)

            for (index, entity) in decl.entities.enumerated() {
                if entity.name == "_" { continue }
                let irType = canonicalize(entity.type!)

                let rhsIrValuePtr = builder.buildStructGEP(retValue, index: index)

                let rhsIrValue = builder.buildLoad(rhsIrValuePtr)

                let lhsIrValue: IRValue
                if let function = context.currentProcedure?.llvm {
                    lhsIrValue = emitEntryBlockAlloca(in: function, type: irType, named: entity.name, default: rhsIrValue)
                } else {
                    lhsIrValue = emitGlobal(name: entity.name, type: irType, value: rhsIrValue)
                }

                llvmPointers[entity] = lhsIrValue
            }

        } else if decl.entities.count == 1, let entity = decl.entities.first,
            case .proc = entity.type!.kind, let value = decl.initExprs.first {

            emitProcedureDefinition(entity, value)
        } else if decl.entities.count == 1, let entity = decl.entities.first,
            entity.type!.isType, let value = decl.initExprs.first,
            case .litStruct = value {
            // struct definitions

            emitGlobalType(entity)
        } else if decl.entities.count == 1, let entity = decl.entities.first,
            case .array(let underlyingType, let count) = entity.type!.kind, values.count == 0 {
            
            let irType = ArrayType(elementType: canonicalize(underlyingType), count: Int(count))
            
            let irValuePtr: IRValue
            if let function = context.currentProcedure?.llvm {
                irValuePtr = emitEntryBlockAlloca(in: function, type: irType, named: entity.name)
            } else {
                irValuePtr = emitGlobal(name: entity.mangledName!, type: irType, value: nil)
            }
            
            llvmPointers[entity] = irValuePtr
        } else {
            assert(decl.entities.count == decl.initExprs.count)

            for (entity, value) in zip(decl.entities, decl.initExprs) {

                if entity.name == "_" {
                    continue // do nothing.
                }
                if case .alias? = entity.type?.kind {
                    continue
                }

                let entityType = entity.type!
                let irType = canonicalize(entityType)

                let irValue: IRValue?
                if case .directive = value {
                    irValue = nil
                } else {
                    irValue = emitExpr(value)
                }

                let irValuePtr: IRValue
                if let function = context.currentProcedure?.llvm {
                    irValuePtr = emitEntryBlockAlloca(in: function, type: irType, named: entity.name, default: irValue)
                } else {
                    irValuePtr = emitGlobal(name: entity.mangledName!, type: irType, value: irValue)
                }

                llvmPointers[entity] = irValuePtr
            }
        }
    }

    
    func emitStmtAssignment(_ node: AstNode) {
        guard case .stmtAssign(let op, let lhs, let rhs, _) = node else {
            panic(node)
        }

        var lhsIrPtrs: [IRValue?] = []
        for lhs in lhs {
            if lhs.isDispose {
                lhsIrPtrs.append(nil)
            }

            let lhsIrPtr = emitExpr(lhs, returnAddress: true)

            lhsIrPtrs.append(lhsIrPtr)
        }

        if lhs.count > 1, rhs.count == 1, let value = rhs.first {
            //
            // When lhs.count > 1 and the rhs.count is 1 then this *must* be a proc
            //

            let procRetType = checker.info.types[value]!

            assert(procRetType.isTuple)

            let procRetValue = emitExpr(value)
            let retValue = builder.buildAlloca(type: procRetValue.type)
            builder.buildStore(procRetValue, to: retValue)

            // FIXME(vdka): Revisit this emitter for proc return tuples and clean it up.
            for (index, lhsIrPtr) in lhsIrPtrs.enumerated() {
                guard let lhsIrPtr = lhsIrPtr else { continue }

                let rhsIrValuePtr = builder.buildStructGEP(retValue, index: index)
                let rhsIrValue = builder.buildLoad(rhsIrValuePtr)

                builder.buildStore(rhsIrValue, to: lhsIrPtr)
            }
        } else if lhsIrPtrs.count == 1 && rhs.count == 1,
            let lhsIrPtr = lhsIrPtrs.first,
            let lhs = lhs.first, let rhs = rhs.first {

            //
            // There is one expression on each side of the assignment
            //

            let rhsIrVal = emitExpr(rhs)

            if case .equals = op {

                guard let lhsIrPtr = lhsIrPtr else {
                    return // Do nothing `_ = 5`
                }

                builder.buildStore(rhsIrVal, to: lhsIrPtr)
                return
            }

            guard let lhsIrPtr = lhsIrPtr else {
                fatalError("_ += 5")
            }

            let lhsIrVal = builder.buildLoad(lhsIrPtr)

            switch op {
            case .equals:
                fatalError()

            case .addEquals:
                let r = builder.buildAdd(lhsIrVal, rhsIrVal)
                builder.buildStore(r, to: lhsIrPtr)

            case .subEquals:
                let r = builder.buildSub(lhsIrVal, rhsIrVal)
                builder.buildStore(r, to: lhsIrPtr)

            case .mulEquals:
                let r = builder.buildMul(lhsIrVal, rhsIrVal)
                builder.buildStore(r, to: lhsIrPtr)

            case .divEquals:
                let type = checker.info.types[lhs]!
                let r = builder.buildDiv(lhsIrVal, rhsIrVal, signed: type.isSigned)
                builder.buildStore(r, to: lhsIrPtr)

            case .modEquals:
                let type = checker.info.types[lhs]!
                let r = builder.buildRem(lhsIrVal, rhsIrVal, signed: type.isSigned)
                builder.buildStore(r, to: lhsIrPtr)

            case .rshiftEquals: // FIXME(vdka): Arithmatic shift?
                let r = builder.buildShr(lhsIrVal, rhsIrVal)
                builder.buildStore(r, to: lhsIrPtr)

            case .lshiftEquals:
                let r = builder.buildShl(lhsIrVal, rhsIrVal)
                builder.buildStore(r, to: lhsIrPtr)

            case .andEquals:
                let r = builder.buildAnd(lhsIrVal, rhsIrVal)
                builder.buildStore(r, to: lhsIrPtr)
                
            case .orEquals:
                let r = builder.buildOr(lhsIrVal, rhsIrVal)
                builder.buildStore(r, to: lhsIrPtr)
                
            case .xorEquals:
                let r = builder.buildXor(lhsIrVal, rhsIrVal)
                builder.buildStore(r, to: lhsIrPtr)
            }
        } else {
            assert(lhsIrPtrs.count == rhs.count)
            for (index, lhsIrPtr) in lhsIrPtrs.enumerated() {

                guard let lhsIrPtr = lhsIrPtr else {
                    continue
                }

                let rhs = rhs[index]
                let rhsIrVal = emitExpr(rhs)
                builder.buildStore(rhsIrVal, to: lhsIrPtr)
            }
        }
    }

    
    func emitStmtDefer(_ node: AstNode) {
        guard case .stmtDefer(let stmt, _) = node else {
            fatalError()
        }

        let curBlock = builder.insertBlock!
        let returnBlock = context.currentProcedure!.returnBlock

        let curFunction = builder.currentFunction!

        if context.currentProcedure!.deferBlock == nil {
            context.currentProcedure!.deferBlock = curFunction.appendBasicBlock(named: "defer")
            builder.positionAtEnd(of: context.currentProcedure!.deferBlock!)
            builder.buildBr(returnBlock)
        }

        let deferBlock  = context.currentProcedure!.deferBlock!

        if let firstInst = deferBlock.firstInstruction {
            //
            // By positioning before the first Instruction we ensure the things defered last execute first
            //
            builder.positionBefore(firstInst)
        }

        // At scope exit, reset the builder position
        defer { builder.positionAtEnd(of: curBlock) }

        emitStmt(stmt)
    }

    func emitStmtFor(_ node: AstNode) {
        guard case .stmtFor(let initializer, let cond, let post, let body, _) = node else {
            panic()
        }

        pushScope(for: body)
        defer { popScope() }

        let curFunction = builder.currentFunction!

        // Set these later to ensure correct order. (as a viewer)
        var loopBody: BasicBlock
        var loopDone: BasicBlock

        var loopCond: BasicBlock?
        var loopPost: BasicBlock?

        if let initializer = initializer {
            emitStmt(initializer)
        }

        if let cond = cond {

            loopCond = curFunction.appendBasicBlock(named: "for.cond")
            if post != nil {
                loopPost = curFunction.appendBasicBlock(named: "for.post")
            }
            loopBody = curFunction.appendBasicBlock(named: "for.body")
            loopDone = curFunction.appendBasicBlock(named: "for.done")

            builder.buildBr(loopCond!)

            builder.positionAtEnd(of: loopCond!)

            let condVal = emitExprConditional(cond)

            builder.buildCondBr(condition: condVal, then: loopBody, else: loopDone)
        } else {
            if post != nil {
                loopPost = curFunction.appendBasicBlock(named: "for.post")
            }
            loopBody = curFunction.appendBasicBlock(named: "for.body")
            loopDone = curFunction.appendBasicBlock(named: "for.done")

            builder.buildBr(loopBody)
        }

        context.escapePoints = Context.EscapePoints(break: loopDone, continue: loopPost ?? loopCond ?? loopBody)

        builder.positionAtEnd(of: loopBody)

        guard case .stmtBlock(let stmts, _) = body else {
            panic()
        }
        for stmt in stmts {
            emitStmt(stmt)
        }

        let hasJump = builder.insertBlock?.lastInstruction?.isATerminatorInst ?? false

        if let post = post {

            if !hasJump {
                builder.buildBr(loopPost!)
            }
            builder.positionAtEnd(of: loopPost!)

            emitStmt(post)

            builder.buildBr(loopCond!)
        } else if let loopCond = loopCond {
            // `for x < 5 { /* ... */ }` || `for i := 1; x < 5; { /* ... */ }`

            if !hasJump {
                builder.buildBr(loopCond)
            }
        } else {
            // `for { /* ... */ }`
            if !hasJump {
                builder.buildBr(loopBody)
            }
        }

        builder.positionAtEnd(of: loopDone)
    }

    func emitStmtReturn(_ node: AstNode) {
        guard let currentProcedure = context.currentProcedure else {
            fatalError("Return statement outside of procedure")
        }

        guard case .stmtReturn(let values, _) = node else {
            panic()
        }

        if values.count == 1, let value = values.first {
            let irValue = emitExpr(value)

            if !(irValue is VoidType) {
                builder.buildStore(irValue, to: currentProcedure.returnValue!)
            }
        }
        if values.count > 1 {
            var retVal = builder.buildLoad(currentProcedure.returnValue!)
            for (index, value) in values.enumerated() {
                let irValue = emitExpr(value)
                retVal = builder
                    .buildInsertValue(aggregate: retVal, element: irValue, index: index)
            }

            builder.buildStore(retVal, to: currentProcedure.returnValue!)
        }

        if let deferBlock = currentProcedure.deferBlock {
            builder.buildBr(deferBlock)
        } else {
            builder.buildBr(currentProcedure.returnBlock)
        }
    }

    func emitEntryBlockAlloca(in function: Function, type: IRType, named name: String, default defaultValue: IRValue? = nil) -> IRValue {

        let prevBlock = builder.insertBlock!

        let entryBlock = function.entryBlock!

        if let first = entryBlock.firstInstruction {
            builder.position(first, block: entryBlock)
        }

        let allocation = builder.buildAlloca(type: type, name: name)

        // return to the prev location
        builder.positionAtEnd(of: prevBlock)

        if let defaultValue = defaultValue {
            builder.buildStore(defaultValue, to: allocation)
        }

        return allocation
    }

    func emitProcedurePrototype(_ entity: Entity) -> Function {
        if let function = module.function(named: entity.mangledName!) {
            return function
        }

        let procIrType = canonicalize(entity.type!) as! FunctionType

        let procedure = builder.addFunction(entity.mangledName!, type: procIrType)

        guard case .proc(let params, _, _) = entity.type!.kind else {
            panic()
        }

        for (var paramIr, param) in zip(procedure.parameters, params) {

            if param.name != "_" {
                paramIr.name = param.name
            }
        }

        return procedure
    }

    @discardableResult
    func emitProcedureDefinition(_ entity: Entity, _ node: AstNode) -> Function {

        if let llvmPointer = llvmPointers[entity] {
            return llvmPointer as! Function
        }

        guard case let .litProc(_, body, _) = node else {
            preconditionFailure()
        }

        let prevBlock = builder.insertBlock
        defer {
            if let prevBlock = prevBlock {
                builder.positionAtEnd(of: prevBlock)
            }
        }

        // TODO(Brett): use mangled name when available
        var name = entity.mangledName!
        if case .directive("foreign", let args, _) = body, case .litString(let symbolName, _)? = args[safe: 1] {
            name = symbolName
        }

        let proc = emitProcedurePrototype(entity)

        llvmPointers[entity] = proc

        if case .directive("foreign", _, _) = body {
            return proc
        }

        let scope = entity.childScope!
        let previousScope = context.scope
        context.scope = scope
        defer {
            context.scope = previousScope
        }

        let entryBlock = proc.appendBasicBlock(named: "entry")
        let returnBlock = proc.appendBasicBlock(named: "return")

        let type = checker.info.types[node]!
        let irType = canonicalize(type) as! FunctionType

        guard case .proc(let params, let results, _) = type.kind else {
            panic()
        }

        var resultValue: IRValue? = nil

        builder.positionAtEnd(of: entryBlock)

        if !(irType.returnType is VoidType) {

            resultValue = emitEntryBlockAlloca(in: proc, type: irType.returnType, named: "result")
        }

        var args: [IRValue] = []
        for (i, param) in params.enumerated() {

            // TODO(Brett): values

            let arg = proc.parameter(at: i)!
            let argPointer = emitEntryBlockAlloca(in: proc, type: arg.type, named: arg.name)

            builder.buildStore(arg, to: argPointer)

            llvmPointers[param] = argPointer
            args.append(argPointer)
        }

        let procedure = Procedure(scope: scope, llvm: proc, type: irType, returnBlock: returnBlock, returnValue: resultValue)

        let previousProcPointer = context.currentProcedure
        context.currentProcedure = procedure
        defer {
            context.currentProcedure = previousProcPointer
        }

        guard case .stmtBlock(let stmts, _) = body else {
            panic()
        }
        for stmt in stmts {
            emitStmt(stmt)
        }

        let insert = builder.insertBlock!
        if !insert.hasTerminatingInstruction {
            if let deferBlock = procedure.deferBlock {
                builder.buildBr(deferBlock)
            } else {
                builder.buildBr(returnBlock)
            }
        }

        returnBlock.moveAfter(proc.lastBlock!)
        builder.positionAtEnd(of: returnBlock)

        if irType.returnType is VoidType {
            builder.buildRetVoid()
        } else {
            let result = builder.buildLoad(resultValue!, name: "result")
            builder.buildRet(result)
        }

        return proc
    }

    func emitExpr(_ node: AstNode, returnAddress: Bool = false) -> IRValue {
        assert(node.isExpr || node.isIdent)

        switch node {
        case .litString, .litFloat, .litInteger, .litProc, .litCompound:
            assert(!returnAddress)
            return emitExprLiteral(node)

        // FIXME(vdka): Feels a bit hacky.
        case .ident("true", _):
            assert(!returnAddress)
            return IntType.int1.constant(1)

        case .ident("false", _):
            assert(!returnAddress)
            return IntType.int1.constant(0)

        case .ident("nil", _):
            assert(!returnAddress)
            let type = checker.info.types[node]!
            return canonicalize(type).constPointerNull()

        case .ident(let identifier, _):

            let entity = context.scope.lookup(identifier)!
            let ptr = llvmPointers[entity]!

            if returnAddress {
                return ptr
            }

            return builder.buildLoad(ptr)

        case .exprParen(let expr, _):
            assert(!returnAddress) // TODO(vdka): we should ban paren'd lvalues
            return emitExpr(expr)

        case .exprDeref(let expr, _):
            let ptr = emitExpr(expr)

            if returnAddress {
                return ptr
            }
            return builder.buildLoad(ptr)

        case .exprUnary:
            return emitExprUnary(node)

        case .exprBinary:
            return emitExprBinary(node)

        case .exprTernary:
            return emitExprTernary(node)

        case .exprSubscript:
            return emitExprSubscript(node, returnAddress: returnAddress)

        case .exprCall:
            if checker.info.casts.contains(node) {
                return emitExprCast(node)
            }
            return emitExprCall(node)

        case .exprSelector:
            return emitExprSelector(node, returnAddress: returnAddress)

        default:
            if node.isExpr {
                fatalError("Failed to handle all expressions in \(#function)")
            }

            panic()
        }
    }

    @discardableResult
    func emitExprLiteral(_ node: AstNode) -> IRValue {
        switch node {
        case .litInteger(let val, _):
            let type = checker.info.types[node]!


            //
            // A literal integer can also be a floating point type if constrained to be.
            //

            switch canonicalize(type) {
            case let type as IntType:
                return type.constant(val)

            case let type as FloatType:
                return type.constant(Double(val))

            default:
                fatalError()
            }

        case .litFloat(let val, _):
            let type = checker.info.types[node]!
            return (canonicalize(type) as! FloatType).constant(val)

        case .litString(let val, _):
            return builder.buildGlobalStringPtr(val.escaped)

        case .litCompound(_, let elements, _):
            let type = checker.info.types[node]!

            switch type.kind {
            case .named:
                if type.isStruct {
                    fallthrough
                }

                unimplemented() // Named arrays? `People :: [5]Person`

            case .struct:
                let values = elements.map {
                    emitExpr($0)
                }

                var val = canonicalize(type).undef()

                for (index, value) in values.enumerated() {
                    val = builder.buildInsertValue(aggregate: val, element: value, index: index)
                }

                return val

            case .array(let underlyingType, _):
                let values = elements.map {
                    emitExpr($0)
                }
                // FIXME(vdka): For literals that do not exactly match the count of the array they are assigned to this emits bad IR.
                return ArrayType.constant(values, type: canonicalize(underlyingType))

            default:
                unimplemented("Emitting constants for \(type)")
            }

        default:
            fatalError()
        }
    }

    func emitExprCast(_ node: AstNode) -> IRValue {
        guard case .exprCall(let r, let args, _) = node else {
            panic()
        }

        assert(checker.info.casts.contains(node))

        let arg = args.first!

        let argType = checker.info.types[arg]!
        let outType = checker.info.types[r]!.underlyingType!

        let outIrType = canonicalize(outType)
        
        if case .array = argType.kind, case .pointer = outType.kind {
            let argIrVal  = emitExpr(arg, returnAddress: true)
            
            return builder.buildBitCast(argIrVal, type: outIrType)
        } else if outType.width == argType.width {
            let argIrVal  = emitExpr(arg)
            
            if argType.isFloat && outType.isInteger {
                return builder.buildFPToInt(argIrVal, type: outIrType as! IntType, signed: outType.isSigned)
            } else if argType.isInteger && outType.isFloat {
                return builder.buildIntToFP(argIrVal, type: outIrType as! FloatType, signed: argType.isSigned)
            }

            return builder.buildBitCast(argIrVal, type: outIrType)
        } else if outType.width < argType.width {
            let argIrVal  = emitExpr(arg)
            
            return builder.buildTrunc(argIrVal, type: outIrType)
        } else if outType.width > argType.width, outType.isInteger && argType.isInteger {
            let argIrVal  = emitExpr(arg)
            
            if argType.isSigned {

                return builder.buildSExt(argIrVal, type: outIrType)
            } else {

                return builder.buildZExt(argIrVal, type: outIrType)
            }
        } else if argType.isFloat && outType.isFloat {
            let argIrVal  = emitExpr(arg)
            
            return builder.buildFPCast(argIrVal, type: outIrType)
        } else if argType.isInteger && outType.isFloat {
            let argIrVal  = emitExpr(arg)
            
            return builder.buildIntToFP(argIrVal, type: outIrType as! FloatType, signed: argType.isSigned)
        } else {
            
            fatalError("I probably missed things")
        }
    }

    @discardableResult
    func emitExprCall(_ node: AstNode) -> IRValue {

        // TODO(vdka): We can have receivers that could be called that are not identifiers ie:
        /*
         foo : [] (void) -> void = [(void) -> void { print("hello") }]
         foo[0]()
         */

        guard
            case .exprCall(let receiver, let args, _) = node,
            case .ident(let ident, _) = receiver
            else {
                preconditionFailure()
        }

        let receiverEntity = context.scope.lookup(ident)!

        // TODO(vdka): Just `emitExpr(rec)`
        let function = llvmPointers[receiverEntity] as! Function
        //let function = module.function(named: ident)!

        var irArgs: [IRValue] = []
        for arg in args {
            let val = emitExpr(arg)
            irArgs.append(val)
        }

        return builder.buildCall(function, args: irArgs)
    }

    func emitExprUnary(_ node: AstNode, returnAddress: Bool = false) -> IRValue {
        guard case .exprUnary(let op, let expr, _) = node else {
            panic()
        }

        let type = checker.info.types[expr]!

        switch op {
        case .plus: // This is oddly a do nothing kind of operator. Lazy guy.
            return emitExpr(expr)

        case .minus:
            let val = emitExpr(expr)
            return builder.buildNeg(val)

        case .bang:
            let val = emitExpr(expr)
            if type === Type.bool {
                return builder.buildNot(val)
            } else {
                let truncdVal = builder.buildTrunc(val, type: IntType.int1)
                return builder.buildNot(truncdVal)
            }

        case .tilde:
            let val = emitExpr(expr)
            return builder.buildNot(val)

        case .ampersand:
            switch expr {
            case .ident(let name, _):
                let entity = context.scope.lookup(name)!
                return llvmPointers[entity]!

            case .exprSubscript:
                return emitExprSubscript(expr, returnAddress: true)
                
            default:
                return emitExpr(expr)
            }

        case .asterix:
            let val = emitExpr(expr)
            return builder.buildLoad(val)

        default:
            unimplemented("Unary Operator '\(op)'")
        }
    }

    // TODO(vdka): Check the types to determine llvm calls
    func emitExprBinary(_ node: AstNode) -> IRValue {

        guard case .exprBinary(let op, let lhs, let rhs, _) = node else {
            panic()
        }

        var lvalue = emitExpr(lhs)
        var rvalue = emitExpr(rhs)

        let lhsType = checker.info.types[lhs]!
        let rhsType = checker.info.types[rhs]!

        // TODO(vdka): Trunc or Ext if needed / possible

        if lhsType !== rhsType {
            if lhsType.width == rhsType.width {
                //
                // `x: uint = 1; y: int = 1; z := x + y`
                // We don't know what the return type should be so it's an error caught in the checker
                //
                panic()
            }
            if lhsType.isUnconstrained && !lhs.isBasicLit {
                if lhsType.isUnsigned {
                    lvalue = builder.buildZExt(lvalue, type: rvalue.type)
                } else {
                    lvalue = builder.buildSExt(lvalue, type: rvalue.type)
                }
            }
            if rhsType.isUnconstrained && !rhs.isBasicLit {
                if rhsType.isUnsigned {
                    rvalue = builder.buildZExt(rvalue, type: lvalue.type)
                } else {
                    rvalue = builder.buildSExt(rvalue, type: lvalue.type)
                }
            }
        }

        switch op {
        case .plus:
            return builder.buildAdd(lvalue, rvalue)

        case .minus:
            return builder.buildSub(lvalue, rvalue)

        case .asterix:
            return builder.buildMul(lvalue, rvalue)

        case .slash:
            if lhsType.isUnsigned {

                return builder.buildDiv(lvalue, rvalue, signed: false)
            } else {

                return builder.buildDiv(lvalue, rvalue, signed: true)
            }

        case .percent:
            if lhsType.isUnsigned {

                return builder.buildRem(lvalue, rvalue, signed: false)
            } else {

                return builder.buildRem(lvalue, rvalue, signed: true)
            }

        // TODO(vdka): Are these arithmatic or logical? Which should they be?
        case .doubleLeftChevron:
            return builder.buildShl(lvalue, rvalue)

        case .doubleRightChevron:
            return builder.buildShr(lvalue, rvalue)

        case .leftChevron:
            if lhsType.isUnsigned {
                return builder.buildICmp(lvalue, rvalue, .unsignedLessThan)
            } else if lhsType.isInteger {
                return builder.buildICmp(lvalue, rvalue, .signedLessThan)
            } else if lhsType.isFloat {
                return builder.buildFCmp(lvalue, rvalue, .orderedLessThan)
            }
            panic()

        case .leftChevronEquals:
            if lhsType.isUnsigned {
                return builder.buildICmp(lvalue, rvalue, .unsignedLessThanOrEqual)
            } else if lhsType.isInteger {
                return builder.buildICmp(lvalue, rvalue, .signedLessThanOrEqual)
            } else if lhsType.isFloat {
                return builder.buildFCmp(lvalue, rvalue, .orderedLessThanOrEqual)
            }
            panic()

        case .rightChevron:
            if lhsType.isUnsigned {
                return builder.buildICmp(lvalue, rvalue, .unsignedGreaterThan)
            } else if lhsType.isInteger {
                return builder.buildICmp(lvalue, rvalue, .signedGreaterThan)
            } else if lhsType.isFloat {
                return builder.buildFCmp(lvalue, rvalue, .orderedGreaterThan)
            }
            panic()

        case .rightChevronEquals:
            if lhsType.isUnsigned {
                return builder.buildICmp(lvalue, rvalue, .unsignedGreaterThanOrEqual)
            } else if lhsType.isInteger {
                return builder.buildICmp(lvalue, rvalue, .signedGreaterThanOrEqual)
            } else if lhsType.isFloat {
                return builder.buildFCmp(lvalue, rvalue, .orderedGreaterThanOrEqual)
            }
            panic()

        case .equalsEquals:
            if lhsType.isInteger {
                return builder.buildICmp(lvalue, rvalue, .equal)
            } else if lhsType.isFloat {
                return builder.buildFCmp(lvalue, rvalue, .orderedEqual)
            }
            panic()

        case .bangEquals:
            if lhsType.isInteger {
                return builder.buildICmp(lvalue, rvalue, .notEqual)
            } else if lhsType.isFloat {
                return builder.buildFCmp(lvalue, rvalue, .orderedNotEqual)
            }
            return builder.buildICmp(lvalue, rvalue, .notEqual)

        case .ampersand:
            return builder.buildAnd(lvalue, rvalue)

        case .pipe:
            return builder.buildOr(lvalue, rvalue)

        case .carot:
            return builder.buildXor(lvalue, rvalue)

        case .doubleAmpersand:
            let r = builder.buildAnd(lvalue, rvalue)
            return builder.buildTrunc(r, type: IntType.int1)

        case .doublePipe:
            let r = builder.buildOr(lvalue, rvalue)
            return builder.buildTrunc(r, type: IntType.int1)

        default:
            unimplemented("Binary Operator '\(op)'")
        }
    }

    func emitExprTernary(_ node: AstNode) -> IRValue {
        guard case .exprTernary(let condExpr, let thenExpr, let elseExpr, _) = node else {
            panic()
        }

        let condVal = emitExprConditional(condExpr)
        let thenVal = emitExpr(thenExpr)
        let elseVal = emitExpr(elseExpr)

        return builder.buildSelect(condVal, then: thenVal, else: elseVal)
    }

    func emitExprSubscript(_ node: AstNode, returnAddress: Bool = false) -> IRValue {
        guard case .exprSubscript(let receiver, let value, _) = node else {
            preconditionFailure()
        }

        let lvalue: IRValue
        
        switch receiver {
        case .ident(let identifier, _):
            let entity = context.scope.lookup(identifier)!
            lvalue = llvmPointers[entity]!
            
        default:
            unimplemented()
        }
        
        let index = emitExpr(value)

        let ptr: IRValue
        let type = checker.info.types[receiver]!
        if type.isArray {
            ptr = builder.buildGEP(lvalue, indices: [IntType.int64.zero(), index])
        } else {
            let lvalue = builder.buildLoad(lvalue)
            ptr = builder.buildGEP(lvalue, indices: [index])
        }

        if returnAddress || type.isPointeresque {
            return ptr
        }

        return builder.buildLoad(ptr)
    }

    func emitExprSelector(_ node: AstNode, returnAddress: Bool = false) -> IRValue {
        guard case .exprSelector(let receiver, let member, _) = node else {
            panic()
        }

        if case .ident(let ident, _) = receiver,
            let recvEntity = context.scope.lookup(ident),
            case .importName = recvEntity.kind {

            //
            // Import entities are phantoms which don't actually exist at an IR level.
            // As such this code effectively bypasses the first node.
            //
            let entity = recvEntity.childScope!.lookup(member.identifier)!
            if let val = llvmPointers[entity] {

                return builder.buildLoad(val)
            } else {

                let val = builder.addGlobal(entity.mangledName!, type: canonicalize(entity.type!))
                llvmPointers[entity] = val

                return builder.buildLoad(val)
            }
        }


        let recvType = checker.info.types[receiver]!
        let entity = recvType.memberScope!.lookup(member)!
//        let entity = recvType.child(member)!

//        let recvEntity = context.scope.lookup(receiver)!
//        let entity = recvEntity.child(member)

        let recIrVal = emitExpr(receiver, returnAddress: true)
        let memberPtr = builder.buildStructGEP(recIrVal, index: Int(entity.offsetInParent!))

        if returnAddress {
            return memberPtr
        }

        return builder.buildLoad(memberPtr)
    }

    /// If a value is meant to be used as a condition use this.
    /// It will truncate to an `i1` for you
    func emitExprConditional(_ node: AstNode) -> IRValue {
        let val = emitExpr(node)

        guard (val.type as! IntType).width == 1 else {
            return builder.buildTrunc(val, type: IntType.int1)
        }

        return val
    }
}


// MARK: Helper Code Gen

extension IRGenerator {

    func emitGlobalString(name: String? = nil, value: String) -> IRValue {
        return builder.buildGlobalStringPtr(
            value.escaped,
            name: name ?? ""
        )
    }

    func emitGlobal(name: String? = nil, type: IRType? = nil, value: IRValue? = nil) -> IRValue {
        let name = name ?? ""

        if let value = value {
            return builder.addGlobal(name, initializer: value)
        } else if let type = type {
            return builder.addGlobal(name, type: type)
        } else {
            preconditionFailure()
        }
    }

    @discardableResult
    func emitGlobalType(_ entity: Entity) -> IRType {

        if let existing = module.type(named: entity.mangledName!) {
            return existing
        }

        let memberScope = entity.type!.underlyingType!.memberScope!

        var irTypes: [IRType] = []

        for member in memberScope.elements.orderedValues {
            switch member.kind {
            case .runtime:
                let irType = canonicalize(member.type!)
                irTypes.append(irType)

            case .compiletime:
                // This is likely to be a type nested within
                break

            default:
                continue
            }
        }

        return builder.createStruct(name: entity.mangledName!, types: Array(irTypes), isPacked: false)
    }
}


// MARK: Helpers

extension IRGenerator {

    func lookupEntity(_ node: AstNode) -> Entity? {

        switch node {
        case .ident(let ident, _):
            return context.scope.lookup(ident)

        case .exprSelector(let receiver, member: let member, _):
            guard let receiverScope = lookupEntity(receiver)?.childScope else {
                return nil
            }
            let prevScope = context.scope
            defer { context.scope = prevScope }
            context.scope = receiverScope
            return lookupEntity(member)

        case .exprDeref(let expr, _):
            return lookupEntity(expr)

        case .exprUnary(.ampersand, let expr, _):
            return lookupEntity(expr)

        default:
            return nil
        }
    }

    @discardableResult
    func pushScope(for node: AstNode) -> Scope {
        let scope = checker.info.scopes[node]!

        context.scope = scope
        return scope
    }

    func popScope() {
        context.scope = context.scope.parent!
    }
}

extension String {

    //TODO(vdka): This should be done in the lexer.
    var escaped: String {
        return self.replacingOccurrences(of: "\\n", with: "\n")
            .replacingOccurrences(of: "\\t", with: "\t")
    }
}

extension BasicBlock {
    var hasTerminatingInstruction: Bool {
        guard let instruction = lastInstruction else {
            return false
        }
        
        return instruction.isATerminatorInst
    }
}

extension IRGenerator {

    func canonicalize(_ type: Type) -> IRType {

        switch type.kind {
        case .builtin(let typeName):
            switch typeName {
            case "void", "unconstrNil":
                return VoidType()

            case "bool", "unconstrBool":
                return IntType.int1

            case "i8", "u8":
                return IntType.int8

            case "i16", "u16":
                return IntType.int16

            case "i32", "u32":
                return IntType.int32

            case "i64", "u64", "int", "uint", "unconstrInteger":
                return IntType.int64

            case "f32":
                return FloatType.float

            case "f64", "unconstrFloat":
                return FloatType.double

            case "string", "unconstrString":
                return PointerType(pointee: IntType.int8)

            default:
                unimplemented("Type emission for type \(type)")
            }

        case .named(let entity, _):

            if let type = module.type(named: entity.mangledName!) {
                return type
            }

            return emitGlobalType(entity)

        case .alias(let entity, _):
            if let irType = module.type(named: entity.mangledName!) {
                return irType
            }
             // should have already been declared?
            // Maybe not the case if the referenced type is in another module, in which case what do we do?
            fatalError()

        case .struct(let members):

            // FIXME(vdka): If types can be nested (they can) this won't be correct. Fix that.
            let memberIrTypes = Array(members.elements.orderedValues.map({ self.canonicalize($0.type!) }))

            return StructType(elementTypes: memberIrTypes)

        case .pointer(let underlyingType),
             .nullablePointer(let underlyingType):
            return PointerType(pointee: canonicalize(underlyingType))

        case .array(let underlyingType, let count):
            return ArrayType(elementType: canonicalize(underlyingType), count: Int(count))

        case .proc(let params, let results, let isVariadic):

            let paramTypes: [IRType]
            if isVariadic {
                paramTypes = params.dropLast().map({ canonicalize($0.type!) })
            } else {
                paramTypes = params.map({ canonicalize($0.type!) })
            }

            let resultType: IRType

            if results.count == 1, let firstResult = results.first {

                resultType = canonicalize(firstResult)
            } else {

                let resultIrTypes = results.map({ canonicalize($0) })
                resultType = StructType(elementTypes: resultIrTypes)
            }

            return FunctionType(argTypes: paramTypes, returnType: resultType, isVarArg: isVariadic)
            
        case .tuple(let types):
            return StructType(elementTypes: types.map({ canonicalize($0) }))
            
        case .typeInfo:
            unimplemented("Type info")
        }
    }
}