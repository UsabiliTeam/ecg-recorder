# Feedback bot (Telegram -> Google Sheet)

Users chat with a Telegram bot; each message becomes a row in a Google Sheet, and photos land in a Drive
folder linked from the row. `/bug ...` and `/idea ...` label a message; anything else is a `note`.

## Setup (about 10 minutes, all in your own accounts)

1. **Bot**: in Telegram, message `@BotFather`, send `/newbot`, pick a name. Copy the token.
2. **Sheet**: create a Google Sheet. Extensions > Apps Script. Replace `Code.gs` with this folder's `Code.gs`.
3. **Folder**: create a Drive folder for images. Copy its ID (the part after `/folders/` in the URL).
4. **Properties**: in Apps Script, Project Settings > Script properties, add
   `BOT_TOKEN` (step 1), `SECRET` (any long random string), `FOLDER_ID` (step 3).
5. **Deploy**: Deploy > New deployment > type Web app. Execute as: Me. Who has access: Anyone.
   Approve the permissions (Sheets, Drive, external requests).
6. **Connect**: in the editor, pick `setWebhook` and press Run. The log should say `"ok":true`.
7. Send the bot a message and a photo; both should appear in the `Feedback` tab.

After changing the code: Deploy > Manage deployments > edit > New version (keeps the URL; no need to rerun
`setWebhook`). `webhookInfo` shows Telegram's last delivery error if rows stop arriving.

## Notes

- "Anyone" access is needed for Telegram to reach the script; the `SECRET` in the URL keeps others out.
- Telegram retries deliveries it considers failed; the script handles each `update_id` once.
- Images: the sheet row has the Drive link and file ID. Claude can read them through the Google Drive
  connector (connect it in claude.ai settings), or you download the folder and share the files.
