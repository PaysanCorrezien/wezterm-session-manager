local wezterm = require "wezterm"
local session_manager = {}

-- TODO: add global config options Neovim stylem with defaults that user override
-- use config.param in others functions
function session_manager.config()
  return "not implemented"
end

--- Displays a notification in WezTerm.
-- @param message string: The notification message to be displayed.
--- Displays a system notification and logs the message.
-- https://wezfurlong.org/wezterm/config/lua/window/toast_notification.html?
-- On windows it doesnt close the notification after time_ms
---@param args table: A table containing the arguments for the notification.
---  - window userdata (required): The window object where the notification will be displayed.
---  - title string (optional): The notification title to be displayed. Defaults to "WezTerm Session Manager".
---  - message string (optional): The notification message to be displayed. Defaults to "Wezterm Notification by Session Manager".
---  - url string (optional): The URL to be opened when the notification is clicked. Defaults to nil (no URL).
---  - time_ms number (optional): The duration of the notification in milliseconds. Defaults to 2000.
local function display_notification(args)
  -- Extract arguments from the table and assign default values
  local window = args.window
  local title = args.title or "WezTerm Session Manager"
  local message = args.message or "Wezterm Notification by Session Manager"
  local url = args.url
  local time_ms = args.time_ms or 2000

  -- Validate required arguments
  if not window then
    error "display_notification: 'window' argument is required"
  end
  -- Log the message
  wezterm.log_info(message)

  -- Display the notification
  window:toast_notification(title, message, url, time_ms)
end

--- Retrieves the current workspace data from the active window.
-- @return table or nil: The workspace data table or nil if no active window is found.
local function retrieve_workspace_data(window)
  local workspace_name = window:active_workspace()
  local workspace_data = {
    name = workspace_name,
    tabs = {},
  }

  -- Iterate over tabs in the current window
  for _, tab in ipairs(window:mux_window():tabs()) do
    local tab_data = {
      tab_id = tostring(tab:tab_id()),
      panes = {},
    }

    -- Iterate over panes in the current tab
    for _, pane_info in ipairs(tab:panes_with_info()) do
      -- Collect pane details, including layout and process information
      table.insert(tab_data.panes, {
        pane_id = tostring(pane_info.pane:pane_id()),
        index = pane_info.index,
        is_active = pane_info.is_active,
        is_zoomed = pane_info.is_zoomed,
        left = pane_info.left,
        top = pane_info.top,
        width = pane_info.width,
        height = pane_info.height,
        pixel_width = pane_info.pixel_width,
        pixel_height = pane_info.pixel_height,
        cwd = tostring(pane_info.pane:get_current_working_dir()),
        tty = tostring(pane_info.pane:get_foreground_process_name()),
      })
    end

    table.insert(workspace_data.tabs, tab_data)
  end

  return workspace_data
end

--- Saves data to a JSON file.
-- @param data table: The workspace data to be saved.
-- @param file_path string: The file path where the JSON file will be saved.
-- @return boolean: true if saving was successful, false otherwise.
local function save_to_json_file(data, file_path)
  if not data then
    wezterm.log_info "No workspace data to log."
    return false
  end

  local file = io.open(file_path, "w")
  if file then
    file:write(wezterm.json_encode(data))
    file:close()
    return true
  else
    return false
  end
end

--- Recreates the workspace based on the provided data.
-- @param workspace_data table: The data structure containing the saved workspace state.
local function recreate_workspace(window, workspace_data)
  if not workspace_data or not workspace_data.tabs then
    wezterm.log_info "Invalid or empty workspace data provided."
    return
  end

  local tabs = window:mux_window():tabs()

  if #tabs ~= 1 or #tabs[1]:panes() ~= 1 then
    wezterm.log_info "Restoration can only be performed in a window with a single tab and a single pane, to prevent accidental data loss."
    return
  end

  local initial_pane = window:active_pane()
  local foreground_process = initial_pane:get_foreground_process_name()

  -- Check if the foreground process is a shell
  if
    foreground_process:find "sh"
    or foreground_process:find "cmd.exe"
    or foreground_process:find "powershell.exe"
    or foreground_process:find "pwsh.exe"
  then
    -- Safe to close
    initial_pane:send_text "exit\r"
  else
    wezterm.log_info "Active program detected. Skipping exit command for initial pane."
  end

  -- Recreate tabs and panes from the saved state
  -- should work for windows and linux
  local is_windows = wezterm.target_triple:find "windows" ~= nil

  for i, tab_data in ipairs(workspace_data.tabs) do
    local cwd_uri = tab_data.panes[1].cwd
    local cwd_path

    if is_windows then
      -- On Windows, transform 'file:///C:/path/to/dir' to 'C:/path/to/dir'
      cwd_path = cwd_uri:gsub("file:///", "")
    else
      -- On Linux, transform 'file:///path/to/dir' to '/path/to/dir'
      cwd_path = cwd_uri:gsub("file://", "")
    end

    local new_tab = window:mux_window():spawn_tab { cwd = cwd_path }

    if not new_tab then
      wezterm.log_info "Failed to create a new tab."
      break
    end

    -- Activate the new tab before creating panes
    new_tab:activate()

    -- Recreate panes within this tab
    for j, pane_data in ipairs(tab_data.panes) do
      local new_pane
      if j == 1 then
        new_pane = new_tab:active_pane()
      else
        local direction = "Right"
        if pane_data.left == tab_data.panes[j - 1].left then
          direction = "Bottom"
        end

        new_pane = new_tab:active_pane():split {
          direction = direction,
          cwd = pane_data.cwd:gsub("file:///", ""),
        }
      end

      if not new_pane then
        wezterm.log_info "Failed to create a new pane."
        break
      end

      -- Restore TTY for Neovim on Linux
      -- NOTE: cwd is handled differently on windows. maybe extend functionality for windows later
      -- This could probably be handled better in general
      if not is_windows and pane_data.tty == "/usr/bin/nvim" then
        new_pane:send_text(pane_data.tty .. " ." .. "\n")
      end
    end
  end

  wezterm.log_info "Workspace recreated with new tabs and panes based on saved state."
  return true
