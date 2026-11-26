/*
 * Генерирует tests/test.enc — СИНТЕТИЧЕСКИЕ данные в контрактном формате
 * (base64(salt‖iv‖ct+tag), PBKDF2 200k, AES-256-GCM) через tools/crypt.js.
 * Нужен для регрессионного теста расшифровки в tests/harness.html:
 * пароль синтетический (TEST_ENC_PASSWORD, по умолчанию fixture-test) —
 * это НЕ секрет владельца, реальных данных в файле нет.
 * Запуск: node tests/make_test_enc.js
 */
'use strict';
const fs = require('fs');
const path = require('path');
const { execFileSync } = require('child_process');

const F = require('./fixture.js').AvitoFixtures;
const fix = F.main();
const json = JSON.stringify({ updated: fix.updated, rows: fix.rows, edits: fix.edits });

const tmp = path.join(__dirname, '_fixture.json');
const out = path.join(__dirname, 'test.enc');
fs.writeFileSync(tmp, json, 'utf8');
try {
  execFileSync(process.execPath, [
    path.join(__dirname, '..', 'tools', 'crypt.js'), 'encrypt',
    '--in', tmp, '--out', out
  ], {
    env: Object.assign({}, process.env, {
      PLAN_PASSWORD: process.env.TEST_ENC_PASSWORD || 'fixture-test'
    }),
    stdio: ['ignore', 'inherit', 'inherit']
  });
} finally {
  try { fs.unlinkSync(tmp); } catch (e) {}
}
console.log('OK: ' + out + ' (' + fs.statSync(out).size + ' bytes)');
