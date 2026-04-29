//
//  hostinfo.m
//  iSH-AOK
//
//  Created by Michael Miller on 12/25/23.
//

#import <Foundation/Foundation.h>
#import <mach-o/arch.h>
#import <stdio.h>
#import <sys/sysctl.h>
#import <sys/utsname.h>
#import "hostinfo.h"

static NSString *hostMachineIdentifier(void);
static NSString *hostProcessMachineIdentifier(void);
static BOOL hostIdentifierNeedsSimulatorOverride(NSString *identifier);

NSString* translateDeviceIdentifier(NSString *identifier) {
    NSDictionary<NSString *, NSString *> *deviceNames = @{
        // iPhones with 64-bit Processors
        @"arm64": @"iDevice Simulator (ARM)",
        @"x86_64": @"iDevice Simulator (x86_64)",
        @"iPhone6,1": @"iPhone 5S (GSM)",
        @"iPhone6,2": @"iPhone 5S (Global)",
        @"iPhone7,1": @"iPhone 6 Plus",
        @"iPhone7,2": @"iPhone 6",
        @"iPhone8,1": @"iPhone 6s",
        @"iPhone8,2": @"iPhone 6s Plus",
        @"iPhone8,4": @"iPhone SE (GSM)",
        @"iPhone9,1": @"iPhone 7",
        @"iPhone9,2": @"iPhone 7 Plus",
        @"iPhone9,3": @"iPhone 7",
        @"iPhone9,4": @"iPhone 7 Plus",
        @"iPhone10,1" : @"iPhone 8",
        @"iPhone10,2": @"iPhone 8 Plus",
        @"iPhone10,3": @"iPhone X Global",
        @"iPhone10,4": @"iPhone 8",
        @"iPhone10,5": @"iPhone 8 Plus",
        @"iPhone10,6": @"iPhone X GSM",
        @"iPhone11,2": @"iPhone XS",
        @"iPhone11,4": @"iPhone XS Max",
        @"iPhone11,6": @"iPhone XS Max Global",
        @"iPhone11,8": @"iPhone XR",
        @"iPhone12,1": @"iPhone 11",
        @"iPhone12,3": @"iPhone 11 Pro",
        @"iPhone12,5": @"iPhone 11 Pro Max",
        @"iPhone12,8": @"iPhone SE 2nd Gen",
        @"iPhone13,1": @"iPhone 12 Mini",
        @"iPhone13,2": @"iPhone 12",
        @"iPhone13,3": @"iPhone 12 Pro",
        @"iPhone13,4": @"iPhone 12 Pro Max",
        @"iPhone14,2": @"iPhone 13 Pro",
        @"iPhone14,3": @"iPhone 13 Pro Max",
        @"iPhone14,4": @"iPhone 13 Mini",
        @"iPhone14,5": @"iPhone 13",
        @"iPhone14,6": @"iPhone SE 3rd Gen",
        @"iPhone14,7": @"iPhone 14",
        @"iPhone14,8": @"iPhone 14 Plus",
        @"iPhone15,2": @"iPhone 14 Pro",
        @"iPhone15,3": @"iPhone 14 Pro Max",
        @"iPhone15,4": @"iPhone 15",
        @"iPhone15,5": @"iPhone 15 Plus",
        @"iPhone16,1": @"iPhone 15 Pro",
        @"iPhone16,2": @"iPhone 15 Pro Max",
        @"iPhone17,1": @"iPhone 16 Pro / Pro Max",
        @"iPhone17,2": @"iPhone 16 Pro / Pro Max",
        @"iPhone17,3": @"iPhone 16 / 16 Plus",
        @"iPhone17,4": @"iPhone 16 / 16 Plus",
        @"iPhone17,5": @"iPhone 16e",
        @"iPhone18,1": @"iPhone 17 / 17 Pro / 17 Pro Max",
        @"iPhone18,2": @"iPhone 17 / 17 Pro / 17 Pro Max",
        @"iPhone18,3": @"iPhone 17 / 17 Pro / 17 Pro Max",
        @"iPhone18,4": @"iPhone Air",
        @"iPhone18,5": @"iPhone 17e",
        // iPads with 64-bit Processors
        @"iPad4,1": @"iPad Air (WiFi)",
        @"iPad4,2": @"iPad Air (GSM+CDMA)",
        @"iPad4,3": @"1st Gen iPad Air (China)",
        @"iPad4,4": @"iPad mini Retina (WiFi)",
        @"iPad4,5": @"iPad mini Retina (GSM+CDMA)",
        @"iPad4,6": @"iPad mini Retina (China)",
        @"iPad4,7": @"iPad mini 3 (WiFi)",
        @"iPad4,8": @"iPad mini 3 (GSM+CDMA)",
        @"iPad4,9": @"iPad Mini 3 (China)",
        @"iPad5,1": @"iPad mini 4 (WiFi)",
        @"iPad5,2": @"4th Gen iPad mini (WiFi+Cellular)",
        @"iPad5,3": @"iPad Air 2 (WiFi)",
        @"iPad5,4": @"iPad Air 2 (Cellular)",
        @"iPad6,3": @"iPad Pro (9.7 inch, WiFi)",
        @"iPad6,4": @"iPad Pro (9.7 inch, WiFi+LTE)",
        @"iPad6,7": @"iPad Pro (12.9 inch, WiFi)",
        @"iPad6,8": @"iPad Pro (12.9 inch, WiFi+LTE)",
        @"iPad7,3": @"iPad Pro 10.5-inch 2nd Gen",
        @"iPad7,4": @"iPad Pro 10.5-inch 2nd Gen",
        @"iPad7,5": @"iPad 6th Gen (WiFi)",
        @"iPad7,6": @"iPad 6th Gen (WiFi+Cellular)",
        @"iPad7,11": @"iPad 7th Gen 10.2-inch (WiFi)",
        @"iPad7,12": @"iPad 7th Gen 10.2-inch (WiFi+Cellular)",
        @"iPad8,1": @"iPad Pro 11 inch 3rd Gen (WiFi)",
        @"iPad8,2": @"iPad Pro 11 inch 3rd Gen (1TB, WiFi)",
        @"iPad8,3": @"iPad Pro 11 inch 3rd Gen (WiFi+Cellular)",
        @"iPad8,4": @"iPad Pro 11 inch 3rd Gen (1TB, WiFi+Cellular)",
        @"iPad8,5": @"iPad Pro 12.9 inch 3rd Gen (WiFi)",
        @"iPad8,6": @"iPad Pro 12.9 inch 3rd Gen (1TB, WiFi)",
        @"iPad8,7": @"iPad Pro 12.9 inch 3rd Gen (WiFi+Cellular)",
        @"iPad8,8": @"iPad Pro 12.9 inch 3rd Gen (1TB, WiFi+Cellular)",
        @"iPad8,9": @"iPad Pro 11 inch 4th Gen (WiFi)",
        @"iPad8,10": @"iPad Pro 11 inch 4th Gen (WiFi+Cellular)",
        @"iPad8,11": @"iPad Pro 12.9 inch 4th Gen (WiFi)",
        @"iPad8,12": @"iPad Pro 12.9 inch 4th Gen (WiFi+Cellular)",
        @"iPad11,1": @"iPad mini 5th Gen (WiFi)",
        @"iPad11,2": @"iPad mini 5th Gen",
        @"iPad11,3": @"iPad Air 3rd Gen (WiFi)",
        @"iPad11,4": @"iPad Air 3rd Gen",
        @"iPad11,6": @"iPad 8th Gen (WiFi)",
        @"iPad11,7": @"iPad 8th Gen (WiFi+Cellular)",
        @"iPad12,1": @"iPad 9th Gen (WiFi)",
        @"iPad12,2": @"iPad 9th Gen (WiFi+Cellular)",
        @"iPad14,1": @"iPad mini 6th Gen (WiFi)",
        @"iPad14,2": @"iPad mini 6th Gen (WiFi+Cellular)",
        @"iPad13,1": @"iPad Air 4th Gen (WiFi)",
        @"iPad13,2": @"iPad Air 4th Gen (WiFi+Cellular)",
        @"iPad13,4": @"iPad Pro 11 inch 3rd Gen (WiFi)",
        @"iPad13,5": @"iPad Pro 11 inch 3rd Gen (WiFi+Cellular US)",
        @"iPad13,6": @"iPad Pro 11 inch 3rd Gen (WiFi+Cellular Global)",
        @"iPad13,7": @"iPad Pro 11 inch 3rd Gen (WiFi+Cellular China)",
        @"iPad13,8": @"iPad Pro 12.9 inch 5th Gen",
        @"iPad13,9": @"iPad Pro 12.9 inch 5th Gen",
        @"iPad13,10": @"iPad Pro 12.9 inch 5th Gen",
        @"iPad13,11": @"iPad Pro 12.9 inch 5th Gen",
        @"iPad13,16": @"iPad Air 5th Gen (WiFi)",
        @"iPad13,17": @"iPad Air 5th Gen (WiFi+Cellular)",
        @"iPad13,18": @"iPad 10th Gen",
        @"iPad13,19": @"iPad 10th Gen",
        @"iPad14,3": @"iPad Pro 11 inch 4th Gen",
        @"iPad14,4": @"iPad Pro 11 inch 4th Gen",
        @"iPad14,5": @"iPad Pro 12.9 inch 6th Gen",
        @"iPad14,6": @"iPad Pro 12.9 inch 6th Gen",
        @"iPad14,8": @"iPad Air (11-inch, M2)",
        @"iPad14,9": @"iPad Air (11-inch, M2)",
        @"iPad14,10": @"iPad Air (13-inch, M2)",
        @"iPad14,11": @"iPad Air (13-inch, M2)",
        @"iPad16,1": @"iPad mini (A17 Pro)",
        @"iPad16,2": @"iPad mini (A17 Pro)",
        @"iPad16,3": @"iPad Pro 11-inch (M4)",
        @"iPad16,4": @"iPad Pro 11-inch (M4)",
        @"iPad16,5": @"iPad Pro 13-inch (M4)",
        @"iPad16,6": @"iPad Pro 13-inch (M4)",
    };
    
    NSString *deviceName = deviceNames[identifier];
    if (deviceName) {
        return deviceName;
    } else {
        return identifier; // Return the original identifier if no mapping is found
    }
}

