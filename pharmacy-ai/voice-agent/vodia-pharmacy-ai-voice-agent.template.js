// OpenAI integration through SIP
// Vodia Pharmacy AI Request Intake - Known Customer + CVS/Walgreens Pickup + Delivery Version
'use strict'

// OpenAI key is injected by Vodia from the Voice Agent OpenAI key field.
var secret = typeof secret !== "undefined" ? secret : ""

// Pharmacy backend settings
var pharmacyApiSecret = "__PHARMACY_API_SECRET__"

var pharmacyRequestUrl = "__PHARMACY_BASE_URL__/api/ai/refill-intake"
var customerLookupUrl = "__PHARMACY_BASE_URL__/api/ai/customer-lookup"
var customerEnrichUrl = "__PHARMACY_BASE_URL__/api/ai/refill-request-enrich"
var fulfillmentUrl = "__PHARMACY_BASE_URL__/api/ai/request-fulfillment"
var pharmacyLocationSearchUrl = "__PHARMACY_BASE_URL__/api/ai/pharmacy-location-search"

var staffTransferDestination = "__STAFF_TRANSFER_DESTINATION__"

var conversationLanguage = "en"
var knownCustomerProfile = null
var knownCustomerGreeting = ""
var transferInProgress = false
var lastPharmacyLocationOptions = []
var selectedPickupOption = null
var allowDemoPharmacyFallback = true

var DRUG_CLASSIFICATIONS = [
  { name: "heroin", schedule: "I", action: "block" },
  { name: "marijuana", schedule: "I", action: "block" },
  { name: "cannabis", schedule: "I", action: "block" },
  { name: "lsd", schedule: "I", action: "block" },
  { name: "mdma", schedule: "I", action: "block" },
  { name: "ecstasy", schedule: "I", action: "block" },
  { name: "molly", schedule: "I", action: "block" },
  { name: "psilocybin", schedule: "I", action: "block" },
  { name: "mushrooms", schedule: "I", action: "block" },
  { name: "shrooms", schedule: "I", action: "block" },
  { name: "crack", schedule: "I", action: "block" },
  { name: "weed", schedule: "I", action: "block" },
  { name: "pot", schedule: "I", action: "block" },
  { name: "oxy", schedule: "II", action: "review" },
  { name: "oxycodone", schedule: "II", action: "review" },
  { name: "oxycontin", schedule: "II", action: "review" },
  { name: "percocet", schedule: "II", action: "review" },
  { name: "fentanyl", schedule: "II", action: "review" },
  { name: "morphine", schedule: "II", action: "review" },
  { name: "hydrocodone", schedule: "II", action: "review" },
  { name: "vicodin", schedule: "II", action: "review" },
  { name: "norco", schedule: "II", action: "review" },
  { name: "adderall", schedule: "II", action: "review" },
  { name: "ritalin", schedule: "II", action: "review" },
  { name: "vyvanse", schedule: "II", action: "review" },
  { name: "cocaine", schedule: "II", action: "review" },
  { name: "suboxone", schedule: "III", action: "review" },
  { name: "buprenorphine", schedule: "III", action: "review" },
  { name: "ketamine", schedule: "III", action: "review" },
  { name: "xanax", schedule: "IV", action: "review" },
  { name: "alprazolam", schedule: "IV", action: "review" },
  { name: "valium", schedule: "IV", action: "review" },
  { name: "diazepam", schedule: "IV", action: "review" },
  { name: "klonopin", schedule: "IV", action: "review" },
  { name: "clonazepam", schedule: "IV", action: "review" },
  { name: "ativan", schedule: "IV", action: "review" },
  { name: "ambien", schedule: "IV", action: "review" },
  { name: "tramadol", schedule: "IV", action: "review" },
  { name: "bars", schedule: "IV", action: "review" },
  { name: "benzos", schedule: "IV", action: "review" },
  { name: "gabapentin", schedule: "V", action: "review" },
  { name: "lyrica", schedule: "V", action: "review" },
  { name: "pregabalin", schedule: "V", action: "review" }
]

function normalizeDrugName(name) {
  return String(name || "").toLowerCase().trim().replace(/\s+/g, " ")
}

