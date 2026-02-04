//
//  JobRegistry.swift
//  job-runner
//
//  Created by Henry on 2/3/26.
//

import Foundation

nonisolated final class JobRegistry<Context: Sendable> {
  private var types: [String: Any] = [:]
  
  func register<J: Job>(_ type: J.Type) where J.Context == Context {
    let name = String(describing: type)
    types[name] = type
  }
  
  func encode<J: Job>(_ job: J) throws -> (String, Data) where J.Context == Context {
    let typeName = String(describing: type(of: job))
    let data = try JSONEncoder().encode(job)
    return (typeName, data)
  }
  
  func decode(_ serialized: SerializedJob) throws -> any Job<Context> {
    guard let type = types[serialized.typeName] else {
      throw JobError.unknownJobType(serialized.typeName)
    }
    guard let jobType = type as? any Job<Context>.Type else {
      throw JobError.unknownJobType(serialized.typeName)
    }
    return try JSONDecoder().decode(jobType, from: serialized.jobData)
  }
}
