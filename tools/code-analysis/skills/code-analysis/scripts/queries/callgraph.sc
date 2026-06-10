// callgraph.sc — Caller/callee analysis up to N depth (BFS)
// Tested: Joern 2.x
//
// Env vars read:
//   JOERN_TARGET       function name to analyse (exact match)
//   JOERN_DEPTH        BFS depth  (default 2)
//   JOERN_MAX_RESULTS  cap per direction (default 20)
//
// Output: println("BEGIN_JSON") … println("END_JSON")

import scala.collection.mutable

val targetName = sys.env.getOrElse("JOERN_TARGET", "")
val depth      = sys.env.getOrElse("JOERN_DEPTH", "2").toIntOption.getOrElse(2)
val maxResults = sys.env.getOrElse("JOERN_MAX_RESULTS", "20").toIntOption.getOrElse(20)

def esc(s: String): String = s.replace("\\", "\\\\").replace("\"", "\\\"")

case class CNode(name: String, file: String, line: Int, d: Int)

def bfs(start: String, maxD: Int, limit: Int,
        expand: String => List[io.shiftleft.codepropertygraph.generated.nodes.Method]
       ): (List[CNode], Boolean) = {
  val visited = mutable.LinkedHashSet[String]()
  val queue   = mutable.Queue[(String, Int)]()
  val result  = mutable.ListBuffer[CNode]()

  def enqueue(name: String, d: Int): Unit =
    if (result.size < limit && visited.add(name)) {
      queue.enqueue(name -> d)
      val ms = expand(name)
      ms.headOption.foreach { m =>
        result += CNode(name, m.filename, m.lineNumber.getOrElse(-1), d)
      }
    }

  // seed with depth-1 neighbours of the target
  expand(start).foreach(m => enqueue(m.name, 1))

  while (queue.nonEmpty && result.size < limit) {
    val (cur, curD) = queue.dequeue()
    if (curD < maxD) expand(cur).foreach(m => enqueue(m.name, curD + 1))
  }

  (result.toList, result.size >= limit)
}

def renderNode(n: CNode): String =
  s"""{"name":"${esc(n.name)}","file":"${esc(n.file)}","line":${n.line},"depth_from_target":${n.d}}"""

if (targetName.isEmpty) {
  println("BEGIN_JSON")
  println("""{"schema_version":"1.0","query":"callgraph","status":"error","error_message":"JOERN_TARGET is not set","truncated":false}""")
  println("END_JSON")
} else if (cpg.method.name(targetName).isEmpty) {
  println("BEGIN_JSON")
  println(s"""{"schema_version":"1.0","query":"callgraph","status":"error","error_message":"Function not found: ${esc(targetName)}","truncated":false}""")
  println("END_JSON")
} else {
  val (callers, callersTrunc) = bfs(
    targetName, depth, maxResults,
    name => cpg.method.name(name).caller.l
  )
  val (callees, calleesTrunc) = bfs(
    targetName, depth, maxResults,
    name => cpg.method.name(name).callee.l
  )

  val truncated = callersTrunc || calleesTrunc
  val callersJson = callers.map(renderNode).mkString("[", ",", "]")
  val calleesJson = callees.map(renderNode).mkString("[", ",", "]")

  val out =
    s"""{
  "schema_version": "1.0",
  "query": "callgraph",
  "status": "ok",
  "target": {"function": "${esc(targetName)}"},
  "truncated": $truncated,
  "result": {
    "function": "${esc(targetName)}",
    "depth": $depth,
    "callers": $callersJson,
    "callees": $calleesJson,
    "total_callers": ${callers.size},
    "total_callees": ${callees.size}
  }
}"""

  println("BEGIN_JSON")
  println(out)
  println("END_JSON")
}