function checkDrugClassification(medicationName) {
  var normalized = normalizeDrugName(medicationName)
  if (!normalized || normalized.length < 3) return { matched: false, action: "allow" }

  for (var i = 0; i < DRUG_CLASSIFICATIONS.length; i++) {
    var entry = DRUG_CLASSIFICATIONS[i]
    var entryName = normalizeDrugName(entry.name)
    if (!entryName || entryName.length < 3) continue

    var exactMatch = normalized === entryName
    var callerContainsEntry = false

    if (!exactMatch && entryName.length >= 4) {
      callerContainsEntry = (" " + normalized + " ").indexOf(" " + entryName + " ") !== -1
    }

    if (exactMatch || callerContainsEntry) {
      return {
        matched: true,
        drug_name: medicationName,
        matched_name: entry.name,
        schedule: entry.schedule,
        action: entry.action,
        reason: entry.action === "block"
          ? "Schedule " + entry.schedule + " controlled substance. Blocking AI intake."
          : "Schedule " + entry.schedule + " controlled substance. Routing for pharmacist review."
      }
    }
  }

  return { matched: false, action: "allow" }
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
  if (conversationLanguage === "es") return "Gracias. Su solicitud de farmacia ha sido ingresada para revision del personal. Adios."
  return "Thank you. Your pharmacy request has been entered for staff review. Goodbye."
}

function transferMessage() {
  if (conversationLanguage === "es") return "Lo voy a transferir al personal de farmacia para ayudarle."
  return "I will transfer you to pharmacy staff for help."
}

var timer = setTimeout(function() {
  console.log("Safety timeout reached. Transferring caller to pharmacy staff.")
  transferInProgress = true
  call.transfer(staffTransferDestination)
}, 240000)

call.http(onhttp)

function onhttp(args) {
  console.log("OpenAI ringing...")
  console.log(JSON.stringify(args))

  var body = {}
  try {
    body = JSON.parse(args.body || "{}")
  } catch (e) {
    console.log("Could not parse incoming HTTP body: " + e.message)
    return
  }

  if (body.type == "realtime.call.incoming") {
    var callid = body.data.call_id

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
        connected(code, response, headers, callid)
      }
    })
  }
}

