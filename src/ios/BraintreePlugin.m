//
//  BraintreePlugin.m
//
//  Copyright (c) 2016 Justin Unterreiner. All rights reserved.
//

#import "BraintreePlugin.h"
#import <objc/runtime.h>
#import <PassKit/PassKit.h>

// Import Braintree SDK components
#import <Braintree/Braintree.h>
#import <BraintreeDropIn/BraintreeDropIn.h>
#import <Braintree/BraintreeDataCollector.h>
#import <BrainTree/BTPayPalCheckoutRequest.h>
#import <Braintree/BTPayPalDriver.h>
#import <Braintree/BTPayPalLineItem.h>
#import <Braintree/BTPayPalAccountNonce.h>
#import "AppDelegate.h"

@interface BraintreePlugin() <PKPaymentAuthorizationViewControllerDelegate, BTViewControllerPresentingDelegate>

@property (nonatomic, strong) BTAPIClient *braintreeClient;
@property (nonatomic, strong) BTDataCollector *dataCollector;
@property NSString* token;

@end

@implementation AppDelegate(BraintreePlugin)


- (BOOL)application:(UIApplication *)application
            openURL:(NSURL *)url
  sourceApplication:(NSString *)sourceApplication
         annotation:(id)annotation {
    NSString *bundle_id = [NSBundle mainBundle].bundleIdentifier;
    bundle_id = [bundle_id stringByAppendingString:@".payments"];

    if ([url.scheme localizedCaseInsensitiveCompare:bundle_id] == NSOrderedSame) {
        // Use Braintree's URL handler - updated for SDK 5.25.0
        [BTAppContextSwitcher setReturnURLScheme:bundle_id];
        return YES;
    }

    // all plugins will get the notification, and their handlers will be called
    [[NSNotificationCenter defaultCenter] postNotification:[NSNotification notificationWithName:CDVPluginHandleOpenURLNotification object:url]];

    return NO;
}

@end

@implementation BraintreePlugin

NSString *dropInUIcallbackId;
NSString *paypalProcessCallbackId;
NSString *applePayProcessCallbackId;
bool applePaySuccess;
bool applePayInited = NO;
NSString *applePayMerchantID;
NSString *currencyCode;
NSString *countryCode;

#pragma mark - Cordova commands

- (void)initialize:(CDVInvokedUrlCommand *)command {

    // Ensure we have the correct number of arguments.
    if ([command.arguments count] != 1) {
        CDVPluginResult *res = [CDVPluginResult resultWithStatus:CDVCommandStatus_ERROR messageAsString:@"A token is required."];
        [self.commandDelegate sendPluginResult:res callbackId:command.callbackId];
        return;
    }

    // Obtain the arguments.
    self.token = [command.arguments objectAtIndex:0];

    if (!self.token) {
        CDVPluginResult *res = [CDVPluginResult resultWithStatus:CDVCommandStatus_ERROR messageAsString:@"A token is required."];
        [self.commandDelegate sendPluginResult:res callbackId:command.callbackId];
        return;
    }

    self.braintreeClient = [[BTAPIClient alloc] initWithAuthorization:self.token];

    if (!self.braintreeClient) {
        CDVPluginResult *res = [CDVPluginResult resultWithStatus:CDVCommandStatus_ERROR messageAsString:@"The Braintree client failed to initialize."];
        [self.commandDelegate sendPluginResult:res callbackId:command.callbackId];
        return;
    }

    self.dataCollector = [[BTDataCollector alloc] initWithAPIClient:self.braintreeClient];

    NSString *bundle_id = [NSBundle mainBundle].bundleIdentifier;
    bundle_id = [bundle_id stringByAppendingString:@".payments"];

    // Use Braintree's shared instance to set up URL scheme handling
    [BTAppContextSwitcher setReturnURLScheme:bundle_id];

    CDVPluginResult *res = [CDVPluginResult resultWithStatus:CDVCommandStatus_OK];
    [self.commandDelegate sendPluginResult:res callbackId:command.callbackId];
}