static NSString *hostChipIdentifier(NSString *identifier) {
    NSDictionary<NSString *, NSString *> *chipNames = @{
        @"iPhone6,1": @"A7",
        @"iPhone6,2": @"A7",
        @"iPhone7,1": @"A8",
        @"iPhone7,2": @"A8",
        @"iPhone8,1": @"A9",
        @"iPhone8,2": @"A9",
        @"iPhone8,4": @"A9",
        @"iPhone9,1": @"A10",
        @"iPhone9,2": @"A10",
        @"iPhone9,3": @"A10",
        @"iPhone9,4": @"A10",
        @"iPhone10,1": @"A11",
        @"iPhone10,2": @"A11",
        @"iPhone10,3": @"A11",
        @"iPhone10,4": @"A11",
        @"iPhone10,5": @"A11",
        @"iPhone10,6": @"A11",
        @"iPhone11,2": @"A12",
        @"iPhone11,4": @"A12",
        @"iPhone11,6": @"A12",
        @"iPhone11,8": @"A12",
        @"iPhone12,1": @"A13",
        @"iPhone12,3": @"A13",
        @"iPhone12,5": @"A13",
        @"iPhone12,8": @"A13",
        @"iPhone13,1": @"A14",
        @"iPhone13,2": @"A14",
        @"iPhone13,3": @"A14",
        @"iPhone13,4": @"A14",
        @"iPhone14,2": @"A15",
        @"iPhone14,3": @"A15",
        @"iPhone14,4": @"A15",
        @"iPhone14,5": @"A15",
        @"iPhone14,6": @"A15",
        @"iPhone14,7": @"A15",
        @"iPhone14,8": @"A15",
        @"iPhone15,2": @"A16",
        @"iPhone15,3": @"A16",
        @"iPhone15,4": @"A16",
        @"iPhone15,5": @"A16",
        @"iPhone16,1": @"A17 Pro",
        @"iPhone16,2": @"A17 Pro",
        @"iPad4,1": @"A7",
        @"iPad4,2": @"A7",
        @"iPad4,3": @"A7",
        @"iPad4,4": @"A8",
        @"iPad4,5": @"A8",
        @"iPad4,6": @"A8",
        @"iPad4,7": @"A8",
        @"iPad4,8": @"A8",
        @"iPad4,9": @"A8",
        @"iPad5,1": @"A8",
        @"iPad5,2": @"A8",
        @"iPad5,3": @"A8X",
        @"iPad5,4": @"A8X",
        @"iPad6,3": @"A9X",
        @"iPad6,4": @"A9X",
        @"iPad6,7": @"A9X",
        @"iPad6,8": @"A9X",
        @"iPad7,3": @"A10X",
        @"iPad7,4": @"A10X",
        @"iPad7,5": @"A10",
        @"iPad7,6": @"A10",
        @"iPad7,11": @"A10",
        @"iPad7,12": @"A10",
        @"iPad8,1": @"A12X",
        @"iPad8,2": @"A12X",
        @"iPad8,3": @"A12X",
        @"iPad8,4": @"A12X",
        @"iPad8,5": @"A12X",
        @"iPad8,6": @"A12X",
        @"iPad8,7": @"A12X",
        @"iPad8,8": @"A12X",
        @"iPad8,9": @"A12Z",
        @"iPad8,10": @"A12Z",
        @"iPad8,11": @"A12Z",
        @"iPad8,12": @"A12Z",
        @"iPad11,1": @"A12",
        @"iPad11,2": @"A12",
        @"iPad11,3": @"A12",
        @"iPad11,4": @"A12",
        @"iPad11,6": @"A12",
        @"iPad11,7": @"A12",
        @"iPad12,1": @"A13",
        @"iPad12,2": @"A13",
        @"iPad13,1": @"A14",
        @"iPad13,2": @"A14",
        @"iPad13,4": @"M1",
        @"iPad13,5": @"M1",
        @"iPad13,6": @"M1",
        @"iPad13,7": @"M1",
        @"iPad13,8": @"M1",
        @"iPad13,9": @"M1",
        @"iPad13,10": @"M1",
        @"iPad13,11": @"M1",
        @"iPad13,16": @"M1",
        @"iPad13,17": @"M1",
        @"iPad13,18": @"A14",
        @"iPad13,19": @"A14",
        @"iPad14,1": @"A15",
        @"iPad14,2": @"A15",
        @"iPad14,3": @"M2",
        @"iPad14,4": @"M2",
        @"iPad14,5": @"M2",
        @"iPad14,6": @"M2",
        @"iPad14,8": @"M2",
        @"iPad14,9": @"M2",
        @"iPad14,10": @"M2",
        @"iPad14,11": @"M2",
        @"iPad16,1": @"A17 Pro",
        @"iPad16,2": @"A17 Pro",
        @"iPad16,3": @"M4",
        @"iPad16,4": @"M4",
        @"iPad16,5": @"M4",
        @"iPad16,6": @"M4",
    };

    return chipNames[identifier];
}