function connected(code, response, headers, callid) {
  if (code < 200 || code >= 300) {
    console.log("OpenAI accept failed. Transferring to staff.")
    transferInProgress = true
    clearTimeout(timer)
    call.transfer(staffTransferDestination)
    return
  }

  var ws = new Websocket("wss://api.openai.com/v1/realtime?call_id=" + callid)

  ws.header([
    { name: "Authorization", value: "Bearer " + secret, secret: true },
    { name: "User-Agent", value: "Vodia-PBX/70.0" }
  ])

  ws.on("open", function() {
    console.log("Websocket opened")

    var instructions =
      audioDirective +
      "\n\nYou are the Vodia Pharmacy AI assistant." +
      "\n\nStart in English. If the caller asks for Spanish or says Espanol, call set_conversation_language with language es." +
      "\n\nYour job is to enter pharmacy requests for staff review." +
      "\n\nIf the caller says they are calling back, checking status, following up, or asking about a previous request, first verify callback phone, date of birth, and address, then call lookup_previous_pharmacy_request." +
      "\n\nRequired new request intake flow:" +
      "\n1. Identify the medication." +
      "\n2. Ask for first and last name." +
      "\n3. Ask for date of birth." +
      "\n4. Ask for callback phone number including area code." +
      "\n5. Call lookup_customer after callback phone is collected." +
      "\n6. Ask for full address with street, city, state, and 5-digit ZIP code." +
      "\n7. Ask optional support details: prescription number, doctor name, pharmacy name, or insurance information." +
      "\n8. Ask exactly: Would you prefer delivery to your address, pickup at a pharmacy, or no preference? I am only recording the preference for staff review." +
      "\n9. If pickup, ask if they prefer CVS, Walgreens, or no preference, then call search_pharmacy_locations using ZIP and chain_preference." +
      "\n10. Read up to three location options. After the caller chooses a number, call select_pharmacy_location." +
      "\n11. Repeat all details and ask: Does everything sound correct? Please say yes to confirm." +
      "\n12. Submit only after caller confirms." +
      "\n\nFor delivery, use the collected address as delivery_address. The final recap yes counts as delivery address confirmation." +
      "\n\nFor pickup, do not submit until select_pharmacy_location has confirmed the selected option." +
      "\n\nNever say medication is ready, approved, available, shipped, guaranteed, or ready for pickup." +
      "\n\nDo not provide medical advice, dosage advice, or medication recommendations." +
      "\n\nControlled substance rule: Schedule I requests must not be processed. Offer transfer to a pharmacist. Schedule II-V requests may be collected but must be flagged for pharmacist review." +
      "\n\nIf caller asks for pharmacist, emergency help, side effects, dosage, new prescription questions, clinical questions, or anything unsafe, call transfer_call." +
      "\n\nAfter submit_pharmacy_request succeeds, say exactly: " + JSON.stringify(successMessage()) + " Then call end_call with reason request_completed." +
      "\n\nIf backend says transfer_to_staff true, say exactly: " + JSON.stringify(transferMessage()) + " Then call transfer_call using destination " + staffTransferDestination + "."

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
                language: { type: "string", enum: ["en", "es"] }
              },
              required: ["language"]
            }
          },
          {
            type: "function",
            name: "lookup_customer",
            description: "Looks up whether the caller is a known customer.",
            parameters: {
              type: "object",
              properties: {
                callback_phone: { type: "string" },
                customer_name: { type: "string" },
                date_of_birth: { type: "string" },
                language: { type: "string", enum: ["en", "es"] }
              },
              required: ["callback_phone"]
            }
          },
          {
            type: "function",
            name: "lookup_previous_pharmacy_request",
            description: "Looks up the caller's previous pharmacy request.",
            parameters: {
              type: "object",
              properties: {
                callback_phone: { type: "string" },
                date_of_birth: { type: "string" },
                address: { type: "string" },
                customer_name: { type: "string" }
              },
              required: ["callback_phone", "date_of_birth", "address"]
            }
          },
          {
            type: "function",
            name: "search_pharmacy_locations",
            description: "Searches for CVS, Walgreens, or any pharmacy options near caller ZIP code.",
            parameters: {
              type: "object",
              properties: {
                zip: { type: "string" },
                city: { type: "string" },
                state: { type: "string" },
                chain_preference: { type: "string", enum: ["cvs", "walgreens", "any"] }
              },
              required: ["zip", "chain_preference"]
            }
          },
          {
            type: "function",
            name: "select_pharmacy_location",
            description: "Confirms the caller's chosen pickup pharmacy from search results.",
            parameters: {
              type: "object",
              properties: {
                option_number: { type: "number" }
              },
              required: ["option_number"]
            }
          },
          {
            type: "function",
            name: "leave_status_callback_note",
            description: "Leaves a status callback note for pharmacy staff.",
            parameters: {
              type: "object",
              properties: {
                request_id: { type: "string" },
                callback_phone: { type: "string" },
                customer_name: { type: "string" },
                caller_message: { type: "string" }
              },
              required: ["request_id", "callback_phone"]
            }
          },
          {
            type: "function",
            name: "submit_pharmacy_request",
            description: "Submit pharmacy request after mandatory details, fulfillment preference, and confirmation.",
            parameters: {
              type: "object",
              properties: {
                request_type: { type: "string", enum: ["refill", "medication_order", "stock_question"] },
                customer_name: { type: "string" },
                callback_phone: { type: "string" },
                date_of_birth: { type: "string" },
                address: { type: "string" },
                medication: { type: "string" },
                quantity_requested: { type: "number" },
                customer_question: { type: "string" },
                notes: { type: "string" },
                rx_number: { type: "string" },
                prescriber_name: { type: "string" },
                pharmacy_name: { type: "string" },
                insurance_provider: { type: "string" },
                insurance_member_id: { type: "string" },
                insurance_group_number: { type: "string" },
                insurance_bin: { type: "string" },
                insurance_pcn: { type: "string" },
                fulfillment_method: { type: "string", enum: ["pickup", "delivery", "undecided"] },
                chain_preference: { type: "string", enum: ["cvs", "walgreens", "any", "none"] },
                delivery_address: { type: "string" },
                delivery_address_confirmed: { type: "boolean" },
                delivery_instructions: { type: "string" },
                fulfillment_confirmed: { type: "boolean" },
                caller_confirmed: { type: "boolean" }
              },
              required: ["medication", "customer_name", "callback_phone", "date_of_birth", "address", "pharmacy_name", "fulfillment_method", "fulfillment_confirmed", "caller_confirmed"]
            }
          },
          {
            type: "function",
            name: "transfer_call",
            description: "Transfers the active SIP call to pharmacy staff.",
            parameters: {
              type: "object",
              properties: {
                destination: { type: "string" }
              },
              required: ["destination"]
            }
          },
          {
            type: "function",
            name: "end_call",
            description: "Gracefully ends the active SIP call.",
            parameters: {
              type: "object",
              properties: {
                reason: { type: "string" }
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
      response: { instructions: "Greet with: " + text("initial") }
    }))
  })

  ws.on("close", function() {
    console.log("Websocket closed")
  })

  ws.on("message", function(message) {
    var evt

    try {
      evt = JSON.parse(message)
    } catch (e) {
      console.log("Could not parse websocket message:")
      console.log(message)
      return
    }

    if (evt.type === "response.output_item.done" && evt.item && evt.item.type === "function_call") {
      var functionName = evt.item.name
      var callId = evt.item.call_id
      var functionArgs = {}

      try {
        functionArgs = JSON.parse(evt.item.arguments || "{}")
      } catch (e1) {
        console.log("Could not parse function arguments:")
        console.log(evt.item.arguments)
      }

      if (functionName === "set_conversation_language") return handleSetConversationLanguage(ws, callId, functionArgs)
      if (functionName === "lookup_customer") return handleLookupCustomer(ws, callId, functionArgs)
      if (functionName === "lookup_previous_pharmacy_request") return handleLookupPreviousPharmacyRequest(ws, callId, functionArgs)
      if (functionName === "leave_status_callback_note") return handleLeaveStatusCallbackNote(ws, callId, functionArgs)
      if (functionName === "search_pharmacy_locations") return handleSearchPharmacyLocations(ws, callId, functionArgs)
      if (functionName === "select_pharmacy_location") return handleSelectPharmacyLocation(ws, callId, functionArgs)
      if (functionName === "transfer_call") return handleTransferCall(ws, callId, functionArgs)
      if (functionName === "end_call") return handleEndCall(ws, callId, functionArgs)
      if (functionName === "submit_pharmacy_request") return handleSubmitPharmacyRequest(ws, callId, functionArgs)
    }
  })

  ws.connect()
}

