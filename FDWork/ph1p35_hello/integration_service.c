#include "integration_service.h"
#include "fabric_regs.h"
#include <string.h>
#define F1(x) FABRIC_REG(x)
static uint32_t normal_profile,style_profile,motion_profile,desired_mode;
static uint32_t motion_extra,submitted_extra;
static uint32_t submitted_config,submitted_motion,applied_generation;
static uint32_t last_motion_seq,last_motion_frame,last_motion_ms,last_observed_frame,last_observed_ms;
static uint32_t last_awb_seq,awb_r,awb_b,last_poll;
static uint32_t configuration(void);
static IntegrationStats stats;
static uint32_t last_stats_poll;
static unsigned stats_valid,exposure_hold,exposure_reset;
void integration_exposure_hold(unsigned hold) {
    hold=!!hold;
    if(exposure_hold && !hold) exposure_reset=1;
    exposure_hold=hold;
}
int integration_get_stats(IntegrationStats *out) {
    if(!stats_valid) return 0;
    *out=stats;return 1;
}
int integration_measure_ready(void) {
    return !(F1(0x190)&1u) && F1(0x194)==F1(0x198) &&
        F1(0x198)==applied_generation && (F1(0x19c)&3u)==desired_mode &&
        configuration()==submitted_config && motion_profile==submitted_motion;
}
static uint8_t page,selected,stable,candidate,chord;
static uint32_t since,last_keys;
static unsigned bcd(unsigned n) {
    unsigned result=0;
    for(unsigned i=0;i<4;i++) {result|=(n%10u)<<(4*i);n/=10u;}
    return result;
}
static uint32_t configuration(void) {
    return (desired_mode==2?style_profile:normal_profile)|desired_mode;
}
void integration_init(uint32_t now) {
    stats_valid=exposure_hold=exposure_reset=0;last_stats_poll=now-5u;memset(&stats,0,sizeof(stats));
    normal_profile=256u<<9;
    style_profile=(FINAL1_STYLE_GG_Q8<<9)|(1u<<8);
    motion_profile=20u|(3u<<8)|(5u<<11)|(10u<<17);
    motion_extra=submitted_extra=(20u<<16)|8u;
    F1(0x1ac)=motion_extra|4u;fabric_fence();
    // Restarting the MCU leaves FPGA active/pending configuration and HUD intact.
    // Do not mistake software defaults for an acknowledged hardware submission.
    // Force one complete transaction after any older in-flight request drains;
    // existing readiness gates keep HUD/AE/tracking blocked until it applies.
    desired_mode=0;submitted_config=UINT32_MAX;submitted_motion=UINT32_MAX;
    applied_generation=F1(0x198);last_motion_seq=last_awb_seq=last_motion_frame=0;
    last_motion_ms=last_observed_ms=last_poll=last_keys=now;last_observed_frame=0;
    awb_r=95907;awb_b=100825;page=selected=chord=0;stable=candidate=15;since=now;
    motion_reset();
}
uint32_t integration_mode(void) {return F1(0x19c)&3u;}
int integration_tracking_ready(void) {
    fabric_fence();
    return desired_mode==0 && configuration()==submitted_config && motion_profile==submitted_motion &&
        !(F1(0x190)&1u) && F1(0x198)==applied_generation &&
        F1(0x194)==applied_generation && (F1(0x19c)&3u)==0;
}
unsigned integration_page(void) {return page;}
static int page_value(void) {
    if(page==1) return selected?((normal_profile>>8)&1u):desired_mode;
    if(page==2) {
        if(selected==4) return (int8_t)(motion_extra>>8);
        if(selected==5) return (motion_extra>>16)&255u;
        static const unsigned shifts[]={0,8,11,17},masks[]={255,7,63,31};
        return (motion_profile>>shifts[selected])&masks[selected];
    }
    if(page==3) {
        if(selected==0) return (int)final1_fx_decode(style_profile);
        return selected==1 ? (int)((style_profile>>6)&3u) : 0;
    }
    return 0;
}
uint32_t integration_get_mode(void) {
    return desired_mode;
}

