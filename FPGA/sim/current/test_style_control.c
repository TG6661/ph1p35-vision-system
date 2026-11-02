#include <assert.h>
#include <stdio.h>
#include "fabric_regs.h"
#include "integration_service.h"
uint32_t fabric_test_mmio[512];
static uint32_t now;
void fabric_test_fence(void) {
    if(FABRIC_REG(0x18c)==1) {
        FABRIC_REG(0x194)++;
        FABRIC_REG(0x198)=FABRIC_REG(0x194);
        FABRIC_REG(0x19c)=FABRIC_REG(0x188);
        FABRIC_REG(0x18c)=0;
    }
}
void motion_reset(void) {}
uint8_t motion_process(uint8_t v,const uint32_t in[4],unsigned h,int o,uint32_t out[4]) {
    (void)v;(void)in;(void)h;(void)o;(void)out;return 0;
}
static uint32_t flush(void) {
    now+=10;integration_poll(now);now+=10;integration_poll(now);
    assert(integration_measure_ready());return FABRIC_REG(0x19c);
}
int main(void) {
    uint32_t a,b,c,cfg;
    integration_init(0);integration_set_mode(2);cfg=flush();
    assert(cfg==((224u<<9)|256u|2u));
    for(int i=0;i<512;i++) {
        char cmd[32];snprintf(cmd,sizeof(cmd),"style gg %d",i);
        assert(integration_command(cmd)==(i==224?1:-1));
    }
    assert(integration_command("style gg -1")==-1);
    assert(integration_command("style gg 224 garbage")==-1);
    for(int i=0;i<4;i++) {
        char cmd[32];snprintf(cmd,sizeof(cmd),"style lsc %d",i);
        assert(integration_command(cmd)==-1);
    }
    for(int slot=0;slot<3;slot++) {
        for(int i=0;i<10;i++) integration_adjust_param(slot,1);
    }
    integration_get_active_params(&a,&b,&c);assert(a==5&&b==2&&c==0);
    cfg=flush();assert(((cfg>>9)&511u)==224);
    for(int slot=0;slot<3;slot++) {
        for(int i=0;i<10;i++) integration_adjust_param(slot,-1);
    }
    integration_get_active_params(&a,&b,&c);assert(a==0&&b==0&&c==0);
    cfg=flush();assert(((cfg>>9)&511u)==224);
    for(int fx=0;fx<6;fx++) for(int cl=0;cl<3;cl++) {
        char cmd[32];snprintf(cmd,sizeof(cmd),"style fx %d",fx);assert(integration_command(cmd)==1);
        snprintf(cmd,sizeof(cmd),"style cl %d",cl);assert(integration_command(cmd)==1);
        cfg=flush();assert(cfg==((224u<<9)|256u|((unsigned)(fx&3)<<4)|((unsigned)(fx&4)<<16)|(unsigned)(cl<<6)|2u));
    }
    assert(integration_command("style fx 6")==-1);
    assert(integration_command("style fx 7")==-1);
    assert(integration_command("style fx -1")==-1);
    assert(integration_command("style fx 4 extra")==-1);
    integration_get_active_params(&a,&b,&c);assert(a==5&&b==2&&c==0);
    integration_adjust_param(0,-1);cfg=flush();assert(final1_fx_decode(cfg)==4 && (cfg&FINAL1_FX_HIGH_BIT));
    integration_adjust_param(0,-1);cfg=flush();assert(final1_fx_decode(cfg)==3 && !(cfg&FINAL1_FX_HIGH_BIT));
    integration_adjust_param(0,1);cfg=flush();assert(final1_fx_decode(cfg)==4 && (cfg&FINAL1_FX_HIGH_BIT));
    integration_set_mode(1);cfg=flush();assert(cfg==((256u<<9)|1u));
    integration_set_mode(0);cfg=flush();assert(cfg==(256u<<9));assert(integration_tracking_ready());
    integration_set_mode(2);cfg=flush();assert(cfg==((224u<<9)|256u|FINAL1_FX_HIGH_BIT|128u|2u));
    puts("STYLE_CONTROL_PASS: 512 GG values, retired LSC rejected, menu saturation, 18 combinations, three-mode profiles/readiness");
    return 0;
}
