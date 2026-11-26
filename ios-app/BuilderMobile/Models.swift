import Foundation

struct GitHubUser: Decodable {
    let login: String
    let name: String?
    let avatarURL: URL?

    enum CodingKeys: String, CodingKey {
        case login, name
        case avatarURL = "avatar_url"
    }
}

struct GitHubRepository: Decodable, Identifiable, Hashable {
    let id: Int
    let name: String
    let fullName: String
    let isPrivate: Bool
    let defaultBranch: String
    let description: String?
    let updatedAt: Date?

    enum CodingKeys: String, CodingKey {
        case id, name, description
        case fullName = "full_name"
        case isPrivate = "private"
        case defaultBranch = "default_branch"
        case updatedAt = "updated_at"
    }
}

struct WorkflowRunsEnvelope: Decodable {
    let workflowRuns: [WorkflowRun]

    enum CodingKeys: String, CodingKey {
        case workflowRuns = "workflow_runs"
    }
}

struct WorkflowRun: Decodable, Identifiable, Hashable {
    let id: Int64
    let name: String?
    let status: String
    let conclusion: String?
    let htmlURL: URL?
    let runNumber: Int
    let createdAt: Date?
    let headBranch: String?
    let event: String?
    let updatedAt: Date?
    let displayTitle: String?

    enum CodingKeys: String, CodingKey {
        case id, name, status, conclusion, event
        case htmlURL = "html_url"
        case runNumber = "run_number"
        case createdAt = "created_at"
        case headBranch = "head_branch"
        case updatedAt = "updated_at"
        case displayTitle = "display_title"
    }

    var isFinished: Bool { status == "completed" }
    var isSuccess: Bool { status == "completed" && conclusion == "success" }
    var isFailure: Bool {
        status == "completed" && ["failure", "timed_out", "startup_failure", "cancelled"].contains(conclusion ?? "")
    }
    var title: String { displayTitle ?? name ?? "Build #\(runNumber)" }

    var displayStatus: String {
        if status == "completed" {
            return conclusion ?? "completed"
        }
        return status
    }
}

struct ArtifactsEnvelope: Decodable {
    let artifacts: [BuildArtifact]
}

struct BuildArtifact: Decodable, Identifiable, Hashable {
    let id: Int64
    let name: String
    let expired: Bool
    let sizeInBytes: Int64

    enum CodingKeys: String, CodingKey {
        case id, name, expired
        case sizeInBytes = "size_in_bytes"
    }
}

// MARK: - Repository Files

struct GitHubContentItem: Decodable, Identifiable, Hashable {
    let name: String
    let path: String
    let sha: String
    let size: Int?
    let type: String

    var id: String {
        path
    }

    var isDirectory: Bool {
        type == "dir"
    }
}

struct GitHubFileContent: Decodable {
    let name: String
    let path: String
    let sha: String
    let size: Int?
    let content: String?
    let encoding: String?

    var decodedText: String? {
        guard let content, encoding == "base64" else {
            return nil
        }

        let cleaned = content
            .components(separatedBy: .whitespacesAndNewlines)
            .joined()

        guard let data = Data(
            base64Encoded: cleaned,
            options: .ignoreUnknownCharacters
        ) else {
            return nil
        }

        return String(data: data, encoding: .utf8)
    }
}

struct GitHubAPIError: LocalizedError {
    let statusCode: Int
    let message: String

    var errorDescription: String? {
        "GitHub (\(statusCode)): \(message)"
    }
}

// MARK: - Jobs, logs, trees, secrets

struct WorkflowJobsEnvelope: Decodable {
    let jobs: [WorkflowJob]
}

struct WorkflowJob: Decodable, Identifiable, Hashable {
    let id: Int64
    let name: String
    let status: String
    let conclusion: String?
    let steps: [WorkflowStep]?
}

struct WorkflowStep: Decodable, Hashable {
    let name: String
    let status: String
    let conclusion: String?
    let number: Int
}

struct GitTreeResponse: Decodable {
    let tree: [GitTreeEntry]
    let truncated: Bool?
}

struct GitTreeEntry: Decodable, Hashable {
    let path: String
    let type: String
    let sha: String
    let size: Int?
}

struct ActionsPublicKey: Decodable {
    let keyID: String
    let key: String

    enum CodingKeys: String, CodingKey {
        case keyID = "key_id"
        case key
    }
}

// MARK: - Project categories

enum ProjectCategory: String, CaseIterable, Identifiable, Codable {
    case app, source, website

    var id: String { rawValue }

    var title: String {
        switch self {
        case .app: return "تطبيقات"
        case .source: return "سورسات"
        case .website: return "مواقع"
        }
    }

    var singular: String {
        switch self {
        case .app: return "تطبيق"
        case .source: return "سورس"
        case .website: return "موقع"
        }
    }

    var icon: String {
        switch self {
        case .app: return "iphone.gen3"
        case .source: return "chevron.left.forwardslash.chevron.right"
        case .website: return "globe"
        }
    }
}

/// A file or folder that can be downloaded or deleted from a repository.
struct RepoItemRef: Hashable {
    let path: String
    let isDirectory: Bool
    var name: String { (path as NSString).lastPathComponent }
}