int integration_get_hud(IntegrationHud *out) {
    fabric_fence();
    if(!integration_measure_ready()) return 0;
    uint32_t generation=F1(0x198);
    out->config=F1(0x19c);
    // Only one config transaction can be outstanding; measure_ready confirms it applied.
    out->motion=submitted_motion;
    out->extra=F1(0x1ac);
    fabric_fence();
    return generation==F1(0x198) && out->config==F1(0x19c) && integration_measure_ready();
}

void integration_set_mode(uint32_t m) {
    if(m < 3) desired_mode = m;
}

void integration_get_active_params(uint32_t *p1, uint32_t *p2, uint32_t *p3) {
    if(desired_mode == 1) { // MOT: slot 0=DIFF, 1=NEIG, 2=HOLD
        *p1 = (motion_profile >> 0) & 255u;
        *p2 = (motion_profile >> 8) & 7u;
        *p3 = (motion_profile >> 17) & 31u;
    } else if(desired_mode == 2) { // STY: slot 0=FX, 1=CL; slot2 retired
        *p1 = final1_fx_decode(style_profile);
        *p2 = (style_profile >> 6) & 3u;
        *p3 = 0;
    }
}

void integration_adjust_param(int slot, int dir) {
    if(desired_mode == 1) { // MOT: slot 0=DIFF, 1=NEIG, 2=HOLD
        static const unsigned ms[] = {0, 8, 17};
        static const unsigned mm[] = {255, 7, 31};
        static const unsigned ml[] = {1, 1, 0};
        if(slot >= 0 && slot < 3) {
            unsigned shift = ms[slot], mask = mm[slot], low = ml[slot], high = mask;
            unsigned val = (motion_profile >> shift) & mask;
            if(dir > 0) val = (val < high) ? val + 1 : high;
            else val = (val > low) ? val - 1 : low;
            motion_profile = (motion_profile & ~(mask << shift)) | (val << shift);
        }
    } else if(desired_mode == 2) { // STY: slot 0=FX, 1=CL; slot2 retired
        if(slot==0) {
            unsigned fx=final1_fx_decode(style_profile);
            fx=dir>0 ? (fx<5?fx+1:5) : (fx>0?fx-1:0);
            style_profile=(style_profile&~FINAL1_FX_MASK)|final1_fx_encode(fx);
            return;
        }
        static const unsigned ss[] = {4, 6};
        static const unsigned sm[] = {3, 3};
        static const unsigned sh[] = {3, 2};
        if(slot >= 0 && slot < 2) {
            unsigned shift = ss[slot], mask = sm[slot], high = sh[slot];
            unsigned val = (style_profile >> shift) & mask;
            if(dir > 0) val = (val < high) ? val + 1 : high;
            else val = (val > 0) ? val - 1 : 0;
            style_profile = (style_profile & ~(mask << shift)) | (val << shift);
        }
    }
}

