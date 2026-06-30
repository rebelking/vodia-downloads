// Vodia Pharmacy AI Request Intake - Known Customer + Pickup/Delivery Version
'use strict'

// If your Vodia template already injects secret from the OpenAI key field, leave this alone.
// If not, replace the placeholder with a fresh OpenAI key inside Vodia only.
if (typeof secret === "undefined") {
var secret = typeof secret !== "undefined" ? secret : ""
}

// Pharmacy backend settings
var pharmacyApiSecret = "PASTE_GENERATED_PHARMACY_SECRET_HERE"

var pharmacyRequestUrl = "PASTE_GENERATED_PHARMACY_REQUEST_URL_HERE"
var customerLookupUrl = "PASTE_GENERATED_CUSTOMER_LOOKUP_URL_HERE"
var customerEnrichUrl = "PASTE_GENERATED_CUSTOMER_ENRICH_URL_HERE"
var fulfillmentUrl = "PASTE_GENERATED_FULFILLMENT_URL_HERE"

var staffTransferDestination = "2005"

var conversationLanguage = "en"
var knownCustomerProfile = null
var knownCustomerGreeting = ""
var transferInProgress = false

var pharmacyStores = {
lawrence: {
store_code: "LAWRENCE-DEMO",
store_name: "Vodia Test Pharmacy Lawrence",
full_address: "69 Bailey Street, Lawrence, MA 01843"
},
burlington: {
store_code: "BURLINGTON-DEMO",
store_name: "Vodia Test Pharmacy Burlington",
full_address: "25 Network Way, Burlington, MA 01803"
},
methuen: {
store_code: "METHUEN-DEMO",
store_name: "Vodia Test Pharmacy Methuen",
full_address: "100 Demo Avenue, Methuen, MA 01844"
}
}

var audioDirective = "Process audio like a human in a noisy room: identify intent, context, and relevance before responding. Ignore incidental speech, background voices, music, and environmental noise. Respond only when speech is clearly directed at you or relevant to the active conversation. "

var texts = {
initial: {
en: "Thank you for calling Vodia Pharmacy. I can help enter a refill request, medication request, or stock review request for pharmacy staff. If you would like to continue in Spanish, please say Spanish or Espanol. How can I help you today?",
es: "Gracias por llamar a Vodia Pharmacy. Puedo ayudarle a ingresar una solicitud de refill, una solicitud de medicamento, o una revision de inventario para el personal de farmacia. Como puedo ayudarle hoy?"
}
}

function text(name) {
var prompt = texts[name] || {}
if (conversationLanguage in prompt) return prompt[conversationLanguage]
return prompt["en"] || ""
}

function languagePrefix() {
if (conversationLanguage === "es") return "Continue in Spanish. "
return "Continue in English. "
}

function successMessage() {
if (conversationLanguage === "es") {
return "Gracias. Su solicitud de farmacia ha sido ingresada para revision del personal. Adios."
}

return "Thank you. Your pharmacy request has been entered for staff review. Goodbye."
}

function transferMessage() {
if (conversationLanguage === "es") {
return "Lo voy a transferir al personal de farmacia para ayudarle."
}

return "I will transfer you to pharmacy staff for help."
}

// Safety timeout. If the assistant gets stuck or caller is silent too long, transfer to staff.
// 240000 ms = 4 minutes.
var timer = setTimeout(function() {
console.log("Safety timeout reached. Transferring caller to pharmacy staff.")
transferInProgress = true
call.transfer(staffTransferDestination)
}, 240000)

call.http(onhttp)

function onhttp(args) {
console.log("OpenAI ringing...")
console.log(JSON.stringify(args))

var body = JSON.parse(args.body)
console.log("Body:")
console.log(JSON.stringify(body))

if (body.type == "realtime.call.incoming") {
var callid = body.data.call_id

```
console.log("Call id:")
console.log(callid)

system.http({
  method: "POST",
  url: "https://api.openai.com/v1/realtime/calls/" + callid + "/accept",
  header: [
    { name: "Authorization", value: "Bearer " + secret, secret: true },
    { name: "Content-Type", value: "application/json" }
  ],
  body: JSON.stringify({
    type: "realtime",
    model: "gpt-realtime",
    instructions: "You are the Vodia Pharmacy AI assistant."
  }),
  callback: function(code, response, headers) {
    console.log("OpenAI accept response code:")
    console.log(code)
    console.log("OpenAI accept response body:")
    console.log(response)

    connected(code, response, headers, callid)
  }
})
```

}
}

