#include "SMCBridge.h"
#include <IOKit/IOKitLib.h>
#include <mach/mach.h>
#include <stdio.h>
#include <string.h>
#include <unistd.h>

enum { SMC_CALL = 2, SMC_READ = 5, SMC_WRITE = 6, SMC_GET_KEY_FROM_INDEX = 8, SMC_READ_KEY_INFO = 9 };

typedef struct { uint8_t major, minor, build, reserved; uint16_t release; } SMCVersion;
typedef struct { uint16_t version, length; uint32_t cpu, gpu, memory; } SMCPLimit;
typedef struct { uint32_t dataSize, dataType; uint8_t attributes, padding[3]; } SMCKeyInfo;
typedef struct {
    uint32_t key;
    SMCVersion version;
    SMCPLimit limit;
    SMCKeyInfo keyInfo;
    uint8_t result, status, data8;
    uint32_t data32;
    uint8_t bytes[32];
} SMCParam;
typedef struct { uint32_t size, type; uint8_t bytes[32]; } SMCValue;

_Static_assert(sizeof(SMCParam) == 80, "SMCParam must match Apple SMC ABI");

static io_connect_t connection;

static uint32_t key_code(const char *key) {
    return ((uint32_t)key[0] << 24) | ((uint32_t)key[1] << 16) |
           ((uint32_t)key[2] << 8) | (uint32_t)key[3];
}

static int open_smc(void) {
    if (connection) return 0;
    io_service_t service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSMC"));
    if (!service) return -1;
    kern_return_t result = IOServiceOpen(service, mach_task_self(), 0, &connection);
    IOObjectRelease(service);
    if (result != KERN_SUCCESS) { connection = 0; return result == kIOReturnNotPrivileged ? -2 : -1; }
    return 0;
}

static int call_smc(SMCParam *input, SMCParam *output) {
    int opened = open_smc();
    if (opened != 0) return opened;
    size_t outputSize = sizeof(*output);
    kern_return_t result = IOConnectCallStructMethod(connection, SMC_CALL, input, sizeof(*input), output, &outputSize);
    if (result == kIOReturnNotPrivileged) return -2;
    if (result != KERN_SUCCESS || output->result != 0) return -1;
    return 0;
}

static int key_info(const char *name, SMCKeyInfo *info) {
    SMCParam input = {0}, output = {0};
    input.key = key_code(name);
    input.data8 = SMC_READ_KEY_INFO;
    int result = call_smc(&input, &output);
    if (result != 0) return result;
    *info = output.keyInfo;
    return info->dataSize <= 32 ? 0 : -1;
}

static int read_value(const char *name, SMCValue *value) {
    SMCKeyInfo info = {0};
    int result = key_info(name, &info);
    if (result != 0) return result;
    SMCParam input = {0}, output = {0};
    input.key = key_code(name);
    input.keyInfo.dataSize = info.dataSize;
    input.data8 = SMC_READ;
    result = call_smc(&input, &output);
    if (result != 0) return result;
    value->size = info.dataSize;
    value->type = info.dataType;
    memcpy(value->bytes, output.bytes, info.dataSize);
    return 0;
}

static int write_value(const char *name, const uint8_t *bytes, uint32_t size) {
    SMCKeyInfo info = {0};
    int result = key_info(name, &info);
    if (result != 0 || info.dataSize != size) return result != 0 ? result : -1;
    SMCParam input = {0}, output = {0};
    input.key = key_code(name);
    input.keyInfo.dataSize = size;
    input.data8 = SMC_WRITE;
    memcpy(input.bytes, bytes, size);
    return call_smc(&input, &output);
}

static uint16_t be16(const uint8_t *bytes) { return ((uint16_t)bytes[0] << 8) | bytes[1]; }
static uint32_t type_code(const char *type) { return key_code(type); }

static int value_number(const SMCValue *value, double *number) {
    if (value->type == type_code("flt ") && value->size >= 4) {
        float decoded;
        memcpy(&decoded, value->bytes, sizeof(decoded));
        *number = decoded;
        return 0;
    }
    if (value->type == type_code("sp78") && value->size >= 2) {
        *number = (double)((int16_t)be16(value->bytes)) / 256.0;
        return 0;
    }
    if (value->type == type_code("fpe2") && value->size >= 2) {
        *number = (double)be16(value->bytes) / 4.0;
        return 0;
    }
    if (value->type == type_code("ui8 ") && value->size >= 1) { *number = value->bytes[0]; return 0; }
    if (value->type == type_code("ui16") && value->size >= 2) { *number = be16(value->bytes); return 0; }
    return -1;
}

