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
--          pending, dirty_full, partial, base_line_count }
--   pending: { start, old_end, new_end } | nil
--     Unsent splice from the tokenizer's cached buffer to the live buffer.
--     tokenizer[start, old_end) is replaced by current[start, new_end).
--     `start` is the same index in both; the prefix above it is unchanged.
--     Successive on_lines events merge into this one splice.
--   dirty_full: bool
--     The splice is not safe (or the cache was dropped). Next pass sends the
--     whole buffer.
--   base_line_count: integer|nil
--     Line count of the snapshot the in-flight or last complete tokenize
--     established. `old_end` is measured against that snapshot.
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

-- Fold `on_lines(f, l, nl)` into the unsent splice. The tokenizer buffer is
-- frozen, so an edit above the span shifts only the current-buffer end.
-- `pending_ok` rejects a splice whose indexes no longer describe both buffers.
local function merge_pending(pending, f, l, nl)
	if not pending then
		return { start = f, old_end = l, new_end = nl }
	end
	local start = pending.start
	local old_end = pending.old_end
	local new_end = pending.new_end
	local delta = new_end - old_end
	local line_delta = nl - l

	if l <= start then
		return {
			start = f,
			old_end = old_end,
			new_end = new_end + line_delta,
		}
	end

	if f >= new_end then
		return {
			start = start,
			old_end = l - delta,
			new_end = nl,
		}
	end

	-- Overlaps the span. A delete that runs past new_end consumes tokenizer
	-- suffix lines; the live dirty region then ends where that edit ends.
	local merged_old_end = old_end
	local merged_new_end
	if l > new_end then
		local mapped = l - delta
		if mapped > merged_old_end then
			merged_old_end = mapped
		end
		merged_new_end = nl
	else
		merged_new_end = new_end + line_delta
	end
	return {
		start = math.min(start, f),
		old_end = merged_old_end,
		new_end = merged_new_end,
	}
end

local function pending_ok(pending, base_line_count, line_count)
	if not pending then
		return false
	end
	if pending.start < 0 or pending.old_end < pending.start or pending.new_end < pending.start then
		return false
	end
	if pending.new_end > line_count then
		return false
	end
	if base_line_count and pending.old_end > base_line_count then
		return false
	end
	return true
end

local function queue_full(st)
	st.pending = nil
	st.dirty_full = true
	st.partial = false
	st.dirty = true
end

-- At most one tokenize request is outstanding per buffer. This keeps the
-- tokenizer's cached base in lockstep with the snapshot we last sent, so a
-- later range splice applies on top of that snapshot. Edits that land while
-- the request is in flight merge into `pending` and go out as one range once
-- it returns.
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
		-- dirty_full stops a later edit from splicing against that dropped cache.
		config.client:drop(buf)
		st.base_line_count = nil
		st.pending = nil
		st.dirty_full = true
		return
	end
	if st.inflight then
		st.dirty = true
		return
	end

	-- Reply for one in-flight tokenize. A complete request (range, or a full
	-- send with no prefix limit) leaves the Node cache equal to the snapshot
	-- that was sent. Edits since that snapshot sit in `pending`; paint is
	-- skipped because the reply's line numbers are for the snapshot. A prefix
	-- tokenize has no suffix in the cache, so a mismatch there still drops.
	local function finish(err, result, report_err)
		vim.schedule(function()
			local s = state[buf]
			if not s or not s.attached then
				return
			end
			s.inflight = false
			if not vim.api.nvim_buf_is_valid(buf) then
				return
			end
			if err then
				-- The snapshot was not cached. Drop the base we recorded at send
				-- time so the next pass does not splice against it.
				s.base_line_count = nil
				if report_err then
					vim.notify("[textmate] " .. err, vim.log.levels.WARN)
				else
					queue_full(s)
				end
			elseif vim.api.nvim_buf_get_changedtick(buf) == s.tick then
				paint_range(buf, s.ns, result.start, result.stop, result.tokens)
				-- Only a prefix was painted; queue a full pass to tokenize the rest.
				-- The prefix cache stays so that pass resumes instead of redoing it.
				if s.partial then
					s.partial = false
					s.dirty = true
				end
			elseif s.partial or s.dirty_full or not pending_ok(s.pending, s.base_line_count, vim.api.nvim_buf_line_count(buf)) then
				queue_full(s)
			else
				s.dirty = true
			end
			if s.dirty then
				s.dirty = false
				schedule(buf)
			end
		end)
	end

	-- Incremental path: one merged splice, no prefix limit, cache still valid.
	-- The tokenizer replaces its cached rows [start, old_end) with the live
	-- rows [start, new_end) and retokenizes until the rule stack converges.
	-- `base_line_count` is set when a complete snapshot is sent; without it
	-- the Node process has nothing to splice into, so this falls through.
	local pending = st.pending
	if pending and not st.dirty_full and limit == nil and st.base_line_count then
		if not pending_ok(pending, st.base_line_count, line_count) then
			st.dirty_full = true
		else
			st.pending = nil
			st.dirty_full = false
			st.partial = false
			st.inflight = true
			st.dirty = false
			st.base_line_count = line_count
			st.tick = vim.api.nvim_buf_get_changedtick(buf)
			local lines = vim.api.nvim_buf_get_lines(buf, pending.start, pending.new_end, false)
			config.client:tokenize_range(
				buf,
				st.scope_name,
				pending.start,
				pending.old_end,
				pending.new_end,
				lines,
				function(err, result)
					finish(err, result, false)
				end
			)
			return
		end
	end

	-- Full-buffer path: initial attach (with optional prefix limit), reload,
	-- or a splice that failed validation. A dropped cache is cleared first so
	-- the tokenizer does not diff against a base the splice could not describe.
	-- The prefix follow-up leaves the cache in place and diffs against it.
	if st.dirty_full then
		config.client:drop(buf)
		st.base_line_count = nil
	end
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
	if not partial then
		st.base_line_count = line_count
	end
	st.tick = vim.api.nvim_buf_get_changedtick(buf)
	config.client:tokenize(buf, st.scope_name, lines, function(err, result)
		finish(err, result, true)
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
			-- A dropped cache cannot take a splice. Later edits stay on the
			-- full-buffer path; that pass reads the live buffer.
			if not st.dirty_full then
				local merged = merge_pending(st.pending, firstline, lastline, new_lastline)
				if pending_ok(merged, st.base_line_count, vim.api.nvim_buf_line_count(buf)) then
					st.pending = merged
				else
					st.pending = nil
					st.dirty_full = true
				end
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
			-- rather than only an incremental diff. dirty_full keeps a keystroke
			-- before that pass from splicing against the dropped cache.
			local st = state[buf]
			st.pending = nil
			st.dirty_full = true
			st.base_line_count = nil
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
