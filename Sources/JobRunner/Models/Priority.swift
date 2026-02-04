//
//  Priority.swift
//  job-runner
//
//  Created by Henry on 2/3/26.
//

import Foundation

public nonisolated enum Priority: Int, Codable, Comparable, Sendable {
  case low = 0
  case medium = 1
  case high = 2
  case immediate = 3
  
  public static func < (lhs: Priority, rhs: Priority) -> Bool {
    lhs.rawValue < rhs.rawValue
  }
}
