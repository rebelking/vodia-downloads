// OpenAI integration through SIP
// Vodia Pharmacy AI Request Intake - Known Customer + CVS/Walgreens Pickup + Delivery Version
'use strict'

// Key is injected by Vodia from the Voice Agent OpenAI key field.
// The fallback below is safe — it will NOT override an injected key.
// Remove the placeholder string before production.
var secret = typeof secret !== "undefined" ? secret : ""

// Pharmacy backend settings
// Rotate pharmacyApiSecret before any real PHI is processed.
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

// Selected pickup pharmacy from search results.
// Set by handleSelectPharmacyLocation() so submit does not have to guess.
var selectedPickupOption = null

// Set to false before production to prevent fake pharmacy locations
// from appearing in staff portal when real location search fails.
var allowDemoPharmacyFallback = true

// ─────────────────────────────────────────────────────────────────────────────
// Controlled Substance Classification
//
// This table covers the most common cases the AI will encounter.
// For a complete list, import the DEA Alphabetical Controlled Substances list
// and Massachusetts Chapter 94C into the blocked_or_review_drugs database table.
//
// Actions:
//   block  = Schedule I or known illegal — AI refuses, offers human staff
//   review = Schedule II-V — AI collects info, routes to pharmacist review
//   allow  = Regular prescription or OTC — normal workflow
//
// Source references:
//   Federal:       DEA Alphabetical Listing / 21 CFR Part 1308
//   Massachusetts: M.G.L. Chapter 94C / MCSR
// ─────────────────────────────────────────────────────────────────────────────

