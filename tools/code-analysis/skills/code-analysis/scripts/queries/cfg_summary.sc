// cfg_summary.sc — CFG complexity metrics for a function
// Tested: Joern 2.x
//
// Env vars: JOERN_TARGET
//
// Metrics:
//   basic_blocks          — total CFG nodes (Joern represents each statement as a node)
//   branch_points         — control structure count (if/while/for/switch)
//   unreachable_blocks    — CFG nodes with no incoming edges that are not the entry node
//   cyclomatic_complexity — branch_points + 1  (McCabe approximation)

val targetName = sys.env.getOrElse("JOERN_TARGET", "")

def esc(s: String): String = s.replace("\\", "\\\\").replace("\"", "\\\"")

def errorJson(msg: String): String =
  s"""{"schema_version":"1.0","query":"cfg_summary","status":"error","error_message":"${esc(msg)}","truncated":false}"""

if (targetName.isEmpty) {
  println("BEGIN_JSON"); println(errorJson("JOERN_TARGET is not set")); println("END_JSON")
} else {
  val methods = cpg.method.name(targetName).l
  if (methods.isEmpty) {
    println("BEGIN_JSON"); println(errorJson(s"Function not found: $targetName")); println("END_JSON")
  } else {
    val m = methods.head

    // CFG node count (statements, expressions, entry, exit)
    val cfgNodes    = m.cfgNode.l
    val totalNodes  = cfgNodes.size

    // Branch points = control structures in AST
    val branchPoints = m.ast.isControlStructure.size

    // Cyclomatic complexity (McCabe): M = E - N + 2P, simplified as branches + 1 for single function
    val cc = branchPoints + 1

    // Unreachable approximation: CFG nodes with no predecessors that are not the method entry node
    val unreachable = cfgNodes.count { n =>
      n.cfgIn.isEmpty &&
      !n.isInstanceOf[io.shiftleft.codepropertygraph.generated.nodes.Method] &&
      !n.isInstanceOf[io.shiftleft.codepropertygraph.generated.nodes.MethodReturn]
    }

    val summary = s"${totalNodes} CFG nodes, ${branchPoints} branch points, ${unreachable} potentially unreachable, CC=${cc}"

    val out =
      s"""{
  "schema_version": "1.0",
  "query": "cfg_summary",
  "status": "ok",
  "target": {"function": "${esc(targetName)}"},
  "truncated": false,
  "result": {
    "function": "${esc(m.name)}",
    "basic_blocks": $totalNodes,
    "branch_points": $branchPoints,
    "unreachable_blocks": $unreachable,
    "cyclomatic_complexity": $cc,
    "summary": "${esc(summary)}"
  }
}"""

    println("BEGIN_JSON"); println(out); println("END_JSON")
  }
}