- (void)setupApplePay:(CDVInvokedUrlCommand *)command {

    // Ensure the client has been initialized.
    if (!self.braintreeClient) {
        CDVPluginResult *res = [CDVPluginResult resultWithStatus:CDVCommandStatus_ERROR messageAsString:@"The Braintree client must first be initialized via BraintreePlugin.initialize(token)"];
        [self.commandDelegate sendPluginResult:res callbackId:command.callbackId];
        return;
    }

    if ([command.arguments count] != 3) {
        CDVPluginResult *res = [CDVPluginResult resultWithStatus:CDVCommandStatus_ERROR messageAsString:@"Merchant id, Currency code and Country code are required."];
        [self.commandDelegate sendPluginResult:res callbackId:command.callbackId];
        return;
    }

    if ((PKPaymentAuthorizationViewController.canMakePayments) && ([PKPaymentAuthorizationViewController canMakePaymentsUsingNetworks:@[PKPaymentNetworkVisa, PKPaymentNetworkMasterCard, PKPaymentNetworkAmex, PKPaymentNetworkDiscover]])) {
        applePayMerchantID = [command.arguments objectAtIndex:0];
        currencyCode = [command.arguments objectAtIndex:1];
        countryCode = [command.arguments objectAtIndex:2];

        applePayInited = YES;

        CDVPluginResult *res = [CDVPluginResult resultWithStatus:CDVCommandStatus_OK];
        [self.commandDelegate sendPluginResult:res callbackId:command.callbackId];
    } else {
        CDVPluginResult *res = [CDVPluginResult resultWithStatus:CDVCommandStatus_ERROR messageAsString:@"ApplePay cannot be used."];
        [self.commandDelegate sendPluginResult:res callbackId:command.callbackId];
    }
}

- (void)applePayProcess:(CDVInvokedUrlCommand *)command {
    // Ensure the client has been initialized.
    if (!self.braintreeClient) {
        CDVPluginResult *res = [CDVPluginResult resultWithStatus:CDVCommandStatus_ERROR messageAsString:@"The Braintree client must first be initialized via BraintreePlugin.initialize(token)"];
        [self.commandDelegate sendPluginResult:res callbackId:command.callbackId];
        return;
    }

    // Ensure we have the correct number of arguments.
     if ([command.arguments count] < 2) {
        CDVPluginResult *res = [CDVPluginResult resultWithStatus:CDVCommandStatus_ERROR messageAsString:@"amount and line item description required."];
        [self.commandDelegate sendPluginResult:res callbackId:command.callbackId];
        return;
     }

    // Obtain the arguments.
    NSString* amount = (NSString *)[command.arguments objectAtIndex:0];
    if ([amount isKindOfClass:[NSNumber class]]) {
        amount = [(NSNumber *)amount stringValue];
    }
    if (!amount) {
        CDVPluginResult *res = [CDVPluginResult resultWithStatus:CDVCommandStatus_ERROR messageAsString:@"amount is required."];
        [self.commandDelegate sendPluginResult:res callbackId:command.callbackId];
        return;
    }

    NSString* lineItemName = [command.arguments objectAtIndex:1];

    // Save off the Cordova callback ID so it can be used in the completion handlers.
    applePayProcessCallbackId = command.callbackId;

    PKPaymentRequest *apPaymentRequest = [[PKPaymentRequest alloc] init];
    apPaymentRequest.paymentSummaryItems = @[
        [PKPaymentSummaryItem summaryItemWithLabel:lineItemName amount:[NSDecimalNumber decimalNumberWithString: amount]],
                                             [PKPaymentSummaryItem summaryItemWithLabel:@"Rikorda S.C.A.R.L." amount:[NSDecimalNumber decimalNumberWithString: amount]]
                                             ];
    apPaymentRequest.supportedNetworks = [self paymentMethods];
    apPaymentRequest.merchantCapabilities = PKMerchantCapability3DS;
    apPaymentRequest.currencyCode = currencyCode;
    apPaymentRequest.countryCode = countryCode;

    apPaymentRequest.merchantIdentifier = applePayMerchantID;

    if ((PKPaymentAuthorizationViewController.canMakePayments) && ([PKPaymentAuthorizationViewController canMakePaymentsUsingNetworks:apPaymentRequest.supportedNetworks])) {
        PKPaymentAuthorizationViewController *viewController = [[PKPaymentAuthorizationViewController alloc] initWithPaymentRequest:apPaymentRequest];
        viewController.delegate = self;

        applePaySuccess = NO;

        // display ApplePay ont the rootViewController
        UIViewController *rootViewController = [[[UIApplication sharedApplication] keyWindow] rootViewController];

        [rootViewController presentViewController:viewController animated:YES completion:nil];
    } else {
        CDVPluginResult *pluginResult = [CDVPluginResult resultWithStatus:CDVCommandStatus_ERROR messageAsString:@"ApplePay cannot be used."];

        [self.commandDelegate sendPluginResult:pluginResult callbackId:applePayProcessCallbackId];
        applePayProcessCallbackId = nil;
    }
}