static int read_number(const char *key, double *number) {
    SMCValue value = {0};
    int result = read_value(key, &value);
    if (result != 0) return result;
    return value_number(&value, number);
}

static void fan_key(char out[5], uint32_t fan, char suffix1, char suffix2) {
    snprintf(out, 5, "F%u%c%c", fan, suffix1, suffix2);
}

/// 0 on fanless Macs such as the MacBook Air.
static uint32_t fan_count(void) {
    double count = 0;
    if (read_number("FNum", &count) != 0 || count < 1) return 0;
    return count > 8 ? 8 : (uint32_t)count;
}

int fanbar_read_fan(uint32_t index, FanBarFan *fan) {
    if (!fan) return -1;
    char key[5];
    double rpm, minimum, maximum;
    int result;
    fan_key(key, index, 'A', 'c');
    if ((result = read_number(key, &rpm)) != 0) return result;
    fan_key(key, index, 'M', 'n');
    if ((result = read_number(key, &minimum)) != 0) return result;
    fan_key(key, index, 'M', 'x');
    if ((result = read_number(key, &maximum)) != 0) return result;
    fan->rpm = rpm > 0 ? (uint32_t)rpm : 0;
    fan->minimumRPM = (uint32_t)minimum;
    fan->maximumRPM = (uint32_t)maximum;
    return 0;
}

/// Across all fans: the fastest current speed, the lowest minimum, and the
/// highest maximum. Targets outside a fan's own range are clamped when set.
int fanbar_read_metrics(FanBarMetrics *metrics) {
    if (!metrics) return -1;
    uint32_t count = fan_count();
    if (count == 0) return -1;
    FanBarFan fan;
    int result = fanbar_read_fan(0, &fan);
    if (result != 0) return result;
    metrics->fanCount = count;
    metrics->rpm = fan.rpm;
    metrics->minimumRPM = fan.minimumRPM;
    metrics->maximumRPM = fan.maximumRPM;
    for (uint32_t index = 1; index < count; index++) {
        if (fanbar_read_fan(index, &fan) != 0) continue;
        if (fan.rpm > metrics->rpm) metrics->rpm = fan.rpm;
        if (fan.minimumRPM < metrics->minimumRPM) metrics->minimumRPM = fan.minimumRPM;
        if (fan.maximumRPM > metrics->maximumRPM) metrics->maximumRPM = fan.maximumRPM;
    }
    double temperature = 0;
    result = read_number("TC0P", &temperature);
    if (result != 0) result = read_number("Tp09", &temperature);
    if (result != 0) result = read_number("Tp01", &temperature);
    metrics->temperatureC = result == 0 ? temperature : 0;
    return 0;
}

int fanbar_read_temperature(const char *key, double *celsius) {
    if (!key || !celsius || strlen(key) != 4) return -1;
    SMCValue value = {0};
    int result = read_value(key, &value);
    if (result != 0) return result;
    return value_number(&value, celsius);
}

int fanbar_key_count(uint32_t *count) {
    if (!count) return -1;
    SMCValue value = {0};
    int result = read_value("#KEY", &value);
    if (result != 0) return result;
    if (value.size < 4) return -1;
    *count = ((uint32_t)value.bytes[0] << 24) | ((uint32_t)value.bytes[1] << 16) |
             ((uint32_t)value.bytes[2] << 8) | (uint32_t)value.bytes[3];
    return 0;
}

int fanbar_key_at(uint32_t index, char name[5]) {
    if (!name) return -1;
    SMCParam input = {0}, output = {0};
    input.data8 = SMC_GET_KEY_FROM_INDEX;
    input.data32 = index;
    int result = call_smc(&input, &output);
    if (result != 0) return result;
    name[0] = (char)(output.key >> 24);
    name[1] = (char)(output.key >> 16);
    name[2] = (char)(output.key >> 8);
    name[3] = (char)output.key;
    name[4] = 0;
    return 0;
}

// Fan control. On Apple silicon, thermalmonitord owns the fans: a manual mode
// write may be refused until the Ftst key is set (M1 to M4), and then it takes
// a few seconds to let go. Some models spell the mode key F0md. The approach
// follows the Stats app (github.com/exelban/stats, MIT), SMC/smc.swift.

