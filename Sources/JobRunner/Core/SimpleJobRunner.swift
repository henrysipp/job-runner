//
//  SimpleJobRunner.swift
//  job-runner
//
//  Created by Henry on 2/3/26.
//

import Foundation

/// A typealias for JobRunner with Void context for simple jobs that don't need dependencies
public typealias SimpleJobRunner = JobRunner<Void>
