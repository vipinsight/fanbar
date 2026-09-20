#include "SMCBridge.h"
#include <IOKit/IOKitLib.h>
#include <mach/mach.h>
#include <string.h>

enum { SMC_CALL = 2, SMC_READ = 5, SMC_WRITE = 6, SMC_READ_KEY_INFO = 9 };

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

int fanbar_read_metrics(FanBarMetrics *metrics) {
    if (!metrics) return -1;
    SMCValue count = {0}, temp = {0}, rpm = {0}, min = {0}, max = {0};
    int result = read_value("FNum", &count);
    if (result != 0) return result;
    if ((result = read_value("F0Ac", &rpm)) != 0) return result;
    if ((result = read_value("F0Mn", &min)) != 0) return result;
    if ((result = read_value("F0Mx", &max)) != 0) return result;
    result = read_value("TC0P", &temp);
    if (result != 0) result = read_value("Tp09", &temp);
    if (result != 0) result = read_value("Tp01", &temp);
    if (result != 0) return result;
    double countNumber, tempNumber, rpmNumber, minNumber, maxNumber;
    if (value_number(&count, &countNumber) != 0 || value_number(&temp, &tempNumber) != 0 ||
        value_number(&rpm, &rpmNumber) != 0 || value_number(&min, &minNumber) != 0 || value_number(&max, &maxNumber) != 0) return -1;
    metrics->fanCount = (uint32_t)countNumber;
    metrics->temperatureC = tempNumber;
    metrics->rpm = (uint32_t)rpmNumber;
    metrics->minimumRPM = (uint32_t)minNumber;
    metrics->maximumRPM = (uint32_t)maxNumber;
    return 0;
}

int fanbar_set_automatic(void) {
    uint8_t mode = 0;
    return write_value("F0Md", &mode, 1);
}

int fanbar_set_target_rpm(uint32_t rpm) {
    uint8_t mode = 1;
    int result = write_value("F0Md", &mode, 1);
    if (result != 0) return result;
    SMCKeyInfo info = {0};
    result = key_info("F0Tg", &info);
    if (result != 0) return result;
    if (info.dataType == type_code("flt ") && info.dataSize == 4) {
        float target = (float)rpm;
        return write_value("F0Tg", (const uint8_t *)&target, 4);
    }
    uint8_t target[2] = {(uint8_t)(rpm >> 8), (uint8_t)rpm};
    return write_value("F0Tg", target, 2);
}
