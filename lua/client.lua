-- 控制 socket 客户端：与 dbvoiced 收发换行分隔的 JSON。
--
-- hs.socket 的 read("\n") 是一次性的，收到一行后要重新挂读，
-- 所以每次回调末尾都重新 read 一次。

local M = {}
M.__index = M

local SOCKET_PATH = os.getenv("HOME") .. "/.doubao-voice/ctl.sock"

function M.new(onEvent, onDisconnect)
  local self = setmetatable({}, M)
  self.onEvent = onEvent
  self.onDisconnect = onDisconnect
  self.connected = false
  self:connect()
  return self
end

-- 连接是否真的活着。
--
-- 别信 self.connected 那个缓存标志：daemon 被 launchd 重启或 kickstart 掉时，
-- hs.socket 并不保证回调一次空读，标志就永远停在 true。后果很隐蔽——HUD 是
-- Hammerspoon 本地画的，不经过 socket，所以按键照样出波形、松手照样显示
-- "识别中"，但 start/stop 命令全被 send() 当成"已连接"写进死 socket 丢掉，
-- final 事件永远不来，HUD 就一直停在"识别中"。菜单栏也不会变 🚫，因为
-- onDisconnect 从没被触发。直接问 socket 才是可信的。
function M:isLive()
  if not self.sock then return false end
  local ok, live = pcall(function() return self.sock:connected() end)
  return ok and live == true
end

function M:connect()
  if self.sock then
    pcall(function() self.sock:disconnect() end)
  end
  self.connecting = true
  self.sock = hs.socket.new(function(data) self:handleData(data) end)
  self.sock:connect(SOCKET_PATH, function()
    self.connected = true
    self.connecting = false
    self.sock:read("\n")
    self:send({ cmd = "ping" })
  end)
  -- hs.socket 的 connect 回调只在成功时触发。daemon 真没起来时不清这个
  -- 标志，重连就被自己堵死了，所以到点无条件放开。
  hs.timer.doAfter(2, function() self.connecting = false end)
end

function M:handleData(data)
  if not data or data == "" then
    self.connected = false
    if self.onDisconnect then self.onDisconnect() end
    return
  end
  local line = data:gsub("%s+$", "")
  if line ~= "" then
    local ok, decoded = pcall(hs.json.decode, line)
    if ok and decoded then
      self.onEvent(decoded)
    else
      print("dbvoice: 无法解析事件 " .. line)
    end
  end
  self.sock:read("\n")
end

function M:send(obj)
  if not self:isLive() then
    print("dbvoice: daemon 未连接，丢弃命令 " .. (obj.cmd or "?"))
    -- 立刻标记断开并试着重连，别等看护的下一个 3 秒周期：用户此刻正按着键
    self.connected = false
    if self.onDisconnect then self.onDisconnect() end
    if not self.connecting then self:connect() end
    return false
  end
  self.sock:write(hs.json.encode(obj) .. "\n")
  return true
end

-- daemon 挂掉后由 launchd 拉起，这里定期重连
function M:startReconnectWatcher()
  self.watcher = hs.timer.doEvery(3, function()
    if self:isLive() then return end
    -- 从"活着"跌到"断了"的那一次要通知出去，菜单栏才会变 🚫
    if self.connected then
      self.connected = false
      if self.onDisconnect then self.onDisconnect() end
    end
    if not self.connecting then self:connect() end
  end)
end

function M:stop()
  if self.watcher then self.watcher:stop() end
  if self.sock then pcall(function() self.sock:disconnect() end) end
  self.connected = false
end

return M