function handleSetConversationLanguage(ws, callId, args) {
  var language = String(args.language || "en").trim().toLowerCase()
  if (language !== "es" && language !== "en") language = "en"
  conversationLanguage = language
  sendFunctionOutput(ws, callId, { success: true, language: conversationLanguage })
  ws.send(JSON.stringify({ type: "response.create", response: { instructions: languagePrefix() + "Continue in the selected language. Ask the next needed intake question." } }))
}

function handleLookupCustomer(ws, callId, args) {
  system.http({
    method: "POST",
    url: customerLookupUrl,
    header: [
      { name: "Content-Type", value: "application/json" },
      { name: "X-Pharmacy-Secret", value: pharmacyApiSecret, secret: true }
    ],
    body: JSON.stringify({
      callback_phone: normalizePhoneE164(args.callback_phone || ""),
      customer_name: String(args.customer_name || "").trim(),
      date_of_birth: String(args.date_of_birth || "").trim(),
      language: conversationLanguage
    }),
    callback: function(code, response, headers) {
      var output = parseJsonOrDefault(response, { success: false, lookup: { known_customer: false, greeting: "", profile: null } })
      if (!output.lookup) output.lookup = { known_customer: false, greeting: "", profile: null }

      if (output.lookup.known_customer === true && output.lookup.profile) {
        knownCustomerProfile = output.lookup.profile
        knownCustomerGreeting = String(output.lookup.greeting || "").trim()
      } else {
        knownCustomerProfile = null
        knownCustomerGreeting = ""
      }

      sendFunctionOutput(ws, callId, output)

      var instruction = knownCustomerGreeting
        ? languagePrefix() + "Say exactly this greeting: " + JSON.stringify(knownCustomerGreeting) + " Then continue with the next missing intake question."
        : languagePrefix() + "Continue normally. Do not say the customer was not found. Ask the next missing intake question."

      ws.send(JSON.stringify({ type: "response.create", response: { instructions: instruction } }))
    }
  })
}

function handleLookupPreviousPharmacyRequest(ws, callId, args) {
  system.http({
    method: "POST",
    url: pharmacyRequestUrl.replace("/refill-intake", "/previous-request-lookup"),
    header: [
      { name: "Content-Type", value: "application/json" },
      { name: "X-Pharmacy-Secret", value: pharmacyApiSecret, secret: true }
    ],
    body: JSON.stringify({
      callback_phone: normalizePhoneE164(args.callback_phone || ""),
      date_of_birth: String(args.date_of_birth || "").trim(),
      address: String(args.address || "").trim(),
      customer_name: String(args.customer_name || "").trim(),
      language: conversationLanguage
    }),
    callback: function(code, response, headers) {
      var output = parseJsonOrDefault(response, { success: false, found: false })
      sendFunctionOutput(ws, callId, output)

      var instruction = languagePrefix()
      if (output.success === true && output.found === true && output.last_request) {
        instruction += "Tell the caller you found their previous pharmacy request. Mention only medication name, request status, and pickup or delivery preference. Ask: Are you calling about this request?"
      } else {
        instruction += "Tell the caller you could not find a matching previous request with those verification details. Continue with a new pharmacy request intake."
      }

      ws.send(JSON.stringify({ type: "response.create", response: { instructions: instruction } }))
    }
  })
}

