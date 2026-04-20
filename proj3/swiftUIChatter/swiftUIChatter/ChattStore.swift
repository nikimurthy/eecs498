import SwiftUI

struct OllamaReply: Decodable {
    let model: String
    let response: String
}

enum SseEventType { case Error, Message, ToolCalls }

struct OllamaMessage: Codable {
    let role: String
    let content: String?
    let thinking: String?
    let toolCalls: [OllamaToolCall]?
    
    enum CodingKeys: String, CodingKey {
        // to map json field to property
        // if one is specified, must specify all
        case role = "role"
        case content = "content"
        case thinking = "thinking"
        case toolCalls = "tool_calls"
    }
}

struct OllamaRequest: Encodable {
    let appID: String?
    let model: String?
    var messages: [OllamaMessage]
    let stream: Bool
    var tools: [OllamaToolSchema]?
}

struct OllamaResponse: Decodable {
    let model: String
    let message: OllamaMessage
}

@Observable
final class ChattStore {
    static let shared = ChattStore() // create one instance of the class to be shared, and
    private init() {} // make the constructor private so no other instances can be created

    private(set) var chatts = [Chatt]()

    private let serverUrl = "https://3.129.24.48"
//    private let serverUrl = "https://mada.eecs.umich.edu"
  
    
    func llmPrep(appID: String, chatt: Chatt, errMsg: Binding<String>) async {
        guard let apiUrl = URL(string: "\(serverUrl)/llmprep") else {
            errMsg.wrappedValue = "llmPrep: Bad URL"
            return
        }

        let ollamaRequest = OllamaRequest(
            appID: appID,
            model: chatt.name,
            messages: [OllamaMessage(role: "system", content: chatt.message, thinking: nil, toolCalls: nil)],
            stream: false
        )

        guard let requestBody = try? JSONEncoder().encode(ollamaRequest) else {
            errMsg.wrappedValue = "llmPrep: JSONEncoder error"
            return
        }

        var request = URLRequest(url: apiUrl)
        request.httpMethod = "POST"
        request.setValue("application/json; charset=utf-8", forHTTPHeaderField: "Content-Type")
        request.httpBody = requestBody

        do {
            let (_, response) = try await URLSession.shared.data(for: request)

            if let http = response as? HTTPURLResponse, http.statusCode != 200 {
                errMsg.wrappedValue = "llmPrep: \(http.statusCode)\n\(apiUrl)\n\(HTTPURLResponse.localizedString(forStatusCode: http.statusCode))"
            }
        } catch {
            errMsg.wrappedValue = "llmPrep: POSTing failed \(error)"
        }
    }
    
    
    // networking methods
    func llmTools(appID: String, chatt: Chatt, errMsg: Binding<String>) async {
        
        self.chatts.append(chatt)
        
        // prepare placeholder
        let resChatt = Chatt( // placeholder for assistant's streaming reply
            name: "assistant (\(chatt.name ?? "ollama"))",
            message: "")
        self.chatts.append(resChatt)
        
        // prepare prompt
        guard let apiUrl = URL(string: "\(serverUrl)/llmtools") else {
            errMsg.wrappedValue = "llmPrompt: Bad URL"
            return
        }
        var ollamaRequest = OllamaRequest(
            appID: appID,
            model: chatt.name,
            messages: [OllamaMessage(role: "user", content: chatt.message, thinking: nil, toolCalls: nil)],
            stream: true,
            tools: TOOLBOX.isEmpty ? nil : []
        )
        
        // append all on-device tools to ollamaRequest
        for (_, tool) in TOOLBOX {
            ollamaRequest.tools?.append(tool.schema)
        }
        
        // prepare request
        var request = URLRequest(url: apiUrl)
        request.timeoutInterval = 1200 // for 20 minutes
        request.httpMethod = "POST"
        request.setValue("application/json; charset=utf-8", forHTTPHeaderField: "Content-Type")
        request.setValue("text/event-streaming", forHTTPHeaderField: "Accept")
        
        
        var sendNewPrompt = true
        while sendNewPrompt {
            sendNewPrompt = false
                        
            guard let requestBody = try? JSONEncoder().encode(ollamaRequest) else {
                errMsg.wrappedValue = "llmTools: JSONEncoder error"
                return
            }
            request.httpBody = requestBody
            
            // leave existing do-catch block here
            // connect to chatterd and Ollama
            do {
                let (bytes, response) = try await URLSession.shared.bytes(for: request)
                
                if let http = response as? HTTPURLResponse, http.statusCode != 200 {
                    var msg = ""
                    for try await line in bytes.lines {
                        guard let data = line.data(using: .utf8) else {
                            continue
                        }
                        msg += String(data: data, encoding: .utf8) ?? ""
                    }
                    errMsg.wrappedValue = "\(http.statusCode)\n\(apiUrl)\n\(msg.isEmpty ? HTTPURLResponse.localizedString(forStatusCode: http.statusCode) : msg)"
                    return
                }
                
                // receive Ollama response
                // streaming NDJSON
                // streaming SSE
                var sseEvent = SseEventType.Message
                var line = ""
                for try await char in bytes.characters {
                    if char != "\n" && char != "\r\n" { // Python eol is "\r\n"
                        line.append(char)
                        continue
                    }
                    if line.isEmpty {
                        // new SSE event, default to Message
                        // SSE events are delimited by "\n\n"
                        if (sseEvent == .Error) {
                            resChatt.message?.append("\n\n**llmChat Error**: \(errMsg.wrappedValue)\n\n")
                        }
                        sseEvent = .Message
                        continue
                    }
                    
                    let parts = line.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
                    let event = parts[1].trimmingCharacters(in: .whitespaces)
                    if parts[0].starts(with: "event") {
                        if event == "error" {
                            sseEvent = .Error
                        } else if event == "tool_calls" {
                            sseEvent = .ToolCalls
                        } else if !event.isEmpty && event != "message" {
                            // we only support "error" event,
                            print("LLMCHAT: Unknown event: '\(parts[1])'")
                        }
                    } else if parts[0].starts(with: "data") {
                        if sseEvent == .Error {
                            errMsg.wrappedValue += String(describing: parts[1].trimmingCharacters(in: .whitespaces).utf8)
                            
                            line = ""
                            continue
                        }
                        
                        let data = Data(parts[1].trimmingCharacters(in: .whitespaces).utf8)
                        
                        do {
                            let ollamaResponse = try JSONDecoder().decode(OllamaResponse.self, from: data)
                            
                            if let token = ollamaResponse.message.content, !token.isEmpty {
                                resChatt.message?.append(token)
                            }
//                            } else if let token = ollamaResponse.message.thinking, !token.isEmpty {
//                                resChatt.message?.append(token)
//                            }
                            
                            // check tool call and make the tool call
                            if sseEvent == .ToolCalls, let toolCalls = ollamaResponse.message.toolCalls {
                                // message.content is usually empty
                                for toolCall in toolCalls {
                                    let toolResult = await toolInvoke(function: toolCall.function)
                                    
                                    if toolResult != nil {
                                        // reuse OllamaMessage to carry tool result
                                        // to be sent back to Ollama
                                        ollamaRequest.messages.append(
                                            OllamaMessage(role: "tool", content: toolResult, thinking: nil, toolCalls: nil)
                                        )
                                        // don't send tools multiple times
                                        ollamaRequest.tools = nil
                                        
                                        // send result back to Ollama
                                        sendNewPrompt = true
                                    } else {
                                        // tool unknown, report to user as error
                                        errMsg.wrappedValue += "llmTools ERROR: tool '\(toolCall.function.name)' called"
                                        resChatt.message?.append("\n\n**llmTools Error**: tool '\(toolCall.function.name)' called\n\n")
                                    }
                                }
                            }
                            
                            
                        } catch {
                            errMsg.wrappedValue += "\(error)\n\(apiUrl)\n\(String(data: data, encoding: .utf8) ?? "decoding error")"
                        }
                    }
                    line = ""
                    
                }
            } catch {
                errMsg.wrappedValue = "llmPrompt: failed \(error)"
            }
            
        } // while sendNewPrompt
        
        
    }
    