static NSDictionary<NSString *, NSNumber *> *hostFallbackCoreTopology(NSString *identifier) {
    NSDictionary<NSString *, NSDictionary<NSString *, NSNumber *> *> *topologies = @{
        @"iPhone6,1": @{@"performance": @2, @"efficiency": @0},
        @"iPhone6,2": @{@"performance": @2, @"efficiency": @0},
        @"iPhone7,1": @{@"performance": @2, @"efficiency": @0},
        @"iPhone7,2": @{@"performance": @2, @"efficiency": @0},
        @"iPhone8,1": @{@"performance": @2, @"efficiency": @0},
        @"iPhone8,2": @{@"performance": @2, @"efficiency": @0},
        @"iPhone8,4": @{@"performance": @2, @"efficiency": @0},
        @"iPhone9,1": @{@"performance": @2, @"efficiency": @2},
        @"iPhone9,2": @{@"performance": @2, @"efficiency": @2},
        @"iPhone9,3": @{@"performance": @2, @"efficiency": @2},
        @"iPhone9,4": @{@"performance": @2, @"efficiency": @2},
        @"iPhone10,1": @{@"performance": @2, @"efficiency": @4},
        @"iPhone10,2": @{@"performance": @2, @"efficiency": @4},
        @"iPhone10,3": @{@"performance": @2, @"efficiency": @4},
        @"iPhone10,4": @{@"performance": @2, @"efficiency": @4},
        @"iPhone10,5": @{@"performance": @2, @"efficiency": @4},
        @"iPhone10,6": @{@"performance": @2, @"efficiency": @4},
        @"iPhone11,2": @{@"performance": @2, @"efficiency": @4},
        @"iPhone11,4": @{@"performance": @2, @"efficiency": @4},
        @"iPhone11,6": @{@"performance": @2, @"efficiency": @4},
        @"iPhone11,8": @{@"performance": @2, @"efficiency": @4},
        @"iPhone12,1": @{@"performance": @2, @"efficiency": @4},
        @"iPhone12,3": @{@"performance": @2, @"efficiency": @4},
        @"iPhone12,5": @{@"performance": @2, @"efficiency": @4},
        @"iPhone12,8": @{@"performance": @2, @"efficiency": @4},
        @"iPhone13,1": @{@"performance": @2, @"efficiency": @4},
        @"iPhone13,2": @{@"performance": @2, @"efficiency": @4},
        @"iPhone13,3": @{@"performance": @2, @"efficiency": @4},
        @"iPhone13,4": @{@"performance": @2, @"efficiency": @4},
        @"iPhone14,2": @{@"performance": @2, @"efficiency": @4},
        @"iPhone14,3": @{@"performance": @2, @"efficiency": @4},
        @"iPhone14,4": @{@"performance": @2, @"efficiency": @4},
        @"iPhone14,5": @{@"performance": @2, @"efficiency": @4},
        @"iPhone14,6": @{@"performance": @2, @"efficiency": @4},
        @"iPhone14,7": @{@"performance": @2, @"efficiency": @4},
        @"iPhone14,8": @{@"performance": @2, @"efficiency": @4},
        @"iPhone15,2": @{@"performance": @2, @"efficiency": @4},
        @"iPhone15,3": @{@"performance": @2, @"efficiency": @4},
        @"iPhone15,4": @{@"performance": @2, @"efficiency": @4},
        @"iPhone15,5": @{@"performance": @2, @"efficiency": @4},
        @"iPhone16,1": @{@"performance": @2, @"efficiency": @4},
        @"iPhone16,2": @{@"performance": @2, @"efficiency": @4},
        @"iPad4,1": @{@"performance": @2, @"efficiency": @0},
        @"iPad4,2": @{@"performance": @2, @"efficiency": @0},
        @"iPad4,3": @{@"performance": @2, @"efficiency": @0},
        @"iPad4,4": @{@"performance": @2, @"efficiency": @0},
        @"iPad4,5": @{@"performance": @2, @"efficiency": @0},
        @"iPad4,6": @{@"performance": @2, @"efficiency": @0},
        @"iPad4,7": @{@"performance": @2, @"efficiency": @0},
        @"iPad4,8": @{@"performance": @2, @"efficiency": @0},
        @"iPad4,9": @{@"performance": @2, @"efficiency": @0},
        @"iPad5,1": @{@"performance": @2, @"efficiency": @0},
        @"iPad5,2": @{@"performance": @2, @"efficiency": @0},
        @"iPad5,3": @{@"performance": @3, @"efficiency": @0},
        @"iPad5,4": @{@"performance": @3, @"efficiency": @0},
        @"iPad6,3": @{@"performance": @2, @"efficiency": @0},
        @"iPad6,4": @{@"performance": @2, @"efficiency": @0},
        @"iPad6,7": @{@"performance": @2, @"efficiency": @0},
        @"iPad6,8": @{@"performance": @2, @"efficiency": @0},
        @"iPad7,3": @{@"performance": @3, @"efficiency": @3},
        @"iPad7,4": @{@"performance": @3, @"efficiency": @3},
        @"iPad7,5": @{@"performance": @2, @"efficiency": @2},
        @"iPad7,6": @{@"performance": @2, @"efficiency": @2},
        @"iPad7,11": @{@"performance": @2, @"efficiency": @2},
        @"iPad7,12": @{@"performance": @2, @"efficiency": @2},
        @"iPad8,1": @{@"performance": @4, @"efficiency": @4},
        @"iPad8,2": @{@"performance": @4, @"efficiency": @4},
        @"iPad8,3": @{@"performance": @4, @"efficiency": @4},
        @"iPad8,4": @{@"performance": @4, @"efficiency": @4},
        @"iPad8,5": @{@"performance": @4, @"efficiency": @4},
        @"iPad8,6": @{@"performance": @4, @"efficiency": @4},
        @"iPad8,7": @{@"performance": @4, @"efficiency": @4},
        @"iPad8,8": @{@"performance": @4, @"efficiency": @4},
        @"iPad8,9": @{@"performance": @4, @"efficiency": @4},
        @"iPad8,10": @{@"performance": @4, @"efficiency": @4},
        @"iPad8,11": @{@"performance": @4, @"efficiency": @4},
        @"iPad8,12": @{@"performance": @4, @"efficiency": @4},
        @"iPad11,1": @{@"performance": @2, @"efficiency": @4},
        @"iPad11,2": @{@"performance": @2, @"efficiency": @4},
        @"iPad11,3": @{@"performance": @2, @"efficiency": @4},
        @"iPad11,4": @{@"performance": @2, @"efficiency": @4},
        @"iPad11,6": @{@"performance": @2, @"efficiency": @4},
        @"iPad11,7": @{@"performance": @2, @"efficiency": @4},
        @"iPad12,1": @{@"performance": @2, @"efficiency": @4},
        @"iPad12,2": @{@"performance": @2, @"efficiency": @4},
        @"iPad13,1": @{@"performance": @2, @"efficiency": @4},
        @"iPad13,2": @{@"performance": @2, @"efficiency": @4},
        @"iPad13,4": @{@"performance": @4, @"efficiency": @4},
        @"iPad13,5": @{@"performance": @4, @"efficiency": @4},
        @"iPad13,6": @{@"performance": @4, @"efficiency": @4},
        @"iPad13,7": @{@"performance": @4, @"efficiency": @4},
        @"iPad13,8": @{@"performance": @4, @"efficiency": @4},
        @"iPad13,9": @{@"performance": @4, @"efficiency": @4},
        @"iPad13,10": @{@"performance": @4, @"efficiency": @4},
        @"iPad13,11": @{@"performance": @4, @"efficiency": @4},
        @"iPad13,16": @{@"performance": @4, @"efficiency": @4},
        @"iPad13,17": @{@"performance": @4, @"efficiency": @4},
        @"iPad13,18": @{@"performance": @2, @"efficiency": @4},
        @"iPad13,19": @{@"performance": @2, @"efficiency": @4},
        @"iPad14,1": @{@"performance": @2, @"efficiency": @4},
        @"iPad14,2": @{@"performance": @2, @"efficiency": @4},
        @"iPad14,3": @{@"performance": @4, @"efficiency": @4},
        @"iPad14,4": @{@"performance": @4, @"efficiency": @4},
        @"iPad14,5": @{@"performance": @4, @"efficiency": @4},
        @"iPad14,6": @{@"performance": @4, @"efficiency": @4},
        @"iPad14,8": @{@"performance": @4, @"efficiency": @4},
        @"iPad14,9": @{@"performance": @4, @"efficiency": @4},
        @"iPad14,10": @{@"performance": @4, @"efficiency": @4},
        @"iPad14,11": @{@"performance": @4, @"efficiency": @4},
        @"iPad16,1": @{@"performance": @2, @"efficiency": @4},
        @"iPad16,2": @{@"performance": @2, @"efficiency": @4},
    };

    return topologies[identifier];
}

