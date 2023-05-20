# InAppPay

in-app purchase

## Usage
```swift

// Get product list
InAppPay.instance.list(productIds: ["com.test.test"]) { list in
    
}

// start pay
InAppPay.instance.start("com.test.test", password: "aaa") { type, responseData in
    // If isServerAuth is true, responseData is receipt, you need to convert Base64 by yourself
    // If is is false, responseData is the value after verification, which can be converted to JSON
}

// restore pay
InAppPay.instance.restore { type, data in
    // data same as above
}

```
