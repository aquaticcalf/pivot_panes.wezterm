local wezterm = require("wezterm") --[[@as Wezterm]]
local lib = wezterm.plugin.require("https://github.com/aquaticcalf/lib.wezterm")

local utils = require("utils")
local config = require("config")

local M = {}

local logger = lib.logger.new({
	prefix = "[pivot]",
	debug_enabled = config.config.debug,
})

-- Capture state of a pane
---@param pane any
---@return PaneState
function M.capture_pane_state(pane)
	local process_info = lib.wezterm.get_pane_process(pane, config.config.shell_detection)
	local scrollback = utils.capture_scrollback(pane, config.config)
	local priority = utils.get_process_priority(process_info.name, config.config)

	local state = {
		command = process_info.name,
		args = process_info.args,
		cwd = process_info.cwd,
		is_shell = process_info.is_shell,
		process_name = process_info.name,
		priority = priority,
		scrollback = scrollback,
	}

	logger:debug(
		"Captured pane state:",
		"process =",
		process_info.name,
		"is_shell =",
		process_info.is_shell,
		"priority =",
		priority,
		"cwd =",
		process_info.cwd,
		"scrollback =",
		scrollback and #scrollback .. " bytes" or "disabled"
	)

	return state
end

-- Restore pane state
---@param pane any
---@param state PaneState
function M.restore_pane_state(pane, state)
	logger:debug("Restoring pane state:", "process =", state.process_name)

	-- For shell processes, we can restore to the same directory
	if state.is_shell then
		-- First send escape key to ensure we're at a prompt
		pane:send_text("\x1b")
		wezterm.sleep_ms(100)

		-- Clear the prompt
		pane:send_text("clear\r")
		wezterm.sleep_ms(100)

		-- Change to the saved directory
		if state.cwd and #state.cwd > 0 then
			pane:send_text("cd " .. state.cwd .. "\r")
			wezterm.sleep_ms(100)
		end

		-- For some shell processes, we might want to restore the scrollback
		if state.scrollback and #state.scrollback > 0 then
			logger:debug("Would restore scrollback of size:", #state.scrollback)
			-- This is challenging to do correctly, so it's left for future enhancement
		end
	else
		-- For non-shell processes, try to restart the same command
		-- This is simplistic and might not restore application state
		if state.command and state.command ~= "unknown" then
			pane:send_text(state.command .. "\r")
		end
	end
end

-- Determine if a set of panes can be pivoted
---@param panes table Array of panes to check
---@return boolean can_pivot
---@return string|nil orientation Current orientation if can pivot
function M.can_pivot(panes, pane_info_by_id)
	if #panes < 2 then
		logger:debug("Cannot pivot: Not enough panes (need at least 2)")
		return false, nil
	end

	-- For simplicity, we'll only support pivoting 2 panes for now
	if #panes > 2 then
		logger:debug("Currently only supporting 2-pane pivoting")
		return false, nil
	end

	local first_info = pane_info_by_id[panes[1]:pane_id()]
	local second_info = pane_info_by_id[panes[2]:pane_id()]
	local is_adjacent, orientation = lib.wezterm.get_panes_orientation(first_info, second_info)

	if not is_adjacent then
		logger:debug("Cannot pivot: Panes are not adjacent")
		return false, nil
	end

	if orientation == "unknown" then
		logger:debug("Cannot pivot: Could not determine pane orientation")
		return false, nil
	end

	logger:debug("Panes can be pivoted. Current orientation:", orientation)
	return true, orientation
end

-- Pivot two panes, toggling their orientation
---@param panes table Array of panes to pivot
---@param current_orientation string Current orientation "horizontal" or "vertical"
---@return boolean success
function M.pivot_panes(panes, current_orientation, pane_info_by_id, gui_window)
	-- Capture state of both panes
	local pane_states = {}
	for i, pane in ipairs(panes) do
		pane_states[i] = M.capture_pane_state(pane)
	end

	-- Determine target orientation (toggle)
	local target_orientation = current_orientation == "horizontal" and "vertical" or "horizontal"

	-- Sort panes by position for consistent behavior
	local sorted_panes = {}
	local sorted_states = {}
	local first_info = pane_info_by_id[panes[1]:pane_id()]
	local second_info = pane_info_by_id[panes[2]:pane_id()]

	if current_orientation == "horizontal" then
		-- Sort by x position for horizontal orientation
		if first_info.left < second_info.left then
			sorted_panes = { panes[1], panes[2] }
			sorted_states = { pane_states[1], pane_states[2] }
		else
			sorted_panes = { panes[2], panes[1] }
			sorted_states = { pane_states[2], pane_states[1] }
		end
	else
		-- Sort by y position for vertical orientation
		if first_info.top < second_info.top then
			sorted_panes = { panes[1], panes[2] }
			sorted_states = { pane_states[1], pane_states[2] }
		else
			sorted_panes = { panes[2], panes[1] }
			sorted_states = { pane_states[2], pane_states[1] }
		end
	end

	-- Close the second pane
	if not gui_window then
		logger:error("A GUI window is required to close the pane being pivoted")
		return false
	end
	sorted_panes[2]:activate()
	gui_window:perform_action(wezterm.action.CloseCurrentPane({ confirm = false }), sorted_panes[2])

	-- Create a new pane with the new orientation
	local new_pane
	if target_orientation == "horizontal" then
		-- Create horizontal split (side by side)
		new_pane = sorted_panes[1]:split({
			direction = "Right",
		})
	else
		-- Create vertical split (stacked)
		new_pane = sorted_panes[1]:split({
			direction = "Bottom",
		})
	end

	if not new_pane then
		logger:error("Failed to create new pane")
		return false
	end

	-- The first pane remains alive with its state intact; restore only the pane
	-- recreated by the new split.
	logger:debug("Restoring recreated pane:", sorted_states[2].process_name)
	M.restore_pane_state(new_pane, sorted_states[2])

	return true
end

-- Toggle pane orientation for the current or specified panes
---@param tab_or_pane? any Optional tab or pane to use (defaults to current)
---@return boolean success
function M.toggle_orientation(tab_or_pane, gui_window)
	local tab = tab_or_pane

	-- A keybinding callback supplies the active tab explicitly. For callers
	-- that pass a pane directly, retain support when the pane exposes its tab.
	if tab_or_pane and tab_or_pane.get_position then
		local ok, parent_tab = pcall(function()
			return tab_or_pane:tab()
		end)
		if ok then
			tab = parent_tab
		else
			logger:error("Could not determine the tab for the specified pane")
			return false
		end
	end

	if not tab then
		logger:error("No tab supplied; call this from a keybinding callback or pass a tab/pane")
		return false
	end

	local panes_with_info = tab:panes_with_info()
	local pane_info_by_id = {}
	for _, pane_info in ipairs(panes_with_info) do
		pane_info_by_id[pane_info.pane:pane_id()] = pane_info
	end

	-- If we were given a specific pane, find the adjacent pane to pivot with
	if tab_or_pane and tab_or_pane.get_position then
		local given_pane = tab_or_pane
		local adjacent_panes = {}
		table.insert(adjacent_panes, given_pane)

		-- Find an adjacent pane
		for _, p_info in ipairs(panes_with_info) do
			local pane = p_info.pane
			if pane ~= given_pane then
				local is_adjacent, _ = lib.wezterm.get_panes_orientation(
					pane_info_by_id[given_pane:pane_id()],
					pane_info_by_id[pane:pane_id()]
				)
				if is_adjacent then
					table.insert(adjacent_panes, pane)
					break
				end
			end
		end

		-- Check if we can pivot the selected panes
			local can_pivot, orientation = M.can_pivot(adjacent_panes, pane_info_by_id)
		if can_pivot then
			return M.pivot_panes(adjacent_panes, orientation, pane_info_by_id, gui_window)
		else
			logger:warn("Could not find suitable adjacent pane to pivot with")
			return false
		end
	else
		-- Handle the case of selected panes or active pane
		local selected_panes = {}

		-- Check if we have multiple selected panes
		for _, p_info in ipairs(panes_with_info) do
			if p_info.is_active or p_info.is_zoomed then
				table.insert(selected_panes, p_info.pane)
			end
		end

		-- If no selection, use the active pane and try to find an adjacent pane
		if #selected_panes < 2 then
			local active_pane = selected_panes[1]
			if not active_pane then
				for _, p_info in ipairs(panes_with_info) do
					if p_info.is_active then
						active_pane = p_info.pane
						table.insert(selected_panes, active_pane)
						break
					end
				end
			end

			-- Find an adjacent pane to the active pane
			if active_pane then
				for _, p_info in ipairs(panes_with_info) do
					local pane = p_info.pane
					if pane ~= active_pane then
						local is_adjacent, _ = lib.wezterm.get_panes_orientation(
							pane_info_by_id[active_pane:pane_id()],
							pane_info_by_id[pane:pane_id()]
						)
						if is_adjacent then
							table.insert(selected_panes, pane)
							break
						end
					end
				end
			end
		end

		-- Check if we can pivot the selected panes
		local can_pivot, orientation = M.can_pivot(selected_panes, pane_info_by_id)
		if can_pivot then
			return M.pivot_panes(selected_panes, orientation, pane_info_by_id, gui_window)
		else
			logger:warn("Could not find suitable panes to pivot")
			return false
		end
	end
end

-- Initialize the module
---@param module_config PivotConfig
---@return table
function M.setup(module_config)
	config.setup(module_config)
	logger:info("Pivot pane module initialized")
	return M
end

return M