function connected(code, response, headers, callid) {
var ws = new Websocket("wss://api.openai.com/v1/realtime?call_id=" + callid)

ws.header([
{ name: "Authorization", value: "Bearer " + secret, secret: true },
{ name: "User-Agent", value: "Vodia-PBX/69.5.3" }
])

ws.on("open", function() {
console.log("Websocket opened")

```
var instructions =
  audioDirective +

  "\n\nYou are the Vodia Pharmacy AI assistant." +

  "\n\nLanguage rule:" +
  "\n- Start in English." +
  "\n- If the caller says Spanish, Espanol, or asks to continue in Spanish, call set_conversation_language with language es and continue in Spanish." +
  "\n- If the caller later asks for English, call set_conversation_language with language en and continue in English." +

  "\n\nYour job is to enter pharmacy requests for staff review." +

  "\n\nKnown customer rule:" +
  "\n- After you collect the callback phone number, call lookup_customer using callback_phone, customer_name if known, date_of_birth if known, and language." +
  "\n- If lookup_customer returns known_customer true, say only the returned greeting, then continue the intake." +
  "\n- Do not read insurance ID, member ID, BIN, PCN, prescription number, or private profile data out loud unless the caller provides it first." +
  "\n- If lookup_customer returns known_customer false, continue normally and still enter the request." +

  "\n\nYou can help with:" +
  "\n1. refill requests" +
  "\n2. medication requests" +
  "\n3. stock review questions" +

  "\n\nFake test pickup pharmacy locations:" +
  "\n- Lawrence: Vodia Test Pharmacy Lawrence, 69 Bailey Street, Lawrence, MA 01843." +
  "\n- Burlington: Vodia Test Pharmacy Burlington, 25 Network Way, Burlington, MA 01803." +
  "\n- Methuen: Vodia Test Pharmacy Methuen, 100 Demo Avenue, Methuen, MA 01844." +

  "\n\nRequired intake flow:" +
  "\n1. First identify the medication the caller is requesting." +
  "\n2. Ask for the caller's first and last name." +
  "\n3. Ask for date of birth." +
  "\n4. Ask for the best callback phone number including area code." +
  "\n5. Call lookup_customer after callback phone is collected." +
  "\n6. Ask for the full address, including street address, city, state, and 5-digit ZIP code." +
  "\n7. Ask one optional support question: Do you have a prescription number, prescribing doctor name, pharmacy name, or insurance information? If not, I can still enter the request for staff review." +
  "\n8. Ask: Would you prefer pickup at the pharmacy, delivery to your address, or no preference? I am only recording the preference for staff review." +
  "\n9. If pickup, ask which pickup location they prefer: Lawrence, Burlington, or Methuen. Then confirm the pickup store name and address." +
  "\n10. If delivery, say: I have your delivery address as the address you provided. Is that correct for delivery? Wait for yes." +
  "\n11. If the caller does not want pickup or delivery, set fulfillment_method to undecided." +
  "\n12. Never say the medication is ready, approved, shipped, guaranteed, available, or ready for pickup." +
  "\n13. Repeat the medication, first and last name, date of birth, callback number, full address, optional support detail, and pickup or delivery preference." +
  "\n14. In English ask: Does everything sound correct? Please say yes to confirm." +
  "\n15. In Spanish ask: Todo suena correcto? Por favor diga si para confirmar." +
  "\n16. After the caller confirms, call submit_pharmacy_request with caller_confirmed true and fulfillment_confirmed true." +

  "\n\nDo not submit the request after only hearing the medication name." +
  "\n\nDo not submit the request without first and last name." +
  "\n\nDo not submit the request without date of birth." +
  "\n\nDo not submit the request without a callback phone number that includes area code." +
  "\n\nDo not submit the request without a full address and a 5-digit ZIP code." +
  "\n\nDo not submit until the caller confirms the repeated information. caller_confirmed must be true only after confirmation." +
  "\n\nDo not submit until pickup/delivery preference has been asked. fulfillment_confirmed must be true only after the pickup/delivery question is answered." +

  "\n\nFulfillment rules:" +
  "\n- If the caller wants pickup, set fulfillment_method to pickup." +
  "\n- For pickup, set pickup_store_location to lawrence, burlington, or methuen." +
  "\n- If the caller wants delivery, set fulfillment_method to delivery." +
  "\n- For delivery, use the same full address collected from the caller as delivery_address." +
  "\n- For delivery, delivery_address_confirmed must be true only after the caller confirms the address is correct for delivery." +
  "\n- If the caller does not want pickup or delivery, set fulfillment_method to undecided." +
  "\n- Never say the medication is ready for pickup, shipped, approved, available, or guaranteed. You are only recording the preference for staff review." +

  "\n\nIf the caller gives only a first name, ask for their last name." +
  "\n\nIf the caller gives only 7 digits for the phone number, ask for the full phone number including area code." +
  "\n\nIf the ZIP code is missing or is not exactly 5 digits, ask for the 5-digit ZIP code." +

  "\n\nAddress validation is performed by the backend after submission using Smarty. The backend may tell staff whether the address was validated or needs review. Do not tell the caller that the address is guaranteed valid." +

  "\n\nIf the caller cannot provide first and last name, date of birth, callback number with area code, or full address with 5-digit ZIP code, say that pharmacy staff needs that information to follow up. Offer to transfer to staff. If yes, call transfer_call." +

  "\n\nAsk one question at a time. Keep the conversation short, calm, professional, and friendly." +

  "\n\nDo not provide medical advice. Do not discuss dosage instructions. Do not recommend medications. Do not say a medication is approved, ready, guaranteed, available, or ready for pickup. Do not promise pickup times." +

  "\n\nIf medication is not found or is out of stock, still submit the request after mandatory information is collected. Do not mention alternatives, substitutions, possible options, special ordering, availability, pickup status, or delivery status to the caller." +

  "\n\nIf the caller asks for a pharmacist, staff member, emergency help, side effects, dosage questions, new prescription questions, insurance issues, clinical questions, or anything you cannot safely handle, call transfer_call." +

  "\n\nAfter submit_pharmacy_request returns a result, do not repeat long backend wording." +
  "\n\nIn English say exactly: Thank you. Your pharmacy request has been entered for staff review. Goodbye." +
  "\n\nIn Spanish say exactly: Gracias. Su solicitud de farmacia ha sido ingresada para revision del personal. Adios." +
  "\n\nThen immediately call end_call with reason request_completed. Do not ask if there is anything else. Do not continue the conversation." +

  "\n\nIf the backend response says transfer_to_staff is true, say a short transfer message, then call transfer_call using destination " + staffTransferDestination + "."

var update = {
  type: "session.update",
  session: {
    type: "realtime",
    instructions: instructions,
    tools: [
      {
        type: "function",
        name: "set_conversation_language",
        description: "Sets the active spoken language for this call.",
        parameters: {
          type: "object",
          properties: {
            language: {
              type: "string",
              enum: ["en", "es"],
              description: "Use en for English or es for Spanish."
            }
          },
          required: ["language"]
        }
      },
      {
        type: "function",
        name: "lookup_customer",
        description: "Looks up whether the caller is a known customer by callback phone, or by name and date of birth when available.",
        parameters: {
          type: "object",
          properties: {
            callback_phone: {
              type: "string",
              description: "Caller callback phone number, preferably including area code."
            },
            customer_name: {
              type: "string",
              description: "Caller full name if known."
            },
            date_of_birth: {
              type: "string",
              description: "Caller date of birth if known."
            },
            language: {
              type: "string",
              enum: ["en", "es"],
              description: "Current conversation language."
            }
          },
          required: ["callback_phone"]
        }
      },
      {
        type: "function",
        name: "submit_pharmacy_request",
        description: "Submit a pharmacy refill, medication request, or stock review request to the backend. Only use after collecting medication, first and last name, date of birth, callback phone with area code, full address with 5-digit ZIP code, optional support detail if provided, pickup/delivery preference, and caller confirmation.",
        parameters: {
          type: "object",
          properties: {
            request_type: {
              type: "string",
              enum: ["refill", "medication_order", "stock_question"],
              description: "Type of pharmacy request. Use medication_order if unsure."
            },
            customer_name: {
              type: "string",
              description: "Caller full name. Must include first and last name."
            },
            callback_phone: {
              type: "string",
              description: "Caller callback phone number. Must include area code. Prefer E.164 format like +19785551234."
            },
            date_of_birth: {
              type: "string",
              description: "Caller date of birth."
            },
            address: {
              type: "string",
              description: "Caller full address including street, city, state, and exactly 5-digit ZIP code."
            },
            medication: {
              type: "string",
              description: "Medication name the caller is asking about."
            },
            quantity_requested: {
              type: "number",
              description: "Quantity requested if provided. Use 1 if unknown."
            },
            customer_question: {
              type: "string",
              description: "Short question from the caller for pharmacy staff."
            },
            notes: {
              type: "string",
              description: "Any short notes for pharmacy staff."
            },
            rx_number: {
              type: "string",
              description: "Prescription number if the caller provides it."
            },
            prescriber_name: {
              type: "string",
              description: "Prescribing doctor name if the caller provides it."
            },
            pharmacy_name: {
              type: "string",
              description: "Pharmacy name if the caller provides it."
            },
            insurance_provider: {
              type: "string",
              description: "Insurance provider if the caller provides it."
            },
            insurance_member_id: {
              type: "string",
              description: "Insurance member ID if the caller provides it."
            },
            insurance_group_number: {
              type: "string",
              description: "Insurance group number if the caller provides it."
            },
            insurance_bin: {
              type: "string",
              description: "Insurance BIN if the caller provides it."
            },
            insurance_pcn: {
              type: "string",
              description: "Insurance PCN if the caller provides it."
            },
            fulfillment_method: {
              type: "string",
              enum: ["pickup", "delivery", "undecided"],
              description: "Caller fulfillment preference. Use pickup if they want to pick up at the pharmacy. Use delivery if they want delivery. Use undecided if they do not choose either."
            },
            pickup_store_location: {
              type: "string",
              enum: ["lawrence", "burlington", "methuen", "unknown"],
              description: "Pickup store location if fulfillment_method is pickup."
            },
            pickup_store_code: {
              type: "string",
              description: "Pickup store code if known, such as LAWRENCE-DEMO, BURLINGTON-DEMO, or METHUEN-DEMO."
            },
            pickup_store_name: {
              type: "string",
              description: "Pickup store name if known."
            },
            pickup_store_address: {
              type: "string",
              description: "Pickup store address if known."
            },
            delivery_address: {
              type: "string",
              description: "Delivery address if fulfillment_method is delivery. Use the collected customer address unless caller gives a different delivery address."
            },
            delivery_address_confirmed: {
              type: "boolean",
              description: "True only after caller confirms the delivery address is correct."
            },
            delivery_instructions: {
              type: "string",
              description: "Optional delivery instructions if the caller provides them."
            },
            fulfillment_confirmed: {
              type: "boolean",
              description: "True only after caller answers pickup/delivery preference."
            },
            caller_confirmed: {
              type: "boolean",
              description: "Must be true only after caller confirms the repeated details are correct."
            }
          },
          required: [
            "medication",
            "customer_name",
            "callback_phone",
            "date_of_birth",
            "address",
            "fulfillment_method",
            "fulfillment_confirmed",
            "caller_confirmed"
          ]
        }
      },
      {
        type: "function",
        name: "transfer_call",
        description: "Transfers the active SIP call to pharmacy staff.",
        parameters: {
          type: "object",
          properties: {
            destination: {
              type: "string",
              description: "Extension or phone number to transfer to."
            }
          },
          required: ["destination"]
        }
      },
      {
        type: "function",
        name: "end_call",
        description: "Gracefully ends the active SIP call after the goodbye message.",
        parameters: {
          type: "object",
          properties: {
            reason: {
              type: "string",
              description: "Reason for ending the call."
            }
          },
          required: ["reason"]
        }
      }
    ],
    tool_choice: "auto"
  }
}

ws.send(JSON.stringify(update))

ws.send(JSON.stringify({
  type: "response.create",
  response: {
    instructions: "Greet with: " + text("initial")
  }
}))
```

})

ws.on("close", function() {
console.log("Websocket closed")
})

ws.on("message", function(message) {
var evt

```
try {
  evt = JSON.parse(message)
} catch (e) {
  console.log("Could not parse websocket message:")
  console.log(message)
  return
}

if (
  evt.type === "response.output_item.done" &&
  evt.item &&
  evt.item.type === "function_call"
) {
  var functionName = evt.item.name
  var functionArgs = {}

  try {
    functionArgs = JSON.parse(evt.item.arguments || "{}")
  } catch (e1) {
    console.log("Could not parse function arguments:")
    console.log(evt.item.arguments)
    functionArgs = {}
  }

  if (functionName === "set_conversation_language") {
    handleSetConversationLanguage(ws, evt.item.call_id, functionArgs)
    return
  }

  if (functionName === "lookup_customer") {
    handleLookupCustomer(ws, evt.item.call_id, functionArgs)
    return
  }

  if (functionName === "transfer_call") {
    handleTransferCall(ws, functionArgs)
    return
  }

  if (functionName === "end_call") {
    handleEndCall(ws, functionArgs)
    return
  }

  if (functionName === "submit_pharmacy_request") {
    handleSubmitPharmacyRequest(ws, evt.item.call_id, functionArgs)
    return
  }
}
```

})

ws.connect()
}

