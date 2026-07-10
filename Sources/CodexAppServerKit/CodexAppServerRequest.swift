import CoreFoundation
import Foundation

package enum CodexServerRequestID: Hashable, Sendable, Codable {
    case integer(Int64)
    case string(String)

    package init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let value = try? container.decode(Int64.self) {
            self = .integer(value)
        } else {
            self = .string(try container.decode(String.self))
        }
    }

    package func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .integer(let value):
            try container.encode(value)
        case .string(let value):
            try container.encode(value)
        }
    }

    package init?(jsonObject: Any?) {
        switch jsonObject {
        case let value as String:
            self = .string(value)
        case let value as NSNumber where CFGetTypeID(value) != CFBooleanGetTypeID():
            let integer = value.int64Value
            guard value.doubleValue.isFinite,
                  value.doubleValue == Double(integer) else {
                return nil
            }
            self = .integer(integer)
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

package enum CodexAppServerRequest: Equatable, Sendable {
    case commandExecutionApproval(CodexCommandExecutionApprovalRequest)
    case fileChangeApproval(CodexFileChangeApprovalRequest)
    case userInput(CodexUserInputRequest)
    case mcpElicitation(CodexMCPElicitationRequest)
    case permissions(CodexPermissionsRequest)
    case dynamicToolCall(CodexDynamicToolCallRequest)
    case chatGPTAuthTokensRefresh(CodexChatGPTAuthTokensRefreshRequest)
    case attestationGenerate(CodexAttestationGenerateRequest)
    case currentTimeRead(CodexCurrentTimeReadRequest)
    case unknown(CodexRawServerRequest)

    package var method: String {
        switch self {
        case .commandExecutionApproval:
            "item/commandExecution/requestApproval"
        case .fileChangeApproval:
            "item/fileChange/requestApproval"
        case .userInput:
            "item/tool/requestUserInput"
        case .mcpElicitation:
            "mcpServer/elicitation/request"
        case .permissions:
            "item/permissions/requestApproval"
        case .dynamicToolCall:
            "item/tool/call"
        case .chatGPTAuthTokensRefresh:
            "account/chatgptAuthTokens/refresh"
        case .attestationGenerate:
            "attestation/generate"
        case .currentTimeRead:
            "currentTime/read"
        case .unknown(let request):
            request.method
        }
    }
}

package struct CodexCommandExecutionApprovalRequest: Codable, Equatable, Sendable {
    package var threadID: String
    package var turnID: String
    package var itemID: String
    package var startedAtMs: Int64
    package var approvalID: String?
    package var environmentID: String?
    package var reason: String?
    package var networkApprovalContext: CodexJSONValue?
    package var command: String?
    package var cwd: String?
    package var commandActions: [CodexJSONValue]?
    package var additionalPermissions: CodexJSONValue?
    package var proposedExecpolicyAmendment: CodexExecPolicyAmendment?
    package var proposedNetworkPolicyAmendments: [CodexNetworkPolicyAmendment]?
    package var availableDecisions: [CodexApprovalDecision]?

    private enum CodingKeys: String, CodingKey {
        case threadID = "threadId"
        case turnID = "turnId"
        case itemID = "itemId"
        case startedAtMs
        case approvalID = "approvalId"
        case environmentID = "environmentId"
        case reason
        case networkApprovalContext
        case command
        case cwd
        case commandActions
        case additionalPermissions
        case proposedExecpolicyAmendment
        case proposedNetworkPolicyAmendments
        case availableDecisions
    }
}

package struct CodexFileChangeApprovalRequest: Codable, Equatable, Sendable {
    package var threadID: String
    package var turnID: String
    package var itemID: String
    package var startedAtMs: Int64
    package var reason: String?
    package var grantRoot: String?

    private enum CodingKeys: String, CodingKey {
        case threadID = "threadId"
        case turnID = "turnId"
        case itemID = "itemId"
        case startedAtMs
        case reason
        case grantRoot
    }
}

package struct CodexUserInputOption: Codable, Equatable, Sendable {
    package var label: String
    package var description: String
}

package struct CodexUserInputQuestion: Codable, Equatable, Sendable {
    package var id: String
    package var header: String
    package var question: String
    package var isOther: Bool
    package var isSecret: Bool
    package var options: [CodexUserInputOption]?
}

package struct CodexUserInputRequest: Codable, Equatable, Sendable {
    package var threadID: String
    package var turnID: String
    package var itemID: String
    package var questions: [CodexUserInputQuestion]
    package var autoResolutionMs: UInt64?

    private enum CodingKeys: String, CodingKey {
        case threadID = "threadId"
        case turnID = "turnId"
        case itemID = "itemId"
        case questions
        case autoResolutionMs
    }
}

package struct CodexMCPElicitationRequest: Codable, Equatable, Sendable {
    package var threadID: String
    package var turnID: String?
    package var serverName: String
    package var elicitation: CodexMCPElicitation

    private enum CodingKeys: String, CodingKey {
        case threadID = "threadId"
        case turnID = "turnId"
        case serverName
        case mode
        case meta = "_meta"
        case message
        case requestedSchema
        case url
        case elicitationID = "elicitationId"
    }

    private enum Mode: String, Codable {
        case form
        case openAIForm = "openai/form"
        case url
    }

    package init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.threadID = try container.decode(String.self, forKey: .threadID)
        self.turnID = try container.decodeIfPresent(String.self, forKey: .turnID)
        self.serverName = try container.decode(String.self, forKey: .serverName)
        let meta = try container.decodeIfPresent(CodexJSONValue.self, forKey: .meta)
        let message = try container.decode(String.self, forKey: .message)
        switch try container.decode(Mode.self, forKey: .mode) {
        case .form:
            self.elicitation = .form(
                meta: meta,
                message: message,
                requestedSchema: try container.decode(
                    CodexJSONValue.self,
                    forKey: .requestedSchema
                )
            )
        case .openAIForm:
            self.elicitation = .openAIForm(
                meta: meta,
                message: message,
                requestedSchema: try container.decode(
                    CodexJSONValue.self,
                    forKey: .requestedSchema
                )
            )
        case .url:
            self.elicitation = .url(
                meta: meta,
                message: message,
                url: try container.decode(String.self, forKey: .url),
                elicitationID: try container.decode(String.self, forKey: .elicitationID)
            )
        }
    }

    package func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(threadID, forKey: .threadID)
        try container.encode(turnID, forKey: .turnID)
        try container.encode(serverName, forKey: .serverName)
        switch elicitation {
        case .form(let meta, let message, let requestedSchema):
            try container.encode(Mode.form, forKey: .mode)
            try container.encode(meta, forKey: .meta)
            try container.encode(message, forKey: .message)
            try container.encode(requestedSchema, forKey: .requestedSchema)
        case .openAIForm(let meta, let message, let requestedSchema):
            try container.encode(Mode.openAIForm, forKey: .mode)
            try container.encode(meta, forKey: .meta)
            try container.encode(message, forKey: .message)
            try container.encode(requestedSchema, forKey: .requestedSchema)
        case .url(let meta, let message, let url, let elicitationID):
            try container.encode(Mode.url, forKey: .mode)
            try container.encode(meta, forKey: .meta)
            try container.encode(message, forKey: .message)
            try container.encode(url, forKey: .url)
            try container.encode(elicitationID, forKey: .elicitationID)
        }
    }
}

