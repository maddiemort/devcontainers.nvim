local M = {}

local meta_model = require('devcontainers.lsp.meta_model')
local OperationTree = require('devcontainers.lsp.operation_tree').OperationTree
local utils = require('devcontainers.utils')
local log = require('devcontainers.log').rpc

---@enum devcontainers.lsp.ErrorCodes
M.LspErrorCodes = {
	ParseError = -32699,
	InvalidRequest = -32599,
	MethodNotFound = -32600,
	InvalidParams = -32601,
	InternalError = -32602,
	jsonrpcReservedErrorRangeStart = -32098,
	ServerNotInitialized = -32001,
	UnknownErrorCode = -32000,
	jsonrpcReservedErrorRangeEnd = -31999;
	lspReservedErrorRangeStart = -32898,
	RequestFailed = -32802,
	ServerCancelled = -32801,
	ContentModified = -32800,
	RequestCancelled = -32799,
	lspReservedErrorRangeEnd = -32799,
}

local model_ctx = meta_model.Context:new(meta_model.load())

---@alias devcontainers.rpc.Direction 'server2client'|'client2server'
---@class devcontainers.rpc.PerDirection<T>: { server2client: T, client2server: T }

---@alias devcontainers.rpc.Mappings devcontainers.rpc.PerDirection<devcontainers.rpc.DirectionMappings>

---@class devcontainers.rpc.DirectionMappings lookups by method
---@field request_params table<string, devcontainers.OperationTree>
---@field request_result table<string, devcontainers.OperationTree>
---@field notification_params table<string, devcontainers.OperationTree>

---@class devcontainers.rpc.MappingContext
---@field method string
---@field direction devcontainers.rpc.Direction
---@field type 'request_params'|'request_result'|'notification_params'
---@field tree devcontainers.OperationTree

---@alias devcontainers.rpc.MappingFn fun(ctx: devcontainers.rpc.MappingContext, value: any)

---@return devcontainers.rpc.DirectionMappings
local function new_dir_mappings()
    return {
        request_params = {},
        request_result = {},
        notification_params = {},
    }
end

---@param item_filter fun(item: devcontainers.LspTypeIter.Item): boolean should only match on basic (leaf) items!
---@return devcontainers.rpc.Mappings
function M.make_mappings(item_filter)
    ---@type devcontainers.rpc.Mappings
    local mappings = {
        server2client = new_dir_mappings(),
        client2server = new_dir_mappings(),
    }

    ---@param method string
    ---@param messageDirection LspMetaModel.MessageDirection
    ---@param data_type LspMetaModel.Type
    ---@param store_to 'request_params'|'request_result'|'notification_params'
    local function add_data_type(method, messageDirection, data_type, store_to)
        ---@type devcontainers.OperationTree[]
        local trees = {}

        for item, visitor in model_ctx:iter_types(data_type) do
            assert(item)
            if item_filter(item) then
                local tree = assert(OperationTree.from_path(model_ctx, visitor.stack))
                table.insert(trees, tree)
            end
        end

        if next(trees) then
            local tree = OperationTree.merged(unpack(trees)):simplified()

            if messageDirection == 'both' or messageDirection == 'clientToServer' then
                assert(not mappings.client2server[store_to][method], method)
                mappings.client2server[store_to][method] = tree
            end
            if messageDirection == 'both' or messageDirection == 'serverToClient' then
                assert(not mappings.server2client[store_to][method], method)
                mappings.server2client[store_to][method] = tree
            end
        end
    end

    for _, request in ipairs(model_ctx.model.requests) do
        -- TODO: request.params/notification.params may be an array of types?
        if request.params then
            add_data_type(request.method, request.messageDirection, request.params, 'request_params')
        end
        add_data_type(request.method, request.messageDirection, request.result, 'request_result')
    end
    for _, notification in ipairs(model_ctx.model.notifications) do
        if notification.params then
            add_data_type(notification.method, notification.messageDirection, notification.params, 'notification_params')
        end
    end

    return mappings
end

---@generic T
---@param value T
---@param fn devcontainers.rpc.MappingFn
---@param ctx devcontainers.rpc.MappingContext .tree can be nil
---@return T
local function apply(value, fn, ctx)
    if value ~= nil and ctx.tree ~= nil then
        local ok, new_value = pcall(ctx.tree.apply, ctx.tree, function(v)
            return fn(ctx, v)
        end, value)
        if ok then
            value = new_value
        else
            local err = new_value
            log.error('%s:\nmethod=%s, direction=%s type=%s, tree=%s,\nvalue=%s', err, ctx.method, ctx.direction, ctx.type, ctx.tree, vim.inspect(value))
        end
    end
    return value
