-- This is a run strategy for "meta" tasks. This task itself will not perform
-- any jobs, but will instead wrap and manage a collection of other tasks.
local constants = require("overseer.constants")
local log = require("overseer.log")
local Task = require("overseer.task")
local task_list = require("overseer.task_list")
local template = require("overseer.template")
local util = require("overseer.util")
local STATUS = constants.STATUS

---@param tasks table
---@param cb fun(task: overseer.Task)
local function for_each_task(tasks, cb)
  for _, section in ipairs(tasks) do
    for _, id in ipairs(section) do
      local task = task_list.get(id)
      if task then
        cb(task)
      end
    end
  end
end

---@class overseer.OrchestratorStrategy : overseer.Strategy
---@field bufnr integer
---@field task_defns overseer.Serialized[][]
---@field tasks integer[][]
local OrchestratorStrategy = {}

---Strategy for a meta-task that manage a sequence of other tasks
---@param opts table
---    tasks table A list of task definitions to run. Can include sub-lists that will be run in parallel
---@return overseer.Strategy
---@example
--- overseer.new_task({
---   name = "Build and serve app",
---   strategy = {
---     "orchestrator",
---     tasks = {
---       "make clean", -- Step 1: clean
---       {             -- Step 2: build js and css in parallel
---          "npm build",
---         { "shell", cmd = "lessc styles.less styles.css" },
---       },
---       "npm serve",  -- Step 3: serve
---     },
---   },
--- })
function OrchestratorStrategy.new(opts)
  vim.validate({
    opts = { opts, "t" },
  })
  vim.validate({
    tasks = { opts.tasks, "t" },
  })
  -- Each entry in tasks can be either a task definition, OR a list of task definitions.
  -- Convert it to each entry being a list of task definitions.
  local task_defns = {}
  for i, v in ipairs(opts.tasks) do
    if type(v) == "table" and vim.tbl_islist(v) then
      task_defns[i] = v
    else
      task_defns[i] = { v }
    end
  end
  return setmetatable({
    task = nil,
    bufnr = vim.api.nvim_create_buf(false, true),
    task_defns = task_defns,
    tasks = {},
  }, { __index = OrchestratorStrategy })
end

function OrchestratorStrategy:render_buf()
  if not self.bufnr or not vim.api.nvim_buf_is_valid(self.bufnr) then
    return
  end
  local ns = vim.api.nvim_create_namespace("overseer")
  vim.api.nvim_buf_clear_namespace(self.bufnr, ns, 0, -1)

  local lines = {}
  local highlights = {}

  local columns = {}
  local col_widths = {}
  local max_row = 0

  local function calc_width(task)
    return vim.api.nvim_strwidth(task.name) + task.status:len() + 1
  end

  for i, task_ids in ipairs(self.tasks) do
    columns[i] = vim.tbl_map(task_list.get, task_ids)
    col_widths[i] = 1
    for _, task in ipairs(columns[i]) do
      col_widths[i] = math.max(col_widths[i], calc_width(task))
    end
    max_row = math.max(max_row, #columns[i])
  end

  for i = 1, max_row do
    local line = {}
    local col_start = 0
    for j, column in ipairs(columns) do
      local task = column[i]
      if task then
        table.insert(
          line,
          util.ljust(string.format("%s %s", task.status, task.name), col_widths[j])
        )
        local col_end = col_start + task.status:len()
        table.insert(
          highlights,
          { string.format("Overseer%s", task.status), #lines + 1, col_start, col_end }
        )
      else
        table.insert(line, string.rep(" ", col_widths[j]))
      end
      col_start = col_start + line[#line]:len() + 4
    end
    table.insert(lines, table.concat(line, " -> "))
  end

  vim.bo[self.bufnr].modifiable = true
  vim.api.nvim_buf_set_lines(self.bufnr, 0, -1, true, lines)
  vim.bo[self.bufnr].modifiable = false
  vim.bo[self.bufnr].modified = false
  util.add_highlights(self.bufnr, ns, highlights)
end

function OrchestratorStrategy:reset()
  self.task = nil
  for_each_task(self.tasks, function(task)
    task:reset()
  end)
end

function OrchestratorStrategy:get_bufnr()
  return self.bufnr
end

---@param task_ids integer[]
local function get_status(task_ids)
  for _, v in ipairs(task_ids) do
    local task = task_list.get(v)
    local status = task and task.status or STATUS.FAILURE
    if status ~= STATUS.SUCCESS then
      return status
    end
  end
  return STATUS.SUCCESS
end

function OrchestratorStrategy:start_next()
  if self.task and not self.task:is_complete() then
    local all_success = false
    for i, section in ipairs(self.tasks) do
      local status = get_status(section)
      if status == STATUS.PENDING then
        for _, id in ipairs(section) do
          local task = task_list.get(id)
          if task and task:is_pending() then
            task:start()
          end
        end
        break
      elseif status == STATUS.RUNNING then
        break
      elseif status == STATUS.FAILURE or status == STATUS.CANCELED then
        if self.task and self.task:is_running() then
          self.task:finalize(status)
        end
        break
      end
      all_success = i == #self.tasks
    end
    if all_success then
      self.task:finalize(STATUS.SUCCESS)
    end
  end
  self:render_buf()
end

---@param task overseer.Task
function OrchestratorStrategy:start(task)
  self.task = task
  task:add_component("orchestrator.on_broadcast_update_orchestrator")
  local function section_complete(idx)
    for _, v in ipairs(self.tasks[idx]) do
      if v == -1 then
        return false
      end
    end
    return vim.tbl_count(self.tasks[idx]) == vim.tbl_count(self.task_defns[idx])
  end
  local search = {
    dir = self.task.cwd,
  }
  for i, section in ipairs(self.task_defns) do
    self.tasks[i] = self.tasks[i] or {}
    for j, def in ipairs(section) do
      local task_idx = { i, j }
      local name, params = util.split_config(def)
      params = params or {}
      local subtask = self.tasks[i][j] and task_list.get(self.tasks[i][j])
      if not subtask or subtask:is_disposed() then
        self.tasks[i][j] = -1
        template.get_by_name(name, search, function(tmpl)
          if not tmpl then
            log:error("Orchestrator could not find task '%s'", name)
            self.task:finalize(STATUS.FAILURE)
            return
          end
          local build_opts = {
            search = search,
            params = params,
          }
          template.build_task_args(
            tmpl,
            build_opts,
            vim.schedule_wrap(function(task_defn)
              if not task_defn then
                log:warn("Canceled building task '%s'", name)
                self.task:finalize(STATUS.FAILURE)
                return
              end
              if params.cwd then
                task_defn.cwd = params.cwd
              end
              if task_defn.env or params.env then
                task_defn.env = vim.tbl_deep_extend("force", task_defn.env or {}, params.env or {})
              end
              local new_task = Task.new(task_defn)
              new_task:add_component("orchestrator.on_status_broadcast")
              -- Don't include child tasks when saving to bundle. We will re-create them when the
              -- orchestration task is loaded.
              new_task:set_include_in_bundle(false)
              self.tasks[task_idx[1]][task_idx[2]] = new_task.id
              if section_complete(1) then
                self:start_next()
              end
            end)
          )
        end)
      end
    end
  end
  if section_complete(1) then
    self:start_next()
  end
end

function OrchestratorStrategy:stop()
  for_each_task(self.tasks, function(task)
    task:stop()
  end)
end

function OrchestratorStrategy:dispose()
  for_each_task(self.tasks, function(task)
    task:dispose()
  end)
  util.soft_delete_buf(self.bufnr)
end

return OrchestratorStrategy
