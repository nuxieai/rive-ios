//
//  RiveNuxieScriptingBridge.h
//  RiveRuntime
//
//  Created by Nuxie.
//

#ifndef rive_nuxie_scripting_bridge_h
#define rive_nuxie_scripting_bridge_h

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface RiveNuxieScriptEvent : NSObject

@property(nonatomic, readonly) NSString* name;
@property(nonatomic, readonly) NSDictionary<NSString*, id>* payload;

- (instancetype)init NS_UNAVAILABLE;
- (instancetype)initWithName:(NSString*)name
                     payload:(NSDictionary<NSString*, id>*)payload
    NS_DESIGNATED_INITIALIZER;

@end

@interface RiveNuxieScriptingBridge : NSObject

- (NSArray<RiveNuxieScriptEvent*>*)drainTriggerEvents;

@end

NS_ASSUME_NONNULL_END

#endif /* rive_nuxie_scripting_bridge_h */