end

M.stats = utils.new_stats()
apply = M.stats:wrap_fn(apply)

---@param dispatchers vim.lsp.rpc.Dispatchers
---@param mappings devcontainers.rpc.DirectionMappings
---@param fn devcontainers.rpc.MappingFn
---@return vim.lsp.rpc.Dispatchers
function M.wrap_server_to_client(dispatchers, mappings, fn)
    ---@type vim.lsp.rpc.Dispatchers
    return {
        notification = function(method, params)
            log.debug('server2client:notification:%s', method)
            log.trace('params=%s', utils.lazy_inspect_oneline(params))
            params = apply(params, fn, {
                method = method,
                direction = 'server2client',
                type = 'notification_params',
                tree = mappings.notification_params[method]
            })
            return dispatchers.notification(method, params)
        end,
        server_request = function(method, params)
            log.debug('server2client:request:%s', method)
            log.trace('params=%s', utils.lazy_inspect_oneline(params))
            params = apply(params, fn, {
                method = method,
                direction = 'server2client',
                type = 'request_params',
                tree = mappings.request_params[method]
            })
            local result, err = dispatchers.server_request(method, params)
            log.debug('server2client:response:%s', method)
            if not err then
                log.trace('result=%s', utils.lazy_inspect_oneline(result))
                result = apply(result, fn, {
                    method = method,
                    direction = 'client2server', -- reversed
                    type = 'request_result',
                    tree = mappings.request_result[method]
                })
            end
            return result, err
        end,
        on_exit = function(code, signal)
            log.debug('server2client:on_exit: code=%s signal=%s', code, signal)
            return dispatchers.on_exit(code, signal)
        end,
        on_error = function(code, err)
            log.debug('server2client:on_error: code=%s err=%s', code, err)
            return dispatchers.on_error(code, err)
        end,
    }
end

---@param rpc vim.lsp.rpc.PublicClient
---@param mappings devcontainers.rpc.DirectionMappings
---@param fn devcontainers.rpc.MappingFn
---@return vim.lsp.rpc.PublicClient
function M.wrap_client_to_server(rpc, mappings, fn)
    ---@type vim.lsp.rpc.PublicClient
    return {
        request = function(method, params, callback, notify_reply_callback)
            -- NOTE: We need to deepcopy because some data in params may be stored by reference, e.g. vim.lsp puts workspace_folders
            -- in initialize request so modifying it leads to problems. Deepcopying is seems to be cheap enough to do this for every
            -- if it ever becomes bottleneck we may try to limit it to only the `params` that we modify.
            -- `noref=true` seems to be more performant for LSP from my benchmarks.
            params = vim.deepcopy(params, true)
			
			-- (Based)pyright checks whether LSP is running via kill(PID, 0), fails because container doesn't have host PID or smth. See: https://github.com/microsoft/pyright/discussions/5917
			if method == "initialize" and params and params.processId then
				log.trace("Nullifying processId in initialize request to prevent container PID namespace issues")
				params.processId = vim.NIL
			end

            log.debug('client2server:request:%s', method)
            log.trace('params=%s', utils.lazy_inspect_oneline(params))
            params = apply(params, fn, {
                method = method,
                direction = 'client2server',
                type = 'request_params',
                tree = mappings.request_params[method]
            })
            return rpc.request(method, params, function(err, result)
                log.debug('client2server:response:%s', method)
                if not err then
                    log.trace('result=%s', utils.lazy_inspect_oneline(result))
                    result = apply(result, fn, {
                        method = method,
                        direction = 'server2client', -- reversed
                        type = 'request_result',
                        tree = mappings.request_result[method]
                    })
                end
                return callback(err, result)
            end, notify_reply_callback)
        end,
        notify = function(method, params)
            params = vim.deepcopy(params, true)
            log.debug('client2server:notify:%s', method)
            log.trace('params=%s', utils.lazy_inspect_oneline(params))
            params = apply(params, fn, {
                method = method,
                direction = 'client2server',
                type = 'notification_params',
                tree = mappings.notification_params[method]
            })
            return rpc.notify(method, params)
        end,
        is_closing = function()
            log.debug('client2server:is_closing')
            return rpc.is_closing()
        end,
        terminate = function()
            log.debug('client2server:terminate')
            return rpc.terminate()
        end,
    }