uint8_t integration_keys(uint8_t raw,uint32_t now) {
    (void)now;
    return raw & 15u;
}
static uint32_t next_gain(uint32_t g,uint32_t denominator,uint32_t old) {
    uint64_t ratio=((uint64_t)g<<16)/denominator;
    if(ratio<32768) ratio=32768;
    if(ratio>229376) ratio=229376;
    return (old*7u+(uint32_t)ratio)>>3;
}
static void motion_service(uint32_t now) {
    if(F1(0x2a0)&1u) return;
    F1(0x220)=1;fabric_fence();
    uint32_t seq=F1(0x200),gen=F1(0x204),frame=F1(0x208),meta=F1(0x20c),input[4],output[4];
    for(unsigned i=0;i<4;i++) input[i]=F1(0x210+4*i);
    F1(0x220)=2;fabric_fence();
    if(!seq || seq==last_motion_seq || gen!=applied_generation) return;
    if(last_motion_seq && (frame!=last_motion_frame+1u || (uint32_t)(now-last_motion_ms)>500)) motion_reset();
    last_motion_seq=seq;last_motion_frame=frame;last_motion_ms=now;
    uint8_t valid=meta&15u;
    if(valid) {last_observed_frame=frame;last_observed_ms=now;}
    if((uint32_t)(now-last_observed_ms)>=500) motion_reset();
    uint8_t result=motion_process(valid,input,(motion_profile>>17)&31u,(int8_t)(motion_extra>>8),output);
    if(exposure_hold) result=0;
    if((uint32_t)(frame-last_observed_frame)>=16) result=0;
    F1(0x280)=gen;F1(0x284)=result?last_observed_frame:frame;F1(0x288)=result;
    for(unsigned i=0;i<4;i++) F1(0x28c+4*i)=output[i];
    fabric_fence();F1(0x29c)=1;fabric_fence();
}
static void stats_service(uint32_t now) {
    if((uint32_t)(now-last_stats_poll)<5u) return;
    last_stats_poll=now;
    F1(0x420)=1;fabric_fence();
    IntegrationStats t={F1(0x400),F1(0x404),F1(0x408),F1(0x40c),F1(0x410),
                        F1(0x414),F1(0x418),F1(0x41c),now};
    F1(0x420)=2;fabric_fence();
    if((stats_valid && t.seq==stats.seq) || !t.seq || t.generation!=applied_generation) return;
    stats=t;stats_valid=1;
}
static void awb_service(void) {
    if((F1(0x454)&1u) || !stats_valid || stats.seq==last_awb_seq) return;
    uint32_t r=stats.r,g=stats.g,b=stats.b;
    last_awb_seq=stats.seq;
    if(r<=1000 || g<=1000 || b<=1000) return;
    awb_r=next_gain(g,r,awb_r);awb_b=next_gain(g,b,awb_b);
    F1(0x440)=awb_r;F1(0x444)=awb_b;F1(0x448)=stats.generation;F1(0x44c)=stats.source;
    fabric_fence();F1(0x450)=1;fabric_fence();
}
int integration_poll(uint32_t now) {
    int changed=0;
    if((uint32_t)(now-last_poll)>50) {motion_reset();last_motion_seq=0;}
    last_poll=now;
    uint32_t effective_extra=exposure_hold?(motion_extra&~8u):motion_extra;
    if(effective_extra!=submitted_extra || exposure_reset) {
        F1(0x1ac)=effective_extra|(exposure_reset?4u:0u);fabric_fence();submitted_extra=effective_extra;
        if(exposure_reset) motion_reset();
        exposure_reset=0;
    }
    uint32_t status=F1(0x190),gen=F1(0x198),active=F1(0x19c);
    if(gen!=applied_generation) {
        stats_valid=0;
        applied_generation=gen;last_motion_seq=last_awb_seq=last_motion_frame=0;
        last_observed_frame=0;last_observed_ms=now;motion_reset();awb_r=95907;awb_b=100825;changed=1;
    }
    if(!(status&1u)) {
        uint32_t cfg=configuration();
        if(cfg!=submitted_config || motion_profile!=submitted_motion) {
            F1(0x188)=cfg;F1(0x1a8)=motion_profile;fabric_fence();
            uint32_t before=F1(0x194);F1(0x18c)=1;fabric_fence();
            if(F1(0x194)==before+1u) {submitted_config=cfg;submitted_motion=motion_profile;}
        } else {
            stats_service(now);
            if((active&3u)==1) motion_service(now);
            if(active&(1u<<8)) awb_service();
        }
    }
    int value=page_value();
    F1(0x1b0)=(page<<24)|(selected<<20)|(value<0?1u<<16:0)|bcd((unsigned)(value<0?-value:value));
    return changed;
}
static int named_value(const char *p,char item[12],int *value) {
    unsigned n=0,v=0;
    while(*p==' ' || *p=='\t') ++p;
    while(*p && *p!=' ' && *p!='\t') {if(n==11) return 0;item[n++]=*p++;}
    item[n]=0;if(!n) return 0;
    while(*p==' ' || *p=='\t') ++p;
    int negative=0;
    if(*p=='-') {negative=1;++p;}
    if(*p<'0' || *p>'9') return 0;
    do {v=v*10u+(unsigned)(*p++-'0');if(v>511) return 0;} while(*p>='0' && *p<='9');
    while(*p==' ' || *p=='\t') ++p;
    if(*p) return 0;
    *value=negative?-(int)v:(int)v;return 1;
}
int integration_command(const char *line) {
    if(!strcmp(line,"diag") || !strcmp(line,"motion status") || !strcmp(line,"style status")) return 2;
    if(!strncmp(line,"mode ",5)) {
        if(!strcmp(line+5,"red")) desired_mode=0;
        else if(!strcmp(line+5,"motion")) desired_mode=1;
        else if(!strcmp(line+5,"style")) desired_mode=2;
        else return -1;
        return 1;
    }
    if(!strncmp(line,"page ",5)) {
        if(!strcmp(line+5,"base")) page=0;
        else if(!strcmp(line+5,"mode")) page=1;
        else if(!strcmp(line+5,"motion")) page=2;
        else if(!strcmp(line+5,"style")) page=3;
        else return -1;
        selected=0;return 1;
    }
    char item[12];int value;
    if(!strncmp(line,"style ",6)) {
        if(!named_value(line+6,item,&value) || value<0) return -1;
        unsigned shift,mask;
        if(!strcmp(item,"fx") && value<=5) {
            style_profile=(style_profile&~FINAL1_FX_MASK)|final1_fx_encode((unsigned)value);
            return 1;
        }
        else if(!strcmp(item,"cl") && value<=2) {shift=6;mask=3;}
        else if(!strcmp(item,"gg") && value==(int)FINAL1_STYLE_GG_Q8) {shift=9;mask=511;}
        else if(!strcmp(item,"auto") && value<=1) {shift=8;mask=1;}
        else return -1;
        style_profile=(style_profile&~(mask<<shift))|(value<<shift);return 1;
    }
    if(!strncmp(line,"motion ",7)) {
        if(!strcmp(line+7,"reset")) {exposure_reset=1;motion_reset();return 1;}
        if(!named_value(line+7,item,&value)) return -1;
        if(!strcmp(item,"yoff") && value>=-16 && value<=32) {
            motion_extra=(motion_extra&~(255u<<8))|((uint32_t)(uint8_t)value<<8);return 1;
        }
        if(!strcmp(item,"dwell") && value>=5 && value<=60) {
            motion_extra=(motion_extra&~(255u<<16))|((uint32_t)value<<16);return 1;
        }
        if(!strcmp(item,"mask") && value>=0 && value<=1) {
            motion_extra=(motion_extra&~8u)|((uint32_t)value<<3);return 1;
        }
        unsigned shift,mask;
        if(!strcmp(item,"diff") && value>=1 && value<=255) {shift=0;mask=255;}
        else if(!strcmp(item,"neighbor") && value>=1 && value<=7) {shift=8;mask=7;}
        else if(!strcmp(item,"min") && value>=1 && value<=63) {shift=11;mask=63;}
        else if(!strcmp(item,"hold") && value>=0 && value<=31) {shift=17;mask=31;}
        else return -1;
        motion_profile=(motion_profile&~(mask<<shift))|(value<<shift);return 1;
    }
    if(!strcmp(line,"display fixed")) {normal_profile&=~(1u<<8);return 1;}
    if(!strcmp(line,"display auto")) {normal_profile|=1u<<8;return 1;}
    return 0;
}
