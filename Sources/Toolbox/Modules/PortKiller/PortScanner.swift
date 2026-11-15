import Darwin
import Foundation

struct RawSocketRecord: Equatable, Sendable {
    enum Source: String, Sendable {
        case lsof
        case netstat
    }

    let pid: pid_t
    let command: String
    let uid: uid_t?
    let address: String
    let port: Int
    let isIPv6: Bool
    let source: Source
}

struct ProcessMetadata: Sendable {
    let command: String?
    let uid: uid_t?
    let executablePath: String?
    let workingDirectory: String?
}

struct ListeningPort: Identifiable, Hashable, Sendable {
    var id: String { "\(pid):\(port)" }

    let pid: pid_t
    let port: Int
    let processName: String
    let uid: uid_t?
    let addresses: [String]
    let executablePath: String?
    let workingDirectory: String?
    let isSystemDaemon: Bool
    let requiresElevation: Bool
    let seenInLsof: Bool

    var cwdBasename: String? {
        guard let cwd = workingDirectory, !cwd.isEmpty else { return nil }
        let name = URL(fileURLWithPath: cwd).lastPathComponent
        return name.isEmpty ? cwd : name
    }

    var executableBasename: String? {
        guard let path = executablePath, !path.isEmpty else { return nil }
        return URL(fileURLWithPath: path).lastPathComponent
    }

    var ownerLabel: String? {
        guard let uid else { return requiresElevation ? "elevated" : nil }
        if uid == 0 { return "root" }
        if uid != getuid() { return "uid \(uid)" }
        return nil
    }

    var bindDisplay: String {
        if addresses.isEmpty { return "*" }
        let hasLoopbackV4 = addresses.contains("127.0.0.1")
        let hasLoopbackV6 = addresses.contains("[::1]")
        let hasWildcard = addresses.contains("*") || addresses.contains("[::]") || addresses.contains("0.0.0.0")

        if hasLoopbackV4 && hasLoopbackV6 && addresses.count == 2 {
            return "localhost (IPv4 + IPv6)"
        }
        if hasWildcard && addresses.count > 1 {
            return "* (IPv4 + IPv6)"
        }
        if addresses.count == 1, let only = addresses.first {
            if only == "127.0.0.1" || only == "[::1]" {
                return "\(only) (localhost)"
            }
            return only
        }
        return addresses.joined(separator: ", ")
    }
}

enum PortScanner {
    static let commonDevPorts: Set<Int> = [
        3000, 3001, 3002, 3306, 4000, 4200, 4321,
        5000, 5001, 5173, 5174, 5432, 5500, 6379,
        8000, 8001, 8080, 8081, 8443, 8888, 9000, 9090, 9229, 27017
    ]

    private static let knownSystemDaemonNames: Set<String> = [
        "rapportd",
        "ControlCenter",
        "sharingd",
        "AirPlayXPCHelper",
        "mDNSResponder",
        "launchd",
        "UserEventAgent",
        "identityservicesd",
        "bluetoothd",
        "airportd",
        "symptomsd",
        "locationd",
        "remoted",
        "usbmuxd",
        "apsd",
        "ARDAgent",
        "ScreensharingAgent"
    ]

    // MARK: - Live System Scan

    static func scanListeningPorts() async -> [ListeningPort] {
        await Task.detached(priority: .userInitiated) {
            scanListeningPortsSync()
        }.value
    }

    static func scanListeningPortsSync() -> [ListeningPort] {
        let lsofOut = runCommand("/usr/sbin/lsof", arguments: ["-iTCP", "-sTCP:LISTEN", "-P", "-n", "-F", "pcnTu"])
        let netstatOut = runCommand("/usr/sbin/netstat", arguments: ["-anv", "-p", "tcp"])

        let lsofRecords = parseLsofOutput(lsofOut)
        let netstatRecords = parseNetstatOutput(netstatOut)
        let currentUID = getuid()

        var cache: [pid_t: ProcessMetadata] = [:]
        return mergeAndDeduplicate(
            lsofRecords: lsofRecords,
            netstatRecords: netstatRecords,
            currentUID: currentUID
        ) { pid in
            if let cached = cache[pid] {
                return cached
            }
            let meta = inspectProcess(pid: pid)
            cache[pid] = meta
            return meta
        }
    }

    // MARK: - Parsers (Pure & Testable)

