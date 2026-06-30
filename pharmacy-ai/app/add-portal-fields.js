'use strict';

const sqlite3 = require('sqlite3').verbose();

const db = new sqlite3.Database('./pharmacy.db');

function columnExists(tableName, columnName) {
  return new Promise(function (resolve, reject) {
    db.all(`PRAGMA table_info(${tableName})`, [], function (err, rows) {
      if (err) return reject(err);

      const exists = rows.some(function (row) {
        return row.name === columnName;
      });

      resolve(exists);
    });
  });
}

function runSql(sql) {
  return new Promise(function (resolve, reject) {
    db.run(sql, function (err) {
      if (err) return reject(err);
      resolve();
    });
  });
}

async function main() {
  console.log('Adding portal fields if missing...');

  if (!(await columnExists('refill_requests', 'agent_notes'))) {
    await runSql(`ALTER TABLE refill_requests ADD COLUMN agent_notes TEXT`);
    console.log('Added agent_notes');
  }

  if (!(await columnExists('refill_requests', 'fulfilled_at'))) {
    await runSql(`ALTER TABLE refill_requests ADD COLUMN fulfilled_at TEXT`);
    console.log('Added fulfilled_at');
  }

  if (!(await columnExists('refill_requests', 'updated_at'))) {
    await runSql(`ALTER TABLE refill_requests ADD COLUMN updated_at TEXT`);
    console.log('Added updated_at');
  }

  console.log('Portal fields are ready.');
}

main()
  .catch(function (err) {
    console.error('Migration failed:', err.message);
    process.exit(1);
  })
  .finally(function () {
    db.close();
  });
