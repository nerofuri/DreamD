import Foundation

/// IDM-style HTTP downloader: probes the server, and when byte ranges are
/// supported splits the file into parts downloaded over parallel connections,
/// all written into a preallocated file. Falls back to a single-stream
/// download (with resume data) when ranges are unavailable.
final class SegmentedHTTPDownloader: NSObject, DownloadWorker {
    private let item: DownloadItem
    private let url: URL

    private let delegateQueue: OperationQueue = {
        let q = OperationQueue()
        q.maxConcurrentOperationCount = 1
        q.name = "dreamd.http.delegate"
        return q
    }()

    private lazy var session: URLSession = {
        let cfg = URLSessionConfiguration.default
        cfg.timeoutIntervalForRequest = 30
        cfg.httpMaximumConnectionsPerHost = 16
        cfg.waitsForConnectivity = true
        return URLSession(configuration: cfg, delegate: self, delegateQueue: delegateQueue)
    }()

    private struct Part {
        var offset: Int64
        var length: Int64
        var written: Int64 = 0
        var taskID: Int = -1
        var done: Bool { written >= length }
    }

    private var probeTask: URLSessionDataTask?
    private var parts: [Part] = []
    private var taskToPart: [Int: Int] = [:]
    private var runningTasks: [Int: URLSessionDataTask] = [:]
    private var handle: FileHandle?
    private var totalSize: Int64 = 0
    private var singleTask: URLSessionDownloadTask?
    private var resumeData: Data?
    private var isPaused = false
    private var isCancelled = false
    private var finished = false
    private let meter = SpeedMeter()
    private var uiTimer: DispatchSourceTimer?

    /// Guards the fields the main-queue UI timer reads while the delegate queue
    /// writes them (`parts` itself is only touched on the delegate queue).
    private let stateLock = NSLock()
    private var receivedCounter: Int64 = 0
    private var isSegmented = false

    init(item: DownloadItem, url: URL) {
        self.item = item
        self.url = url
        super.init()
    }

    // MARK: - DownloadWorker

    func start() {
        item.update { $0.state = .fetchingInfo }
        var req = URLRequest(url: url)
        req.setValue("bytes=0-1", forHTTPHeaderField: "Range")
        let task = session.dataTask(with: req)
        probeTask = task
        task.resume()
        startUITimer()
    }

    func pause() {
        delegateQueue.addOperation { [weak self] in
            guard let self, !self.finished else { return }
            self.isPaused = true
            self.probeTask?.cancel()
            self.probeTask = nil
            for task in self.runningTasks.values { task.cancel() }
            self.runningTasks.removeAll()
            if let single = self.singleTask {
                single.cancel { [weak self] data in
                    self?.resumeData = data
                }
                self.singleTask = nil
            }
            self.meter.reset()
            self.item.update { $0.state = .paused; $0.speed = 0 }
        }
    }

    func resume() {
        delegateQueue.addOperation { [weak self] in
            guard let self, !self.finished else { return }
            guard self.isPaused else { return }
            self.isPaused = false
            self.item.update { $0.state = .downloading; $0.errorMessage = nil }
            if !self.parts.isEmpty {
                self.launchPendingParts()
            } else if let data = self.resumeData {
                self.resumeData = nil
                let task = self.session.downloadTask(withResumeData: data)
                self.singleTask = task
                task.resume()
            } else {
                // No resume information; restart from scratch.
                self.isPaused = false
                DispatchQueue.main.async { self.start() }
            }
        }
    }

    func cancel() {
        delegateQueue.addOperation { [weak self] in
            guard let self else { return }
            self.isCancelled = true
            self.probeTask?.cancel()
            for task in self.runningTasks.values { task.cancel() }
            self.runningTasks.removeAll()
            self.singleTask?.cancel()
            self.closeHandle()
            self.stopUITimer()
        }
    }

    // MARK: - Setup after probe

