local ROOT_MARKERS = { ".git", "Makefile", "go.mod", "package.json", "pyproject.toml", "Cargo.toml" }

local function project_root()
  return vim.fs.root(0, ROOT_MARKERS) or vim.fn.getcwd()
end

local function relative_to_root()
  local full = vim.fn.expand("%:p")
  local root = project_root()
  if full == root then
    return vim.fn.fnamemodify(full, ":t")
  end
  local prefix = root .. "/"
  if vim.startswith(full, prefix) then
    return full:sub(#prefix + 1)
  end
  return vim.fn.expand("%")
end

vim.keymap.set("n", "<leader>cp", function()
  local path = relative_to_root()
  vim.fn.setreg("+", path)
  vim.notify("Copied: " .. path, vim.log.levels.INFO)
end, { desc = "Copy project-relative path to clipboard" })
