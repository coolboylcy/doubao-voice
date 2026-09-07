-- 串联：右 Option 事件 → 状态机 → 动作分发。

local state = require("doubao-voice.state")
local Client = require("doubao-voice.client")
local hud = require("doubao-voice.hud")
local inject = require("doubao-voice.inject")
local menubar = require("doubao-voice.menubar")

local M = {}

local CONFIG_PATH = os.getenv("HOME") .. "/.doubao-voice/config.json"

-- CGEvent 的设备相关位（IOKit NX_DEVICE*KEYMASK）。这些位才能区分左右，
-- 通用的 kCGEventFlagMaskAlternate(0x00080000) 区分不了。
-- 用 `hs -c 'return DBVOICE.probeFlags()'` 可实测校验。
local MASK_RIGHT_ALT = 0x00000040
local MASK_LEFT_ALT = 0x00000020

local DEFAULTS = {
  long_press_ms = 300,
  max_recording_seconds = 120,
  silence_cancel_ms = 3000,
  clipboard_restore_ms = 400,
  clipboard_backup_max_bytes = 10485760,
}

local cfg = DEFAULTS
local current = state.IDLE
local client = nil
local timers = { longpress = nil, silence = nil, max = nil }
local lastText = ""
local altDown = false


local function loadConfig()
  local merged = {}
  for k, v in pairs(DEFAULTS) do merged[k] = v end
  local f = io.open(CONFIG_PATH, "r")
  if f then
    local body = f:read("*a")
    f:close()
    local ok, parsed = pcall(hs.json.decode, body)
    if ok and parsed then
      for k, v in pairs(parsed) do
        if merged[k] ~= nil then merged[k] = v end
      end
    end
  end
  return merged
end

local function stopTimer(name)
  if timers[name] then
    timers[name]:stop()
    timers[name] = nil
  end
end

-- 必须定义在 onEvent 之前：Lua 的 local 只对其后的代码可见，
-- 定义在后面的话 onEvent 里拿到的是 nil 全局变量，出错时才崩

local function fire(event)
  local newState, actions = state.step(current, event)
  current = newState
  for _, action in ipairs(actions) do
    M.perform(action)
  end
end

function M.perform(action)
  if action == "send_start" then
    lastText = ""
    client:send({ cmd = "start" })
  elseif action == "send_stop" then
    client:send({ cmd = "stop" })
    -- 2.0 是整段说完才出文本，这段等待有 1-2 秒，不给反馈会以为卡死了
    hud.setPending("识别中……")
  elseif action == "send_cancel" then
    client:send({ cmd = "cancel" })

  elseif action == "start_longpress_timer" then
    stopTimer("longpress")
    timers.longpress = hs.timer.doAfter(cfg.long_press_ms / 1000, function()
      timers.longpress = nil
      fire("longpress_timer")
    end)
  elseif action == "cancel_longpress_timer" then
    stopTimer("longpress")

  elseif action == "start_silence_timer" or action == "reset_silence_timer" then
    stopTimer("silence")
    timers.silence = hs.timer.doAfter(cfg.silence_cancel_ms / 1000, function()
      timers.silence = nil
      fire("silence_timer")
    end)
  elseif action == "cancel_silence_timer" then
    stopTimer("silence")

  elseif action == "start_max_timer" then
    stopTimer("max")
    timers.max = hs.timer.doAfter(cfg.max_recording_seconds, function()
      timers.max = nil
      fire("max_timer")
    end)
  elseif action == "cancel_max_timer" then
    stopTimer("max")

  elseif action == "show_hud" then
    hud.show()
    menubar.setState("recording")
  elseif action == "hide_hud" then
    hud.hide()
    menubar.setState("idle")
  elseif action == "show_empty" then
    hud.flash("没听到", 1.5)
    menubar.setState("idle")
  elseif action == "show_error" then
    menubar.setState("idle")

  elseif action == "inject" then
    local _, skipped = inject.paste(lastText, {
      restoreMs = cfg.clipboard_restore_ms,
      maxBackupBytes = cfg.clipboard_backup_max_bytes,
    })
    if skipped then
      hs.notify.new({
        title = "豆包听写",
        informativeText = "剪贴板内容过大，未保留原内容",
      }):send()
    end
  end