function handleLeaveStatusCallbackNote(ws, callId, args) {
  var callerText = String(args.caller_message || "Caller called in for status update.").trim()

  system.http({
    method: "POST",
    url: pharmacyRequestUrl.replace("/refill-intake", "/status-callback-note"),
    header: [
      { name: "Content-Type", value: "application/json" },
      { name: "X-Pharmacy-Secret", value: pharmacyApiSecret, secret: true }
    ],
    body: JSON.stringify({
      request_id: String(args.request_id || "").trim(),
      callback_phone: normalizePhoneE164(args.callback_phone || ""),
      customer_name: String(args.customer_name || "").trim(),
      caller_message: callerText,
      caller_summary: callerText,
      language: conversationLanguage,
      source: "vodia_ai_phone"
    }),
    callback: function(code, response, headers) {
      var output = parseJsonOrDefault(response, { success: false })
      sendFunctionOutput(ws, callId, output)

      var instruction = output.success === true
        ? languagePrefix() + "Tell the caller: I have left a note for the pharmacist that you called for a status update. Ask if there is anything else you can help with today."
        : languagePrefix() + "Tell the caller you were unable to leave a note at this time. Ask if they would like to be transferred to a pharmacist."

      ws.send(JSON.stringify({ type: "response.create", response: { instructions: instruction } }))
    }
  })
}

function handleSearchPharmacyLocations(ws, callId, args) {
  var zip = String(args.zip || "").replace(/\D/g, "").substring(0, 5)
  var city = String(args.city || "").trim()
  var state = String(args.state || "").trim()
  var chainPreference = normalizeChainPreference(args.chain_preference || "any")

  if (!zip || zip.length !== 5) {
    sendFunctionOutput(ws, callId, { success: false, error: "missing_zip", options: [] })
    ws.send(JSON.stringify({ type: "response.create", response: { instructions: languagePrefix() + "Ask the caller for the 5-digit ZIP code so you can search nearby pharmacy locations." } }))
    return
  }

  system.http({
    method: "POST",
    url: pharmacyLocationSearchUrl,
    header: [
      { name: "Content-Type", value: "application/json" },
      { name: "X-Pharmacy-Secret", value: pharmacyApiSecret, secret: true }
    ],
    body: JSON.stringify({ zip: zip, city: city, state: state, chain_preference: chainPreference }),
    callback: function(code, response, headers) {
      var output = parseJsonOrDefault(response, null)

      if (!output || output.success !== true || !output.options || !output.options.length) {
        output = {
          success: true,
          fallback: true,
          source: "demo_fallback",
          demo_only: true,
          warning: "DEMO ONLY - NOT REAL PHARMACY LOCATIONS",
          zip: zip,
          chain_preference: chainPreference,
          options: allowDemoPharmacyFallback ? buildDemoPharmacyOptions(chainPreference, zip, city, state) : []
        }
      }

      lastPharmacyLocationOptions = output.options || []
      sendFunctionOutput(ws, callId, output)

      var instruction = lastPharmacyLocationOptions.length
        ? languagePrefix() + "Read up to three numbered pharmacy options by name and address only. Then ask which option number they want. After they answer, call select_pharmacy_location."
        : languagePrefix() + "Tell the caller you could not find pickup options right now. Ask if they want no preference noted for pharmacy staff."

      ws.send(JSON.stringify({ type: "response.create", response: { instructions: instruction } }))
    }
  })
}

function handleSelectPharmacyLocation(ws, callId, args) {
  var selected = getOptionByNumber(Number(args.option_number || 0))

  if (!selected) {
    sendFunctionOutput(ws, callId, { success: false, error: "option_not_found" })
    ws.send(JSON.stringify({ type: "response.create", response: { instructions: languagePrefix() + "Tell the caller that option number was not found. Ask them to choose again from the options you read." } }))
    return
  }

  selectedPickupOption = selected
  sendFunctionOutput(ws, callId, { success: true, selected: selected })
  ws.send(JSON.stringify({ type: "response.create", response: { instructions: languagePrefix() + "Tell the caller you have noted their pickup location as: " + selected.name + ", " + selected.address + ". Then continue with the next intake step." } }))
}

