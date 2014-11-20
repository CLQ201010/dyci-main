//
//  SFDynamicCodeInjection
//  Dynamic Code Injection
//
//  Created by Paul Taykalo on 10/7/12.
//  Copyright (c) 2012 Stanfy LLC. All rights reserved.
//
#import <objc/runtime.h>
#import "SFDynamicCodeInjection.h"
#include <dlfcn.h>
#import "SFFileWatcher.h"
#import "NSSet+ClassesList.h"
#import "NSObject+DyCInjection.h"
#import "SFInjectionsNotificationsCenter.h"


#if TARGET_IPHONE_SIMULATOR

#import <mach-o/loader.h>
#import <mach-o/dyld.h>
#import <mach-o/arch.h>

@interface SFDynamicCodeInjection () <SFFileWatcherDelegate>

@end

@implementation SFDynamicCodeInjection {

    BOOL _enabled;

    SFFileWatcher *_dciDirectoryFileWatcher;

}

+ (void)load {
    [self enable];

    NSLog(@"============================================");
    NSLog(@"DYCI : Dynamic Code Injection was started...");
    NSLog(@"To disable it, paste next line in your application:didFinishLaunching: method : \n\n"
        "[NSClassFromString(@\"SFDynamicCodeInjection\") performSelector:@selector(disable)];\n\n");
    NSLog(@"     or");
    NSLog(@"Simply remove dyci from dependencies");
    NSLog(@"============================================");


}

+ (SFDynamicCodeInjection *)sharedInstance {
    static SFDynamicCodeInjection *_instance = nil;

    @synchronized (self) {
        if (_instance == nil) {
            _instance = [[self alloc] init];
        }
    }

    return _instance;
}

+ (void)enable {

    if (![self sharedInstance]->_enabled) {

        [self sharedInstance]->_enabled = YES;

        // Swizzling init and dealloc methods
        [NSObject allowInjectionSubscriptionOnInitMethod];

        NSString *dciDirectoryPath = [self dciDirectoryPath];

        // Saving application bundle path, to have ability to inject
        // Resources, xibs, etc
        [self saveCurrentApplicationBundlePath:dciDirectoryPath];

        [self saveCurrentArchitectureAt:dciDirectoryPath];

        // Setting up watcher, to get in touch with director contents
        [self sharedInstance]->_dciDirectoryFileWatcher =
            [SFFileWatcher fileWatcherWithPath:dciDirectoryPath
                                      delegate:[self sharedInstance]];
    }

}


+ (void)disable {
    if ([self sharedInstance]->_enabled) {
        [self sharedInstance]->_enabled = NO;

        // Re-swizzling init and dealloc methods
        [NSObject allowInjectionSubscriptionOnInitMethod];

        // Removing file watcher
        [self sharedInstance]->_dciDirectoryFileWatcher.delegate = nil;
        [self sharedInstance]->_dciDirectoryFileWatcher = nil;
        NSLog(@"============================================");
        NSLog(@"DYCI : Dynamic Code Injection was stopped   ");
        NSLog(@"============================================");

    }
}


#pragma mark - Checking for Library

+ (NSString *)dciDirectoryPath {

    char *userENV = getenv("USER");
    NSString *dciDirectoryPath = nil;
    if (userENV != NULL) {
        dciDirectoryPath = [NSString stringWithFormat:@"/Users/%s/.dyci/", userENV];
    } else {
        // Fallback to the path, since, we cannot get USER variable
        NSString *userDirectoryPath = [@"~" stringByExpandingTildeInPath];

        // Assume default installation, which will have /Users/{username}/ structure
        NSArray *simUserDirectoryPathComponents = [userDirectoryPath pathComponents];
        if (simUserDirectoryPathComponents.count > 3) {
            // Get first 3 components
            NSMutableArray *macUserDirectoryPathComponents = [[simUserDirectoryPathComponents subarrayWithRange:NSMakeRange(0, 3)] mutableCopy];
            [macUserDirectoryPathComponents addObject:@".dyci"];
            dciDirectoryPath = [NSString pathWithComponents:macUserDirectoryPathComponents];
        }
    }
    NSLog(@"DYCI directory path is : %@", dciDirectoryPath);
    return dciDirectoryPath;
}


#pragma mark - Injections

/*
 Injecting in all classes, that were found in specified set
 */
