import Foundation

struct ModelFamily {
  let name: String  // e.g. "Qwen3 2507"
  let series: String  // e.g. "qwen"
  let description: String?  // optional description of the family
  let serverArgs: [String]?  // optional defaults for all models/builds
  let overheadMultiplier: Double  // overhead multiplier for file size
  let sizes: [ModelSize]
  /// Deprecated families are hidden from the catalog browse view but still
  /// match installed models so they keep their curated icon, name, and metadata.
  let deprecated: Bool

  init(
    name: String,
    series: String,
    description: String? = nil,
    serverArgs: [String]? = nil,
    overheadMultiplier: Double = 1.05,
    deprecated: Bool = false,
    sizes: [ModelSize]
  ) {
    self.name = name
    self.series = series
    self.description = description
    self.serverArgs = serverArgs
    self.overheadMultiplier = overheadMultiplier
    self.deprecated = deprecated
    self.sizes = sizes.sorted { $0.parameterCount < $1.parameterCount }
  }

  var iconName: String {
    "ModelLogos/\(series.lowercased())"
  }

  var allModels: [CatalogEntry] {
    sizes.flatMap { size in
      ([size.build] + size.quantizedBuilds).map { build in
        Catalog.entry(family: self, size: size, build: build)
      }
    }
  }

  func catalogModels() -> [CatalogEntry] {
    allModels.sorted(by: CatalogEntry.displayOrder(_:_:))
  }

  func liveCatalogEntry(size: ModelSize, resolved: HFRepoResolver.Resolved) -> CatalogEntry {
    let effectiveArgs = (serverArgs ?? []) + (size.serverArgs ?? [])
    let quantization = resolved.quant.uppercased()
    let fullPrecisionLabels: Set<String> = ["F16", "BF16", "FP16", "F32"]

    return CatalogEntry(
      id: resolved.modelId,
      family: name,
      parameterCount: size.parameterCount,
      size: size.name,
      ctxWindow: size.ctxWindow,
      fileSize: resolved.approximateBytes,
      ctxBytesPer1kTokens: size.ctxBytesPer1kTokens,
      overheadMultiplier: overheadMultiplier,
      downloadUrl: resolved.mainUrl,
      additionalParts: resolved.additionalParts.isEmpty ? nil : resolved.additionalParts,
      mmprojUrl: resolved.mmprojUrl ?? size.mmproj,
      mmprojLocalFilename: size.mmprojLocalFilename,
      serverArgs: effectiveArgs,
      icon: iconName,
      quantization: quantization,
      isFullPrecision: fullPrecisionLabels.contains(quantization)
    )
  }

  func selectableModels() -> [CatalogEntry] {
    // Group by size (e.g., "27B") to pick the preferred version
    let modelsBySize = Dictionary(grouping: allModels, by: { $0.size })

    return modelsBySize.values.compactMap { models in
      // First try to find a compatible model
      let compatibleModels = models.filter { $0.isCompatible() }
      if let bestCompatible = bestModel(in: compatibleModels) {
        return bestCompatible
      }

      // Fallback to best model regardless of compatibility
      // If no compatible models, pick the one with the lowest memory usage (lightest)
      // to show the minimum requirements.
      return models.min(by: {
        $0.runtimeMemoryUsageMb() < $1.runtimeMemoryUsageMb()
      })
    }.sorted(by: CatalogEntry.displayOrder(_:_:))
  }

  private func bestModel(in models: [CatalogEntry]) -> CatalogEntry? {
    // Prefer full precision, fallback to quantized
    return models.first(where: { $0.isFullPrecision })
      ?? models.first(where: { !$0.isFullPrecision })
  }
}
