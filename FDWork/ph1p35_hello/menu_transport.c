#include "menu_transport.h"
#include "fabric_regs.h"
#include <string.h>
#define MENU_COOKIE UINT32_C(0x4d454e33)
void menu_transport_init(MenuTransport *t) {
    memset(t,0,sizeof(*t));REG_SCRATCH0=MENU_COOKIE;fabric_fence();
}
unsigned menu_transport_service(MenuTransport *t,Menu *m,uint32_t now) {
    unsigned events=0;
    fabric_fence();
    if(REG_SCRATCH0!=MENU_COOKIE) {
        // A video reset can clear Fabric without restarting the processor.
        menu_init(m,now);menu_transport_init(t);events|=TRANS_RESET;
    }
    if(t->menu_pending && !(REG_MENU_STATUS&1u)) {
        if(REG_MENU_APPLIED_SEQ==t->menu_seq && REG_MENU_ACCEPTED_SEQ==t->menu_seq)
            events|=TRANS_MENU_ACK;
        else {t->menu_sent=0;events|=TRANS_REJECT;}
        t->menu_pending=0;
    }
    if(t->rgb_pending) {
        if(!(REG_THRESH_STATUS&1u)) {
            if(REG_APPLIED_SEQ==t->rgb_seq && REG_ACCEPTED_SEQ==t->rgb_seq)
                events|=TRANS_RGB_APPLIED;
            else {t->rgb_sent=0;events|=TRANS_REJECT;}
            t->rgb_pending=0;
        } else if(!t->warned && (uint32_t)(now-t->rgb_start)>=2000) {
            t->warned=1;events|=TRANS_RGB_WAIT;
        }
    }
    uint32_t camera=menu_camera(m),ui=menu_ui(m),rgb=menu_rgb(m);
    if(!t->menu_pending && (REG_MENU_STATUS&9u)==8u &&
       (!t->menu_sent || camera!=t->camera || ui!=t->ui)) {
        uint32_t before=REG_MENU_ACCEPTED_SEQ;
        REG_MENU_CAMERA=camera;REG_MENU_UI=ui;fabric_fence();
        REG_MENU_COMMAND=5u;fabric_fence();
        t->menu_seq=REG_MENU_ACCEPTED_SEQ;
        if(t->menu_seq!=before) {
            t->camera=camera;t->ui=ui;t->menu_sent=1;t->menu_pending=1;
        } else events|=TRANS_REJECT;
    }
    if(!t->rgb_pending && !(REG_THRESH_STATUS&1u) && (!t->rgb_sent || rgb!=t->rgb)) {
        uint32_t before=REG_ACCEPTED_SEQ;
        REG_THRESH_SHADOW=rgb;fabric_fence();REG_THRESH_COMMAND=7u;fabric_fence();
        t->rgb_seq=REG_ACCEPTED_SEQ;
        if(t->rgb_seq!=before) {
            t->rgb=rgb;t->rgb_sent=1;t->rgb_pending=1;t->warned=0;t->rgb_start=now;
        } else events|=TRANS_REJECT;
    }
    return events;
}
