// void uuss_call_swift_method(void *fn, void *swiftSelf, void *arg0);
//
// Swift 实例方法调用约定（arm64）：self 放 x20（swiftself），第一个参数放 x0。
// 这里用独立汇编函数完成寄存器搬运，避免内联汇编被编译器重排/占用寄存器。
// x20 是 C 的 callee-saved 寄存器，调用前后自行保存恢复。

    .text
    .align 2
    .globl _uuss_call_swift_method
_uuss_call_swift_method:
    stp     x29, x30, [sp, #-32]!
    mov     x29, sp
    stp     x20, x21, [sp, #16]
    mov     x16, x0
    mov     x20, x1
    mov     x0, x2
    blr     x16
    ldp     x20, x21, [sp, #16]
    ldp     x29, x30, [sp], #32
    ret

// void uuss_call_key_sink(void *fn, void *sink, void *array, uint8_t action, void *type, void *wtable);
//
// KeyboardEventSink 的协议见证方法：swiftself=x20，x0=Array<Int>，w1=action，
// x2=实例类型元数据，x3=协议见证表。
    .align 2
    .globl _uuss_call_key_sink
_uuss_call_key_sink:
    stp     x29, x30, [sp, #-32]!
    mov     x29, sp
    stp     x20, x21, [sp, #16]
    mov     x16, x0
    mov     x20, x1
    mov     x0, x2
    mov     w1, w3
    mov     x2, x4
    mov     x3, x5
    blr     x16
    ldp     x20, x21, [sp, #16]
    ldp     x29, x30, [sp], #32
    ret

// C(fn=x0, self=x1, a=d0, b=d1) -> Swift(self=x20, a=d0, b=d1).
    .align 2
    .globl _uuss_call_swift_geometry
_uuss_call_swift_geometry:
    stp     x29, x30, [sp, #-32]!
    mov     x29, sp
    stp     x20, x21, [sp, #16]
    mov     x16, x0
    mov     x20, x1
    blr     x16
    ldp     x20, x21, [sp, #16]
    ldp     x29, x30, [sp], #32
    ret