var DRUG_CLASSIFICATIONS = [
  // ── Schedule I — block ────────────────────────────────────────────────────
  // No accepted medical use under federal law. Hard block.
  { name: "heroin",          schedule: "I",  action: "block"  },
  { name: "diacetylmorphine",schedule: "I",  action: "block"  },
  { name: "marijuana",       schedule: "I",  action: "block"  },
  { name: "cannabis",        schedule: "I",  action: "block"  },
  { name: "lsd",             schedule: "I",  action: "block"  },
  { name: "lysergic acid diethylamide", schedule: "I", action: "block" },
  { name: "mdma",            schedule: "I",  action: "block"  },
  { name: "ecstasy",         schedule: "I",  action: "block"  },
  { name: "molly",           schedule: "I",  action: "block"  },
  { name: "psilocybin",      schedule: "I",  action: "block"  },
  { name: "psilocin",        schedule: "I",  action: "block"  },
  { name: "mushrooms",       schedule: "I",  action: "block"  },
  { name: "shrooms",         schedule: "I",  action: "block"  },
  { name: "mescaline",       schedule: "I",  action: "block"  },
  { name: "peyote",          schedule: "I",  action: "block"  },
  { name: "methaqualone",    schedule: "I",  action: "block"  },
  { name: "quaalude",        schedule: "I",  action: "block"  },
  { name: "bath salts",      schedule: "I",  action: "block"  },
  { name: "flakka",          schedule: "I",  action: "block"  },
  { name: "spice",           schedule: "I",  action: "block"  },
  { name: "k2",              schedule: "I",  action: "block"  },
  { name: "synthetic marijuana", schedule: "I", action: "block" },
  { name: "crack",           schedule: "I",  action: "block"  },
  { name: "crack cocaine",   schedule: "I",  action: "block"  },
  { name: "freebase",        schedule: "I",  action: "block"  },

  // ── Schedule I street names ───────────────────────────────────────────────
  { name: "smack",           schedule: "I",  action: "block"  },
  { name: "dope",            schedule: "I",  action: "block"  },
  { name: "junk",            schedule: "I",  action: "block"  },
  { name: "black tar",       schedule: "I",  action: "block"  },
  { name: "horse",           schedule: "I",  action: "block"  },
  { name: "acid",            schedule: "I",  action: "block"  },
  { name: "tabs",            schedule: "I",  action: "block"  },
  { name: "e",               schedule: "I",  action: "block"  },
  { name: "rolls",           schedule: "I",  action: "block"  },
  { name: "x",               schedule: "I",  action: "block"  },
  { name: "weed",            schedule: "I",  action: "block"  },
  { name: "pot",             schedule: "I",  action: "block"  },
  { name: "grass",           schedule: "I",  action: "block"  },
  { name: "bud",             schedule: "I",  action: "block"  },
  { name: "ganja",           schedule: "I",  action: "block"  },
  { name: "reefer",          schedule: "I",  action: "block"  },
  { name: "mary jane",       schedule: "I",  action: "block"  },

  // ── Schedule II — review ─────────────────────────────────────────────────
  // High potential for abuse. Legal with valid prescription.
  // AI collects info, flags for pharmacist review.
  { name: "oxycodone",       schedule: "II", action: "review" },
  { name: "oxycontin",       schedule: "II", action: "review" },
  { name: "percocet",        schedule: "II", action: "review" },
  { name: "roxicodone",      schedule: "II", action: "review" },
  { name: "hydrocodone",     schedule: "II", action: "review" },
  { name: "vicodin",         schedule: "II", action: "review" },
  { name: "norco",           schedule: "II", action: "review" },
  { name: "fentanyl",        schedule: "II", action: "review" },
  { name: "duragesic",       schedule: "II", action: "review" },
  { name: "morphine",        schedule: "II", action: "review" },
  { name: "ms contin",       schedule: "II", action: "review" },
  { name: "codeine",         schedule: "II", action: "review" },
  { name: "methadone",       schedule: "II", action: "review" },
  { name: "dolophine",       schedule: "II", action: "review" },
  { name: "hydromorphone",   schedule: "II", action: "review" },
  { name: "dilaudid",        schedule: "II", action: "review" },
  { name: "oxymorphone",     schedule: "II", action: "review" },
  { name: "opana",           schedule: "II", action: "review" },
  { name: "meperidine",      schedule: "II", action: "review" },
  { name: "demerol",         schedule: "II", action: "review" },
  { name: "methylphenidate", schedule: "II", action: "review" },
  { name: "ritalin",         schedule: "II", action: "review" },
  { name: "concerta",        schedule: "II", action: "review" },
  { name: "adderall",        schedule: "II", action: "review" },
  { name: "amphetamine",     schedule: "II", action: "review" },
  { name: "dextroamphetamine", schedule: "II", action: "review" },
  { name: "dexedrine",       schedule: "II", action: "review" },
  { name: "vyvanse",         schedule: "II", action: "review" },
  { name: "lisdexamfetamine", schedule: "II", action: "review" },
  { name: "cocaine",         schedule: "II", action: "review" }, // medical use exists (topical anesthetic)
  { name: "phencyclidine",   schedule: "II", action: "review" },
  { name: "pcp",             schedule: "II", action: "review" },

  // ── Schedule II street names ──────────────────────────────────────────────
  { name: "oxy",             schedule: "II", action: "review" },
  { name: "oxys",            schedule: "II", action: "review" },
  { name: "perc",            schedule: "II", action: "review" },
  { name: "percs",           schedule: "II", action: "review" },
  { name: "blues",           schedule: "II", action: "review" },
  { name: "m30",             schedule: "II", action: "review" },
  { name: "roxies",          schedule: "II", action: "review" },
  { name: "vikes",           schedule: "II", action: "review" },
  { name: "hydros",          schedule: "II", action: "review" },
  { name: "norcos",          schedule: "II", action: "review" },
  { name: "patches",         schedule: "II", action: "review" }, // fentanyl patches
  { name: "fentanyl patch",  schedule: "II", action: "review" },
  { name: "snow",            schedule: "II", action: "review" }, // cocaine slang
  { name: "coke",            schedule: "II", action: "review" },
  { name: "blow",            schedule: "II", action: "review" },
  { name: "study drug",      schedule: "II", action: "review" },
  { name: "smart drug",      schedule: "II", action: "review" },

  // ── Schedule III — review ─────────────────────────────────────────────────
  { name: "buprenorphine",   schedule: "III", action: "review" },
  { name: "suboxone",        schedule: "III", action: "review" },
  { name: "subutex",         schedule: "III", action: "review" },
  { name: "anabolic steroids", schedule: "III", action: "review" },
  { name: "testosterone",    schedule: "III", action: "review" },
  { name: "ketamine",        schedule: "III", action: "review" },
  { name: "tylenol with codeine", schedule: "III", action: "review" },

  // ── Schedule IV — review ──────────────────────────────────────────────────
  { name: "alprazolam",      schedule: "IV", action: "review" },
  { name: "xanax",           schedule: "IV", action: "review" },
  { name: "diazepam",        schedule: "IV", action: "review" },
  { name: "valium",          schedule: "IV", action: "review" },
  { name: "clonazepam",      schedule: "IV", action: "review" },
  { name: "klonopin",        schedule: "IV", action: "review" },
  { name: "lorazepam",       schedule: "IV", action: "review" },
  { name: "ativan",          schedule: "IV", action: "review" },
  { name: "temazepam",       schedule: "IV", action: "review" },
  { name: "restoril",        schedule: "IV", action: "review" },
  { name: "triazolam",       schedule: "IV", action: "review" },
  { name: "halcion",         schedule: "IV", action: "review" },
  { name: "zolpidem",        schedule: "IV", action: "review" },
  { name: "ambien",          schedule: "IV", action: "review" },
  { name: "tramadol",        schedule: "IV", action: "review" },
  { name: "ultram",          schedule: "IV", action: "review" },
  { name: "carisoprodol",    schedule: "IV", action: "review" },
  { name: "soma",            schedule: "IV", action: "review" },
  { name: "phentermine",     schedule: "IV", action: "review" },
  { name: "modafinil",       schedule: "IV", action: "review" },
  { name: "provigil",        schedule: "IV", action: "review" },

  // ── Schedule IV street names ──────────────────────────────────────────────
  { name: "bars",            schedule: "IV", action: "review" }, // xanax bars
  { name: "xans",            schedule: "IV", action: "review" },
  { name: "benzos",          schedule: "IV", action: "review" },
  { name: "zannies",         schedule: "IV", action: "review" },
  { name: "sleepers",        schedule: "IV", action: "review" },
  { name: "nerve pills",     schedule: "IV", action: "review" },

  // ── Schedule V — review ───────────────────────────────────────────────────
  { name: "pregabalin",      schedule: "V",  action: "review" },
  { name: "lyrica",          schedule: "V",  action: "review" },
  { name: "gabapentin",      schedule: "V",  action: "review" }, // MA Schedule V
  { name: "neurontin",       schedule: "V",  action: "review" },
  { name: "lacosamide",      schedule: "V",  action: "review" },
  { name: "vimpat",          schedule: "V",  action: "review" }
]

// Normalize drug name for matching: lowercase, trim, collapse spaces.
function normalizeDrugName(name) {
  return String(name || "").toLowerCase().trim().replace(/\s+/g, " ")
}

