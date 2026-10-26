local function cycle_buffer(direction)
	local listed = vim.tbl_filter(function(bufnr)
		return vim.api.nvim_buf_is_valid(bufnr) and vim.bo[bufnr].buflisted
	end, vim.api.nvim_list_bufs())

	if #listed < 2 then
		return
	end

	local current = vim.api.nvim_get_current_buf()
	local index
	for i, bufnr in ipairs(listed) do
		if bufnr == current then
			index = i
			break
		end
	end

	if not index then
		vim.cmd(direction > 0 and "bnext" or "bprevious")
		return
	end

	vim.api.nvim_set_current_buf(listed[((index - 1 + direction) % #listed) + 1])
end

local function statusline_theme()
	local theme = vim.deepcopy(require("lualine.themes.gruvbox"))
	-- Keep the right-hand block on the old normal color. Only the mode block changes.
	theme.normal.z = vim.deepcopy(theme.normal.a)
	theme.normal.a = { fg = "#282828", bg = "#83a598", gui = "bold" }
	return theme
end

local M = {
	"nvim-lualine/lualine.nvim",
	dependencies = { "nvim-tree/nvim-web-devicons" },
	config = function()
		require("lualine").setup({
			options = {
				theme = statusline_theme(),
				globalstatus = true,
			},
			sections = {
				lualine_b = { "diff" },
				lualine_c = {
					{
						"buffers",
						max_length = function()
							return math.floor(vim.o.columns * 0.5)
						end,
						separator = { right = "" },
						symbols = {
							alternate_file = "",
						},
						buffers_color = {
							active = { fg = "#282828", bg = "#a89984", gui = "bold" },
							inactive = { fg = "#a89984", bg = "#3c3836" },
						},
					},
				},
				lualine_x = { "diagnostics", "fileformat", "filetype" },
			},
			inactive_sections = {
				lualine_c = {},
			},
		})

		vim.keymap.set("n", "<C-Right>", function()
			cycle_buffer(1)
		end, { desc = "Next buffer" })
		vim.keymap.set("n", "<C-Left>", function()
			cycle_buffer(-1)
		end, { desc = "Previous buffer" })
	end,
}

return M
