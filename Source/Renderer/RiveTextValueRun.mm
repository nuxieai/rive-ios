//
//  RiveTextValueRun.m
//
//
//  Created by Zach Plata on 7/27/23.
//

#import <Rive.h>
#import <RivePrivateHeaders.h>

#ifdef WITH_RIVE_TEXT
#include "rive/text/text.hpp"
#include "rive/text/text_style_paint.hpp"
#include "rive/shapes/paint/fill.hpp"
#include "rive/shapes/paint/solid_color.hpp"
#endif

/*
 * RiveTextValueRun
 */
@implementation RiveTextValueRun
{
    const rive::TextValueRun*
        instance; // note: we do NOT own this, so don't delete it
}

- (const rive::TextValueRun*)getInstance
{
    return instance;
}

// Creates a new RiveTextValueRun from a cpp TextValueRun
- (instancetype)initWithTextValueRun:(const rive::TextValueRun*)textRun
{
    if (self = [super init])
    {
        instance = textRun;
        return self;
    }
    else
    {
        return nil;
    }
}

- (void)setText:(NSString*)textValue
{
    std::string stdName = std::string([textValue UTF8String]);
    ((rive::TextValueRun*)[self getInstance])->text(stdName);
}

- (NSString*)text
{
    std::string str = ((const rive::TextValueRun*)instance)->text();
    return [NSString stringWithCString:str.c_str()
                              encoding:[NSString defaultCStringEncoding]];
}

- (CGRect)localBounds
{
#ifdef WITH_RIVE_TEXT
    auto run = (const rive::TextValueRun*)instance;
    if (run == nullptr)
    {
        return CGRectZero;
    }
    auto text = run->textComponent();
    if (text == nullptr)
    {
        return CGRectZero;
    }

    rive::AABB aabb = text->localBounds();
    return CGRectMake(aabb.minX, aabb.minY, aabb.width(), aabb.height());
#else
    return CGRectZero;
#endif
}

- (CGAffineTransform)rootShapeWorldTransform
{
#ifdef WITH_RIVE_TEXT
    auto run = (const rive::TextValueRun*)instance;
    if (run == nullptr)
    {
        return CGAffineTransformIdentity;
    }
    auto text = run->textComponent();
    if (text == nullptr)
    {
        return CGAffineTransformIdentity;
    }
    auto artboard = text->artboard();
    if (artboard == nullptr)
    {
        return CGAffineTransformIdentity;
    }

    // Use the Text component's world transform (not shapeWorldTransform).
    // `shapeWorldTransform` includes internal glyph-layout transforms (origin,
    // vertical align, overflow-fit scaling) which would distort the component
    // bounds returned by `Text::localBounds()`.
    const rive::Mat2D& world = text->worldTransform();
    rive::Vec2D p0 = world * rive::Vec2D(0, 0);
    rive::Vec2D p1 = world * rive::Vec2D(1, 0);
    rive::Vec2D p2 = world * rive::Vec2D(0, 1);

    rive::Vec2D r0 = artboard->rootTransform(p0);
    rive::Vec2D r1 = artboard->rootTransform(p1);
    rive::Vec2D r2 = artboard->rootTransform(p2);

    rive::Mat2D root;
    root[0] = r1.x - r0.x;
    root[1] = r1.y - r0.y;
    root[2] = r2.x - r0.x;
    root[3] = r2.y - r0.y;
    root[4] = r0.x;
    root[5] = r0.y;

    return CGAffineTransformMake(
        root[0], root[1], root[2], root[3], root[4], root[5]);
#else
    return CGAffineTransformIdentity;
#endif
}

- (CGFloat)fontSize
{
#ifdef WITH_RIVE_TEXT
    auto run = (rive::TextValueRun*)instance;
    if (run == nullptr || run->style() == nullptr)
    {
        return 0;
    }
    return run->style()->fontSize();
#else
    return 0;
#endif
}

