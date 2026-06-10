// dataflow.sc — Source→sink taint reachability
// Tested: Joern 2.x  (requires dataflowengineoss module, bundled in joern-cli)
//
// Env vars:
//   JOERN_SOURCE       source function name
//   JOERN_SINK         sink function name
//   JOERN_MAX_RESULTS  max paths to return (default 20)
//
// Strategy: treat source function's parameters as taint origins,
// sink function's parameters as taint sinks, then use reachableByFlows.

import io.joern.dataflowengineoss.language._
import io.joern.dataflowengineoss.queryengine.EngineContext
import io.shiftleft.semanticcpg.language._

val sourceName = sys.env.getOrElse("JOERN_SOURCE", "")
val sinkName   = sys.env.getOrElse("JOERN_SINK",   "")
val maxResults = sys.env.getOrElse("JOERN_MAX_RESULTS", "20").toIntOption.getOrElse(20)

def esc(s: String): String = s.replace("\\", "\\\\").replace("\"", "\\\"")

def errorJson(msg: String): String =
  s"""{"schema_version":"1.0","query":"dataflow","status":"error","error_message":"${esc(msg)}","truncated":false}"""

if (sourceName.isEmpty || sinkName.isEmpty) {
  println("BEGIN_JSON")
  println(errorJson("Both JOERN_SOURCE and JOERN_SINK must be set"))
  println("END_JSON")
} else {
  val sourceMethod = cpg.method.name(sourceName)
  val sinkMethod   = cpg.method.name(sinkName)

  val missing = List(
    if (sourceMethod.isEmpty) Some(s"source '$sourceName'") else None,
    if (sinkMethod.isEmpty)   Some(s"sink '$sinkName'")     else None
  ).flatten

  if (missing.nonEmpty) {
    println("BEGIN_JSON")
    println(errorJson(s"Function not found: ${missing.mkString(", ")}"))
    println("END_JSON")
  } else {
    // Source: all parameters of the source function (taint entry points)
    val sources = sourceMethod.parameter.l
    // Sink: all parameters of the sink function
    val sinks   = sinkMethod.parameter.l

    implicit val engineContext: EngineContext = EngineContext()
    val allFlows = sinks.reachableByFlows(sources: _*).l
    val flows    = allFlows.take(maxResults)
    val reachable  = flows.nonEmpty
    val truncated  = allFlows.size > maxResults

    def nodeLabel(node: io.shiftleft.codepropertygraph.generated.nodes.StoredNode): String = node match {
      case p: io.shiftleft.codepropertygraph.generated.nodes.MethodParameterIn =>
        s"${p.method.name}(param:${p.name})"
      case c: io.shiftleft.codepropertygraph.generated.nodes.Call =>
        c.name
      case i: io.shiftleft.codepropertygraph.generated.nodes.Identifier =>
        i.name
      case m: io.shiftleft.codepropertygraph.generated.nodes.Method =>
        m.name
      case other => other.label
    }

    val pathsJson = flows.map { flow =>
      val nodes   = flow.elements.map(n => esc(nodeLabel(n))).distinct
      val summary = esc(nodes.mkString(" → "))
      val nodesJson = nodes.map(n => s""""$n"""").mkString("[", ",", "]")
      s"""{"summary":"$summary","hops":${flow.elements.size},"nodes":$nodesJson}"""
    }.mkString("[", ",", "]")

    val out =
      s"""{
  "schema_version": "1.0",
  "query": "dataflow",
  "status": "ok",
  "target": {"source": "${esc(sourceName)}", "sink": "${esc(sinkName)}"},
  "truncated": $truncated,
  "result": {
    "source": "${esc(sourceName)}",
    "sink": "${esc(sinkName)}",
    "reachable": $reachable,
    "paths": $pathsJson,
    "total_paths_found": ${allFlows.size}
  }
}"""

    println("BEGIN_JSON"); println(out); println("END_JSON")
  }
}
