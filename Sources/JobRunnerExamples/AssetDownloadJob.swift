//
//  AssetDownloadJob.swift
//  job-runner
//
//  Created by Henry on 2/4/26.
//

import Foundation
import JobRunner

#if canImport(UIKit)
import UIKit

public enum AssetType: Sendable {
  case image
  case video
  case document

  public init?(url: URL) {
    let ext = url.pathExtension.lowercased()
    switch ext {
    case "jpg", "jpeg", "png", "gif", "webp", "heic":
      self = .image
    case "mp4", "mov", "m4v", "avi":
      self = .video
    case "pdf", "doc", "docx", "txt":
      self = .document
    default:
      return nil
    }
  }
}

public struct AssetDownloadJob: Job {
  public typealias Context = AssetDownloadContext

  public let url: URL

  public init(url: URL) {
    self.url = url
  }

  public func run(context: AssetDownloadContext) async throws {
    guard let assetType = AssetType(url: url) else {
      throw AssetDownloadError.unsupportedAssetType(url)
    }

    let (data, response) = try await context.urlSession.data(from: url)

    guard let httpResponse = response as? HTTPURLResponse else {
      throw AssetDownloadError.networkError(url, description: "Invalid response type")
    }

    guard (200...299).contains(httpResponse.statusCode) else {
      throw AssetDownloadError.downloadFailed(url, statusCode: httpResponse.statusCode)
    }

    switch assetType {
    case .image:
      guard UIImage(data: data) != nil else {
        throw AssetDownloadError.invalidImageData(url)
      }
      // TODO: Implement image saving
      // try await context.saveImage(data: data, for: url)
      break

    case .video:
      // TODO: Implement video saving
      // try await context.saveVideo(data: data, for: url)
      break

    case .document:
      // TODO: Implement document saving
      // try await context.saveDocument(data: data, for: url)
      break
    }
  }
}
#endif
