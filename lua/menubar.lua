-- 菜单栏图标：idle / recording / disconnected 三态。

local M = {}

local ICONS = {
  idle = "🎙",
  recording = "🔴",
  disconnected = "🚫",
  chatting = "💬",
  thinking = "🤔",
}

local bar = nil

function M.start(handlers)
  bar = hs.menubar.new()
  bar:setTitle(ICONS.idle)
  bar:setTooltip("豆包语音听写")
  bar:setMenu({
    { title = "右 Option = 听写　左 Option = 对话", disabled = true },
    { title = "-" },
    { title = "重开一段对话（清空上下文）", fn = handlers.resetChat },
    { title = "测试录音 5 秒", fn = handlers.testRecord },
    { title = "重连 daemon", fn = handlers.reconnect },
    { title = "-" },
    {
      title = "打开日志",
      fn = function()
        hs.execute("open -a Console " .. os.getenv("HOME") .. "/.doubao-voice/daemon.log")
      end,
    },
    { title = "重载配置", fn = function() hs.reload() end },
  })
  return M
end

function M.setState(state)
  if bar then bar:setTitle(ICONS[state] or ICONS.idle) end
end

function M.stop()
  if bar then bar:delete() end
  bar = nil
end

return M