static int write_with_retry(const char *key, const uint8_t *bytes, uint32_t size, int attempts, useconds_t delay) {
    int result = -1;
    for (int attempt = 0; attempt < attempts; attempt++) {
        if ((result = write_value(key, bytes, size)) == 0) return 0;
        if (attempt + 1 < attempts) usleep(delay);
    }
    return result;
}

/// Writes the first byte of a key, keeping the rest of its current value.
static int write_first_byte(const char *key, uint8_t byte, int attempts, useconds_t delay) {
    SMCValue value = {0};
    int result = read_value(key, &value);
    if (result != 0) return result;
    if (value.size == 0) return -1;
    value.bytes[0] = byte;
    return write_with_retry(key, value.bytes, value.size, attempts, delay);
}

static void mode_key(char out[5], uint32_t fan) {
    static int lowercase = -1;
    if (lowercase < 0) {
        SMCValue probe = {0};
        lowercase = read_value("F0md", &probe) == 0 && probe.size > 0;
    }
    fan_key(out, fan, 'M', 'd');
    if (lowercase) out[3] = 'd', out[2] = 'm';
}

static int unlock_fan(uint32_t fan) {
    char key[5];
    mode_key(key, fan);
    SMCValue mode = {0};
    if (read_value(key, &mode) == 0 && mode.size > 0 && mode.bytes[0] == 1) return 0;
    if (write_first_byte(key, 1, 1, 0) == 0) return 0;

    SMCValue test = {0};
    if (read_value("Ftst", &test) != 0 || test.size == 0) return -1;
    if (test.bytes[0] != 1) {
        int result = write_first_byte("Ftst", 1, 100, 50000);
        if (result != 0) return result;
        usleep(3000000);
    }
    return write_first_byte(key, 1, 300, 100000);
}

static int write_target(uint32_t fan, uint32_t rpm) {
    char key[5];
    fan_key(key, fan, 'T', 'g');
    SMCKeyInfo info = {0};
    int result = key_info(key, &info);
    if (result != 0) return result;
    if (info.dataType == type_code("flt ") && info.dataSize == 4) {
        float target = (float)rpm;
        return write_with_retry(key, (const uint8_t *)&target, 4, 10, 50000);
    }
    // fpe2: unsigned 14.2 fixed point, big endian (Intel).
    uint16_t encoded = (uint16_t)(rpm << 2);
    uint8_t target[2] = {(uint8_t)(encoded >> 8), (uint8_t)encoded};
    return write_with_retry(key, target, 2, 10, 50000);
}

/// Sets every fan to `rpm`, clamped to its own range; `useMaximum` sends each to its own maximum.
static int set_all(uint32_t rpm, int useMaximum) {
    uint32_t count = fan_count();
    int failure = 0;
    for (uint32_t index = 0; index < count; index++) {
        FanBarFan fan;
        if (fanbar_read_fan(index, &fan) != 0) { failure = -1; continue; }
        uint32_t target = useMaximum ? fan.maximumRPM : rpm;
        if (target < fan.minimumRPM) target = fan.minimumRPM;
        if (fan.maximumRPM > 0 && target > fan.maximumRPM) target = fan.maximumRPM;
        int result = unlock_fan(index);
        if (result == 0) result = write_target(index, target);
        if (result != 0) failure = result;
    }
    return failure;
}

int fanbar_set_target_rpm(uint32_t rpm) {
    return set_all(rpm, 0);
}

int fanbar_set_maximum(void) {
    return set_all(0, 1);
}

int fanbar_set_automatic(void) {
    uint32_t count = fan_count();
    int failure = 0;
    for (uint32_t index = 0; index < count; index++) {
        char key[5];
        mode_key(key, index);
        SMCValue mode = {0};
        if (read_value(key, &mode) == 0 && mode.size > 0 && mode.bytes[0] != 0) {
            int result = write_first_byte(key, 0, 10, 50000);
            if (result != 0) failure = result;
        }
    }
    // Hand the fans back to thermalmonitord.
    SMCValue test = {0};
    if (read_value("Ftst", &test) == 0 && test.size > 0 && test.bytes[0] != 0) {
        int result = write_first_byte("Ftst", 0, 10, 50000);
        if (result != 0) failure = result;
    }
    return failure;
}
