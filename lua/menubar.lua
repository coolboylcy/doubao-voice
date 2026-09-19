-- 菜单栏图标：idle / recording / disconnected 三态。

local M = {}

-- 使用单色符号，避免 emoji 在不同 macOS 字体下尺寸和颜色不一致。
local STATES = {
  idle = { title = "◉", tooltip = "Doubao Voice · 就绪" },
  recording = { title = "●", tooltip = "Doubao Voice · 正在听写" },
  disconnected = { title = "!", tooltip = "Doubao Voice · 服务未连接" },
}

local bar = nil

function M.start(handlers)
  bar = hs.menubar.new()
  bar:setTitle(STATES.idle.title)
  bar:setTooltip(STATES.idle.tooltip)
  bar:setMenu({
    { title = "按住右 Option 说话", disabled = true },
    { title = "-" },
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
  if bar then
    local item = STATES[state] or STATES.idle
    bar:setTitle(item.title)
    bar:setTooltip(item.tooltip)
  end
end

function M.stop()
  if bar then bar:delete() end
  bar = nil
end

return M