package enum CodexMCPElicitation: Equatable, Sendable {
    case form(meta: CodexJSONValue?, message: String, requestedSchema: CodexJSONValue)
    case openAIForm(meta: CodexJSONValue?, message: String, requestedSchema: CodexJSONValue)
    case url(meta: CodexJSONValue?, message: String, url: String, elicitationID: String)
}

package struct CodexPermissionsRequest: Codable, Equatable, Sendable {
    package var threadID: String
    package var turnID: String
    package var itemID: String
    package var environmentID: String?
    package var startedAtMs: Int64
    package var cwd: String
    package var reason: String?
    package var permissions: CodexJSONValue

    private enum CodingKeys: String, CodingKey {
        case threadID = "threadId"
        case turnID = "turnId"
        case itemID = "itemId"
        case environmentID = "environmentId"
        case startedAtMs
        case cwd
        case reason
        case permissions
    }
}

package struct CodexDynamicToolCallRequest: Codable, Equatable, Sendable {
    package var threadID: String
    package var turnID: String
    package var callID: String
    package var namespace: String?
    package var tool: String
    package var arguments: CodexJSONValue

    private enum CodingKeys: String, CodingKey {
        case threadID = "threadId"
        case turnID = "turnId"
        case callID = "callId"
        case namespace
        case tool
        case arguments
    }
}

