import Foundation
import PileEvalKit

/// pile-eval embed --spec evals/piles.json --model <folder with b70/> --store <scratch dir> --vectors <out.json>
/// pile-eval score --spec evals/piles.json --vectors <json> --index <vectors.egix> --db <roll.sqlite> --out <dir>
///
/// Keep `--vectors`, `--index`, `--db` and `--store` outside the repo (private data); `--out` gets counts only.
let usage = """
  usage: pile-eval embed --spec FILE --model DIR --store DIR --vectors FILE
         pile-eval score --spec FILE --vectors FILE --index FILE --db FILE --out DIR
  """

func options(_ args: ArraySlice<String>) -> [String: String] {
  var out: [String: String] = [:], key: String?
  for a in args {
    if a.hasPrefix("--") { key = String(a.dropFirst(2)) } else if let k = key { out[k] = a; key = nil }
  }
  return out
}

func url(_ path: String) -> URL { URL(fileURLWithPath: (path as NSString).expandingTildeInPath) }

let args = CommandLine.arguments
guard args.count >= 2 else { print(usage); exit(2) }
let opts = options(args.dropFirst(2))
func need(_ key: String) -> String {
  guard let v = opts[key] else { print("missing --\(key)\n\(usage)"); exit(2) }
  return v
}

do {
  let spec = try JSONDecoder().decode(PileSpec.self, from: Data(contentsOf: url(need("spec")))).validated()
  switch args[1] {
  case "embed":
    try await embedQueries(spec: spec, model: url(need("model")), store: url(need("store")), out: url(need("vectors")))
  case "score":
    try scoreQueries(spec: spec, vectorsURL: url(need("vectors")), indexURL: url(need("index")),
                     dbPath: (need("db") as NSString).expandingTildeInPath, out: url(need("out")))
  default:
    print(usage); exit(2)
  }
} catch {
  print("pile-eval: \(error)")
  exit(1)
}
