/// Represents the bulk index request.
class BulkIndex {
    let documents: [(source: String, type: String)]

    init(documents: [(source: String, type: String)]) {
        self.documents = documents
    }

    func toBody(index: String) -> String {
        var body = ""
        for document in documents {
            body += "{ \"index\" : { \"_index\": \"\(index)\", \"_type\" : \"\(document.type)\" } }\n"
            body += document.source.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines) + "\n"
        }
        return body
    }
}

/// Basic promise implementation.
class Promise<T> {
    private var successCb: ((T) -> ())?
    private var failureCb: ((Error?, HTTPURLResponse?, Data?) -> ())?
    private var alwaysCb: (() -> ())?
    private let semaphore = DispatchSemaphore(value: 0)
    private let semaphoreTimeout: TimeInterval?

    init() {
        self.semaphoreTimeout = nil
    }

    init(semaphoreTimeout: TimeInterval) {
        self.semaphoreTimeout = semaphoreTimeout
    }

    func finish(_ obj: T) {
        successCb?(obj)
        alwaysCb?()
        semaphore.signal()
    }

    func raiseError(_ error: Error?, response: HTTPURLResponse? = nil, data: Data? = nil) {
        failureCb?(error, response, data)
        alwaysCb?()
        semaphore.signal()
    }

    func success(successCb: @escaping (T) -> ()) -> Promise<T> {
        self.successCb = successCb;
        return self
    }

    func failure(failureCb: @escaping (Error?, HTTPURLResponse?, Data?) -> ()) -> Promise<T> {
        self.failureCb = failureCb
        return self
    }

    func always(alwaysCb: @escaping () -> ()) -> Promise<T> {
        self.alwaysCb = alwaysCb
        return self
    }

    /// Waits until either the promise is finished, or an error is raised.
    func wait() {
        if let timeout = semaphoreTimeout {
            _ = semaphore.wait(timeout: .now() + timeout)
        } else {
            _ = semaphore.wait(timeout: .distantFuture)
        }
    }
}


/// The base client for interacting with the Logsene api.
class LogseneClient {
    let receiverUrl: String
    let appToken: String
    let session: URLSession
    let configuration: URLSessionConfiguration

    /**
        Initializes the client.

        - Parameters:
            - receiverUrl: The url of the logsene receiver.
            - appToken: Your logsene app token.
    */
    init(receiverUrl: String, appToken: String, configuration: URLSessionConfiguration) {
        self.receiverUrl = LogseneClient.cleanReceiverUrl(receiverUrl)
        self.appToken = appToken
        self.configuration = configuration
        self.session = URLSession(configuration: configuration)
    }

    /**
        Executes a bulk index request.

        - Parameters:
            - bulkIndex: The bulk index request.
    */
    func execute(_ bulkIndex: BulkIndex) -> Promise<JsonObject> {
        var request = prepareRequest(method: "POST")
        request.httpBody = bulkIndex.toBody(index: appToken).data(using: .utf8)
        return execute(request)
    }

    private func execute(_ request: URLRequest) -> Promise<JsonObject> {
        let promise = Promise<JsonObject>(semaphoreTimeout: self.configuration.timeoutIntervalForResource)
      let task = URLSession.shared.dataTask(with: request) { (maybeData, maybeResponse, maybeError) in
            if let error = maybeError {
                promise.raiseError(error, response: maybeResponse as? HTTPURLResponse)
                return
            }

            if let response = maybeResponse as? HTTPURLResponse {
                // if status code not in success range (200-299), fail the promise
                if response.statusCode < 200 || response.statusCode > 299  {
                    promise.raiseError(maybeError, response: response, data: maybeData)
                    return
                }
            }

            if let data = maybeData {
                if let jsonObject = (try? JSONSerialization.jsonObject(with: data, options: [])) as? JsonObject {
                    promise.finish(jsonObject)
                } else {
                    NSLog("Couldn't deserialize json response, returning empty json object instead")
                    return promise.finish([:])
                }
            }
        }
        task.resume()
        return promise
    }

    private func prepareRequest(method: String) -> URLRequest {
        var request = URLRequest(url: URL(string: "\(receiverUrl)/_bulk")!)
        request.httpMethod = method
        request.setValue("application/json; charset=utf-8", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        return request
    }

    private class func cleanReceiverUrl(_ url: String) -> String {
        let cleaned = url.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines)
        if cleaned.hasSuffix("/") {
            return String(cleaned[cleaned.startIndex..<cleaned.endIndex])
        } else {
            return cleaned
        }
    }
}
