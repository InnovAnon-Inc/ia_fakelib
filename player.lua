-- ia_fakelib/player.lua

-- Define methods for the Fakelib State Layer
local fake_player_methods = {
    is_player = function() return true end,
    is_valid = function() return true end,
    get_player_name = function(self)
        local data = self.data or (self.fake_player and self.fake_player.data)
        assert(data ~= nil, "Fakelib data missing in get_player_name")
        return data.name
    end,
    get_inventory = function(self)
        local data = self.data or (self.fake_player and self.fake_player.data)
        assert(data ~= nil, "Fakelib data missing in get_inventory")
        return data.inventory
    end,
    get_meta = function(self)
        local data = self.data or (self.fake_player and self.fake_player.data)
        assert(data ~= nil, "Fakelib data missing in get_meta")
        return data.metadata
    end,
    get_wield_index = function(self)
        local data = self.data or (self.fake_player and self.fake_player.data)
        return data and data.wield_index or 1
    end,
    get_wield_list = function(self)
        local data = self.data or (self.fake_player and self.fake_player.data)
        return data and data.wield_list or "main"
    end,
    get_player_control = function(self)
        return {jump=false, up=false, down=false, left=false, right=false, sneak=false, aux1=false, dig=false, place=false, zoom=false}
    end,
    get_breath = function(self)
        local data = self.data or (self.fake_player and self.fake_player.data)
        assert(data ~= nil, "Fakelib data missing in get_breath")
        return data.breath or 11 -- Default to full breath (usually 10 or 11 in MT)
    end,
    set_breath = function(self, value)
        local data = self.data or (self.fake_player and self.fake_player.data)
        assert(data ~= nil, "Fakelib data missing in set_breath")
        data.breath = value
        -- We don't need to call the engine object's set_breath because it would return nil/fail
        return true
    end,
}

--- Checks if an object is a (fake) player
function fakelib.is_player(x)
    if type(x) == "userdata" and x.is_player and x:is_player() then
        return true
    elseif type(x) == "table" and x.is_player and x:is_player() then
        return true
    end
    return false
end

--- Universal Proxy Bridge
--- Ensures the Lua entity table (self) can act as a proxy for both Fakelib state and ObjectRef logic.
function fakelib.bridge_object(object, entity, proxy)
    assert(object ~= nil, "[fakelib] Cannot bridge a nil ObjectRef")
    assert(entity ~= nil, "[fakelib] Cannot bridge a nil Lua entity")
    assert(proxy ~= nil,  "[fakelib] Cannot bridge a nil player proxy")

    -- FIX: We MUST create a new, unique metatable for every entity instance.
    -- If we modify the existing metatable, all mobs of this type will share
    -- the proxy of the most recently initialized mob.
    local mt = {} 

    mt.__index = function(t, k)
        -- 1. Explicit Data Trapdoor
        if k == "data" then
            return proxy.data
        end

        -- 2. State Layer Methods (get_player_name, etc.)
        if fake_player_methods[k] then
            return function(inner_t, ...)
                return fake_player_methods[k](proxy, ...)
            end
        end

        -- 3. Check the Proxy Instance (Interceptors like set_properties live here)
        if proxy[k] ~= nil then
            if type(proxy[k]) == "function" then
                return function(inner_t, ...)
                    return proxy[k](proxy, ...)
                end
            end
            return proxy[k]
        end

        -- 4. Fallback: Standard Engine ObjectRef methods
        local engine_val = object[k]
        if type(engine_val) == "function" then
            return function(inner_t, ...)
                return engine_val(object, ...)
            end
        end

        return engine_val
    end

    setmetatable(entity, mt)
end

-- Constructor for the Fakelib Player Proxy
function fakelib.create_player(options)
    local data = {}
    local input = type(options) == "table" and options or { name = options }

    -- 1. Initialize Persistent State
    data.name = input.name or "unknown"
    data.wield_index = 1
    data.wield_list = "main"
    data.metadata = fakelib.create_metadata()
    data.inventory = fakelib.create_inventory({
        main = 32,
        craft = 9,
        craftpreview = 1,
        craftresult = 1,
        hand = 1
    })
    data.properties = {}

    -- 2. Initialize the Physical Layer
    assert(ia_fake_player ~= nil, "[fakelib] ia_fake_player is not initialized")
    local physical_proxy = { object = input.object }
    setmetatable(physical_proxy, { __index = ia_fake_player })

    -- 3. Build the Composite Instance
    local instance = {
        data = data,
        object = input.object,
    }

    -- 4. Setup Delegation Logic for the Proxy itself (with property caching)
    local mt = {
        __index = function(t, k)
            if k == "data" then return data end

            -- INTERCEPTOR: Capture visual changes so they can be persisted
            if k == "set_properties" then
                return function(inner_t, props)
                    for pk, pv in pairs(props) do
                        data.properties[pk] = pv
                    end
                    return instance.object:set_properties(props)
                end
            elseif k == "get_properties" then
                return function(inner_t)
                    return instance.object:get_properties()
                end
            end

            -- Priority: State Methods
            if fake_player_methods[k] then
                return function(inner_t, ...) return fake_player_methods[k](instance, ...) end
            end

            -- Priority: Physical Proxy
            if physical_proxy[k] ~= nil then
                if type(physical_proxy[k]) == "function" then
                    return function(inner_t, ...)
                        return physical_proxy[k](physical_proxy, ...)
                    end
                end
                return physical_proxy[k]
            end

            -- Fallback: Engine Object
            local obj_val = instance.object and instance.object[k]
            if type(obj_val) == "function" then
                return function(inner_t, ...)
                    return obj_val(instance.object, ...)
                end
            end
            return obj_val
        end
    }
    setmetatable(instance, mt)

    return instance
end

-- ia_fakelib/player.lua

--- Unifies ObjectRefs into a Player-like interface.
-- If it's a real player, returns the ObjectRef.
-- If it's a bridged mob, returns the bridged entity (self).
-- @param obj The ObjectRef to check.
-- @return The player-compatible object or nil.
function fakelib.get_player_interface(obj)
    if not obj or not obj:is_valid() then return nil end

    -- 1. Real Engine Players
    if obj:is_player() then
        return obj
    end

    -- 2. Bridged Mobs
    -- We check the luaentity. If it has been bridged,
    -- its is_player() method (from fake_player_methods) will return true.
    local ent = obj:get_luaentity()
    if ent and ent.is_player and ent:is_player() then
        return ent
    end

    return nil
end
