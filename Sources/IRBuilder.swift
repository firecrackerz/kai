
struct IRBuilder {

  static func getIR(for node: AST.Node) -> ByteString {

    var output: ByteString = ""

    switch node.kind {
    case .procedure:
      // TODO(vdka): Is symbol global or local?

      output.append(contentsOf: "define")
      output.append(contentsOf: " " + node.procedureReturnTypeName! + " ")

      /// TODO(vdka): Think about Scoping '@' is global '%' is local
      output.append(contentsOf: "@" + node.name!)

      // TODO(vdka): Do this properly
      if node.procedureArgumentTypeNames!.isEmpty {
        output.append(contentsOf: "()")
      } else {
        unimplemented("Multiple arguments")
      }

      let irForBody = IRBuilder.getIR(for: node.procedureBody!)

      output.append(contentsOf: irForBody)

      return output

    case .scope:
      output.append("{")
      output.append("\n")

      for child in node.children {
        let ir = IRBuilder.getIR(for: child)
        output.append(contentsOf: ir)
      }

      output.append("\n")
      output.append("}")

      return output

    case .returnStatement:
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