static BOOL readSysctlUnsigned(const char *name, unsigned *value) {
    size_t size = sizeof(*value);
    return sysctlbyname(name, value, &size, NULL, 0) == 0;
}

static NSString *readSysctlString(const char *name) {
    size_t size = 0;
    if (sysctlbyname(name, NULL, &size, NULL, 0) != 0 || size == 0)
        return nil;

    char *buffer = malloc(size);
    if (buffer == NULL)
        return nil;

    if (sysctlbyname(name, buffer, &size, NULL, 0) != 0) {
        free(buffer);
        return nil;
    }

    NSString *result = [NSString stringWithCString:buffer encoding:NSUTF8StringEncoding];
    free(buffer);
    return result;
}

static NSDictionary<NSString *, NSNumber *> *hostRuntimeCoreTopology(void) {
    unsigned perfLevelCount = 0;
    if (!readSysctlUnsigned("hw.nperflevels", &perfLevelCount) || perfLevelCount == 0)
        return nil;

    unsigned performance = 0;
    unsigned efficiency = 0;
    unsigned homogeneous = 0;

    for (unsigned i = 0; i < perfLevelCount; i++) {
        char countName[64];
        snprintf(countName, sizeof(countName), "hw.perflevel%u.physicalcpu", i);

        unsigned coreCount = 0;
        if (!readSysctlUnsigned(countName, &coreCount)) {
            snprintf(countName, sizeof(countName), "hw.perflevel%u.logicalcpu", i);
            if (!readSysctlUnsigned(countName, &coreCount))
                continue;
        }

        char levelNameKey[64];
        snprintf(levelNameKey, sizeof(levelNameKey), "hw.perflevel%u.name", i);
        NSString *levelName = [[readSysctlString(levelNameKey) lowercaseString] copy];

        if ([levelName containsString:@"perf"]) {
            performance += coreCount;
        } else if ([levelName containsString:@"eff"]) {
            efficiency += coreCount;
        } else if (perfLevelCount == 1) {
            homogeneous += coreCount;
        } else if (i == 0) {
            performance += coreCount;
        } else if (i == perfLevelCount - 1) {
            efficiency += coreCount;
        } else {
            homogeneous += coreCount;
        }
    }

    if (performance == 0 && efficiency == 0 && homogeneous == 0)
        return nil;

    return @{
        @"performance": @(performance),
        @"efficiency": @(efficiency),
        @"homogeneous": @(homogeneous),
    };
}

