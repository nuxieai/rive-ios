//
//  RiveScriptRuntime.mm
//  RiveRuntime
//

#import <RiveScriptRuntime.h>

#include <CoreFoundation/CoreFoundation.h>
#include <algorithm>
#include <climits>
#include <cmath>
#include <map>
#include <memory>

#include "rive/assets/script_asset.hpp"
#include "rive/factory.hpp"
#include "rive/file.hpp"
#include "rive/lua/rive_lua_libs.hpp"
#include "rive/lua/scripting_vm.hpp"
#include "rive/refcnt.hpp"

static const int maxScriptValueDepth = 12;

static NSString* RiveStringFromLua(lua_State* L, int index)
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

static id RiveObjectFromLua(lua_State* L, int index, int depth);

static id RiveTableFromLua(lua_State* L, int index, int depth)
{
    if (depth > maxScriptValueDepth)
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
        id value = RiveObjectFromLua(L, -1, depth + 1) ?: [NSNull null];
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
            NSString* key = RiveStringFromLua(L, -2);
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

static id RiveObjectFromLua(lua_State* L, int index, int depth)
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
            return RiveStringFromLua(L, index);
        case LUA_TTABLE:
            return RiveTableFromLua(L, index, depth);
        default:
            return [NSNull null];
    }
}

static bool RiveNumberIsBoolean(NSNumber* number)
{
    return CFGetTypeID((__bridge CFTypeRef)number) == CFBooleanGetTypeID();
}

static void RivePushObjectToLua(lua_State* L, id object, int depth)
{
    if (object == nil || object == [NSNull null] || depth > maxScriptValueDepth)
    {
        lua_pushnil(L);
        return;
    }

    if ([object isKindOfClass:[NSNumber class]])
    {
        NSNumber* number = (NSNumber*)object;
        if (RiveNumberIsBoolean(number))
        {
            lua_pushboolean(L, number.boolValue ? 1 : 0);
        }
        else
        {
            lua_pushnumber(L, number.doubleValue);
        }
        return;
    }

    if ([object isKindOfClass:[NSString class]])
    {
        NSString* string = (NSString*)object;
        NSData* data = [string dataUsingEncoding:NSUTF8StringEncoding];
        lua_pushlstring(L, (const char*)data.bytes, data.length);
        return;
    }

    if ([object isKindOfClass:[NSArray class]])
    {
        NSArray* array = (NSArray*)object;
        lua_createtable(L, (int)array.count, 0);
        for (NSUInteger index = 0; index < array.count; index++)
        {
            RivePushObjectToLua(L, array[index], depth + 1);
            lua_rawseti(L, -2, (int)index + 1);
        }
        return;
    }

    if ([object isKindOfClass:[NSDictionary class]])
    {
        NSDictionary* dictionary = (NSDictionary*)object;
        lua_createtable(L, 0, (int)dictionary.count);
        for (id key in dictionary)
        {
            NSString* stringKey = [key isKindOfClass:[NSString class]]
                                      ? (NSString*)key
                                      : [key description];
            if (stringKey.length == 0)
            {
                continue;
            }
            RivePushObjectToLua(L, dictionary[key], depth + 1);
            lua_setfield(L, -2, stringKey.UTF8String);
        }
        return;
    }

    lua_pushstring(L, [[object description] UTF8String]);
}

@interface RiveScriptRuntime ()
- (rive::ScriptingVM*)scriptingVMForFactory:(rive::Factory*)factory;
- (void)registerUnverifiedScriptsInFile:(rive::File*)file;
- (id)invokeModuleNamed:(NSString*)moduleName
          functionNamed:(NSString*)functionName
              arguments:(NSArray<id>*)arguments;
@end

static int RiveScriptHostFunction(lua_State* L)
{
    RiveScriptRuntime* runtime =
        (__bridge RiveScriptRuntime*)lua_touserdata(L, lua_upvalueindex(1));
    NSString* moduleName = RiveStringFromLua(L, lua_upvalueindex(2));
    NSString* functionName = RiveStringFromLua(L, lua_upvalueindex(3));

    if (runtime == nil || moduleName.length == 0 || functionName.length == 0)
    {
        return 0;
    }

    int argumentCount = lua_gettop(L);
    NSMutableArray<id>* arguments =
        [NSMutableArray arrayWithCapacity:(NSUInteger)argumentCount];
    for (int index = 1; index <= argumentCount; index++)
    {
        [arguments addObject:RiveObjectFromLua(L, index, 0) ?: [NSNull null]];
    }

    id result = [runtime invokeModuleNamed:moduleName
                             functionNamed:functionName
                                 arguments:arguments];
    if (result == nil || result == [NSNull null])
    {
        return 0;
    }

    RivePushObjectToLua(L, result, 0);
    return 1;
}