end

--- Loads data from a JSON file.
-- @param file_path string: The file path from which the JSON data will be loaded.
-- @return table or nil: The loaded data as a Lua table, or nil if loading failed.
local function load_from_json_file(file_path)
  local file = io.open(file_path, "r")
  if not file then
    wezterm.log_info("Failed to open file: " .. file_path)
    return nil
  end

  local file_content = file:read "*a"
  file:close()

  local data = wezterm.json_parse(file_content)
  if not data then
    wezterm.log_info("Failed to parse JSON data from file: " .. file_path)
  end
  return data
end

--- Loads the saved json file matching the current workspace.
function session_manager.restore_state(window)
  local workspace_name = window:active_workspace()
  local file_path = wezterm.home_dir
    .. "/.config/wezterm/wezterm-session-manager/wezterm_state_"
    .. workspace_name
    .. ".json"

  local workspace_data = load_from_json_file(file_path)
  if not workspace_data then
    window:toast_notification(
      "WezTerm",
      "Workspace state file not found for workspace: " .. workspace_name,
      nil,
      4000
    )
    return
  end

  if recreate_workspace(window, workspace_data) then
    window:toast_notification(
      "WezTerm",
      "Workspace state loaded for workspace: " .. workspace_name,
      nil,
      4000
    )
  else
    window:toast_notification(
      "WezTerm",
      "Workspace state loading failed for workspace: " .. workspace_name,
      nil,
      4000
    )
  end
end

-- Helper function to get a list of active workspace names
-- @return table A list of active workspace names
local function get_active_sessions()
  local all_windows = wezterm.mux.all_windows()
  local active_workspaces = {}

  for _, win in ipairs(all_windows) do
    local workspace_name = win:get_workspace()
    table.insert(active_workspaces, workspace_name)
  end

  return active_workspaces
end
-- go throught the list of all sessions and try to find the provide session name
local function is_session_active(session_name, active_sessions)
  for _, active_session_name in ipairs(active_sessions) do
    if session_name == active_session_name then
      return true
    end
  end
  return false
end

-- return a table of all saved sessions and the absolute path to the file containing the session information
local function get_session_saved(folder_path, pattern)
  local sessions = {}
  pattern = pattern or "wezterm_state_"
  folder_path = folder_path
    or wezterm.home_dir .. "/.config/wezterm/wezterm-session-manager/"

  for _, file in ipairs(wezterm.read_dir(folder_path)) do
    if file:find(pattern) then
      local session_name = file:match(pattern .. "(.+)%.json$")
      if session_name then
        sessions[session_name] = file
      end
    end
  end
  return sessions
end

---@param window userdata: The GuiWindow object.
---@param pane userdata: The MuxPane object.
---@param session_name string: The name of the session to restore.
---@param selected_path string: The absolute path to the file containing the session information.
local function restore_session_state(window, pane, session_name, selected_path)
  wezterm.log_info(
    "Restoring session '" .. session_name .. "' from path: " .. selected_path
  )

  -- Create a new workspace which returns a MuxTab object ...
  -- --NOTE: this create a mux_window but dont create the associated GUI window ,
  -- cant go this route i guess because GUIwindow cant be crate by mux on background ?
  -- we could go from Muxtab to MuxWindow to GUIwindow but it fail :
  -- event: mux window id 8 is not currently associated with a gui window
  -- local _, _, mux_window =
  --   wezterm.mux.spawn_window { workspace = selected_session_name }
  -- Switch to the workspace first; this should trigger UI window creation too
  window:perform_action(wezterm.action.SwitchToWorkspace { name = session_name }, pane)

  -- Retrieve all GUI windows
  local all_gui_windows = wezterm.gui.gui_windows()

  -- Find the GUI window that matches the target workspace
  local gui_window = nil
  for _, gw in ipairs(all_gui_windows) do
    if gw:active_workspace() == session_name then
      gui_window = gw
      break
    end
  end

  if not gui_window then
    wezterm.log_error("Failed to find a GUI window for the workspace: " .. session_name)
    return
  end

  -- Load session data from the JSON file
  local session_data = load_from_json_file(selected_path)
  if not session_data then
    wezterm.log_error("Failed to load session data from: " .. selected_path)
    return
  end

  -- Restore the session state using the found GuiWindow object
  recreate_workspace(gui_window, session_data) --NOTE: maybe add return type to recreate_workspace to check if it fail or not ?
  display_notification {
    window = gui_window,
    message = "Workspace loaded successfully!",
  }