- (void)paypalProcess:(CDVInvokedUrlCommand *)command {
    // Ensure the client has been initialized.
    if (!self.braintreeClient) {
        CDVPluginResult *res = [CDVPluginResult resultWithStatus:CDVCommandStatus_ERROR messageAsString:@"The Braintree client must first be initialized via BraintreePlugin.initialize(token)"];
        [self.commandDelegate sendPluginResult:res callbackId:command.callbackId];
        return;
    }

    // Ensure we have the correct number of arguments.
    if ([command.arguments count] < 2) {
        CDVPluginResult *res = [CDVPluginResult resultWithStatus:CDVCommandStatus_ERROR messageAsString:@"amount and currency code required."];
        [self.commandDelegate sendPluginResult:res callbackId:command.callbackId];
        return;
    }

    // Obtain the arguments.
    NSString* amount = (NSString *)[command.arguments objectAtIndex:0];
    if ([amount isKindOfClass:[NSNumber class]]) {
        amount = [(NSNumber *)amount stringValue];
    }
    if (!amount) {
        CDVPluginResult *res = [CDVPluginResult resultWithStatus:CDVCommandStatus_ERROR messageAsString:@"amount is required."];
        [self.commandDelegate sendPluginResult:res callbackId:command.callbackId];
        return;
    }

    NSString* currencyCode = [command.arguments objectAtIndex:1];

    //--Rut - 04/12/2020 - sfrutto il terzo parametro (in origine 'env') per farmi passare un titolo da attribuire al numero d'ordine
    NSString* lineItemName = [command.arguments objectAtIndex:2];

    // Save off the Cordova callback ID so it can be used in the completion handlers.
    paypalProcessCallbackId = command.callbackId;

    BTPayPalDriver *payPalDriver = [[BTPayPalDriver alloc] initWithAPIClient:self.braintreeClient];
    //payPalDriver.viewControllerPresentingDelegate = self;
    // appSwitchDelegate is no longer needed in v5.25.0
    
    // Updated to use BTPayPalCheckoutRequest instead of BTPayPalRequest
    BTPayPalCheckoutRequest *request = [[BTPayPalCheckoutRequest alloc] initWithAmount:amount];
    request.currencyCode = currencyCode;
    
    BTPayPalLineItem *orderDesc = [[BTPayPalLineItem alloc] initWithQuantity:@"1" unitAmount:amount name:lineItemName kind:BTPayPalLineItemKindDebit];
    NSArray *lineItems = @[orderDesc];
    request.lineItems = lineItems;

    // Updated to use tokenizePayPalAccount instead of requestOneTimePayment
    [payPalDriver tokenizePayPalAccountWithPayPalRequest:request
                            completion:^(BTPayPalAccountNonce *tokenizedPayPalAccount, NSError *error) {
        if (tokenizedPayPalAccount) {
            NSLog(@"Got a nonce: %@", tokenizedPayPalAccount.nonce);

            [self.dataCollector collectDeviceData:^(NSString * _Nonnull deviceData) {
                NSDictionary *dictionary = @{
                    @"nonce": tokenizedPayPalAccount.nonce,
                    @"deviceData": deviceData,
                    @"payerId": tokenizedPayPalAccount.payerID,
                    @"firstName": tokenizedPayPalAccount.firstName ?: [NSNull null],
                    @"lastName": tokenizedPayPalAccount.lastName ?: [NSNull null]
                };

                CDVPluginResult *pluginResult = [CDVPluginResult resultWithStatus:CDVCommandStatus_OK messageAsDictionary:dictionary];
                [self.commandDelegate sendPluginResult:pluginResult callbackId:paypalProcessCallbackId];
            }];
        } else if (error) {
            // Handle error here...
            CDVPluginResult *res = [CDVPluginResult resultWithStatus:CDVCommandStatus_ERROR messageAsString:[error localizedDescription]];
            [self.commandDelegate sendPluginResult:res callbackId:command.callbackId];
        } else {
            // Buyer canceled payment approval
            CDVPluginResult *res = [CDVPluginResult resultWithStatus:CDVCommandStatus_ERROR messageAsString:@"cancel"];
            [self.commandDelegate sendPluginResult:res callbackId:command.callbackId];
        }
    }];
 }

