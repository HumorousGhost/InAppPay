import StoreKit
import Foundation

open class InAppPay: NSObject, SKPaymentTransactionObserver, SKProductsRequestDelegate {
    
    public static let instance = InAppPay()
    
    private override init() {
        super.init()
        SKPaymentQueue.default().add(self)
    }
    
    deinit {
        SKPaymentQueue.default().remove(self)
    }
    
    let sandboxUrl = "https://sandbox.itunes.apple.com/verifyReceipt"
    let itunesUrl = "https://buy.itunes.apple.com/verifyReceipt"
    var password: String = ""
    
    typealias AppPayBlock = (_ type: PayType, _ responseData: Data?) -> Void
    
    private var isComplete: Bool = true
    private var isRestoring: Bool = false
    private var isServerAuth: Bool = false
    private var statusBlock: AppPayBlock!
    private var isTestServer: Bool = true
    
    private var productMap: [String: SKProduct] = [:]
    
    private var products: (([SKProduct]) -> Void)?
    
    /// According to the product id list, get the list of products that can be purchased,
    /// and link to the Apple server for a long callback time
    public func list(productIds: Set<String>, products: (([SKProduct]) -> Void)? = .none) {
        guard SKPaymentQueue.canMakePayments() else {
            products?([])
            return
        }
        self.products = products
        let request = SKProductsRequest(productIdentifiers: productIds)
        request.delegate = self
        request.start()
    }
    
    // MARK: - Get product list callback
    public func productsRequest(_ request: SKProductsRequest, didReceive response: SKProductsResponse) {
        let products = response.products
        if products.isEmpty {
            // no product list
            DispatchQueue.main.async {
                self.products?([])
            }
            return
        }
        self.productMap.removeAll()
        products.forEach { product in
            self.productMap[product.productIdentifier] = product
        }
        DispatchQueue.main.async {
            self.products?(products)
        }
    }
    
    // MARK: - start payment
    /// Start in-app purchase
    /// - Parameters:
    ///   - productId: product identifier
    ///   - password: pay shared key
    ///   - isTestServer: is it a test server
    ///   - complated: call back
    public func start(_ productId: String, password: String, isTestServer: Bool = false, isServerAuth: Bool = false, complated: @escaping (_ type: PayType, _ data: Data?) -> Void) {
        guard !self.productMap.isEmpty else {
            complated(.noList, nil)
            return
        }
        guard SKPaymentQueue.canMakePayments() else {
            complated(.notAllow, nil)
            return
        }
        
        let product = self.productMap[productId]
        guard let product = product else {
            complated(.failed, nil)
            return
        }
        self.statusBlock = complated
        self.isTestServer = isTestServer
        self.password = password
        self.isServerAuth = isServerAuth
        let payment = SKPayment(product: product)
        SKPaymentQueue.default().add(payment)
    }
    
    // MARK: - transaction close
    private func completeTransction(_ transaction: SKPaymentTransaction) {
        let productId = transaction.payment.productIdentifier
        if !productId.isEmpty {
            verifyPurchase(transaction)
        }
    }
    
    // MARK: - verify transaction
    private func verifyPurchase(_ transaction: SKPaymentTransaction?) {
        let recepitUrl = Bundle.main.appStoreReceiptURL
        guard let recepitUrl = recepitUrl else {
            self.statusBlock(.verFailed, nil)
            return
        }
        do {
            let recepit = try Data(contentsOf: recepitUrl)
            if self.isServerAuth {
                self.statusBlock(.success, recepit)
            } else {
                self.toServerVerifyPurchase(transaction, recpit: recepit)
            }
        } catch {
            self.statusBlock(.failed, nil)
        }
    }
    
    // MARK: - to server verify purchase
    private func toServerVerifyPurchase(_ transaction: SKPaymentTransaction?, recpit: Data) {
        do {
            var params = ["receipt-data": recpit.base64EncodedString(options: .endLineWithLineFeed)]
            if !self.password.isEmpty {
                params["password"] = password
            }
            let body = try JSONSerialization.data(withJSONObject: params, options: .prettyPrinted)
            let serverString = self.isTestServer ? sandboxUrl : itunesUrl
            let storeURL = URL(string: serverString)
            var storeRequest = URLRequest(url: storeURL!)
            storeRequest.httpMethod = "POST"
            storeRequest.httpBody = body
            let session = URLSession.shared
            let task = session.dataTask(with: storeRequest) { [unowned self] responseData, response, error in
                guard error == nil else {
                    self.statusBlock(.verFailed, nil)
                    return
                }
                do {
                    let json = try JSONSerialization.jsonObject(with: responseData!, options: .mutableContainers) as! [String: Any]
                    let status = json["status"] as! Int
                    switch status {
                    case 0:
                        self.statusBlock(.success, responseData)
                        self.finishTransaction(transaction)
                    case 21007:
                        self.isTestServer = true
                        self.verifyPurchase(transaction)
                    case 21008:
                        self.isTestServer = false
                        self.verifyPurchase(transaction)
                    default:
                        self.statusBlock(.verFailed, nil)
                        self.finishTransaction(transaction)
                    }
                } catch {
                    self.statusBlock(.verFailed, nil)
                    self.finishTransaction(transaction)
                }
            }
            task.resume()
        } catch {
            self.statusBlock(.verFailed, nil)
            self.finishTransaction(transaction)
        }
    }
    
