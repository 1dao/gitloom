-- Organizations and teams.  Kept in a separate JSON document so the feature
-- can be enabled without changing existing user/repository records.
local path = nil
local orgs = nil
local function ensure()
    if orgs then return true end
    path = util_path_join(cfg_get('DATA_DIR', 'data'), 'organizations.json')
    local raw = util_file_read(path)
    orgs = (raw and raw ~= '' and xutils.json_unpack(raw)) or {}
    if type(orgs) ~= 'table' then orgs = {} end
    return true
end
local function save()
    local body = xutils.json_pack(orgs)
    if not body then return nil, 'could not serialise organizations' end
    return util_file_write_atomic(path, body)
end
function g_exports.org_list() ensure(); local out={}; for _,o in pairs(orgs) do out[#out+1]=o end; return out end
function g_exports.org_get(slug) ensure(); return orgs[slug] end
function g_exports.org_create(owner, slug, name)
    ensure(); if type(slug)~='string' or not slug:match('^[a-z0-9][a-z0-9-]*$') then return nil,'invalid organization slug',400 end
    if orgs[slug] then return nil,'organization already exists',409 end
    local o={slug=slug,name=name or slug,owner=owner,members={[owner]='owner'},teams={},created_at=os.time()}; orgs[slug]=o
    local ok,err=save(); if not ok then orgs[slug]=nil; return nil,err,500 end; return o
end
function g_exports.org_team_put(slug, team, user, role)
    ensure(); local o=orgs[slug]; if not o then return nil,'organization not found',404 end
    if type(team)~='string' or not team:match('^[a-z0-9][a-z0-9-]*$') then return nil,'invalid team name',400 end
    if role~='member' and role~='maintainer' then return nil,'invalid team role',400 end
    o.teams[team]=o.teams[team] or {name=team,members={}}; o.teams[team].members[user]=role
    local ok,err=save(); if not ok then return nil,err,500 end; return o.teams[team]
end
function g_exports.org_member_put(slug,user,role) ensure(); local o=orgs[slug]; if not o then return nil,'organization not found',404 end; if role~='member' and role~='admin' then return nil,'invalid member role',400 end; o.members[user]=role; local ok,err=save(); if not ok then return nil,err,500 end; return o end