- (void)presentDropInPaymentUI:(CDVInvokedUrlCommand *)command {

    // Ensure the client has been initialized.
    if (!self.braintreeClient) {
        CDVPluginResult *res = [CDVPluginResult resultWithStatus:CDVCommandStatus_ERROR messageAsString:@"The Braintree client must first be initialized via BraintreePlugin.initialize(token)"];
        [self.commandDelegate sendPluginResult:res callbackId:command.callbackId];
        return;
    }

    // Ensure we have the correct number of arguments.
    if ([command.arguments count] < 1) {
        CDVPluginResult *res = [CDVPluginResult resultWithStatus:CDVCommandStatus_ERROR messageAsString:@"amount required."];
        [self.commandDelegate sendPluginResult:res callbackId:command.callbackId];
        return;
    }

    // Obtain the arguments.

    NSString* amount = (NSString *)[command.arguments objectAtIndex:0];
    if ([amount isKindOfClass:[NSNumber class]]) {
        amount = [(NSNumber *)amount stringValue];
    }
    if (!amount) {
        CDVPluginResult *res = [CDVPluginResult resultWithStatus:CDVCommandStatus_ERROR messageAsString:@"amount is required."];
        [self.commandDelegate sendPluginResult:res callbackId:command.callbackId];
        return;
    }

    NSString* primaryDescription = [command.arguments objectAtIndex:1];

    // Save off the Cordova callback ID so it can be used in the completion handlers.
    dropInUIcallbackId = command.callbackId;

    /* Drop-IN 5.0 */
    BTDropInRequest *paymentRequest = [[BTDropInRequest alloc] init];

    //parte drop-in INUTILIZZATA DA NOI - COMMENTATA -
    /*
    paymentRequest.amount = amount;
    paymentRequest.applePayDisabled = !applePayInited;

    BTDropInController *dropIn = [[BTDropInController alloc] initWithAuthorization:self.token request:paymentRequest handler:^(BTDropInController * _Nonnull controller, BTDropInResult * _Nullable result, NSError * _Nullable error) {
        [self.viewController dismissViewControllerAnimated:YES completion:nil];
        if (error != nil) {
            NSLog(@"ERROR: %@", [error localizedDescription]);
            CDVPluginResult *pluginResult = [CDVPluginResult resultWithStatus:CDVCommandStatus_ERROR messageAsString:[error localizedDescription]];

            [self.commandDelegate sendPluginResult:pluginResult callbackId:dropInUIcallbackId];
            dropInUIcallbackId = nil;
        } else if (result.cancelled) {
            if (dropInUIcallbackId) {

                NSDictionary *dictionary = @{ @"userCancelled": @YES };

                CDVPluginResult *pluginResult = [CDVPluginResult resultWithStatus:CDVCommandStatus_OK
                                                              messageAsDictionary:dictionary];

                [self.commandDelegate sendPluginResult:pluginResult callbackId:dropInUIcallbackId];
                dropInUIcallbackId = nil;
            }
        } else {
            if (dropInUIcallbackId) {
                if (result.paymentOptionType == BTUIKPaymentOptionTypeApplePay ) {
                    PKPaymentRequest *apPaymentRequest = [[PKPaymentRequest alloc] init];
                    apPaymentRequest.paymentSummaryItems = @[
                                                             [PKPaymentSummaryItem summaryItemWithLabel:primaryDescription amount:[NSDecimalNumber decimalNumberWithString: amount]]
                                                             ];
                    apPaymentRequest.supportedNetworks = @[PKPaymentNetworkVisa, PKPaymentNetworkMasterCard, PKPaymentNetworkAmex, PKPaymentNetworkDiscover];
                    apPaymentRequest.merchantCapabilities = PKMerchantCapability3DS;
                    apPaymentRequest.currencyCode = currencyCode;
                    apPaymentRequest.countryCode = countryCode;

                    apPaymentRequest.merchantIdentifier = applePayMerchantID;

                    if ((PKPaymentAuthorizationViewController.canMakePayments) && ([PKPaymentAuthorizationViewController canMakePaymentsUsingNetworks:apPaymentRequest.supportedNetworks])) {
                        PKPaymentAuthorizationViewController *viewController = [[PKPaymentAuthorizationViewController alloc] initWithPaymentRequest:apPaymentRequest];
                        viewController.delegate = self;

                        applePaySuccess = NO;

                        // display ApplePay ont the rootViewController
                        UIViewController *rootViewController = [[[UIApplication sharedApplication] keyWindow] rootViewController];

                        [rootViewController presentViewController:viewController animated:YES completion:nil];
                    } else {
                        CDVPluginResult *pluginResult = [CDVPluginResult resultWithStatus:CDVCommandStatus_ERROR messageAsString:@"ApplePay cannot be used."];

                        [self.commandDelegate sendPluginResult:pluginResult callbackId:dropInUIcallbackId];
                        dropInUIcallbackId = nil;
                    }
                } else {
                    NSDictionary *dictionary = [self getPaymentUINonceResult:result.paymentMethod];

                    CDVPluginResult *pluginResult = [CDVPluginResult resultWithStatus:CDVCommandStatus_OK messageAsDictionary:dictionary];

                    [self.commandDelegate sendPluginResult:pluginResult callbackId:dropInUIcallbackId];
                    dropInUIcallbackId = nil;
                }
            }
        }
    }];
*/
   // [self.viewController presentViewController:dropIn animated:YES completion:nil];
}

