//
//  Example.swift
//  JobRunner
//
//  Created by Henry on 2/3/26.
//

import Foundation
import JobRunner

#if canImport(UIKit)
    import UIKit

    /// Context providing dependencies for asset download jobs
    public struct AssetDownloadContext: Sendable {
        public let urlSession: URLSession

        public init(urlSession: URLSession = .shared) {
            self.urlSession = urlSession
        }

        // TODO: Implement image saving
        // func saveImage(data: Data, for url: URL) async throws

        // TODO: Implement video saving
        // func saveVideo(data: Data, for url: URL) async throws

        // TODO: Implement document saving
        // func saveDocument(data: Data, for url: URL) async throws
    }

    /// A typealias for JobRunner configured for asset downloads
    public typealias AssetDownloadJobRunner = JobRunner<AssetDownloadContext>

    public extension AssetDownloadJobRunner {
        static let shared = {
            let context = AssetDownloadContext()
            return AssetDownloadJobRunner(context: context, maxConcurrent: 2, maxAttempts: 3)
        }()
    }

    func TestAssetDownloader() async throws {
        try await AssetDownloadJobRunner.shared.register(AssetDownloadJob.self)
        try await AssetDownloadJobRunner.shared.start()

        try await AssetDownloadJobRunner.shared.enqueue(
            AssetDownloadJob(url: URL(string: "https://example.com/video.mp4")!)
        )
    }

#endif