    private func handleProbeResponse(_ response: HTTPURLResponse) {
        guard !isPaused, !isCancelled else { return }
        applyFileName(from: response)
        if response.statusCode == 206,
           let contentRange = response.value(forHTTPHeaderField: "Content-Range"),
           let totalPart = contentRange.split(separator: "/").last,
           let total = Int64(totalPart), total > 0 {
            setupSegmented(total: total)
        } else if response.statusCode >= 200 && response.statusCode < 300 {
            setupSingleStream()
        } else {
            item.fail("Server returned HTTP \(response.statusCode)")
            stopUITimer()
        }
    }

    private func applyFileName(from response: HTTPURLResponse) {
        var name = item.name
        if let disposition = response.value(forHTTPHeaderField: "Content-Disposition") {
            // filename="x.zip" or filename=x.zip
            if let range = disposition.range(of: "filename=", options: .caseInsensitive) {
                var value = String(disposition[range.upperBound...])
                if let semi = value.firstIndex(of: ";") { value = String(value[..<semi]) }
                value = value.trimmingCharacters(in: CharacterSet(charactersIn: "\" "))
                if !value.isEmpty { name = value }
            }
        }
        if (name as NSString).pathExtension.isEmpty,
           let mime = response.mimeType {
            let extMap = ["application/zip": "zip", "application/pdf": "pdf",
                          "video/mp4": "mp4", "audio/mpeg": "mp3",
                          "application/x-bittorrent": "torrent"]
            if let ext = extMap[mime.lowercased()] { name += ".\(ext)" }
        }
        let final = name
        item.update { $0.name = final }
    }

    private func setupSegmented(total: Int64) {
        totalSize = total
        let destination = DownloadManager.shared.uniqueDestination(for: item.name)
        item.destinationURL = destination
        guard prepareFile(at: destination, size: total) else {
            item.fail("Could not create file on disk")
            return
        }

        let minPartSize: Int64 = 512 * 1024
        let maxParts = Int64(AppSettings.maxConnectionsPerDownload)
        let count = max(1, min(maxParts, total / minPartSize))
        let base = total / count
        parts = (0..<count).map { i in
            let offset = Int64(i) * base
            let length = i == count - 1 ? total - offset : base
            return Part(offset: offset, length: length)
        }

        stateLock.lock(); isSegmented = true; stateLock.unlock()
        item.update { $0.state = .downloading; $0.totalBytes = total }
        launchPendingParts()
    }

    private func setupSingleStream() {
        item.update { $0.state = .downloading }
        let task = session.downloadTask(with: url)
        singleTask = task
        task.resume()
    }

    private func prepareFile(at destination: URL, size: Int64) -> Bool {
        FileManager.default.createFile(atPath: destination.path, contents: nil)
        guard let h = try? FileHandle(forWritingTo: destination) else { return false }
        h.truncateFile(toSize: UInt64(size))
        handle = h
        return true
    }

    private func launchPendingParts() {
        for (i, part) in parts.enumerated() where !part.done {
            let from = part.offset + part.written
            let to = part.offset + part.length - 1
            var req = URLRequest(url: url)
            req.setValue("bytes=\(from)-\(to)", forHTTPHeaderField: "Range")
            let task = session.dataTask(with: req)
            parts[i].taskID = task.taskIdentifier
            taskToPart[task.taskIdentifier] = i
            runningTasks[task.taskIdentifier] = task
            task.resume()
        }
    }

    // MARK: - Completion

    private func finishIfDone() {
        guard !finished, !parts.isEmpty, parts.allSatisfy({ $0.done }) else { return }
        finished = true
        closeHandle()
        stopUITimer()
        let total = totalSize
        item.update {
            $0.receivedBytes = total
            $0.state = .completed
            $0.speed = 0
        }
        DownloadManager.shared.persistSoon()
    }

    private func closeHandle() {
        try? handle?.close()
        handle = nil
    }

