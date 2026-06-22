//
//  RiveNuxieScriptingBridge.mm
//  RiveRuntime
//
//  Created by Nuxie.
//

#import <RiveNuxieScriptingBridge.h>

#include <algorithm>
#include <climits>
#include <cmath>
#include <map>
#include <memory>
#include <string>

#include "rive/factory.hpp"
#include "rive/lua/rive_lua_libs.hpp"
#include "rive/lua/scripting_vm.hpp"
#include "rive/refcnt.hpp"

extern "C"
{
#include "lua.h"
#include "lualib.h"
}

static NSString* NuxieStringFromLua(lua_State* L, int index)
{
    size_t length = 0;
    const char* value = lua_tolstring(L, index, &length);
    if (value == nullptr)
    {
        return @"";
    }
    return [[NSString alloc] initWithBytes:value
                                    length:length
                                  encoding:NSUTF8StringEncoding]
        ?: @"";
}

static id NuxieObjectFromLua(lua_State* L, int index, int depth);

static id NuxieTableFromLua(lua_State* L, int index, int depth)
{
    if (depth > 12)
    {
        return [NSNull null];
    }

    if (index < 0)
    {
        index = lua_gettop(L) + index + 1;
    }
    NSMutableDictionary<NSString*, id>* dictionary =
        [NSMutableDictionary dictionary];
    std::map<int, id> arrayValues;
    bool arrayCandidate = true;
    int maxArrayIndex = 0;

    lua_pushnil(L);
    while (lua_next(L, index) != 0)
    {
        id value = NuxieObjectFromLua(L, -1, depth + 1) ?: [NSNull null];
        int keyType = lua_type(L, -2);

        if (keyType == LUA_TNUMBER)
        {
            double numericKey = lua_tonumber(L, -2);
            double integerKey = std::floor(numericKey);
            if (numericKey == integerKey && integerKey >= 1 &&
                integerKey <= INT_MAX)
            {
                int arrayIndex = (int)integerKey;
                arrayValues[arrayIndex] = value;
                maxArrayIndex = std::max(maxArrayIndex, arrayIndex);
            }
            else
            {
                arrayCandidate = false;
                dictionary[[NSString stringWithFormat:@"%g", numericKey]] =
                    value;
            }
        }
        else
        {
            arrayCandidate = false;
            NSString* key = NuxieStringFromLua(L, -2);
            if (key.length > 0)
            {
                dictionary[key] = value;
            }
        }

        lua_pop(L, 1);
    }

    if (maxArrayIndex > 0 && arrayCandidate && dictionary.count == 0 &&
        arrayValues.size() == (size_t)maxArrayIndex)
    {
        NSMutableArray* array = [NSMutableArray arrayWithCapacity:maxArrayIndex];
        for (int arrayIndex = 1; arrayIndex <= maxArrayIndex; arrayIndex++)
        {
            auto found = arrayValues.find(arrayIndex);
            if (found == arrayValues.end())
            {
                arrayCandidate = false;
                break;
            }
            [array addObject:found->second ?: [NSNull null]];
        }
        if (arrayCandidate)
        {
            return array;
        }
    }

    for (const auto& [key, value] : arrayValues)
    {
        dictionary[[NSString stringWithFormat:@"%d", key]] =
            value ?: [NSNull null];
    }
    return dictionary;
}

static id NuxieObjectFromLua(lua_State* L, int index, int depth)
{
    switch (lua_type(L, index))
    {
        case LUA_TNIL:
            return [NSNull null];
        case LUA_TBOOLEAN:
            return @(lua_toboolean(L, index) != 0);
        case LUA_TNUMBER:
            return @(lua_tonumber(L, index));
        case LUA_TSTRING:
            return NuxieStringFromLua(L, index);
        case LUA_TTABLE:
            return NuxieTableFromLua(L, index, depth);
        default:
            return [NSNull null];
    }
}

