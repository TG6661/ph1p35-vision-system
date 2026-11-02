#ifndef FINAL1_EXPOSURE_SERVICE_H
#define FINAL1_EXPOSURE_SERVICE_H
#include "camera_service.h"
#include "integration_service.h"
typedef struct {
    unsigned enabled,supported,state,mean,coverage,target,updates;
    unsigned filtered,filter_valid,stable,locked,severe;
    uint32_t seq,generation,groups,settle_ms,min_frame,last_step,severe_since;
    uint32_t last_stats_ms,session_ms;
    unsigned seen_enabled,seen_mode,seen_bl,seen_bo;
} ExposureState;
extern ExposureState g_exposure;
void exposure_init(uint32_t now);
int exposure_set_enabled(unsigned enabled);
/* 1 handled (including status), 0 unrelated, -1 invalid/unsupported. */
int exposure_command(const char *line);
void exposure_poll(Menu *menu,const CameraService *camera,uint32_t now);
/* Returns 1 for a new bounded pair, 0 when already at target/limit. */
int exposure_choose(unsigned ae,unsigned ag,unsigned mean,unsigned target,
                    unsigned coverage,unsigned ae_max,unsigned *next_ae,unsigned *next_ag);
unsigned exposure_gain_q8(unsigned ag);
#endif
