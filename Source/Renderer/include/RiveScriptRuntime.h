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

/// When YES, script assets whose content signature could not be verified are
/// still registered with the scripting VM after a file imports. Defaults to
/// NO, which preserves the runtime's signed-content requirement. Only enable
/// this for files whose scripts the host application itself authored or
/// otherwise trusts; unverified bytecode runs with the same privileges as
/// verified bytecode.
@property(nonatomic) BOOL allowsUnverifiedScripts;

- (instancetype)initWithModules:(NSArray<RiveScriptModule*>*)modules;
- (void)addModule:(RiveScriptModule*)module NS_SWIFT_NAME(add(_:));

@end

NS_ASSUME_NONNULL_END

#endif /* rive_script_runtime_h */