@interface RiveNuxieScriptingBridge ()
- (rive::ScriptingVM*)scriptingVMForFactory:(rive::Factory*)factory;
- (void)enqueueEventName:(NSString*)name
                 payload:(NSDictionary<NSString*, id>*)payload;
@end

class NuxieScriptingContext : public rive::CPPRuntimeScriptingContext
{
public:
    NuxieScriptingContext(rive::Factory* factory,
                          RiveNuxieScriptingBridge* bridge) :
        rive::CPPRuntimeScriptingContext(factory), m_bridge(bridge)
    {}

    void trigger(const char* name, NSDictionary<NSString*, id>* payload)
    {
        RiveNuxieScriptingBridge* bridge = m_bridge;
        if (bridge == nil)
        {
            return;
        }

        NSString* eventName =
            name == nullptr ? @"" : [NSString stringWithUTF8String:name];
        if (eventName.length == 0)
        {
            return;
        }

        [bridge enqueueEventName:eventName payload:payload ?: @{}];
    }

private:
    __unsafe_unretained RiveNuxieScriptingBridge* m_bridge;
};

static int NuxieTrigger(lua_State* L)
{
    const char* eventName = luaL_checkstring(L, 1);
    NSDictionary<NSString*, id>* payload = @{};

    if (lua_gettop(L) >= 2 && !lua_isnil(L, 2))
    {
        id parsedPayload = NuxieObjectFromLua(L, 2, 0);
        if ([parsedPayload isKindOfClass:[NSDictionary class]])
        {
            payload = parsedPayload;
        }
        else if (parsedPayload != nil && parsedPayload != [NSNull null])
        {
            payload = @{@"value" : parsedPayload};
        }
    }

    auto context =
        static_cast<NuxieScriptingContext*>(lua_getthreaddata(L));
    if (context != nullptr)
    {
        context->trigger(eventName, payload);
    }
    return 0;
}

static void SeedNuxieModule(lua_State* L)
{
    luaL_findtable(L, LUA_REGISTRYINDEX, "_MODULES", 1);
    lua_pushstring(L, "nuxie");
    lua_createtable(L, 0, 1);
    lua_pushcclosurek(L, NuxieTrigger, "nuxie.trigger", 0, nullptr);
    lua_setfield(L, -2, "trigger");
    lua_settable(L, -3);
    lua_pop(L, 1);
}

@implementation RiveNuxieScriptEvent

- (instancetype)initWithName:(NSString*)name
                     payload:(NSDictionary<NSString*, id>*)payload
{
    if (self = [super init])
    {
        _name = [name copy];
        _payload = [payload copy];
    }
    return self;
}

@end

@implementation RiveNuxieScriptingBridge
{
    rive::rcp<rive::ScriptingVM> _scriptingVM;
    NSMutableArray<RiveNuxieScriptEvent*>* _events;
}

- (instancetype)init
{
    if (self = [super init])
    {
        _events = [NSMutableArray array];
    }
    return self;
}

- (rive::ScriptingVM*)scriptingVMForFactory:(rive::Factory*)factory
{
    if (_scriptingVM == nullptr)
    {
        auto context =
            std::make_unique<NuxieScriptingContext>(factory, self);
        _scriptingVM =
            rive::make_rcp<rive::ScriptingVM>(std::move(context));
        SeedNuxieModule(_scriptingVM->state());
    }
    return _scriptingVM.get();
}

- (void)enqueueEventName:(NSString*)name
                 payload:(NSDictionary<NSString*, id>*)payload
{
    RiveNuxieScriptEvent* event =
        [[RiveNuxieScriptEvent alloc] initWithName:name payload:payload ?: @{}];
    @synchronized(self)
    {
        [_events addObject:event];
    }
}

- (NSArray<RiveNuxieScriptEvent*>*)drainTriggerEvents
{
    @synchronized(self)
    {
        NSArray<RiveNuxieScriptEvent*>* drained = [_events copy];
        [_events removeAllObjects];
        return drained;
    }
}

@end