#pragma mark - PKPaymentAuthorizationViewControllerDelegate
- (void)paymentAuthorizationViewController:(PKPaymentAuthorizationViewController *)controller didAuthorizePayment:(PKPayment *)payment completion:(void (^)(PKPaymentAuthorizationStatus status))completion {

    applePaySuccess = YES;

    BTApplePayClient *applePayClient = [[BTApplePayClient alloc] initWithAPIClient:self.braintreeClient];
    [applePayClient tokenizeApplePayPayment:payment completion:^(BTApplePayCardNonce *tokenizedApplePayPayment, NSError *error) {
        if (tokenizedApplePayPayment) {
            // On success, send nonce to your server for processing.
            NSDictionary *dictionary = [self getPaymentUINonceResult:tokenizedApplePayPayment];

            CDVPluginResult *pluginResult = [CDVPluginResult resultWithStatus:CDVCommandStatus_OK
                                                          messageAsDictionary:dictionary];

            [self.commandDelegate sendPluginResult:pluginResult callbackId:applePayProcessCallbackId];
            applePayProcessCallbackId = nil;

            // Then indicate success or failure via the completion callback, e.g.
            completion(PKPaymentAuthorizationStatusSuccess);
        } else {
            // Tokenization failed. Check `error` for the cause of the failure.
            CDVPluginResult *pluginResult = [CDVPluginResult resultWithStatus:CDVCommandStatus_ERROR messageAsString:@"Apple Pay tokenization failed"];

            [self.commandDelegate sendPluginResult:pluginResult callbackId:applePayProcessCallbackId];
            applePayProcessCallbackId = nil;

            // Indicate failure via the completion callback:
            completion(PKPaymentAuthorizationStatusFailure);
        }
    }];
}

