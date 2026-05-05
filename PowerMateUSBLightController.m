#import "PowerMateUSBLightController.h"
#import <IOKit/IOCFPlugIn.h>
#import <IOKit/IOKitLib.h>
#import <IOKit/usb/IOUSBLib.h>

static const SInt32 PMVendorID = 0x077d;
static const SInt32 PMProductID = 0x0410;

@implementation PowerMateUSBLightController

+ (BOOL)setBrightness:(double)brightness
{
    UInt16 value = (UInt16)lrint(fmax(0.0, fmin(1.0, brightness)) * 255.0);
    return [self sendCommand:1 value:value];
}

+ (BOOL)setPulseEnabled:(BOOL)enabled
{
    return [self sendCommand:3 value:(enabled ? 1 : 0)];
}

+ (BOOL)setPulseRate:(double)pulseRate
{
    UInt16 n = (UInt16)lrint(fmax(0.0, fmin(1.0, pulseRate)) * 31.0);
    UInt16 value = 0;

    if (n < 16) {
        value = (UInt16)((15 - n) << 8);
    } else {
        value = (UInt16)(((n - 16) << 8) | 0x02);
    }

    return [self sendCommand:4 value:value];
}

+ (BOOL)sendCommand:(UInt16)command value:(UInt16)value
{
    io_iterator_t iterator = IO_OBJECT_NULL;
    if (![self copyPowerMateUSBDeviceIterator:&iterator]) {
        return NO;
    }

    BOOL sentToAnyDevice = NO;
    BOOL allRequestsSucceeded = YES;

    io_service_t service = IOIteratorNext(iterator);
    while (service != IO_OBJECT_NULL) {
        IOUSBDeviceInterface **device = [self copyUSBDeviceInterfaceForService:service];
        IOObjectRelease(service);

        if (device != NULL) {
            BOOL commandSucceeded = [self sendCommand:command value:value toDevice:device];
            sentToAnyDevice = YES;
            allRequestsSucceeded = allRequestsSucceeded && commandSucceeded;
            (*device)->Release(device);
        }

        service = IOIteratorNext(iterator);
    }

    IOObjectRelease(iterator);

    return sentToAnyDevice && allRequestsSucceeded;
}

+ (BOOL)sendCommand:(UInt16)command value:(UInt16)value toDevice:(IOUSBDeviceInterface **)device
{
    IOReturn openResult = (*device)->USBDeviceOpen(device);
    if (openResult != kIOReturnSuccess && openResult != kIOReturnExclusiveAccess) {
        return NO;
    }

    IOUSBDevRequest request;
    bzero(&request, sizeof(request));
    request.bmRequestType = 0x41;
    request.bRequest = 0x01;
    request.wValue = command;
    request.wIndex = value;
    request.wLength = 0;
    request.pData = NULL;

    IOReturn requestResult = (*device)->DeviceRequest(device, &request);

    if (openResult == kIOReturnSuccess) {
        (*device)->USBDeviceClose(device);
    }

    return requestResult == kIOReturnSuccess;
}

+ (BOOL)copyPowerMateUSBDeviceIterator:(io_iterator_t *)iterator
{
    CFMutableDictionaryRef matching = IOServiceMatching(kIOUSBDeviceClassName);
    if (matching == NULL) {
        return NO;
    }

    CFNumberRef vendor = CFNumberCreate(kCFAllocatorDefault, kCFNumberSInt32Type, &PMVendorID);
    CFNumberRef product = CFNumberCreate(kCFAllocatorDefault, kCFNumberSInt32Type, &PMProductID);
    CFDictionarySetValue(matching, CFSTR(kUSBVendorID), vendor);
    CFDictionarySetValue(matching, CFSTR(kUSBProductID), product);
    CFRelease(vendor);
    CFRelease(product);

    IOReturn result = IOServiceGetMatchingServices(kIOMainPortDefault, matching, iterator);
    if (result != kIOReturnSuccess) {
        return NO;
    }

    return YES;
}

+ (IOUSBDeviceInterface **)copyUSBDeviceInterfaceForService:(io_service_t)service
{
    IOCFPlugInInterface **plugin = NULL;
    SInt32 score = 0;
    IOReturn result = IOCreatePlugInInterfaceForService(
        service,
        kIOUSBDeviceUserClientTypeID,
        kIOCFPlugInInterfaceID,
        &plugin,
        &score
    );

    if (result != kIOReturnSuccess || plugin == NULL) {
        return NULL;
    }

    IOUSBDeviceInterface **device = NULL;
    HRESULT queryResult = (*plugin)->QueryInterface(
        plugin,
        CFUUIDGetUUIDBytes(kIOUSBDeviceInterfaceID),
        (LPVOID *)&device
    );

    (*plugin)->Release(plugin);

    if (queryResult || device == NULL) {
        return NULL;
    }

    return device;
}

@end
