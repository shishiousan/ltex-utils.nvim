local M = {}

local Config = require("ltex-utils.config")
local ltex_lsp = require("ltex-utils.ltex_lsp")
local settings_io = require("ltex-utils.settings_io")
local table_utils = require("ltex-utils.table_utils")
local Path = require("plenary.path")

local function ltex_filename(absolutePath)
	-- Separate path and filename
	local path, name_with_possible_ext = absolutePath:match("^(.-)([^/]+)$")
	-- -- Split filename into name and its optional extension using your pattern
	local name, ext = name_with_possible_ext:match("^([^%.]*)(%.?.*)$")
	-- -- Construct the new filename
	local newName = name .. ext:gsub("%.", "_") .. "_ltex.json"
	-- return path .. "~" .. newName
	-- return path .. newName
	--

	local parent = Path:new({ path })

	local path_ = Path:new({ parent, ".git" })
	if path_:exists() then
		return parent .. Path.path.sep .. "ltex-utils-settings.json"
	end

	local parents = parent:parents()

	for _, parent in pairs(parents) do
		path_ = Path:new({ parent, ".git" })
		if path_:exists() then
			return parent .. Path.path.sep .. "ltex-utils-settings.json"
		end
	end

	-- NOTE: Shion modified
	local common_dir = ".ltex-util"
	local home_dir = os.getenv("HOME")
	local new_path = home_dir .. "/" .. common_dir
	local ok, err = os.rename(new_path, new_path)
	if not ok then
		os.execute("mkdir " .. new_path)
		print(common_dir .. " directory was made in your home dir")
	else
		print("common setting file will be loaded from " .. common_dir .. " in your home dir")
	end
	-- return Path:new({ os.getenv("HOME"), "ltex-utils-settings.json" })
	return new_path .. "/ltex-utils-settings.json"
end

---Generates a code action handler updating LSP server settings with 'cmd_cfg'
---and 'setting_cfg' fields.
---@param cmd_cfg string The key for the code action command
---@param setting_cfg string The key of the server settings
---@return function(vim.lsp.diagnostic.action.command) # The code action handler
function M.new_handler(cmd_cfg, setting_cfg)
	return function(command)
		---@type table|nil
		local client = ltex_lsp.get_ltex()
		-- if no active ltex client abort
		if not client then
			return
		end

		---@type table<string, string[]>
		local settings = ltex_lsp.get_settings_or_init(client, setting_cfg)

		for lang, rules in pairs(command.arguments[1][cmd_cfg]) do
			table_utils.extend_or_init(settings[setting_cfg], lang, rules)
		end

		client.notify("workspace/didChangeConfiguration", client.config.settings)
	end
end

---Writes the current LTeX LSP server settings to a JSON file. It saves the
---current dictionaries and their languages, hidden false positives, and
---disabled rules. The settings are written to a JSON file, named
---'current_filename_ltex.json' located in its parent directory.
function M.write_ltex_to_file(bufnr)
	---@type integer
	bufnr = bufnr or vim.api.nvim_get_current_buf()
	---@type table|nil
	local client = ltex_lsp.get_ltex(bufnr)
	-- if no active ltex client abort
	if not client then
		vim.notify("No active ltex client found", vim.log.levels.ERROR)
		return
	end

	-- Use local variables to reduce table lookup cost
	---@type table
	local settings = client.config.settings.ltex
	if not settings then
		return
	end

	---@type string[]
	local langs
	if Config.dictionary.use_vim_dict then
		-- Neovim takes care of saving dictionaries
		-- only remember used languages
		langs = vim.tbl_keys(settings.dictionary)
	else
		-- save dictionaries; update them if necessary
		if settings.dictionary then
			settings_io.ensure_folder_exists(Config.dictionary.path)
			langs = settings_io.update_dictionary_files(settings.dictionary)
		end
	end

	---@type table<string, string[]>
	local settings_to_save = {}

	for _, settings_cfg in ipairs({ "hiddenFalsePositives", "disabledRules" }) do
		if settings[settings_cfg] then
			settings_to_save[settings_cfg] = settings[settings_cfg]
			langs = table_utils.merge_lists_unique(langs, vim.tbl_keys(settings[settings_cfg]))
		end
	end

	settings_to_save.langs = langs or nil

	if settings_to_save then
		---@type string
		local buf_filename = vim.api.nvim_buf_get_name(bufnr)
		settings_io.write(ltex_filename(buf_filename), vim.json.encode(settings_to_save))
	end
end

---Loads LTeX  LSP settings from JSON file. Updates the active LTeX LSP
---server with read settings (hidden false positives, disabled rules, and
---specific language dictionaries). Settings file given by
---'buffer_filename_ltex.json'.  If settings file doesn't exist, an
---notification is printed.
---@return boolean # true if successful, false otherwise.
---@return string|nil # nil if successful, error message otherwise.
function M.load_ltex_from_file()
	local bufnr = vim.api.nvim_get_current_buf()
	---@type table|nil
	local client = ltex_lsp.get_ltex(bufnr)
	-- if no active ltex client abort
	if not client then
		return false, "No active ltex client found"
	end

	---@type string
	local settings_filename = vim.api.nvim_buf_get_name(bufnr)

	---@type table<string, string[]>|nil, string|nil
	local saved_settings, err = settings_io.read_settings(ltex_filename(settings_filename))
	-- return error; we get here when opening a fresh tex-file
	-- without an existing config.
	if not saved_settings then
		return false, err
	end

	---@type table<string, string[]>
	local client_settings = client.config.settings.ltex
	client_settings.hiddenFalsePositives = saved_settings.hiddenFalsePositives or nil
	client_settings.disabledRules = saved_settings.disabledRules or nil

	if saved_settings.langs then
		if not client_settings.dictionary and #saved_settings.langs > 0 then
			client_settings.dictionary = {}
		end
		-- read the required dictionaries
		client_settings.dictionary = settings_io.load_dictionaries(saved_settings.langs)
	end

	client.notify("workspace/didChangeConfiguration", client.config.settings)
	return true, nil
end

return M