- (void)paymentAuthorizationViewControllerDidFinish:(PKPaymentAuthorizationViewController *)controller {
    UIViewController *rootViewController = [[[UIApplication sharedApplication] keyWindow] rootViewController];

    [rootViewController dismissViewControllerAnimated:YES completion:nil];

    /* if not success, fire cancel event */
    if (!applePaySuccess) {
        NSDictionary *dictionary = @{ @"userCancelled": @YES };

        CDVPluginResult *pluginResult = [CDVPluginResult resultWithStatus:CDVCommandStatus_OK  messageAsDictionary:dictionary];

        [self.commandDelegate sendPluginResult:pluginResult callbackId:applePayProcessCallbackId];
        applePayProcessCallbackId = nil;
    }
}

#pragma mark - BTViewControllerPresentingDelegate

// Required
- (void)paymentDriver:(id)paymentDriver
requestsPresentationOfViewController:(UIViewController *)viewController {
    [self.viewController presentViewController:viewController animated:YES completion:nil];
}

// Required
- (void)paymentDriver:(id)paymentDriver
requestsDismissalOfViewController:(UIViewController *)viewController {
    [self.viewController dismissViewControllerAnimated:YES completion:nil];
}


#pragma mark - Helpers
/**
 * Helper used to return a dictionary of values from the given payment method nonce.
 * Handles several different types of nonces (eg for cards, Apple Pay, PayPal, etc).
 */
