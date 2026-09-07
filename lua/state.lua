-- 热键状态机。纯函数，零 hs 依赖，可用标准 lua 解释器跑测试。
--
-- 核心决策（见 spec 第 8 节）：按下的瞬间无法区分短按与长按，所以两种
-- 模式都从按下即刻开始录音，靠松手时机决定语义。若等 300ms 确认是长按
-- 再开录，PTT 开头 300ms 的语音必然丢失——而人往往按下的同时就开口。
--
-- 静音取消只对 TOGGLE 生效：PENDING → PTT 的转移显式取消静音定时器，
-- 因为 PTT 下按住键思考四五秒再开口完全正常。

local M = {}

M.IDLE = "IDLE"
M.PENDING = "PENDING"
M.PTT = "PTT"
M.TOGGLE = "TOGGLE"

local RECORDING = { [M.PENDING] = true, [M.PTT] = true, [M.TOGGLE] = true }

-- Esc 只在录音态被消费，其余时刻必须透传给焦点 App
function M.consumes_esc(state)
  return RECORDING[state] == true
end

local function cancel_all()
  return {
    "send_cancel",
    "cancel_longpress_timer",
    "cancel_silence_timer",
    "cancel_max_timer",
    "hide_hud",
  }
end

local function stop_all()
  return {
    "send_stop",
    "cancel_longpress_timer",
    "cancel_silence_timer",
    "cancel_max_timer",
  }
end

local TABLE = {
  [M.IDLE] = {
    key_down = function()
      return M.PENDING, {
        "send_start",
        "start_longpress_timer",
        "start_silence_timer",
        "start_max_timer",
        "show_hud",
      }
    end,
    final = function() return M.IDLE, { "inject", "hide_hud" } end,
    empty = function() return M.IDLE, { "show_empty" } end,
    error = function() return M.IDLE, { "show_error" } end,
    cancelled = function() return M.IDLE, { "hide_hud" } end,
  },

  [M.PENDING] = {
    longpress_timer = function()
      return M.PTT, { "cancel_silence_timer" }
    end,
    key_up = function() return M.TOGGLE, {} end,
    esc = function() return M.IDLE, cancel_all() end,
    silence_timer = function() return M.IDLE, cancel_all() end,
    max_timer = function() return M.IDLE, stop_all() end,
    voice = function() return M.PENDING, { "reset_silence_timer" } end,
    error = function()
      return M.IDLE, {
        "cancel_longpress_timer",
        "cancel_silence_timer",
        "cancel_max_timer",
        "show_error",
      }
    end,
  },

  [M.PTT] = {
    key_up = function() return M.IDLE, stop_all() end,
    esc = function() return M.IDLE, cancel_all() end,
    max_timer = function() return M.IDLE, stop_all() end,
    error = function()
      return M.IDLE, { "cancel_silence_timer", "cancel_max_timer", "show_error" }
    end,
  },

  [M.TOGGLE] = {
    key_down = function() return M.IDLE, stop_all() end,
    esc = function() return M.IDLE, cancel_all() end,
    silence_timer = function() return M.IDLE, cancel_all() end,
    max_timer = function() return M.IDLE, stop_all() end,
    voice = function() return M.TOGGLE, { "reset_silence_timer" } end,
    error = function()
      return M.IDLE, { "cancel_silence_timer", "cancel_max_timer", "show_error" }
    end,
  },
}

-- step(state, event) -> newState, actions
function M.step(state, event)
  local row = TABLE[state]
  if not row then return state, {} end
  local handler = row[event]
  if not handler then return state, {} end
  return handler()
end

return M
