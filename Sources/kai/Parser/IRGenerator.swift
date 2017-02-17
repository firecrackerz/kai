import LLVM

struct IRGenerator {
    //FIXME(Brett):
    //TODO(Brett): will be removed when #foreign is supported
    struct InternalFuncs {
        var puts: Function?
        var printf: Function?
        
        init(builder: IRBuilder) {
            puts = generatePuts(builder: builder)
            printf = nil
        }
        
        func generatePuts(builder: IRBuilder) -> Function {
            let putsType = FunctionType(
                argTypes:[ PointerType(pointee: IntType.int8) ],
                returnType: IntType.int32
            )
            
            return builder.addFunction("puts", type: putsType)
        }
        
        func generatePrintf() -> Function? {
            return nil
        }
    }
    
    enum Error: Swift.Error {
        case unimplemented(String)
        case expectedFileNode
        case unidentifiedSymbol(String)
        case preconditionNotMet(expected: String, got: String)
    }

    let module: Module
    let builder: IRBuilder
    let rootNode: AST
    let internalFuncs: InternalFuncs
    
    init(node: AST.Node) throws {
        guard case .file(let fileName) = node.kind else {
            throw Error.expectedFileNode
        }

        rootNode = node
        module = Module(name: fileName)
        builder = IRBuilder(module: module)
        internalFuncs = InternalFuncs(builder: builder)
    }

    static func build(for node: AST.Node) throws {
        let generator = try IRGenerator(node: node)
        try generator.emitGlobals()
        try generator.emitMain()
        
        generator.module.dump()
        try TargetMachine().emitToFile(module: generator.module, type: .object, path: "main.o")
    }
}

extension IRGenerator {
    func emitMain() throws {
        // TODO(Brett): Update to emit function definition
        let mainType = FunctionType(argTypes: [], returnType: VoidType())
        let main = builder.addFunction("main", type: mainType)
        let entry = main.appendBasicBlock(named: "entry")
        builder.positionAtEnd(of: entry)
        
        for child in rootNode.children {
            switch child.kind {
            case .procedureCall:
                try emitProcedureCall(for: child)
                
            default: break
            }
        }
        
        builder.buildRetVoid()
    }
    
    func emitGlobals() throws {
        for child in rootNode.children {
            switch child.kind {
            case .procedureCall:
                // procedure calls are allowed, but aren't a global symbol so 
                // just continue
                break
                
            case .declaration(let symbol):
                try emitDeclaration(for: symbol)
                
            default:
                print("unsupported node in file-scope: \(child)")
                continue
            }
        }
    }
}

extension IRGenerator {
    @discardableResult
    func emitDeclaration(for symbol: Symbol) throws -> IRValue? {
        guard let type = symbol.type else {
            throw Error.unidentifiedSymbol(symbol.name.string)
        }
        
        switch type {
        case .string:
            break
        case .integer:
            break
        case .float:
            break
        case .boolean:
            break
            
        default:
            throw Error.unimplemented("emitDeclaration for type: \(type.description)")
        }
        
        return nil
    }
    
    func emitProcedureCall(for node: AST.Node) throws {
        assert(node.kind == .procedureCall)
        
        guard
            node.children.count >= 2,
            let firstNode = node.children.first,
            case .identifier(let identifier) = firstNode.kind
        else {
            throw Error.preconditionNotMet(
                expected: "identifier",
                got: "\(node.children.first?.kind)"
            )
        }
        
        let arguments = node.children[1]
        
        // FIXME(Brett):
        // TODO(Brett): will be removed when #foreign is supported
        if identifier == "print" {
            try emitPrintCall(for: arguments)
        } else {
            throw Error.unimplemented("emitProcedureCall for :\(node)")
        }
        
    }
    
    func emitStaticString(name: String? = nil, value: ByteString) -> IRValue {
        return builder.buildGlobalStringPtr(
            value.string,
            name: name ?? ""
        )
    }
    
    // FIXME(Brett):
    // TODO(Brett): will be removed when #foreign is supported
    func emitPrintCall(for arguments: AST.Node) throws {
        guard arguments.children.count == 1 else {
            throw Error.preconditionNotMet(expected: "1 argument", got: "\(arguments.children.count)")
        }
        
        let argument = arguments.children[0]
        
        switch argument.kind {
        case .string(let string):
            let stringPtr = emitStaticString(value: string)
            builder.buildCall(internalFuncs.puts!, args: [stringPtr])
            
        default:
            throw Error.unimplemented("emitPrintCall: \(argument.kind)")
        }
    }
}


/*
struct IRBuilder {

  static func getIR(for node: AST.Node, indentationLevel: Int = 0) -> ByteString {

    let indentation = ByteString(Array(repeating: " ", count: indentationLevel))

    var output: ByteString = ""

    switch node.kind {
    case .file:
      output.append(contentsOf: "; " + ByteString(node.name!))
      return output

    case .procedure:
      // TODO(vdka): Is symbol global or local?

      output.append(contentsOf: "define")
      output.append(contentsOf: " " + node.procedureReturnTypeName! + " ")

      /// TODO(vdka): Think about Scoping '@' is global '%' is local
      output.append(contentsOf: "@" + node.name!)

      // TODO(vdka): Do this properly
      if node.procedureArgumentTypeNames!.isEmpty {
        output.append(contentsOf: "() ")
      } else {
        unimplemented("Multiple arguments")
      }

      let irForBody = IRBuilder.getIR(for: node.procedureBody!, indentationLevel: indentationLevel + 2)

      output.append(contentsOf: irForBody)

      return output

    case .scope:
      output.append("{")
      output.append("\n")

      for child in node.children {
        let ir = IRBuilder.getIR(for: child, indentationLevel: indentationLevel)
        output.append(contentsOf: ir)
      }

      output.append("\n")
      output.append("}")

      return output

    case .returnStatement:
      output.append(contentsOf: indentation)
      output.append(contentsOf: "ret ")

      return output

    case .integer:
      output.append(contentsOf: "i64 ")

      output.append(contentsOf: node.value!)

      return output

    default:
      return ""
    }
  }
}
*/