- (NSDictionary*)getPaymentUINonceResult:(BTPaymentMethodNonce *)paymentMethodNonce {

    BTCardNonce *cardNonce;
    BTPayPalAccountNonce *payPalAccountNonce;
    BTApplePayCardNonce *applePayCardNonce;
   // BTThreeDSecureCardNonce *threeDSecureCardNonce;
    //BTVenmoAccountNonce *venmoAccountNonce;

    if ([paymentMethodNonce isKindOfClass:[BTCardNonce class]]) {
        cardNonce = (BTCardNonce*)paymentMethodNonce;
    }

    if ([paymentMethodNonce isKindOfClass:[BTPayPalAccountNonce class]]) {
        payPalAccountNonce = (BTPayPalAccountNonce*)paymentMethodNonce;
    }

    if ([paymentMethodNonce isKindOfClass:[BTApplePayCardNonce class]]) {
        applePayCardNonce = (BTApplePayCardNonce*)paymentMethodNonce;
    }
/*
    if ([paymentMethodNonce isKindOfClass:[BTThreeDSecureCardNonce class]]) {
        threeDSecureCardNonce = (BTThreeDSecureCardNonce*)paymentMethodNonce;
    }
*/
    /*if ([paymentMethodNonce isKindOfClass:[BTVenmoAccountNonce class]]) {
        venmoAccountNonce = (BTVenmoAccountNonce*)paymentMethodNonce;
    }*/

    NSDictionary *dictionary = @{ @"userCancelled": @NO,

                                  // Standard Fields
                                  @"nonce": paymentMethodNonce.nonce,
                                  @"type": paymentMethodNonce.type,
                                  @"localizedDescription": paymentMethodNonce.description,

                                  // BTCardNonce Fields
                                  @"card": !cardNonce ? [NSNull null] : @{
                                          @"lastTwo": cardNonce.lastTwo,
                                          @"network": [self formatCardNetwork:cardNonce.cardNetwork]
                                          },

                                  // BTPayPalAccountNonce
                                  @"payPalAccount": !payPalAccountNonce ? [NSNull null] : @{
                                          @"email": payPalAccountNonce.email,
                                          @"firstName": (payPalAccountNonce.firstName == nil ? [NSNull null] : payPalAccountNonce.firstName),
                                          @"lastName": (payPalAccountNonce.lastName == nil ? [NSNull null] : payPalAccountNonce.lastName),
                                          @"phone": (payPalAccountNonce.phone == nil ? [NSNull null] : payPalAccountNonce.phone),
                                          //@"billingAddress" //TODO
                                          //@"shippingAddress" //TODO
                                          @"clientMetadataId":  (payPalAccountNonce.clientMetadataID == nil ? [NSNull null] : payPalAccountNonce.clientMetadataID),
                                          @"payerId": (payPalAccountNonce.payerID == nil ? [NSNull null] : payPalAccountNonce.payerID),
                                          },

                                  // BTApplePayCardNonce
                                  @"applePayCard": !applePayCardNonce ? [NSNull null] : @{
                                          },

                                  // BTThreeDSecureCardNonce Fields
                                  @"threeDSecureCard": [NSNull null],

                                  // BTVenmoAccountNonce Fields
                                  /*@"venmoAccount": !venmoAccountNonce ? [NSNull null] : @{
                                          @"username": venmoAccountNonce.username
                                          }*/
                                  };
    return dictionary;
}

- (NSArray *) paymentMethods {
    NSMutableArray<PKPaymentNetwork> *paymentMethods = [@[PKPaymentNetworkVisa, PKPaymentNetworkMasterCard, PKPaymentNetworkAmex] mutableCopy];

    if (@available(iOS 12.0, *)) {
        [paymentMethods addObject:PKPaymentNetworkMaestro];
    }

    return paymentMethods;
}

/**
 * Helper used to provide a string value for the given BTCardNetwork enumeration value.
 */
- (NSString*)formatCardNetwork:(BTCardNetwork)cardNetwork {
    NSString *result = nil;

    // TODO: This method should probably return the same values as the Android plugin for consistency.

    switch (cardNetwork) {
        case BTCardNetworkUnknown:
            result = @"BTCardNetworkUnknown";
            break;
        case BTCardNetworkAMEX:
            result = @"BTCardNetworkAMEX";
            break;
        case BTCardNetworkDinersClub:
            result = @"BTCardNetworkDinersClub";
            break;
        case BTCardNetworkDiscover:
            result = @"BTCardNetworkDiscover";
            break;
        case BTCardNetworkMasterCard:
            result = @"BTCardNetworkMasterCard";
            break;
        case BTCardNetworkVisa:
            result = @"BTCardNetworkVisa";
            break;
        case BTCardNetworkJCB:
            result = @"BTCardNetworkJCB";
            break;
        case BTCardNetworkLaser:
            result = @"BTCardNetworkLaser";
            break;
        case BTCardNetworkMaestro:
            result = @"BTCardNetworkMaestro";
            break;
        case BTCardNetworkUnionPay:
            result = @"BTCardNetworkUnionPay";
            break;
        case BTCardNetworkSolo:
            result = @"BTCardNetworkSolo";
            break;
        case BTCardNetworkSwitch:
            result = @"BTCardNetworkSwitch";
            break;
        case BTCardNetworkUKMaestro:
            result = @"BTCardNetworkUKMaestro";
            break;
        default:
            result = nil;
    }

    return result;
}

@end

