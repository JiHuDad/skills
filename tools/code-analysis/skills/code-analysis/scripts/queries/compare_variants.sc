// compare_variants.sc — List all non-external functions in this CPG
// Used by compare_variants.sh to diff two CPG function sets.
// Tested: Joern 2.x
//
// Env vars:
//   JOERN_MAX_RESULTS   (default 500)
//
// This script intentionally does one thing only: emit the function inventory
// of a single CPG as JSON. The shell script compare_variants.sh runs it twice
// and computes the diff, avoiding the fragile two-CPG-in-one-script pattern.

val maxResults = sys.env.getOrElse("JOERN_MAX_RESULTS", "500").toIntOption.getOrElse(500)

def esc(s: String): String = s.replace("\\", "\\\\").replace("\"", "\\\"")

val funcs = cpg.method.filterNot(_.isExternal).l.take(maxResults)

val funcsJson = funcs.map { m =>
  val callees = m.callee.name.l.distinct.take(20)
  val calleesJson = callees.map(n => s""""${esc(n)}"""").mkString("[",",","]")
  s"""{"name":"${esc(m.name)}","file":"${esc(m.filename)}","callees":$calleesJson}"""
}.mkString("[",",","]")

val out =
  s"""{
  "schema_version": "1.0",
  "query": "compare_variants",
  "status": "ok",
  "target": {"function": "*"},
  "truncated": ${funcs.size >= maxResults},
  "result": {
    "functions": $funcsJson,
    "total": ${funcs.size}
  }
}"""

println("BEGIN_JSON"); println(out); println("END_JSON")