    // MARK: - transaction finish
    private func finishTransaction(_ transaction: SKPaymentTransaction?) {
        if let transaction = transaction {
            SKPaymentQueue.default().finishTransaction(transaction)
        }
        isComplete = true
    }
    
    // MARK: - transaction failed
    private func failedTransaction(_ transaction: SKPaymentTransaction) {
        guard let error = transaction.error as? SKError else {
            self.statusBlock(.failed, nil)
            return
        }
        switch error.code {
        case .unknown:
            debugPrint("Possibly a jailbroken phone")
        case .clientInvalid:
            debugPrint("The current Apple account cannot be purchased")
        case .paymentCancelled:
            debugPrint("order has been canceled")
        case .paymentInvalid:
            debugPrint("invalid order")
        case .paymentNotAllowed:
            debugPrint("The current device cannot be purchased")
        case .storeProductNotAvailable:
            debugPrint("Current item is unavailable")
        case .cloudServicePermissionDenied:
            debugPrint("Do not allow access to cloud services")
        case .cloudServiceNetworkConnectionFailed:
            debugPrint("The device cannot connect to the network")
        case .cloudServiceRevoked:
            debugPrint("User has revoked permission to use this cloud service")
        case .privacyAcknowledgementRequired:
            debugPrint("Users agree to Apple's Privacy Policy")
        case .unauthorizedRequestData:
            debugPrint("The app is trying to use the requestData property of SKPayment without the proper entitlements")
        case .invalidOfferIdentifier:
            debugPrint("Invalid subscription offer identifier specified")
        case .invalidSignature:
            debugPrint("The provided cryptographic signature is invalid")
        case .missingOfferParams:
            debugPrint("One or more parameters of SKPaymentDiscount are missing")
        case .invalidOfferPrice:
            debugPrint("The price of the selected offer is invalid (e.g. lower than the current base subscription price)")
        case .overlayCancelled:
            debugPrint("overlay cancel")
        case .overlayInvalidConfiguration:
            debugPrint("overlay invalid configuration")
        case .overlayTimeout:
            debugPrint("timeout")
        case .ineligibleForOffer:
            debugPrint("User is not eligible for subscription offer")
        case .unsupportedPlatform:
            debugPrint("unsupported platform")
        case .overlayPresentedInBackgroundScene:
            debugPrint("Client tries to render SKOverlay in UIWindowScene instead of foreground")
        @unknown default:
            debugPrint("unknown mistake")
        }
        self.statusBlock(.failed, nil)
    }
    
    // MARK: - Monitor purchase results
    public func paymentQueue(_ queue: SKPaymentQueue, updatedTransactions transactions: [SKPaymentTransaction]) {
        transactions.forEach { transaction in
            switch transaction.transactionState {
            case .purchased:
                self.completeTransction(transaction)
            case .purchasing:
                break
            case .restored:
                self.isRestoring = true
            case .failed:
                self.failedTransaction(transaction)
                self.finishTransaction(transaction)
            default:
                break
            }
        }
    }
    
    // MARK: - restore purchase
    /// restore purchase
    /// - Parameter complated: call back
    public func restore(complated: @escaping (_ type: PayType, _ data: Data?) -> Void) {
        guard SKPaymentQueue.canMakePayments() else {
            complated(.notAllow, nil)
            return
        }
        self.statusBlock = complated
        SKPaymentQueue.default().restoreCompletedTransactions()
    }
    
    public func paymentQueueRestoreCompletedTransactionsFinished(_ queue: SKPaymentQueue) {
        if self.isRestoring && !queue.transactions.isEmpty {
            self.isRestoring = false
            self.verifyPurchase(queue.transactions.last!)
        } else {
            self.statusBlock(.failed, nil)
        }
    }
}

@available(iOS 13.0, *)
public extension InAppPay {
    /// According to the product id list, get the list of products that can be purchased,
    /// and link to the Apple server for a long callback time
    @discardableResult
    func list(productIds: Set<String>) async -> [SKProduct] {
        await withCheckedContinuation({ result in
            self.list(productIds: productIds) { products in
                result.resume(returning: products)
            }
        })
    }
    
    /// Start in-app purchase
    /// - Parameters:
    ///   - productId: product identifier
    ///   - password: pay shared key
    ///   - isTestServer: is it a test server
    func start(_ productId: String, password: String, isTestServer: Bool = false, isServerAuth: Bool = false) async -> (type: PayType, data: Data?) {
        await withCheckedContinuation({ result in
            self.start(productId, password: password, isTestServer: isTestServer, isServerAuth: isServerAuth) { type, data in
                result.resume(returning: (type, data))
            }
        })
    }
    
    /// restore purchase
    func restore() async -> (type: PayType, data: Data?) {
        await withCheckedContinuation({ result in
            self.restore { type, data in
                result.resume(returning: (type, data))
            }
        })
    }
}

public enum PayType {
    /// pay success
    case success
    /// pay failed
    case failed
    /// pay cancel
    case cancel
    /// order verification failed
    case verFailed
    /// order verification success
    case verSuccess
    /// the current device does not allow payment
    case notAllow
    /// no product list
    case noList
}
