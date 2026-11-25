# Google Apps Script → веб-API календаря (без Google Cloud)

Вместо скачивания всего ICS-файла клиент `calendar_api.ps1` запрашивает только
нужный диапазон дат у веб-приложения Google Apps Script. Ссылка — секрет
(как текущая ICS): не писать в отчёты, git, логи и чаты.

Формат ответа (GET `?from=yyyy-MM-dd&to=yyyy-MM-dd`):

```json
[{"summary":"...","start":"2026-11-16T08:30:00.000Z","end":"2026-11-16T09:30:00.000Z","allDay":false,"marked":"new"}]
```

- `start`/`end` — ISO-8601 в UTC; клиент переводит в Asia/Krasnoyarsk (UTC+7).
- `marked` — `"new"` (в названии «новый/новая/новые»), `"old"` («старый/старая/старые»),
  иначе `null`. Регистр не важен; если слово «старый» и «новый» вместе — `"old"`
  (как в ICS-парсере).
- Удалённые события Google не отдаёт. Отменённые вхождения повторяющихся событий
  CalendarApp обычно тоже не возвращает — **проверь вручную** на реальных данных
  (сверить счётчиков API и ICS за один период).

---

## 1. Код Apps Script (копировать целиком)

Создай проект на <https://script.google.com> и замени содержимое `Code.gs` на:

```javascript
/**
 * calendar_api — события Google Calendar как JSON для plan-dashboard.
 * GET <url>?from=yyyy-MM-dd&to=yyyy-MM-dd
 * → [{summary, start, end, allDay, marked}]  (marked: "new" | "old" | null)
 * URL секретный (как ICS): не писать в отчёты/git/логи.
 * Развёртывание — см. пошаговую инструкцию ниже (apps_script_setup.md).
 */
function doGet(e) {
  var p = (e && e.parameter) || {};
  var from = String(p.from || '');
  var to = String(p.to || '');
  var re = /^\d{4}-\d{2}-\d{2}$/;
  if (!re.test(from) || !re.test(to)) {
    return json_({ error: 'нужны from и to в формате yyyy-MM-dd' });
  }
  if (to < from) return json_({ error: 'to раньше from' });

  // Границы: from 00:00 … (to+1 сутки) 00:00 по Asia/Krasnoyarsk (UTC+7).
  var start = new Date(from + 'T00:00:00+07:00');
  var end = new Date(new Date(to + 'T00:00:00+07:00').getTime() + 86400000);

  var events = CalendarApp.getDefaultCalendar().getEvents(start, end);
  var out = [];
  for (var i = 0; i < events.length; i++) {
    var ev = events[i];
    var title = ev.getTitle() || '';
    out.push({
      summary: title,
      start: utcIso_(ev.getStartTime()),
      end: utcIso_(ev.getEndTime()),
      allDay: ev.isAllDayEvent(),
      marked: /стары/i.test(title) ? 'old' : (/новы/i.test(title) ? 'new' : null)
    });
  }
  return json_(out);
}

// Date → ISO-8601 UTC, независимо от часового пояса проекта скрипта
function utcIso_(d) {
  return Utilities.formatDate(d, 'UTC', "yyyy-MM-dd'T'HH:mm:ss'Z'");
}

function json_(obj) {
  return ContentService.createTextOutput(JSON.stringify(obj))
    .setMimeType(ContentService.MimeType.JSON);
}
```

## 2. Пошаговая инструкция (точные кнопки)

1. Открыть <https://script.google.com> (аккаунт владельца) → слева «**Новый
   проект**» (кнопка «+») → проект называется, например, `calendar_api`.
2. В редакторе выделить всё в `Code.gs` (Ctrl+A), вставить код выше, **Ctrl+S**.
3. Кнопка «**Развернуть**» справа вверху → «**Новое развёртывание**» → у значка
   шестерёнки «**Выбрать тип**» → «**Веб-приложение**»:
   - Описание: `calendar_api`
   - **Выполнять от:** «Моего имени»
   - **Доступ:** «Любой, у кого есть ссылка»
   → кнопка «**Развернуть**».
4. Первый запуск попросит доступ: «Авторизация доступа» → «Просмотр разрешений»
   → выбрать аккаунт → «**Дополнительно**» → «**Перейти к (небезопасно)**»
   (Google так пишет про скрипты, которые написал сам владелец) → «**Разрешить**»
   (доступ к календарю).
5. «**Скопировать URL**» (вида `https://script.google.com/macros/s/.../exec`).
   Отправить его агенту — он добавит в `.env` строку
   `CALENDAR_API_URL=<ваш URL>` (значение не светить в отчётах/git/логах).
6. Проверка в браузере: открыть `<URL>?from=2026-11-15&to=2026-11-24` — должен
   вернуться JSON-массив событий.

**При правке кода** (URL не изменится): «Развернуть» → «Управление
развёртываниями» → карандаш ✏️ → «Версия»: «Новая» → «Развернуть».

## 3. Что делает дальше клиент

- `tools/calendar_api.ps1` читает `CALENDAR_API_URL` из окружения или `.env`,
  шлёт `?from=&to=` (диапазон — даты CSV), считает записи новые/старые по дням
  и обновляет колонки CSV (схема та же, что у `calendar_stats.ps1`).
- Если `CALENDAR_API_URL` пуст или запрос упал — клиент сам падает на текущий
  ICS-парсинг (`calendar_stats.ps1`), заливка не ломается.
- Для локальных тестов вместо URL можно указать путь к JSON-файлу
  (или `file://...`) — клиент прочитает его без HTTP.
