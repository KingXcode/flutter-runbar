import Foundation
import dnssd

/// Reads only services registered on this Mac, not services on the LAN. DNS-SD
/// supplies the authentication path; loopback + getVM/PID validation is still
/// mandatory. Addresses and TXT data are never logged or persisted here.
final class LocalDartVMServices: @unchecked Sendable {
    private let queue = DispatchQueue(label: "runbar.local-vm-discovery")
    private let ports: Set<Int>
    private var browser: DNSServiceRef?
    private var resolvers: [DNSServiceRef] = []
    private var names = Set<String>()
    private var results: [VMServiceEndpoint] = []
    private var continuation: CheckedContinuation<[VMServiceEndpoint], Never>?
    private var cancelled = false

    private init(ports: [Int]) { self.ports = Set(ports.prefix(8)) }

    static func endpoints(ports: [Int]) async -> [VMServiceEndpoint] {
        await LocalDartVMServices(ports: ports).find()
    }

    private func find() async -> [VMServiceEndpoint] {
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                queue.async {
                    guard !self.cancelled else { continuation.resume(returning: []); return }
                    self.continuation = continuation
                    let context = Unmanaged.passUnretained(self).toOpaque()
                    let error = DNSServiceBrowse(&self.browser, 0, kDNSServiceInterfaceIndexLocalOnly,
                                                 "_dartVmService._tcp", "local.", Self.browseReply, context)
                    guard error == 0, let browser = self.browser else { self.finish(); return }
                    guard DNSServiceSetDispatchQueue(browser, self.queue) == 0 else { self.finish(); return }
                    self.queue.asyncAfter(deadline: .now() + .seconds(3)) { [weak self] in self?.finish() }
                }
            }
        } onCancel: {
            self.queue.async { self.cancelled = true; self.finish() }
        }
    }

    private static let browseReply: DNSServiceBrowseReply = { _, flags, _, error, name, type, domain, context in
        guard error == 0, flags & DNSServiceFlags(kDNSServiceFlagsAdd) != 0,
              let name, let type, let domain, let context else { return }
        let owner = Unmanaged<LocalDartVMServices>.fromOpaque(context).takeUnretainedValue()
        guard owner.continuation != nil, owner.names.count < 32 else { return }
        let identity = String(cString: name) + "." + String(cString: domain)
        guard owner.names.insert(identity).inserted else { return }
        var resolver: DNSServiceRef?
        let result = DNSServiceResolve(&resolver, 0, kDNSServiceInterfaceIndexLocalOnly,
                                       name, type, domain, LocalDartVMServices.resolveReply, context)
        guard result == 0, let resolver else { return }
        if DNSServiceSetDispatchQueue(resolver, owner.queue) == 0 { owner.resolvers.append(resolver) }
        else { DNSServiceRefDeallocate(resolver) }
    }

    private static let resolveReply: DNSServiceResolveReply = { _, _, _, error, _, _, networkPort, length, txt, context in
        guard error == 0, length <= 4096, let context else { return }
        let owner = Unmanaged<LocalDartVMServices>.fromOpaque(context).takeUnretainedValue()
        guard owner.continuation != nil else { return }
        let port = Int(UInt16(bigEndian: networkPort))
        guard (1...65535).contains(port), owner.ports.isEmpty || owner.ports.contains(port) else { return }
        var auth = ""
        if length > 0, let txt {
            var size: UInt8 = 0
            if let bytes = TXTRecordGetValuePtr(length, txt, "authCode", &size) {
                guard let decoded = String(data: Data(bytes: bytes, count: Int(size)), encoding: .utf8) else { return }
                auth = decoded.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
                let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_=+")
                guard auth.unicodeScalars.allSatisfy({ allowed.contains($0) }) else { return }
            }
        }
        for host in ["127.0.0.1", "[::1]"] {
            guard let endpoint = VMServiceEndpoint("http://\(host):\(port)/\(auth)\(auth.isEmpty ? "" : "/")"),
                  !owner.results.contains(endpoint), owner.results.count < 16 else { continue }
            owner.results.append(endpoint)
        }
    }

    // DNSServiceRefDeallocate must run on the dispatch queue assigned above.
    private func finish() {
        guard let continuation else { return }
        self.continuation = nil
        if let browser { DNSServiceRefDeallocate(browser); self.browser = nil }
        for resolver in resolvers { DNSServiceRefDeallocate(resolver) }
        resolvers.removeAll(); names.removeAll()
        let endpoints = cancelled ? [] : results
        results.removeAll()
        continuation.resume(returning: endpoints)
    }
}
