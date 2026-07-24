import XCTest
@testable import PrintPlexCore

final class ShopifyClientTests: XCTestCase {

    func testNormalizedDomain() {
        XCTAssertEqual(
            ShopifyCredentials(storeDomain: "https://maboutique.myshopify.com/", accessToken: "t")
                .normalizedDomain,
            "maboutique.myshopify.com"
        )
        XCTAssertEqual(
            ShopifyCredentials(storeDomain: "maboutique", accessToken: "t").normalizedDomain,
            "maboutique.myshopify.com"
        )
        XCTAssertEqual(
            ShopifyCredentials(storeDomain: "  boutique.example.com  ", accessToken: "t")
                .normalizedDomain,
            "boutique.example.com"
        )
    }

    func testIsConfigured() {
        XCTAssertFalse(ShopifyCredentials(storeDomain: "", accessToken: "").isConfigured)
        XCTAssertFalse(ShopifyCredentials(storeDomain: "shop", accessToken: "  ").isConfigured)
        XCTAssertTrue(ShopifyCredentials(storeDomain: "shop", accessToken: "token").isConfigured)
    }

    func testParseLinkHeader() {
        let header = #"<https://x.myshopify.com/admin/api/2024-01/products.json?page_info=abc123&limit=250>; rel="next", <https://x.myshopify.com/admin/api/2024-01/products.json?page_info=zzz>; rel="previous""#
        XCTAssertEqual(ShopifyClient.parseLinkHeader(header), "abc123")
        XCTAssertNil(ShopifyClient.parseLinkHeader(nil))
        XCTAssertNil(ShopifyClient.parseLinkHeader(#"<https://x/p.json?page_info=zzz>; rel="previous""#))
    }

    func testMatchProductExplicitIdWins() {
        let products = [
            ShopifyProduct(id: 1, title: "Dragon articulé", status: "active", handle: "dragon",
                           variants: [ShopifyVariant(id: 10, price: "15.00", title: "Default")]),
            ShopifyProduct(id: 2, title: "Vase spirale", status: "draft", handle: "vase",
                           variants: []),
        ]

        // Explicit ID beats name matching
        let explicit = ShopifyClient.matchProduct(
            in: products, projectName: "Dragon", explicitProductId: "2")
        XCTAssertEqual(explicit?.id, 2)

        // Fuzzy name match
        let fuzzy = ShopifyClient.matchProduct(
            in: products, projectName: "dragon", explicitProductId: nil)
        XCTAssertEqual(fuzzy?.id, 1)

        // No match
        XCTAssertNil(ShopifyClient.matchProduct(
            in: products, projectName: "Inexistant", explicitProductId: nil))
    }

    func testLowestPriceAndStatus() {
        let product = ShopifyProduct(
            id: 1, title: "T", status: "active", handle: "t",
            variants: [
                ShopifyVariant(id: 1, price: "25.00", title: "Grand"),
                ShopifyVariant(id: 2, price: "12.50", title: "Petit"),
            ])
        XCTAssertEqual(product.lowestPrice, 12.50)
        XCTAssertTrue(product.isActive)
        XCTAssertEqual(product.statusLabel, "En vente")
    }
}
