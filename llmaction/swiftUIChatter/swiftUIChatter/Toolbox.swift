//
//  Toolbox.swift
//  swiftUIChatter
//
//  Created by Niki Murthy on 3/30/26.
//


import Foundation

struct OllamaToolSchema: Codable {
    let type: String
    let function: OllamaToolFunction
}

struct OllamaToolFunction: Codable {
    let name: String
    let description: String
    let parameters: OllamaFunctionParams?
}

struct OllamaFunctionParams: Codable {
    let type: String
    let properties: [String:OllamaParamProp]?
    let required: [String]?
}

struct OllamaParamProp: Codable {
    let type: String
    let description: String
    let enum_: [String]?
    
    enum CodingKeys: String, CodingKey {
        // to map json field to property
        // if specify one, must specify all
        case type = "type"
        case description = "description"
        case enum_ = "enum"
    }
}

struct OllamaToolCall: Codable {
    let function: OllamaFunctionCall
}

struct OllamaFunctionCall: Codable {
    let name: String
    let arguments: [String:String]
}

typealias ToolFunction = ([String]) async -> String?

struct Tool {
    let schema: OllamaToolSchema
    let function: ToolFunction
}

let TOOLBOX = [
    "get_location": Tool(schema: jsonToSchema("get_location"), function: getLocation),
    "get_auth": Tool(schema: jsonToSchema("get_auth"), function: getAuth),
]

func getLocation(_ argv: [String]) async -> String? {
    "latitude: \(LocManagerViewModel.shared.location.lat), longitude: \(LocManagerViewModel.shared.location.lon)"
}

func getAuth(_ argv: [String]) async -> String? {
    if let id = ChatterID.shared.id {
        return id
    }
    return nil
}

func jsonToSchema(_ tool: String) -> OllamaToolSchema {
    guard let url = Bundle.main.url(forResource: tool, withExtension: "json"), // prior to Xcode 16: subdirectory: "tools"),
          let data = try? Data(contentsOf: url) else {
        fatalError("Failed to find \(tool).json in bundle")
    }
    
    do {
        return try JSONDecoder().decode(OllamaToolSchema.self, from: data)
    } catch {
        fatalError("Failed to decode \(tool).json: \(error)")
    }
}


func toolInvoke(function: OllamaFunctionCall) async -> String? {
    if let tool = TOOLBOX[function.name] {
        var argv = [String]()
        for label in tool.schema.function.parameters?.required ?? [] {
            // get arguments in order, Dict doesn't preserve insertion order;
            // arguments may also arrive out of order from the back end
            if let arg = function.arguments[label] {
                argv.append(arg)
            }
        }
        return await tool.function(argv)
    }
    return nil
}
