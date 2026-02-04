//
//  AssetDownloadError.swift
//  job-runner
//
//  Created by Henry on 2/4/26.
//

import Foundation

public enum AssetDownloadError: Error, Equatable, Sendable {
  case invalidURL(String)
  case downloadFailed(URL, statusCode: Int)
  case invalidImageData(URL)
  case cacheFailed(URL)
  case unsupportedAssetType(URL)
  case networkError(URL, description: String)
}
