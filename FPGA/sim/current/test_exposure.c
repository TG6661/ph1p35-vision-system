#include <assert.h>
#include <stdio.h>
#include <string.h>
#include "exposure_service.h"
#include "fabric_regs.h"
#include "gimbal_track.h"
#include "menu_display.h"
uint32_t fabric_test_mmio[512];
static unsigned resets,writes;static uint32_t written[64];
void motion_reset(void) {resets++;}
uint8_t motion_process(uint8_t v,const uint32_t in[4],unsigned h,int o,uint32_t out[4]) {
    (void)h;(void)o;memcpy(out,in,16);return v;
}
void fabric_test_fence(void) {
    if(FABRIC_REG(0x18c)==1) {
        FABRIC_REG(0x18c)=0;FABRIC_REG(0x194)++;FABRIC_REG(0x198)=FABRIC_REG(0x194);
        FABRIC_REG(0x19c)=FABRIC_REG(0x188);
    }
    if(REG_CAM_COMMAND) {
        unsigned cmd=REG_CAM_COMMAND;REG_CAM_COMMAND=0;
        REG_CAM_ACCEPTED++;REG_CAM_COMPLETED=REG_CAM_ACCEPTED;REG_CAM_STATUS=8;
        if(!(cmd&8u) && writes<64) written[writes++]=(REG_CAM_ADDR<<8)|REG_CAM_DATA;
    }
}
static Menu menu;static CameraService cam;
static void setup(void) {
    memset(fabric_test_mmio,0,sizeof(fabric_test_mmio));writes=resets=0;
    FABRIC_REG(0x184)=31;REG_SERVO_ABI=SERVO_ABI;REG_CAM_STATUS=8;
    integration_init(0);exposure_init(0);menu_init(&menu,0);gimbal_track_init();
    memset(&cam,0,sizeof(cam));cam.phase=10;cam.have_applied=1;cam.groups=1;
    cam.ae=cam.applied_ae=menu.ae;cam.ag=cam.applied_ag=menu.ag;
    FABRIC_REG(0x19c)=256u<<9;
    // Complete the explicit boot configuration before measuring steady-state AE.
    // Production must not meter against FPGA state retained across an MCU reload.
    assert(!integration_measure_ready());
    integration_poll(0);integration_poll(0);assert(integration_measure_ready());
}
static void stats(unsigned seq,unsigned frame,unsigned y,unsigned count,unsigned now) {
    FABRIC_REG(0x400)=seq;FABRIC_REG(0x404)=FABRIC_REG(0x198);
    FABRIC_REG(0x408)=frame;FABRIC_REG(0x41c)=seq;
    FABRIC_REG(0x40c)=FABRIC_REG(0x410)=FABRIC_REG(0x414)=y*count+1;
    FABRIC_REG(0x418)=count;integration_poll(now);exposure_poll(&menu,&cam,now);
    // The real main loop keeps polling between statistics arrivals. In
    // particular, sensor-group and generation acknowledgements can both be
    // observed in the same millisecond; neither bypasses the 80 ms settle gate.
    exposure_poll(&menu,&cam,now);
}
static void applied(unsigned now) {
    for(unsigned i=0;i<40;i++) camera_service_poll(&cam,&menu,now+i);
    assert(cam.applied_ae==menu.ae && cam.applied_ag==menu.ag);
}
static void key(unsigned raw,unsigned *now) {
    for(unsigned i=0;i<25;i++) menu_sample(&menu,(uint8_t)raw,++*now);
}
int main(void) {
    unsigned a,g,n=230400;
    setup();integration_set_mode(2);menu.selected=6;
    unsigned kt=10,fxp,clp,lscp,hw[3];
    for(unsigned i=0;i<6;i++) {key(11,&kt);key(15,&kt);}
    integration_get_active_params(&fxp,&clp,&lscp);assert(fxp==5);
    menu_display_pack_mode(0,0,2,fxp,clp,lscp,hw);assert(((hw[1]>>20)&4095u)==5 && ((hw[2]>>29)&3u)==2);
    key(7,&kt);key(15,&kt);integration_get_active_params(&fxp,&clp,&lscp);assert(fxp==4);
    puts("NEGATIVE_MENU_KEYS_AND_HUD_PACK_PASS");

    /* Faster cadence still waits for the whole ACKed sensor group, 80 ms,
     * a post-update source frame and at least 100 ms since the last step. */
    setup();exposure_set_enabled(1);stats(1,10,200,n,10);
    stats(2,20,200,n,89);assert(g_exposure.updates==0); // 79 ms settling
    stats(3,21,200,n,99);assert(g_exposure.updates==0); // 99 ms step gate
    exposure_poll(&menu,&cam,100);assert(g_exposure.updates==1);
    unsigned rate_ag=menu.ag;
    stats(4,30,200,n,200);assert(g_exposure.updates==1 && menu.ag==rate_ag); // not applied
    applied(210);FABRIC_REG(0x1c0)=30;
    stats(5,30,200,n,250);assert(g_exposure.updates==1); // group ACK starts settle
    stats(6,40,200,n,329);assert(g_exposure.updates==1); // 79 ms
    exposure_poll(&menu,&cam,330);assert(g_exposure.updates==2); // 80 ms
    applied(340);FABRIC_REG(0x1c0)=100;
    stats(7,100,200,n,380); // reset minimum source to 103
    stats(8,103,200,n,480);assert(g_exposure.updates==2); // +3 itself is still stale
    stats(9,104,200,n,485);assert(g_exposure.updates==3);
    // Ten actual changes in one second are possible with timely grouped writes.
    setup();exposure_set_enabled(1);stats(1,10,200,n,10);
    for(unsigned step=1;step<=10;step++) {
        stats(step*2,step*10,200,n,step*100-1);
        assert(g_exposure.updates==step-1);
        exposure_poll(&menu,&cam,step*100);assert(g_exposure.updates==step);
        applied(step*100+1);
        FABRIC_REG(0x1c0)=step*10;
        stats(step*2+1,step*10,200,n,step*100+10);
    }
    puts("EXPOSURE_RATE_PASS: 100 ms step, 80 ms settle, ACK/source guards, 10 updates in 1 s simulated");

    /* Monotonic hardware gain map, rails, deadband, exposure priority. */
    assert(exposure_gain_q8(16)==256 && exposure_gain_q8(239)==126*256);
    for(unsigned v=17;v<=239;v++) assert(exposure_gain_q8(v)>exposure_gain_q8(v-1));
    assert(!exposure_choose(100,16,80,80,100,1991,&a,&g));
    assert(exposure_choose(100,16,10,80,100,1991,&a,&g) && a>100 && g==16);
    assert(exposure_choose(1991,16,10,80,100,1991,&a,&g) && a==1991 && g>16);
    assert(exposure_choose(100,100,200,80,100,1991,&a,&g) && a==100 && g<100);
    assert(exposure_choose(100,16,200,80,100,1991,&a,&g) && a<100 && g==16);
    assert(exposure_choose(100,16,20,80,10,1991,&a,&g) && a<100);
    assert(!exposure_choose(1991,239,0,80,100,1991,&a,&g));
    for(unsigned v=207;v<239;v++) {
        assert(exposure_choose(1991,v,0,80,100,1991,&a,&g));
        assert(a==1991 && g>v && g<=239);
    }
    assert(!exposure_choose(2,16,255,80,0,1991,&a,&g));
    for(unsigned e=2;e<=1991;e+=7) for(unsigned v=16;v<=239;v++) {
        exposure_choose(e,v,250,80,100,1991,&a,&g);
        assert(a>=2 && a<=1991 && g>=16 && g<=239 && a*exposure_gain_q8(g)<=e*exposure_gain_q8(v));
    }
    for(unsigned mode=0;mode<3;mode++) {
        setup();integration_set_mode(mode);integration_poll(5);integration_poll(6);
        assert(menu_command(&menu,"value AE 1991",0)==1);
        assert(menu_command(&menu,"value AE 1992",0)==-1 && menu.ae==1991);
        assert(menu_command(&menu,"value AE 3982",0)==-1 && menu.ae==1991);
        assert(menu_command(&menu,"value AE 2",0)==1);
        assert(menu_command(&menu,"value AE 1",0)==-1 && menu.ae==2);
        assert(menu_command(&menu,"value AG 239",0)==1);
        assert(menu_command(&menu,"value AG 240",0)==-1 && menu.ag==239);
        assert(menu_command(&menu,"value AE 1991",0)==1);
        unsigned key_ms=10;menu.selected=MENU_AE;key(11,&key_ms);
        for(unsigned i=0;i<1200;i++)menu_sample(&menu,11,++key_ms);
        assert(menu.ae==1991);key(15,&key_ms);
        menu.selected=MENU_AG;key(11,&key_ms);
        for(unsigned i=0;i<1200;i++)menu_sample(&menu,11,++key_ms);
        assert(menu.ag==239);
        // Real exposure_poll must share 1991 even in STYLE; darkness raises AG.
        menu.ag=cam.ag=cam.applied_ag=207;
        exposure_set_enabled(1);
        stats(1,10,0,n,3000);stats(2,20,0,n,3300);stats(3,30,0,n,3600);
        assert(menu.ae==1991 && menu.ag>207 && menu.ag<=239 && g_exposure.updates==1);
    }
    setup();assert(!g_exposure.enabled);
    assert(exposure_command("exposure target 90")==1 && g_exposure.target==90);
    assert(exposure_command("exposure target -1")==-1 && g_exposure.target==90);
    assert(exposure_command("exposure target 4294967296")==-1 && g_exposure.target==90);
    assert(exposure_command("exposure target 90x")==-1 && g_exposure.target==90);
    assert(exposure_command("exposure target 80")==1 && g_exposure.target==80);
    assert(exposure_command("exposure status")==1 && !g_exposure.enabled);
    assert(menu_command(&menu,"value AUTOEXP 1",0)==1 && g_exposure.enabled);
    stats(1,10,200,n,10); // initial actuator acknowledgement guard
    assert(menu.ag==190);
    stats(2,2,200,n,300);assert(menu.ag==190); // cached pre-update source
    stats(3,20,200,n,600);assert(menu.ag<190 && menu.ae==1991);
    unsigned held=menu.ag;stats(4,30,200,n,900);assert(menu.ag==held); // wait for I2C
    applied(910);assert(writes==8 && written[0]==0x381200 && written[7]==0x381230);
    for(unsigned i=1;i<7;i++) assert(written[i]==camera_group_word(i,1991,held));
    stats(5,40,200,n,1000);assert(menu.ag==held); // new group settling
    stats(6,50,200,n,1300);assert(menu.ag<held);
    held=menu.ag;assert(exposure_set_enabled(0));stats(7,60,200,n,1600);assert(menu.ag==held);
    assert(menu_command(&menu,"value AUTOEXP 1",0)==1);
    assert(menu_command(&menu,"value AE 1000",0)==1 && !g_exposure.enabled && menu.ae==1000);
    assert(menu_command(&menu,"value AUTOEXP 1",0)==1);
    assert(menu_command(&menu,"value AG 80",0)==1 && !g_exposure.enabled && menu.ag==80);
    setup();unsigned now=0;menu.selected=MENU_EXPOSURE;key(11,&now);assert(g_exposure.enabled);
    key(15,&now);key(7,&now);assert(!g_exposure.enabled);
    key(15,&now);key(13,&now);assert(menu.selected==MENU_AE); // 11-item wrap
    menu.selected=MENU_EXPOSURE;key(15,&now);key(11,&now);key(15,&now);
    menu.selected=MENU_AG;key(11,&now);assert(!g_exposure.enabled);
    setup();exposure_set_enabled(1);cam.errors=1;cam.fault=1;stats(1,50,10,n,500);assert(g_exposure.state==5 && menu.ag==190);
    setup();exposure_set_enabled(1);cam.errors=1;stats(1,10,25,n,10);
    stats(2,20,25,n,300);assert(g_exposure.updates==1 && menu.ag>190 && cam.errors==1);
    setup();exposure_set_enabled(1);stats(1,10,80,n,10);
    stats(2,20,80,n,300);assert(g_exposure.state==7 && menu.ag==190);
    exposure_poll(&menu,&cam,1000);assert(g_exposure.state==6);
    stats(3,30,80,n+1,1200);assert(g_exposure.state==6);
    stats(4,40,0,0,1500);assert(menu.ag<190); // all clipped recovers downward
    setup(); // automatic metering must NOT activate AWB in normal fixed mode
    stats(1,10,40,n,10);assert(FABRIC_REG(0x450)==0);
    IntegrationStats t;assert(integration_get_stats(&t) && t.frame==10 && t.count==n);
    integration_command("display auto");integration_poll(20);
    FABRIC_REG(0x19c)|=256; // emulate accepted configuration
    stats(2,20,40,n,30);assert(FABRIC_REG(0x450)==1);
    setup();integration_set_mode(1);integration_poll(5);FABRIC_REG(0x19c)=(256u<<9)|1;
    exposure_set_enabled(1);stats(1,10,80,n,10);integration_poll(20);assert(!(FABRIC_REG(0x1ac)&8));
    integration_command("motion reset");integration_poll(21);assert(!(FABRIC_REG(0x1ac)&8));
    stats(2,20,80,n,300);stats(3,30,80,n,600);stats(4,40,80,n,900);stats(5,50,80,n,1200);
    assert(g_exposure.locked);integration_poll(1210);assert((FABRIC_REG(0x1ac)&12)==12);
    stats(6,60,100,n,1500);assert(g_exposure.locked && menu.ag==190);
    for(unsigned i=7;i<=25;i++) stats(i,50+i,240,n,1500+(i-6)*250);
    assert(!g_exposure.locked && menu.ag<190);
    /* Arithmetic frame wrap remains ordered; awaiting a new generation never
     * changes the actuator based on an old snapshot. */
    setup();FABRIC_REG(0x1c0)=0xfffffffdu;exposure_set_enabled(1);
    stats(1,0xfffffffdu,200,n,10);stats(2,5,200,n,300);assert(menu.ag<190);
    held=menu.ag;FABRIC_REG(0x190)=1;stats(3,10,20,n,600);assert(menu.ag==held);
    /* Simple sensor model, 2-frame feedback lag and actual grouped writes.
     * This checks loop direction/convergence, not real sensor calibration. */
    for(unsigned scene=0;scene<2;scene++) {
        setup();exposure_set_enabled(1);unsigned raw=10,delayed[2]={80,80};
        for(unsigned ms=50;ms<=20000;ms+=50) {
            applied(ms);raw+=3;FABRIC_REG(0x1c0)=raw;
            unsigned y=delayed[0];delayed[0]=delayed[1];
            delayed[1]=(unsigned)(((uint64_t)cam.applied_ae*exposure_gain_q8(cam.applied_ag))/(scene?16000u:300000u));
            unsigned count=y>=240?0:n;if(y>255)y=255;
            stats(ms/50,raw-6,y,count,ms);
        }
        assert(g_exposure.mean>=70 && g_exposure.mean<=90);
    }
    setup();FABRIC_REG(0x184)=15;exposure_init(0);assert(!exposure_set_enabled(1));
    assert(menu_command(&menu,"value AUTOEXP 1",0)==-1);
    puts("AUTO_EXPOSURE_HOST_PASS: bounds/gain/priority/menu/hold/manual/I2C/settling/stale/clipped/AWB/MOTION/capability");
    return 0;
}
