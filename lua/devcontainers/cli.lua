local M = {}

local config = require('devcontainers.config')
local utils = require('devcontainers.utils')
local log = require('devcontainers.log').cli

-- TODO: use this at least in health check
M.is_supported = utils.lazy(function()
    local result = utils.system(utils.flatten(config.devcontainers_cli_cmd, '--version'))
    if result.code == 0 and #result.stdout > 0 then
        log.debug('Found devcontainer-cli version %s', result.stdout)
        return true
    else
        log.notify.warn('devcontainer-cli not available')
        return false
    end
end)

--- Run a long running task with overseer, parser JSONs from output
---@param cmd string[]
---@param opts? { name?: string, cwd?: string }
---@async
---@return { code: integer, result?: table }
local function overseer_task(cmd, opts)
    opts = opts or {}

    -- Because stderr/stdout are interleaved we must parse JSONs from output
    local overseer = require('overseer')
    local task = overseer.new_task {
        cmd = cmd,
        name = opts.name,
        cwd = opts.cwd,
        components = {
            'default',
            -- { 'on_output_parse', parser = { 'loop', { 'sequence', { 'extract_json' } } } },
            -- { 'on_output_parse', parser = { jsons = { { 'loop', { 'extract_json' } } } } },
            -- { 'on_output_parse', parser = { jsons = { 'extract_json' } } },
            {
                'on_output_parse',
                parser = {
                    'extract',
                    {
                        postprocess = function(data)
                            data.json = vim.F.npcall(vim.json.decode, data.json)
                        end,
                    },
                    '(%b{})',
                    'json',
                },
            },
        },
    }
    local resume = utils.coroutine_resume()
    task:subscribe('on_complete', resume)
    task:start()
    local result = coroutine.yield()
    task:unsubscribe('on_complete', resume)

    -- Use last non-empty JSONs as result
    local json
    for _, res in ipairs(task.result) do
        if res.json and res.json ~= vim.empty_dict() then
            json = res.json
        end
    end

    return {
        code = result.exit_code,
        result = json,
    }
end

--- Should return the command override if workspace_dir matches, otherwise return nil
---@alias devcontainer.cli.CmdOverrideFn fun(workspace_dir: string, subcommand: string, ...): (string[]|nil)

---@class devcontainer.cli.CmdOverride
---@field id string
---@field fn devcontainer.cli.CmdOverrideFn
---@field priority number

---@type table<string, devcontainer.cli.CmdOverride>
local overrides_by_id = {}

---@type devcontainer.cli.CmdOverride[]
local overrides_sorted = {}

---@param id string
---@param fn devcontainer.cli.CmdOverrideFn
---@param priority? number defaults to 0
function M.register_cmd_override(id, fn, priority)
    assert(not overrides_by_id[id])
    local entry = { id = id, fn = fn, priority = vim.F.if_nil(priority, 0) }
    overrides_by_id[id] = entry
    table.insert(overrides_sorted, entry)
    -- sort from highest to lowest priority
    table.sort(overrides_sorted, function(a, b)
        return a.priority > b.priority
    end)
end

---@param id string
function M.clear_cmd_override(id)
    overrides_by_id[id] = nil
    for i, entry in ipairs(overrides_sorted) do
        if entry.id == id then
            table.remove(overrides_sorted, i)
            return
        end
    end
end

---@param workspace_dir string
---@param subcommand string
---@vararg string
---@return string[]
function M.cmd(workspace_dir, subcommand, ...)
    for _, override in ipairs(overrides_sorted) do
        local cmd = override.fn(workspace_dir, subcommand, ...)
        if cmd then
            return cmd
        end
    end
    return utils.flatten(config.devcontainers_cli_cmd, subcommand, '--workspace-folder', workspace_dir, ...)
end

---@param out vim.SystemCompleted
---@return boolean is_success
---@return devcontainer.up_status?
local function up_status(out)
    if out.code ~= 0 then
        return false
    end
    local info = vim.F.npcall(vim.json.decode, out.stdout)
    if not info then
        log.error('Could not decode JSON from %s', utils.lazy_inspect(out))
        return false
    end
    return info.outcome == 'success', info
end

---@param workspace_dir string
---@return { ok: boolean, error?: string, code: integer, status?: devcontainer.up_status }
function M.devcontainer_up(workspace_dir)
    local cmd = M.cmd(workspace_dir, 'up')
    local ret
    -- TODO: refactor task management into single interface with multiple backends
    if vim.F.npcall(require, 'overseer') then
        local out = overseer_task(cmd, { name = 'devcontainer up' })
        local ok = out.code == 0 and vim.tbl_get(out, 'result', 'outcome') == 'success'
        ret = {
            ok = ok,
            code = out.code,
            error = not ok and vim.inspect(out) or nil,
            status = out.result,
        }
    else
        local short_dir = vim.fn.pathshorten(workspace_dir)
        local notif = vim.notify(string.format('Starting devcontainer in %s', short_dir))
        local result = utils.system(cmd)
        local ok, status = up_status(result)
        ret = {
            ok = ok,
            error = not ok and table.concat({result.stdout, result.stderr}, '\n') or nil,
            code = result.code,
            status = status
        }
        if ok then
            local msg = string.format('Starting devcontainer in %s: OK', short_dir)
            vim.notify(msg, nil, { replace = notif and notif.id })
        else
            local msg = string.format('Starting devcontainer in %s: FAILED: code=%d status=%s', short_dir, result.code, vim.inspect(status))
            vim.notify(msg, nil, { replace = notif and notif.id })
        end
    end
    return ret
end

---@class devcontainer.cli.Config
---@field workspace devcontainer.cli.Config.workspace
---@field configuration devcontainer.cli.Config.configuration

---@class devcontainer.cli.Config.workspace
---@field workspaceFolder string
---@field workspaceMount string

---@class devcontainer.cli.Config.configuration: table
---@field configFilePath { fsPath: string, path: string, scheme: string }

---@param workspace_dir string
---@return devcontainer.cli.Config
function M.read_configuration(workspace_dir)
    local result = utils.system(M.cmd(workspace_dir, 'read-configuration'))
    if result.code ~= 0 then
        log.exception('read-configuration failed for %s: %s', workspace_dir, result.stderr)
    end
    return assert(vim.json.decode(result.stdout))
end

---@param workspace_dir string
---@param cmd string[]
---@param opts? vim.SystemOpts
---@return { stdout: string, stderr: string }
function M.exec(workspace_dir, cmd, opts)
    local result = utils.system(M.cmd(workspace_dir, 'exec', unpack(cmd)), opts)
    if result.code ~= 0 then
        log.exception('exec failed for %s: stderr="%s" stdout="%s" signal=%s', workspace_dir, result.stderr, result.stdout, result.signal)
    end
    return { stdout = result.stdout, stderr = result.stderr }
end

---@param workspace_dir string
---@return boolean
function M.container_is_running(workspace_dir)
    local ok = pcall(M.exec, workspace_dir, {'echo'})
    return ok
end

return M
