-- Organization membership and repository permissions are separate. Team grants
-- use immutable IDs: recreating a deleted team cannot inherit its old access.
local orgs = nil
local busy = false
local pending_slug = nil

local function copy(value)
    if type(value) ~= 'table' then return value end
    local out = {}
    for k, v in pairs(value) do out[k] = copy(v) end
    return out
end

local function slug_key(slug)
    return type(slug) == 'string' and slug:lower() or ''
end

function g_exports.org_index_load()
    local map, err = store_collaboration_load('organizations')
    if not map then cfg_log_error('organization store: %s', tostring(err)); return nil, err end
    for slug, org in pairs(map) do
        if type(org) ~= 'table' or type(org.owner) ~= 'string' or
           type(org.members) ~= 'table' or type(org.teams) ~= 'table' then
            return nil, 'invalid organization record'
        end
        org.slug = slug
        org.members[org.owner] = 'owner'
        for _, team in pairs(org.teams) do
            if type(team) ~= 'table' or type(team.members) ~= 'table' then
                return nil, 'invalid team record'
            end
        end
    end
    orgs = map
    return map
end

function g_exports.org_get(slug)
    return orgs and orgs[slug_key(slug)]
end

function g_exports.org_name_reserved(slug)
    return pending_slug == slug_key(slug) or org_get(slug) ~= nil
end

function g_exports.org_can_manage(org, user)
    return org ~= nil and user ~= nil and
        (user.admin or org.owner == user.username or org.members[user.username] == 'admin')
end

function g_exports.org_list(user)
    local out = {}
    for _, org in pairs(orgs or {}) do
        if user and (user.admin or org.members[user.username]) then out[#out + 1] = org end
    end
    table.sort(out, function(a, b) return a.slug < b.slug end)
    return out
end

-- Never publish speculative privileges while a database write is pending.
local function mutate(slug, change, create)
    if not orgs then return nil, 'organization store unavailable', 503 end
    if busy then return nil, 'organization update in progress; retry', 409 end
    slug = slug_key(slug)
    local current = orgs[slug]
    if not current and not create then return nil, 'no such organization', 404 end
    local result, err, status = change(copy(current))
    if not result then return nil, err, status end
    local next_map = {}
    for k, v in pairs(orgs) do next_map[k] = v end
    next_map[slug] = result
    busy, pending_slug = true, slug
    local ok, saved, serr = pcall(store_collaboration_save, 'organizations', next_map)
    busy, pending_slug = false, nil
    if not ok or not saved then
        cfg_log_error('organization persistence failed: %s', tostring(ok and serr or saved))
        return nil, 'could not persist organization', 500
    end
    orgs = next_map
    return result
end

function g_exports.org_create(owner, slug, name)
    if type(slug) ~= 'string' or #slug > 100 or not slug:match('^[a-z0-9][a-z0-9-]*$') or
       not repo_name_ok(slug) then return nil, 'invalid organization slug', 400 end
    if name ~= nil and (type(name) ~= 'string' or #name > 200 or name == '') then
        return nil, 'organization name must be 1 to 200 bytes', 400
    end
    if org_name_reserved(slug) then return nil, 'organization already exists', 409 end
    if auth_namespace_exists(slug) then return nil, 'owner namespace already exists', 409 end
    for _, rec in ipairs(repo_list()) do
        if rec.owner:lower() == slug then return nil, 'owner namespace already exists', 409 end
    end
    return mutate(slug, function()
        return { slug = slug, name = name or slug, owner = owner,
            members = { [owner] = 'owner' }, teams = {}, created_at = os.time() }
    end, true)
end

function g_exports.org_member_put(slug, username, role)
    if role ~= 'member' and role ~= 'admin' then return nil, 'invalid member role', 400 end
    local exists, err = auth_user_exists(username)
    if err then return nil, err, 503 end
    if not exists then return nil, 'no such user', 404 end
    return mutate(slug, function(org)
        if org.owner == username then return nil, 'cannot demote organization owner', 409 end
        org.members[username] = role
        return org
    end)
end

function g_exports.org_member_delete(slug, username)
    return mutate(slug, function(org)
        if org.owner == username then return nil, 'cannot remove organization owner', 409 end
        if not org.members[username] then return nil, 'no such member', 404 end
        org.members[username] = nil
        for _, team in pairs(org.teams) do team.members[username] = nil end
        return org
    end)
end

local function valid_team(name)
    return type(name) == 'string' and #name <= 100 and name:match('^[a-z0-9][a-z0-9-]*$')
end

function g_exports.org_team_create(slug, name)
    if not valid_team(name) then return nil, 'invalid team name', 400 end
    return mutate(slug, function(org)
        if org.teams[name] then return nil, 'team already exists', 409 end
        org.teams[name] = { name = name, id = util_rand_hex(16), members = {} }
        return org
    end)
end

function g_exports.org_team_put(slug, name, username, role)
    if not valid_team(name) then return nil, 'invalid team name', 400 end
    if role ~= 'member' and role ~= 'maintainer' then return nil, 'invalid team role', 400 end
    return mutate(slug, function(org)
        if not org.members[username] then return nil, 'user must be an organization member', 400 end
        if not org.teams[name] then return nil, 'no such team', 404 end
        local team = org.teams[name]
        team.id = team.id or util_rand_hex(16)
        team.members[username] = role
        return org
    end)
end

function g_exports.org_team_member_delete(slug, name, username)
    return mutate(slug, function(org)
        local team = org.teams[name]
        if not team then return nil, 'no such team', 404 end
        if not team.members[username] then return nil, 'no such team member', 404 end
        team.members[username] = nil
        return org
    end)
end

function g_exports.org_team_delete(slug, name)
    return mutate(slug, function(org)
        if not org.teams[name] then return nil, 'no such team', 404 end
        org.teams[name] = nil
        return org
    end)
end

function g_exports.org_repo_permission(rec, user)
    local org = rec and org_get(rec.owner)
    if not org or not user then return nil end
    if org_can_manage(org, user) then return 'admin' end
    if not org.members[user.username] then return nil end
    local level
    for _, team in pairs(org.teams) do
        if team.id and team.members[user.username] then
            local grant = (rec.collaborators or {})['@team/' .. team.id]
            if grant == 'write' then return 'write' end
            if grant == 'read' then level = 'read' end
        end
    end
    return level
end
