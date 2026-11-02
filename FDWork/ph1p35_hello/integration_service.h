#ifndef FINAL1_INTEGRATION_SERVICE_H
#define FINAL1_INTEGRATION_SERVICE_H
#include <stdint.h>
void integration_init(uint32_t now);
/* Returns 1 when a newly applied mode/config requires red tracker reset. */
int integration_poll(uint32_t now);
typedef struct {
    uint32_t seq,generation,frame,r,g,b,count,source,received_ms;
} IntegrationStats;
int integration_get_stats(IntegrationStats *stats);
int integration_measure_ready(void);
void integration_exposure_hold(unsigned hold);
/* Return GPIO sample for the mode-specific MCU menu. */
uint8_t integration_keys(uint8_t raw,uint32_t now);
/* 0 unrecognized, 1 queued, 2 status query, -1 malformed. */
int integration_command(const char *line);
uint32_t integration_mode(void);
int integration_tracking_ready(void);
unsigned integration_page(void);
void motion_reset(void);
uint8_t motion_process(uint8_t valid,const uint32_t input[4],unsigned hold,int y_offset,uint32_t output[4]);

/* Option B unified HUD helpers */
uint32_t integration_get_mode(void);
void integration_set_mode(uint32_t m);
void integration_get_active_params(uint32_t *p1, uint32_t *p2, uint32_t *p3);
void integration_adjust_param(int slot, int dir);
/* Settled control-domain snapshot, not an HDMI source-frame ownership tag. */
typedef struct {uint32_t config,motion,extra;} IntegrationHud;
int integration_get_hud(IntegrationHud *out);
#endif
