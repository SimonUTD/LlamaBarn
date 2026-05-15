import Foundation

/// Finds runnable GGUFs in the pre-HF-cache flat directory (~/.llamabarn).
/// This keeps models usable even after their catalog entries are removed.
enum LegacyModelScanner {

  struct ScanResult {
    let entries: [(entry: CatalogEntry, paths: ResolvedPaths)]
  }

  private struct IniEntry {
    let id: String
    let fields: [String: String]
  }

  static func scan(directory: URL, knownFiles: Set<String>) -> ScanResult {
    let fm = FileManager.default
    guard let files = try? fm.contentsOfDirectory(atPath: directory.path) else {
      return ScanResult(entries: [])
    }

    let fileSet = Set(files)
    var matchedFiles = knownFiles
    var usedIds: Set<String> = []
    var results: [(entry: CatalogEntry, paths: ResolvedPaths)] = []

    let iniURLs = [
      directory.appendingPathComponent("models.ini"),
      UserSettings.appSupportDir.appendingPathComponent("models.ini"),
    ]

    for iniURL in iniURLs {
      for iniEntry in parseModelsIni(at: iniURL) {
        guard let rawModelPath = iniEntry.fields["model"] else { continue }
        let modelURL = resolve(rawModelPath, relativeTo: directory)
        guard isGGUF(modelURL.lastPathComponent),
          isPath(modelURL, inside: directory),
          fm.fileExists(atPath: modelURL.path),
          !matchedFiles.contains(modelURL.lastPathComponent)
        else { continue }

        let shardURLs = shardURLs(for: modelURL.lastPathComponent, in: fileSet, directory: directory)
        let mmprojURL = iniEntry.fields["mmproj"].flatMap {
          existingGGUFPath($0, relativeTo: directory, fileManager: fm)
        }
        let id = uniqueId(iniEntry.id, used: &usedIds)

        guard
          let result = buildEntry(
            id: id,
            modelURL: modelURL,
            additionalPartURLs: shardURLs,
            mmprojURL: mmprojURL,
            fields: iniEntry.fields,
            fileManager: fm
          )
        else { continue }

        results.append(result)
        matchedFiles.insert(modelURL.lastPathComponent)
        shardURLs.forEach { matchedFiles.insert($0.lastPathComponent) }
        if let mmprojURL { matchedFiles.insert(mmprojURL.lastPathComponent) }
      }
    }

    let remainingGGUFs = fileSet
      .filter { isGGUF($0) && !isLikelyMmproj($0) && !matchedFiles.contains($0) }
      .sorted()

    var shardGroups: [String: [String]] = [:]
    var standaloneFiles: [String] = []
    for filename in remainingGGUFs {
      if let shardBase = HFRepoParser.splitShardBaseName(filename) {
        shardGroups[shardBase, default: []].append(filename)
      } else {
        standaloneFiles.append(filename)
      }
    }

    for filename in standaloneFiles {
      let modelURL = directory.appendingPathComponent(filename)
      let id = uniqueId(genericId(for: filename), used: &usedIds)
      if let result = buildEntry(
        id: id,
        modelURL: modelURL,
        additionalPartURLs: [],
        mmprojURL: nil,
        fields: [:],
        fileManager: fm
      ) {
        results.append(result)
        matchedFiles.insert(filename)
      }
    }

    for (_, shardFilenames) in shardGroups {
      let sorted = shardFilenames.sorted()
      guard let firstShard = sorted.first, HFRepoParser.isFirstShard(firstShard) else { continue }
      let modelURL = directory.appendingPathComponent(firstShard)
      let additional = sorted.dropFirst().map { directory.appendingPathComponent($0) }
      let id = uniqueId(genericId(for: firstShard), used: &usedIds)
      if let result = buildEntry(
        id: id,
        modelURL: modelURL,
        additionalPartURLs: additional,
        mmprojURL: nil,
        fields: [:],
        fileManager: fm
      ) {
        results.append(result)
        sorted.forEach { matchedFiles.insert($0) }
      }
    }

    return ScanResult(entries: results)
  }

