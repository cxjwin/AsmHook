//
//  AsmHook_x86_64.mm
//  AssemblyMac
//
//  Created by smart on 2018/8/13.
//  Copyright © 2018年 smart. All rights reserved.
//

#include "AsmHook_x86_64.h"

#if __x86_64__

#import <objc/runtime.h>
#import <objc/message.h>

#include <pthread.h>
#include <stdint.h> // uint64_t

/*
 -ARM64
 http://infocenter.arm.com/help/topic/com.arm.doc.den0024a/DEN0024A_v8_architecture_PG.pdf (7.2.1 Floating-point) (4.6.1 Floating-point register organization in AArch64)
 use struct and union to describe diagram in the above link, nice!
 -X86
 https://en.wikipedia.org/wiki/X86_calling_conventions
 RDI, RSI, RDX, RCX, R8, R9, XMM0–7
 */
// x86_64 is XMM, arm64 is q
typedef union FPMReg_ {
    __int128_t q;
    struct {
        double d1; // Holds the double (LSB).
        double d2;
    } d;
    struct {
        float f1; // Holds the float (LSB).
        float f2;
        float f3;
        float f4;
    } f;
} FPReg;
// just ref how to backup/restore registers
struct RegState_ {
    union {
        uint64_t arr[7];
        struct {
            uint64_t rax;
            uint64_t rdi;
            uint64_t rsi;
            uint64_t rdx;
            uint64_t rcx;
            uint64_t r8;
            uint64_t r9;
        } regs;
    } general;
    
    uint64_t _; // for align
    
    union {
        FPReg arr[8];
        struct {
            FPReg xmm0;
            FPReg xmm1;
            FPReg xmm2;
            FPReg xmm3;
            FPReg xmm4;
            FPReg xmm5;
            FPReg xmm6;
            FPReg xmm7;
        } regs;
    } floating;
};
typedef struct pa_list_ {
    struct RegState_ *regs; // Registers saved when function is called.
    unsigned char *stack; // Address of current argument.
    int ngrn; // The Next General-purpose Register Number.
    int nsrn; // The Next SIMD and Floating-point Register Number.
} pa_list;


// Shared structures.

typedef struct CallRecord_ {
    __unsafe_unretained id obj;
    SEL _cmd;
    uintptr_t lr;
    struct RegState_ *copyRegState;
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
    if (cs->stack) {
        if (cs->stack->copyRegState) {
            free(cs->stack->copyRegState);
        }
        free(cs->stack);
    }
    free(cs);
}

static inline void pushCallRecord(id obj, uintptr_t lr, SEL _cmd, ThreadCallStack *cs, struct RegState_ *rs) {
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
    
    struct RegState_ *copyRegState = (struct RegState_ *)malloc(sizeof(struct RegState_));
    memcpy(copyRegState, rs, sizeof(struct RegState_));
    newRecord->copyRegState = copyRegState;
    
    newRecord->isWatchHit = 0;
}

static inline CallRecord * popCallRecord(ThreadCallStack *cs) {
    return &cs->stack[cs->index--];
}

struct PointerAndInt_ {
    uintptr_t ptr;
    int i;
};

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

struct PointerAndInt_ preObjc_msgSend(id self, uintptr_t lr, SEL _cmd, struct RegState_ *rs) {
    ThreadCallStack *cs = getThreadCallStack();
    
    IMP origIMP = getOrigIMPFrom(self, _cmd);
    
    if (!cs->isLoggingEnabled) { // Not enabled, just return.
        return (struct PointerAndInt_) {reinterpret_cast<uintptr_t>(origIMP), 0};
    }
    
    pushCallRecord(self, lr, _cmd, cs, rs);
    pa_list args = (pa_list){ rs, ((unsigned char *)rs) + 208, 2, 0 }; // 208 is the offset of rs from the top of the stack.
    
    // TODO: Phrase args
    
    NSLog(@"%s", __func__);
    
    return (struct PointerAndInt_) {reinterpret_cast<uintptr_t>(origIMP), 1};
}

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
    
    NSLog(@"%s", __func__);
    
    return record->lr;
}

