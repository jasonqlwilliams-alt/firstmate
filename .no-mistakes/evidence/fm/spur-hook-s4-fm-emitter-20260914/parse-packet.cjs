// Parse one URGENT-ALERT v1 packet into a semantic model (YAML front matter via
// the eemeli `yaml` parser, body as ordered key: value lines) and compare it
// with the expected model given as JSON. Exit 0 on match, 1 on mismatch.
const fs = require("fs");
const YAML = require(process.env.YAML_PKG);
const [file, expectJson] = process.argv.slice(2);
const want = JSON.parse(expectJson);
const raw = fs.readFileSync(file, "utf8");
const problems = [];
if (!raw.startsWith("---\n")) problems.push("packet does not start with front matter");
if (!raw.endsWith("\n")) problems.push("packet does not end with a newline");
const end = raw.indexOf("\n---\n", 4);
const fmText = raw.slice(4, end + 1);
const body = raw.slice(end + 5);
const doc = YAML.parseDocument(fmText);
if (doc.errors.length) problems.push("front matter YAML errors: " + doc.errors.map(String).join("; "));
const meta = doc.toJS();
for (const [k, v] of Object.entries(want.front_matter)) {
  if (meta[k] !== v) problems.push(`front matter ${k}=${JSON.stringify(meta[k])} want ${JSON.stringify(v)}`);
}
const lines = body.split("\n").filter((l) => l !== "");
if (lines[0] !== "URGENT-ALERT v1") problems.push(`body banner ${JSON.stringify(lines[0])}`);
const fields = [];
for (const l of lines.slice(1)) {
  const i = l.indexOf(":");
  fields.push([l.slice(0, i), l.slice(i + 1).replace(/^ /, "")]);
}
const order = fields.map(([k]) => k).join(",");
const wantOrder = Object.keys(want.body).join(",");
if (order !== wantOrder) problems.push(`body field order ${order} want ${wantOrder}`);
for (const [k, v] of fields) {
  if (want.body[k] !== v) problems.push(`body ${k}=${JSON.stringify(v)} want ${JSON.stringify(want.body[k])}`);
}
console.log("front matter (parsed):", JSON.stringify(meta));
console.log("body (parsed):", JSON.stringify(Object.fromEntries(fields)));
if (problems.length) {
  console.log("PARSE MISMATCH:\n  " + problems.join("\n  "));
  process.exit(1);
}
console.log("PARSE OK: packet matches the URGENT-ALERT v1 envelope contract");
