#ifndef OOP_CAMERA_SERVICE_H
#define OOP_CAMERA_SERVICE_H
#include "menu_control.h"
typedef struct {
    uint32_t sequence,started,deadline,errors,timeouts,groups;
    uint32_t state_word;
    uint16_t sensor_id,ae,applied_ae;
    uint8_t ag,applied_ag,phase,next_phase,pending,index,have_applied,fault;
    /* Historical diagnostics survive a successful retry. Applied values are
     * valid only after all eight sensor writes in one attempt were ACKed. */
    uint32_t retries,last_error_word,last_error_ms;
    uint8_t group_failed,group_retries,last_error_phase,last_error_index;
} CameraService;
enum { CAMERA_GROUP_MAX_RETRIES = 2 };
int camera_service_ready(const CameraService *service);
/* One poll advances at most one transaction. No sleeps or busy loops. */
void camera_service_init(CameraService *s,uint32_t now);
void camera_service_poll(CameraService *s,const Menu *m,uint32_t now);
uint32_t camera_gain_code(unsigned gain);
uint32_t camera_group_word(unsigned index,unsigned ae,unsigned gain);
#endif
