//
//  FileAssetLoaderAdapter.m
//  RiveRuntime
//
//  Created by Maxwell Talbot on 07/11/2023.
//  Copyright © 2023 Rive. All rights reserved.
//

#import <FileAssetLoaderAdapter.hpp>
#import <RiveFileAssetLoader.h>
#import <RiveFileAsset.h>
#import <RiveFactory.h>
#import <RiveRuntime/RiveRuntime-Swift.h>

NS_ASSUME_NONNULL_BEGIN

rive::FileAssetLoaderAdapter::FileAssetLoaderAdapter(
    RiveFileAssetLoader* myLoader)
{
    loader = myLoader;
}

bool rive::FileAssetLoaderAdapter::loadContents(rive::FileAsset& asset,
                                                rive::Span<const uint8_t> bytes,
                                                rive::Factory* factory)
{
    NSData* data = [NSData dataWithBytes:bytes.data() length:bytes.size()];
    RiveFactory* myFactory = [[RiveFactory alloc] initWithFactory:factory];
#ifdef WITH_RIVE_TEXT
    if (asset.is<rive::FontAsset>())
    {
        // Register the font data with CoreText so UIKit text inputs can use the
        // exact same font face as the Rive file.
        if (bytes.size() > 0)
        {
            std::string key = asset.uniqueName();
            NSString* assetKey = [NSString stringWithUTF8String:key.c_str()];
            if (assetKey != nil)
            {
                (void)[RiveFontAssetRegistry registerFontWithAssetKey:assetKey
                                                                data:data];
            }
        }

        RiveFontAsset* fontAsset = [[RiveFontAsset alloc]
            initWithFileAsset:asset.as<rive::FontAsset>()];
        return [loader loadContentsWithAsset:fontAsset
                                     andData:data
                                  andFactory:myFactory];
    }
#endif
    if (asset.is<rive::ImageAsset>())
    {
        RiveImageAsset* imageAsset = [[RiveImageAsset alloc]
            initWithFileAsset:asset.as<rive::ImageAsset>()];
        return [loader loadContentsWithAsset:imageAsset
                                     andData:data
                                  andFactory:myFactory];
    }
#ifdef WITH_RIVE_AUDIO
    if (asset.is<rive::AudioAsset>())
    {
        RiveAudioAsset* audioAsset = [[RiveAudioAsset alloc]
            initWithFileAsset:asset.as<rive::AudioAsset>()];
        return [loader loadContentsWithAsset:audioAsset
                                     andData:data
                                  andFactory:myFactory];
    }
#endif
    return false;
}

NS_ASSUME_NONNULL_END
