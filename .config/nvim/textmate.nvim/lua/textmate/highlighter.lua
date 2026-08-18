-- Per-buffer highlighting: sends the buffer (throttled) to the tokenizer, which
-- keeps per-buffer grammar state and replies with only the contiguous line range
-- an edit could have changed. We repaint just that range, leaving extmarks on
-- unchanged lines in place (they auto-track text edits), which avoids the flicker
-- and cost of clearing and repainting the whole buffer on every keystroke.
--
-- Updates are throttled (leading + trailing) rather than debounced, so colors
-- refresh periodically *while* typing instead of only after a pause. This keeps
-- an identifier being typed (e.g. "const testing") at its real color promptly
-- rather than leaving the new characters uncolored until the user stops.

local theme = require("textmate.theme")

local M = {}

-- buf -> { ns, scope_name, attached, timer, last_run, inflight, dirty, tick,
--          pending, dirty_full, partial }
--   pending: { firstline, lastline, new_lastline } | nil
--     A single on_lines edit not yet sent. If a second edit arrives before the
--     first is sent, `dirty_full` is set and the next pass falls back to a
--     whole-buffer tokenize.
--   dirty_full: bool
--     Force a full-buffer send on the next pass (multi-edit coalescing, or any
--     case where the incremental range path can't be used safely).
local state = {}

local config = {
	client = nil,
	throttle_ms = 40,
	max_lines = 5000,
}

--- @param opts { client: table, throttle_ms: number, max_lines: number }
function M.setup(opts)
	config.client = opts.client
	config.throttle_ms = opts.throttle_ms or config.throttle_ms
	config.max_lines = opts.max_lines or config.max_lines
end

-- Repaint the changed line range [start, stop). `tokens[i]` holds the tokens for
-- line `start + i - 1`. Only this window's extmarks are cleared; highlights on
-- lines outside it are left untouched.
local function paint_range(buf, ns, start, stop, tokens)
	if not vim.api.nvim_buf_is_valid(buf) then
		return
	end
	vim.api.nvim_buf_clear_namespace(buf, ns, start, stop)
	for i, line_tokens in ipairs(tokens) do
		local lnum = start + i - 1
		for _, tok in ipairs(line_tokens) do
			local group = theme.group(tok.c, tok.y)
			if group and tok.e > tok.s then
				-- Buffer may have shrunk under us between request and paint;
				-- a bad range raises, so swallow it and let the next pass fix it.
				-- Above treesitter's default extmark priority (100) so our
				-- highlight wins even if treesitter remains active on the buffer.
				-- end_right_gravity: characters typed at a token's end extend its
				-- highlight (e.g. typing "con" stays the identifier color) instead
				-- of rendering uncolored until the next re-tokenize reclassifies it.
				pcall(vim.api.nvim_buf_set_extmark, buf, ns, lnum, tok.s, {
					end_col = tok.e,
					hl_group = group,
					priority = 200,
					end_right_gravity = true,
				})
			end
		end
	end
end

local schedule

-- At most one tokenize request is outstanding per buffer. This keeps the
-- tokenizer's cached base in lockstep with what we last painted, so its
-- incremental diffs stay valid. Edits arriving while a request is in flight set
-- `dirty`, triggering a follow-up pass once the current one returns.
--
-- `limit`, when set, sends only the first `limit` lines. The tokenizer caches
-- rule-stack state for just that prefix, so the follow-up full pass resumes
-- tokenizing from where this one stopped instead of redoing it. Used on initial
-- attach to paint the visible viewport first, so colors appear without waiting
-- for the whole file to tokenize.
local function send_tokenize(buf, limit)
	local st = state[buf]
	if not st or not st.attached or not vim.api.nvim_buf_is_valid(buf) then
		return
	end
	local line_count = vim.api.nvim_buf_line_count(buf)
	if line_count > config.max_lines then
		-- Drop any cached base so re-enabling below the limit re-tokenizes cleanly.
		config.client:drop(buf)
		return
	end
	if st.inflight then
		st.dirty = true
		return
	end

	-- Incremental path: exactly one edit pending, no partial-paint limit, no
	-- full-buffer fallback flagged. Sends only the changed line range; the
	-- tokenizer splices it into its cached buffer state and re-tokenizes from
	-- the edit's start row until state convergence with the unchanged suffix.
	local pending = st.pending
	if pending and not st.dirty_full and limit == nil then
		st.pending = nil
		st.dirty_full = false
		st.inflight = true
		st.tick = vim.api.nvim_buf_get_changedtick(buf)
		local lines = vim.api.nvim_buf_get_lines(buf, pending.firstline, pending.new_lastline, false)
		config.client:tokenize_range(
			buf,
			st.scope_name,
			pending.firstline,
			pending.lastline,
			pending.new_lastline,
			lines,
			function(err, result)
				vim.schedule(function()
					local s = state[buf]
					if not s or not s.attached then
						return
					end
					s.inflight = false
					if err then
						-- No cached base (e.g. after a drop) or stale cache: retry
						-- with a full-buffer tokenize on the next pass.
						s.dirty = true
					elseif not vim.api.nvim_buf_is_valid(buf) then
						return
					elseif vim.api.nvim_buf_get_changedtick(buf) == s.tick then
						paint_range(buf, s.ns, result.start, result.stop, result.tokens)
					else
						-- The buffer changed during the request, so the result's
						-- line numbers no longer line up and the cached base is
						-- stale. Discard it and force a full re-tokenize.
						config.client:drop(buf)
						s.dirty_full = true
						s.dirty = true
					end
					if s.dirty then
						s.dirty = false
						schedule(buf)
					end
				end)
			end
		)
		return
	end

	-- Full-buffer path: initial attach (with optional partial-paint limit),
	-- reload, multi-edit coalescing, or a range-path fallback. Re-sends the
	-- whole buffer; the tokenizer diffs against its cached base.
	st.pending = nil
	st.dirty_full = false
	local send_count = line_count
	local partial = false
	if limit and limit < line_count then
		send_count = limit
		partial = true
	end
	local lines = vim.api.nvim_buf_get_lines(buf, 0, send_count, false)
	st.inflight = true
	st.dirty = false
	st.partial = partial
	st.tick = vim.api.nvim_buf_get_changedtick(buf)
	config.client:tokenize(buf, st.scope_name, lines, function(err, result)
		vim.schedule(function()
			local s = state[buf]
			if not s or not s.attached then
				return
			end
			s.inflight = false
			if err then
				vim.notify("[textmate] " .. err, vim.log.levels.WARN)
			elseif not vim.api.nvim_buf_is_valid(buf) then
				return
			elseif vim.api.nvim_buf_get_changedtick(buf) == s.tick then
				paint_range(buf, s.ns, result.start, result.stop, result.tokens)
				-- Only a prefix was painted; queue a full pass to tokenize the rest.
				if s.partial then
					s.partial = false
					s.dirty = true
				end
			else
				-- The buffer changed during the request, so the result's line
				-- numbers no longer line up and the cached base is stale. Discard
				-- it and force the next pass to re-tokenize from scratch.
				config.client:drop(buf)
				s.dirty = true
			end
			if s.dirty then
				s.dirty = false
				schedule(buf)
			end
		end)
	end)
end

local function run(buf)
	local st = state[buf]
	if not st then
		return
	end
	st.last_run = vim.uv.now()
	vim.schedule(function()
		send_tokenize(buf)
	end)
end

-- Leading + trailing throttle: the first change runs immediately, further
-- changes within the window are coalesced into a single trailing run, so a
-- continuous typing burst still refreshes about once per throttle window.
function schedule(buf)
	local st = state[buf]
	if not st then
		return
	end
	if st.timer then
		return
	end
	local elapsed = vim.uv.now() - (st.last_run or 0)
	if elapsed >= config.throttle_ms then
		run(buf)
		return
	end
	local timer = vim.uv.new_timer()
	st.timer = timer
	timer:start(config.throttle_ms - elapsed, 0, function()
		timer:stop()
		timer:close()
		if state[buf] then
			state[buf].timer = nil
		end
		run(buf)
	end)
end

-- Lines below the viewport still tokenized in the first pass, so a small scroll
-- lands on already-painted text while the background pass catches up.
local INITIAL_OVERSCAN = 100

-- Last visible line of a window showing `buf`, plus overscan; nil when the
-- buffer is not displayed (then the caller does a normal full tokenize). A
-- top-anchored slice is safe because line 0 begins from the grammar's INITIAL
-- state, so the prefix tokenizes identically whether sent alone or with the
-- rest of the file.
local function initial_limit(buf)
	local win = vim.fn.bufwinid(buf)
	if win == -1 then
		return nil
	end
	local bottom = vim.api.nvim_win_call(win, function()
		return vim.fn.line("w$")
	end)
	if not bottom or bottom <= 0 then
		return nil
	end
	return bottom + INITIAL_OVERSCAN
end

--- Attach highlighting to a buffer for the given grammar scope.
function M.attach(buf, scope_name)
	if state[buf] and state[buf].attached then
		return
	end
	local ns = vim.api.nvim_create_namespace("textmate:" .. buf)
	state[buf] = {
		ns = ns,
		scope_name = scope_name,
		attached = true,
		pending = nil,
		dirty_full = false,
	}

	vim.api.nvim_buf_attach(buf, false, {
		on_lines = function(_, _, _, firstline, lastline, new_lastline)
			if not state[buf] or not state[buf].attached then
				return true -- detach the callback
			end
			local st = state[buf]
			if st.pending then
				-- A second edit arrived before the first was sent. The single-edit
				-- splice can't represent two disjoint edits safely, so fall back
				-- to a whole-buffer tokenize on the next pass.
				st.pending = nil
				st.dirty_full = true
			else
				st.pending = { firstline = firstline, lastline = lastline, new_lastline = new_lastline }
			end
			schedule(buf)
		end,
		on_reload = function()
			if not state[buf] or not state[buf].attached then
				return true -- detach the callback
			end
			-- A reload (e.g. autoread after `git reset --hard` rewrites the file)
			-- wipes every extmark and replaces all lines. Drop the cached base so
			-- the next pass is a full re-tokenize, repainting the whole buffer
			-- rather than only an incremental diff.
			local st = state[buf]
			st.pending = nil
			st.dirty_full = false
			config.client:drop(buf)
			schedule(buf)
		end,
		on_detach = function()
			M.detach(buf)
		end,
	})

	config.client:when_ready(function()
		vim.schedule(function()
			send_tokenize(buf, initial_limit(buf))
		end)
	end)
end

--- Detach highlighting and clear extmarks.
function M.detach(buf)
	local st = state[buf]
	if not st then
		return
	end
	st.attached = false
	st.pending = nil
	st.dirty_full = false
	if st.timer then
		st.timer:stop()
		st.timer:close()
		st.timer = nil
	end
	config.client:drop(buf)
	if vim.api.nvim_buf_is_valid(buf) then
		vim.api.nvim_buf_clear_namespace(buf, st.ns, 0, -1)
	end
	state[buf] = nil
end

function M.is_attached(buf)
	return state[buf] ~= nil and state[buf].attached
end

return M
