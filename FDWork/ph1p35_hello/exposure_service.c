#include "exposure_service.h"
#include "fabric_regs.h"
#include <string.h>
ExposureState g_exposure;
/* 10 Hz ceiling; successful sensor writes must also settle for 80 ms and
 * pass the existing source-frame/generation guard. These waits overlap.
 * Actual cadence depends on sensor writes and completed statistics frames. */
enum { EXPOSURE_STEP_MS = 100u, EXPOSURE_SETTLE_MS = 80u };
/* State: 0 OFF, 1 waiting, 2 settling, 3 adjusting, 4 MOTION locked,
 * 5 camera fault, 6 stale/invalid statistics, 7 target or actuator limit.
 * AE is the existing sensor code, NOT milliseconds. Keep proven manual bounds.
 * AG retains the existing analog + digital table, with automatic cap 239.
 * Gain mapping follows SC520GainTbl: 1,2,4,8,16,32,64 times fine/128. */
unsigned exposure_gain_q8(unsigned ag) {
    unsigned s=ag<16?0:ag>239?223:ag-16;
    return (256u+8u*(s%32u))<<(s/32u);
}
int exposure_choose(unsigned ae,unsigned ag,unsigned mean,unsigned target,
                    unsigned coverage,unsigned ae_max,unsigned *na,unsigned *ng) {
    *na=ae;*ng=ag;
    int direction=coverage<75? -1 : mean+5<target?1 : mean>target+5?-1:0;
    if(!direction) return 0;
    unsigned far=coverage<75 || mean+24<target || mean>target+24;
    unsigned delta=ae/(far?4u:16u);if(!delta) delta=1;
    unsigned gain=exposure_gain_q8(ag),step=gain/(far?4u:16u);
    if(direction>0) {
        if(ae<ae_max) *na=ae+delta>ae_max?ae_max:ae+delta;
        else if(ag<MENU_AG_MAX) {
            *ng=ag+1;
            while(*ng<MENU_AG_MAX && exposure_gain_q8(*ng+1)<=gain+step) ++*ng;
        }
    } else if(ag>16) {
        *ng=ag-1;
        while(*ng>16 && exposure_gain_q8(*ng-1)>=gain-step) --*ng;
    }
    else if(ae>2) *na=ae>delta+2?ae-delta:2;
    return *na!=ae || *ng!=ag;
}
void exposure_init(uint32_t now) {
    memset(&g_exposure,0,sizeof(g_exposure));
    g_exposure.supported=!!(FABRIC_REG(0x184)&FINAL1_EXPOSURE_CAP);
    g_exposure.target=80; /* Linear pre-Gamma starting point; board calibration required. */
    g_exposure.settle_ms=g_exposure.last_stats_ms=now;
}
int exposure_set_enabled(unsigned enabled) {
    if(enabled && !g_exposure.supported) return 0;
    if(g_exposure.enabled!=!!enabled) {
        g_exposure.enabled=!!enabled;g_exposure.seen_enabled=0;
        g_exposure.filter_valid=g_exposure.stable=g_exposure.locked=g_exposure.severe=0;
    }
    if(!enabled) {g_exposure.state=0;integration_exposure_hold(0);}
    return 1;
}
static int newer(uint32_t a,uint32_t b) {return a!=b && (uint32_t)(a-b)<0x80000000u;}
int exposure_command(const char *line) {
    if(strncmp(line,"exposure",8) || (line[8] && line[8]!=' ')) return 0;
    if(!strcmp(line,"exposure auto")) return exposure_set_enabled(1)?1:-1;
    if(!strcmp(line,"exposure manual")) {exposure_set_enabled(0);return 1;}
    if(!strcmp(line,"exposure status")) return 1;
    if(!strncmp(line,"exposure target ",16)) {
        const char *p=line+16;unsigned n=0;
        if(!*p) return -1;
        while(*p>='0' && *p<='9') {n=n*10u+(unsigned)(*p++-'0');if(n>160) return -1;}
        if(*p || n<16) return -1;
        g_exposure.target=n;g_exposure.seen_enabled=0;return 1;
    }
    return -1;
}
void exposure_poll(Menu *m,const CameraService *c,uint32_t now) {
    ExposureState *s=&g_exposure;
    if(!s->enabled) {s->state=0;return;}
    unsigned mode=integration_get_mode();
    if(!s->seen_enabled || mode!=s->seen_mode || m->bl!=s->seen_bl || m->bo!=s->seen_bo) {
        s->seen_enabled=1;s->seen_mode=mode;s->seen_bl=m->bl;s->seen_bo=m->bo;
        s->filter_valid=s->stable=s->locked=s->severe=0;
        s->seq=0;s->settle_ms=s->last_stats_ms=s->session_ms=now;
        s->min_frame=FABRIC_REG(0x1c0)+3u;
        integration_exposure_hold(mode==1);
    }
    /* Historical NACKs are diagnostic, not a permanent interlock. The camera
     * service admits only fully ACKed groups and faults on exhausted retries. */
    if(c->fault || c->timeouts) {s->state=5;integration_exposure_hold(0);return;}
    if(!integration_measure_ready() || !camera_service_ready(c) ||
       c->ae!=m->ae || c->ag!=m->ag || c->applied_ae!=m->ae || c->applied_ag!=m->ag) {
        s->state=1;return;
    }
    if(c->groups!=s->groups) {
        s->groups=c->groups;s->settle_ms=now;s->min_frame=FABRIC_REG(0x1c0)+3u;
        s->filter_valid=0;s->state=2;return;
    }
    IntegrationStats t;
    if(!integration_get_stats(&t) || (uint32_t)(now-t.received_ms)>500u) {s->state=6;return;}
    if(t.generation!=s->generation) {
        s->generation=t.generation;s->filter_valid=s->stable=s->locked=0;
        s->settle_ms=s->session_ms=now;s->severe=0;s->min_frame=FABRIC_REG(0x1c0)+3u;
        integration_exposure_hold(mode==1);s->state=2;return;
    }
    if((uint32_t)(now-s->settle_ms)<EXPOSURE_SETTLE_MS || !newer(t.frame,s->min_frame)) {s->state=2;return;}
    if(t.seq==s->seq || (uint32_t)(now-s->last_step)<EXPOSURE_STEP_MS) return;
    s->seq=t.seq;s->last_step=now;s->last_stats_ms=now;
    const unsigned samples=1280u*720u/4u;
    if(t.count>samples || t.r>t.count*255u+1 || t.g>t.count*255u+1 || t.b>t.count*255u+1) {
        s->state=6;return;
    }
    s->coverage=t.count*100u/samples;
    /* Zero eligible samples is valid for an entirely clipped frame. */
    if(t.r==0 || t.g==0 || t.b==0) {s->state=6;return;}
    unsigned y=t.count ? ((t.r-1u)+2u*(t.g-1u)+(t.b-1u))/(4u*t.count) : 255u;
    s->filtered=s->filter_valid?(3u*s->filtered+y+2u)/4u:y;
    s->filter_valid=1;s->mean=s->filtered;
    if(mode==1 && s->locked) {
        s->state=4;
        unsigned severe=s->coverage<75 || s->mean+24<s->target || s->mean>s->target+24;
        if(!severe) {s->severe=0;return;}
        if(!s->severe) {s->severe=1;s->severe_since=now;return;}
        if((uint32_t)(now-s->severe_since)<2000u) return;
        s->locked=s->stable=s->severe=0;s->session_ms=now;integration_exposure_hold(1);
    }
    unsigned ae,ag;
    if(mode==1 && (uint32_t)(now-s->session_ms)>8000u) {
        s->locked=1;s->state=4;integration_exposure_hold(0);return;
    }
    /* All three modes share the manual limit; no long-exposure exception. */
    unsigned ceiling=MENU_AE_MAX;
    if(exposure_choose(m->ae,m->ag,s->mean,s->target,s->coverage,ceiling,&ae,&ag)) {
        m->ae=(uint16_t)ae;m->ag=(uint8_t)ag;s->updates++;s->stable=0;s->state=3;
    } else {s->stable++;s->state=7;}
    /* Bound MOTION acquisition time even in scenes the global meter cannot
     * satisfy. Release overlays, rebuild background, then lock exposure. */
    if(mode==1 && s->stable>=3) {
        s->locked=1;s->state=4;integration_exposure_hold(0);
    }
}