end

local function onEvent(e)
  if e.event == "level" then
    -- daemon 每包音频报一次电平：peak 喂给波形，voiced 供静音判定。
    -- 豆包 2.0 只有 nostream 模式，整段说完才给文本，静音判定拿不到
    -- 服务端增量，只能靠本地音量。
    hud.setLevel(e.peak)
    if e.voiced then fire("voice") end
  elseif e.event == "partial" then
    -- 2.0 走 nostream，实际只有末包才带文本，这条留给日后换回双向流式。
    lastText = e.text or ""
    if lastText ~= "" then hud.setText(lastText) end
  elseif e.event == "final" then
    lastText = e.text or ""
    fire("final")
  elseif e.event == "empty" then
    fire("empty")
  elseif e.event == "cancelled" then
    fire("cancelled")
  elseif e.event == "error" then
    local code = (e.code and e.code ~= "") and ("[" .. e.code .. "] ") or ""
    hud.flashError(code .. (e.message or "未知错误"))
    fire("error")
  elseif e.event == "pong" then
    menubar.setState("idle")
  end
end

-- 实测左右 Option 的 CGEvent 位掩码，用于排查
function M.probeFlags()
  local seen = {}
  local tap
  tap = hs.eventtap.new({ hs.eventtap.event.types.flagsChanged }, function(ev)
    local f = ev:getRawEventData().CGEventData.flags
    table.insert(seen, string.format("0x%08X R=%s L=%s", f,
      tostring((f & MASK_RIGHT_ALT) ~= 0), tostring((f & MASK_LEFT_ALT) ~= 0)))
    return false
  end)
  tap:start()
  hs.timer.doAfter(10, function()
    tap:stop()
    hs.alert.show("探针结果:\n" .. table.concat(seen, "\n"), 8)
  end)
  return "10 秒内按左右 Option，结果会弹出来"
end

function M.start()
  cfg = loadConfig()

  -- 关机重启后热键要还在。daemon 那头由 launchd 的 RunAtLoad 管，
  -- Hammerspoon 自己不设这个就不会开机启动。
  if not hs.autoLaunch() then hs.autoLaunch(true) end

  menubar.start({
    testRecord = function()
      fire("key_down")
      hs.timer.doAfter(5, function()
        if current == state.PTT or current == state.PENDING then fire("key_up") end
      end)
    end,
    reconnect = function() client:connect() end,
  })

  client = Client.new(onEvent, function()
    menubar.setState("disconnected")
  end)
  client:startReconnectWatcher()

  -- 右 Option 按下/松手，边沿触发。
  M.flagsTap = hs.eventtap.new({ hs.eventtap.event.types.flagsChanged }, function(ev)
    local flags = ev:getRawEventData().CGEventData.flags

    local rightDown = (flags & MASK_RIGHT_ALT) ~= 0
    if rightDown and not altDown then
      altDown = true
      fire("key_down")
    elseif not rightDown and altDown then
      altDown = false
      fire("key_up")
    end

    return false -- 绝不吞掉，Option 与其他键的组合必须照常工作
  end)
  M.flagsTap:start()

  -- Esc 仅在录音态或对话进行中被消费；其余时刻必须透传，
  -- 否则 vim 用户会当场崩溃
  M.escTap = hs.eventtap.new({ hs.eventtap.event.types.keyDown }, function(ev)
    if ev:getKeyCode() ~= hs.keycodes.map.escape then return false end
    if not state.consumes_esc(current) then return false end
    fire("esc")
    return true -- 吞掉，不让 Esc 传给焦点 App
  end)
  M.escTap:start()

  print("dbvoice: 已启动，热键为右 Option")
  return M
end

function M.stop()
  if M.flagsTap then M.flagsTap:stop() end
  if M.escTap then M.escTap:stop() end
  for name in pairs(timers) do stopTimer(name) end
  if client then client:stop() end
  menubar.stop()
  hud.hide()
end

return M
