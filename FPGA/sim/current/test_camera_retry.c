#include <assert.h>
#include <stdio.h>
#include <string.h>
#include "camera_service.h"
#include "exposure_service.h"
#include "fabric_regs.h"
#include "sc520_regs.h"

uint32_t fabric_test_mmio[512];
static CameraService cam;
static Menu menu;
static unsigned now, accepted, completed, attempt, slot, sensor_writes;
static unsigned inflight, due, hang, reject, command_mode, command_word;
static unsigned fail_slot, fail_attempts, init_fail_addr, last_nack;
static unsigned init_fail_index,id_fail_addr;
static unsigned delay=2, holds;
static uint32_t log_words[4096];
static IntegrationStats sample;
unsigned integration_get_mode(void) { return 0; }
int integration_measure_ready(void) { return 1; }
void integration_exposure_hold(unsigned h) { holds=h; }
int integration_get_stats(IntegrationStats *s) { *s=sample;return 1; }

void fabric_test_fence(void) {
    if(!REG_CAM_COMMAND) return;
    unsigned cmd=REG_CAM_COMMAND;REG_CAM_COMMAND=0;
    assert(!inflight); // Never overlap a pending hardware transaction.
    if(reject) return;
    command_mode=cmd&10u;command_word=(REG_CAM_ADDR<<8)|(REG_CAM_DATA&255u);
    accepted++;REG_CAM_ACCEPTED=accepted;REG_CAM_STATUS=9;inflight=1;due=now+delay;
    if(!command_mode) {
        assert(sensor_writes<4096);log_words[sensor_writes++]=command_word;
        if(command_word==0x381200) {attempt++;slot=0;}
    }
}
static void tick(void) {
    ++now;
    if(inflight && !hang && (int)(now-due)>=0) {
        unsigned nack=0;
        if(command_mode==2) {
            REG_CAM_READ_DATA=(command_word>>8)==0x3107?0xee:0x4b;
            if((command_word>>8)==id_fail_addr) nack=1;
        }
        if(!command_mode) {
            if(cam.phase==5 && cam.index==init_fail_index) nack=1;
            if(attempt && slot==fail_slot && attempt<=fail_attempts) nack=1;
            if(attempt) slot++;
        }
        if(command_mode==8) REG_CAM_COMPLETED_STATE=REG_CAM_STATE;
        last_nack=nack;inflight=0;completed=accepted;REG_CAM_COMPLETED=completed;
        REG_CAM_STATUS=12|(nack?16:0);
    }
    camera_service_poll(&cam,&menu,now);
}
static void setup(int initialized) {
    memset(fabric_test_mmio,0,sizeof fabric_test_mmio);memset(&menu,0,sizeof menu);
    memset(&sample,0,sizeof sample);memset(log_words,0,sizeof log_words);
    now=accepted=completed=attempt=slot=sensor_writes=inflight=hang=reject=0;
    command_mode=command_word=fail_attempts=init_fail_addr=last_nack=holds=0;
    fail_slot=99;delay=2;REG_CAM_STATUS=8;FABRIC_REG(0x184)=31;
    init_fail_index=0xffffffffu;id_fail_addr=0;
    camera_service_init(&cam,now);menu.ae=1000;menu.ag=100;menu.bl=1;menu.bo=32;
    if(initialized) {
        cam.phase=10;cam.have_applied=1;cam.sensor_id=0xee4b;cam.state_word=0xee4b0007;
        cam.ae=cam.applied_ae=800;cam.ag=cam.applied_ag=80;cam.groups=1;
    }
    exposure_init(now);
}
static void meter(void) {
    sample.seq++;sample.frame+=10;sample.count=230400;sample.received_ms=now;
    sample.r=sample.g=sample.b=25*sample.count+1;
    exposure_poll(&menu,&cam,now);
}
static void finish(unsigned limit) {
    for(unsigned i=0;i<limit;i++) {
        tick();
        if(cam.fault || (camera_service_ready(&cam) && cam.applied_ae==menu.ae && cam.applied_ag==menu.ag)) return;
    }
    assert(!"service did not finish");
}
static void check_attempts(unsigned count,unsigned ae,unsigned ag) {
    assert(sensor_writes==count*8);
    for(unsigned a=0;a<count;a++) for(unsigned k=0;k<8;k++)
        assert(log_words[a*8+k]==camera_group_word(k,ae,ag));
}
int main(void) {
    unsigned cases=0;
    // Every possible failed write, including group hold/release; one/two retries.
    for(unsigned k=0;k<8;k++) for(unsigned failures=1;failures<=2;failures++) {
        setup(1);fail_slot=k;fail_attempts=failures;exposure_set_enabled(1);
        while(!camera_service_ready(&cam) || cam.groups==1) {
            tick();assert(now<500);
            if(cam.groups==1) {
                assert(cam.applied_ae==800 && cam.applied_ag==80);
                assert(!camera_service_ready(&cam));meter();assert(g_exposure.updates==0);
            }
        }
        assert(!cam.fault && cam.errors==failures && cam.retries==failures);
        assert(cam.groups==2 && cam.have_applied && cam.applied_ae==1000 && cam.applied_ag==100);
        assert(cam.last_error_word==camera_group_word(k,1000,100) && cam.last_error_index==k);
        assert(cam.last_error_phase==8 && cam.last_error_ms>0);
        check_attempts(failures+1,1000,100);
        meter();assert(g_exposure.state==2); // Fresh successful group must settle.
        now+=201;meter();assert(g_exposure.updates==1 && menu.ae>1000 && cam.errors==failures);
        cases++;
    }
    // Persistent NACK exhausts exactly two retries, never falsely publishes.
    for(unsigned k=0;k<8;k++) {
        setup(1);fail_slot=k;fail_attempts=99;exposure_set_enabled(1);finish(500);
        assert(cam.fault && !cam.have_applied && cam.errors==3 && cam.retries==2 && cam.groups==1);
        assert(!inflight && !cam.pending);check_attempts(3,1000,100);
        unsigned writes=sensor_writes;for(unsigned i=0;i<200;i++) tick();
        assert(sensor_writes==writes);meter();assert(g_exposure.state==5 && g_exposure.updates==0);
        cases++;
    }
    // User changes desired values and disables AUTO during retry; frozen group
    // completes first, then a new group applies the latest manual wish.
    setup(1);fail_slot=3;fail_attempts=1;exposure_set_enabled(1);
    while(cam.phase!=12) tick();
    exposure_set_enabled(0);menu.ae=1400;menu.ag=120;finish(500);
    assert(cam.groups==3 && cam.retries==1 && sensor_writes==24);
    for(unsigned i=0;i<24;i++) assert(log_words[i]==camera_group_word(i%8,i<16?1000:1400,i<16?100:120));
    meter();assert(!g_exposure.enabled && g_exposure.updates==0);cases++;
    // Each sensor transaction can time out: leave ownership/pending intact;
    // never resend over the still-active bus, and never accept late completion.
    for(unsigned k=0;k<8;k++) {
        setup(1);
        while(!(inflight && command_mode==0 && slot==k)) {tick();assert(now<100);}
        hang=1;unsigned writes=sensor_writes;
        for(unsigned i=0;i<150;i++) tick();
        assert(cam.fault && cam.timeouts==1 && cam.pending && inflight && cam.retries==0);
        assert(!cam.have_applied && cam.groups==1 && sensor_writes==writes);
        hang=0;tick();assert(cam.fault && !inflight && cam.groups==1);cases++;
    }
    // A debugger pause after completion must not manufacture a timeout.
    setup(1);tick();tick();now+=1000;tick();assert(!cam.fault && !cam.timeouts);finish(500);cases++;
    // Command rejection is not retried as though it were a completed NACK.
    setup(1);reject=1;finish(100);assert(cam.fault && !cam.pending && !cam.retries);cases++;
    // Healthy complete initialization; initialization NACK cannot be hidden by
    // a later successful exposure group. Check every init table register.
    setup(0);finish(2000);assert(!cam.fault && cam.groups==1 && cam.sensor_id==0xee4b);cases++;
    for(unsigned i=0;i<SC520_INIT_REG_COUNT;i++) {
        setup(0);init_fail_index=i;init_fail_addr=sc520_init_regs[i]>>8;finish(2000);
        assert(cam.fault && cam.errors==1 && !cam.groups && !cam.have_applied && !cam.retries);
        assert(cam.last_error_word>>8==init_fail_addr && cam.last_error_index==i);cases++;
    }
    for(unsigned a=0x3107;a<=0x3108;a++) {
        setup(0);id_fail_addr=a;finish(100);
        assert(cam.fault && cam.errors==1 && cam.last_error_word>>8==a && !sensor_writes);cases++;
    }
    // Counter is history; verified idle health is the admission condition.
    setup(1);menu.ae=800;menu.ag=80;cam.errors=7;exposure_set_enabled(1);
    meter();now+=300;meter();assert(g_exposure.updates==1 && cam.errors==7);cases++;
    printf("CAMERA_RETRY_PASS cases=%u: per-write NACK recovery/exhaustion/timeout/frozen requests/init/AE settling/history\n",cases);
    return 0;
}