package enum CodexChatGPTAuthTokensRefreshReason: String, Codable, Equatable, Sendable {
    case unauthorized
}

package struct CodexChatGPTAuthTokensRefreshRequest: Codable, Equatable, Sendable {
    package var reason: CodexChatGPTAuthTokensRefreshReason
    package var previousAccountID: String?

    private enum CodingKeys: String, CodingKey {
        case reason
        case previousAccountID = "previousAccountId"
    }
}

package struct CodexAttestationGenerateRequest: Codable, Equatable, Sendable {}

package struct CodexCurrentTimeReadRequest: Codable, Equatable, Sendable {
    package var threadID: String

    private enum CodingKeys: String, CodingKey {
        case threadID = "threadId"
    }
}

package struct CodexRawServerRequest: Equatable, Sendable {
    package var method: String
    package var params: Data
}

package enum CodexAppServerRequestResolution: Equatable, Sendable {
    case approval(CodexApprovalDecision)
    case userInput(CodexUserInputResponse)
    case permissions(CodexPermissionsResponse)
    case dynamicToolCall(CodexDynamicToolCallResponse)
    case mcpElicitation(CodexMCPElicitationResponse)
    case chatGPTAuthTokensRefresh(CodexChatGPTAuthTokensRefreshResponse)
    case attestationGenerate(CodexAttestationGenerateResponse)
    case currentTimeRead(CodexCurrentTimeReadResponse)
    case rejectUnknown(code: Int, message: String)
}

package typealias CodexAppServerRequestHandler =
    @Sendable (CodexAppServerRequest) async throws -> CodexAppServerRequestResolution

package enum CodexApprovalDecision: Codable, Equatable, Sendable {
    case accept
    case acceptForSession
    case acceptWithExecpolicyAmendment(CodexExecPolicyAmendment)
    case applyNetworkPolicyAmendment(CodexNetworkPolicyAmendment)
    case decline
    case cancel

    private enum Scalar: String, Codable {
        case accept
        case acceptForSession
        case decline
        case cancel
    }

    private enum CodingKeys: String, CodingKey {
        case acceptWithExecpolicyAmendment
        case applyNetworkPolicyAmendment
    }

    private enum ExecPolicyCodingKeys: String, CodingKey {
        case amendment = "execpolicy_amendment"
    }

    private enum NetworkPolicyCodingKeys: String, CodingKey {
        case amendment = "network_policy_amendment"
    }

    package init(from decoder: Decoder) throws {
        if let scalar = try? Scalar(from: decoder) {
            self = switch scalar {
            case .accept: .accept
            case .acceptForSession: .acceptForSession
            case .decline: .decline
            case .cancel: .cancel
            }
            return
        }

        let container = try decoder.container(keyedBy: CodingKeys.self)
        if container.contains(.acceptWithExecpolicyAmendment) {
            let nested = try container.nestedContainer(
                keyedBy: ExecPolicyCodingKeys.self,
                forKey: .acceptWithExecpolicyAmendment
            )
            self = .acceptWithExecpolicyAmendment(
                try nested.decode(CodexExecPolicyAmendment.self, forKey: .amendment)
            )
        } else {
            let nested = try container.nestedContainer(
                keyedBy: NetworkPolicyCodingKeys.self,
                forKey: .applyNetworkPolicyAmendment
            )
            self = .applyNetworkPolicyAmendment(
                try nested.decode(CodexNetworkPolicyAmendment.self, forKey: .amendment)
            )
        }
    }

    package func encode(to encoder: Encoder) throws {
        switch self {
        case .accept:
            try Scalar.accept.encode(to: encoder)
        case .acceptForSession:
            try Scalar.acceptForSession.encode(to: encoder)
        case .decline:
            try Scalar.decline.encode(to: encoder)
        case .cancel:
            try Scalar.cancel.encode(to: encoder)
        case .acceptWithExecpolicyAmendment(let amendment):
            var container = encoder.container(keyedBy: CodingKeys.self)
            var nested = container.nestedContainer(
                keyedBy: ExecPolicyCodingKeys.self,
                forKey: .acceptWithExecpolicyAmendment
            )
            try nested.encode(amendment, forKey: .amendment)
        case .applyNetworkPolicyAmendment(let amendment):
            var container = encoder.container(keyedBy: CodingKeys.self)
            var nested = container.nestedContainer(
                keyedBy: NetworkPolicyCodingKeys.self,
                forKey: .applyNetworkPolicyAmendment
            )
            try nested.encode(amendment, forKey: .amendment)
        }
    }

    package var isValidForFileChange: Bool {
        switch self {
        case .accept, .acceptForSession, .decline, .cancel:
            true
        case .acceptWithExecpolicyAmendment, .applyNetworkPolicyAmendment:
            false
        }
    }
}