  private static func buildEntry(
    id: String,
    modelURL: URL,
    additionalPartURLs: [URL],
    mmprojURL: URL?,
    fields: [String: String],
    fileManager: FileManager
  ) -> (entry: CatalogEntry, paths: ResolvedPaths)? {
    let allModelURLs = [modelURL] + additionalPartURLs
    let fileSize = allModelURLs.reduce(Int64(0)) { total, url in
      let resolvedPath = url.resolvingSymlinksInPath().path
      let attrs = try? fileManager.attributesOfItem(atPath: resolvedPath)
      return total + ((attrs?[.size] as? NSNumber)?.int64Value ?? 0)
    }
    guard fileSize > 0 else { return nil }

    let filename = modelURL.lastPathComponent
    let quant =
      GGUFQuantLabel.parse(filename)
      ?? HFRepoParser.parseQuant(filename: filename)
      ?? "unknown"
    let metadata = metadata(from: filename, quant: quant)
    let ctxWindow = max(intValue(fields["ctx-size"]) ?? 131_072, 4_096)

    let entry = CatalogEntry(
      id: id,
      family: metadata.family,
      parameterCount: 0,
      size: metadata.size,
      ctxWindow: ctxWindow,
      fileSize: fileSize,
      ctxBytesPer1kTokens: 0,
      downloadUrl: modelURL,
      additionalParts: additionalPartURLs.isEmpty ? nil : additionalPartURLs,
      mmprojUrl: mmprojURL,
      serverArgs: serverArgs(from: fields),
      icon: "sideloaded",
      quantization: quant,
      isFullPrecision: false,
      isSideloaded: true,
      tags: metadata.tags
    )

    let paths = ResolvedPaths(
      modelFile: modelURL.path,
      additionalParts: additionalPartURLs.map(\.path),
      mmprojFile: mmprojURL?.path,
      isLegacy: true
    )

    return (entry: entry, paths: paths)
  }

  private static func parseModelsIni(at url: URL) -> [IniEntry] {
    guard let content = try? String(contentsOf: url, encoding: .utf8) else { return [] }

    var entries: [IniEntry] = []
    var currentId: String?
    var currentFields: [String: String] = [:]

    func flush() {
      guard let id = currentId else { return }
      entries.append(IniEntry(id: id, fields: currentFields))
    }

    for rawLine in content.components(separatedBy: .newlines) {
      let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
      guard !line.isEmpty, !line.hasPrefix("#"), !line.hasPrefix(";") else { continue }

      if line.hasPrefix("["), line.hasSuffix("]") {
        flush()
        currentId = String(line.dropFirst().dropLast()).trimmingCharacters(in: .whitespaces)
        currentFields = [:]
        continue
      }

      guard currentId != nil, let eq = line.firstIndex(of: "=") else { continue }
      let key = String(line[..<eq]).trimmingCharacters(in: .whitespaces).lowercased()
      let value = String(line[line.index(after: eq)...]).trimmingCharacters(in: .whitespaces)
      currentFields[key] = unquote(value)
    }

    flush()
    return entries
  }

  private static func resolve(_ path: String, relativeTo directory: URL) -> URL {
    if path.hasPrefix("/") {
      return URL(fileURLWithPath: path).standardizedFileURL
    }
    return directory.appendingPathComponent(path).standardizedFileURL
  }

  private static func existingGGUFPath(
    _ path: String, relativeTo directory: URL, fileManager: FileManager
  ) -> URL? {
    let url = resolve(path, relativeTo: directory)
    guard isGGUF(url.lastPathComponent),
      isPath(url, inside: directory),
      fileManager.fileExists(atPath: url.path)
    else { return nil }
    return url
  }

  private static func isPath(_ url: URL, inside directory: URL) -> Bool {
    let dirPath = directory.standardizedFileURL.path
    let path = url.standardizedFileURL.path
    let prefix = dirPath.hasSuffix("/") ? dirPath : dirPath + "/"
    return path == dirPath || path.hasPrefix(prefix)
  }