- (void)performInjectionWithClassesInSet:(NSMutableSet *)classesSet {

    for (NSValue *classWrapper in classesSet) {
        Class clz;
        [classWrapper getValue:&clz];
        NSString *className = NSStringFromClass(clz);

        if ([className hasPrefix:@"__"] && [className hasSuffix:@"__"]) {
            // Skip some O_o classes

        } else {

            [self performInjectionWithClass:clz];
            NSLog(@"Class was successfully injected");

        }
    }
}


- (void)performInjectionWithClass:(Class)injectedClass {
    // Parsing it's method

    // This is really fun
    // Even if we load two instances of classes with the same name :)
    // NSClassFromString Will return FIRST(Original) Instance. And this is cool!
    NSString *className = [NSString stringWithFormat:@"%s", class_getName(injectedClass)];
    Class originalClass = NSClassFromString(className);

    // Replacing instance methods
    [self replaceMethodsOfClass:originalClass withMethodsOfClass:injectedClass];

    // Additionally we need to update Class methods (not instance methods) implementations
    [self replaceMethodsOfClass:object_getClass(originalClass) withMethodsOfClass:object_getClass(injectedClass)];

    // Notifying about new classes logic
    NSLog(@"Class (%@) and their subclasses instances would be notified with", NSStringFromClass(originalClass));
    NSLog(@" - (void)updateOnClassInjection ");

    [[SFInjectionsNotificationsCenter sharedInstance] notifyOnClassInjection:originalClass];

}


- (void)replaceMethodsOfClass:(Class)originalClass withMethodsOfClass:(Class)injectedClass {
    if (originalClass != injectedClass) {

        NSLog(@"Injecting %@ class : %@", class_isMetaClass(injectedClass) ? @"meta" : @"", NSStringFromClass(injectedClass));

        // Original class methods

        int i = 0;
        unsigned int mc = 0;

        Method *injectedMethodsList = class_copyMethodList(injectedClass, &mc);
        for (i = 0; i < mc; i++) {

            Method m = injectedMethodsList[i];
            SEL selector = method_getName(m);
            const char *types = method_getTypeEncoding(m);
            IMP injectedImplementation = method_getImplementation(m);

            //  Replacing old implementation with new one
            class_replaceMethod(originalClass, selector, injectedImplementation, types);

        }

    }
}


#pragma mark - Helpers

+ (void)saveCurrentApplicationBundlePath:(NSString *)dyciPath {

    NSString *filePathWithBundleInformation = [dyciPath stringByAppendingPathComponent:@"bundle"];

    NSString *mainBundlePath = [[NSBundle mainBundle] resourcePath];
    [mainBundlePath writeToFile:filePathWithBundleInformation
                     atomically:NO
                       encoding:NSUTF8StringEncoding
                          error:nil];
}

+ (void)saveCurrentArchitectureAt:(NSString *)dyciPath {

    // http://stackoverflow.com/questions/5567215/how-to-determine-binary-image-architecture-at-runtime
    // So the first header is here
    // So idea is here that first image - is the image of the app itself, which seems to be true
    const struct mach_header *image_header = _dyld_get_image_header(0);
    NSLog(@"Image header retrievied");

    // http://www.polarhome.com/service/man/generic.php?qf=NXGetArchInfoFromCpuType&type=2&of=MacOSX&sf=
    // Name	   CPU Type	       CPU Subtype		   Description
    //  x86_64	   CPU_TYPE_X86_64     CPU_SUBTYPE_X86_64_ALL	   Intel
    //  x86-64
    //  i386	   CPU_TYPE_I386       CPU_SUBTYPE_I386_ALL	   Intel 80x86
    //  arm	   CPU_TYPE_ARM	       CPU_SUBTYPE_ARM_ALL	   ARM
    //  arm64	   CPU_TYPE_ARM64      CPU_SUBTYPE_ARM64_ALL	   ARM64
    //  ppc	   CPU_TYPE_POWERPC    CPU_SUBTYPE_POWERPC_ALL	   PowerPC
    //  ppc64	   CPU_TYPE_POWERPC64  CPU_SUBTYPE_POWERPC64_ALL   PowerPC
    const NXArchInfo *architecture_info = NXGetArchInfoFromCpuType(image_header->cputype, image_header->cpusubtype);
    const char *arch = architecture_info->name;
    NSLog(@"Arch retrievied %s", arch);

    // So, let's save this architecture to specified path :)
    NSString *filePathWithBundleInformation = [dyciPath stringByAppendingPathComponent:@"arch"];

    NSString *imageArchitecture = [NSString stringWithCString:arch encoding:NSUTF8StringEncoding];
    [imageArchitecture writeToFile:filePathWithBundleInformation
                     atomically:NO
                       encoding:NSUTF8StringEncoding
                          error:nil];

}

