package net.justincredible;

import android.util.Log;

import androidx.annotation.NonNull;

import com.braintreepayments.api.ErrorWithResponse;
import com.braintreepayments.api.PayPalAccountNonce;
import com.braintreepayments.api.PayPalCheckoutRequest;
import com.braintreepayments.api.PayPalClient;
import com.braintreepayments.api.BraintreeClient;
import com.braintreepayments.api.PayPalLineItem;
import com.braintreepayments.api.PayPalListener;
import com.braintreepayments.api.PayPalPaymentIntent;
import com.braintreepayments.api.UserCanceledException;

import org.apache.cordova.CallbackContext;
import org.apache.cordova.CordovaPlugin;
import org.json.JSONArray;
import org.json.JSONException;
import org.json.JSONObject;

import java.util.ArrayList;
import java.util.HashMap;
import java.util.Map;

public class BraintreePlugin extends CordovaPlugin implements PayPalListener {

    private static final String TAG = "BraintreePlugin";
    private BraintreeClient braintreeClient;
    private PayPalClient payPalClient;
    private CallbackContext _callbackContext = null;

    @Override
    public synchronized boolean execute(String action, final JSONArray args, final CallbackContext callbackContext) throws JSONException {

        if (action == null) {
            Log.e(TAG, "execute ==> exiting for bad action");
            return false;
        }

        Log.w(TAG, "execute ==> " + action + " === " + args);

        _callbackContext = callbackContext;

        try {
            switch (action) {
                case "initialize" -> this.initializeBT(args);
                case "paypalProcess" -> this.paypalProcess(args);
                case "setupApplePay" -> this.setupApplePay();
                default -> {
                    // The given action was not handled above.
                    return false;
                }
            }
        } catch (Exception exception) {
            callbackContext.error("BraintreePlugin uncaught exception: " + exception.getMessage());
        }

        return true;
    }

    // Actions

    private synchronized void initializeBT(final JSONArray args) throws Exception {

        // Ensure we have the correct number of arguments.
        if (args.length() != 1) {
            _callbackContext.error("A token is required.");
            return;
        }

        // Obtain the arguments.
        String token = args.getString(0);

        if (token == null || token.equals("")) {
            _callbackContext.error("A token is required.");
            return;
        }

        braintreeClient = new BraintreeClient(this.cordova.getContext(), token);
        this.cordova.getActivity().runOnUiThread(() -> {
            payPalClient = new PayPalClient(this.cordova.getActivity(), braintreeClient);
            payPalClient.setListener(this);
        });

        _callbackContext.success();
    }

    private synchronized void setupApplePay() throws JSONException {
        // Apple Pay available on iOS only
        _callbackContext.success();
    }

    private synchronized void paypalProcess(final JSONArray args) throws Exception {
        String amount = args.getString(0);
        /*payPalRequest = new PayPalRequest(amount);
        payPalRequest.currencyCode(args.getString(1));
        payPalRequest.intent(PayPalRequest.INTENT_AUTHORIZE);

        //--Rut - 04/12/2020 - sfrutto il terzo parametro (in origine 'env') per farmi passare un titolo da attribuire al numero d'ordine
        String lineItemName = args.getString(2);
        PayPalLineItem itemTest = new PayPalLineItem(PayPalLineItem.KIND_DEBIT, lineItemName, "1", amount);
        ArrayList<PayPalLineItem> lineItems = new ArrayList<>();
        lineItems.add(itemTest);
        payPalRequest.lineItems(lineItems);

        PayPal.requestOneTimePayment(braintreeFragment, payPalRequest);*/

        PayPalCheckoutRequest request = new PayPalCheckoutRequest(amount);
        request.setIntent(PayPalPaymentIntent.AUTHORIZE);
        request.setCurrencyCode(args.getString(1));
        String lineItemName = args.getString(2);
        PayPalLineItem itemTest = new PayPalLineItem(PayPalLineItem.KIND_DEBIT, lineItemName, "1", amount);
        ArrayList<PayPalLineItem> lineItems = new ArrayList<>();
        lineItems.add(itemTest);
        request.setLineItems(lineItems);

        payPalClient.tokenizePayPalAccount(this.cordova.getActivity(), request);
    }

    @Override
    public void onPayPalSuccess(@NonNull PayPalAccountNonce payPalAccountNonce) {
        Map<String, Object> resultMap = new HashMap<String, Object>();

        resultMap.put("nonce", payPalAccountNonce.getString());


        Map<String, Object> innerMap = new HashMap<String, Object>();
        resultMap.put("email", payPalAccountNonce.getEmail());
        resultMap.put("firstName", payPalAccountNonce.getFirstName());
        resultMap.put("lastName", payPalAccountNonce.getLastName());
        resultMap.put("phone", payPalAccountNonce.getPhone());
        resultMap.put("clientMetadataId", payPalAccountNonce.getClientMetadataId());
        resultMap.put("payerId", payPalAccountNonce.getPayerId());

        resultMap.put("paypalAccount", innerMap);

        _callbackContext.success(new JSONObject(resultMap));

    }

    @Override
    public void onPayPalFailure(@NonNull Exception error) {
        if (error instanceof UserCanceledException) {
            // user canceled
            Log.e(TAG, "User canceled payment: " + error.getMessage());
            _callbackContext.error("cancel");
        } else {
            // handle error
            Log.e(TAG, "Caught error from BraintreeSDK: " + error.getMessage());
            JSONObject errObj = new JSONObject();
            try {
                errObj.put("message", error.getMessage());
                errObj.put("trace", Log.getStackTraceString(error));
                if (error instanceof ErrorWithResponse) {
                    errObj.put("errorResponse", ((ErrorWithResponse) error).getErrorResponse());
                }
                _callbackContext.error(errObj);
            } catch (JSONException e) {
                e.printStackTrace();
                _callbackContext.error("BraintreePlugin uncaught exception: " + Log.getStackTraceString(error));
            }
        }
    }
}
