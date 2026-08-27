#import "CExceptionCatcher.h"

#include <cxxabi.h>
#include <objc/runtime.h>
#include <typeinfo>

// ObjC++ with a C++ catch-all rather than `@catch (NSException *)`, and the
// distinction is load-bearing: clang picks the personality routine per function
// from the handler's type, so a handler naming an ObjC type emits
// `___objc_personality_v0`. That is a fourth routine beside C++, Rust and the
// one ThreadSanitizer injects, and Apple's compact unwind format encodes three
// per image (`UNWIND_PERSONALITY_MASK` is a two bit index, 0 means none), so the
// sanitizer build stops linking. `catch (...)` keeps this function on the C++
// personality, which C++ already occupies, and the count stays at three.
//
// Renaming the file alone does nothing: `.mm` with `@catch` still emits the ObjC
// personality. So does a C++ `catch (NSException *)`. Only the catch-all avoids
// it, and only as long as nothing below reintroduces an ObjC handler.
//
// Catching still works because the modern ObjC runtime implements a raise on top
// of the C++ ABI, so the NSException travels as a C++ exception and is recovered
// through the libc++abi current-exception API.
NSError *_Nullable audiotap_tryBlock(NS_NOESCAPE void (^block)(void)) {
    try {
        block();
        return nil;
    } catch (...) {
        NSString *name = @"UnknownException";
        NSString *desc = name;
        const std::type_info *type = __cxxabiv1::__cxa_current_exception_type();
        void *primary = __cxxabiv1::__cxa_current_primary_exception();
        if (type != nullptr) {
            // An ObjC exception's typeinfo name is the plain class name
            // ("NSException"); a C++ one is mangled and will not resolve to a
            // class. Only read the thrown storage as an object once the type is
            // known to be an NSException subclass.
            Class cls = objc_getClass(type->name());
            if (primary != nullptr && cls != Nil
                && [cls isSubclassOfClass:[NSException class]]) {
                NSException *exception = *(__unsafe_unretained NSException **)primary;
                name = exception.name;
                desc = exception.reason ?: exception.name;
            } else {
                // A C++ exception escaping the block. The old `@catch` let it
                // through to terminate; reporting it is the better outcome for a
                // wrapper whose whole purpose is to keep a raise from killing
                // the process.
                desc = [NSString stringWithUTF8String:type->name()] ?: name;
            }
        }
        NSError *error = [NSError errorWithDomain:@"AudioTapLib.NSException"
                                             code:1
                                         userInfo:@{
                                             NSLocalizedDescriptionKey: desc,
                                             @"exceptionName": name,
                                         }];
        if (primary != nullptr) {
            // __cxa_current_primary_exception incremented the refcount.
            __cxxabiv1::__cxa_decrement_exception_refcount(primary);
        }
        return error;
    }
}
