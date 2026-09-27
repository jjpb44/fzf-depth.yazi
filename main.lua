local M = {}

local state = ya.sync(function()
    local selected = {}
    for _, url in pairs(cx.active.selected) do
        selected[#selected + 1] = url
    end
    return cx.active.current.cwd, selected
end)

--- @param cwd Url
--- @param depth string|nil
--- @return Url[]
local function fd(cwd, depth)
    local selected = {}
    local output, err =
        Command('fd'):arg({ '-d', depth, '--no-ignore' }):cwd(tostring(cwd)):stdout(Command.PIPED):output()

    if not output or not output.status.success then
        return cwd, Err('Failed to start `fd`, error: %s', err)
    end

    for line in output.stdout:gmatch('[^\r\n]+') do
        selected[#selected + 1] = Url(line)
    end

    return selected
end

--- @param job {args: {depth: string|nil}}
function M:entry(job)
    ya.emit('escape', { visual = true })

    local cwd, selected = state()

    -- Searches always start at ~ (never the current pane). Picks open their
    -- own tabs, so the current tab is never touched.
    cwd = Url(os.getenv('HOME') or tostring(cwd))

    if cwd.spec and cwd.spec.is_virtual then
        return ya.notify({
            title = 'Fzf',
            content = 'Not supported under virtual filesystems',
            timeout = 5,
            level = 'warn',
        })
    end

    if #selected == 0 and job.args.depth and job.args.depth ~= '0' then
        selected = fd(cwd, job.args.depth)
    end

    local permit = ui.hide and ui.hide() or ya.hide()

    local output, err = M.run_with(cwd, selected)
    if not output then
        return ya.notify({ title = 'Fzf', content = tostring(err), timeout = 5, level = 'error' })
    end

    local urls = M.split_urls(cwd, output)
    if #urls == 0 then
        -- canceled: nothing was created, nothing to clean up.
    elseif #urls == 1 then
        -- Open the pick in a FRESH tab at its location (tab_create switches
        -- to it, so the follow-up reveal lands in the new tab).
        local target = tostring(urls[1])
        local cha = #selected == 0 and fs.cha(urls[1])
        if cha and cha.is_dir then
            ya.emit('tab_create', { target })
        else
            local dir = target:match('^(.*)/[^/]*$')
            if dir and dir ~= '' then
                ya.emit('tab_create', { dir })
                ya.emit('reveal', { urls[1] })
            else
                ya.emit('reveal', { urls[1] })
            end
        end
    elseif #urls > 1 then
        urls.state = #selected > 0 and 'off' or 'on'
        ya.emit('toggle_all', urls)
    end
end

function M.run_with(cwd, selected)
    local child, err = Command('fzf')
        :arg({ '-m', '--header', 'C-h: hidden files',
            '--bind', 'ctrl-h:reload(fd --type f --absolute-path --hidden)' })
        :env('FZF_DEFAULT_COMMAND', 'fd --type f --absolute-path')
        :cwd(tostring(cwd))
        :stdin(#selected > 0 and Command.PIPED or Command.INHERIT)
        :stdout(Command.PIPED)
        :spawn()

    if not child then
        return nil, Err('Failed to start `fzf`, error: %s', err)
    end

    for _, u in ipairs(selected) do
        child:write_all(string.format('%s\n', u))
    end
    if #selected > 0 then
        child:flush()
    end

    local output, err = child:wait_with_output()
    if not output then
        return nil, Err('Cannot read `fzf` output, error: %s', err)
    elseif not output.status.success and output.status.code ~= 130 then
        return nil, Err('`fzf` exited with error code %s', output.status.code)
    end
    return output.stdout, nil
end

function M.split_urls(cwd, output)
    local t = {}
    for line in output:gmatch('[^\r\n]+') do
        local u = Url(line)
        if u.is_absolute then
            t[#t + 1] = u
        else
            t[#t + 1] = cwd:join(u)
        end
    end
    return t
end

return M
