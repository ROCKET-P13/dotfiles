-- Owns the long-lived Node tokenizer process and the newline-delimited JSON
-- request/response protocol over its stdio.

local Client = {}
Client.__index = Client

local function new()
	return setmetatable({
		job = nil,
		next_id = 0,
		pending = {}, -- id -> callback(err, result)
		stdout_buf = "",
		ready = false,
		on_ready = {},
		color_map = nil, -- populated from the tokenizer "ready" message
	}, Client)
end

--- @param opts { node: string, tokenizer: string, theme: string }
function Client:start(opts)
	if self.job then
		return
	end
	local cmd = { opts.node, opts.tokenizer, opts.theme }
	self.job = vim.fn.jobstart(cmd, {
		stdout_buffered = false,
		on_stdout = function(_, data)
			self:_on_stdout(data)
		end,
		on_stderr = function(_, data)
			local text = table.concat(data, "\n")
			if text:gsub("%s", "") ~= "" then
				vim.schedule(function()
					vim.notify("[textmate] tokenizer stderr: " .. text, vim.log.levels.WARN)
				end)
			end
		end,
		on_exit = function(_, code)
			self.job = nil
			self.ready = false
			if code ~= 0 then
				vim.schedule(function()
					vim.notify("[textmate] tokenizer exited with code " .. code, vim.log.levels.ERROR)
				end)
			end
		end,
	})
	if self.job <= 0 then
		self.job = nil
		error("[textmate] failed to start tokenizer process")
	end
end

function Client:_on_stdout(data)
	-- jobstart splits on newlines; the last element is a partial line.
	self.stdout_buf = self.stdout_buf .. table.concat(data, "\n")
	while true do
		local nl = self.stdout_buf:find("\n", 1, true)
		if not nl then
			break
		end
		local line = self.stdout_buf:sub(1, nl - 1)
		self.stdout_buf = self.stdout_buf:sub(nl + 1)
		if line ~= "" then
			self:_handle_line(line)
		end
	end
end

function Client:_handle_line(line)
	local ok, msg = pcall(vim.json.decode, line)
	if not ok or type(msg) ~= "table" then
		return
	end
	if msg.type == "ready" then
		self.ready = true
		self.color_map = msg.colorMap
		local callbacks = self.on_ready
		self.on_ready = {}
		for _, cb in ipairs(callbacks) do
			cb()
		end
		return
	end
	if msg.type == "fatal" then
		vim.schedule(function()
			vim.notify("[textmate] tokenizer fatal: " .. tostring(msg.message), vim.log.levels.ERROR)
		end)
		return
	end
	if msg.id == nil then
		return
	end
	local cb = self.pending[msg.id]
	if not cb then
		return
	end
	self.pending[msg.id] = nil
	if msg.type == "error" then
		cb(msg.message or "unknown error", nil)
	else
		cb(nil, msg)
	end
end

--- Run `fn` once the process has emitted its ready signal.
function Client:when_ready(fn)
	if self.ready then
		fn()
	else
		table.insert(self.on_ready, fn)
	end
end

--- Tokenize lines for a buffer's grammar scope.
--- The tokenizer keeps per-buffer state keyed by `buf` and only re-tokenizes the
--- region an edit could have changed; the result reports a contiguous changed
--- line range. Call `drop` when a buffer is no longer highlighted.
--- @param buf integer
--- @param scope_name string
--- @param lines string[]
--- @param callback fun(err: string|nil, result: { start: integer, stop: integer, tokens: table, lineCount: integer }|nil)
function Client:tokenize(buf, scope_name, lines, callback)
	if not self.job then
		callback("tokenizer not running", nil)
		return
	end
	self.next_id = self.next_id + 1
	local id = self.next_id
	self.pending[id] = function(err, msg)
		if err then
			callback(err, nil)
		else
			callback(nil, msg)
		end
	end
	local payload = vim.json.encode({
		id = id,
		type = "tokenize",
		bufId = buf,
		scopeName = scope_name,
		lines = lines,
	})
	vim.fn.chansend(self.job, payload .. "\n")
end

--- Discard the tokenizer's cached state for a buffer. Fire-and-forget.
--- @param buf integer
function Client:drop(buf)
	if not self.job then
		return
	end
	vim.fn.chansend(self.job, vim.json.encode({ type = "drop", bufId = buf }) .. "\n")
end

function Client:stop()
	if self.job then
		vim.fn.jobstop(self.job)
		self.job = nil
		self.ready = false
	end
end

return { new = new }
