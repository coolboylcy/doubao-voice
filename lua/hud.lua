-- 录音浮层：胶囊形，左侧呼吸录音点 + 中间实时音频波形 + 右侧计时。
--
-- 这里本来是打算放实时字幕的，但豆包 2.0 只有 nostream 模式，整段说完才
-- 给文本，中途无字可显。改放波形——它同样能让人确信"它在听、听到了"，
-- 而且数据现成：daemon 为了做静音判定本来就在算每包 PCM 峰值。

local M = {}

local WIDTH = 300
local HEIGHT = 52
local BOTTOM_MARGIN = 130

local BARS = 24
local BAR_W = 3
local BAR_GAP = 5
local BAR_X0 = 40
local BAR_MIN_H = 3
local BAR_MAX_H = 26

-- 说话峰值一般几千，取 6000 做满刻度；超过就削平
local FULL_SCALE = 6000

local IDX_BG = 1
local IDX_DOT = 2
local IDX_BAR0 = 3 -- 波形占 3 .. 3+BARS-1
local IDX_TIME = IDX_BAR0 + BARS
local IDX_STATUS = IDX_TIME + 1

local canvas = nil
local tickTimer = nil
local hideTimer = nil
local startedAt = nil
local levels = {}
local target = 0
local smoothed = 0

local function now()
  return hs.timer.secondsSinceEpoch()
end

local function buildCanvas()
  local screen = hs.screen.mainScreen():frame()
  local c = hs.canvas.new({
    x = screen.x + (screen.w - WIDTH) / 2,
    y = screen.y + screen.h - BOTTOM_MARGIN - HEIGHT,
    w = WIDTH,
    h = HEIGHT,
  })
  c:level(hs.canvas.windowLevels.overlay)
  c:behavior(hs.canvas.windowBehaviors.canJoinAllSpaces)

  c[IDX_BG] = {
    type = "rectangle",
    action = "strokeAndFill",
    roundedRectRadii = { xRadius = HEIGHT / 2, yRadius = HEIGHT / 2 },
    fillColor = { red = 0.07, green = 0.07, blue = 0.08, alpha = 0.93 },
    strokeColor = { white = 1, alpha = 0.10 },
    strokeWidth = 1,
  }

  c[IDX_DOT] = {
    type = "circle",
    action = "fill",
    center = { x = 22, y = HEIGHT / 2 },
    radius = 4.5,
    fillColor = { red = 1, green = 0.30, blue = 0.32, alpha = 1 },
  }

  for i = 0, BARS - 1 do
    c[IDX_BAR0 + i] = {
      type = "rectangle",
      action = "fill",
      roundedRectRadii = { xRadius = BAR_W / 2, yRadius = BAR_W / 2 },
      frame = {
        x = BAR_X0 + i * (BAR_W + BAR_GAP),
        y = (HEIGHT - BAR_MIN_H) / 2,
        w = BAR_W,
        h = BAR_MIN_H,
      },
      fillColor = { red = 0.20, green = 0.88, blue = 0.75, alpha = 0.30 },
    }
  end

  c[IDX_TIME] = {
    type = "text",
    text = "0.0s",
    textColor = { white = 0.62, alpha = 1 },
    textSize = 12,
    textAlignment = "right",
    frame = { x = WIDTH - 76, y = HEIGHT / 2 - 9, w = 56, h = 18 },
  }

  c[IDX_STATUS] = {
    type = "text",
    text = "",
    textColor = { white = 0.95, alpha = 1 },
    textSize = 14,
    textAlignment = "left",
    frame = { x = 40, y = HEIGHT / 2 - 11, w = WIDTH - 60, h = 22 },
  }

  return c
end

local function ensureCanvas()
  if not canvas then canvas = buildCanvas() end
  return canvas
end

local function stopTick()
  if tickTimer then
    tickTimer:stop()
    tickTimer = nil
  end
end

local function cancelHide()
  if hideTimer then
    hideTimer:stop()
    hideTimer = nil
  end
end

local function setBarsVisible(visible)
  local c = ensureCanvas()
  for i = 0, BARS - 1 do
    c[IDX_BAR0 + i].action = visible and "fill" or "skip"
  end
  c[IDX_DOT].action = visible and "fill" or "skip"
  c[IDX_TIME].action = visible and "fill" or "skip"
end

local function tick()
  if not canvas or not startedAt then return end
  local t = now()

  -- 电平指数平滑：起得快、落得慢，看起来才像在跟着声音走而不是抽搐
  local rise, fall = 0.55, 0.15
  smoothed = smoothed + (target - smoothed) * (target > smoothed and rise or fall)
  target = target * 0.82 -- 没有新数据就自然衰减

  table.insert(levels, math.min(1, smoothed))
  while #levels > BARS do
    table.remove(levels, 1)
  end

  for i = 0, BARS - 1 do
    local v = levels[#levels - (BARS - 1 - i)] or 0
    local h = BAR_MIN_H + v * (BAR_MAX_H - BAR_MIN_H)
    local bar = canvas[IDX_BAR0 + i]
    bar.frame = {
      x = BAR_X0 + i * (BAR_W + BAR_GAP),
      y = (HEIGHT - h) / 2,
      w = BAR_W,
      h = h,
    }
    bar.fillColor = {
      red = 0.20,
      green = 0.88,
      blue = 0.75,
      alpha = 0.28 + v * 0.72,
    }
  end

  -- 录音点呼吸
  local pulse = 4.2 + 1.1 * math.sin(t * 5.5) + smoothed * 1.6
  canvas[IDX_DOT].radius = pulse

  canvas[IDX_TIME].text = string.format("%.1fs", t - startedAt)
end

function M.show()
  cancelHide()
  local c = ensureCanvas()
  startedAt = now()
  levels = {}
  target = 0
  smoothed = 0
  c[IDX_STATUS].text = ""
  setBarsVisible(true)
  c:show()
  stopTick()
  tickTimer = hs.timer.doEvery(0.04, tick)
end

-- daemon 每包音频报一次电平
function M.setLevel(peak)
  local v = math.min(1, (peak or 0) / FULL_SCALE)
  if v > target then target = v end
end

-- 等待识别结果：波形收起，只留一行提示
function M.setPending(text)
  if not canvas then return end
  stopTick()
  setBarsVisible(false)
  canvas[IDX_STATUS].text = text or "识别中……"
  canvas[IDX_STATUS].textColor = { white = 0.95, alpha = 1 }
end

function M.setText(text)
  M.setPending(text)
end

function M.hide()
  cancelHide()
  stopTick()
  startedAt = nil
  if canvas then canvas:hide() end
end

-- 显示一条消息后自动淡出
function M.flash(text, seconds, color)
  cancelHide()
  stopTick()
  local c = ensureCanvas()
  startedAt = nil
  setBarsVisible(false)
  c[IDX_STATUS].text = text
  c[IDX_STATUS].textColor = color or { white = 0.75, alpha = 1 }
  c:show()
  hideTimer = hs.timer.doAfter(seconds or 1.5, function()
    if canvas then canvas:hide() end
    hideTimer = nil
  end)
end

function M.flashError(text)
  M.flash(text, 3.5, { red = 1, green = 0.42, blue = 0.35, alpha = 1 })
end

-- 调试用：把当前浮层导出成图片。走 canvas 自己的渲染，不需要屏幕录制权限。
function M.snapshot(path)
  if not canvas then return "canvas 未创建" end
  local img = canvas:imageFromCanvas()
  if not img then return "导出失败" end
  img:saveToFile(path)
  return path
end

return M
