// HostedImageStoreTests.swift

import Foundation
import Testing
import UniformTypeIdentifiers
@testable import BattyKit

@MainActor
struct HostedImageStoreTests {
    private let f = HostedImageFixture()

    private func expectKeptNothing() async {
        #expect(f.digestFolders().isEmpty)
        #expect(await f.store.records().isEmpty)
        #expect(f.temporaryContents().isEmpty)
    }

    private func failure(_ image: HostedBackgroundImage) async -> HostedImageError? {
        do {
            _ = try await f.store.fetch(image)
            return nil
        } catch {
            return error
        }
    }

    @Test func goodPNGIsStoredUnderTheCatalogTitleAndRecordedByItsURL() async throws {
        let image = f.image(data: try BackgroundTestImage.encoded())
        let path = try await f.store.fetch(image)
        #expect((path as NSString).lastPathComponent == "Harbor at Night.png")
        #expect(TerminalBackgroundImageImporter.inspect(path: path, directory: f.hostedFolder) == .usable)
        let records = await f.store.records()
        #expect(records.count == 1)
        #expect(records.first?.url == image.full)
        #expect(records.first?.digest == TerminalBackgroundImageImporter.digest(ofPath: path))
        #expect(await f.store.digests() == Set(records.map(\.digest)))
        #expect(f.fetcher.requests.last?.byteLimit == BackgroundCatalogLimits.fullBytes)
    }

    @Test func goodJPEGIsReencodedToAPNG() async throws {
        let image = f.image(data: try BackgroundTestImage.encoded(type: .jpeg), fileExtension: "jpg")
        let path = try await f.store.fetch(image)
        #expect(path.hasSuffix(".png"))
        #expect(HostedImageHeader.read(URL(fileURLWithPath: path))?.type == "public.png")
    }

    @Test func secondFetchReturnsTheLocalCopyWithoutARequest() async throws {
        let image = f.image(data: try BackgroundTestImage.encoded())
        let first = try await f.store.fetch(image)
        f.fetcher.set(.failure(.unreachable), for: image.full)
        let second = try await f.store.fetch(image)
        #expect(first == second)
        #expect(f.fetcher.count(image.full) == 1)
        #expect(await f.store.localPath(for: image) == first)
    }

    @Test(arguments: ["gif", "html"])
    func unsupportedTypeKeepsNothing(_ kind: String) async throws {
        let data = kind == "gif" ? try BackgroundTestImage.encoded(type: .gif) : Data("<html>hi</html>".utf8)
        let image = f.image(data: data)
        #expect(await failure(image) == .unsupportedType)
        await expectKeptNothing()
    }

    @Test(arguments: [("jpg", "png"), ("png", "jpeg"), ("gif", "png"), ("", "png")])
    func typeNotMatchingTheExtensionKeepsNothing(_ fileExtension: String, _ actual: String) async throws {
        let type: UTType = actual == "png" ? .png : .jpeg
        let image = f.image(data: try BackgroundTestImage.encoded(type: type), fileExtension: fileExtension)
        #expect(await failure(image) == .unsupportedType)
        await expectKeptNothing()
    }

    @Test func overLimitHeaderIsRefusedBeforeImport() async throws {
        let data = HostedImageFixture.patchingIHDR(try BackgroundTestImage.encoded(), width: 20_000, height: 20_000)
        let image = f.image(data: data)
        #expect(await failure(image) == .tooManyPixels)
        await expectKeptNothing()
    }

    @Test func notFoundKeepsNothing() async throws {
        let image = f.image(data: try BackgroundTestImage.encoded())
        f.fetcher.set(.failure(.notFound), for: image.full)
        #expect(await failure(image) == .fetch(.notFound))
        #expect(HostedImageError.fetch(.notFound).message(host: "batty.sstools.co") == "Not found (404)")
        await expectKeptNothing()
    }

    @Test func fetcherRefusingAnOversizedFileKeepsNothing() async throws {
        let image = f.image(data: try BackgroundTestImage.encoded())
        f.fetcher.set(.failure(.tooLarge), for: image.full)
        #expect(await failure(image) == .fetch(.tooLarge))
        await expectKeptNothing()
    }

    @Test func temporaryFolderIsRemovedOnSuccessAndFailure() async throws {
        let good = f.image(id: "good", data: try BackgroundTestImage.encoded())
        _ = try await f.store.fetch(good)
        #expect(f.temporaryContents().isEmpty)
        let bad = f.image(id: "bad", data: Data("<html>hi</html>".utf8))
        #expect(await failure(bad) == .unsupportedType)
        #expect(f.temporaryContents().isEmpty)
    }

    @Test func corruptRecordsFileReadsAsNoRecords() async throws {
        try FileManager.default.createDirectory(at: f.hostedFolder, withIntermediateDirectories: true)
        try Data("not json".utf8).write(to: f.store.recordsFile)
        #expect(await f.store.records().isEmpty)
        let image = f.image(data: try BackgroundTestImage.encoded())
        _ = try await f.store.fetch(image)
        #expect(await f.store.records().count == 1)
    }

    @Test func overLimitHeaderIsRefusedWithoutDecoding() async throws {
        let imports = DecodeCounter()
        let store = HostedImageStore(directory: f.hostedFolder, fetcher: f.fetcher, temporaryRoot: f.temporaryRoot, importImage: { _ in
            imports.increment()
            throw CancellationError()
        })
        let huge = HostedImageFixture.patchingIHDR(try BackgroundTestImage.encoded(width: 16, height: 16), width: 20_000, height: 20_000)
        let image = f.image(data: huge)
        do {
            _ = try await store.fetch(image)
            Issue.record("expected a refusal")
        } catch {
            #expect(error == .tooManyPixels)
        }
        #expect(imports.value == 0)
    }

    @Test func removeRecordsDropsOnlyTheGivenURLsAndKeepsTheFiles() async throws {
        let one = f.image(id: "one", data: try BackgroundTestImage.encoded(width: 40))
        let two = f.image(id: "two", data: try BackgroundTestImage.encoded(width: 41))
        let onePath = try await f.store.fetch(one)
        _ = try await f.store.fetch(two)
        await f.store.removeRecords(for: [one.full])
        #expect(await f.store.records().map(\.url) == [two.full])
        #expect(FileManager.default.fileExists(atPath: onePath))
        #expect(f.digestFolders().count == 2)
    }
}

/// A thread-safe tally for decode-counting seams.
nonisolated final class DecodeCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    var value: Int { lock.withLock { count } }
    func increment() { lock.withLock { count += 1 } }
}
