//
//  AsmHook.h
//  AsmHook
//
//  Created by smart on 2018/8/13.
//  Copyright © 2018年 smart. All rights reserved.
//

#import <Foundation/Foundation.h>

//! Project version number for AsmHook.
FOUNDATION_EXPORT double AsmHookVersionNumber;

//! Project version string for AsmHook.
FOUNDATION_EXPORT const unsigned char AsmHookVersionString[];

// In this header, you should import all the public headers of your framework using statements like #import <AsmHook/PublicHeader.h>

#if __x86_64__
#import "AsmHook_x86_64.h"
#endif

#if __arm64__
#import "AsmHook_arm64.h"
#endif

#ifdef __arm__
#import "AsmHook_arm.h"
#endif

