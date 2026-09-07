-- 录音浮层：胶囊形，左侧呼吸录音点 + 中间实时音频波形 + 右侧计时，
-- 波形下面一行显示服务端回来的中间文本。
--
-- 两条硬规则，都是踩过坑换来的：
--
-- 1. **录音期间波形永不消失。** 豆包在长录音时每 0.2 秒就回一次累积文本，
--    早先的实现让文字顶掉波形（setText 转调 setPending），于是说得稍长
--    波形就永久消失、再也不回来——看起来跟死机一样，实际还在录。所以
--    文字单独占一行，跟波形共存，不抢位置。
--
-- 2. **波形按真实音频时间轴推进，不按渲染帧推进。** 每收到一个电平就压
--    入一格，渲染只负责画。早先是每帧压一格 + 指数平滑，等于把波形变成
--    了"音量趋势图"，既有延迟又不对应实际说话。

local M = {}

local WIDTH = 460
local HEIGHT = 76

local BOTTOM_MARGIN = 130

-- 40 格 × 50ms = 2 秒可见历史。daemon 按 50ms 报电平（见 mic.BLOCKSIZE），
-- 一格一包，所以横轴就是真实时间。
local BARS = 40
local BAR_W = 4
local BAR_GAP = 4
local BAR_X0 = 46
local BAR_MIN_H = 3
local BAR_MAX_H = 40
local BAR_CY = 30 -- 波形垂直中心；下方留给文字行

-- 说话峰值一般几千，取 6000 做满刻度；超过就削平
local FULL_SCALE = 6000

-- 文字行：字号 12，这个宽度约放得下 26 个汉字。豆包回的是**累积**文本
-- （见 asr.py），越说越长，取尾部——正在说的那几个字才是要确认的。
local TEXT_MAX_CHARS = 26

local function tailChars(s, n)
  local total = utf8.len(s)
  if not total or total <= n then return s end
  return "…" .. s:sub(utf8.offset(s, total - n + 1))
end

local IDX_BG = 1
local IDX_DOT = 2
local IDX_BAR0 = 3 -- 波形占 3 .. 3+BARS-1
local IDX_TIME = IDX_BAR0 + BARS
local IDX_STATUS = IDX_TIME + 1 -- 录音中的文字行 / 终态的提示语

local canvas = nil
local tickTimer = nil
local hideTimer = nil
local startedAt = nil
local levels = {}
local latest = 0

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
    roundedRectRadii = { xRadius = 22, yRadius = 22 },
    fillColor = { red = 0.07, green = 0.07, blue = 0.08, alpha = 0.94 },
    strokeColor = { white = 1, alpha = 0.10 },
    strokeWidth = 1,
  }

  c[IDX_DOT] = {
    type = "circle",
    action = "fill",
    center = { x = 26, y = BAR_CY },
    radius = 5,
    fillColor = { red = 1, green = 0.30, blue = 0.32, alpha = 1 },
  }

  for i = 0, BARS - 1 do
    c[IDX_BAR0 + i] = {
      type = "rectangle",
      action = "fill",
      roundedRectRadii = { xRadius = BAR_W / 2, yRadius = BAR_W / 2 },
      frame = {
        x = BAR_X0 + i * (BAR_W + BAR_GAP),
        y = BAR_CY - BAR_MIN_H / 2,
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
    textSize = 13,
    textAlignment = "right",
    frame = { x = WIDTH - 74, y = BAR_CY - 10, w = 56, h = 20 },
  }

  c[IDX_STATUS] = {
    type = "text",
    text = "",
    textColor = { white = 0.72, alpha = 1 },
    textSize = 12,
    textAlignment = "left",
    frame = { x = BAR_X0, y = HEIGHT - 26, w = WIDTH - BAR_X0 - 20, h = 20 },
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
  local act = visible and "fill" or "skip"
  for i = 0, BARS - 1 do
    c[IDX_BAR0 + i].action = act
  end
  c[IDX_DOT].action = act
  c[IDX_TIME].action = act
end

-- 把一格电平画成一根柱：低电平偏青、高电平偏亮绿，最新那一根提亮，
-- 这样即使说话平稳也能看出波形在往前走。
local function paintBar(c, slot, v, newest)
  local h = BAR_MIN_H + v * (BAR_MAX_H - BAR_MIN_H)
  local bar = c[IDX_BAR0 + slot]
  bar.frame = {
    x = BAR_X0 + slot * (BAR_W + BAR_GAP),
    y = BAR_CY - h / 2, -- 从中心上下对称生长
    w = BAR_W,
    h = h,
  }
  bar.fillColor = {
    red = 0.20 + v * 0.45,
    green = 0.88,
    blue = 0.75 - v * 0.25,
    alpha = (newest and 0.55 or 0.26) + v * 0.45,
  }
end

local function render()
  if not canvas then return end
  local n = #levels
  for slot = 0, BARS - 1 do
    -- 右端是最新：levels 不足 BARS 时左边留空
    local idx = n - (BARS - 1 - slot)
    paintBar(canvas, slot, levels[idx] or 0, idx == n)
  end
end

-- 只负责呼吸点与计时；波形由 setLevel 驱动，不在这里推进
local function tick()
  if not canvas or not startedAt then return end
  local t = now()
  canvas[IDX_DOT].radius = 4.6 + 1.2 * math.sin(t * 5.5) + latest * 1.8
  canvas[IDX_TIME].text = string.format("%.1fs", t - startedAt)
end

function M.show()
  cancelHide()
  local c = ensureCanvas()
  startedAt = now()
  levels = {}
  latest = 0
  c[IDX_STATUS].text = ""
  c[IDX_STATUS].textColor = { white = 0.72, alpha = 1 }
  c[IDX_STATUS].frame = { x = BAR_X0, y = HEIGHT - 26, w = WIDTH - BAR_X0 - 20, h = 20 }
  setBarsVisible(true)
  render()
  c:show()
  stopTick()
  tickTimer = hs.timer.doEvery(0.03, tick)
end

-- daemon 每包音频（50ms）报一次电平。一包一格，立刻重画——不做跨帧平滑，
-- 那会同时牺牲延迟和准确度。
function M.setLevel(peak)
  local v = math.min(1, (peak or 0) / FULL_SCALE)
  latest = v
  levels[#levels + 1] = v
  while #levels > BARS do
    table.remove(levels, 1)
  end
  render()
end

-- 等待识别结果：波形、呼吸点、计时一起收起，只留一行居中提示。
-- 这是"已录完"的终态，必须跟录音中长得明显不同。
function M.setPending(text)
  if not canvas then return end
  stopTick()
  setBarsVisible(false)
  canvas[IDX_STATUS].frame = { x = BAR_X0, y = HEIGHT / 2 - 11, w = WIDTH - BAR_X0 - 20, h = 22 }
  canvas[IDX_STATUS].text = text or "识别中……"
  canvas[IDX_STATUS].textColor = { white = 0.95, alpha = 1 }
end

-- 录音**进行中**收到中间结果：只写下面那行文字，波形照旧滚动。
function M.setText(text)
  if not canvas then return end
  canvas[IDX_STATUS].text = tailChars(text or "", TEXT_MAX_CHARS)
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
  c[IDX_STATUS].frame = { x = BAR_X0, y = HEIGHT / 2 - 11, w = WIDTH - BAR_X0 - 20, h = 22 }
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
