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

function M:connect()
  if self.sock then
    pcall(function() self.sock:disconnect() end)
  end
  self.sock = hs.socket.new(function(data) self:handleData(data) end)
  self.sock:connect(SOCKET_PATH, function()
    self.connected = true
    self.sock:read("\n")
    self:send({ cmd = "ping" })
  end)
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
  if not self.connected or not self.sock then
    print("dbvoice: daemon 未连接，丢弃命令 " .. (obj.cmd or "?"))
    return false
  end
  self.sock:write(hs.json.encode(obj) .. "\n")
  return true
end

-- daemon 挂掉后由 launchd 拉起，这里定期重连
function M:startReconnectWatcher()
  self.watcher = hs.timer.doEvery(3, function()
    if not self.connected then self:connect() end
  end)
end

function M:stop()
  if self.watcher then self.watcher:stop() end
  if self.sock then pcall(function() self.sock:disconnect() end) end
  self.connected = false
end

return M
