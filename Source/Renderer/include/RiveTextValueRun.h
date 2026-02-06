//
//  RiveTextValueRun.h
//  RiveRuntime
//
//  Created by Zach Plata on 7/27/23.
//  Copyright © 2023 Rive. All rights reserved.
//

#ifndef rive_text_value_run_h
#define rive_text_value_run_h

#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>

NS_ASSUME_NONNULL_BEGIN

/*
 * TextValueRun
 */
@interface RiveTextValueRun : NSObject
- (NSString*)text;
- (void)setText:(NSString*)newValue;

/// Returns the local bounds of the owning `Text` component (text-local space).
/// Returns `CGRectZero` if the owning text component cannot be resolved.
- (CGRect)localBounds;

/// Returns an affine transform that maps from text-local coordinates into the
/// root artboard's coordinate space (includes nested artboard transforms).
/// Returns `CGAffineTransformIdentity` if unavailable.
- (CGAffineTransform)rootShapeWorldTransform;

/// Style information (best-effort). Values are in artboard units.
- (CGFloat)fontSize;
- (CGFloat)lineHeight;
- (CGFloat)letterSpacing;
/// A stable key for the font asset used by this run (best-effort).
/// Currently maps to Rive runtime `FileAsset::uniqueName()` for the referenced
/// font asset, or an empty string if unavailable.
- (NSString*)fontAssetKey;
/// Best-effort font weight in the OpenType range [1, 1000]. Returns 0 if unavailable.
- (CGFloat)fontWeight;
/// Best-effort italic flag. Returns NO if unavailable.
- (BOOL)fontIsItalic;

/// Text component layout information (best-effort). Values mirror Rive enums.
- (NSInteger)textAlign;
- (NSInteger)textWrap;
- (NSInteger)textOverflow;
/// Text sizing mode (best-effort). Values mirror rive::TextSizing:
/// 0 = autoWidth, 1 = autoHeight, 2 = fixed. Returns -1 if unavailable.
- (NSInteger)textSizing;

/// Best-effort solid fill color as ARGB (0xAARRGGBB). Returns 0 if unavailable.
- (uint32_t)solidFillColorARGB;
@end

NS_ASSUME_NONNULL_END

#endif /* rive_text_value_run_h */