    static func parseLsofOutput(_ output: String) -> [RawSocketRecord] {
        var records: [RawSocketRecord] = []
        var currentPID: pid_t?
        var currentCommand = ""
        var currentUID: uid_t?

        for rawLine in output.split(whereSeparator: \.isNewline) {
            let line = String(rawLine)
            guard let tag = line.first else { continue }
            let value = String(line.dropFirst())

            switch tag {
            case "p":
                currentPID = pid_t(value)
                currentCommand = ""
                currentUID = nil
            case "c":
                currentCommand = value
            case "u":
                currentUID = uid_t(value)
            case "n":
                guard let pid = currentPID,
                      let parsed = splitLsofAddressAndPort(value) else {
                    continue
                }
                records.append(RawSocketRecord(
                    pid: pid,
                    command: currentCommand,
                    uid: currentUID,
                    address: parsed.address,
                    port: parsed.port,
                    isIPv6: parsed.isIPv6,
                    source: .lsof
                ))
            default:
                continue
            }
        }
        return records
    }

    static func parseNetstatOutput(_ output: String) -> [RawSocketRecord] {
        var records: [RawSocketRecord] = []

        for rawLine in output.split(whereSeparator: \.isNewline) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard line.hasPrefix("tcp") else { continue }

            // Columns: Proto Recv-Q Send-Q LocalAddress ForeignAddress (state) rxbytes txbytes rhiwat shiwat process:pid ...
            let tokens = splitWhitespaceTokens(line)
            guard tokens.count >= 11 else { continue }
            let proto = tokens[0].text
            let localAddrToken = tokens[3].text
            let stateToken = tokens[5].text
            guard stateToken == "LISTEN" else { continue }

            guard let parsedAddr = splitNetstatAddressAndPort(localAddrToken, proto: proto) else {
                continue
            }

            // `process:pid` starts right after token 9 (`shiwat`). Process names may contain spaces
            // (e.g. "Antigravity Help:1616"), so scan from the start of token 10 to the first `:<digits>`
            // followed by whitespace or end-of-line.
            let afterShiwatStart = tokens[9].range.upperBound
            let remainder = String(line[afterShiwatStart...]).trimmingCharacters(in: .whitespaces)
            guard let procAndPID = parseProcessColonPID(remainder) else {
                continue
            }

            records.append(RawSocketRecord(
                pid: procAndPID.pid,
                command: procAndPID.process,
                uid: nil,
                address: parsedAddr.address,
                port: parsedAddr.port,
                isIPv6: parsedAddr.isIPv6,
                source: .netstat
            ))
        }

