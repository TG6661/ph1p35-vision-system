#include <assert.h>
#include <stdio.h>
#include <string.h>
#include "fabric_regs.h"
#include "menu_control.h"
#include "menu_display.h"
#include "integration_service.h"
#include "gimbal_track.h"
#include "exposure_service.h"
uint32_t fabric_test_mmio[512];
ExposureState g_exposure;
int exposure_set_enabled(unsigned v) {g_exposure.enabled=!!v;return 1;}
void motion_reset(void) {}
uint8_t motion_process(uint8_t v,const uint32_t in[4],unsigned h,int o,uint32_t out[4]) {
    (void)h;(void)o;memcpy(out,in,16);return v;
}
static unsigned now,auto_complete=1,tear_after,vectors;
static uint32_t pending_config,words[3];
static Menu menu;
static MenuDisplay display;
static void complete_config(void) {
    FABRIC_REG(0x198)=FABRIC_REG(0x194);FABRIC_REG(0x19c)=pending_config;FABRIC_REG(0x190)=0;
}
void fabric_test_fence(void) {
    if(tear_after && --tear_after==0) FABRIC_REG(0x198)++;
    if(FABRIC_REG(0x18c)==1) {
        FABRIC_REG(0x18c)=0;FABRIC_REG(0x194)++;FABRIC_REG(0x190)=1;
        pending_config=FABRIC_REG(0x188);if(auto_complete)complete_config();
    }
    if(REG_HUD_COMMAND==5) {
        REG_HUD_COMMAND=0;REG_HUD_ACCEPTED++;REG_HUD_COMPLETED=REG_HUD_ACCEPTED;
        words[0]=REG_HUD_WORD0;words[1]=REG_HUD_WORD1;words[2]=REG_HUD_WORD2;
    }
}
static void flush(void) {integration_poll(now+=5);integration_poll(now+=5);assert(integration_measure_ready());}
static void raw(unsigned v,unsigned duration) {while(duration--)menu_sample(&menu,(uint8_t)v,++now);}
static void key(unsigned v) {raw(v,25);raw(15,25);}
static unsigned bcd(unsigned v) {return (v/10)*16+v%10;}
static void hud(FILE *f) {
    REG_MENU_COMPLETED_CAMERA=menu_camera(&menu);REG_MENU_COMPLETED_UI=menu_ui(&menu);
    REG_THRESH_SELECTED=menu_rgb(&menu);menu_display_poll(&display);
    if(f){fprintf(f,"%08x %08x %08x\n",words[2],words[1],words[0]);vectors++;}
}
int main(int argc,char **argv) {
    assert(argc==2);FILE *f=fopen(argv[1],"w");assert(f);
    REG_SERVO_ABI=SERVO_ABI;REG_HUD_STATUS=8;REG_MENU_STATUS=4;
    FABRIC_REG(0x19c)=256u<<9;FABRIC_REG(0x184)=255;
    integration_init(0);gimbal_track_init();menu_init(&menu,0);menu_display_init(&display);flush();
    const unsigned order[]={MENU_MODE,MENU_EXPOSURE,MENU_AE,MENU_AG,MENU_BL,MENU_BO,MENU_P1,MENU_P2,MENU_P3,MENU_TRACK};
    for(unsigned mode=0;mode<3;mode++) {
        integration_set_mode(mode);menu.selected=MENU_MODE;
        unsigned count=mode==2?8:(mode==1?9:10);
        for(unsigned i=1;i<=count;i++){key(13);assert(menu.selected==order[i%count]);}
        for(unsigned i=1;i<=count;i++){key(14);assert(menu.selected==order[(count-i)%count]);}
        assert(menu_command(&menu,"select GMR",now)==-2);
        if(mode==2){assert(menu_command(&menu,"select P3",now)==-1);assert(menu_command(&menu,"value P3 1",now)==-1);}
        if(mode){assert(menu_command(&menu,"select TRACK",now)==-1);assert(menu_command(&menu,"value TRACK 1",now)==-1);}
    }
    // A scheduling/debugger gap during one physical press must not create
    // another DOWN edge when sampling resumes.
    for(unsigned mode=0;mode<3;mode++) for(unsigned direction=0;direction<2;direction++) {
        integration_set_mode(mode);menu.selected=MENU_MODE;
        unsigned count=mode==2?8:(mode==1?9:10);
        unsigned held_key=direction?13:14;
        unsigned first=direction?1:count-1;
        raw(held_key,25);assert(menu.selected==order[first]);
        for(unsigned gap=51;gap<300;gap+=70) {
            now+=gap;raw(held_key,25);assert(menu.selected==order[first]);
        }
        // A short release bounce cannot re-arm the same physical press.
        raw(15,5);raw(held_key,25);assert(menu.selected==order[first]);
        raw(15,25);key(held_key);
        assert(menu.selected==order[direction?2:count-2]);
    }
    // A fresh press arriving during a gap still requires observed debounce.
    integration_set_mode(0);menu.selected=MENU_MODE;
    now+=60;raw(13,10);assert(menu.selected==MENU_MODE);
    raw(13,15);assert(menu.selected==MENU_EXPOSURE);raw(15,25);
    integration_set_mode(0);menu.selected=MENU_TRACK;raw(11,25);assert(gimbal_track_enabled());
    integration_set_mode(1);raw(11,1500);assert(menu.selected==MENU_MODE && integration_get_mode()==1);
    raw(15,25);key(11);assert(integration_get_mode()==2);
    // STYLE retires P3 even if the key remains held across an external mode change.
    integration_set_mode(1);menu.selected=MENU_P3;raw(11,25);
    integration_set_mode(2);raw(11,1500);assert(menu.selected==MENU_MODE && integration_get_mode()==2);
    raw(15,25);key(7);assert(integration_get_mode()==1);
    // Fixed GMR remains ABI-compatible, but never receives the cursor.
    assert(menu_command(&menu,"value GMR 55",now)==-2);
    assert(menu_command(&menu,"value GMR 70",now)==1);
    gimbal_track_set_enabled(0);menu.selected=MENU_MODE;
    integration_set_mode(0);gimbal_track_set_enabled(1);flush();hud(f);assert((words[2]>>29&3)==0 && !(words[0]>>28&1));
    integration_set_mode(1);flush();hud(f);assert((words[1]&127)==5 && (words[2]>>4&255)==0x20 && (words[2]&15)==3);
    integration_set_mode(2);assert(integration_command("style fx 5")==1);flush();hud(f);
    assert((words[0]>>28&1) && (words[1]>>20&4095)==5);
    // Preserve the old visible snapshot until the whole mode transaction applies.
    uint32_t old_sequence=REG_HUD_ACCEPTED;
    auto_complete=0;integration_set_mode(1);integration_poll(now+=5);hud(NULL);
    assert(REG_HUD_ACCEPTED==old_sequence);
    complete_config();integration_poll(now+=5);auto_complete=1;hud(NULL);assert(REG_HUD_ACCEPTED>old_sequence);
    IntegrationHud snap;uint32_t gen=FABRIC_REG(0x198);tear_after=2;
    assert(!integration_get_hud(&snap));FABRIC_REG(0x198)=gen;
    for(unsigned minimum=1;minimum<=63;minimum++) {
        char cmd[40];snprintf(cmd,sizeof(cmd),"motion min %u",minimum);assert(integration_command(cmd)==1);
        unsigned dwell=5+(minimum%56);snprintf(cmd,sizeof(cmd),"motion dwell %u",dwell);assert(integration_command(cmd)==1);
        snprintf(cmd,sizeof(cmd),"motion mask %u",minimum&1);assert(integration_command(cmd)==1);
        assert(integration_command(minimum&1?"display auto":"display fixed")==1);
        flush();hud(f);
        assert((words[1]&127)==bcd(minimum));assert((words[2]>>4&255)==bcd(dwell));
        assert((words[0]>>28&1)==(minimum&1) && (words[0]>>29&1)==(minimum&1));
        assert((words[0]>>30)==0 && (words[2]&15)==3);
    }
    assert(integration_command("motion mask 1")==1);integration_exposure_hold(1);flush();hud(NULL);
    assert(!(words[0]>>29&1));integration_exposure_hold(0);flush();hud(NULL);assert(words[0]>>29&1);
    integration_set_mode(2);
    for(unsigned fx=0;fx<6;fx++)for(unsigned cl=0;cl<3;cl++)for(unsigned awb=0;awb<2;awb++) {
        char cmd[32];snprintf(cmd,sizeof(cmd),"style fx %u",fx);assert(integration_command(cmd)==1);
        snprintf(cmd,sizeof(cmd),"style cl %u",cl);assert(integration_command(cmd)==1);
        snprintf(cmd,sizeof(cmd),"style auto %u",awb);assert(integration_command(cmd)==1);
        g_exposure.enabled=cl&1;menu.selected=MENU_P1;flush();hud(f);
        assert((words[1]>>20&4095)==fx && (words[2]&4095)==cl && (words[2]>>12&4095)==0);
        assert((words[0]>>28&1)==awb && (words[1]>>7&1)==(cl&1));
    }
    // A newly desired FX must not appear before its config is submitted/applied.
    old_sequence=REG_HUD_ACCEPTED;assert(integration_command("style fx 0")==1);hud(NULL);
    assert(REG_HUD_ACCEPTED==old_sequence);flush();hud(NULL);assert(REG_HUD_ACCEPTED>old_sequence);
    menu.selected=MENU_AE;g_exposure.enabled=1;key(7);assert(!g_exposure.enabled);
    // Reloading the MCU does not reset FPGA state or the last displayed HUD.
    // Reproduce a stale STYLE panel with a previously accepted MOTION switch.
    integration_set_mode(2);flush();hud(NULL);assert((words[2]>>29&3)==2);
    auto_complete=0;integration_set_mode(1);integration_poll(now+=5);
    assert(FABRIC_REG(0x190)&1u);
    integration_init(now);menu_init(&menu,now);menu_display_init(&display);
    assert(!integration_measure_ready());
    complete_config();auto_complete=1;flush();hud(NULL);
    assert(integration_get_mode()==0 && integration_mode()==0 && (words[2]>>29&3)==0);
    integration_set_mode(2);flush();hud(NULL);
    menu.selected=MENU_P1;key(11);flush();hud(NULL);
    assert((words[2]>>29&3)==2 && (words[1]>>20&4095)==1);
    for(unsigned retained=0;retained<3;retained++) {
        integration_set_mode(retained);flush();hud(NULL);
        uint32_t old_gen=FABRIC_REG(0x198);
        integration_init(now);menu_init(&menu,now);menu_display_init(&display);
        assert(!integration_measure_ready() && !integration_tracking_ready());
        flush();hud(NULL);
        assert(FABRIC_REG(0x198)>old_gen && integration_mode()==0 && (words[2]>>29&3)==0);
    }
    fclose(f);printf("MODE_MENU_HOST_PASS: 3 mode navigation, 24 held-key sampling gaps + bounce + fresh-press debounce, MCU restart in all modes + in-flight switch + FX after restart, hidden/readonly rejection, held-key mode change, applied/generation snapshots, MIN1..63, DWELL5..60, 36 STYLE combinations, %u C-to-RTL vectors\n",vectors);
    return 0;
}