function handleSetConversationLanguage(ws, callId, args) {
var language = String(args.language || "en").trim().toLowerCase()

if (language !== "es" && language !== "en") {
language = "en"
}

conversationLanguage = language

sendFunctionOutput(ws, callId, {
success: true,
language: conversationLanguage
})

ws.send(JSON.stringify({
type: "response.create",
response: {
instructions: languagePrefix() + "Continue the conversation in the selected language. Ask the next needed intake question."
}
}))
}

function handleLookupCustomer(ws, callId, args) {
var callbackPhone = normalizePhoneE164(args.callback_phone || "")
var customerName = String(args.customer_name || "").trim()
var dateOfBirth = String(args.date_of_birth || "").trim()

system.http({
method: "POST",
url: customerLookupUrl,
header: [
{ name: "Content-Type", value: "application/json" },
{ name: "X-Pharmacy-Secret", value: pharmacyApiSecret, secret: true }
],
body: JSON.stringify({
callback_phone: callbackPhone,
customer_name: customerName,
date_of_birth: dateOfBirth,
language: conversationLanguage
}),
callback: function(code, response, headers) {
console.log("Customer lookup response code:")
console.log(code)
console.log("Customer lookup response:")
console.log(response)

```
  var output

  try {
    output = JSON.parse(response || "{}")
  } catch (e) {
    output = {
      success: false,
      lookup: {
        known_customer: false,
        greeting: "",
        profile: null
      }
    }
  }

  if (!output.lookup) {
    output.lookup = {
      known_customer: false,
      greeting: "",
      profile: null
    }
  }

  if (output.lookup.known_customer === true && output.lookup.profile) {
    knownCustomerProfile = output.lookup.profile
    knownCustomerGreeting = String(output.lookup.greeting || "").trim()
  } else {
    knownCustomerProfile = null
    knownCustomerGreeting = ""
  }

  sendFunctionOutput(ws, callId, output)

  var nextInstruction

  if (knownCustomerProfile && knownCustomerGreeting) {
    nextInstruction =
      languagePrefix() +
      "Say exactly this greeting: " +
      JSON.stringify(knownCustomerGreeting) +
      " Then continue with the next missing intake question. Do not read private insurance, prescription, or member details out loud."
  } else {
    nextInstruction =
      languagePrefix() +
      "Continue the intake normally. Do not say the customer was not found. Ask the next missing intake question."
  }

  ws.send(JSON.stringify({
    type: "response.create",
    response: {
      instructions: nextInstruction
    }
  }))
}
```

})
}

function normalizePhoneE164(phone) {
var raw = String(phone || "").trim()

if (!raw || raw === "UNKNOWN") return "UNKNOWN"

if (raw.charAt(0) === "+") {
var plusDigits = raw.replace(/\D/g, "")
if (plusDigits.length >= 8 && plusDigits.length <= 15) {
return "+" + plusDigits
}
return raw
}

var digits = raw.replace(/\D/g, "")

if (digits.length === 10) {
return "+1" + digits
}

if (digits.length === 11 && digits.charAt(0) === "1") {
return "+" + digits
}

if (digits.length >= 8 && digits.length <= 15) {
return "+" + digits
}

return raw || "UNKNOWN"
}

function hasFirstAndLastName(name) {
var clean = String(name || "").trim()

if (!clean || clean === "Unknown Caller" || clean === "UNKNOWN") {
return false
}

var parts = clean.split(/\s+/).filter(Boolean)
return parts.length >= 2
}

function hasDateOfBirth(dob) {
var clean = String(dob || "").trim()

if (!clean || clean === "UNKNOWN") {
return false
}

return /\d/.test(clean) && clean.length >= 4
}

function hasPhoneWithAreaCode(phone) {
var raw = String(phone || "").trim()

if (!raw || raw === "UNKNOWN") {
return false
}

var digits = raw.replace(/\D/g, "")

if (digits.length === 10) {
return true
}

if (digits.length === 11 && digits.charAt(0) === "1") {
return true
}

return false
}

function hasFiveDigitZip(address) {
var raw = String(address || "").trim()

if (!raw || raw === "UNKNOWN") {
return false
}

return /\b\d{5}\b/.test(raw)
}

function boolValue(value) {
if (value === true || value === 1 || value === "1") return true

var raw = String(value || "").toLowerCase().trim()

if (raw === "true" || raw === "yes" || raw === "y" || raw === "si" || raw === "sí") {
return true
}

return false
}

function normalizeFulfillmentMethod(method) {
var raw = String(method || "").toLowerCase().trim()

if (raw === "pickup") return "pickup"
if (raw === "delivery") return "delivery"

return "undecided"
}

function resolvePickupStore(input) {
var raw = String(input || "").toLowerCase().trim()

if (!raw) return null

if (raw.indexOf("lawrence") >= 0 || raw === "lawrence-demo") {
return pharmacyStores.lawrence
}

if (raw.indexOf("burlington") >= 0 || raw === "burlington-demo") {
return pharmacyStores.burlington
}

if (raw.indexOf("methuen") >= 0 || raw === "methuen-demo") {
return pharmacyStores.methuen
}

return null
}

function handleTransferCall(ws, args) {
var destination = String(args.destination || staffTransferDestination).trim()

if (!destination) {
destination = staffTransferDestination
}

console.log("Transfer to destination:")
console.log(destination)

transferInProgress = true
clearTimeout(timer)

try {
call.transfer(destination)
} catch (e) {
console.log("Transfer failed: " + e.message)
transferInProgress = false
}
}

function handleEndCall(ws, args) {
console.log("Ending call:")
console.log(JSON.stringify(args))

if (transferInProgress === true) {
console.log("Transfer in progress. Skipping hangup.")
return
}

clearTimeout(timer)

setTimeout(function() {
if (transferInProgress === true) {
console.log("Transfer started during goodbye wait. Skipping hangup.")
return
}

```
try {
  console.log("Closing WebSocket before hangup")
  ws.close()
} catch (e) {
  console.log("WebSocket close failed: " + e.message)
}

call.hangup()
```

}, 8000)
}

function handleSubmitPharmacyRequest(ws, callId, args) {
console.log("Submitting pharmacy request to backend...")
console.log(JSON.stringify(args))

var requestType = String(args.request_type || "medication_order").trim()
var customerName = String(args.customer_name || "").trim()
var callbackPhoneRaw = String(args.callback_phone || "").trim()
var callbackPhone = normalizePhoneE164(callbackPhoneRaw)
var dateOfBirth = String(args.date_of_birth || "UNKNOWN").trim()
var address = String(args.address || "").trim()
var medication = String(args.medication || "").trim()
var quantityRequested = Number(args.quantity_requested || 1)
var customerQuestion = String(args.customer_question || "").trim()
var notes = String(args.notes || "").trim()
var callerConfirmed = boolValue(args.caller_confirmed)

var rxNumber = String(args.rx_number || "").trim()
var prescriberName = String(args.prescriber_name || "").trim()
var pharmacyName = String(args.pharmacy_name || "").trim()
var insuranceProvider = String(args.insurance_provider || "").trim()
var insuranceMemberId = String(args.insurance_member_id || "").trim()
var insuranceGroupNumber = String(args.insurance_group_number || "").trim()
var insuranceBin = String(args.insurance_bin || "").trim()
var insurancePcn = String(args.insurance_pcn || "").trim()

var fulfillmentMethod = normalizeFulfillmentMethod(args.fulfillment_method)
var fulfillmentConfirmed = boolValue(args.fulfillment_confirmed)

var pickupStoreLocation = String(args.pickup_store_location || "").trim()
var pickupStoreCode = String(args.pickup_store_code || "").trim()
var pickupStoreName = String(args.pickup_store_name || "").trim()
var pickupStoreAddress = String(args.pickup_store_address || "").trim()

var deliveryAddress = String(args.delivery_address || "").trim()
var deliveryAddressConfirmed = boolValue(args.delivery_address_confirmed)
var deliveryInstructions = String(args.delivery_instructions || "").trim()

if (!requestType) {
requestType = "medication_order"
}

if (
requestType !== "refill" &&
requestType !== "medication_order" &&
requestType !== "stock_question"
) {
requestType = "medication_order"
}

if (!quantityRequested || quantityRequested < 1) {
quantityRequested = 1
}

if (!medication) {
return askAgain(ws, callId, "missing_medication", "I need the medication name so I can enter the request for pharmacy staff.", "Ask only for the medication name.")
}

if (!hasFirstAndLastName(customerName)) {
return askAgain(ws, callId, "missing_first_last_name", "I need your first and last name so pharmacy staff can follow up with you.", "Ask for their first and last name.")
}

if (!hasDateOfBirth(dateOfBirth)) {
return askAgain(ws, callId, "missing_date_of_birth", "I need your date of birth so pharmacy staff can verify the request.", "Ask for their date of birth.")
}

if (!hasPhoneWithAreaCode(callbackPhoneRaw)) {
return askAgain(ws, callId, "missing_phone_area_code", "I need the full callback phone number including area code.", "Ask for the full callback phone number including area code.")
}

if (!hasFiveDigitZip(address)) {
return askAgain(ws, callId, "missing_five_digit_zip", "I need the 5-digit ZIP code for the address.", "Ask for the full address again, including the 5-digit ZIP code.")
}

if (!fulfillmentConfirmed) {
return askAgain(
ws,
callId,
"missing_fulfillment_preference",
"I need to know whether you prefer pickup, delivery, or no preference.",
"Ask: Would you prefer pickup at the pharmacy, delivery to your address, or no preference? Explain that you are only recording the preference for staff review."
)
}

if (fulfillmentMethod === "pickup") {
var store = resolvePickupStore(pickupStoreLocation || pickupStoreCode || pickupStoreName)

```
if (store) {
  pickupStoreCode = store.store_code
  pickupStoreName = store.store_name
  pickupStoreAddress = store.full_address
}

if (!pickupStoreName || !pickupStoreAddress) {
  return askAgain(
    ws,
    callId,
    "missing_pickup_store",
    "I need to know which pharmacy location you prefer for pickup.",
    "Ask which pickup location they prefer: Lawrence, Burlington, or Methuen."
  )
}
```

}

if (fulfillmentMethod === "delivery") {
if (!deliveryAddress) {
deliveryAddress = address
}

```
if (!deliveryAddressConfirmed) {
  return askAgain(
    ws,
    callId,
    "missing_delivery_address_confirmation",
    "I need you to confirm the delivery address before I enter the request.",
    "Repeat the delivery address and ask: Is this correct for delivery?"
  )
}
```

}

if (!callerConfirmed) {
return askAgain(
ws,
callId,
"missing_confirmation",
"Before I enter the request, I need you to confirm that the information I repeated is correct.",
"Repeat the medication, first and last name, date of birth, callback number, full address, optional support detail, and pickup or delivery preference. Then ask: Does everything sound correct? Please say yes to confirm."
)
}

system.http({
method: "POST",
url: pharmacyRequestUrl,
header: [
{ name: "Content-Type", value: "application/json" },
{ name: "X-Pharmacy-Secret", value: pharmacyApiSecret, secret: true }
],
body: JSON.stringify({
request_type: requestType,
customer_name: customerName,
callback_phone: callbackPhone,
date_of_birth: dateOfBirth,
address: address,
medication: medication,
quantity_requested: quantityRequested,
customer_question: customerQuestion,
notes: notes
}),
callback: function(code, response, headers) {
console.log("Pharmacy backend response code:")
console.log(code)

```
  console.log("Pharmacy backend response:")
  console.log(response)

  var output

  try {
    output = JSON.parse(response || "{}")
  } catch (e) {
    output = {
      success: false,
      transfer_to_staff: true,
      reason: "invalid_backend_response",
      ai_say: "I am having trouble submitting your request right now. I will transfer you to pharmacy staff for help."
    }
  }

  if (code < 200 || code >= 300) {
    if (!output.ai_say) {
      output.ai_say = "I am having trouble submitting your request right now. I will transfer you to pharmacy staff for help."
    }

    output.transfer_to_staff = true
  }

  sendFunctionOutput(ws, callId, output)

  var requestId = extractRequestId(output)

  if (requestId) {
    enrichPharmacyRequest({
      request_id: requestId,
      customer_name: customerName,
      callback_phone: callbackPhone,
      date_of_birth: dateOfBirth,
      language: conversationLanguage,
      customer_profile_id: knownCustomerProfile ? knownCustomerProfile.id : "",
      rx_number: rxNumber,
      prescriber_name: prescriberName,
      pharmacy_name: pharmacyName,
      insurance_provider: insuranceProvider,
      insurance_member_id: insuranceMemberId,
      insurance_group_number: insuranceGroupNumber,
      insurance_bin: insuranceBin,
      insurance_pcn: insurancePcn
    })

    updateRequestFulfillment({
      request_id: requestId,
      fulfillment_method: fulfillmentMethod,
      pickup_requested: fulfillmentMethod === "pickup",
      delivery_requested: fulfillmentMethod === "delivery",
      pickup_store_code: pickupStoreCode,
      pickup_store_name: pickupStoreName,
      pickup_store_address: pickupStoreAddress,
      delivery_address: fulfillmentMethod === "delivery" ? deliveryAddress : "",
      delivery_address_confirmed: fulfillmentMethod === "delivery" ? deliveryAddressConfirmed : false,
      delivery_instructions: deliveryInstructions,
      fulfillment_confirmed: fulfillmentConfirmed,
      fulfillment_notes: buildFulfillmentNotes(fulfillmentMethod, pickupStoreName, deliveryAddress)
    })
  } else {
    console.log("No request id returned from intake. Cannot update enrichment or fulfillment.")
  }

  var sayInstruction =
    languagePrefix() +
    "Say exactly to the caller: " +
    JSON.stringify(successMessage()) +
    " Then call end_call with reason request_completed. Do not ask if there is anything else. Do not mention alternatives, substitutions, possible options, medication availability, inventory status, pickup readiness, delivery shipping, or special ordering."

  if (output.transfer_to_staff === true) {
    sayInstruction =
      languagePrefix() +
      "Say exactly to the caller: " +
      JSON.stringify(transferMessage()) +
      " Then call transfer_call with destination " +
      staffTransferDestination +
      "."
  }

  ws.send(JSON.stringify({
    type: "response.create",
    response: {
      instructions: sayInstruction
    }
  }))
}
```

})
}

function buildFulfillmentNotes(method, pickupStoreName, deliveryAddress) {
if (method === "pickup") {
return "Caller requested pickup at " + String(pickupStoreName || "selected pharmacy") + "."
}

if (method === "delivery") {
return "Caller requested delivery to confirmed address: " + String(deliveryAddress || "") + "."
}

return "Caller did not choose pickup or delivery."
}

function extractRequestId(output) {
if (!output) return ""

return String(
output.request_id ||
output.refill_request_id ||
output.id ||
""
).trim()
}

function enrichPharmacyRequest(payload) {
system.http({
method: "POST",
url: customerEnrichUrl,
header: [
{ name: "Content-Type", value: "application/json" },
{ name: "X-Pharmacy-Secret", value: pharmacyApiSecret, secret: true }
],
body: JSON.stringify(payload),
callback: function(code, response, headers) {
console.log("Customer enrich response code:")
console.log(code)
console.log("Customer enrich response:")
console.log(response)
}
})
}

function updateRequestFulfillment(payload) {
system.http({
method: "POST",
url: fulfillmentUrl,
header: [
{ name: "Content-Type", value: "application/json" },
{ name: "X-Pharmacy-Secret", value: pharmacyApiSecret, secret: true }
],
body: JSON.stringify(payload),
callback: function(code, response, headers) {
console.log("Fulfillment update response code:")
console.log(code)
console.log("Fulfillment update response:")
console.log(response)
}
})
}

function askAgain(ws, callId, reason, aiSay, nextInstruction) {
var output = {
success: false,
transfer_to_staff: false,
reason: reason,
ai_say: aiSay
}

sendFunctionOutput(ws, callId, output)

ws.send(JSON.stringify({
type: "response.create",
response: {
instructions: languagePrefix() + "Tell the caller: " + JSON.stringify(aiSay) + " " + nextInstruction
}
}))
}

function sendFunctionOutput(ws, callId, output) {
if (!callId) {
console.log("Missing function call_id. Cannot send function output.")
return
}

var toolOutputEvent = {
type: "conversation.item.create",
item: {
type: "function_call_output",
call_id: callId,
output: JSON.stringify(output)
}
}

ws.send(JSON.stringify(toolOutputEvent))
}

call.dial("openai")
