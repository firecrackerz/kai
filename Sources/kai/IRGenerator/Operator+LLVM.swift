
import LLVM

extension IRGenerator {

    // TODO(vdka): Check the types to determine llvm calls
    func emitOperator(for node: AstNode) -> IRValue {
        guard case .expr(let expr) = node else {
            preconditionFailure()
        }

        switch expr {
        case .unary(op: let op, expr: let expr, _):

            let val = emitStmt(for: expr)

            // TODO(vdka): There is much more to build.
            switch op {
            case "-":
                return builder.buildNeg(val)

            case "!":
                // TODO(vdka): Truncate to i1
                return builder.buildNot(val)

            case "~":
                return builder.buildNot(val)

            default:
                unimplemented("Unary Operator '\(op)'")
            }

        case .binary(op: let op, lhs: let lhs, rhs: let rhs, _):

            let lvalue = emitStmt(for: lhs)
            let rvalue = emitStmt(for: rhs)

            switch op {
            case "+":
                return builder.buildAdd(lvalue, rvalue)

            case "-":
                return builder.buildSub(lvalue, rvalue)

            case "*":
                return builder.buildMul(lvalue, rvalue)

            case "/":
                return builder.buildDiv(lvalue, rvalue)

            case "%":
                return builder.buildRem(lvalue, rvalue)

            // TODO(vdka): Are these arithmatic or logical? Which should they be?
            case "<<":
                return builder.buildShl(lvalue, rvalue)

            case ">>":
                return builder.buildShr(lvalue, rvalue)

            case "<":
                return builder.buildICmp(lvalue, rvalue, .unsignedLessThan)

            case "<=":
                return builder.buildICmp(lvalue, rvalue, .unsignedLessThanOrEqual)

            case ">":
                return builder.buildICmp(lvalue, rvalue, .unsignedGreaterThan)

            case ">=":
                return builder.buildICmp(lvalue, rvalue, .unsignedGreaterThanOrEqual)

            case "==":
                return builder.buildICmp(lvalue, rvalue, .equal)

            case "!=":
                return builder.buildICmp(lvalue, rvalue, .notEqual)

            // TODO: returns: A value representing the logical AND. This isn't what the bitwise operators are.
            case "&":
                unimplemented()
                //            return builder.buildAnd(lvalue, rvalue)

            case "|":
                unimplemented()
                //            return builder.buildOr(lvalue, rvalue)

            case "^":
                unimplemented()
                //            return builder.buildXor(lvalue, rvalue)

            case "&&":
                return builder.buildAnd(lvalue, rvalue)

            case "||":
                return builder.buildOr(lvalue, rvalue)

            case "+=",
                 "-=",
                 "*=",
                 "/=",
                 "%=":
                unimplemented()

            case ">>=",
                 "<<=":
                unimplemented()

            case "&=",
                 "|=",
                 "^=":
                unimplemented()

            default:
                unimplemented("Binary Operator '\(op)'")
            }

        default:
            fatalError()
        }
    }
}