/**
 * ECG Recorder feedback bot: Telegram chat -> Google Sheet (+ images in a Drive folder).
 *
 * Users chat with the bot. Every message becomes a row; photos (and images sent as files) are saved to a
 * Drive folder and linked from the row. Start a message with /bug or /idea to label it; anything else is
 * "note". Setup: see README.md next to this file.
 *
 * Script properties (Project Settings > Script properties):
 *   BOT_TOKEN  from @BotFather
 *   SECRET     any long random string; the webhook URL carries it, so strangers can't write rows
 *   FOLDER_ID  Drive folder for images (the part after /folders/ in its URL)
 */

const SHEET_NAME = 'Feedback';
const HEADER = ['received', 'user', 'chat_id', 'kind', 'text', 'image', 'image_file_id', 'update_id'];
const MAX_IMAGE_BYTES = 20 * 1024 * 1024; // Telegram's own download limit for bots

function props_() {
  return PropertiesService.getScriptProperties();
}

function doPost(e) {
  // Apps Script can't read request headers, so the shared secret travels in the URL (?key=...).
  if (!e || !e.parameter || e.parameter.key !== props_().getProperty('SECRET')) {
    return ContentService.createTextOutput('forbidden');
  }
  const lock = LockService.getScriptLock();
  lock.waitLock(20000);
  try {
    const update = JSON.parse(e.postData.contents);
    // Telegram re-sends an update when it doesn't like the reply (Apps Script answers with a redirect),
    // so each update_id is handled once.
    const cache = CacheService.getScriptCache();
    const seen = 'u' + update.update_id;
    if (cache.get(seen)) return ContentService.createTextOutput('ok');
    cache.put(seen, '1', 21600);
    handleUpdate_(update);
  } catch (err) {
    console.error(err);
  } finally {
    lock.releaseLock();
  }
  return ContentService.createTextOutput('ok');
}

function handleUpdate_(update) {
  const msg = update.message || update.edited_message;
  if (!msg) return;
  const chatId = msg.chat.id;
  let text = (msg.text || msg.caption || '').trim();

  if (text === '/start' || text === '/help') {
    reply_(chatId, 'Hi! Send me a bug, an idea, or a screenshot.\n' +
      'Start with /bug or /idea to label it. Everything lands with the team.');
    return;
  }

  let kind = 'note';
  const label = text.match(/^\/(bug|idea)\b\s*/i);
  if (label) {
    kind = label[1].toLowerCase();
    text = text.slice(label[0].length);
  }

  const image = saveImage_(msg);
  if (!text && !image) {
    reply_(chatId, 'I can take text, photos and image files. Try again?');
    return;
  }

  const from = msg.from || {};
  const user = from.username ? '@' + from.username : [from.first_name, from.last_name].filter(String).join(' ');
  sheet_().appendRow([
    new Date(msg.date * 1000), safe_(user), String(chatId), kind, safe_(text),
    image ? image.url : '', image ? image.fileId : '', update.update_id,
  ]);
  reply_(chatId, kind === 'bug' ? 'Got it, bug logged. Thanks!' : 'Got it. Thanks!');
}

/** Largest version of a photo, or an image sent as a file. Saved to Drive; returns its link. */
function saveImage_(msg) {
  let fileId = null;
  let name = 'image';
  if (msg.photo && msg.photo.length) {
    fileId = msg.photo[msg.photo.length - 1].file_id;
    name = 'photo.jpg';
  } else if (msg.document && /^image\//.test(msg.document.mime_type || '')) {
    fileId = msg.document.file_id;
    name = msg.document.file_name || 'image';
  }
  if (!fileId) return null;

  const token = props_().getProperty('BOT_TOKEN');
  const info = JSON.parse(UrlFetchApp.fetch(
    'https://api.telegram.org/bot' + token + '/getFile?file_id=' + encodeURIComponent(fileId)).getContentText());
  if (!info.ok || (info.result.file_size || 0) > MAX_IMAGE_BYTES) return null;
  const blob = UrlFetchApp.fetch('https://api.telegram.org/file/bot' + token + '/' + info.result.file_path).getBlob();
  const stamp = Utilities.formatDate(new Date(msg.date * 1000), 'UTC', 'yyyyMMdd_HHmmss');
  blob.setName(stamp + '_' + msg.chat.id + '_' + name.replace(/[^\w.\-]/g, '_'));
  const file = DriveApp.getFolderById(props_().getProperty('FOLDER_ID')).createFile(blob);
  return { url: file.getUrl(), fileId: file.getId() };
}

function sheet_() {
  const book = SpreadsheetApp.getActiveSpreadsheet();
  let sheet = book.getSheetByName(SHEET_NAME);
  if (!sheet) {
    sheet = book.insertSheet(SHEET_NAME);
    sheet.appendRow(HEADER);
    sheet.setFrozenRows(1);
  }
  return sheet;
}

/** A leading = + - @ would run as a formula in the sheet (same rule as the app's CSVs). */
function safe_(s) {
  return /^[=+\-@]/.test(s) ? "'" + s : s;
}

function reply_(chatId, text) {
  UrlFetchApp.fetch('https://api.telegram.org/bot' + props_().getProperty('BOT_TOKEN') + '/sendMessage', {
    method: 'post',
    contentType: 'application/json',
    payload: JSON.stringify({ chat_id: chatId, text: text }),
    muteHttpExceptions: true,
  });
}

/** Run once after each new deployment: points Telegram at this script's web app URL. */
function setWebhook() {
  const url = ScriptApp.getService().getUrl() + '?key=' + encodeURIComponent(props_().getProperty('SECRET'));
  const res = UrlFetchApp.fetch('https://api.telegram.org/bot' + props_().getProperty('BOT_TOKEN') +
    '/setWebhook?drop_pending_updates=true&url=' + encodeURIComponent(url));
  console.log(res.getContentText());
}

/** For checking: shows Telegram's view of the webhook, including the last error. */
function webhookInfo() {
  console.log(UrlFetchApp.fetch('https://api.telegram.org/bot' + props_().getProperty('BOT_TOKEN') +
    '/getWebhookInfo').getContentText());
}
