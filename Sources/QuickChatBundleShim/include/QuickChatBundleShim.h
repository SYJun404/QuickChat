#import <Foundation/Foundation.h>

/// Makes the SwiftPM dependencies' `Bundle.module` resolve inside the assembled
/// .app. Call once, before anything touches a dependency's resources (main.swift
/// does it first thing). Idempotent. See QuickChatBundleShim.m for why.
void QuickChatInstallResourceBundleRedirect(void);

/// How many `Bundle(path:)` lookups have been redirected into Contents/Resources.
/// `--smoke-bundles` asserts this, because "didn't crash" alone proves nothing on a
/// machine where the compile-time fallback directory still exists.
NSUInteger QuickChatResourceBundleRedirectCount(void);
