#include "camera_service.h"
#include "fabric_regs.h"
#include "sc520_regs.h"
#include <string.h>
enum { C_DRAIN,C_CLEAR,C_IDH,C_IDL,C_CHECK,C_TABLE,C_DELAY,C_BEGIN,
       C_GROUP,C_FINISH,C_IDLE,C_FAULT,C_RETRY_WAIT };
int camera_service_ready(const CameraService *s) {
    return !s->fault && !s->timeouts && !s->pending && s->have_applied && s->phase==C_IDLE;
}
uint32_t camera_gain_code(unsigned gain) {
    static const uint8_t analog[]={0,8,9,11,15,31,31};
    unsigned step=gain<=16?0:gain>=239?223:gain-16;
    return ((uint32_t)analog[step/32]<<16) | (step>=192?0x100u:0u) |
           (0x80u+4u*(step%32));
}
uint32_t camera_group_word(unsigned index,unsigned ae,unsigned gain) {
    uint32_t code=camera_gain_code(gain);
    switch(index) {
    case 0:return 0x381200u;
    case 1:return 0x3e0000u|((ae>>12)&15u);
    case 2:return 0x3e0100u|((ae>>4)&255u);
    case 3:return 0x3e0200u|((ae&15u)<<4);
    case 4:return 0x3e0900u|(code>>16);
    case 5:return 0x3e0600u|((code>>8)&255u);
    case 6:return 0x3e0700u|(code&255u);
    case 7:return 0x381230u;
    default:return 0;
    }
}
void camera_service_init(CameraService *s,uint32_t now) {
    memset(s,0,sizeof(*s));s->phase=C_DRAIN;s->started=now;
}
static void fail(CameraService *s) {s->fault=1;s->phase=C_FAULT;}
static int issue(CameraService *s,uint32_t now,uint32_t word,unsigned mode,unsigned next) {
    uint32_t status=REG_CAM_STATUS;
    if((status&9u)!=8u) return 0;
    uint32_t before=REG_CAM_ACCEPTED;
    if(mode==8u) REG_CAM_STATE=s->state_word;
    else {REG_CAM_ADDR=word>>8;REG_CAM_DATA=word&255u;}
    fabric_fence();REG_CAM_COMMAND=5u|mode;fabric_fence();
    s->sequence=REG_CAM_ACCEPTED;
    if(s->sequence==before) {fail(s);return 0;} // no automatic retry
    s->pending=1;s->next_phase=(uint8_t)next;s->started=now;return 1;
}
void camera_service_poll(CameraService *s,const Menu *m,uint32_t now) {
    fabric_fence();
    if(s->fault) return;
    if(s->pending) {
        // Check completion before time: a debugger pause is not an I2C timeout
        // if the hardware has already finished this exact transaction.
        if(!(REG_CAM_STATUS&1u) && REG_CAM_COMPLETED==s->sequence &&
           REG_CAM_ACCEPTED==s->sequence) {
            unsigned nack=!!(REG_CAM_STATUS&16u);
            if(nack) {
                s->errors++;
                s->last_error_word=(REG_CAM_ADDR<<8)|(REG_CAM_DATA&255u);
                s->last_error_ms=now;s->last_error_phase=s->phase;s->last_error_index=s->index;
                s->state_word|=8u;
                if(s->phase==C_GROUP) s->group_failed=1;
                else {
                    // Initialization/ID failures cannot be repaired by merely
                    // rewriting exposure. Do not continue with partial setup.
                    s->pending=0;s->have_applied=0;fail(s);return;
                }
            }
            if(s->phase==C_IDH) s->sensor_id=(uint16_t)((REG_CAM_READ_DATA&255u)<<8);
            if(s->phase==C_IDL) s->sensor_id|=(uint16_t)(REG_CAM_READ_DATA&255u);
            if(s->phase==C_TABLE) {
                if(s->index++==0) s->deadline=now+5u;
            }
            if(s->phase==C_GROUP) ++s->index;
            if(s->phase==C_FINISH) {
                s->applied_ae=s->ae;s->applied_ag=s->ag;s->have_applied=1;s->groups++;
            }
            s->pending=0;s->phase=s->next_phase;
        } else if((uint32_t)(now-s->started)>=100u) {
            // Leave physical busy/ownership intact. Never resend a timed-out
            // write or start another group over a transaction still in flight.
            s->timeouts++;fail(s);
        }
        return;
    }
    switch(s->phase) {
    case C_DRAIN:
        // CPU-only restart: drain an old command before soft-resetting sensor.
        if((REG_CAM_STATUS&9u)==8u) s->phase=C_CLEAR;
        else if((uint32_t)(now-s->started)>=1000u) {s->timeouts++;fail(s);}
        break;
    case C_CLEAR:issue(s,now,0,8,C_IDH);break;
    case C_IDH:issue(s,now,0x310700u,2,C_IDL);break;
    case C_IDL:issue(s,now,0x310800u,2,C_CHECK);break;
    case C_CHECK:
        if((s->sensor_id!=0xee4b && s->sensor_id!=0x9e4b) || s->errors) {fail(s);break;}
        s->state_word=((uint32_t)s->sensor_id<<16)|4u;
        s->index=0;s->phase=C_TABLE;break;
    case C_TABLE:
        if(s->index==SC520_INIT_REG_COUNT) {s->phase=C_BEGIN;break;}
        issue(s,now,sc520_init_regs[s->index],0,s->index==0?C_DELAY:C_TABLE);break;
    case C_DELAY:
        if((int32_t)(now-s->deadline)>=0) s->phase=C_TABLE;
        break;
    case C_BEGIN:
        // Freeze both values for all eight group writes. New wishes coalesce.
        s->ae=m->ae;s->ag=m->ag;s->index=0;
        s->have_applied=0;s->group_failed=0;s->group_retries=0;
        s->state_word&=~2u;
        issue(s,now,0,8,C_GROUP);break;
    case C_GROUP:
        if(s->index==8) {
            // Finish the release write even after an earlier NACK. Retry only
            // after the whole attempt completed, with the same frozen values.
            if(s->group_failed) {
                if(s->group_retries>=CAMERA_GROUP_MAX_RETRIES) {fail(s);break;}
                s->group_retries++;s->retries++;s->index=0;s->group_failed=0;
                s->deadline=now+5u;s->phase=C_RETRY_WAIT;
            } else {
                s->state_word|=3u;if(s->errors) s->state_word|=8u;
                s->phase=C_FINISH;
            }
        } else issue(s,now,camera_group_word(s->index,s->ae,s->ag),0,C_GROUP);
        break;
    case C_RETRY_WAIT:
        if((int32_t)(now-s->deadline)>=0) s->phase=C_GROUP;
        break;
    case C_FINISH:issue(s,now,0,8,C_IDLE);break;
    case C_IDLE:
        if(!s->have_applied || m->ae!=s->applied_ae || m->ag!=s->applied_ag) s->phase=C_BEGIN;
        break;
    default:fail(s);break;
    }
}
