-- Add clickable links to the gitsigns blame popup.
-- Gitsigns already linkifies GitHub PR/commit refs when `gh = true` (see gitsigns.lua).
-- This handles Jira tickets and raw URLs in the commit summary, which gitsigns
-- renders as plain text. Each link is an extmark carrying a `url`, so Neovim's
-- built-in `gx` opens it (when the popup is focused) and `Underlined` makes it
-- visually distinct. `open_blame_link()` opens the first link without focusing.
local M = {}

local ns = vim.api.nvim_create_namespace("floating_links")
local group = vim.api.nvim_create_augroup("BlameLinks", { clear = true })

local JIRA_BASE = "https://rfsmart-products.atlassian.net/browse/"
local JIRA_PATTERN = "[A-Z][A-Z0-9]+-%d+"
local URL_PATTERN = "%a[%w.+-]*://[%w%._/?=&#.+~@!$'()*+,;%-]+"

local function trim_punct(s)
	return s:gsub("[%s.,;:!?%>%)]+$", "")
end

local function add_link(bufnr, row, start_col, end_col, url)
	if not url or url == "" then
		return
	end
	vim.api.nvim_buf_set_extmark(bufnr, ns, row, start_col, {
		end_col = end_col,
		hl_group = "Underlined",
		url = url,
		priority = 100,
	})
end

local function linkify(bufnr)
	local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
	for row, line in ipairs(lines) do
		for start_pos, match in line:gmatch("()(" .. JIRA_PATTERN .. ")") do
			local start_col = start_pos - 1
			add_link(bufnr, row - 1, start_col, start_col + #match, JIRA_BASE .. match)
		end
		for start_pos, match in line:gmatch("()(" .. URL_PATTERN .. ")") do
			local start_col = start_pos - 1
			add_link(bufnr, row - 1, start_col, start_col + #match, trim_punct(match))
		end
	end
end

function M.find_blame_win()
	for _, w in ipairs(vim.api.nvim_list_wins()) do
		if vim.w[w] and vim.w[w].gitsigns_preview == "blame" then
			return w
		end
	end
	return nil
end

function M.open_blame_link()
	local win = M.find_blame_win()
	if not win then
		vim.notify("No git blame popup is open", vim.log.levels.WARN)
		return
	end
	local buf = vim.api.nvim_win_get_buf(win)
	local marks = vim.api.nvim_buf_get_extmarks(buf, ns, 0, -1, { details = true })
	for _, m in ipairs(marks) do
		local url = m[4] and m[4].url
		if url then
			vim.ui.open(url)
			return
		end
	end
	vim.notify("No link found in blame popup", vim.log.levels.WARN)
end

-- `vim.w[win].gitsigns_preview` is set after `nvim_open_win` returns, so the
-- work runs on `vim.schedule` (BufWinEnter fires during `nvim_open_win`).
vim.api.nvim_create_autocmd("BufWinEnter", {
	group = group,
	callback = function(args)
		vim.schedule(function()
			if not M.find_blame_win() then
				return
			end
			if not vim.api.nvim_buf_is_valid(args.buf) then
				return
			end
			-- Only linkify the blame popup buffer itself.
			if vim.api.nvim_win_get_buf(M.find_blame_win()) ~= args.buf then
				return
			end
			vim.api.nvim_buf_clear_namespace(args.buf, ns, 0, -1)
			linkify(args.buf)
		end)
	end,
})

return M
