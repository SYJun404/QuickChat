// Why this exists: `swift build` generates each resource-bearing dependency a
// `Bundle.module` accessor that looks in exactly two places —
//
//     Bundle.main.bundleURL/<Name>.bundle        (the .app ROOT, not Contents/Resources)
//     <absolute build-products dir>/<Name>.bundle (a compile-time fallback)
//
// and traps otherwise. Nothing ever looks in Contents/Resources, which is where
// build.sh puts the bundles and the only place codesign accepts them ("unsealed
// contents present in the bundle root" for anything else). Every build up to 0.1.2
// therefore ran on the FALLBACK — the checkout's own .build/ — and shipped that
// path inside the DMG, so on any other Mac the first hotkey recorder (KeyboardShortcuts
// localizations) or LaTeX message (SwiftMath fonts) was a fatalError. release.sh
// moving the build to /tmp made it reproduce here too, once /tmp was cleaned.
//
// The accessor's first candidate is `Bundle(path:)` on the root path, so the fix is
// to answer THAT lookup: -[NSBundle initWithPath:] is swizzled to redirect
// "<app>/<Name>.bundle" — when it does not exist and the Contents/Resources copy
// does — to the copy. Nothing else matches the predicate, so no other bundle lookup
// changes. Objective-C rather than Swift because initWithPath: is in the init
// method family (consumes self, returns +1); a Swift @objc func cannot declare
// those conventions and swizzling it in leaks or over-releases.

#import "QuickChatBundleShim.h"
#import <objc/runtime.h>
#import <stdatomic.h>

static NSString *appRoot;                      // Bundle.main.bundlePath, captured at install
static _Atomic NSUInteger redirectCount;

static NSString *QuickChatRedirectedPath(NSString *path) {
    if (appRoot == nil || path == nil) return path;
    if (![path.pathExtension isEqualToString:@"bundle"]) return path;
    NSString *standardized = path.stringByStandardizingPath;
    if (![standardized.stringByDeletingLastPathComponent isEqualToString:appRoot]) return path;
    NSFileManager *fm = NSFileManager.defaultManager;
    if ([fm fileExistsAtPath:standardized]) return path;   // a real root-level bundle wins
    NSString *inResources = [[appRoot stringByAppendingPathComponent:@"Contents/Resources"]
                             stringByAppendingPathComponent:standardized.lastPathComponent];
    if (![fm fileExistsAtPath:inResources]) return path;   // let the accessor's fallback try
    atomic_fetch_add(&redirectCount, 1);
    return inResources;
}

@interface NSBundle (QuickChatResourceBundleRedirect)
// Declared as init-family so ARC applies initWithPath:'s ownership rules to the
// swapped-in implementation as well.
- (instancetype)popchat_initWithPath:(NSString *)path __attribute__((objc_method_family(init)));
@end

@implementation NSBundle (QuickChatResourceBundleRedirect)
- (instancetype)popchat_initWithPath:(NSString *)path {
    // After the exchange this selector carries Foundation's original -initWithPath:.
    return [self popchat_initWithPath:QuickChatRedirectedPath(path)];
}
@end

void QuickChatInstallResourceBundleRedirect(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        // Captured BEFORE the swizzle: creating the main bundle must not recurse
        // into the redirect.
        appRoot = NSBundle.mainBundle.bundlePath.stringByStandardizingPath;
        Method original = class_getInstanceMethod(NSBundle.class, @selector(initWithPath:));
        Method replacement = class_getInstanceMethod(NSBundle.class, @selector(popchat_initWithPath:));
        if (original && replacement) method_exchangeImplementations(original, replacement);
    });
}

NSUInteger QuickChatResourceBundleRedirectCount(void) {
    return atomic_load(&redirectCount);
}
