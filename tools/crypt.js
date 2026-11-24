#!/usr/bin/env node
'use strict';
/*
 * crypt.js — шифрование/расшифровка плана.
 *
 * ФОРМАТ (контрактный, НЕ менять):
 *   data/plan.enc = base64( 16 байт salt ‖ 12 байт IV ‖ AES-256-GCM ciphertext+tag )
 *   key = PBKDF2-HMAC-SHA256(password, salt, 200000 итераций, 32 байта)
 *
 * Пароль ТОЛЬКО из переменной окружения PLAN_PASSWORD (не аргумент, не файл).
 * Тот же формат расшифровывается в браузере через WebCrypto (см. index.html).
 *
 * Использование:
 *   node tools/crypt.js encrypt --in <файл> [--out <файл>]   → base64 на stdout
 *   node tools/crypt.js decrypt --in <файл> [--out <файл>]   → открытый текст на stdout
 *   (без --in читается stdin, без --out пишется stdout)
 */
const crypto = require('crypto');
const fs = require('fs');

const ITER = 200000;
const SALT_LEN = 16;
const IV_LEN = 12;
const TAG_LEN = 16;
const KEY_LEN = 32;

function getPassword() {
  const pw = process.env.PLAN_PASSWORD;
  if (!pw) {
    process.stderr.write('ERROR: переменная окружения PLAN_PASSWORD не задана (пароль не передаётся аргументом)\n');
    process.exit(2);
  }
  return pw;
}

function encrypt(plainBuf, password) {
  const salt = crypto.randomBytes(SALT_LEN);
  const iv = crypto.randomBytes(IV_LEN);
  const key = crypto.pbkdf2Sync(password, salt, ITER, KEY_LEN, 'sha256');
  const cipher = crypto.createCipheriv('aes-256-gcm', key, iv);
  const ct = Buffer.concat([cipher.update(plainBuf), cipher.final()]);
  const tag = cipher.getAuthTag();
  return Buffer.concat([salt, iv, ct, tag]).toString('base64');
}

function decrypt(b64, password) {
  const raw = Buffer.from(String(b64).replace(/\s+/g, ''), 'base64');
  if (raw.length < SALT_LEN + IV_LEN + TAG_LEN) {
    throw new Error('файл повреждён: слишком короткий');
  }
  const salt = raw.subarray(0, SALT_LEN);
  const iv = raw.subarray(SALT_LEN, SALT_LEN + IV_LEN);
  const body = raw.subarray(SALT_LEN + IV_LEN);
  const ct = body.subarray(0, body.length - TAG_LEN);
  const tag = body.subarray(body.length - TAG_LEN);
  const key = crypto.pbkdf2Sync(password, salt, ITER, KEY_LEN, 'sha256');
  const d = crypto.createDecipheriv('aes-256-gcm', key, iv);
  d.setAuthTag(tag);
  return Buffer.concat([d.update(ct), d.final()]); // неверный пароль → throw (auth failed)
}

function readInput(argIn) {
  if (argIn) return fs.readFileSync(argIn);
  return fs.readFileSync(0); // stdin
}

function main() {
  const args = process.argv.slice(2);
  const mode = args[0];
  if (mode !== 'encrypt' && mode !== 'decrypt') {
    process.stderr.write('Usage: node crypt.js (encrypt|decrypt) [--in file] [--out file]\n');
    process.exit(2);
  }
  const iIn = args.indexOf('--in');
  const iOut = args.indexOf('--out');
  const inFile = iIn >= 0 ? args[iIn + 1] : null;
  const outFile = iOut >= 0 ? args[iOut + 1] : null;
  const password = getPassword();

  const input = readInput(inFile);
  let output;
  if (mode === 'encrypt') {
    output = Buffer.from(encrypt(input, password), 'ascii');
  } else {
    output = decrypt(input.toString('utf8'), password);
  }
  if (outFile) {
    fs.writeFileSync(outFile, output);
  } else {
    process.stdout.write(output);
  }
}

try {
  main();
} catch (e) {
  process.stderr.write('ERROR: ' + (e && e.message ? e.message : String(e)) + '\n');
  process.exit(1);
}
