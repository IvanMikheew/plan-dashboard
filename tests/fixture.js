/*
 * Синтетические фикстуры для тестов дашборда avito.html.
 * Реальных данных владельца здесь НЕТ — только выдуманные числа.
 *
 * Формат результата — как у расшифрованного data/avito.enc:
 *   { updated: "ГГГГ-ММ-ДД", rows: [{date,item,impressions,views,contacts,
 *     bookings,bookingsOld,bookingsNew,source}], edits: ["ГГГГ-ММ-ДД"] }
 *
 * Использование (в tests/harness.html):
 *   var F = AvitoFixtures;
 *   AvitoUI.render(F.main());      // фикстура SPEC R1: 888/1967, темп 103/нед
 *   AvitoUI.render(F.pagi(40));    // 40 подряд идущих дней (пагинация/график)
 *   AvitoUI.render(F.one());       // 1 день (краевой случай «нет данных»)
 */
(function (root) {
  'use strict';

  function pad(n) { return (n < 10 ? '0' : '') + n; }
  function isoOf(ms) {
    var d = new Date(ms);
    return d.getUTCFullYear() + '-' + pad(d.getUTCMonth() + 1) + '-' + pad(d.getUTCDate());
  }
  function parse(d) { return Date.parse(d + 'T00:00:00Z'); }
  function addDays(d, n) { return isoOf(parse(d) + n * 86400000); }
  function dayDiff(a, b) { return Math.round((parse(b) - parse(a)) / 86400000); }
  function todayLocal() {
    var t = new Date();
    return t.getFullYear() + '-' + pad(t.getMonth() + 1) + '-' + pad(t.getDate());
  }
  // якорь страницы: min(последняя дата данных, вчера)
  function anchor() { return addDays(todayLocal(), -1); }

  function mk(date, imp, views, con, bNew, bOld) {
    var hasB = !(bNew === null && bOld === null);
    return {
      date: date, item: '8547421312',
      impressions: imp, views: views, contacts: con,
      bookings: hasB ? (bNew || 0) + (bOld || 0) : null,
      bookingsOld: hasB ? bOld : null,
      bookingsNew: hasB ? bNew : null,
      source: 'avito'
    };
  }

  // ---- основная фикстура (SPEC R1 / R5) --------------------------------
  // 37 дней календарного размаха, 33 строки, 4 пропуска дат (−2, −4, −10, −25):
  //   Σ показов за 7 дней = 888, за прошлую неделю = 800, всего = 1 967;
  //   Σ просмотров за 7 дней = 103, за 14 дней = 206 → темп 103/нед;
  //   контакты 10 (7 дн.) / 22 (всего); записи: новые 7, старые 3.
  var IMP = { '0': 228, '-1': 210, '-3': 160, '-5': 140, '-6': 150,
              '-7': 150, '-8': 135, '-9': 140, '-11': 125, '-12': 130, '-13': 120 };
  var VIEW = { '0': 23, '-1': 23, '-3': 22, '-5': 17, '-6': 18,
               '-7': 19, '-8': 18, '-9': 18, '-11': 17, '-12': 16, '-13': 15 };
  var CON = { '0': 2, '-1': 2, '-3': 2, '-5': 2, '-6': 2,
              '-7': 2, '-8': 2, '-9': 2, '-11': 2, '-12': 2, '-13': 2 };
  // [новые, старые]; отсутствующий смещение = данных нет (null)
  var BOOK = { '0': [1, 1], '-3': [1, 0], '-5': [0, 1], '-6': [1, 0],
               '-7': [2, 0], '-9': [1, 1], '-11': [0, 1], '-13': [1, 0] };

  function main(opts) {
    var green = !!(opts && opts.green);
    var a = anchor();
    var rows = [];
    var i = 0, off, date, b;
    // старшие 23 дня (−36…−14, без −25): 15 строк по 13 показов + 7 по 12 = 279
    for (off = -36; off <= -14; off++) {
      if (off === -25) continue;
      rows.push(mk(addDays(a, off), i < 15 ? 13 : 12, 2, 0, null, null));
      i++;
    }
    // последние 14 дней (−13…0, без −2, −4, −10)
    for (off = -13; off <= 0; off++) {
      if (off === -2 || off === -4 || off === -10) continue;
      b = BOOK[String(off)] || null;
      // green: просмотры ×3 → темп 309/нед, прогноз 618 ≥ 475 («Успеваем»)
      rows.push(mk(addDays(a, off), IMP[String(off)],
        VIEW[String(off)] * (green && off >= -13 ? 3 : 1), CON[String(off)],
        b ? b[0] : null, b ? b[1] : null));
    }
    return { updated: todayLocal(), rows: rows, edits: [addDays(a, -3)] };
  }

  // n подряд идущих дней без пропусков (пагинация, графики, края)
  function pagi(n) {
    var a = anchor(), rows = [];
    for (var off = -(n - 1); off <= 0; off++) {
      rows.push(mk(addDays(a, off), 10, 5, 1, null, null));
    }
    return { updated: todayLocal(), rows: rows, edits: [] };
  }

  // данные «в будущем» (ошибочные даты) → окно 7 дней пустое → «нет данных»
  function future() {
    var d = addDays(todayLocal(), 1);
    return { updated: todayLocal(), rows: [mk(d, 10, 5, 1, null, null)], edits: [] };
  }

  // один день данных
  function one() { return pagi(1); }

  // есть контакты, но записей НЕТ (0) → конверсия «—» (ADR-0007)
  function zero() {
    var a = anchor(), rows = [];
    for (var off = -9; off <= 0; off++) {
      rows.push(mk(addDays(a, off), 10, 5, 2, 0, 0));
    }
    return { updated: todayLocal(), rows: rows, edits: [] };
  }

  root.AvitoFixtures = {
    pad: pad, addDays: addDays, dayDiff: dayDiff,
    todayLocal: todayLocal, anchor: anchor,
    main: main, pagi: pagi, future: future, one: one, zero: zero
  };
})(typeof window !== 'undefined' ? window : this);
