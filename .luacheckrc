-- Hammerspoon 注入的全局
globals = { "hs", "DBVOICE" }

-- 这些文件跑在 Hammerspoon 里，不是标准 Lua 环境
std = "lua54"

-- 行宽交给人判断，不做机器约束
max_line_length = false

files["tests/*.lua"] = {
  -- 测试脚本用全局变量串联断言，无妨
  allow_defined_top = true,
}
