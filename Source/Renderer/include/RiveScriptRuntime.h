//
//  RiveScriptRuntime.h
//  RiveRuntime
//

#ifndef rive_script_runtime_h
#define rive_script_runtime_h

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

typedef id _Nullable (^RiveScriptFunction)(NSArray<id>* arguments);

/// A host-provided Lua module that can be required by Rive scripts.
///
/// This is intentionally generic: callers choose the module name and
/// functions, and Rive only handles value bridging and script registration.
@interface RiveScriptModule : NSObject

@property(nonatomic, readonly) NSString* name;
@property(nonatomic, readonly)
    NSDictionary<NSString*, RiveScriptFunction>* functions;

- (instancetype)init NS_UNAVAILABLE;
- (instancetype)initWithName:(NSString*)name
                   functions:
                       (NSDictionary<NSString*, RiveScriptFunction>*)functions
    NS_DESIGNATED_INITIALIZER;

@end

/// Runtime state used while importing a file with host-provided script modules.
///
/// Create a runtime, add any modules the host wants scripts to require, then
/// pass it to a RiveFile initializer that accepts scriptRuntime.
@interface RiveScriptRuntime : NSObject

- (instancetype)initWithModules:(NSArray<RiveScriptModule*>*)modules;
- (void)addModule:(RiveScriptModule*)module NS_SWIFT_NAME(add(_:));

@end

NS_ASSUME_NONNULL_END

#endif /* rive_script_runtime_h */