static NSDictionary<NSString *, NSNumber *> *hostCoreTopology(void) {
    NSString *processMachineIdentifier = hostProcessMachineIdentifier();
    if (!hostIdentifierNeedsSimulatorOverride(processMachineIdentifier)) {
        NSDictionary<NSString *, NSNumber *> *runtimeTopology = hostRuntimeCoreTopology();
        if (runtimeTopology != nil)
            return runtimeTopology;
    }
    return hostFallbackCoreTopology(hostMachineIdentifier());
}

static BOOL hostIdentifierNeedsSimulatorOverride(NSString *identifier) {
    return [identifier isEqualToString:@"arm64"] ||
           [identifier isEqualToString:@"arm64e"] ||
           [identifier isEqualToString:@"x86_64"] ||
           [identifier isEqualToString:@"i386"];
}

static NSString *hostMachineIdentifier(void) {
    NSString *machineIdentifier = hostProcessMachineIdentifier();
    if (hostIdentifierNeedsSimulatorOverride(machineIdentifier)) {
        NSString *simulatorIdentifier = NSProcessInfo.processInfo.environment[@"SIMULATOR_MODEL_IDENTIFIER"];
        if (simulatorIdentifier.length > 0)
            machineIdentifier = simulatorIdentifier;
    }

    return machineIdentifier;
}