- (CGFloat)lineHeight
{
#ifdef WITH_RIVE_TEXT
    auto run = (rive::TextValueRun*)instance;
    if (run == nullptr || run->style() == nullptr)
    {
        return 0;
    }
    return run->style()->lineHeight();
#else
    return 0;
#endif
}

- (CGFloat)letterSpacing
{
#ifdef WITH_RIVE_TEXT
    auto run = (rive::TextValueRun*)instance;
    if (run == nullptr || run->style() == nullptr)
    {
        return 0;
    }
    return run->style()->letterSpacing();
#else
    return 0;
#endif
}

- (NSString*)fontAssetKey
{
#ifdef WITH_RIVE_TEXT
    auto run = (rive::TextValueRun*)instance;
    if (run == nullptr || run->style() == nullptr)
    {
        return @"";
    }
    auto asset = run->style()->asset();
    if (asset == nullptr)
    {
        return @"";
    }
    std::string key = asset->uniqueName();
    return [NSString stringWithUTF8String:key.c_str()];
#else
    return @"";
#endif
}

- (CGFloat)fontWeight
{
#ifdef WITH_RIVE_TEXT
    auto run = (rive::TextValueRun*)instance;
    if (run == nullptr || run->style() == nullptr)
    {
        return 0;
    }
    auto font = run->style()->font();
    if (font == nullptr)
    {
        return 0;
    }
    return (CGFloat)font->getWeight();
#else
    return 0;
#endif
}

- (BOOL)fontIsItalic
{
#ifdef WITH_RIVE_TEXT
    auto run = (rive::TextValueRun*)instance;
    if (run == nullptr || run->style() == nullptr)
    {
        return NO;
    }
    auto font = run->style()->font();
    if (font == nullptr)
    {
        return NO;
    }
    return font->isItalic();
#else
    return NO;
#endif
}

- (NSInteger)textAlign
{
#ifdef WITH_RIVE_TEXT
    auto run = (const rive::TextValueRun*)instance;
    if (run == nullptr)
    {
        return -1;
    }
    auto text = run->textComponent();
    if (text == nullptr)
    {
        return -1;
    }
    return (NSInteger)text->align();
#else
    return -1;
#endif
}

- (NSInteger)textWrap
{
#ifdef WITH_RIVE_TEXT
    auto run = (const rive::TextValueRun*)instance;
    if (run == nullptr)
    {
        return -1;
    }
    auto text = run->textComponent();
    if (text == nullptr)
    {
        return -1;
    }
    return (NSInteger)text->wrap();
#else
    return -1;
#endif
}

- (NSInteger)textOverflow
{
#ifdef WITH_RIVE_TEXT
    auto run = (const rive::TextValueRun*)instance;
    if (run == nullptr)
    {
        return -1;
    }
    auto text = run->textComponent();
    if (text == nullptr)
    {
        return -1;
    }
    return (NSInteger)text->overflow();
#else
    return -1;
#endif
}

- (NSInteger)textSizing
{
#ifdef WITH_RIVE_TEXT
    auto run = (const rive::TextValueRun*)instance;
    if (run == nullptr)
    {
        return -1;
    }
    auto text = run->textComponent();
    if (text == nullptr)
    {
        return -1;
    }
    return (NSInteger)text->effectiveSizing();
#else
    return -1;
#endif
}

- (uint32_t)solidFillColorARGB
{
#ifdef WITH_RIVE_TEXT
    auto run = (rive::TextValueRun*)instance;
    if (run == nullptr || run->style() == nullptr)
    {
        return 0;
    }
    auto style = run->style();
    for (auto child : style->children())
    {
        if (child == nullptr)
        {
            continue;
        }
        if (!child->is<rive::Fill>())
        {
            continue;
        }
        auto fill = child->as<rive::Fill>();
        if (!fill->isVisible())
        {
            continue;
        }
        auto paint = fill->paint();
        if (paint == nullptr)
        {
            continue;
        }
        if (paint->is<rive::SolidColor>())
        {
            auto solid = paint->as<rive::SolidColor>();
            return (uint32_t)solid->colorValue();
        }
    }
#endif
    return 0;
}

@end
