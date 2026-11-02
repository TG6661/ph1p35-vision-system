#include "menu_display.h"
#include "menu_control.h"
#include "fabric_regs.h"
#include "integration_service.h"
#include "gimbal_track.h"
#include "exposure_service.h"
#include <string.h>
static uint32_t bcd(unsigned n) {
    uint32_t value=0;
    for(unsigned shift=0;shift<16;shift+=4) {value|=(n%10u)<<shift;n/=10u;}
    return value;
}
void menu_display_pack(uint32_t camera,uint32_t ui,uint32_t rgb,uint32_t w[3]) {
    // AE[15:0], AG[27:16], fixed GMR[38:28], AUTO EXP[39], BO[51:40], RMIN[63:52],
    // RGAP[75:64], BGAP[87:76], selection[91:88], BL[92], mode[94:93].
    // Runtime poll adds the shared tracking-enable flag in bit95.
    uint32_t gamma=bcd(MENU_GAMMA_FIXED_HUNDREDTHS);
    w[0]=bcd(camera&65535u)|(bcd((camera>>16)&255u)<<16)|(gamma<<28);
    w[1]=(gamma>>4)|(bcd((ui>>2)&255u)<<8)|(bcd((rgb>>16)&255u)<<20);
    w[2]=bcd((rgb>>8)&255u)|(bcd(rgb&255u)<<12)|
         (((ui>>15)&15u)<<24)|(((ui>>10)&1u)<<28)|(3u<<29); // Fixed STRONG, including stale legacy UI words.
}
void menu_display_pack_mode(uint32_t camera,uint32_t ui,uint32_t mode,uint32_t p1,uint32_t p2,uint32_t p3,uint32_t w[3]) {
    // Bits38:28 now hold status metadata; Gamma labels are mode-owned RTL constants.
    w[0]=bcd(camera&65535u)|(bcd((camera>>16)&255u)<<16);
    w[1]=(bcd((ui>>2)&255u)<<8)|(bcd(p1&255u)<<20);
    w[2]=bcd(p2&255u)|(bcd(p3&255u)<<12)|
         (((ui>>15)&15u)<<24)|(((ui>>10)&1u)<<28)|((mode&3u)<<29);
}
void menu_display_init(MenuDisplay *s) {memset(s,0,sizeof(*s));}
void menu_display_poll(MenuDisplay *s) {
    fabric_fence();
    if(s->pending) {
        if(REG_HUD_STATUS&1u) return;
        if(REG_HUD_ACCEPTED!=s->sequence || REG_HUD_COMPLETED!=s->sequence) s->sent=0;
        s->pending=0;
    }
    if((REG_HUD_STATUS&9u)!=8u || !(REG_MENU_STATUS&4u)) return;
    // Display the control-domain accepted values, not a newer unsent wish.
    // RGB remains the independently selected value, not a displayed-frame tag.
    uint32_t seq=REG_MENU_APPLIED_SEQ;
    uint32_t camera=REG_MENU_COMPLETED_CAMERA,ui=REG_MENU_COMPLETED_UI;
    uint32_t rgb=REG_THRESH_SELECTED;
    fabric_fence();if(seq!=REG_MENU_APPLIED_SEQ) return;

    IntegrationHud status;
    if(!integration_get_hud(&status)) return;
    uint32_t mode=status.config&3u;
    uint32_t p1=(rgb>>16)&255u;
    uint32_t p2=(rgb>>8)&255u;
    uint32_t p3=rgb&255u;
    if(mode==1) {
        p1=status.motion&255u;p2=(status.motion>>8)&7u;p3=(status.motion>>17)&31u;
    } else if(mode==2) {
        p1=final1_fx_decode(status.config);p2=(status.config>>6)&3u;p3=(status.config>>2)&3u;
    }

    uint32_t w[3];menu_display_pack_mode(camera,ui,mode,p1,p2,p3,w);
    w[0]|=((status.config>>8)&1u)<<28; // Actual display AWB selection, all modes.
    if(mode==1) {
        uint32_t minimum=bcd((status.motion>>11)&63u);
        w[0]|=((status.extra>>3)&1u)<<29;
        w[1]|=minimum&127u; // [38:32], tens 0..6 and units 0..9.
        // NEIG is one BCD digit. Its two spare digits carry DWELL (05..60).
        w[2]=(w[2]&~UINT32_C(0x00000ff0))|((bcd((status.extra>>16)&255u)&255u)<<4);
    }
    w[2]|=(uint32_t)gimbal_track_enabled()<<31; // HUD bit95; held through existing mailbox.
    w[1]|=(uint32_t)g_exposure.enabled<<7; // HUD bit39: unused fixed-GMR digit bit.
    if(s->sent && !memcmp(w,s->words,sizeof(w))) return;
    uint32_t before=REG_HUD_ACCEPTED;
    REG_HUD_WORD0=w[0];REG_HUD_WORD1=w[1];REG_HUD_WORD2=w[2];
    fabric_fence();REG_HUD_COMMAND=5u;fabric_fence();
    s->sequence=REG_HUD_ACCEPTED;
    if(s->sequence!=before) {memcpy(s->words,w,sizeof(w));s->sent=1;s->pending=1;}
}