static NSString *hostProcessMachineIdentifier(void) {
    struct utsname systemInfo;
    uname(&systemInfo);

    NSString *machineIdentifier = [NSString stringWithCString:systemInfo.machine encoding:NSUTF8StringEncoding];
    if (machineIdentifier == nil)
        machineIdentifier = @"unknown";
    return machineIdentifier;
}

char* printHostInfo(void) {
    struct utsname systemInfo;
    uname(&systemInfo);

    NSString *machineIdentifier = hostMachineIdentifier();
    NSString *translatedMachine = translateDeviceIdentifier(machineIdentifier);
    char *hostArchitecture = copyHostArchitecture();
    char *hostCoreTopology = copyHostCoreTopology();

    NSString *deviceInfo = [NSString stringWithFormat:@"Host OS Name: %s\nHost OS Release: %s\nHost OS Version: %s\nHost Architecture: %s\nHost Machine Identifier: %@\nHost Device Name: %@\nHost Core Types: %s\n",
                            systemInfo.sysname,    // Operating system name (e.g., Darwin)
                            systemInfo.release,    // Operating system release (e.g., 20.3.0)
                            systemInfo.version,    // Operating system version
                            hostArchitecture,
                            machineIdentifier,
                            translatedMachine,
                            hostCoreTopology];

    free(hostArchitecture);
    free(hostCoreTopology);
    char *cString = strdup([deviceInfo UTF8String]);
    return cString;
}

