local util = require('model.util')
local sse = require('model.util.sse')

local M = {}

local default_params = {
  model = 'claude-3-opus-20240229',
  stream = true,
}

M.default_prompt = {
  provider = M,
  builder = function(input)
    return {
      messages = {
        {
          role = 'user',
          content = input,
        },
      },
    }
  end,
}

local function extract_chat_data(item)
  local data = util.json.decode(item)
  if data ~= nil and data.delta ~= nil then
    return {
      content = (data.delta or {}).text,
      stop_reason = data.delta.stop_reason,
    }
  end
end

---@deprecated Completion endpoints are pretty outdated
local function extract_completion_data(item)
  local data = util.json.decode(item)
  if data ~= nil and data.choices ~= nil then
    return {
      content = (data.content[1] or {}).text,
      stop_reason = data.content[1].stop_reason,
    }
  end
end

---@param handlers StreamHandlers
---@param params? any Additional options for OpenAI endpoint
---@param options? { url?: string, endpoint?: string, authorization?: string } Request endpoint and url. Defaults to 'https://api.anthropic.com/v1' and 'messages'. `authorization` overrides the request auth header. If url is provided the environment key will not be sent, you'll need to provide an authorization.
function M.request_completion(handlers, params, options)
  options = options or {}

  local headers = {
    ['x-api-key'] = util.env('ANTHROPIC_API_KEY'),
    ['anthropic-version'] = '2023-06-01',
    ['Content-Type'] = 'application/json',
  }

  local endpoint = options.endpoint or 'messages' -- TODO does this make compat harder?
  local extract_data = endpoint == 'messages' and extract_chat_data
    or extract_completion_data

  local completion = ''

  return sse.curl_client({
    headers = headers,
    method = 'POST',
    url = util.string.joinpath(
      options.url or 'https://api.anthropic.com/v1/',
      endpoint
    ),
    body = vim.tbl_deep_extend('force', default_params, params),
  }, {
    on_message = function(message, pending)
      local data = extract_data(message.data)

      if data == nil then
        if not message.data == '[DONE]' then
          handlers.on_error(
            vim.inspect({
              data = message.data,
              pending = pending,
            }),
            'Unrecognized SSE message data'
          )
        end
      else
        if data.content ~= nil then
          completion = completion .. data.content
          handlers.on_partial(data.content)
        end

        if data.stop_reason ~= nil then
          handlers.on_finish(completion, data.stop_reason)
        end
      end
    end,
    on_other = function(content)
      -- Non-SSE message likely means there was an error
      handlers.on_error(content, 'Anthropic API error')
    end,
    on_error = handlers.on_error,
  })
end

---@param standard_prompt StandardPrompt
function M.adapt(standard_prompt)
  return {
    messages = util.table.flatten({
      {
        role = 'system',
        content = standard_prompt.instruction,
      },
      standard_prompt.fewshot,
      standard_prompt.messages,
    }),
  }
end

--- Sets default openai provider params. Currently enforces `stream = true`.
function M.initialize(opts)
  default_params = vim.tbl_deep_extend('force', default_params, opts or {}, {
    stream = true, -- force streaming since data parsing will break otherwise
  })
end

-- These are convenience exports for building prompt params specific to this provider
M.prompt = {}

function M.prompt.input_as_message(input)
  return {
    role = 'user',
    content = input,
  }
end

function M.prompt.add_args_as_last_message(messages, context)
  if #context.args > 0 then
    table.insert(messages, {
      role = 'user',
      content = context.args,
    })
  end

  return messages
end

function M.prompt.input_and_args_as_messages(input, context)
  return {
    messages = M.add_args_as_last_message(M.input_as_message(input), context),
  }
end

function M.prompt.with_system_message(text)
  return function(input, context)
    local body = M.input_and_args_as_messages(input, context)

    table.insert(body.messages, 1, {
      role = 'system',
      content = text,
    })

    return body
  end
end

return M
