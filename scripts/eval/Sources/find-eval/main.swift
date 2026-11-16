import FindEvalKit
import Foundation

/// The find eval (plan `docs/superpowers/plans/2026-11-15-find.md`, "How accuracy is measured"). Pooled judging:
///
///     cd scripts/eval
///     ROLL_GEMMA_PATH=/abs/embeddinggemma-coreml/swift swift build -c release -j 4 --product find-eval
///     B=.build/out/Products/Release/find-eval   (or .build/release/find-eval)
///     P=~/egcm-evidence-raw/2026-11-15/find      (private root: ids, thumbnails, labels)
///
///     $B embed --queries ../../evals/find.json $P/find-private.json --model <folder with b70/files.json> \
///        --store $P/model-store --export $P/export/assets.jsonl --out $P/qvecs.json
///     (--export adds each query's V2 semantic text, e.g. "beach" for "beach last summer")
///     $B pool --db $P/db/roll.sqlite --index $P/index/vectors.egix --qvecs $P/qvecs.json \
///        --queries ../../evals/find.json $P/find-private.json [--export $P/export/assets.jsonl] \
///        [--vision $P/export/vision.jsonl] [--labels $P/labels] [--thumbs $P/thumbs] [--keep-all] \
///        --variants V0,F0,C60,C70,V2,V3,V4,V5,V23,V234,NF --k 50 --out $P/pools
///     (`find-eval variants` lists them; F0 is checked against V0 on every query; V5 needs --labels;
///      with --thumbs, thumb-request.txt lists only ids without a thumbnail yet)
///     (copy $P/pools/thumb-request.txt to the phone, pull thumbs/ back)
///     $B sheets --pool $P/pools/pool --thumbs $P/thumbs --labels $P/labels --out $P/sheets \
///        [--queries ... --export $P/export/assets.jsonl]
///     (judges write judgments.json: {"<slug>": {"sheet-01": {"relevant": [n], "unsure": [n]}}})
///     $B apply-judgments --sheets $P/sheets --judgments $P/judgments.json --labels $P/labels \
///        [--queries ... --export $P/export/assets.jsonl --pool-root $P/pools]
///     (without --judgments it only pre-fills album members as relevant; --pool-root keeps those with a vector)
///     $B score --pool-root $P/pools --labels $P/labels --queries ../../evals/find.json $P/find-private.json \
///        [--export $P/export/assets.jsonl] --out ../../docs/investigations/evidence/2026-11-15-find-eval
///
/// A flag may take several values (`--queries a.json b.json`) or repeat. Everything but `score --out` is private and
/// stays outside the repo; `score` writes counts only, and private queries (album-derived) lose their names there.
let usage = """
  usage: find-eval embed --queries SPEC... --model DIR --store DIR [--export JSONL] --out QVECS
         find-eval pool --db DB --index EGIX --qvecs QVECS --queries SPEC... [--export JSONL] [--vision JSONL]
                        [--labels DIR] --variants V0[,V1...] [--k 50] [--keep-all] [--thumbs DIR] --out DIR
         find-eval sheets --pool DIR/pool --thumbs DIR --labels DIR --out DIR [--queries SPEC... --export JSONL]
         find-eval apply-judgments --sheets DIR [--judgments FILE] --labels DIR
                        [--queries SPEC... --export JSONL [--pool-root DIR]]
         find-eval score --pool-root DIR --labels DIR --queries SPEC... [--export JSONL] --out DIR
         find-eval variants
  """

struct Options {
  private var values: [String: [String]] = [:]

  init(_ args: ArraySlice<String>) {
    var key: String?
    for a in args {
      if a.hasPrefix("--") {
        key = String(a.dropFirst(2))
        values[key!, default: []] += []
      } else if let k = key {
        values[k, default: []].append(a)
      }
    }
  }

  func all(_ key: String) -> [String] { values[key] ?? [] }
  func one(_ key: String) -> String? { values[key]?.last }

  func need(_ key: String) -> String {
    guard let v = one(key) else { fail("missing --\(key)") }
    return v
  }

  func urls(_ key: String) -> [URL] { all(key).map(url) }
}

func url(_ path: String) -> URL { URL(fileURLWithPath: (path as NSString).expandingTildeInPath) }

func fail(_ message: String) -> Never {
  FileHandle.standardError.write(Data("find-eval: \(message)\n\(usage)\n".utf8))
  exit(2)
}

let args = CommandLine.arguments
guard args.count >= 2 else { fail("no command") }
let opts = Options(args.dropFirst(2))
let started = Date()

do {
  switch args[1] {
  case "embed":
    try await embedCommand(specs: opts.urls("queries"), model: url(opts.need("model")), store: url(opts.need("store")),
                           out: url(opts.need("out")), export: opts.one("export").map(url))
  case "pool":
    let names = (opts.one("variants") ?? "V0").split(separator: ",").map { String($0).trimmingCharacters(in: .whitespaces) }
    try await poolCommand(PoolOptions(
      db: url(opts.need("db")), index: url(opts.need("index")), qvecs: url(opts.need("qvecs")),
      specs: opts.urls("queries"), export: opts.one("export").map(url), vision: opts.one("vision").map(url),
      labels: opts.one("labels").map(url), variants: names, k: Int(opts.one("k") ?? "50") ?? 50,
      keepAll: CommandLine.arguments.contains("--keep-all"), thumbs: opts.one("thumbs").map(url),
      out: url(opts.need("out"))))
  case "sheets":
    try sheetsCommand(pool: url(opts.need("pool")), thumbs: url(opts.need("thumbs")), labels: url(opts.need("labels")),
                      out: url(opts.need("out")), specs: opts.urls("queries"), export: opts.one("export").map(url))
  case "apply-judgments":
    try applyJudgmentsCommand(sheets: url(opts.need("sheets")), judgments: opts.one("judgments").map(url),
                              labels: url(opts.need("labels")), specs: opts.urls("queries"),
                              export: opts.one("export").map(url), poolRoot: opts.one("pool-root").map(url))
  case "score":
    try scoreCommand(poolRoot: url(opts.need("pool-root")), labels: url(opts.need("labels")),
                     specs: opts.urls("queries"), export: opts.one("export").map(url), out: url(opts.need("out")))
  case "variants":
    for v in Variants.all { print("\(v.name)\t\(v.about)") }
  default:
    fail("unknown command \(args[1])")
  }
  print(String(format: "find-eval %@: done in %.1f s", args[1], Date().timeIntervalSince(started)))
} catch {
  FileHandle.standardError.write(Data("find-eval: \(error)\n".utf8))
  exit(1)
}
