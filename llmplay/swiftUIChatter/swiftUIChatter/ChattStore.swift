import SwiftUI

struct OllamaReply: Decodable {
    let model: String
    let response: String
}

enum SseEventType { case Error, Message }

struct OllamaMessage: Codable {
    let role: String
    let content: String?
}

struct OllamaRequest: Encodable {
    let appID: String?
    let model: String?
    let messages: [OllamaMessage]
    let stream: Bool
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
            messages: [OllamaMessage(role: "system", content: chatt.message)],
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
    func llmChat(appID: String, chatt: Chatt, errMsg: Binding<String>) async {
        
        self.chatts.append(chatt)
        
        // prepare placeholder
        let resChatt = Chatt( // placeholder for assistant's streaming reply
            name: "assistant (\(chatt.name ?? "ollama"))",
            message: "")
        self.chatts.append(resChatt)
        
        // prepare prompt
        guard let apiUrl = URL(string: "\(serverUrl)/llmchat") else {
            errMsg.wrappedValue = "llmPrompt: Bad URL"
            return
        }
        let ollamaRequest = OllamaRequest(
            appID: appID,
            model: chatt.name,
            messages: [OllamaMessage(role: "user", content: chatt.message)],
            stream: true
        )
        guard let requestBody = try? JSONEncoder().encode(ollamaRequest) else {
            errMsg.wrappedValue = "llmChat: JSONEncoder error"
            return
        }
        
        // prepare request
        var request = URLRequest(url: apiUrl)
        request.timeoutInterval = 1200 // for 20 minutes
        request.httpMethod = "POST"
        request.setValue("application/json; charset=utf-8", forHTTPHeaderField: "Content-Type")
        request.setValue("text/event-streaming", forHTTPHeaderField: "Accept")
        request.httpBody = requestBody
        
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
                        sseEvent = .Message
                        resChatt.message?.append("\n\n**llmChat Error**: \(errMsg.wrappedValue)\n\n")
                    }
                    continue
                }
                
                let parts = line.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
                let event = parts[1].trimmingCharacters(in: .whitespaces)
                if parts[0].starts(with: "event") {
                    if event == "error" {
                        sseEvent = .Error
                    } else if !event.isEmpty && event != "message" {
                        // we only support "error" event,
                        print("LLMCHAT: Unknown event: '\(parts[1])'")
                    }
                } else if parts[0].starts(with: "data") {
                    // not an event line, must be data line;
                    // multiple data lines can belong to the same event
                    let data = Data(event.utf8)
                    do {
                        let ollamaResponse = try JSONDecoder().decode(OllamaResponse.self, from: data)
                        if let token = ollamaResponse.message.content {
                            if sseEvent == .Error {
                                errMsg.wrappedValue += token
                            } else {
                                resChatt.message?.append(token)
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
        
    }
    
    

}