static void RiveInstallScriptModule(lua_State* L,
                                    RiveScriptRuntime* runtime,
                                    RiveScriptModule* module)
{
    if (module.name.length == 0)
    {
        return;
    }

    luaL_findtable(L, LUA_REGISTRYINDEX, "_MODULES", 1);
    lua_pushstring(L, module.name.UTF8String);
    lua_createtable(L, 0, (int)module.functions.count);

    for (NSString* functionName in module.functions)
    {
        if (functionName.length == 0)
        {
            continue;
        }

        // Dotted function names ("response.set") install as nested tables
        // ("module.response.set" in script). Host dispatch is unchanged: the
        // closure keeps the full dotted name, which stays the lookup key in
        // the module's function dictionary.
        NSArray<NSString*>* pathComponents =
            [functionName componentsSeparatedByString:@"."];
        BOOL validPath = YES;
        for (NSString* component in pathComponents)
        {
            if (component.length == 0)
            {
                validPath = NO;
                break;
            }
        }
        if (!validPath)
        {
            continue;
        }

        int nestedDepth = 0;
        for (NSUInteger i = 0; i + 1 < pathComponents.count; i++)
        {
            const char* key = pathComponents[i].UTF8String;
            lua_getfield(L, -1, key);
            if (!lua_istable(L, -1))
            {
                lua_pop(L, 1);
                lua_createtable(L, 0, 1);
                lua_pushvalue(L, -1);
                lua_setfield(L, -3, key);
            }
            nestedDepth++;
        }

        lua_pushlightuserdata(L, (__bridge void*)runtime);
        lua_pushstring(L, module.name.UTF8String);
        lua_pushstring(L, functionName.UTF8String);
        lua_pushcclosurek(
            L, RiveScriptHostFunction, "rive.hostFunction", 3, nullptr);
        lua_setfield(L, -2, pathComponents.lastObject.UTF8String);
        lua_pop(L, nestedDepth);
    }

    lua_settable(L, -3);
    lua_pop(L, 1);
}

@implementation RiveScriptModule

- (instancetype)initWithName:(NSString*)name
                   functions:
                       (NSDictionary<NSString*, RiveScriptFunction>*)functions
{
    if (self = [super init])
    {
        _name = [name copy];
        NSMutableDictionary<NSString*, RiveScriptFunction>* copiedFunctions =
            [NSMutableDictionary dictionaryWithCapacity:functions.count];
        for (NSString* functionName in functions)
        {
            copiedFunctions[functionName] = [functions[functionName] copy];
        }
        _functions = [copiedFunctions copy];
    }
    return self;
}

@end

@implementation RiveScriptRuntime
{
    rive::rcp<rive::ScriptingVM> _scriptingVM;
    NSMutableDictionary<NSString*, RiveScriptModule*>* _modulesByName;
}

- (instancetype)init
{
    return [self initWithModules:@[]];
}

- (instancetype)initWithModules:(NSArray<RiveScriptModule*>*)modules
{
    if (self = [super init])
    {
        _modulesByName = [NSMutableDictionary dictionary];
        for (RiveScriptModule* module in modules)
        {
            [self addModule:module];
        }
    }
    return self;
}

- (void)addModule:(RiveScriptModule*)module
{
    if (module.name.length == 0)
    {
        return;
    }
    _modulesByName[module.name] = module;

    if (_scriptingVM != nullptr)
    {
        RiveInstallScriptModule(_scriptingVM->state(), self, module);
    }
}

- (rive::ScriptingVM*)scriptingVMForFactory:(rive::Factory*)factory
{
    if (_scriptingVM == nullptr)
    {
        auto context =
            std::make_unique<rive::CPPRuntimeScriptingContext>(factory);
        _scriptingVM =
            rive::make_rcp<rive::ScriptingVM>(std::move(context));

        for (RiveScriptModule* module in _modulesByName.allValues)
        {
            RiveInstallScriptModule(_scriptingVM->state(), self, module);
        }
    }
    return _scriptingVM.get();
}

- (void)registerUnverifiedScriptsInFile:(rive::File*)file
{
    if (!self.allowsUnverifiedScripts || file == nullptr ||
        _scriptingVM == nullptr ||
        file->scriptingVM() != _scriptingVM.get())
    {
        return;
    }

    // Import already registered every verified script asset. This mirrors
    // that registration for the assets the verified-only gate skipped,
    // because the host explicitly opted in to running its own unsigned
    // content.
    lua_State* state = _scriptingVM->state();
    for (const rive::rcp<rive::FileAsset>& asset : file->assets())
    {
        if (asset == nullptr || !asset->is<rive::ScriptAsset>())
        {
            continue;
        }
        rive::ScriptAsset* scriptAsset = asset->as<rive::ScriptAsset>();
        if (scriptAsset->verified())
        {
            continue;
        }
        rive::Span<uint8_t> bytecode = scriptAsset->moduleBytecode();
        if (bytecode.empty())
        {
            continue;
        }
        std::string moduleName = scriptAsset->moduleName();
        if (scriptAsset->isProtocolScript())
        {
            if (rive::ScriptingVM::registerScript(state,
                                                  moduleName.c_str(),
                                                  bytecode))
            {
                // registerScript leaves the script function on the stack;
                // keep a ref so scripted objects can bind to it, matching
                // the runtime's own registration path.
                int functionRef = 0;
                if (static_cast<lua_Type>(lua_type(state, -1)) ==
                    LUA_TFUNCTION)
                {
                    functionRef = lua_ref(state, -1);
                }
                lua_pop(state, 1);
                scriptAsset->registrationComplete(functionRef);
            }
        }
        else if (rive::ScriptingVM::registerModule(state,
                                                   moduleName.c_str(),
                                                   bytecode))
        {
            scriptAsset->registrationComplete(0);
        }
    }
}

- (id)invokeModuleNamed:(NSString*)moduleName
          functionNamed:(NSString*)functionName
              arguments:(NSArray<id>*)arguments
{
    RiveScriptFunction function =
        _modulesByName[moduleName].functions[functionName];
    if (function == nil)
    {
        return nil;
    }
    return function(arguments);
}

@end
