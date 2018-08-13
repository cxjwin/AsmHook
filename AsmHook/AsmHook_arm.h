//
//  AsmHook_arm.h
//  AssemblyMac
//
//  Created by smart on 2018/8/13.
//  Copyright © 2018年 smart. All rights reserved.
//

#import <Foundation/Foundation.h>

#ifdef __arm__

void create_pthread_key();

id replacementObjc_msgSend(id receiver, SEL op, ...);

#endif