function handleTransferCall(ws, callId, args) {
  var destination = String(args.destination || staffTransferDestination).trim()
  if (!destination) destination = staffTransferDestination

  sendFunctionOutput(ws, callId, { success: true, destination: destination })
  transferInProgress = true
  clearTimeout(timer)

  setTimeout(function() {
    try {
      call.transfer(destination)
    } catch (e) {
      console.log("Transfer failed: " + e.message)
      transferInProgress = false
    }
  }, 1000)
}

function handleEndCall(ws, callId, args) {
  if (transferInProgress === true) return

  sendFunctionOutput(ws, callId, { success: true, reason: args.reason || "call_ended" })
  clearTimeout(timer)

  setTimeout(function() {
    if (transferInProgress === true) return

    try {
      ws.close()
    } catch (e) {
      console.log("WebSocket close failed: " + e.message)
    }

    call.hangup()
  }, 8000)
}

function handleSubmitPharmacyRequest(ws, callId, args) {
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
  var chainPreference = normalizeChainPreference(args.chain_preference || "any")

  var deliveryAddress = String(args.delivery_address || "").trim()
  var deliveryAddressConfirmed = boolValue(args.delivery_address_confirmed)
  var deliveryInstructions = String(args.delivery_instructions || "").trim()

  var pickupStoreCode = ""
  var pickupStoreName = ""
  var pickupStoreAddress = ""
  var pickupStorePhone = ""
  var pickupStoreSource = ""
  var pickupStoreOptionNumber = 0
  var pickupSearchZip = extractZip(address)

  if (selectedPickupOption) {
    pickupStoreCode = String(selectedPickupOption.store_code || "").trim()
    pickupStoreName = String(selectedPickupOption.name || "").trim()
    pickupStoreAddress = String(selectedPickupOption.address || "").trim()
    pickupStorePhone = String(selectedPickupOption.phone || "").trim()
    pickupStoreSource = String(selectedPickupOption.source || "").trim()
    pickupStoreOptionNumber = Number(selectedPickupOption.option_number || 0)
    pickupSearchZip = String(selectedPickupOption.zip || pickupSearchZip).trim()
  }

  if (!requestType || ["refill", "medication_order", "stock_question"].indexOf(requestType) === -1) requestType = "medication_order"
  if (!quantityRequested || quantityRequested < 1) quantityRequested = 1

  if (!medication) return askAgain(ws, callId, "missing_medication", "I need the medication name so I can enter the request for pharmacy staff.", "Ask only for the medication name.")

  var drugCheck = checkDrugClassification(medication)

  if (drugCheck.action === "block") {
    sendFunctionOutput(ws, callId, { success: false, blocked: true, reason: "controlled_substance_blocked", drug_check: drugCheck })
    ws.send(JSON.stringify({ type: "response.create", response: { instructions: languagePrefix() + "Tell the caller: I am not able to process that request through this line. If you need to speak with a pharmacist or support staff, I can connect you now. Ask: Would you like me to transfer you to a pharmacist?" } }))
    return
  }

  if (drugCheck.action === "review") {
    notes = notes ? notes + " | CONTROLLED SUBSTANCE REVIEW: " + drugCheck.reason : "CONTROLLED SUBSTANCE REVIEW: " + drugCheck.reason
  }

  if (!hasFirstAndLastName(customerName)) return askAgain(ws, callId, "missing_first_last_name", "I need your first and last name so pharmacy staff can follow up with you.", "Ask for their first and last name.")
  if (!hasDateOfBirth(dateOfBirth)) return askAgain(ws, callId, "missing_date_of_birth", "I need your date of birth so pharmacy staff can verify the request.", "Ask for their date of birth.")
  if (!hasPhoneWithAreaCode(callbackPhoneRaw)) return askAgain(ws, callId, "missing_phone_area_code", "I need the full callback phone number including area code.", "Ask for the full callback phone number including area code.")
  if (!hasFiveDigitZip(address)) return askAgain(ws, callId, "missing_five_digit_zip", "I need the 5-digit ZIP code for the address.", "Ask for the full address again, including the 5-digit ZIP code.")
  if (!fulfillmentConfirmed) return askAgain(ws, callId, "missing_fulfillment_preference", "I need to know whether you prefer delivery, pickup, or no preference.", "Ask: Would you prefer delivery to your address, pickup at a pharmacy, or no preference?")

  if (fulfillmentMethod === "delivery") {
    if (!deliveryAddress) deliveryAddress = address
    if (!deliveryAddressConfirmed && callerConfirmed) deliveryAddressConfirmed = true
    if (!deliveryAddressConfirmed) return askAgain(ws, callId, "missing_delivery_address_confirmation", "Before I enter the request, I need you to confirm that the delivery address I repeated is correct.", "Repeat all details including the delivery address, then ask: Does everything sound correct? Please say yes to confirm.")
    if (!pharmacyName) pharmacyName = "Delivery to customer address"
  }

  if (fulfillmentMethod === "pickup") {
    if (!pickupStoreName || !pickupStoreAddress) return askAgain(ws, callId, "missing_pickup_store", "I need to know which pharmacy location you want noted for staff.", "If options were already read, ask which option number they choose, then call select_pharmacy_location.")
    pharmacyName = pickupStoreName
  }

  if (fulfillmentMethod === "undecided" && !pharmacyName) pharmacyName = "No preference"
  if (!pharmacyName) return askAgain(ws, callId, "missing_pharmacy_name", "I need to know whether to note delivery, a pickup pharmacy, or no preference for staff.", "Ask whether they prefer delivery, pickup at a pharmacy, or no preference.")
  if (!callerConfirmed) return askAgain(ws, callId, "missing_confirmation", "Before I enter the request, I need you to confirm that the information I repeated is correct.", "Repeat all details and ask: Does everything sound correct? Please say yes to confirm.")

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
      notes: notes,
      rx_number: rxNumber,
      prescriber_name: prescriberName,
      pharmacy_name: pharmacyName,
      insurance_provider: insuranceProvider,
      insurance_member_id: insuranceMemberId,
      insurance_group_number: insuranceGroupNumber,
      insurance_bin: insuranceBin,
      insurance_pcn: insurancePcn,
      fulfillment_method: fulfillmentMethod,
      chain_preference: chainPreference,
      pickup_requested: fulfillmentMethod === "pickup",
      delivery_requested: fulfillmentMethod === "delivery",
      pickup_store_option_number: pickupStoreOptionNumber,
      pickup_store_code: pickupStoreCode,
      pickup_store_name: pickupStoreName,
      pickup_store_address: pickupStoreAddress,
      pickup_store_phone: pickupStorePhone,
      pickup_store_source: pickupStoreSource,
      pickup_search_zip: pickupSearchZip,
      delivery_address: fulfillmentMethod === "delivery" ? deliveryAddress : "",
      delivery_address_confirmed: fulfillmentMethod === "delivery" ? deliveryAddressConfirmed : false,
      delivery_instructions: deliveryInstructions,
      fulfillment_confirmed: fulfillmentConfirmed,
      fulfillment_notes: buildFulfillmentNotes(fulfillmentMethod, pickupStoreName, deliveryAddress),
      source: "vodia_ai_phone",
      language: conversationLanguage
    }),
    callback: function(code, response, headers) {
      var output = parseJsonOrDefault(response, { success: false, transfer_to_staff: true })

      if (code < 200 || code >= 300 || output.success !== true) {
        output.transfer_to_staff = true
        if (!output.ai_say) output.ai_say = "I am having trouble submitting your request right now. I will transfer you to pharmacy staff for help."
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
      }

      var sayInstruction = languagePrefix() + "Say exactly to the caller: " + JSON.stringify(successMessage()) + " Then call end_call with reason request_completed. Do not ask if there is anything else."

      if (output.transfer_to_staff === true) {
        sayInstruction = languagePrefix() + "Say exactly to the caller: " + JSON.stringify(transferMessage()) + " Then call transfer_call with destination " + staffTransferDestination + "."
      }

      ws.send(JSON.stringify({ type: "response.create", response: { instructions: sayInstruction } }))
    }
  })
}