end

--- Open a file dialog to select a session file to load
--- verify if the session is already active, then reload it
---@param window userdata Guiwindow
function session_manager.load_state(window)
  local active_pane = window:active_pane()
  local active_sessions = get_active_sessions()
  local saved_sessions = get_session_saved()
  local choices = {} --- For input selector
  local path_map = {} -- for path lookup
  for session_name, path in pairs(saved_sessions) do
    table.insert(choices, { id = tostring(session_name), label = session_name })
    path_map[session_name] = path
  end

  window:perform_action(
    wezterm.action.InputSelector {
      choices = choices,
      alphabet = "123456789",
      description = "Press the key corresponding to the session you want to reload to! Press '/' to start FuzzySearch",
      action = wezterm.action_callback(function(window, pane, id, label)
        if not id then
          wezterm.log_error "id is nil"
          return
        end

        local selected_session_name = id
        local selected_path = path_map[selected_session_name]

        if not is_session_active(selected_session_name, active_sessions) then
          restore_session_state(window, pane, selected_session_name, selected_path)
        else
          display_notification {
            window = window,
            message = "Workspace already Exist, Skipping ",
          }
        end
      end),
    },
    active_pane
  )
end

--TODO: Find way to multi select ?
--
--- Delete a session file
---@param window userdata Guiwindow
function session_manager.delete_saved_session(window)
  local active_pane = window:active_pane()
  local saved_sessions = get_session_saved()
  local choices = {}

  for session_name, path in pairs(saved_sessions) do
    wezterm.log_info("Deleting session '" .. session_name .. "' from path: " .. path)
    table.insert(choices, { id = tostring(session_name), label = session_name })
  end
  window:perform_action(
    wezterm.action.InputSelector {
      choices = choices,
      alphabet = "123456789",
      description = "Press the key corresponding to the saved session you want to delete! Press '/' to start FuzzySearch",
      action = wezterm.action_callback(function(window, pane, id, label)
        if not id then
          wezterm.log_error "id is nil"
          return
        end
        local file_to_delete = saved_sessions[id]
        wezterm.log_info("Deleting session '" .. id .. " with file  " .. file_to_delete)
        local success, err = pcall(function()
          os.remove(file_to_delete)
        end)
        if not success then
          display_notification {
            window = window,
            message = "Failed to delete session '" .. id .. "' : " .. err,
          }
        else
          display_notification {
            window = window,
            message = "Session '" .. id .. "' deleted successfully",
          }
        end
      end),
    },
    active_pane
  )
end

-- reload all states files saved, tmux ressurect like
-- TODO: Implement
-- Should check if its the first process of wezterm , to not reload if others system window are open ?
--
function session_manager.resurrect_all_sessions(window)
  local active_pane = window:active_pane()
  local all_saved_sessions = get_session_saved()
  local active_sessions = get_active_sessions()

  if wezterm_is_first_instance() then
    wezterm.log_info "First instance of wezterm, skipping reload all states"
  end

  for session_name, path in pairs(all_saved_sessions) do
    if not is_session_active(session_name, active_sessions) then
      wezterm.log_info("Restoring session '" .. session_name .. "' from path: " .. path)
      restore_session_state(window, active_pane, session_name, path)
    end
    wezterm.log_info("Session '" .. session_name .. "' already active, skipping")
  end
  display_notification {
    window = window,
    message = "All saved sessions loaded successfully!",
  }
end
--- Orchestrator function to save the current workspace state.
-- Collects workspace data, saves it to a JSON file, and displays a notification.
function session_manager.save_state(window)
  local data = retrieve_workspace_data(window)

  -- Construct the file path based on the workspace name
  local file_path = wezterm.home_dir
    .. "/.config/wezterm/wezterm-session-manager/wezterm_state_"
    .. data.name
    .. ".json"

  -- Save the workspace data to a JSON file and display the appropriate notification
  if save_to_json_file(data, file_path) then
    window:toast_notification(
      "WezTerm Session Manager",
      "Workspace state saved successfully",
      nil,
      4000
    )
  else
    window:toast_notification(
      "WezTerm Session Manager",
      "Failed to save workspace state",
      nil,
      4000
    )
  end
end

return session_manager
