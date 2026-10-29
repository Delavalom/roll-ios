import Store

enum AssetRecordFixtures {
  static func photo(bytes: Int64, uti: String = "public.jpeg") -> AssetRecord {
    AssetRecord(id: "p", mediaType: 1, subtypes: 0, pixelW: 4000, pixelH: 3000, uti: uti, estBytes: bytes)
  }

  static func video(bytes: Int64, seconds: Double, w: Int = 1920, h: Int = 1080) -> AssetRecord {
    AssetRecord(id: "v", mediaType: 2, subtypes: 0, pixelW: w, pixelH: h, duration: seconds, estBytes: bytes)
  }
}
