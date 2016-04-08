// Copyright 2016 The Tulsi Authors. All rights reserved.
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//      http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.

import Foundation


/// Models a configuration which can be used to generate an Xcode project directly.
public class TulsiGeneratorConfig {

  public enum Error: ErrorType {
    /// The give input file does not exist or cannot be read.
    case BadInputFilePath
    /// A per-user config was found but could not be read.
    case FailedToReadAdditionalOptionsData(String)
    /// Deserialization failed with the given debug info.
    case DeserializationFailed(String)
    /// Serialization failed with the given debug info.
    case SerializationFailed(String)
  }

  /// The file extension used when saving generator configs.
  public static let FileExtension = "tulsigen"

  /// The name of the Xcode project.
  public let projectName: String

  public var defaultFilename: String {
    return TulsiGeneratorConfig.sanitizeFilename("\(projectName).\(TulsiGeneratorConfig.FileExtension)")
  }

  /// The name of the Xcode project that will be generated by this config.
  public var xcodeProjectFilename: String {
    return TulsiGeneratorConfig.sanitizeFilename("\(projectName).xcodeproj")
  }

  /// Filename to be used when writing out user-specific values.
  public static var perUserFilename: String {
    return "\(NSUserName()).tulsigen-user"
  }

  /// The Bazel targets to generate Xcode build targets for.
  public let buildTargetLabels: [BuildLabel]

  /// The directory paths for which source files should be included in the generated Xcode project.
  public let pathFilters: Set<String>

  /// Additional file paths to add to the Xcode project (e.g., BUILD file paths).
  public let additionalFilePaths: [String]?
  /// The options for this config.
  public let options: TulsiOptionSet

  /// Path to the Bazel binary.
  public var bazelURL: NSURL

  static let ProjectNameKey = "projectName"
  static let BuildTargetsKey = "buildTargets"
  // TODO(abaire): Remove after a reasonable migration period (after April 15th, 2016).
  static let SourceTargetsKey = "sourceTargets"
  static let PathFiltersKey = "sourceFilters"
  static let AdditionalFilePathsKey = "additionalFilePaths"

  /// Returns a copy of the given filename sanitized by replacing path separators.
  public static func sanitizeFilename(filename: String) -> String {
    return filename.stringByReplacingOccurrencesOfString("/", withString: "_")
  }

  public static func load(inputFile: NSURL, bazelURL: NSURL? = nil) throws -> TulsiGeneratorConfig {
    let fileManager = NSFileManager.defaultManager()
    guard let path = inputFile.path, data = fileManager.contentsAtPath(path) else {
      throw Error.BadInputFilePath
    }

    let additionalOptionData: NSData?
    let optionsFolderURL = inputFile.URLByDeletingLastPathComponent!
    let additionalOptionsFileURL = optionsFolderURL.URLByAppendingPathComponent(TulsiGeneratorConfig.perUserFilename)
    if let perUserPath = additionalOptionsFileURL.path where fileManager.isReadableFileAtPath(perUserPath) {
      additionalOptionData = fileManager.contentsAtPath(perUserPath)
      if additionalOptionData == nil {
        throw Error.FailedToReadAdditionalOptionsData("Could not read file at path \(perUserPath)")
      }
    } else {
      additionalOptionData = nil
    }

    return try TulsiGeneratorConfig(data: data,
                                    additionalOptionData: additionalOptionData,
                                    bazelURL: bazelURL)
  }

  public init(projectName: String,
              buildTargetLabels: [BuildLabel],
              pathFilters: Set<String>,
              additionalFilePaths: [String]?,
              options: TulsiOptionSet,
              bazelURL: NSURL?) {
    self.projectName = projectName
    self.buildTargetLabels = buildTargetLabels
    self.pathFilters = pathFilters
    self.additionalFilePaths = additionalFilePaths
    self.options = options

    if let bazelURL = bazelURL {
      self.bazelURL = bazelURL
    } else if let savedBazelPath = options[.BazelPath].commonValue {
      self.bazelURL = NSURL(fileURLWithPath: savedBazelPath)
    } else {
      // TODO(abaire): Flag a fallback to searching for the binary.
      self.bazelURL = NSURL()
    }
  }

  public convenience init(projectName: String,
                          buildTargets: [RuleInfo],
                          pathFilters: Set<String>,
                          additionalFilePaths: [String]?,
                          options: TulsiOptionSet,
                          bazelURL: NSURL?) {
    self.init(projectName: projectName,
              buildTargetLabels: buildTargets.map({ $0.label }),
              pathFilters: pathFilters,
              additionalFilePaths: additionalFilePaths,
              options: options,
              bazelURL: bazelURL)
  }

