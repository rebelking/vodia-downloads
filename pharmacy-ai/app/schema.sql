CREATE TABLE patients (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      first_name TEXT NOT NULL,
      last_name TEXT NOT NULL,
      date_of_birth TEXT NOT NULL,
      address TEXT NOT NULL,
      phone TEXT,
      created_at TEXT DEFAULT CURRENT_TIMESTAMP
    , email TEXT, customer_notes TEXT, updated_at TEXT);
CREATE TABLE sqlite_sequence(name,seq);
CREATE TABLE medications (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      generic_name TEXT NOT NULL,
      brand_name TEXT,
      available INTEGER DEFAULT 1,
      quantity_on_hand INTEGER DEFAULT 0,
      notes TEXT,
      created_at TEXT DEFAULT CURRENT_TIMESTAMP
    , common_names TEXT, updated_at TEXT);
CREATE TABLE refill_requests (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      patient_id INTEGER,
      medication_id INTEGER,
      requested_medication TEXT NOT NULL,
      status TEXT DEFAULT 'pending',
      notes TEXT,
      created_at TEXT DEFAULT CURRENT_TIMESTAMP, agent_notes TEXT, fulfilled_at TEXT, updated_at TEXT, request_type TEXT DEFAULT "refill", customer_name TEXT, callback_phone TEXT, quantity_requested INTEGER DEFAULT 1, customer_question TEXT, stock_status TEXT, stock_snapshot INTEGER, ai_payload_json TEXT, validated_address TEXT, address_valid INTEGER DEFAULT 0, address_validation_provider TEXT, address_validation_status TEXT, address_validation_json TEXT, pharmacist_status TEXT DEFAULT 'pending', pharmacist_reviewed_at TEXT, pharmacist_review_note TEXT, rx_number TEXT, medication_strength TEXT, directions_sig TEXT, quantity_display TEXT, refills_display TEXT, prescriber_name TEXT, pharmacy_name TEXT, insurance_provider TEXT, insurance_plan_type TEXT, insurance_member_id TEXT, insurance_group_number TEXT, insurance_bin TEXT, insurance_pcn TEXT, insurance_copay TEXT, insurance_status TEXT DEFAULT 'not_checked', prior_auth_required TEXT DEFAULT 'unknown', insurance_notes TEXT, customer_profile_id INTEGER, known_customer INTEGER DEFAULT 0, preferred_title TEXT, last_name TEXT, fulfillment_method TEXT DEFAULT 'undecided', pickup_requested INTEGER DEFAULT 0, delivery_requested INTEGER DEFAULT 0, pickup_store_id INTEGER, pickup_store_code TEXT, pickup_store_name TEXT, pickup_store_address TEXT, delivery_address TEXT, delivery_address_confirmed INTEGER DEFAULT 0, delivery_instructions TEXT, fulfillment_confirmed INTEGER DEFAULT 0, fulfillment_notes TEXT, date_of_birth TEXT, address TEXT, pharmacist_notes TEXT, pharmacist_reviewed_by TEXT,
      FOREIGN KEY(patient_id) REFERENCES patients(id),
      FOREIGN KEY(medication_id) REFERENCES medications(id)
    );
CREATE TABLE portal_users (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      name TEXT NOT NULL,
      email TEXT,
      username TEXT NOT NULL UNIQUE,
      password_hash TEXT NOT NULL,
      role TEXT NOT NULL DEFAULT 'agent',
      extension TEXT,
      active INTEGER NOT NULL DEFAULT 1,
      created_at TEXT DEFAULT CURRENT_TIMESTAMP,
      updated_at TEXT,
      last_login_at TEXT,
      revoked_at TEXT
    );
CREATE INDEX idx_portal_users_username ON portal_users(username);
CREATE INDEX idx_portal_users_role ON portal_users(role);
CREATE INDEX idx_portal_users_active ON portal_users(active);
CREATE INDEX idx_patients_dob_address ON patients(date_of_birth, address);
CREATE INDEX idx_patients_phone ON patients(phone);
CREATE INDEX idx_patients_email ON patients(email);
CREATE INDEX idx_medications_generic ON medications(generic_name);
CREATE INDEX idx_medications_brand ON medications(brand_name);
CREATE INDEX idx_medications_available ON medications(available);
CREATE TABLE audit_logs (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      actor_user_id INTEGER,
      actor_name TEXT,
      actor_username TEXT,
      actor_role TEXT,
      action TEXT NOT NULL,
      entity_type TEXT,
      entity_id TEXT,
      summary TEXT,
      before_json TEXT,
      after_json TEXT,
      ip_address TEXT,
      created_at TEXT DEFAULT CURRENT_TIMESTAMP
    );
