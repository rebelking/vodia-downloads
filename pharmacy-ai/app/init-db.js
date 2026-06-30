'use strict';

const sqlite3 = require('sqlite3').verbose();

const db = new sqlite3.Database('./pharmacy.db');

db.serialize(function () {
  console.log('Creating pharmacy database...');

  db.run(`
    CREATE TABLE IF NOT EXISTS patients (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      first_name TEXT NOT NULL,
      last_name TEXT NOT NULL,
      date_of_birth TEXT NOT NULL,
      address TEXT NOT NULL,
      phone TEXT,
      created_at TEXT DEFAULT CURRENT_TIMESTAMP
    )
  `);

  db.run(`
    CREATE TABLE IF NOT EXISTS medications (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      generic_name TEXT NOT NULL,
      brand_name TEXT,
      available INTEGER DEFAULT 1,
      quantity_on_hand INTEGER DEFAULT 0,
      notes TEXT,
      created_at TEXT DEFAULT CURRENT_TIMESTAMP
    )
  `);

  db.run(`
    CREATE TABLE IF NOT EXISTS refill_requests (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      patient_id INTEGER,
      medication_id INTEGER,
      requested_medication TEXT NOT NULL,
      status TEXT DEFAULT 'pending',
      notes TEXT,
      created_at TEXT DEFAULT CURRENT_TIMESTAMP,
      FOREIGN KEY(patient_id) REFERENCES patients(id),
      FOREIGN KEY(medication_id) REFERENCES medications(id)
    )
  `);

  console.log('Tables created.');

  db.run(`
    INSERT INTO patients 
    (first_name, last_name, date_of_birth, address, phone)
    VALUES 
    ('Test', 'Patient', '01/01/1980', '123 Main Street', '555-111-2222')
  `);

  db.run(`
    INSERT INTO medications
    (generic_name, brand_name, available, quantity_on_hand, notes)
    VALUES
    ('metformin', 'Glucophage', 1, 120, 'Common diabetes medication'),
    ('lisinopril', 'Prinivil', 1, 80, 'Blood pressure medication'),
    ('atorvastatin', 'Lipitor', 0, 0, 'Temporarily out of stock'),
    ('amlodipine', 'Norvasc', 1, 50, 'Blood pressure medication')
  `);

  console.log('Sample data inserted.');
});

db.close(function () {
  console.log('Database setup complete.');
});
