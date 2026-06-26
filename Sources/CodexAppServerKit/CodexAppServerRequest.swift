import Foundation

/// A JSON-RPC request initiated by the app-server and delivered to the host.
public struct CodexAppServerRequest: Sendable {
    /// A JSON-RPC request identifier supplied by the app-server.
    public enum ID: Sendable, Equatable {
        case integer(Int)
        case string(String)
    }

    /// The request identifier the response must echo.
    public var id: ID

    /// The app-server request method.
    public var method: String

    /// The encoded request parameters.
    public var params: Data

    /// Creates a server-initiated app-server request.
    public init(id: ID, method: String, params: Data) {
        self.id = id
        self.method = method
        self.params = params
    }

    /// Decodes the request parameters as `Value`.
    public func decodeParams<Value: Decodable>(
        _ type: Value.Type = Value.self,
        decoder: JSONDecoder = JSONDecoder()
    ) throws -> Value {
        try decoder.decode(type, from: params)
    }
}

/// A JSON-RPC response for a server-initiated app-server request.
public struct CodexAppServerResponse: Sendable {
    package enum Payload: Sendable {
        case result(Data)
        case error(code: Int, message: String)
    }

    package var payload: Payload

    package init(payload: Payload) {
        self.payload = payload
    }

    /// Creates an empty successful response.
    public static func emptyResult() throws -> Self {
        try result(EmptyResponse())
    }

    /// Creates a successful response by encoding `value` as the JSON-RPC result.
    public static func result<Value: Encodable>(
        _ value: Value,
        encoder: JSONEncoder = JSONEncoder()
    ) throws -> Self {
        .init(payload: .result(try encoder.encode(value)))
    }

    /// Creates a successful response from pre-encoded JSON result data.
    public static func jsonResult(_ data: Data) -> Self {
        .init(payload: .result(data))
    }

    /// Creates a JSON-RPC error response.
    public static func error(code: Int, message: String) -> Self {
        .init(payload: .error(code: code, message: message))
    }
}

/// Handles app-server requests that require a host-side answer.
public typealias CodexAppServerRequestHandler =
    @Sendable (CodexAppServerRequest) async throws -> CodexAppServerResponse

extension CodexAppServerRequest.ID {
    package init?(jsonObject: Any?) {
        switch jsonObject {
        case let value as Int:
            self = .integer(value)
        case let value as String:
            self = .string(value)
        default:
            return nil
        }
    }

    package var jsonObject: Any {
        switch self {
        case .integer(let value):
            value
        case .string(let value):
            value
        }
    }
}
