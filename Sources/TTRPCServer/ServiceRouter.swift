import Foundation
import TTRPCCore

/// Manages registered services and routes incoming requests to the appropriate handler.
public struct ServiceRouter: Sendable {
    private let services: [String: TTRPCServiceDescriptor]

    public init(services: [any TTRPCServiceRegistration]) {
        var map: [String: TTRPCServiceDescriptor] = [:]
        for registration in services {
            let desc = registration.serviceDescriptor
            map[desc.name] = desc
        }
        self.services = map
    }

    /// Look up the unary method handler for a given service and method name.
    public func lookupMethod(service: String, method: String) throws -> TTRPCMethodDescriptor {
        guard let svc = services[service] else {
            throw TTRPCError.serviceNotFound(service: service, method: method)
        }
        guard let methodDesc = svc.methods[method] else {
            throw TTRPCError.serviceNotFound(service: service, method: method)
        }
        return methodDesc
    }

    /// Look up the streaming handler for a given service and method name.
    public func lookupStream(service: String, method: String) throws -> TTRPCStreamDescriptor {
        guard let svc = services[service] else {
            throw TTRPCError.serviceNotFound(service: service, method: method)
        }
        guard let streamDesc = svc.streams[method] else {
            throw TTRPCError.serviceNotFound(service: service, method: method)
        }
        return streamDesc
    }

    /// Check whether a method exists (either unary or streaming).
    public func hasMethod(service: String, method: String) -> Bool {
        guard let svc = services[service] else { return false }
        return svc.methods[method] != nil || svc.streams[method] != nil
    }

    /// Check whether a specific method is a streaming method.
    public func hasStreamMethod(service: String, method: String) -> Bool {
        guard let svc = services[service] else { return false }
        return svc.streams[method] != nil
    }
}