CREATE INDEX idx_audit_logs_created_at ON audit_logs(created_at);
CREATE INDEX idx_audit_logs_actor_user_id ON audit_logs(actor_user_id);
CREATE INDEX idx_audit_logs_action ON audit_logs(action);
CREATE INDEX idx_audit_logs_entity_type ON audit_logs(entity_type);
CREATE TABLE portal_chat_messages (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      order_id INTEGER,
      sender_user_id INTEGER NOT NULL,
      recipient_user_id INTEGER,
      message TEXT NOT NULL,
      created_at TEXT DEFAULT CURRENT_TIMESTAMP
    );
CREATE INDEX idx_chat_messages_order_id ON portal_chat_messages(order_id);
CREATE INDEX idx_chat_messages_sender ON portal_chat_messages(sender_user_id);
CREATE INDEX idx_chat_messages_recipient ON portal_chat_messages(recipient_user_id);
CREATE INDEX idx_chat_messages_created_at ON portal_chat_messages(created_at);
CREATE INDEX idx_chat_messages_id ON portal_chat_messages(id);
CREATE TABLE portal_chat_message_reads (
      message_id INTEGER NOT NULL,
      user_id INTEGER NOT NULL,
      read_at TEXT DEFAULT CURRENT_TIMESTAMP,
      PRIMARY KEY (message_id, user_id)
    );
CREATE INDEX idx_chat_reads_user ON portal_chat_message_reads(user_id);
CREATE INDEX idx_chat_reads_message ON portal_chat_message_reads(message_id);
CREATE INDEX idx_refill_requests_request_type ON refill_requests(request_type);
CREATE INDEX idx_refill_requests_callback_phone ON refill_requests(callback_phone);
CREATE INDEX idx_refill_requests_stock_status ON refill_requests(stock_status);
CREATE TRIGGER trg_refill_decrement_stock_on_fulfilled
    AFTER UPDATE OF status ON refill_requests
    WHEN NEW.status = 'fulfilled'
      AND OLD.status != 'fulfilled'
      AND NEW.medication_id IS NOT NULL
    BEGIN
      UPDATE medications
      SET
        quantity_on_hand = CASE
          WHEN quantity_on_hand IS NULL THEN 0
          WHEN quantity_on_hand - COALESCE(NEW.quantity_requested, 1) > 0
            THEN quantity_on_hand - COALESCE(NEW.quantity_requested, 1)
          ELSE 0
        END,
        available = CASE
          WHEN quantity_on_hand - COALESCE(NEW.quantity_requested, 1) > 0
            THEN 1
          ELSE 0
        END,
        updated_at = CURRENT_TIMESTAMP
      WHERE id = NEW.medication_id;
    END;
CREATE INDEX idx_refill_requests_address_valid ON refill_requests(address_valid);
CREATE INDEX idx_refill_requests_address_validation_status ON refill_requests(address_validation_status);
CREATE TABLE order_review_actions (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      request_id INTEGER,
      action TEXT NOT NULL,
      note TEXT,
      created_by TEXT DEFAULT 'admin_portal',
      created_at TEXT DEFAULT CURRENT_TIMESTAMP
    );
CREATE TABLE customer_profiles (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      preferred_title TEXT,
      first_name TEXT,
      last_name TEXT,
      full_name TEXT,
      date_of_birth TEXT,
      callback_phone TEXT,
      normalized_phone TEXT UNIQUE,
      address TEXT,

      rx_number TEXT,
      prescriber_name TEXT,
      pharmacy_name TEXT,

      insurance_provider TEXT,
      insurance_plan_type TEXT,
      insurance_member_id TEXT,
      insurance_group_number TEXT,
      insurance_bin TEXT,
      insurance_pcn TEXT,
      insurance_copay TEXT,
      insurance_status TEXT DEFAULT 'not_checked',
      prior_auth_required TEXT DEFAULT 'unknown',
      insurance_notes TEXT,

      notes TEXT,
      created_at TEXT DEFAULT CURRENT_TIMESTAMP,
      updated_at TEXT DEFAULT CURRENT_TIMESTAMP
    );
CREATE TABLE pharmacy_stores (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      store_code TEXT UNIQUE,
      store_name TEXT,
      address TEXT,
      city TEXT,
      state TEXT,
      zip TEXT,
      phone TEXT,
      notes TEXT,
      active INTEGER DEFAULT 1,
      created_at TEXT DEFAULT CURRENT_TIMESTAMP,
      updated_at TEXT DEFAULT CURRENT_TIMESTAMP
    );
CREATE TABLE pharmacy_pickup_locations (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      store_key TEXT UNIQUE NOT NULL,
      chain TEXT NOT NULL,
      name TEXT NOT NULL,
      store_number TEXT,
      address1 TEXT NOT NULL,
      city TEXT NOT NULL,
      state TEXT NOT NULL DEFAULT 'MA',
      zip TEXT NOT NULL,
      phone TEXT,
      service_city TEXT,
      service_zip TEXT,
      source TEXT,
      source_url TEXT,
      active INTEGER DEFAULT 1,
      notes TEXT,
      created_at TEXT DEFAULT CURRENT_TIMESTAMP,
      updated_at TEXT DEFAULT CURRENT_TIMESTAMP
    );