function parseJsonOrDefault(response, fallback) {
  try {
    return JSON.parse(response || "{}")
  } catch (e) {
    return fallback
  }
}

function buildFulfillmentNotes(method, pickupStoreName, deliveryAddress) {
  if (method === "pickup") return "Caller requested pickup at " + String(pickupStoreName || "selected pharmacy") + "."
  if (method === "delivery") return "Caller requested delivery to confirmed address: " + String(deliveryAddress || "") + "."
  return "Caller did not choose pickup or delivery."
}

function extractRequestId(output) {
  if (!output) return ""
  return String(output.request_id || output.refill_request_id || output.id || "").trim()
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
      console.log("Customer enrich response code: " + code)
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
      console.log("Fulfillment update response code: " + code)
    }
  })
}

function askAgain(ws, callId, reason, aiSay, nextInstruction) {
  sendFunctionOutput(ws, callId, {
    success: false,
    transfer_to_staff: false,
    reason: reason,
    ai_say: aiSay
  })

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

  ws.send(JSON.stringify({
    type: "conversation.item.create",
    item: {
      type: "function_call_output",
      call_id: callId,
      output: JSON.stringify(output)
    }
  }))
}

function normalizePhoneE164(phone) {
  var raw = String(phone || "").trim()
  if (!raw || raw === "UNKNOWN") return "UNKNOWN"

  if (raw.charAt(0) === "+") {
    var plusDigits = raw.replace(/\D/g, "")
    if (plusDigits.length >= 8 && plusDigits.length <= 15) return "+" + plusDigits
    return raw
  }

  var digits = raw.replace(/\D/g, "")
  if (digits.length === 10) return "+1" + digits
  if (digits.length === 11 && digits.charAt(0) === "1") return "+" + digits
  if (digits.length >= 8 && digits.length <= 15) return "+" + digits
  return raw || "UNKNOWN"
}

