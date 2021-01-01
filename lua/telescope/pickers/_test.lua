local assert = require('luassert')
local builtin = require('telescope.builtin')
local log = require('telescope.log')

local Job = require("plenary.job")
local Path = require("plenary.path")

local tester = {}

tester.debug = false

local replace_terms = function(input)
  return vim.api.nvim_replace_termcodes(input, true, false, true)
end

local nvim_feed = function(text, feed_opts)
  feed_opts = feed_opts or "m"

  vim.api.nvim_feedkeys(text, feed_opts, true)
end

local writer = function(...)
  if tester.debug then
    print(...)
  else
    io.stderr:write(...)
  end
end

local execute_test_case = function(location, key, spec)
  local ok, actual = pcall(spec[2])

  if not ok then
    writer(vim.fn.json_encode({
      location = 'Error: ' .. location,
      case = key,
      expected = 'To succeed and return: ' .. tostring(spec[1]),
      actual = actual,

      _type = spec._type,
    }))
  else
    writer(vim.fn.json_encode({
      location = location,
      case = key,
      expected = spec[1],
      actual = actual,

      _type = spec._type,
    }))
  end

  writer("\n")
end

local end_test_cases = function()
  vim.cmd [[qa!]]
end

local invalid_test_case = function(k)
  writer(vim.fn.json_encode({ case = k, expected = '<a valid key>', actual = k }))
  writer("\n")

  end_test_cases()
end

tester.picker_feed = function(input, test_cases)
  input = replace_terms(input)

  return coroutine.wrap(function()
    for i = 1, #input do
      local char = input:sub(i, i)
      nvim_feed(char, "")

      -- TODO: I'm not 100% sure this is a hack or not...
      -- it's possible these characters  could still have an on_complete... but i'm not sure.
      if string.match(char, "%g") then
        coroutine.yield()
      end

      if tester.debug then
        vim.wait(200)
      end
    end

    vim.wait(10)

    if tester.debug then
      coroutine.yield()
    end

    vim.defer_fn(function()
      if test_cases.post_typed then
        for k, v in ipairs(test_cases.post_typed) do
          execute_test_case('post_typed', k, v)
        end
      end

      nvim_feed(replace_terms("<CR>"), "")
    end, 20)

    vim.defer_fn(function()
      if test_cases.post_close then
        for k, v in ipairs(test_cases.post_close) do
          execute_test_case('post_close', k, v)
        end
      end

      if tester.debug then
        return
      end

      vim.defer_fn(end_test_cases, 20)
    end, 40)

    coroutine.yield()
  end)
end

local _VALID_KEYS = {
  post_typed = true,
  post_close = true,
}

tester.builtin_picker = function(builtin_key, input, test_cases, opts)
  opts = opts or {}
  tester.debug = opts.debug or false

  for k, _ in pairs(test_cases) do
    if not _VALID_KEYS[k] then
      return invalid_test_case(k)
    end
  end

  opts.on_complete = {
    tester.picker_feed(input, test_cases),
  }

  builtin[builtin_key](opts)
end

local get_results_from_file = function(file)
  local j = Job:new {
    command = 'nvim',
    args = {
      '--noplugin',
      '-u',
      'scripts/minimal_init.vim',
      '-c',
      'luafile ' .. file
    },
  }

  j:sync()

  local results = j:stderr_result()
  local result_table = {}
  for _, v in ipairs(results) do
    table.insert(result_table, vim.fn.json_decode(v))
  end

  return result_table
end


local asserters = {
  _default = assert.are.same,

  are = assert.are.same,
  are_not = assert.are_not.same,
}


local check_results = function(results)
  -- TODO: We should get all the test cases here that fail, not just the first one.
  for _, v in ipairs(results) do
    local assertion = asserters[v._type or 'default']

    assertion(
      v.expected,
      v.actual,
      string.format("Test Case: %s // %s",
        v.location,
        v.case)
    )
  end
end

tester.run_string = function(contents)
  local tempname = vim.fn.tempname()
  log.info("Running test string: ", tempname)

  contents = [[
  local tester = require('telescope.pickers._test')
  local helper = require('telescope.pickers._test_helpers')

  helper.make_globals()
  ]] .. contents

  vim.fn.writefile(vim.split(contents, "\n"), tempname)
  local result_table = get_results_from_file(tempname)
  vim.fn.delete(tempname)

  log.info("Completed string test: ", tempname)

  check_results(result_table)
  -- assert.are.same(result_table.expected, result_table.actual)
end

tester.run_file = function(filename)
  log.info("Running test file:", filename)

  local file = './lua/tests/pickers/' .. filename .. '.lua'

  if not Path:new(file):exists() then
    assert.are.same("<An existing file>", file)
  end

  local result_table = get_results_from_file(file)

  log.info("Completed file test:", filename)
  check_results(result_table)
end

tester.not_ = function(val)
  val._type = 'are_not'
  return val
end

return tester
