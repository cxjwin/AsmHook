//
//  AsmHook_arm64.m
//  AssemblyMac
//
//  Created by smart on 2018/8/13.
//  Copyright © 2018年 smart. All rights reserved.
//

#import "AsmHook_arm64.h"

#if __arm64__

#import <objc/runtime.h>
#import <objc/message.h>

#include <pthread.h>
#include <cstdio>

#import "ARM64Types.h"

// Shared structures.
typedef struct CallRecord_ {
    __unsafe_unretained id obj;
    SEL _cmd;
    uintptr_t lr;
    int prevHitIndex; // Only used if isWatchHit is set.
    char isWatchHit;
} CallRecord;

typedef struct ThreadCallStack_ {
    FILE *file;
    char *spacesStr;
    CallRecord *stack;
    int allocatedLength;
    int index;
    int numWatchHits;
    int lastPrintedIndex;
    int lastHitIndex;
    char isLoggingEnabled;
    char isCompleteLoggingEnabled;
} ThreadCallStack;

static inline ThreadCallStack * getThreadCallStack();

// Optional - comment this out if you want to log on ALL threads (laggy due to rw-locks).
#define MAX_PATH_LENGTH 1024
#define DEFAULT_CALLSTACK_DEPTH 128
#define CALLSTACK_DEPTH_INCREMENT 64
#define DEFAULT_MAX_RELATIVE_RECURSIVE_DESCENT_DEPTH 64

static pthread_key_t threadKey;

static inline ThreadCallStack * getThreadCallStack() {
    ThreadCallStack *cs = (ThreadCallStack *)pthread_getspecific(threadKey);
    if (cs == NULL) {
        cs = (ThreadCallStack *)malloc(sizeof(ThreadCallStack));
        cs->file = NULL;
        cs->isLoggingEnabled = 1;
        cs->isCompleteLoggingEnabled = 0;
        cs->spacesStr = (char *)malloc(DEFAULT_CALLSTACK_DEPTH + 1);
        memset(cs->spacesStr, ' ', DEFAULT_CALLSTACK_DEPTH);
        cs->spacesStr[DEFAULT_CALLSTACK_DEPTH] = '\0';
        cs->stack = (CallRecord *)calloc(DEFAULT_CALLSTACK_DEPTH, sizeof(CallRecord));
        cs->allocatedLength = DEFAULT_CALLSTACK_DEPTH;
        cs->index = cs->lastPrintedIndex = cs->lastHitIndex = -1;
        cs->numWatchHits = 0;
        pthread_setspecific(threadKey, cs);
    }
    return cs;
}

static void destroyThreadCallStack(void *ptr) {
    ThreadCallStack *cs = (ThreadCallStack *)ptr;
    if (cs->file) {
        fclose(cs->file);
    }
    free(cs->spacesStr);
    free(cs->stack);
    free(cs);
}

static inline void pushCallRecord(id obj, uintptr_t lr, SEL _cmd, ThreadCallStack *cs) {
    int nextIndex = (++cs->index);
    if (nextIndex >= cs->allocatedLength) {
        cs->allocatedLength += CALLSTACK_DEPTH_INCREMENT;
        cs->stack = (CallRecord *)realloc(cs->stack, cs->allocatedLength * sizeof(CallRecord));
        cs->spacesStr = (char *)realloc(cs->spacesStr, cs->allocatedLength + 1);
        memset(cs->spacesStr, ' ', cs->allocatedLength);
        cs->spacesStr[cs->allocatedLength] = '\0';
    }
    CallRecord *newRecord = &cs->stack[nextIndex];
    newRecord->obj = obj;
    newRecord->_cmd = _cmd;
    newRecord->lr = lr;
    newRecord->isWatchHit = 0;
}

static inline CallRecord * popCallRecord(ThreadCallStack *cs) {
    return &cs->stack[cs->index--];
}


struct PointerAndInt_ {
    uintptr_t ptr;
    int i;
};

#define arg_list pa_list

// Called in our replacementObjc_msgSend after calling the original objc_msgSend.
// This returns the lr in r0/x0.
uintptr_t postObjc_msgSend() {
    ThreadCallStack *cs = (ThreadCallStack *)pthread_getspecific(threadKey);
    CallRecord *record = popCallRecord(cs);
    if (record->isWatchHit) {
        --cs->numWatchHits;
        cs->lastHitIndex = record->prevHitIndex;
    }
    if (cs->lastPrintedIndex > cs->index) {
        cs->lastPrintedIndex = cs->index;
    }
    return record->lr;
}

IMP getOrigIMPFrom(id receiver, SEL sel) {
    NSString *selName = NSStringFromSelector(sel);
    NSString *replaceSelName = [@"__hook__" stringByAppendingString:selName];
    
    SEL replaceSel = NSSelectorFromString(replaceSelName);
    IMP imp = NULL;
    if ([receiver isKindOfClass:[receiver class]]) {
        Method method = class_getInstanceMethod([receiver class], replaceSel);
        imp = method_getImplementation(method);
    } else {
        Method method = class_getClassMethod([receiver class], replaceSel);
        imp = method_getImplementation(method);
    }
    
    return imp;
}