function hasFirstAndLastName(name) {
  var clean = String(name || "").trim()
  if (!clean || clean === "Unknown Caller" || clean === "UNKNOWN") return false
  return clean.split(/\s+/).filter(Boolean).length >= 2
}

function hasDateOfBirth(dob) {
  var clean = String(dob || "").trim()
  if (!clean || clean === "UNKNOWN") return false
  return /\d/.test(clean) && clean.length >= 4
}

function hasPhoneWithAreaCode(phone) {
  var raw = String(phone || "").trim()
  if (!raw || raw === "UNKNOWN") return false
  var digits = raw.replace(/\D/g, "")
  return digits.length === 10 || (digits.length === 11 && digits.charAt(0) === "1")
}

function hasFiveDigitZip(address) {
  var raw = String(address || "").trim()
  if (!raw || raw === "UNKNOWN") return false
  return /\b\d{5}\b/.test(raw)
}

function boolValue(value) {
  if (value === true || value === 1 || value === "1") return true
  var raw = String(value || "").toLowerCase().trim()
  return raw === "true" || raw === "yes" || raw === "y" || raw === "si" || raw === "sí"
}

function normalizeFulfillmentMethod(method) {
  var raw = String(method || "").toLowerCase().trim()
  if (raw === "pickup") return "pickup"
  if (raw === "delivery") return "delivery"
  return "undecided"
}

function normalizeChainPreference(value) {
  var raw = String(value || "").toLowerCase().trim()
  if (raw.indexOf("cvs") >= 0) return "cvs"
  if (raw.indexOf("walgreen") >= 0 || raw.indexOf("wallgreen") >= 0) return "walgreens"
  if (raw === "none" || raw === "no preference") return "any"
  if (raw === "any" || raw === "either") return "any"
  return "any"
}

function extractZip(address) {
  var match = String(address || "").match(/\b\d{5}\b/)
  return match ? match[0] : ""
}

function getOptionByNumber(optionNumber) {
  for (var i = 0; i < lastPharmacyLocationOptions.length; i++) {
    var option = lastPharmacyLocationOptions[i]
    if (Number(option.option_number || (i + 1)) === Number(optionNumber)) return option
  }
  return null
}

function buildDemoPharmacyOptions(chainPreference, zip, city, state) {
  var prefix = "Demo Pharmacy"
  if (chainPreference === "cvs") prefix = "CVS Demo Pharmacy"
  if (chainPreference === "walgreens") prefix = "Walgreens Demo Pharmacy"

  return [
    {
      option_number: 1,
      store_code: "DEMO-1",
      name: prefix + " Option 1",
      address: "100 Main Street, " + String(city || "Local City") + ", " + String(state || "MA") + " " + zip,
      phone: "",
      source: "demo_fallback",
      zip: zip
    },
    {
      option_number: 2,
      store_code: "DEMO-2",
      name: prefix + " Option 2",
      address: "200 Center Street, " + String(city || "Local City") + ", " + String(state || "MA") + " " + zip,
      phone: "",
      source: "demo_fallback",
      zip: zip
    },
    {
      option_number: 3,
      store_code: "DEMO-3",
      name: prefix + " Option 3",
      address: "300 Broadway, " + String(city || "Local City") + ", " + String(state || "MA") + " " + zip,
      phone: "",
      source: "demo_fallback",
      zip: zip
    }
  ]
}

call.dial("openai")
