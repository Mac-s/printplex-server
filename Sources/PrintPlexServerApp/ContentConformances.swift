import Vapor
import PrintPlexCore

// PrintPlexCore's DTOs become the wire format of the API.
extension ProjectDTO: Content {}
extension FileDTO: Content {}
extension PrintEstimate: Content {}
extension ShopifyProduct: Content {}
extension PrinterProfile: Content {}
extension PrintMaterial: Content {}
