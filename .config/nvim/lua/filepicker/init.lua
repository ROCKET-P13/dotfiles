-- filepicker: a VSCode-style file picker built on a custom Telescope picker
-- with a VSCode-like fuzzy scorer and a persisted MRU store so recently
-- opened files in the current directory surface toward the top.

local picker = require("filepicker.picker")
local mru = require("filepicker.mru")

local M = {}

local defaults = {
	key = "<C-p>",
	debounce_ms = 30,
	recency_weight = 12,
	mru_cap = 200,
	max_files = 50000,
	max_results = 25,
	exclude_ext = { csv = true },
}

-- Buffer types / schemes we never want to record as "recently opened".
local function should_record(buf, path)
	if path == "" or vim.fn.isdirectory(path) == 1 then
		return false
	end
	if path:match("^[%w%-]+://") then
		-- oil://, term://, fugitive://, etc.
		return false
	end
	local buftype = vim.bo[buf].buftype
	if buftype ~= "" then
		return false
	end
	return true
end

function M.setup(opts)
	opts = vim.tbl_deep_extend("force", vim.deepcopy(defaults), opts or {})
	M._opts = opts

	mru.setup({ mru_cap = opts.mru_cap })

	local group = vim.api.nvim_create_augroup("FilepickerMRU", { clear = true })
	vim.api.nvim_create_autocmd({ "BufReadPost" }, {
		group = group,
		callback = function(args)
			local path = vim.api.nvim_buf_get_name(args.buf)
			if not should_record(args.buf, path) then
				return
			end
			mru.record(vim.fn.fnamemodify(path, ":p"))
		end,
	})

	vim.keymap.set("n", opts.key, function()
		picker.open(opts)
	end, { desc = "Find Files (VSCode-style)" })
end

function M.open(opts)
	picker.open(opts or M._opts or defaults)
end

return M
