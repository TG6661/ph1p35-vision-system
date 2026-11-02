#ifndef FINAL1_GIMBAL_TRACK_H
#define FINAL1_GIMBAL_TRACK_H
#include "target_service.h"
/* PD incremental control per accepted detection update (not per video frame).
 * Positions/steps use milli-microseconds to retain fractional tilt steps. */
enum {
    TRACK_MODE_OFF = 0,
    TRACK_MODE_PATROL = 1
};
#define TRACK_MODE_ON TRACK_MODE_PATROL
typedef struct {
    int32_t position[2],kp[2],kd[2],step[2],patrol_step;
    int16_t previous[2];
    uint16_t inner[2],outer[2],wanted[2],patrol_min,patrol_max;
    uint32_t sequence;
    uint8_t supported,enabled,any_shape,armed,have_sequence,has_target;
    uint8_t dead[2],dirty,target_id,target_shape,mode,patrol_dir,patrol_active;
} GimbalTrack;
extern GimbalTrack g_track;
void gimbal_track_set_logger(void (*fn)(const char *,...));
void gimbal_track_init(void);
void gimbal_track_set_mode(unsigned mode);
unsigned gimbal_track_mode(void);
void gimbal_track_set_enabled(unsigned enabled);
unsigned gimbal_track_enabled(void);
void gimbal_track_invalidate(void);
void gimbal_track_poll(const TargetService *targets,uint32_t now);
/* 0 not ours, 1 handled, -1 malformed; parser never partially applies errors. */
int gimbal_track_command(const char *line);
void gimbal_track_status(void);
void gimbal_track_help(void);
#endif
