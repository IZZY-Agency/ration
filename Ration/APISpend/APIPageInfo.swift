import Foundation

struct APIPageInfo: Decodable, Equatable {
    let hasMore: Bool
    let nextPage: String?

    static func decode(_ data: Data) throws -> APIPageInfo {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        do { return try decoder.decode(APIPageInfo.self, from: OpenAISpendDecoder.normalizingZeroExponents(data)) } catch {
            throw APISpendError.integrationChanged(.decode)
        }
    }
}