package struct CodexExecPolicyAmendment: Codable, Equatable, Sendable {
    package var command: [String]

    package init(command: [String]) {
        self.command = command
    }

    package init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        self.command = try container.decode([String].self)
    }

    package func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(command)
    }
}

package enum CodexNetworkPolicyRuleAction: String, Codable, Equatable, Sendable {
    case allow
    case deny
}

package struct CodexNetworkPolicyAmendment: Codable, Equatable, Sendable {
    package var host: String
    package var action: CodexNetworkPolicyRuleAction
}

package struct CodexUserInputAnswer: Codable, Equatable, Sendable {
    package var answers: [String]
}

package struct CodexUserInputResponse: Codable, Equatable, Sendable {
    package var answers: [String: CodexUserInputAnswer]
}

package struct CodexGrantedPermissionProfile: Codable, Equatable, Sendable {
    package var network: CodexJSONValue?
    package var fileSystem: CodexJSONValue?
}

package enum CodexPermissionGrantScope: String, Codable, Equatable, Sendable {
    case turn
    case session
}

package struct CodexPermissionsResponse: Codable, Equatable, Sendable {
    package var permissions: CodexGrantedPermissionProfile
    package var scope: CodexPermissionGrantScope
    package var strictAutoReview: Bool?
}

package enum CodexDynamicToolCallOutputContentItem: Codable, Equatable, Sendable {
    case inputText(text: String)
    case inputImage(imageURL: String)

    private enum CodingKeys: String, CodingKey {
        case type
        case text
        case imageURL = "imageUrl"
    }

    private enum Kind: String, Codable {
        case inputText
        case inputImage
    }

    package init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(Kind.self, forKey: .type) {
        case .inputText:
            self = .inputText(text: try container.decode(String.self, forKey: .text))
        case .inputImage:
            self = .inputImage(imageURL: try container.decode(String.self, forKey: .imageURL))
        }
    }

    package func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .inputText(let text):
            try container.encode(Kind.inputText, forKey: .type)
            try container.encode(text, forKey: .text)
        case .inputImage(let imageURL):
            try container.encode(Kind.inputImage, forKey: .type)
            try container.encode(imageURL, forKey: .imageURL)
        }
    }
}

package struct CodexDynamicToolCallResponse: Codable, Equatable, Sendable {
    package var contentItems: [CodexDynamicToolCallOutputContentItem]
    package var success: Bool
}

package enum CodexMCPElicitationAction: String, Codable, Equatable, Sendable {
    case accept
    case decline
    case cancel
}

package struct CodexMCPElicitationResponse: Codable, Equatable, Sendable {
    package var action: CodexMCPElicitationAction
    package var content: CodexJSONValue?
    package var meta: CodexJSONValue?

    private enum CodingKeys: String, CodingKey {
        case action
        case content
        case meta = "_meta"
    }

    package func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(action, forKey: .action)
        try container.encode(content, forKey: .content)
        try container.encode(meta, forKey: .meta)
    }
}

package struct CodexChatGPTAuthTokensRefreshResponse: Codable, Equatable, Sendable {
    package var accessToken: String
    package var chatGPTAccountID: String
    package var chatGPTPlanType: String?

    private enum CodingKeys: String, CodingKey {
        case accessToken
        case chatGPTAccountID = "chatgptAccountId"
        case chatGPTPlanType = "chatgptPlanType"
    }

    package func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(accessToken, forKey: .accessToken)
        try container.encode(chatGPTAccountID, forKey: .chatGPTAccountID)
        try container.encode(chatGPTPlanType, forKey: .chatGPTPlanType)
    }
}

package struct CodexAttestationGenerateResponse: Codable, Equatable, Sendable {
    package var token: String
}

package struct CodexCurrentTimeReadResponse: Codable, Equatable, Sendable {
    package var currentTimeAt: Int64
}
