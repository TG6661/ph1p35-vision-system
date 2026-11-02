#include <assert.h>
#include <stdio.h>
#include <string.h>
#include "gimbal_track.h"
#include "menu_control.h"
#include "menu_display.h"
#include "integration_service.h"
#include "fabric_regs.h"
#include "exposure_service.h"
ExposureState g_exposure;
int exposure_set_enabled(unsigned v) {g_exposure.enabled=v;return 1;}
uint32_t fabric_test_mmio[512];
static uint32_t mode;
static int ready=1,commits,cancels;
static uint32_t active,pending_pair;static int busy;
static uint32_t pending_pan,pending_tilt;
void fabric_test_fence(void) {
    // Consume command writes and expose read status; snapshot the frozen pair.
    uint32_t c=REG_SERVO_CONTROL;
    if(c==6) {busy=0;++cancels;}
    else if(c==5) {if(!busy) {pending_pan=REG_SERVO_PAN;pending_tilt=REG_SERVO_TILT;
        pending_pair=pending_pan|(pending_tilt<<12);busy=1;++commits;}}
    REG_SERVO_CONTROL=busy;REG_SERVO_ACTIVE=active;
}
static void boundary(void) {if(busy) {active=pending_pair;busy=0;} REG_SERVO_CONTROL=0;REG_SERVO_ACTIVE=active;}
int integration_get_hud(IntegrationHud *h) {h->config=mode;h->motion=0;h->extra=0;return 1;}
uint32_t integration_get_mode(void) {return mode;}
uint32_t integration_mode(void) {return mode;}
int integration_tracking_ready(void) {return ready && mode==0;}
void integration_set_mode(uint32_t m) {mode=m;}
void integration_adjust_param(int slot,int direction) {(void)slot;(void)direction;}
void integration_get_active_params(uint32_t *a,uint32_t *b,uint32_t *c) {(void)a;(void)b;(void)c;}
static void init(void) {
 memset(fabric_test_mmio,0,sizeof(fabric_test_mmio));mode=0;ready=1;busy=0;commits=cancels=0;
 active=1500|(1500u<<12);REG_SERVO_ABI=SERVO_ABI;REG_SERVO_ACTIVE=active;gimbal_track_init();
}
static TargetService targets;
static uint32_t now=100;
static void sample(int x,int y,int shape,int id) {
 targets.have_last=1;targets.last_ms=now;targets.last_sequence++;targets.last.count=1;targets.last.error=0;
 targets.last.items[0]=(Target){.area=1000,.xmin=x-10,.xmax=x+10,.ymin=y-10,.ymax=y+10,.shape=shape,.id=id};
 gimbal_track_poll(&targets,now++);
}
static void arm(void) {gimbal_track_set_enabled(1);gimbal_track_poll(&targets,now++);}
static void key(Menu *m,unsigned raw,uint32_t *t) {
 for(unsigned i=0;i<30;i++) menu_sample(m,(uint8_t)raw,(*t)++);
 for(unsigned i=0;i<30;i++) menu_sample(m,15,(*t)++);
}
int main(void) {
 init();assert(!gimbal_track_enabled() && g_track.supported && !commits);
 REG_SERVO_ABI=0;gimbal_track_init();assert(!g_track.supported);gimbal_track_set_enabled(1);assert(!gimbal_track_enabled());
 assert(gimbal_track_command("track on")==-1);assert(!commits);init();
 memset(&targets,0,sizeof(targets));arm();sample(900,550,2,1);
 assert(g_track.wanted[0]==1490 && g_track.wanted[1]==1506 && busy);int old_commits=commits;
 gimbal_track_poll(&targets,now);assert(commits==old_commits); // duplicate seq
 sample(900,550,2,1);assert(pending_pan==1490 && pending_tilt==1506); // frozen hardware pair
 boundary();gimbal_track_poll(&targets,now);assert(busy && commits==old_commits+1);boundary();
 gimbal_track_set_enabled(0);assert(!busy && !g_track.dirty && !g_track.has_target);
 uint32_t held=active;sample(100,100,2,1);assert(active==held && !busy);
 arm();sample(900,550,2,1);assert(busy);mode=1;gimbal_track_poll(&targets,now);assert(!busy && !g_track.armed && active==held);
 mode=0;gimbal_track_poll(&targets,now);assert(!busy);gimbal_track_poll(&targets,now);assert(!busy);
 sample(900,550,2,1);assert(busy);ready=0;gimbal_track_poll(&targets,now);assert(!busy);ready=1;
 gimbal_track_poll(&targets,now);sample(900,550,2,1);assert(busy);
 gimbal_track_poll(&targets,targets.last_ms+500);assert(!busy && !g_track.has_target);
 sample(900,550,1,1);assert(!g_track.has_target && g_track.patrol_active && busy);boundary();
 assert(gimbal_track_command("track mode any")==1);gimbal_track_poll(&targets,now);sample(900,550,1,1);assert(g_track.has_target);
 targets.last.items[0].geometry_error=1;targets.last_sequence++;gimbal_track_poll(&targets,now);assert(!g_track.has_target && !g_track.patrol_active && !busy);
 sample(900,550,2,1);targets.last.error=1;targets.last_sequence++;gimbal_track_poll(&targets,now);assert(!g_track.has_target && !g_track.patrol_active && !busy);
 assert(gimbal_track_command("servo 0 65535")==1);assert(!gimbal_track_enabled());assert(g_track.wanted[0]==600 && g_track.wanted[1]==2200);boundary();
 assert(gimbal_track_command(" pan 2400 ")==1);assert(g_track.wanted[0]==2400 && g_track.wanted[1]==2200);boundary();
 assert(gimbal_track_command("tilt 800")==1);assert(g_track.wanted[0]==2400 && g_track.wanted[1]==800);boundary();
 const char *bad[]={"track patrol 1000 2000 0","track patrol 1000 2000 20 junk","track patrol 1100 2000 101","track patrol 500 2000","track patrol 2000 1000","track patrol 1000","track patrol 1000 2500","track status on","track on junk","track kp 4 5 6","track kp 99999999999999999999999","track kp 1 -2","track kd 1001","track step 0","track step 1 101","track deadband 20 10","track deadband 360","track mode anyone","servo 1500","servo 1500 1500 x","pan -2","tilt 65536","pan 12x"};
 for(unsigned i=0;i<sizeof(bad)/sizeof(bad[0]);i++) {GimbalTrack copy=g_track;assert(gimbal_track_command(bad[i])==-1);assert(!memcmp(&copy,&g_track,sizeof(copy)));}
 assert(gimbal_track_command("unrelated")==0);
 assert(gimbal_track_command("track kp 1000 8")==1);assert(g_track.kp[0]==1000 && g_track.kp[1]==8);
 assert(gimbal_track_command("track kd 0")==1);assert(!g_track.kd[0] && !g_track.kd[1]);
 assert(gimbal_track_command("track step 100 1")==1);assert(g_track.step[0]==100000 && g_track.step[1]==1000);
 assert(gimbal_track_command("track deadband 35 55")==1);
 assert(gimbal_track_command("track reset")==1);boundary();assert(active==(1500|(1500u<<12)) && !gimbal_track_enabled());
 init();memset(&targets,0,sizeof(targets));arm();sample(640,360,2,1);assert(g_track.dead[0] && g_track.dead[1] && !busy);
 sample(670,390,2,1);assert(!busy);sample(676,396,2,1);assert(!g_track.dead[0] && !g_track.dead[1]);boundary();
 // Largest eligible target, target change derivative reset, and sequence wrap.
 targets.last.count=2;targets.last.items[1]=(Target){.area=2000,.xmin=300,.xmax=320,.ymin=300,.ymax=320,.shape=2,.id=7};
 targets.last_sequence++;targets.last_ms=now;gimbal_track_poll(&targets,now++);assert(g_track.target_id==7);
 g_track.sequence=0xffffffffu;targets.last_sequence=0;targets.last_ms=now;gimbal_track_poll(&targets,now++);assert(g_track.sequence==0);boundary();
 // Converging to both software bounds cannot overflow milli-us accumulators.
 for(unsigned i=0;i<500;i++) {sample(1200,700,2,1);boundary();}assert(g_track.wanted[0]==600 && g_track.wanted[1]<=2200);
 for(unsigned i=0;i<2000;i++) {sample(20,20,2,1);boundary();}assert(g_track.wanted[0]==2400 && g_track.wanted[1]==800);
 // Exact defaults, endpoint reversal and duplicate/stale snapshot behavior.
 init();memset(&targets,0,sizeof(targets));arm();
 assert(g_track.kp[0]==35 && g_track.kp[1]==35 && g_track.kd[0]==20 && g_track.kd[1]==20);
 assert(g_track.step[0]==10000 && g_track.step[1]==10000 && g_track.inner[1]==20 && g_track.outer[1]==35);
 assert(g_track.patrol_min==900 && g_track.patrol_max==2100 && g_track.patrol_step==16000);
 int seen_low=0,seen_high=0;
 for(unsigned i=0;i<220;i++) {
     sample(640,360,1,1);
     assert(g_track.patrol_active && g_track.wanted[0]>=900 && g_track.wanted[0]<=2100);
     if(g_track.wanted[0]==900) {seen_low++;assert(!g_track.patrol_dir);}
     if(g_track.wanted[0]==2100) {seen_high++;assert(g_track.patrol_dir);}
     boundary();
 }
 assert(seen_low && seen_high);
 uint16_t stopped=g_track.wanted[0];old_commits=commits;
 gimbal_track_poll(&targets,now);assert(g_track.wanted[0]==stopped && commits==old_commits);
 sample(640,360,1,1);assert(busy && g_track.patrol_active);
 gimbal_track_poll(&targets,targets.last_ms+500);assert(!busy && !g_track.patrol_active);
 assert(gimbal_track_command("servo 1500 1700")==1);boundary();arm();
 sample(640,360,1,1);assert(g_track.wanted[1]==1690);boundary();
 sample(900,550,2,1);assert(g_track.has_target && !g_track.patrol_active);boundary();
 sample(640,360,1,1);assert(g_track.patrol_active);boundary();
 gimbal_track_invalidate();assert(!g_track.patrol_active && !g_track.armed && !busy);
 // Test patrol mode: sweep when no circle, track when circle present, resume sweep when lost
 init();
 assert(gimbal_track_command("track patrol 1000 2000 20")==1);
 gimbal_track_poll(&targets,now++); // arm
 {
     uint16_t w0=g_track.wanted[0];
     sample(900,550,1,1);boundary(); // shape 1 is not a circle, should sweep in patrol
     assert(g_track.patrol_active && g_track.wanted[0]!=w0);
     sample(900,550,2,1);boundary(); // shape 2 is circle, should lock on target
     assert(!g_track.patrol_active && g_track.has_target);
     sample(900,550,1,1);boundary(); // target lost, should resume patrol sweep
     assert(g_track.patrol_active && !g_track.has_target);
 }
 assert(gimbal_track_command("track off")==1 && !gimbal_track_enabled());
 Menu m;uint32_t t=0;menu_init(&m,t);assert(MENU_COUNT==11 && m.selected==MENU_MODE);key(&m,14,&t);assert(m.selected==MENU_TRACK);
 key(&m,11,&t);assert(gimbal_track_enabled());key(&m,7,&t);assert(!gimbal_track_enabled());
 key(&m,13,&t);assert(m.selected==MENU_MODE);key(&m,13,&t);assert(m.selected==MENU_EXPOSURE);assert(menu_command(&m,"select TRACK",t)==1 && m.selected==9);
 assert(menu_command(&m,"value TRACK 1",t)==1 && gimbal_track_enabled());assert(menu_command(&m,"value TRACK 2",t)==-1);assert(menu_command(&m,"value TRACK 3",t)==-1);
 assert(menu_command(&m,"value GMR 55",t)==-2);assert(menu_command(&m,"value GMR 70",t)==1);assert(m.gamma==6 && m.sf==3);
 MenuDisplay display;menu_display_init(&display);REG_HUD_STATUS=8;REG_MENU_STATUS=4;REG_MENU_COMPLETED_CAMERA=menu_camera(&m);REG_MENU_COMPLETED_UI=menu_ui(&m);REG_THRESH_SELECTED=menu_rgb(&m);
 menu_display_poll(&display);assert((REG_HUD_WORD2>>31)==1 && ((REG_HUD_WORD2>>24)&15)==9);
 gimbal_track_set_enabled(0);menu_display_poll(&display);assert(!(REG_HUD_WORD2>>31));
 assert(menu_command(&m,"defaults",t)==1 && !gimbal_track_enabled());
 puts("GIMBAL_HOST_PASS: gating, timeout, atomic queue, PD, bounds, strict parser, mode-specific keys, HUD flag, patrol mode");return 0;
}
