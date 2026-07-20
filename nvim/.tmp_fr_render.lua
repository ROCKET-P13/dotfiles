vim.api.nvim_ui_attach(120, 40, { rgb = true, ext_linegrid = true })
local fr = require("findreplace")
fr.setup({})
vim.api.nvim_buf_set_lines(0, 0, -1, false, { "foo bar" })
fr.open({ seed = "foo" })
vim.cmd("redraw")
vim.wait(150)
vim.cmd("redraw")
for row = 1, 8 do
  local s = ""
  for col = 1, 120 do
    s = s .. (vim.fn.screenstring(row, col))
  end
  -- trim trailing spaces but keep leading to see alignment
  print(string.format("%2d|%s|", row, (s:gsub("%s+$", ""))))
end
vim.cmd("qa!")