#pragma mark - Privat API's

/*
 This one was found by searching on Github private headers
 */
- (void)flushUIImageCache {
#warning Fix this
    [NSClassFromString(@"UIImage") performSelector:@selector(_flushSharedImageCache)];

}

/*
 And this one was found Here
 http://michelf.ca/blog/2010/killer-private-eraser/
 Thanks to Michel
 */
extern void _CFBundleFlushBundleCaches(CFBundleRef bundle) __attribute__((weak_import));

- (void)flushBundleCache:(NSBundle *)bundle {

    // Check if we still have this function
    if (_CFBundleFlushBundleCaches != NULL) {
        CFURLRef bundleURL;
        CFBundleRef myBundle;

        // Make a CFURLRef from the CFString representation of the
        // bundle’s path.
        bundleURL = CFURLCreateWithFileSystemPath(
            kCFAllocatorDefault,
            (CFStringRef) [bundle bundlePath],
            kCFURLPOSIXPathStyle,
            true);

        // Make a bundle instance using the URLRef.
        myBundle = CFBundleCreate(kCFAllocatorDefault, bundleURL);

        _CFBundleFlushBundleCaches(myBundle);

        CFRelease(myBundle);
        CFRelease(bundleURL);
    }
}


#pragma mark - SFLibWatcherDelegate

- (void)newFileWasFoundAtPath:(NSString *)filePath {

    NSLog(@"New file injection detected at path : %@", filePath);
    if ([[filePath lastPathComponent] isEqualToString:@"resource"]) {

        NSLog(@" ");
        NSLog(@" ================================================= ");
        NSLog(@"New resource was injected");
        NSLog(@"All classes will be notified with");
        NSLog(@" - (void)updateOnResourceInjection:(NSString *)path ");
        NSLog(@" ");

        NSString *injectedResourcePath =
            [NSString stringWithContentsOfFile:filePath
                                      encoding:NSUTF8StringEncoding
                                         error:nil];

        // Flushing UIImage cache
        [self flushUIImageCache];

        if ([[injectedResourcePath pathExtension] isEqualToString:@"strings"]) {
            [self flushBundleCache:[NSBundle mainBundle]];
        }

        [[SFInjectionsNotificationsCenter sharedInstance] notifyOnResourceInjection:injectedResourcePath];

    }

    // If its library
    // Sometimes... we got notification with temporary file
    // dci12123.dylib.ld_1237sj
    NSString *dciDynamicLibraryPath = filePath;
    if (![[dciDynamicLibraryPath pathExtension] isEqualToString:@"dylib"]) {
        dciDynamicLibraryPath = [dciDynamicLibraryPath stringByDeletingPathExtension];
    }
    if ([[dciDynamicLibraryPath pathExtension] isEqualToString:@"dylib"]) {
        NSLog(@" ");
        NSLog(@" ================================================= ");
        NSLog(@"Found new DCI ... Loading");

        NSMutableSet *classesSet = [NSMutableSet currentClassesSet];

        void *libHandle = dlopen([dciDynamicLibraryPath cStringUsingEncoding:NSUTF8StringEncoding],
            RTLD_NOW | RTLD_GLOBAL);
        char *err = dlerror();

        if (libHandle) {

            NSLog(@"DYCI was successfully loaded");
            NSLog(@"Searching classes to inject");

            // Retrieving difference between old classes list and
            // current classes list
            NSMutableSet *currentClassesSet = [NSMutableSet currentClassesSet];
            [currentClassesSet minusSet:classesSet];

            [self performInjectionWithClassesInSet:currentClassesSet];

        } else {

            NSLog(@"Couldn't load file Error : %s", err);

        }

        NSLog(@" ");

        dlclose(libHandle);
    }
}

@end

#else

@implementation SFDynamicCodeInjection {

}
+ (void)enable {
    NSLog(@"DYCI: Sorry, Dynamic Code Ibjection is not available on devices");
}

+ (void)disable {
    NSLog(@"DYCI: Sorry, Dynamic Code Ibjection is not available on devices");
}

@end

#endif