// Check a medication name against the classification table.
// Returns: { matched: bool, drug_name, matched_name, schedule, action, reason }
function checkDrugClassification(medicationName) {
  var normalized = normalizeDrugName(medicationName)

  if (!normalized || normalized.length < 3) {
    return { matched: false, action: "allow" }
  }

  for (var i = 0; i < DRUG_CLASSIFICATIONS.length; i++) {
    var entry = DRUG_CLASSIFICATIONS[i]
    var entryName = normalizeDrugName(entry.name)

    if (!entryName || entryName.length < 3) continue

    // Match only when the entry name appears as a whole word in the caller's input,
    // or the caller's input exactly matches the entry name.
    // This prevents "codeine" from matching "co" or "Claritin" from matching "arin".
    var exactMatch = normalized === entryName
    var callerContainsEntry = false

    if (!exactMatch && entryName.length >= 4) {
      // Check that the entry name appears as a whole token in the normalized input.
      // Pad with spaces to simulate word boundaries without regex look-behind.
      var padded = " " + normalized + " "
      callerContainsEntry = padded.indexOf(" " + entryName + " ") !== -1
    }

    if (exactMatch || callerContainsEntry) {
      return {
        matched: true,
        drug_name: medicationName,
        matched_name: entry.name,
        schedule: entry.schedule,
        action: entry.action,
        reason: entry.action === "block"
          ? "Schedule " + entry.schedule + " controlled substance under federal DEA listing. No accepted medical use."
          : "Schedule " + entry.schedule + " controlled substance. Valid prescription required. Routing to pharmacist review."
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

// Safety timeout — 4 minutes.
var timer = setTimeout(function() {
  console.log("Safety timeout reached. Transferring caller to pharmacy staff.")
  transferInProgress = true
  call.transfer(staffTransferDestination)
}, 240000)

call.http(onhttp)

function onhttp(args) {
  console.log("OpenAI ringing...")
  console.log(JSON.stringify(args))

  // FIX: Safe JSON parsing — bare JSON.parse() crashes the call on bad body.
  var body = {}
  try {
    body = JSON.parse(args.body || "{}")
  } catch (e) {
    console.log("Could not parse incoming HTTP body: " + e.message)
    return
  }

  console.log("Body:")
  console.log(JSON.stringify(body))

  if (body.type == "realtime.call.incoming") {
    var callid = body.data.call_id

    console.log("Call id:")
    console.log(callid)

    system.http({
      method: "POST",
      url: "https://api.openai.com/v1/realtime/calls/" + callid + "/accept",
      header: [
        { name: "Authorization", value: "Bearer " + secret, secret: true },
        { name: "Content-Type", value: "application/json" }
      ],
      // Current GA production model name as of 2025.
      // gpt-realtime   = GA stable
      // gpt-realtime-1.5 = faster speech-to-speech
      // gpt-realtime-2   = strongest reasoning and tool use
      // Test gpt-realtime-1.5 for speed, gpt-realtime-2 if tool calls miss steps.
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
  }
}

function connected(code, response, headers, callid) {
  // FIX: Guard against OpenAI accept failure before opening WebSocket.
  // Without this, a failed accept causes the script to open a WebSocket
  // that immediately errors, leaving the caller with dead air.
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

      "\n\nRequired intake flow:" +
      "\n1. First identify the medication the caller is requesting." +
      "\n2. Ask for the caller's first and last name." +
      "\n3. Ask for date of birth." +
      "\n4. Ask for the best callback phone number including area code." +
      "\n5. Call lookup_customer after callback phone is collected." +
      "\n6. Ask for the full address, including street address, city, state, and 5-digit ZIP code." +
      "\n7. Ask one optional support question: Do you have a prescription number, prescribing doctor name, pharmacy name, or insurance information? If not, I can still enter the request for staff review." +
      "\n8. Ask exactly: Would you prefer delivery to your address, pickup at a pharmacy, or no preference? I am only recording the preference for staff review." +
      "\n9. If delivery, do not ask for a separate delivery address confirmation. Include the delivery address in the final recap. If the caller says yes to the final recap, set delivery_address_confirmed true and caller_confirmed true." +
      "\n10. If pickup, ask: Do you prefer CVS, Walgreens, or no preference for the pharmacy location?" +
      "\n11. After the caller answers CVS, Walgreens, or no preference, call search_pharmacy_locations using the ZIP code from the caller address, city/state from the address if known, and chain_preference cvs, walgreens, or any." +
      "\n12. When search_pharmacy_locations returns options, read up to three numbered options with pharmacy name and address. Ask which option they want noted for staff." +
      "\n13. For pickup, after the caller chooses an option number, call select_pharmacy_location with that option_number. Do not submit until select_pharmacy_location confirms the selection." +
      "\n14. If no preference, set fulfillment_method to undecided and pharmacy_name to No preference." +
      "\n15. Repeat the medication, first and last name, date of birth, callback number, full address, optional support detail, and pickup or delivery preference." +
      "\n16. In English ask: Does everything sound correct? Please say yes to confirm." +
      "\n17. In Spanish ask: Todo suena correcto? Por favor diga si para confirmar." +
      "\n18. After the caller confirms, call submit_pharmacy_request with caller_confirmed true and fulfillment_confirmed true." +

      "\n\nDo not submit the request after only hearing the medication name." +
      "\n\nDo not submit the request without first and last name." +
      "\n\nDo not submit the request without date of birth." +
      "\n\nDo not submit the request without a callback phone number that includes area code." +
      "\n\nDo not submit the request without a full address and a 5-digit ZIP code." +
      "\n\nDo not submit until pickup, delivery, or no preference has been asked and answered." +
      "\n\nFor pickup, do not submit until select_pharmacy_location has confirmed the chosen option." +
      "\n\nDo not submit until the caller confirms the repeated information. caller_confirmed must be true only after confirmation." +
      "\n\nDo not ask for confirmation more than once. Use the final recap confirmation as the confirmation for both caller_confirmed and delivery_address_confirmed." +

      "\n\nFulfillment rules:" +
      "\n- If the caller wants delivery, set fulfillment_method to delivery." +
      "\n- For delivery, set pharmacy_name to Delivery to customer address." +
      "\n- For delivery, use the same full address collected from the caller as delivery_address unless they give another delivery address." +
      "\n- For delivery, delivery_address_confirmed must be true only after the caller confirms the address is correct for delivery." +
      "\n- If the caller wants pickup, set fulfillment_method to pickup." +
      "\n- For pickup, pharmacy_name, pickup_store_name, and pickup_store_address must match the selected location from select_pharmacy_location." +
      "\n- For pickup, if the caller says CVS, chain_preference must be cvs." +
      "\n- For pickup, if the caller says Walgreens, Walgreen, Wallgreens, or Walgreeens, chain_preference must be walgreens." +
      "\n- For pickup, if the caller says no preference, any, either, or does not matter, chain_preference must be any." +
      "\n- If the caller does not want pickup or delivery, set fulfillment_method to undecided and pharmacy_name to No preference." +
      "\n- Never say the medication is ready, approved, shipped, guaranteed, available, or ready for pickup. You are only recording the preference for staff review." +

      "\n\nLocation rule:" +
      "\n- Use the ZIP code from the address as the main search location." +
      "\n- Use city and state from the address if available." +
      "\n- Do not rely on phone area code unless ZIP/city is missing." +
      "\n- If ZIP code is missing, ask for the 5-digit ZIP code before searching pharmacy locations." +

      "\n\nIf the caller gives only a first name, ask for their last name." +
      "\n\nIf the caller gives only 7 digits for the phone number, ask for the full phone number including area code." +
      "\n\nIf the ZIP code is missing or is not exactly 5 digits, ask for the 5-digit ZIP code." +

      "\n\nAddress validation is performed by the backend after submission using Smarty. The backend may tell staff whether the address was validated or needs review. Do not tell the caller that the address is guaranteed valid." +

      "\n\nIf the caller cannot provide first and last name, date of birth, callback number with area code, or full address with 5-digit ZIP code, say that pharmacy staff needs that information to follow up. Offer to transfer to staff. If yes, call transfer_call." +
      "\n\nPrevious request lookup rule:" +
      "\n- If the caller says they are calling back, checking status, following up, or asking about a previous request, do not ask for medication first. First verify callback phone, date of birth, and address, then call lookup_previous_pharmacy_request." +
      "\n- After collecting callback phone, date of birth, and address, call lookup_previous_pharmacy_request before starting a brand-new request." +
      "\n- If a previous request is found, mention only medication name, status, and pickup or delivery preference." +
      "\n- Ask: Are you calling about this request?" +
      "\n- If yes, continue helping with that request. If no, continue with a new pharmacy request." +
      "\n- If the caller confirms they are calling about a previous request, immediately call leave_status_callback_note with the request_id from the lookup result, callback phone, customer name, and a short caller_message describing what they need." +
      "\n- After leave_status_callback_note completes, tell the caller you have notified pharmacy staff. Mention only the medication name and status. Do not read private details aloud." +

      "\n\nAsk one question at a time. Keep the conversation short, calm, professional, and friendly." +

      "\n\nControlled substance rule:" +
      "\n- If the caller asks for a Schedule I substance (heroin, marijuana, LSD, MDMA, psilocybin, or any street name for these), do not process the request. Say you cannot assist with that through this line and offer to connect them to a pharmacist." +
      "\n- If the caller asks for a Schedule II-V controlled substance (oxycodone, fentanyl, Adderall, Xanax, Valium, Suboxone, or similar), collect the normal intake information and submit normally. The system will flag it for pharmacist review automatically." +
      "\n- If the caller uses a street name, slang, or an unclear name (oxy, bars, blues, snow, weed, molly, smack, percs, benzos, patches, etc.), ask for the exact name on the prescription label before proceeding." +
      "\n- Never confirm that a controlled substance is available, in stock, or ready for pickup." +
      "\n- Never discuss whether a controlled substance can be obtained without a prescription." +
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
            name: "lookup_previous_pharmacy_request",
            description: "Looks up the caller's previous pharmacy request using callback phone, date of birth, and address or ZIP.",
            parameters: {
              type: "object",
              properties: {
                callback_phone: {
                  type: "string",
                  description: "Caller callback phone number with area code."
                },
                date_of_birth: {
                  type: "string",
                  description: "Caller date of birth."
                },
                address: {
                  type: "string",
                  description: "Caller delivery address or full address with ZIP."
                },
                customer_name: {
                  type: "string",
                  description: "Caller full name if known."
                }
              },
              required: ["callback_phone", "date_of_birth", "address"]
            }
          },
          {
            type: "function",
            name: "search_pharmacy_locations",
            description: "Searches for CVS, Walgreens, or any pharmacy options near the caller ZIP code or city/state. Use only after pickup is selected.",
            parameters: {
              type: "object",
              properties: {
                zip: {
                  type: "string",
                  description: "Caller 5-digit ZIP code from the address."
                },
                city: {
                  type: "string",
                  description: "Caller city from the address if known."
                },
                state: {
                  type: "string",
                  description: "Caller state from the address if known."
                },
                chain_preference: {
                  type: "string",
                  enum: ["cvs", "walgreens", "any"],
                  description: "Use cvs, walgreens, or any."
                }
              },
              required: ["zip", "chain_preference"]
            }
          },
          {
            // FIX: New dedicated tool for pickup selection.
            // Separates location search from option confirmation so submit_pharmacy_request
            // does not need to guess which option the caller picked from conversation history.
            type: "function",
            name: "select_pharmacy_location",
            description: "Confirms the caller's chosen pickup pharmacy from the options returned by search_pharmacy_locations. Call this after the caller says their option number. Do not submit the order until this is called.",
            parameters: {
              type: "object",
              properties: {
                option_number: {
                  type: "number",
                  description: "The option number the caller selected from the list read aloud."
                }
              },
              required: ["option_number"]
            }
          },
          {
            type: "function",
            name: "leave_status_callback_note",
            description: "Leaves a note for pharmacy staff that the caller called in to check status on a previous request. Call this after the caller confirms they are calling about a previous request.",
            parameters: {
              type: "object",
              properties: {
                request_id: {
                  type: "string",
                  description: "The ID of the previous pharmacy request if returned by lookup_previous_pharmacy_request."
                },
                callback_phone: {
                  type: "string",
                  description: "Caller callback phone number."
                },
                customer_name: {
                  type: "string",
                  description: "Caller full name if known."
                },
                caller_message: {
                  type: "string",
                  description: "Short message from the caller about what they need, such as status update, refill confirmation, or delivery question."
                }
              },
              required: ["request_id", "callback_phone"]
            }
          },
          {
            type: "function",
            name: "submit_pharmacy_request",
            description: "Submit a pharmacy refill, medication request, or stock review request to the backend. Only use after collecting medication, first and last name, date of birth, callback phone with area code, full address with 5-digit ZIP code, optional support detail if provided, pickup/delivery/no preference, and caller confirmation.",
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
                  description: "Required fulfillment label. For pickup, use selected pharmacy name. For delivery, use Delivery to customer address. For no preference, use No preference."
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
                  description: "Caller fulfillment preference. Use pickup, delivery, or undecided."
                },
                chain_preference: {
                  type: "string",
                  enum: ["cvs", "walgreens", "any", "none"],
                  description: "For pickup only. Use cvs, walgreens, any, or none."
                },
                delivery_address: {
                  type: "string",
                  description: "Delivery address if fulfillment_method is delivery."
                },
                delivery_address_confirmed: {
                  type: "boolean",
                  description: "True only after caller confirms the delivery address is correct."
                },
                delivery_instructions: {
                  type: "string",
                  description: "Optional delivery instructions if caller provides them."
                },
                fulfillment_confirmed: {
                  type: "boolean",
                  description: "True only after caller answers pickup/delivery/no preference."
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
                "pharmacy_name",
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

    if (
      evt.type === "response.output_item.done" &&
      evt.item &&
      evt.item.type === "function_call"
    ) {
      var functionName = evt.item.name
      var callId = evt.item.call_id
      var functionArgs = {}

      try {
        functionArgs = JSON.parse(evt.item.arguments || "{}")
      } catch (e1) {
        console.log("Could not parse function arguments:")
        console.log(evt.item.arguments)
        functionArgs = {}
      }

      if (functionName === "set_conversation_language") {
        handleSetConversationLanguage(ws, callId, functionArgs)
        return
      }

      if (functionName === "lookup_previous_pharmacy_request") {
        handleLookupPreviousPharmacyRequest(ws, callId, functionArgs)
        return
      }

      if (functionName === "leave_status_callback_note") {
        handleLeaveStatusCallbackNote(ws, callId, functionArgs)
        return
      }

      if (functionName === "lookup_customer") {
        handleLookupCustomer(ws, callId, functionArgs)
        return
      }

      if (functionName === "search_pharmacy_locations") {
        handleSearchPharmacyLocations(ws, callId, functionArgs)
        return
      }

      if (functionName === "select_pharmacy_location") {
        handleSelectPharmacyLocation(ws, callId, functionArgs)
        return
      }

      if (functionName === "transfer_call") {
        // FIX: Pass callId so handler can send function output before transferring.
        handleTransferCall(ws, callId, functionArgs)
        return
      }

      if (functionName === "end_call") {
        // FIX: Pass callId so handler can send function output before hanging up.
        handleEndCall(ws, callId, functionArgs)
        return
      }

      if (functionName === "submit_pharmacy_request") {
        handleSubmitPharmacyRequest(ws, callId, functionArgs)
        return
      }
    }
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

function handleLeaveStatusCallbackNote(ws, callId, args) {
  var callerText = String(args.caller_message || "Caller called in for status update.").trim()

  var payload = {
    request_id: String(args.request_id || "").trim(),
    callback_phone: normalizePhoneE164(args.callback_phone || ""),
    customer_name: String(args.customer_name || "").trim(),
    caller_message: callerText,
    caller_summary: callerText,
    language: conversationLanguage,
    source: "vodia_ai_phone"
  }

  console.log("Leaving status callback note. Request ID present: " + (!!payload.request_id))

  system.http({
    method: "POST",
    url: pharmacyRequestUrl.replace("/refill-intake", "/status-callback-note"),
    header: [
      { name: "Content-Type", value: "application/json" },
      { name: "X-Pharmacy-Secret", value: pharmacyApiSecret, secret: true }
    ],
    body: JSON.stringify(payload),
    callback: function(code, response, headers) {
      console.log("Status callback note response code: " + code)

      var output

      try {
        output = JSON.parse(response || "{}")
      } catch (e) {
        output = { success: false, error: "invalid_response" }
      }

      sendFunctionOutput(ws, callId, output)

      var instruction = languagePrefix()

      if (output.success === true) {
        instruction +=
          "Tell the caller: I have left a note for the pharmacist that you called for a status update. " +
          "If the previous request lookup returned a status, mention only the status and medication name. " +
          "Do not read DOB, address, insurance, or prescription number aloud. " +
          "Ask if there is anything else you can help with today, such as a new request."
      } else {
        instruction +=
          "Tell the caller you were unable to leave a note at this time but pharmacy staff will be notified of the call. " +
          "Ask if they would like to be transferred to a pharmacist."
      }

      ws.send(JSON.stringify({
        type: "response.create",
        response: { instructions: instruction }
      }))
    }
  })
}

function handleLookupPreviousPharmacyRequest(ws, callId, args) {
  var payload = {
    callback_phone: normalizePhoneE164(args.callback_phone || ""),
    date_of_birth: String(args.date_of_birth || "").trim(),
    address: String(args.address || "").trim(),
    customer_name: String(args.customer_name || "").trim(),
    language: conversationLanguage
  }

  system.http({
    method: "POST",
    url: pharmacyRequestUrl.replace("/refill-intake", "/previous-request-lookup"),
    header: [
      { name: "Content-Type", value: "application/json" },
      { name: "X-Pharmacy-Secret", value: pharmacyApiSecret, secret: true }
    ],
    body: JSON.stringify(payload),
    callback: function(code, response, headers) {
      console.log("Previous request lookup response code: " + code)

      var output

      try {
        output = JSON.parse(response || "{}")
      } catch (e) {
        output = { success: false, found: false, error: "invalid_response" }
      }

      sendFunctionOutput(ws, callId, output)

      var instruction = languagePrefix()

      if (output.success === true && output.found === true && output.last_request) {
        instruction +=
          "Tell the caller you found their previous pharmacy request. " +
          "Mention only the medication name, request status, and pickup or delivery preference. " +
          "Do not read DOB, full address, insurance ID, prescription number, or private details aloud. " +
          "Ask: Are you calling about this request?"
      } else {
        instruction +=
          "Tell the caller you could not find a matching previous request with those verification details. " +
          "Continue with a new pharmacy request intake."
      }

      ws.send(JSON.stringify({
        type: "response.create",
        response: { instructions: instruction }
      }))
    }
  })
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
      console.log("Customer lookup response code: " + code)

      var output

      try {
        output = JSON.parse(response || "{}")
      } catch (e) {
        output = {
          success: false,
          lookup: { known_customer: false, greeting: "", profile: null }
        }
      }

      if (!output.lookup) {
        output.lookup = { known_customer: false, greeting: "", profile: null }
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
        response: { instructions: nextInstruction }
      }))
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

    ws.send(JSON.stringify({
      type: "response.create",
      response: {
        instructions: languagePrefix() + "Ask the caller for the 5-digit ZIP code so you can search for nearby CVS or Walgreens locations."
      }
    }))

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
      console.log("Pharmacy location search response code: " + code)

      var output

      try {
        output = JSON.parse(response || "{}")
      } catch (e) {
        output = null
      }

      if (!output || output.success !== true || !output.options || !output.options.length) {
        if (!allowDemoPharmacyFallback) {
          // Demo fallback disabled — note no preference for staff instead of inventing a pharmacy.
          output = { success: true, fallback: false, options: [], demo_only: false }
        } else {
        // DEMO FALLBACK — label clearly so staff know these are not real locations.
        output = {
          success: true,
          fallback: true,
          source: "demo_fallback",
          demo_only: true,
          warning: "DEMO ONLY - NOT REAL PHARMACY LOCATIONS",
          zip: zip,
          chain_preference: chainPreference,
          options: buildDemoPharmacyOptions(chainPreference, zip, city, state)
        }
        } // end allowDemoPharmacyFallback
      }

      lastPharmacyLocationOptions = output.options || []

      sendFunctionOutput(ws, callId, output)

      var instructions = languagePrefix()

      if (!lastPharmacyLocationOptions.length) {
        instructions += "Tell the caller you could not find pickup options right now. Ask if they want no preference noted for pharmacy staff."
      } else {
        instructions += "Read up to three numbered pharmacy options by name and address only. Then ask which option number they want. After they answer, call select_pharmacy_location with that option number."
      }

      ws.send(JSON.stringify({
        type: "response.create",
        response: { instructions: instructions }
      }))
    }
  })
}

// FIX: New handler for select_pharmacy_location.
// Locks in the caller's chosen option into selectedPickupOption so submit
// does not need to re-derive it from conversation context.
function handleSelectPharmacyLocation(ws, callId, args) {
  var optionNumber = Number(args.option_number || 0)
  var selected = getOptionByNumber(optionNumber)

  if (!selected) {
    sendFunctionOutput(ws, callId, {
      success: false,
      error: "option_not_found",
      option_number: optionNumber
    })

    ws.send(JSON.stringify({
      type: "response.create",
      response: {
        instructions: languagePrefix() + "Tell the caller that option number was not found. Ask them to choose again from the options you read."
      }
    }))

    return
  }

  selectedPickupOption = selected

  sendFunctionOutput(ws, callId, {
    success: true,
    selected: selected
  })

  ws.send(JSON.stringify({
    type: "response.create",
    response: {
      instructions:
        languagePrefix() +
        "Tell the caller you have noted their pickup location as: " + selected.name + ", " + selected.address + ". " +
        "Then continue with the next intake step."
    }
  }))
}

// FIX: Now accepts callId and sends function output before transferring.
// This keeps the OpenAI tool loop clean and prevents dead-air on transfer.
function handleTransferCall(ws, callId, args) {
  var destination = String(args.destination || staffTransferDestination).trim()

  if (!destination) {
    destination = staffTransferDestination
  }

  console.log("Transfer to destination:")
  console.log(destination)

  sendFunctionOutput(ws, callId, {
    success: true,
    destination: destination,
    message: "Transferring caller"
  })

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

// FIX: Now accepts callId and sends function output before hanging up.
function handleEndCall(ws, callId, args) {
  console.log("Ending call:")
  console.log(JSON.stringify(args))

  if (transferInProgress === true) {
    console.log("Transfer in progress. Skipping hangup.")
    return
  }

  sendFunctionOutput(ws, callId, {
    success: true,
    reason: args.reason || "call_ended"
  })

  clearTimeout(timer)

  setTimeout(function() {
    if (transferInProgress === true) {
      console.log("Transfer started during goodbye wait. Skipping hangup.")
      return
    }

    try {
      console.log("Closing WebSocket before hangup")
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

  console.log("Submitting pharmacy request to backend.")
  console.log("Medication present: " + (!!medication))
  console.log("Customer name present: " + (!!customerName))
  console.log("Phone present: " + (!!callbackPhone))
  console.log("Fulfillment method: " + normalizeFulfillmentMethod(args.fulfillment_method))

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

  // Pickup store: prefer selectedPickupOption (set by select_pharmacy_location).
  // Fall back to AI args for compatibility with callers who skip select_pharmacy_location.
  var pickupStoreOptionNumber = Number(args.pickup_store_option_number || 0)
  var pickupStoreCode = String(args.pickup_store_code || "").trim()
  var pickupStoreName = String(args.pickup_store_name || "").trim()
  var pickupStoreAddress = String(args.pickup_store_address || "").trim()
  var pickupStorePhone = String(args.pickup_store_phone || "").trim()
  var pickupStoreSource = String(args.pickup_store_source || "").trim()
  var pickupSearchZip = String(args.pickup_search_zip || extractZip(address)).trim()

  if (selectedPickupOption) {
    pickupStoreCode = String(selectedPickupOption.store_code || pickupStoreCode).trim()
    pickupStoreName = String(selectedPickupOption.name || pickupStoreName).trim()
    pickupStoreAddress = String(selectedPickupOption.address || pickupStoreAddress).trim()
    pickupStorePhone = String(selectedPickupOption.phone || pickupStorePhone).trim()
    pickupStoreSource = String(selectedPickupOption.source || pickupStoreSource).trim()
    pickupStoreOptionNumber = Number(selectedPickupOption.option_number || pickupStoreOptionNumber)
    pickupSearchZip = String(selectedPickupOption.zip || pickupSearchZip).trim()
  }

  // Also apply option-number lookup from lastPharmacyLocationOptions as a second fallback.
  if (!pickupStoreName && pickupStoreOptionNumber) {
    var optionFromList = getOptionByNumber(pickupStoreOptionNumber)
    if (optionFromList) {
      pickupStoreCode = String(optionFromList.store_code || pickupStoreCode).trim()
      pickupStoreName = String(optionFromList.name || pickupStoreName).trim()
      pickupStoreAddress = String(optionFromList.address || pickupStoreAddress).trim()
      pickupStorePhone = String(optionFromList.phone || pickupStorePhone).trim()
      pickupStoreSource = String(optionFromList.source || pickupStoreSource).trim()
      pickupSearchZip = String(optionFromList.zip || pickupSearchZip).trim()
    }
  }

  if (!requestType || ["refill","medication_order","stock_question"].indexOf(requestType) === -1) {
    requestType = "medication_order"
  }

  if (!quantityRequested || quantityRequested < 1) quantityRequested = 1

  if (!medication) {
    return askAgain(ws, callId, "missing_medication", "I need the medication name so I can enter the request for pharmacy staff.", "Ask only for the medication name.")
  }

  // Controlled substance check — runs before any data is submitted.
  var drugCheck = checkDrugClassification(medication)

  if (drugCheck.action === "block") {
    console.log("Drug classification BLOCK: " + JSON.stringify(drugCheck))

    sendFunctionOutput(ws, callId, {
      success: false,
      blocked: true,
      reason: "controlled_substance_schedule_i",
      drug_check: drugCheck
    })

    ws.send(JSON.stringify({
      type: "response.create",
      response: {
        instructions:
          languagePrefix() +
          "Tell the caller: I am not able to process that request through this line. " +
          "If you need to speak with a pharmacist or support staff, I can connect you now. " +
          "Do not name the substance again. Do not explain why in detail. Do not offer alternatives. " +
          "Ask: Would you like me to transfer you to a pharmacist?"
      }
    }))

    return
  }

  if (drugCheck.action === "review") {
    console.log("Drug classification REVIEW: " + JSON.stringify(drugCheck))
    // Do not block — continue intake but add controlled substance flag to notes.
    notes = notes
      ? notes + " | CONTROLLED SUBSTANCE REVIEW: " + drugCheck.reason
      : "CONTROLLED SUBSTANCE REVIEW: " + drugCheck.reason
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
    return askAgain(ws, callId, "missing_fulfillment_preference", "I need to know whether you prefer delivery, pickup, or no preference.", "Ask: Would you prefer delivery to your address, pickup at a pharmacy, or no preference?")
  }

  if (fulfillmentMethod === "delivery") {
    if (!deliveryAddress) deliveryAddress = address

    // Final recap confirmation counts as delivery address confirmation.
    // This prevents the AI from asking the caller to confirm twice.
    if (!deliveryAddressConfirmed && callerConfirmed) {
      deliveryAddressConfirmed = true
    }

    if (!deliveryAddressConfirmed) {
      return askAgain(
        ws,
        callId,
        "missing_delivery_address_confirmation",
        "Before I enter the request, I need you to confirm that the delivery address I repeated is correct.",
        "Repeat all details including the delivery address, then ask: Does everything sound correct? Please say yes to confirm."
      )
    }

    if (!pharmacyName) pharmacyName = "Delivery to customer address"
  }

  if (fulfillmentMethod === "pickup") {
    if (!pickupStoreName || !pickupStoreAddress) {
      return askAgain(ws, callId, "missing_pickup_store", "I need to know which pharmacy location you want noted for staff.", "If options were already read, ask which option number they choose, then call select_pharmacy_location.")
    }
    pharmacyName = pickupStoreName
  }

  if (fulfillmentMethod === "undecided" && !pharmacyName) {
    pharmacyName = "No preference"
  }

  if (!pharmacyName) {
    return askAgain(ws, callId, "missing_pharmacy_name", "I need to know whether to note delivery, a pickup pharmacy, or no preference for staff.", "Ask whether they prefer delivery, pickup at a pharmacy, or no preference.")
  }

  if (!callerConfirmed) {
    return askAgain(ws, callId, "missing_confirmation", "Before I enter the request, I need you to confirm that the information I repeated is correct.", "Repeat all details and ask: Does everything sound correct? Please say yes to confirm.")
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
      console.log("Pharmacy backend response code: " + code)

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

      // Treat backend logical failure (success: false) the same as HTTP error.
      if (output.success !== true && !output.transfer_to_staff) {
        output.transfer_to_staff = true
        if (!output.ai_say) {
          output.ai_say = "I am having trouble submitting your request right now. I will transfer you to pharmacy staff for help."
        }
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
        " Then call end_call with reason request_completed. Do not ask if there is anything else."

      if (output.transfer_to_staff === true) {
        sayInstruction =
          languagePrefix() +
          "Say exactly to the caller: " +
          JSON.stringify(transferMessage()) +
          " Then call transfer_call with destination " + staffTransferDestination + "."
      }

      ws.send(JSON.stringify({
        type: "response.create",
        response: { instructions: sayInstruction }
      }))
    }
  })
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

function extractZip(address) {
  var match = String(address || "").match(/\b\d{5}\b/)
  return match ? match[0] : ""
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

function normalizeChainPreference(chain) {
  var raw = String(chain || "").toLowerCase().trim()
  if (raw === "cvs" || raw === "csv" || raw === "c v s") return "cvs"
  if (raw === "walgreens" || raw === "walgreen" || raw === "wallgreens" || raw === "walgreeens") return "walgreens"
  return "any"
}

function buildDemoPharmacyOptions(chainPreference, zip, city, state) {
  var options = []
  var baseCity = city || "Lawrence"
  var baseState = state || "MA"

  if (chainPreference === "cvs" || chainPreference === "any") {
    options.push({
      option_number: options.length + 1,
      chain: "CVS",
      store_code: "CVS-DEMO-" + zip + "-1",
      name: "CVS Pharmacy Demo " + baseCity + " [DEMO ONLY]",
      address: "205 South Broadway, " + baseCity + ", " + baseState + " " + zip,
      phone: "+19785551001",
      source: "demo_fallback",
      zip: zip
    })
    options.push({
      option_number: options.length + 1,
      chain: "CVS",
      store_code: "CVS-DEMO-" + zip + "-2",
      name: "CVS Pharmacy Demo Alternate [DEMO ONLY]",
      address: "266 Broadway, Methuen, MA 01844",
      phone: "+19785551002",
      source: "demo_fallback",
      zip: zip
    })
  }

  if (chainPreference === "walgreens" || chainPreference === "any") {
    options.push({
      option_number: options.length + 1,
      chain: "Walgreens",
      store_code: "WALGREENS-DEMO-" + zip + "-1",
      name: "Walgreens Pharmacy Demo " + baseCity + " [DEMO ONLY]",
      address: "220 South Broadway, " + baseCity + ", " + baseState + " " + zip,
      phone: "+19785552001",
      source: "demo_fallback",
      zip: zip
    })
    options.push({
      option_number: options.length + 1,
      chain: "Walgreens",
      store_code: "WALGREENS-DEMO-" + zip + "-2",
      name: "Walgreens Pharmacy Demo Nearby [DEMO ONLY]",
      address: "14 Jackson Street, Methuen, MA 01844",
      phone: "+19785552002",
      source: "demo_fallback",
      zip: zip
    })
  }

  return options
}

function getOptionByNumber(optionNumber) {
  var wanted = Number(optionNumber || 0)
  if (!wanted || !lastPharmacyLocationOptions || !lastPharmacyLocationOptions.length) return null

  for (var i = 0; i < lastPharmacyLocationOptions.length; i++) {
    var item = lastPharmacyLocationOptions[i]
    if (Number(item.option_number || i + 1) === wanted) return item
  }

  return null
}

call.dial("openai")