  private static func shardURLs(for filename: String, in fileSet: Set<String>, directory: URL) -> [URL] {
    guard let base = HFRepoParser.splitShardBaseName(filename) else { return [] }
    let shards = fileSet
      .filter { HFRepoParser.splitShardBaseName($0) == base }
      .sorted()
    guard shards.first == filename else { return [] }
    return shards.dropFirst().map { directory.appendingPathComponent($0) }
  }

  private static func serverArgs(from fields: [String: String]) -> [String] {
    let skipped: Set<String> = ["model", "ctx-size", "mmproj"]
    var args: [String] = []
    for key in fields.keys.sorted() where !skipped.contains(key) {
      let flag = String(key.drop(while: { $0 == "-" }))
      guard !flag.isEmpty, let value = fields[key] else { continue }
      args.append("--\(flag)")
      if value.lowercased() != "true" {
        args.append(value)
      }
    }
    return args
  }

  private static func unquote(_ value: String) -> String {
    guard value.count >= 2 else { return value }
    if (value.hasPrefix("\"") && value.hasSuffix("\""))
      || (value.hasPrefix("'") && value.hasSuffix("'"))
    {
      return String(value.dropFirst().dropLast())
    }
    return value
  }

  private static func isGGUF(_ filename: String) -> Bool {
    filename.lowercased().hasSuffix(".gguf")
  }

  private static func isLikelyMmproj(_ filename: String) -> Bool {
    filename.lowercased().contains("mmproj")
  }

  private static func intValue(_ value: String?) -> Int? {
    guard let value else { return nil }
    return Int(value.trimmingCharacters(in: .whitespacesAndNewlines))
  }

  private static func uniqueId(_ preferred: String, used: inout Set<String>) -> String {
    let base = preferred.trimmingCharacters(in: .whitespacesAndNewlines)
    let fallback = base.isEmpty ? "legacy-model" : base
    var candidate = fallback
    var suffix = 2
    while used.contains(candidate) {
      candidate = "\(fallback)-\(suffix)"
      suffix += 1
    }
    used.insert(candidate)
    return candidate
  }

  private static func genericId(for filename: String) -> String {
    let base = baseModelName(from: filename)
    let slug = base.lowercased()
      .components(separatedBy: CharacterSet.alphanumerics.inverted)
      .filter { !$0.isEmpty }
      .joined(separator: "-")
    let quant =
      GGUFQuantLabel.parse(filename)
      ?? HFRepoParser.parseQuant(filename: filename)
      ?? "unknown"
    return "legacy/\(slug.isEmpty ? "model" : slug):\(quant)"
  }

  private struct Metadata {
    let family: String
    let size: String
    let tags: [String]
  }

  private static func metadata(from filename: String, quant: String) -> Metadata {
    let cleaned = baseModelName(from: filename, removingQuant: quant)
    let segments = cleaned.split(separator: "-").map(String.init).filter { !$0.isEmpty }

    if let paramIndex = segments.firstIndex(where: isParameterCount) {
      let familySegments = segments[..<paramIndex]
      let family = familySegments.isEmpty ? cleaned : familySegments.joined(separator: "-")
      let tags = Array(segments.dropFirst(paramIndex + 1))
      return Metadata(family: family, size: segments[paramIndex].uppercased(), tags: tags)
    }

    return Metadata(family: cleaned.isEmpty ? "Legacy model" : cleaned, size: quant, tags: [])
  }

  private static func baseModelName(from filename: String, removingQuant quant: String? = nil) -> String {
    let nameOnly = URL(fileURLWithPath: filename).lastPathComponent
    let shardBase = HFRepoParser.splitShardBaseName(nameOnly) ?? nameOnly
    var base = shardBase
    if base.lowercased().hasSuffix(".gguf") {
      base = String(base.dropLast(5))
    }
    if let quant, !quant.isEmpty {
      let suffix = "-\(quant)"
      if base.range(of: suffix, options: [.caseInsensitive, .backwards])?.upperBound == base.endIndex {
        base = String(base.dropLast(suffix.count))
      }
    }
    return base
  }

  private static func isParameterCount(_ segment: String) -> Bool {
    let pattern = #"^\d+(\.\d+)?[BbMmKkTt]$"#
    return segment.range(of: pattern, options: .regularExpression) != nil
  }
}
