-- 状态机测试。用标准 lua 跑：lua tests/state_test.lua
package.path = "lua/?.lua;../lua/?.lua;" .. package.path
local S = require("state")

local failures = 0

local function check(name, ok, detail)
  if ok then
    print("  ok   " .. name)
  else
    failures = failures + 1
    print("FAIL   " .. name .. "   " .. tostring(detail))
  end
end

local function has(actions, want)
  for _, a in ipairs(actions) do
    if a == want then return true end
  end
  return false
end

local function lacks(actions, unwanted)
  return not has(actions, unwanted)
end

local function join(actions)
  return "{" .. table.concat(actions, ", ") .. "}"
end

-- IDLE: 按下即录
local st, acts = S.step(S.IDLE, "key_down")
check("IDLE+key_down 进 PENDING", st == S.PENDING, st)
check("IDLE+key_down 立即 send_start", has(acts, "send_start"), join(acts))
check("IDLE+key_down 启长按定时器", has(acts, "start_longpress_timer"), join(acts))
check("IDLE+key_down 启静音定时器", has(acts, "start_silence_timer"), join(acts))
check("IDLE+key_down 启最长定时器", has(acts, "start_max_timer"), join(acts))
check("IDLE+key_down 显示 HUD", has(acts, "show_hud"), join(acts))

-- PENDING -> PTT：必须取消静音定时器
st, acts = S.step(S.PENDING, "longpress_timer")
check("PENDING+longpress 进 PTT", st == S.PTT, st)
check("PTT 取消静音定时器（按住可长时间沉默）",
      has(acts, "cancel_silence_timer"), join(acts))

-- PENDING -> TOGGLE
st, acts = S.step(S.PENDING, "key_up")
check("PENDING+key_up 进 TOGGLE", st == S.TOGGLE, st)
check("TOGGLE 保留静音定时器", lacks(acts, "cancel_silence_timer"), join(acts))
check("TOGGLE 不重发 start", lacks(acts, "send_start"), join(acts))

-- PTT 松手
st, acts = S.step(S.PTT, "key_up")
check("PTT+key_up 回 IDLE", st == S.IDLE, st)
check("PTT+key_up 发 stop", has(acts, "send_stop"), join(acts))
check("PTT+key_up 不立即隐藏 HUD（要等 final）", lacks(acts, "hide_hud"), join(acts))

-- TOGGLE 再按一下
st, acts = S.step(S.TOGGLE, "key_down")
check("TOGGLE+key_down 回 IDLE", st == S.IDLE, st)
check("TOGGLE+key_down 发 stop", has(acts, "send_stop"), join(acts))

-- TOGGLE 后续的 key_up 必须被忽略
st, acts = S.step(S.IDLE, "key_up")
check("IDLE+key_up 无动作", st == S.IDLE and #acts == 0, join(acts))

-- Esc 取消
for _, from in ipairs({ S.PENDING, S.PTT, S.TOGGLE }) do
  st, acts = S.step(from, "esc")
  check(from .. "+esc 回 IDLE", st == S.IDLE, st)
  check(from .. "+esc 发 cancel", has(acts, "send_cancel"), join(acts))
  check(from .. "+esc 隐藏 HUD", has(acts, "hide_hud"), join(acts))
  check(from .. "+esc 不发 stop", lacks(acts, "send_stop"), join(acts))
end

-- IDLE 下的 Esc 必须透传，绝不能吞（否则 vim 用户当场崩溃）
st, acts = S.step(S.IDLE, "esc")
check("IDLE+esc 不消费", st == S.IDLE and #acts == 0, join(acts))
check("consumes_esc(IDLE) 为假", S.consumes_esc(S.IDLE) == false)
check("consumes_esc(PTT) 为真", S.consumes_esc(S.PTT) == true)
check("consumes_esc(TOGGLE) 为真", S.consumes_esc(S.TOGGLE) == true)
check("consumes_esc(PENDING) 为真", S.consumes_esc(S.PENDING) == true)

-- 静音取消只打 TOGGLE
st, acts = S.step(S.TOGGLE, "silence_timer")
check("TOGGLE+silence 回 IDLE", st == S.IDLE, st)
check("TOGGLE+silence 发 cancel", has(acts, "send_cancel"), join(acts))
st, acts = S.step(S.PTT, "silence_timer")
check("PTT+silence 无动作（定时器早已取消）", st == S.PTT and #acts == 0, join(acts))

-- 检测到人声电平时重置静音定时器（daemon 本地判音量，不依赖服务端）
st, acts = S.step(S.TOGGLE, "voice")
check("TOGGLE+voice 留在 TOGGLE", st == S.TOGGLE, st)
check("TOGGLE+voice 重置静音定时器", has(acts, "reset_silence_timer"), join(acts))
st, acts = S.step(S.PTT, "voice")
check("PTT+voice 不碰静音定时器", lacks(acts, "reset_silence_timer"), join(acts))

-- 最长录音兜底
for _, from in ipairs({ S.PTT, S.TOGGLE }) do
  st, acts = S.step(from, "max_timer")
  check(from .. "+max_timer 回 IDLE", st == S.IDLE, st)
  check(from .. "+max_timer 发 stop（保住已说的话）", has(acts, "send_stop"), join(acts))
end

-- 终结事件
st, acts = S.step(S.IDLE, "final")
check("IDLE+final 注入文本", has(acts, "inject"), join(acts))
check("IDLE+final 隐藏 HUD", has(acts, "hide_hud"), join(acts))
st, acts = S.step(S.IDLE, "empty")
check("IDLE+empty 不注入", lacks(acts, "inject"), join(acts))
check("IDLE+empty 提示没听到", has(acts, "show_empty"), join(acts))
st, acts = S.step(S.IDLE, "error")
check("IDLE+error 显示错误", has(acts, "show_error"), join(acts))
check("IDLE+error 不注入", lacks(acts, "inject"), join(acts))

-- 未知事件不得炸
st, acts = S.step(S.IDLE, "bogus_event")
check("未知事件安全忽略", st == S.IDLE and #acts == 0, join(acts))
st, acts = S.step("BOGUS_STATE", "key_down")
check("未知状态安全忽略", st == "BOGUS_STATE" and #acts == 0, join(acts))

print()
if failures == 0 then
  print("全部通过")
  os.exit(0)
else
  print(failures .. " 项未通过")
  os.exit(1)
end
