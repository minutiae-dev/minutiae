import FluidAudio
import XCTest

@testable import EngineCore

/// The ASR model cache is "complete" only when every artifact is on disk.
/// FluidAudio downloads files one at a time with no completion sentinel and
/// writes `metadata.json` near the end, so a single-file probe misreads an
/// interrupted download — in one direction it re-downloads ~1.5 GB on every
/// launch, in the other it declares a broken cache ready and fails to load.
final class ModelCacheTests: XCTestCase {
    private var dir: URL!

    override func setUpWithError() throws {
        dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("minutiae-model-cache-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    /// Writes a compiled-model directory the way CoreML lays one out.
    private func writeModel(_ name: String) throws {
        let model = dir.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: model, withIntermediateDirectories: true)
        try Data("compiled".utf8).write(to: model.appendingPathComponent("coremldata.bin"))
    }

    private func writeFile(_ name: String, bytes: String = "{}") throws {
        try Data(bytes.utf8).write(to: dir.appendingPathComponent(name))
    }

    /// A full multilingual variant: metadata + tokenizer + the CoreML artifacts.
    private func writeCompleteMultilingual() throws {
        try writeFile(ModelNames.NemotronMultilingualStreaming.metadata)
        try writeFile(ModelNames.NemotronMultilingualStreaming.tokenizer)
        try writeModel(ModelNames.NemotronMultilingualStreaming.preprocessorFile)
        try writeModel(ModelNames.NemotronMultilingualStreaming.encoderFile)
        try writeModel(ModelNames.NemotronMultilingualStreaming.decoderFile)
        try writeModel(ModelNames.NemotronMultilingualStreaming.jointFile)
    }

    func testCompleteCacheIsReady() throws {
        try writeCompleteMultilingual()
        XCTAssertTrue(NemotronEngine.modelsComplete(in: dir, variant: .multilingual))
    }

    /// The reported bug: everything downloaded except the last file. The old
    /// metadata-only probe reported "not ready" forever and re-downloaded.
    func testMissingMetadataIsNotReady() throws {
        try writeCompleteMultilingual()
        try FileManager.default.removeItem(
            at: dir.appendingPathComponent(ModelNames.NemotronMultilingualStreaming.metadata))
        XCTAssertFalse(NemotronEngine.modelsComplete(in: dir, variant: .multilingual))
    }

    /// The inverse: metadata landed but a model did not. A metadata-only probe
    /// calls this ready and the load then fails at runtime.
    func testMetadataWithoutEncoderIsNotReady() throws {
        try writeCompleteMultilingual()
        try FileManager.default.removeItem(
            at: dir.appendingPathComponent(ModelNames.NemotronMultilingualStreaming.encoderFile))
        XCTAssertFalse(NemotronEngine.modelsComplete(in: dir, variant: .multilingual))
    }

    /// A half-written `.mlmodelc` is a directory too — existence alone is not
    /// enough, CoreML needs `coremldata.bin` inside it.
    func testEmptyModelDirectoryIsNotReady() throws {
        try writeCompleteMultilingual()
        let encoder = dir.appendingPathComponent(ModelNames.NemotronMultilingualStreaming.encoderFile)
        try FileManager.default.removeItem(at: encoder.appendingPathComponent("coremldata.bin"))
        XCTAssertFalse(NemotronEngine.modelsComplete(in: dir, variant: .multilingual))
    }

    /// Multilingual accepts either the fused `decoder_joint` or the bare pair.
    func testFusedDecoderJointSatisfiesDecodePath() throws {
        try writeFile(ModelNames.NemotronMultilingualStreaming.metadata)
        try writeFile(ModelNames.NemotronMultilingualStreaming.tokenizer)
        try writeModel(ModelNames.NemotronMultilingualStreaming.preprocessorFile)
        try writeModel(ModelNames.NemotronMultilingualStreaming.encoderFile)
        try writeModel("decoder_joint.mlmodelc")
        XCTAssertTrue(NemotronEngine.modelsComplete(in: dir, variant: .multilingual))
    }

    func testNoDecodePathIsNotReady() throws {
        try writeFile(ModelNames.NemotronMultilingualStreaming.metadata)
        try writeFile(ModelNames.NemotronMultilingualStreaming.tokenizer)
        try writeModel(ModelNames.NemotronMultilingualStreaming.preprocessorFile)
        try writeModel(ModelNames.NemotronMultilingualStreaming.encoderFile)
        XCTAssertFalse(NemotronEngine.modelsComplete(in: dir, variant: .multilingual))
    }

    func testEmptyDirectoryIsNotReady() {
        XCTAssertFalse(NemotronEngine.modelsComplete(in: dir, variant: .multilingual))
        XCTAssertFalse(NemotronEngine.modelsComplete(in: dir, variant: .english))
    }

    /// An empty file counts as absent — a zero-byte truncation is not a model.
    func testZeroLengthFileIsNotReady() throws {
        try writeCompleteMultilingual()
        try writeFile(ModelNames.NemotronMultilingualStreaming.tokenizer, bytes: "")
        XCTAssertFalse(NemotronEngine.modelsComplete(in: dir, variant: .multilingual))
    }

    // MARK: - Parakeet TDT v3 (the shipped default)

    private func writeCompleteParakeet() throws {
        for name in ParakeetEngine.requiredEntries() {
            if name.hasSuffix(".mlmodelc") { try writeModel(name) } else { try writeFile(name) }
        }
    }

    func testParakeetCompleteCacheIsReady() throws {
        try writeCompleteParakeet()
        XCTAssertTrue(ParakeetEngine.modelsComplete(in: dir))
    }

    func testParakeetEmptyDirectoryIsNotReady() {
        XCTAssertFalse(ParakeetEngine.modelsComplete(in: dir))
    }

    /// The interrupted-download case: everything but the encoder landed.
    func testParakeetMissingEncoderIsNotReady() throws {
        try writeCompleteParakeet()
        try FileManager.default.removeItem(
            at: dir.appendingPathComponent(ParakeetEncoderPrecision.int8.encoderFileName))
        XCTAssertFalse(ParakeetEngine.modelsComplete(in: dir))
    }

    /// The vocabulary is not a CoreML bundle but the decoder is useless
    /// without it, so it counts too.
    func testParakeetMissingVocabularyIsNotReady() throws {
        try writeCompleteParakeet()
        try FileManager.default.removeItem(
            at: dir.appendingPathComponent(ModelNames.ASR.vocabularyFile))
        XCTAssertFalse(ParakeetEngine.modelsComplete(in: dir))
    }

    /// A half-written `.mlmodelc` is still a directory; CoreML needs the
    /// compiled blob inside it.
    func testParakeetEmptyModelDirectoryIsNotReady() throws {
        try writeCompleteParakeet()
        let decoder = dir.appendingPathComponent(ModelNames.ASR.decoderFile)
        try FileManager.default.removeItem(at: decoder.appendingPathComponent("coremldata.bin"))
        XCTAssertFalse(ParakeetEngine.modelsComplete(in: dir))
    }

    /// A cache stamped by a different FluidAudio revision predates a
    /// deliberate version bump — re-prepare rather than load it.
    func testParakeetStaleRevisionMarkerIsNotReady() throws {
        try writeCompleteParakeet()
        try Data("0.0.0".utf8).write(to: dir.appendingPathComponent(ModelCache.readyMarkerName))
        XCTAssertFalse(ParakeetEngine.modelsComplete(in: dir))
        try Data(ParakeetEngine.version.utf8)
            .write(to: dir.appendingPathComponent(ModelCache.readyMarkerName))
        XCTAssertTrue(ParakeetEngine.modelsComplete(in: dir))
    }

    /// English keeps its encoder in a subdirectory; the check must follow it.
    func testEnglishRequiresNestedEncoder() throws {
        for name in ModelNames.NemotronStreaming.requiredModels {
            if name.hasSuffix(".mlmodelc") {
                try writeModel(name)
            } else {
                try writeFile(name)
            }
        }
        XCTAssertTrue(NemotronEngine.modelsComplete(in: dir, variant: .english))

        try FileManager.default.removeItem(
            at: dir.appendingPathComponent(ModelNames.NemotronStreaming.encoderInt8File))
        XCTAssertFalse(NemotronEngine.modelsComplete(in: dir, variant: .english))
    }
}
