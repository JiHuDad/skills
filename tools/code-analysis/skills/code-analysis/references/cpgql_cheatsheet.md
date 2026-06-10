# CPGQL Cheat Sheet

Patterns verified against Joern 2.x. All examples assume `cpg` is loaded.

---

## Method / Function

```scala
// exact name
cpg.method.name("main")

// regex (wrap in quotes, use .* for wildcard)
cpg.method.name("recv.*")

// filter by file
cpg.method.filename(".*service\\.c")

// exclude external / library methods
cpg.method.filterNot(_.isExternal)

// list all names
cpg.method.name.l
```

---

## Call Graph

```scala
// one-hop callers (functions that call "foo")
cpg.method.name("foo").caller.name.l

// one-hop callees (functions "foo" calls)
cpg.method.name("foo").callee.name.l

// call sites (Call nodes, not Method nodes)
cpg.method.name("foo").callIn.l          // where foo is called
cpg.call.name("malloc").l                // all calls to malloc

// caller with location
cpg.method.name("foo").caller.map(m => (m.name, m.filename, m.lineNumber)).l
```

---

## CFG Traversal

```scala
// all CFG nodes of a method
cpg.method.name("foo").cfgNode.l

// control structures (if/while/for/switch)
cpg.method.name("foo").ast.isControlStructure.l

// control structure condition text
cpg.method.name("foo").ast.isControlStructure.condition.code.l

// CFG successors / predecessors
node.cfgNext.l
node.cfgIn.l
```

---

## Data Flow

```scala
import io.joern.dataflowengineoss.language._
import io.joern.dataflowengineoss.queryengine.EngineContext
implicit val ec: EngineContext = EngineContext()

// parameters of source function as taint origins
val sources = cpg.method.name("recvPacket").parameter.l

// parameters of sink function as taint destinations
val sinks = cpg.method.name("execCmd").parameter.l

// reachable paths  (sink.reachableByFlows(sources))
val flows = sinks.reachableByFlows(sources: _*).l

// print path summaries
flows.foreach { f =>
  println(f.elements.map(_.code).mkString(" → "))
}
```

---

## Identifiers & Literals

```scala
// all identifiers with a specific name
cpg.identifier.name("buf").l

// all string literals
cpg.literal.typeFullName("java.lang.String").code.l

// assignments to a variable
cpg.assignment.target.isIdentifier.name("cmd").l
```

---

## Common Filters

```scala
// filter by source file
.filter(_.filename.endsWith("main.c"))

// filter by line range
.filter(n => n.lineNumber.exists(l => l >= 10 && l <= 50))

// filter by method signature containing a keyword
cpg.method.filter(_.signature.contains("char *"))
```

---

## Output Helpers

```scala
// count
cpg.method.size

// to list
.l

// take N
.l.take(10)

// map to tuples
cpg.method.name("foo").caller.map(m => (m.name, m.lineNumber.getOrElse(-1))).l
```

---

## Escape for JSON Output in Scripts

```scala
def esc(s: String): String = s.replace("\\", "\\\\").replace("\"", "\\\"")
```

---

## Notes

- `.name(pattern)` uses **regex**, not glob. `"foo"` matches exactly `foo`.
  Use `"foo.*"` for prefix match.
- `.l` is mandatory to evaluate lazy traversals to a `List`.
- `lineNumber` returns `Option[Int]` — use `.getOrElse(-1)`.
- `caller` / `callee` return `Method` nodes, not `Call` nodes. Use `callIn` for call sites.
- `reachableByFlows` can be slow on large CPGs; set `--timeout` in `query.sh`.
