import Foundation

enum RemoteQuotaError: LocalizedError {
    case loginRequired(String)
    case requestFailed
    case httpStatus(Int)
    case invalidResponse

    var errorDescription: String? {
        switch self {
        case .loginRequired(let command):
            return "登录已失效：在终端运行一次 \(command) 并登录后恢复"
        case .requestFailed:
            return "无法连接额度接口"
        case .httpStatus(let status):
            return "额度接口请求失败（HTTP \(status)）"
        case .invalidResponse:
            return "无法解析额度接口响应"
        }
    }
}

enum QuotaKeychain {
    static func read(_ arguments: [String], command: String) throws -> Data {
        let process = Process()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        process.arguments = ["find-generic-password"] + arguments + ["-w"]
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
        } catch {
            throw RemoteQuotaError.loginRequired(command)
        }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0, !data.isEmpty else {
            throw RemoteQuotaError.loginRequired(command)
        }
        return data
    }
}

enum RemoteQuotaRequest {
    private static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.urlCredentialStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.timeoutIntervalForRequest = 15
        configuration.timeoutIntervalForResource = 30
        return URLSession(configuration: configuration, delegate: RejectRedirects(), delegateQueue: nil)
    }()

    static func send(_ request: URLRequest, command: String) async throws -> Data {
        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw RemoteQuotaError.requestFailed
        }
        guard let response = response as? HTTPURLResponse else {
            throw RemoteQuotaError.invalidResponse
        }
        switch response.statusCode {
        case 200..<300:
            return data
        case 401:
            throw RemoteQuotaError.loginRequired(command)
        default:
            throw RemoteQuotaError.httpStatus(response.statusCode)
        }
    }

    static func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let value = try decoder.singleValueContainer().decode(String.self)
            if let date = try? Date.ISO8601FormatStyle(includingFractionalSeconds: true).parse(value) {
                return date
            }
            return try Date.ISO8601FormatStyle().parse(value)
        }
        do {
            return try decoder.decode(type, from: data)
        } catch {
            throw RemoteQuotaError.invalidResponse
        }
    }

    private final class RejectRedirects: NSObject, URLSessionTaskDelegate {
        func urlSession(
            _ session: URLSession,
            task: URLSessionTask,
            willPerformHTTPRedirection response: HTTPURLResponse,
            newRequest request: URLRequest,
            completionHandler: @escaping (URLRequest?) -> Void
        ) {
            completionHandler(nil)
        }
    }
}
