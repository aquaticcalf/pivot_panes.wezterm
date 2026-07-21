local M = {}

-- Get priority for a process name
---@param process_name string
---@param config PivotConfig
---@return number
function M.get_process_priority(process_name, config)
	return config.priority_apps[process_name:lower()] or 1
end

-- Capture scrollback buffer from a pane if enabled
---@param pane any
---@param config PivotConfig
---@return string|nil
function M.capture_scrollback(pane, config)
	-- State restoration intentionally preserves the original pane and recreates
	-- only the second pane; scrollback is not replayed. Avoid the legacy helper
	-- that is incompatible with current WezTerm.
	return nil
end

return M