  public convenience init(data: NSData,
                          additionalOptionData: NSData? = nil,
                          bazelURL: NSURL? = nil) throws {
    func extractJSONDict(data: NSData, errorBuilder: (String) -> Error) throws -> [String: AnyObject] {
      do {
        guard let jsonDict = try NSJSONSerialization.JSONObjectWithData(data,
                                                                        options: NSJSONReadingOptions()) as? [String: AnyObject] else {
          throw errorBuilder("Config file contents are invalid")
        }
        return jsonDict
      } catch let e as Error {
        throw e
      } catch let e as NSError {
        throw errorBuilder(e.localizedDescription)
      } catch {
        assertionFailure("Unexpected exception")
        throw errorBuilder("Unexpected exception")
      }
    }

    let dict = try extractJSONDict(data) { Error.DeserializationFailed($0)}

    let projectName = dict[TulsiGeneratorConfig.ProjectNameKey] as? String ?? "Unnamed Tulsi Project"
    let buildTargetLabels = dict[TulsiGeneratorConfig.BuildTargetsKey] as? [String] ?? []
    let additionalFilePaths = dict[TulsiGeneratorConfig.AdditionalFilePathsKey] as? [String]

    // TODO(abaire): Clean up after a reasonable migration period (after April 15th, 2016).
    let rawPathFilters: Set<String>
    if let sourceTargetLabels = dict[TulsiGeneratorConfig.SourceTargetsKey] as? [String] {
      rawPathFilters = Set<String>(sourceTargetLabels)
    } else {
      rawPathFilters = Set<String>(dict[TulsiGeneratorConfig.PathFiltersKey] as? [String] ?? [])
    }

    // Convert any path filters specified as build labels to their package paths.
    var pathFilters = Set<String>()
    for sourceTarget in rawPathFilters {
      if let packageName = BuildLabel(sourceTarget).packageName {
        pathFilters.insert(packageName)
      }
    }

    var optionsDict = TulsiOptionSet.getOptionsFromContainerDictionary(dict) ?? [:]
    if let additionalOptionData = additionalOptionData {
      let additionalOptions = try extractJSONDict(additionalOptionData) {
        Error.FailedToReadAdditionalOptionsData($0)
      }
      guard let newOptions = TulsiOptionSet.getOptionsFromContainerDictionary(additionalOptions) else {
        throw Error.FailedToReadAdditionalOptionsData("Invalid per-user options file")
      }
      for (key, value) in newOptions {
        optionsDict[key] = value
      }
    }
    let options = TulsiOptionSet(fromDictionary: optionsDict)

    self.init(projectName: projectName,
              buildTargetLabels: buildTargetLabels.map({ BuildLabel($0) }),
              pathFilters: pathFilters,
              additionalFilePaths: additionalFilePaths,
              options: options,
              bazelURL: bazelURL)
  }

  public func save() throws -> NSData {
    let sortedBuildTargetLabels = buildTargetLabels.map({ $0.value }).sort()
    let sortedPathFilters = [String](pathFilters).sort()
    var dict: [String: AnyObject] = [
        TulsiGeneratorConfig.ProjectNameKey: projectName,
        TulsiGeneratorConfig.BuildTargetsKey: sortedBuildTargetLabels,
        TulsiGeneratorConfig.PathFiltersKey: sortedPathFilters,
    ]
    if let additionalFilePaths = additionalFilePaths {
      dict[TulsiGeneratorConfig.AdditionalFilePathsKey] = additionalFilePaths
    }
    options.saveShareableOptionsIntoDictionary(&dict)

    do {
      return try NSJSONSerialization.dataWithJSONObject(dict, options: .PrettyPrinted)
    } catch let e as NSError {
      throw Error.SerializationFailed(e.localizedDescription)
    } catch {
      throw Error.SerializationFailed("Unexpected exception")
    }
  }

  public func savePerUserSettings() throws -> NSData? {
    var dict = [String: AnyObject]()
    options.savePerUserOptionsIntoDictionary(&dict)
    if dict.isEmpty { return nil }
    do {
      return try NSJSONSerialization.dataWithJSONObject(dict, options: .PrettyPrinted)
    } catch let e as NSError {
      throw Error.SerializationFailed(e.localizedDescription)
    } catch {
      throw Error.SerializationFailed("Unexpected exception")
    }
  }
}
