//
//  AsmHook_x86_64.h
//  AssemblyMac
//
//  Created by smart on 2018/8/13.
//  Copyright © 2018年 smart. All rights reserved.
//

#import <Foundation/Foundation.h>

#if __x86_64__

void create_pthread_key();

id replacementObjc_msgSend(id receiver, SEL op, ...);

#endif

