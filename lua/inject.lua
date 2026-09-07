-- 把识别文本送到焦点 App 的光标处：备份剪贴板 → 写入 → Cmd+V → 恢复。
--
-- 已知取舍（见 spec 第 9 节）：
--   * 恢复窗口内用户自己按 Cmd+V 会拿到语音文本。窗口足够窄，不加锁。
--   * 剪贴板原内容超上限时跳过备份，避免几十 MB 图片造成可感知卡顿。

local M = {}

local DEFAULT_RESTORE_MS = 400
local DEFAULT_MAX_BACKUP_BYTES = 10 * 1024 * 1024

function M.paste(text, opts)
  if not text or text == "" then return false, false end

  opts = opts or {}
  local restoreMs = opts.restoreMs or DEFAULT_RESTORE_MS
  local maxBytes = opts.maxBackupBytes or DEFAULT_MAX_BACKUP_BYTES

  local backup, skipped = nil, false
  local ok, contents = pcall(hs.pasteboard.readAllData)
  if ok and contents then
    local size = 0
    for _, data in pairs(contents) do
      if type(data) == "string" then size = size + #data end
    end
    if size <= maxBytes then
      backup = contents
    else
      skipped = true
    end
  end

  hs.pasteboard.setContents(text)
  hs.eventtap.keyStroke({ "cmd" }, "v", 0)

  if backup then
    hs.timer.doAfter(restoreMs / 1000, function()
      pcall(hs.pasteboard.writeAllData, backup)
    end)
  end

  return true, skipped
end

return M
