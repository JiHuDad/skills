// env_branches.sc — Find if/switch branches that gate environment/config variants
// Tested: Joern 2.x
//
// Env vars:
//   JOERN_TARGET       function name to scan (omit or "*" = scan all non-external methods)
//   JOERN_MAX_RESULTS  max branches to return (default 50)
//
// Detects conditions referencing: env, mode, platform, config, feature, flag,
// getenv, getProperty, System.getenv, BUILD_*, PLATFORM_*

val targetName = sys.env.getOrElse("JOERN_TARGET", "")
val maxResults = sys.env.getOrElse("JOERN_MAX_RESULTS", "50").toIntOption.getOrElse(50)

def esc(s: String): String = s.replace("\\", "\\\\").replace("\"", "\\\"")

// Patterns that signal environment/config-sensitive branching
val envKeywords = Seq(
  "env", "mode", "platform", "config", "feature", "flag",
  "getenv", "getProperty", "getenv", "BUILD_", "PLATFORM_",
  "DEBUG", "RELEASE", "STAGING", "PROD", "DEV"
)

def looksEnvSensitive(code: String): Boolean = {
  val lower = code.toLowerCase
  envKeywords.exists(kw => lower.contains(kw.toLowerCase))
}

val methods =
  if (targetName.isEmpty || targetName == "*")
    cpg.method.filterNot(_.isExternal).l
  else
    cpg.method.name(targetName).l

if (methods.isEmpty && targetName.nonEmpty && targetName != "*") {
  println("BEGIN_JSON")
  println(s"""{"schema_version":"1.0","query":"env_branches","status":"error","error_message":"Function not found: ${esc(targetName)}","truncated":false}""")
  println("END_JSON")
} else {
  val branches = methods.flatMap { m =>
    m.ast.isControlStructure.filter { cs =>
      val condCode = cs.condition.code.l.headOption.getOrElse("")
      looksEnvSensitive(condCode)
    }.map { cs =>
      val condCode = cs.condition.code.l.headOption.getOrElse("")
      (m, cs, condCode)
    }.l
  }.take(maxResults)

  val truncated = branches.size >= maxResults

  val branchesJson = branches.map { case (m, cs, cond) =>
    val csType = cs.controlStructureType
    s"""{
      "function": "${esc(m.name)}",
      "file": "${esc(m.filename)}",
      "line": ${cs.lineNumber.getOrElse(-1)},
      "control_structure": "${esc(csType)}",
      "condition": "${esc(cond)}"
    }"""
  }.mkString("[", ",", "]")

  val scanScope = if (targetName.isEmpty || targetName == "*") "*" else targetName

  val out =
    s"""{
  "schema_version": "1.0",
  "query": "env_branches",
  "status": "ok",
  "target": {"function": "${esc(scanScope)}"},
  "truncated": $truncated,
  "result": {
    "env_sensitive_branches": $branchesJson,
    "total_found": ${branches.size}
  }
}"""

  println("BEGIN_JSON"); println(out); println("END_JSON")
}