// arm64 hooking magic.
// Called in our replacementObjc_msgSend before calling the original objc_msgSend.
// This pushes a CallRecord to our stack, most importantly saving the lr.
// Returns orig_objc_msgSend in x0 and isLoggingEnabled in x1.
struct PointerAndInt_ preObjc_msgSend(id self, uintptr_t lr, SEL _cmd, struct RegState_ *rs) {
    ThreadCallStack *cs = getThreadCallStack();
    
    IMP origIMP = getOrigIMPFrom(self, _cmd);
    
    if (!cs->isLoggingEnabled) { // Not enabled, just return.
        return (struct PointerAndInt_) {reinterpret_cast<uintptr_t>(origIMP), 0};
    }
    pushCallRecord(self, lr, _cmd, cs);
    pa_list args = (pa_list){ rs, ((unsigned char *)rs) + 208, 2, 0 }; // 208 is the offset of rs from the top of the stack.
    
    // TODO: Phrase args

    return (struct PointerAndInt_) {reinterpret_cast<uintptr_t>(origIMP), 1};
}

// Our replacement objc_msgSend (arm64).
//
// See:
// https://blog.nelhage.com/2010/10/amd64-and-va_arg/
// http://infocenter.arm.com/help/topic/com.arm.doc.ihi0055b/IHI0055B_aapcs64.pdf
// https://developer.apple.com/library/ios/documentation/Xcode/Conceptual/iPhoneOSABIReference/Articles/ARM64FunctionCallingConventions.html
__attribute__((__naked__))
static void replacementObjc_msgSend() {
    __asm__ volatile (
                      // push {q0-q7}
                      "stp q6, q7, [sp, #-32]!\n"
                      "stp q4, q5, [sp, #-32]!\n"
                      "stp q2, q3, [sp, #-32]!\n"
                      "stp q0, q1, [sp, #-32]!\n"
                      // push {x0-x8, lr}
                      "stp x8, lr, [sp, #-16]!\n"
                      "stp x6, x7, [sp, #-16]!\n"
                      "stp x4, x5, [sp, #-16]!\n"
                      "stp x2, x3, [sp, #-16]!\n"
                      "stp x0, x1, [sp, #-16]!\n"
                      // Swap args around for call.
                      "mov x2, x1\n"
                      "mov x1, lr\n"
                      "mov x3, sp\n"
                      // Call preObjc_msgSend which puts orig_objc_msgSend into x0 and isLoggingEnabled into x1.
                      "bl __Z15preObjc_msgSendP11objc_objectmP13objc_selectorP9RegState_\n"
                      "mov x9, x0\n"
                      "mov x10, x1\n"
                      "tst x10, x10\n" // Set condition code for later branch.
                      // pop {x0-x8, lr}
                      "ldp x0, x1, [sp], #16\n"
                      "ldp x2, x3, [sp], #16\n"
                      "ldp x4, x5, [sp], #16\n"
                      "ldp x6, x7, [sp], #16\n"
                      "ldp x8, lr, [sp], #16\n"
                      // pop {q0-q7}
                      "ldp q0, q1, [sp], #32\n"
                      "ldp q2, q3, [sp], #32\n"
                      "ldp q4, q5, [sp], #32\n"
                      "ldp q6, q7, [sp], #32\n"
                      // Make sure it's enabled.
                      "b.eq Lpassthrough\n"
                      // Call through to the original objc_msgSend.
                      "blr x9\n"
                      // push {x0-x9}
                      "stp x0, x1, [sp, #-16]!\n"
                      "stp x2, x3, [sp, #-16]!\n"
                      "stp x4, x5, [sp, #-16]!\n"
                      "stp x6, x7, [sp, #-16]!\n"
                      "stp x8, x9, [sp, #-16]!\n" // Not sure if needed - push for alignment.
                      // push {q0-q7}
                      "stp q0, q1, [sp, #-32]!\n"
                      "stp q2, q3, [sp, #-32]!\n"
                      "stp q4, q5, [sp, #-32]!\n"
                      "stp q6, q7, [sp, #-32]!\n"
                      // Call our postObjc_msgSend hook.
                      "bl __Z16postObjc_msgSendv\n"
                      "mov lr, x0\n"
                      // pop {q0-q7}
                      "ldp q6, q7, [sp], #32\n"
                      "ldp q4, q5, [sp], #32\n"
                      "ldp q2, q3, [sp], #32\n"
                      "ldp q0, q1, [sp], #32\n"
                      // pop {x0-x9}
                      "ldp x8, x9, [sp], #16\n"
                      "ldp x6, x7, [sp], #16\n"
                      "ldp x4, x5, [sp], #16\n"
                      "ldp x2, x3, [sp], #16\n"
                      "ldp x0, x1, [sp], #16\n"
                      "ret\n"
                      
                      // Pass through to original objc_msgSend.
                      "Lpassthrough:\n"
                      "br x9"
                      );
}

void create_pthread_key() {
    pthread_key_create(&threadKey, &destroyThreadCallStack);
}

#endif