__attribute__((__naked__))
id replacementObjc_msgSend(id receiver, SEL op, ...)
{
    // backup registers
    __asm__ volatile(
                     "subq $(16*8+8), %%rsp\n" // +8 for alignment
                     "movdqa %%xmm0, (%%rsp)\n"
                     "movdqa %%xmm1, 0x10(%%rsp)\n"
                     "movdqa %%xmm2, 0x20(%%rsp)\n"
                     "movdqa %%xmm3, 0x30(%%rsp)\n"
                     "movdqa %%xmm4, 0x40(%%rsp)\n"
                     "movdqa %%xmm5, 0x50(%%rsp)\n"
                     "movdqa %%xmm6, 0x60(%%rsp)\n"
                     "movdqa %%xmm7, 0x70(%%rsp)\n"
                     "pushq %%rax\n" // stack align
                     "pushq %%r9\n" // might be xmm parameter count
                     "pushq %%r8\n"
                     "pushq %%rcx\n"
                     "pushq %%rdx\n"
                     "pushq %%rsi\n"
                     "pushq %%rdi\n"
                     "pushq %%rax\n"
                     // origin rsp, contain `ret address`, how to use leaq, always wrong.
                     "movq %%rsp, %%rax\n"
                     "addq $(16*8+8+8+7*8), %%rax\n"
                     :
                     :
                     :);
    
    // prepare args for func
    __asm__ volatile(
                     "movq %%rsi, %%rdx\n" // arg3
                     "movq (%%rax), %%rsi\n" // arg2
                     "movq %%rsp, %%rcx\n" // arg4
                     "callq __Z15preObjc_msgSendP11objc_objectmP13objc_selectorP9RegState_\n"
                     :
                     :
                     :);
    
    // get value from `PointerAndInt_`
    __asm__ volatile(
                     "movq %%rax, %%r10\n"
                     "movq %%rdx, %%r11\n" ::
                     :);
    
    // restore registers
    __asm__ volatile(
                     "popq %%rax\n"
                     "popq %%rdi\n"
                     "popq %%rsi\n"
                     "popq %%rdx\n"
                     "popq %%rcx\n"
                     "popq %%r8\n"
                     "popq %%r9\n"
                     "popq %%rax\n" // stack align
                     "movdqa (%%rsp), %%xmm0\n"
                     "movdqa 0x10(%%rsp), %%xmm1\n"
                     "movdqa 0x20(%%rsp), %%xmm2\n"
                     "movdqa 0x30(%%rsp), %%xmm3\n"
                     "movdqa 0x40(%%rsp), %%xmm4\n"
                     "movdqa 0x50(%%rsp), %%xmm5\n"
                     "movdqa 0x60(%%rsp), %%xmm6\n"
                     "movdqa 0x70(%%rsp), %%xmm7\n"
                     "addq $(16*8+8), %%rsp\n"
                     :
                     :
                     :);
    
    // go to the original objc_msgSend
    __asm__ volatile(
                     "cmpq $1, %%r11\n"
                     "jne Lthroughx\n"
                     // trick to jmp
                     "jmp NextInstruction\n"
                     "Begin:\n"
                     "popq %%r11\n"
                     "movq %%r11, (%%rsp)\n"
                     "jmpq *%%r10\n"
                     "NextInstruction:\n"
                     "call Begin"
                     :
                     :
                     :);
    
    //-----------------------------------------------------------------------------
    // after objc_msgSend we parse the result.
    // backup registers
    __asm__ volatile(
                     "push %%r11\n"
                     "push %%rbp\n"
                     "mov %%rsp, %%rbp\n"
                     "sub $0x80+8,  %%rsp\n"
                     "movdqa %%xmm0, -0x80(%%rbp)\n"
                     "push %%rax\n"
                     "movdqa %%xmm1, -0x70(%%rbp)\n"
                     "push %%rdi\n"
                     "movdqa %%xmm2, -0x60(%%rbp)\n"
                     "push %%rsi\n"
                     "movdqa %%xmm3, -0x50(%%rbp)\n"
                     "push %%rdx\n"
                     "movdqa %%xmm4, -0x40(%%rbp)\n"
                     "push %%rcx\n"
                     "movdqa %%xmm5, -0x30(%%rbp)\n"
                     "push %%r8\n"
                     "movdqa %%xmm6, -0x20(%%rbp)\n"
                     "push %%r9\n"
                     "movdqa %%xmm7, -0x10(%%rbp)\n"
                     :
                     :
                     :);
    
    // prepare args for func
    __asm__ volatile(
                     "callq __Z16postObjc_msgSendv\n"
                     "movq %%rax, %%r10\n"
                     :
                     :
                     :);
    
    // restore registers
    __asm__ volatile(
                     "movq %%rax, %%r11\n"
                     "movdqa -0x80(%%rbp), %%xmm0\n"
                     "pop %%r9\n"
                     "movdqa -0x70(%%rbp), %%xmm1\n"
                     "pop %%r8\n"
                     "movdqa -0x60(%%rbp), %%xmm2\n"
                     "pop %%rcx\n"
                     "movdqa -0x50(%%rbp), %%xmm3\n"
                     "pop %%rdx\n"
                     "movdqa -0x40(%%rbp), %%xmm4\n"
                     "pop %%rsi\n"
                     "movdqa -0x30(%%rbp), %%xmm5\n"
                     "pop %%rdi\n"
                     "movdqa -0x20(%%rbp), %%xmm6\n"
                     "pop %%rax\n"
                     "movdqa -0x10(%%rbp), %%xmm7\n"
                     "leave\n"
                     // return original objc_msgSend result
                     "movq %%r10, (%%rsp)\n"
                     "ret\n"
                     :
                     :
                     :);
    
    // go to the original objc_msgSend
    __asm__ volatile(
                     "Lthroughx:\n"
                     "jmpq *%%r10"
                     :
                     :
                     :);
}

void create_pthread_key() {
    pthread_key_create(&threadKey, &destroyThreadCallStack);
}

#endif