end

---@return vim.lsp.rpc.PublicClient
---@return fun(client?: vim.lsp.rpc.PublicClient, err?: string) resolve
function M.make_stub()
    ---@type (fun(ok: boolean, err?: string))[]
    local pending = {}

    ---@param callback fun(ok: boolean, err?: string)
    local function push_pending(callback)
        table.insert(pending, callback)
    end

    --- Client table to be returned as vim.lsp.ClientConfig.cmd
    ---@type vim.lsp.rpc.PublicClient
    ---@diagnostic disable-next-line:missing-fields
    local client = {}

    ---@param other vim.lsp.rpc.PublicClient
    local function set_client(other)
        client.request = assert(other.request)
        client.notify = assert(other.notify)
        client.is_closing = assert(other.is_closing)
        client.terminate = assert(other.terminate)
    end

    ---@param new_client? vim.lsp.rpc.PublicClient
    ---@param err? string
    local function resolve(new_client, err)
        if new_client then -- success
            log.info('stub: resolved sucessfully, handling %d pending operations', #pending)
            -- Replace the stubs with the final client and successfully resolve all pending operations
            set_client(new_client)
            for _, callback in ipairs(pending) do
                callback(true)
            end
        else -- failure
            err = err or '?'
            log.info('stub: resolved with error: "%s" (%d pending operations)', err, #pending)
            -- Resolve all pending operations as errors and don't accept any more operations
            local function panic()
                log.exception('stub: rpc client no longer valid: %s', err)
            end
            set_client({ request = panic, notify = panic, is_closing = panic, terminate = panic })
            for _, callback in ipairs(pending) do
                callback(false, err)
            end
        end
    end

    --- Table with stub methods used until resolve is called
    ---@type vim.lsp.rpc.PublicClient
    ---@diagnostic disable-next-line:missing-fields
    local stub = {}
    local message_id = 0

    function stub.request(method, params, callback, notify_reply_callback)
        push_pending(function(ok, err)
            if ok then
                assert(client.request ~= stub.request) -- must have already been replaced with the proper client
                client.request(method, params, callback, notify_reply_callback)
            else
                callback({ code = M.LspErrorCodes.ServerNotInitialized, message = err or 'Lsp server startup failed' })
            end
        end)
        message_id = message_id + 1
        local id = message_id
        log.debug('stub: queued client2server:request:%s: %d', method, id)
        return true, id
    end

    function stub.notify(method, params)
        push_pending(function(ok)
            if ok then
                assert(client.notify ~= stub.notify)
                client.notify(method, params)
            end
        end)
        log.debug('stub: queued client2server:notify:%s', method)
        return true
    end

    function stub.is_closing()
        return false
    end

    function stub.terminate()
        push_pending(function(ok)
            if ok then
                assert(client.terminate ~= stub.terminate)
                client.terminate()
            end
        end)
        log.debug('stub: queued client2server:terminate')
    end

    set_client(stub)
    return client, resolve
end

---@param config vim.lsp.ClientConfig
---@param cmd string[]|fun(dispatchers: vim.lsp.rpc.Dispatchers): vim.lsp.rpc.PublicClient
---@return fun(dispatchers: vim.lsp.rpc.Dispatchers): vim.lsp.rpc.PublicClient
function M.cmd_to_rpc(config, cmd)
    if type(cmd) == 'function' then
        return cmd
    end
    return function(dispatchers)
        return vim.lsp.rpc.start(cmd, dispatchers, {
            cwd = config.cmd_cwd,
            env = config.cmd_env,
            detached = config.detached,
        })
    end
end

---@param config vim.lsp.ClientConfig
---@param cmd string[]
---@param mappings devcontainers.rpc.Mappings
---@param fn devcontainers.rpc.MappingFn
---@return fun(dispatchers: vim.lsp.rpc.Dispatchers): vim.lsp.rpc.PublicClient
function M.wrap_cmd(config, cmd, mappings, fn)
    local start_rpc = M.cmd_to_rpc(config, cmd)
    return function(dispatchers)
        dispatchers = M.wrap_server_to_client(dispatchers, mappings.server2client, fn)
        local rpc = start_rpc(dispatchers)
        return M.wrap_client_to_server(rpc, mappings.client2server, fn)
    end
end

return M
