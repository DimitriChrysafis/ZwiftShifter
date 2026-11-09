#include <CoreFoundation/CoreFoundation.h>
#include <IOKit/hid/IOHIDManager.h>
#include <dlfcn.h>
#include <stdio.h>

// A two-button gamepad, no keyboard usage and no synthetic power/cadence.
static const unsigned char descriptor[] = {
    0x05, 0x01, 0x09, 0x05, 0xa1, 0x01,
    0x05, 0x09, 0x19, 0x01, 0x29, 0x02,
    0x15, 0x00, 0x25, 0x01, 0x75, 0x01, 0x95, 0x02,
    0x81, 0x02, 0x75, 0x06, 0x95, 0x01, 0x81, 0x03, 0xc0
};

int main(void) {
    void *framework = dlopen("/System/Library/Frameworks/IOKit.framework/IOKit", RTLD_NOW);
    typedef CFTypeRef (*CreateFn)(CFAllocatorRef, CFDictionaryRef);
    CreateFn create = (CreateFn)dlsym(framework, "IOHIDUserDeviceCreate");
    if (!create) { puts("IOHIDUserDeviceCreate not exported"); return 2; }
    CFMutableDictionaryRef props = CFDictionaryCreateMutable(NULL, 0,
        &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
    CFDataRef report = CFDataCreate(NULL, descriptor, sizeof descriptor);
    CFDictionarySetValue(props, CFSTR("ReportDescriptor"), report);
    CFDictionarySetValue(props, CFSTR("Product"), CFSTR("ZwiftShift Research Gamepad"));
    CFDictionarySetValue(props, CFSTR("Transport"), CFSTR("Virtual"));
    int vendor = 0x1209, product = 0x5a53;
    CFNumberRef v = CFNumberCreate(NULL, kCFNumberIntType, &vendor);
    CFNumberRef p = CFNumberCreate(NULL, kCFNumberIntType, &product);
    CFDictionarySetValue(props, CFSTR("VendorID"), v);
    CFDictionarySetValue(props, CFSTR("ProductID"), p);
    CFTypeRef device = create(kCFAllocatorDefault, props);
    printf("IOHIDUserDeviceCreate=%s\n", device ? "created" : "NULL (creation rejected)");
    if (device) { CFRunLoopRunInMode(kCFRunLoopDefaultMode, 5.0, false); CFRelease(device); }
    CFRelease(p); CFRelease(v); CFRelease(report); CFRelease(props); dlclose(framework);
    return device ? 0 : 1;
}
