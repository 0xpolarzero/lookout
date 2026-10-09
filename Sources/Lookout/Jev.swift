import Foundation

/// TypeSafe's Jev (a "System One" model): given some state and a list of options, it picks one, with probabilities.
/// It doesn't write text, and only input is billed. https://docs.typesafe.ai/api
struct JevClient {
    let key: String
    var endpoint = URL(string: "https://api.typesafe.ai/v1/systemone")!
    var session = Network.session

    struct Failure: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    struct Choice {
        let choice: String
        let confidence: Double
        /// Every option's probability (they sum to 1).
        let probabilities: [String: Double]
    }

    /// The best of `options` for `state`, and how sure Jev is. `hints` describes options whose name isn't enough.
    func choose(_ options: [String], hints: [String: String] = [:], for state: [String: String], instructions: String) async throws -> Choice {
        // Option keys: SF Symbol names use dots; keep keys plain and map back.
        let keys = Dictionary(uniqueKeysWithValues: options.map { (Self.key(for: $0), $0) })
        let body: [String: Any] = [
            "model": "jev-latest",
            "state": state,
            "questions": [
                "pick": [
                    "type": "choice",
                    "instructions": instructions,
                    "criteria": keys.mapValues { option -> Any in hints[option] ?? NSNull() },
                ],
            ],
        ]
        var request = URLRequest(url: endpoint, timeoutInterval: 20)
        request.httpMethod = "POST"
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, response) = try await session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else {
            let message = switch status {
            case 401: "TypeSafe didn't accept the API key"
            case 429, 529: "TypeSafe is busy, will retry later"
            default: "TypeSafe returned \(status)"
            }
            throw Failure(message: message)
        }
        return try Self.parse(data, keys: keys)
    }

    static func key(for option: String) -> String {
        option.replacingOccurrences(of: ".", with: "_")
    }

    static func parse(_ data: Data, keys: [String: String]) throws -> Choice {
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let pick = (json["answers"] as? [String: Any])?["pick"] as? [String: Any],
              let key = pick["choice"] as? String, let option = keys[key] else {
            throw Failure(message: "Unexpected answer from TypeSafe")
        }
        // The distribution is what callers decide on: one that is missing or doesn't add up is an error, never made up.
        guard let raw = pick["probabilities"] as? [String: Any], !raw.isEmpty else {
            throw Failure(message: "TypeSafe's answer has no probabilities")
        }
        var probabilities: [String: Double] = [:]
        for (key, value) in raw {
            guard let option = keys[key], let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
                  number.doubleValue.isFinite, (0...1).contains(number.doubleValue) else {
                throw Failure(message: "TypeSafe's probabilities are invalid")
            }
            probabilities[option] = number.doubleValue
        }
        guard (0.98...1.02).contains(probabilities.values.reduce(0, +)) else {
            throw Failure(message: "TypeSafe's probabilities don't add up")
        }
        return Choice(choice: option, confidence: (pick["confidence"] as? Double) ?? 0, probabilities: probabilities)
    }
}

extension Claude {
    /// The first thing you asked in a session (skipping commands and system notes), from the transcript's head.
    static func firstMessage(head: Data) -> String? {
        for line in head.split(separator: UInt8(ascii: "\n")) {
            guard let obj = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any],
                  obj["type"] as? String == "user", obj["isMeta"] as? Bool != true else { continue }
            let content = (obj["message"] as? [String: Any])?["content"]
            let text: String? = (content as? String)
                ?? (content as? [[String: Any]])?.first { $0["type"] as? String == "text" }?["text"] as? String
            guard let text = text?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty, !text.hasPrefix("<") else { continue }
            return String(text.prefix(2000))
        }
        return nil
    }

    static func head(of url: URL, bytes: Int = 256 * 1024) -> Data {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return Data() }
        defer { try? handle.close() }
        return (try? handle.read(upToCount: bytes)) ?? Data()
    }
}