char *copyHostArchitecture(void) {
    const char *archName = NULL;
    const NXArchInfo *archInfo = NXGetLocalArchInfo();
    if (archInfo != NULL && archInfo->name != NULL)
        archName = archInfo->name;

    if (archName == NULL) {
#if defined(__aarch64__) || defined(__arm64__)
        archName = "arm64";
#elif defined(__x86_64__)
        archName = "x86_64";
#elif defined(__i386__)
        archName = "i386";
#elif defined(__arm__)
        archName = "arm";
#else
        archName = "unknown";
#endif
    }

    NSString *machineIdentifier = hostMachineIdentifier();
    NSString *chipIdentifier = hostChipIdentifier(machineIdentifier);
    if (chipIdentifier.length > 0) {
        NSString *description = [NSString stringWithFormat:@"%s(%@)", archName, chipIdentifier];
        return strdup([description UTF8String]);
    }

    return strdup(archName);
}

char *copyHostMachineIdentifier(void) {
    return strdup([hostMachineIdentifier() UTF8String]);
}

char *copyHostDeviceName(void) {
    NSString *translatedMachine = translateDeviceIdentifier(hostMachineIdentifier());
    return strdup([translatedMachine UTF8String]);
}

char *copyHostCoreTopology(void) {
    NSDictionary<NSString *, NSNumber *> *topology = hostCoreTopology();
    if (topology == nil)
        return strdup("unknown");

    NSInteger performance = topology[@"performance"].integerValue;
    NSInteger efficiency = topology[@"efficiency"].integerValue;
    NSInteger homogeneous = topology[@"homogeneous"].integerValue;

    NSString *summary = nil;
    if (performance > 0 || efficiency > 0) {
        summary = [NSString stringWithFormat:@"performance=%ld efficiency=%ld",
                   (long) performance, (long) efficiency];
    } else {
        summary = [NSString stringWithFormat:@"homogeneous=%ld", (long) homogeneous];
    }
    return strdup([summary UTF8String]);
}