    func addUser(_ idToken: String?, errMsg: Binding<String>) async -> String? {
        guard let idToken else {
            return nil
        }

        guard let apiUrl = URL(string: "\(serverUrl)/adduser") else {
            errMsg.wrappedValue = "addUser: Bad URL"
            return nil
        }
        let authObj = ["clientID": "40540597127-9i6gmrn97gvf89798gfuv0pqo4om0oq3.apps.googleusercontent.com",
                       "idToken" : idToken]
        guard let requestBody = try? JSONSerialization.data(withJSONObject: authObj) else {
            errMsg.wrappedValue = "addUser: JSONSerialization error"
            return nil
        }
        
        var request = URLRequest(url: apiUrl)
        request.httpMethod = "POST"
        request.setValue("application/json; charset=utf-8", forHTTPHeaderField: "Content-Type")
        request.httpBody = requestBody
        
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            
            if let http = response as? HTTPURLResponse, http.statusCode != 200 {
                errMsg.wrappedValue = "addUser: \(http.statusCode) \(HTTPURLResponse.localizedString(forStatusCode: http.statusCode))\n\(apiUrl)"
                return nil
            }
            
            // obtain username and chatterID from back end
            guard let chatterObj = try? JSONSerialization.jsonObject(with: data) as? [String:Any] else {
                errMsg.wrappedValue = "addUser: JSON deserialization"
                return nil
            }

            if let creator = chatterObj["username"] as? String {
                if creator.count > 32 {
                    errMsg.wrappedValue = "addUser: creator name (\(creator) longer than 32 characters"
                    return nil
                }
                ChatterID.shared.creator = creator
            }
            ChatterID.shared.id = chatterObj["chatterID"] as? String
            ChatterID.shared.expiration = Date()+(chatterObj["lifetime"] as! TimeInterval)
            
            return ChatterID.shared.id

        } catch {
            errMsg.wrappedValue = "addUser: POSTing failed \(error)"
            return nil
        }
    }
    
    

}