        return records
    }

    static func mergeAndDeduplicate(
        lsofRecords: [RawSocketRecord],
        netstatRecords: [RawSocketRecord],
        currentUID: uid_t,
        enrichProcess: (pid_t) -> ProcessMetadata
    ) -> [ListeningPort] {
        struct Key: Hashable {
            let pid: pid_t
            let port: Int
        }

        struct Accumulator {
            let pid: pid_t
            let port: Int
            var command: String
            var uid: uid_t?
            var addresses: [String] = []
            var seenInLsof: Bool = false
        }

        var map: [Key: Accumulator] = [:]

        // 1. Seed with lsof (has untruncated command & exact UID for user processes)
        for rec in lsofRecords {
            let key = Key(pid: rec.pid, port: rec.port)
            if var existing = map[key] {
                if !existing.addresses.contains(rec.address) {
                    existing.addresses.append(rec.address)
                }
                if existing.command.isEmpty && !rec.command.isEmpty {
                    existing.command = rec.command
                }
                if existing.uid == nil {
                    existing.uid = rec.uid
                }
                existing.seenInLsof = true
                map[key] = existing
            } else {
                map[key] = Accumulator(
                    pid: rec.pid,
                    port: rec.port,
                    command: rec.command,
                    uid: rec.uid,
                    addresses: [rec.address],
                    seenInLsof: true
                )
            }
        }

        // 2. Merge netstat (surfaces root / other-user / sudo-only listeners missed by lsof)
        for rec in netstatRecords {
            let key = Key(pid: rec.pid, port: rec.port)
            if var existing = map[key] {
                if !existing.addresses.contains(rec.address) {
                    existing.addresses.append(rec.address)
                }
                if existing.command.isEmpty && !rec.command.isEmpty {
                    existing.command = rec.command
                }
                map[key] = existing
            } else {
                map[key] = Accumulator(
                    pid: rec.pid,
                    port: rec.port,
                    command: rec.command,
                    uid: rec.uid,
                    addresses: [rec.address],
                    seenInLsof: false
                )
            }
        }

        // 3. Enrich per-PID metadata and classify system vs elevated
        var results: [ListeningPort] = []
        results.reserveCapacity(map.count)

        for acc in map.values {
            let meta = enrichProcess(acc.pid)
            let resolvedUID = acc.uid ?? meta.uid
            let resolvedName: String = {
                let lsofOrMeta = acc.seenInLsof ? acc.command : (meta.command ?? acc.command)
                if !lsofOrMeta.isEmpty {
                    return lsofOrMeta
                }
                if let execPath = meta.executablePath, !execPath.isEmpty {
                    return URL(fileURLWithPath: execPath).lastPathComponent
                }
                return acc.command.isEmpty ? "pid \(acc.pid)" : acc.command
            }()

            let requiresElevation: Bool = {
                if let uid = resolvedUID {
                    return uid != currentUID
                }
                return !acc.seenInLsof
            }()

            let isSystem = classifySystemDaemon(
                processName: resolvedName,
                executablePath: meta.executablePath,
                uid: resolvedUID,
                currentUID: currentUID
            )

            results.append(ListeningPort(
                pid: acc.pid,
                port: acc.port,
                processName: resolvedName,
                uid: resolvedUID,
                addresses: acc.addresses,
                executablePath: meta.executablePath,
                workingDirectory: meta.workingDirectory,
                isSystemDaemon: isSystem,
                requiresElevation: requiresElevation,
                seenInLsof: acc.seenInLsof
            ))
        }

        return results.sorted { lhs, rhs in
            if lhs.port != rhs.port { return lhs.port < rhs.port }
            return lhs.pid < rhs.pid
        }
    }

    // MARK: - Helpers

    private static func classifySystemDaemon(
        processName: String,
        executablePath: String?,
        uid: uid_t?,
        currentUID: uid_t
    ) -> Bool {
        if knownSystemDaemonNames.contains(processName) {
            return true
        }
        if let path = executablePath {
            if path.hasPrefix("/System/Library/") || path.hasPrefix("/usr/libexec/") {
                return true
            }
        }
        // Only hide other-user processes automatically if they look like macOS system services,
        // NOT developer servers like nginx, httpd, postgres, docker, caddy, etc.
        if let uid, uid != currentUID, uid < 500 {
            let devServerPrefixes = ["nginx", "httpd", "postgres", "redis", "docker", "containerd", "caddy", "node", "python", "ruby", "java", "go", "mysqld", "mongod"]
            let lower = processName.lowercased()
            if !devServerPrefixes.contains(where: { lower.hasPrefix($0) }) && executablePath?.hasPrefix("/System/") == true {
                return true
            }
        }
        return false
    }

    private static func splitLsofAddressAndPort(_ raw: String) -> (address: String, port: Int, isIPv6: Bool)? {
        guard let colonIdx = raw.lastIndex(of: ":") else { return nil }
        let portStr = String(raw[raw.index(after: colonIdx)...])
        guard let port = Int(portStr), port > 0 && port <= 65535 else { return nil }
        let host = String(raw[..<colonIdx])
        let isIPv6 = host.contains("[") || host.contains(":")
        return (host.isEmpty ? "*" : host, port, isIPv6)
    }

    private static func splitNetstatAddressAndPort(_ raw: String, proto: String) -> (address: String, port: Int, isIPv6: Bool)? {
        guard let dotIdx = raw.lastIndex(of: ".") else { return nil }
        let portStr = String(raw[raw.index(after: dotIdx)...])
        guard let port = Int(portStr), port > 0 && port <= 65535 else { return nil }
        let rawHost = String(raw[..<dotIdx])
        let isIPv6 = proto.contains("6") || rawHost.contains(":")

        let normalizedHost: String
        if rawHost == "*" || rawHost.isEmpty {
            normalizedHost = "*"
        } else if isIPv6 && !rawHost.hasPrefix("[") {
            normalizedHost = "[\(rawHost)]"
        } else {
            normalizedHost = rawHost
        }

        return (normalizedHost, port, isIPv6)
    }

    private struct TokenSpan {
        let text: String
        let range: Range<String.Index>
    }

    private static func splitWhitespaceTokens(_ line: String) -> [TokenSpan] {
        var result: [TokenSpan] = []
        var idx = line.startIndex
        while idx < line.endIndex {
            while idx < line.endIndex && line[idx].isWhitespace {
                idx = line.index(after: idx)
            }
            guard idx < line.endIndex else { break }
            let start = idx
            while idx < line.endIndex && !line[idx].isWhitespace {
                idx = line.index(after: idx)
            }
            result.append(TokenSpan(text: String(line[start..<idx]), range: start..<idx))
        }
        return result
    }

    private static func parseProcessColonPID(_ remainder: String) -> (process: String, pid: pid_t)? {
        // Format: `<processName>:<pid>   <hexFlags> ...`
        // Find the first `:` followed immediately by digits and then whitespace/EOL.
        var searchStart = remainder.startIndex
        while let colonIdx = remainder[searchStart...].firstIndex(of: ":") {
            let digitsStart = remainder.index(after: colonIdx)
            var digitsEnd = digitsStart
            while digitsEnd < remainder.endIndex && remainder[digitsEnd].isNumber {
                digitsEnd = remainder.index(after: digitsEnd)
            }
            let hasDigits = digitsEnd > digitsStart
            let followedByBoundary = digitsEnd == remainder.endIndex || remainder[digitsEnd].isWhitespace
            if hasDigits && followedByBoundary,
               let pid = pid_t(remainder[digitsStart..<digitsEnd]) {
                let procName = String(remainder[..<colonIdx]).trimmingCharacters(in: .whitespaces)
                return (procName, pid)
            }
            searchStart = digitsStart
        }
        return nil
    }

    // MARK: - Subprocess & libproc

    private static func inspectProcess(pid: pid_t) -> ProcessMetadata {
        var bsdInfo = proc_bsdinfo()
        let bsdSize = Int32(MemoryLayout<proc_bsdinfo>.size)
        let bsdRet = proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &bsdInfo, bsdSize)

        var uid: uid_t?
        var command: String?
        if bsdRet == bsdSize {
            uid = bsdInfo.pbi_uid
            let name = withUnsafePointer(to: bsdInfo.pbi_name) { ptr in
                ptr.withMemoryRebound(to: CChar.self, capacity: Int(MAXCOMLEN) * 2) {
                    String(cString: $0)
                }
            }
            if !name.isEmpty {
                command = name
            } else {
                let comm = withUnsafePointer(to: bsdInfo.pbi_comm) { ptr in
                    ptr.withMemoryRebound(to: CChar.self, capacity: Int(MAXCOMLEN)) {
                        String(cString: $0)
                    }
                }
                if !comm.isEmpty { command = comm }
            }
        }

        var pathBuffer = [CChar](repeating: 0, count: Int(MAXPATHLEN) * 4)
        let pathLen = proc_pidpath(pid, &pathBuffer, UInt32(pathBuffer.count))
        let executablePath: String? = pathLen > 0 ? decodeCStringBuffer(pathBuffer) : nil

        var vnodeInfo = proc_vnodepathinfo()
        let vnodeSize = Int32(MemoryLayout<proc_vnodepathinfo>.size)
        let vnodeRet = proc_pidinfo(pid, PROC_PIDVNODEPATHINFO, 0, &vnodeInfo, vnodeSize)
        var workingDirectory: String?
        if vnodeRet == vnodeSize {
            let cwd = withUnsafePointer(to: vnodeInfo.pvi_cdir.vip_path) { ptr in
                ptr.withMemoryRebound(to: CChar.self, capacity: Int(MAXPATHLEN)) {
                    String(cString: $0)
                }
            }
            if !cwd.isEmpty {
                workingDirectory = cwd
            }
        }

        return ProcessMetadata(
            command: command,
            uid: uid,
            executablePath: executablePath,
            workingDirectory: workingDirectory
        )
    }

    private static func decodeCStringBuffer(_ buffer: [CChar]) -> String {
        let bytes = buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }
        return String(decoding: bytes, as: UTF8.self)
    }

    private static func runCommand(_ executable: String, arguments: [String]) -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        do {
            try process.run()
        } catch {
            return ""
        }

        let data = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(data: data, encoding: .utf8) ?? ""
    }
}
