#include <stdint.h>

typedef struct {
    double temperatureC;
    uint32_t rpm;
    uint32_t minimumRPM;
    uint32_t maximumRPM;
    uint32_t fanCount;
} FanBarMetrics;

int fanbar_read_metrics(FanBarMetrics *metrics);
int fanbar_read_temperature(const char *key, double *celsius);
int fanbar_set_automatic(void);
int fanbar_set_target_rpm(uint32_t rpm);
