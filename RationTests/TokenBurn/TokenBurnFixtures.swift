import Foundation

/// Synthetic Claude Code log lines built from the verified field names only.
enum TokenBurnFixtures {
    static func line(id: String = "msg_1", request: String = "req_1", timestamp: String = "2026-09-29T10:15:00.250Z",
                     model: String = "claude-opus-5-5", input: Int = 10, output: Int = 20, cacheRead: Int = 30,
                     cacheWrite: Int = 40, split5m: Int? = 40, split1h: Int? = 0, tier: String? = "standard",
                     speed: String? = "standard", geo: String? = "not_available", webSearches: Int = 0,
                     text: String = "hello") -> String {
        var usage: [String: Any] = ["input_tokens": input, "output_tokens": output,
                                    "cache_read_input_tokens": cacheRead, "cache_creation_input_tokens": cacheWrite,
                                    "server_tool_use": ["web_search_requests": webSearches, "web_fetch_requests": 0]]
        if let split5m, let split1h {
            usage["cache_creation"] = ["ephemeral_5m_input_tokens": split5m, "ephemeral_1h_input_tokens": split1h]
        }
        if let tier { usage["service_tier"] = tier }
        if let speed { usage["speed"] = speed }
        if let geo { usage["inference_geo"] = geo }
        let record: [String: Any] = [
            "type": "assistant", "timestamp": timestamp, "requestId": request, "sessionId": "s1",
            "message": ["id": id, "model": model, "role": "assistant",
                        "content": [["type": "text", "text": text]], "usage": usage],
        ]
        let data = try! JSONSerialization.data(withJSONObject: record, options: [.sortedKeys])
        return String(decoding: data, as: UTF8.self)
    }

    static func userLine(text: String = "please ask the assistant") -> String {
        #"{"type":"user","message":{"role":"user","content":"\#(text)"}}"#
    }
}