    // MARK: - UI updates

    private func startUITimer() {
        stopUITimer()
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + 0.5, repeating: 0.5)
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            self.stateLock.lock()
            let received = self.receivedCounter
            let segmented = self.isSegmented
            self.stateLock.unlock()
            let speed = self.meter.speed
            guard self.item.state == .downloading else { return }
            if segmented {
                self.item.receivedBytes = received
                self.item.detail = ""
            }
            self.item.speed = speed
        }
        timer.resume()
        uiTimer = timer
    }

    private func stopUITimer() {
        uiTimer?.cancel()
        uiTimer = nil
    }
}

// MARK: - URLSession delegates

extension SegmentedHTTPDownloader: URLSessionDataDelegate, URLSessionDownloadDelegate {
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask,
                    didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        guard let http = response as? HTTPURLResponse else {
            completionHandler(.cancel)
            item.fail("Invalid server response")
            return
        }
        if dataTask == probeTask {
            completionHandler(.cancel)
            probeTask = nil
            guard !isCancelled else { return }
            handleProbeResponse(http)
            return
        }
        if http.statusCode == 206 || (http.statusCode == 200 && parts.count <= 1) {
            completionHandler(.allow)
        } else if http.statusCode == 200 {
            // The server ignored our byte range on a multi-part connection and
            // is sending the whole file; the other parts would corrupt it.
            completionHandler(.cancel)
            if !finished, !isPaused, !isCancelled {
                for other in runningTasks.values { other.cancel() }
                runningTasks.removeAll()
                stopUITimer()
                item.fail("This server doesn't support multi-part downloads. Set Connections per download to 1 in Settings and retry.")
            }
        } else {
            completionHandler(.cancel)
            item.fail("Server returned HTTP \(http.statusCode) for a file part")
        }
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        guard let index = taskToPart[dataTask.taskIdentifier], let handle else { return }
        let part = parts[index]
        // Never write past this part's boundary, in case a server ignored the
        // range and started streaming the whole file into a part connection.
        let room = part.length - part.written
        guard room > 0 else { return }
        let slice = Int64(data.count) <= room ? data : data.prefix(Int(room))
        let writeOffset = part.offset + part.written
        handle.seek(toFileOffset: UInt64(writeOffset))
        handle.write(slice)
        let n = Int64(slice.count)
        parts[index].written += n
        stateLock.lock(); receivedCounter += n; stateLock.unlock()
        meter.add(n)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        runningTasks.removeValue(forKey: task.taskIdentifier)
        if let error = error as NSError? {
            if error.code == NSURLErrorCancelled { return }
            if isPaused || isCancelled || finished { return }
            item.fail(error.localizedDescription)
            for other in runningTasks.values { other.cancel() }
            runningTasks.removeAll()
            stopUITimer()
            return
        }
        if taskToPart[task.taskIdentifier] != nil {
            finishIfDone()
        }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didWriteData bytesWritten: Int64, totalBytesWritten: Int64,
                    totalBytesExpectedToWrite: Int64) {
        meter.add(bytesWritten)
        let speed = meter.speed
        item.update {
            $0.receivedBytes = totalBytesWritten
            if totalBytesExpectedToWrite > 0 { $0.totalBytes = totalBytesExpectedToWrite }
            $0.speed = speed
        }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didFinishDownloadingTo location: URL) {
        let destination = item.destinationURL ?? DownloadManager.shared.uniqueDestination(for: item.name)
        item.destinationURL = destination
        do {
            if FileManager.default.fileExists(atPath: destination.path) {
                try FileManager.default.removeItem(at: destination)
            }
            try FileManager.default.moveItem(at: location, to: destination)
            finished = true
            stopUITimer()
            item.update { $0.state = .completed; $0.speed = 0 }
            DownloadManager.shared.persistSoon()
        } catch {
            item.fail("Could not save file: \(error.localizedDescription)")
        }
    }
}
