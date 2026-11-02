#include <assert.h>
#include <stdio.h>
#include "fabric_regs.h"
#include "integration_service.h"
uint32_t fabric_test_mmio[512];
void fabric_test_fence(void) {
 if(FABRIC_REG(0x18c)==1) {
  FABRIC_REG(0x18c)=0;FABRIC_REG(0x194)++;
  FABRIC_REG(0x198)=FABRIC_REG(0x194);FABRIC_REG(0x19c)=FABRIC_REG(0x188);
 }
}
void motion_reset(void) {}
uint8_t motion_process(uint8_t v,const uint32_t in[4],unsigned h,int o,uint32_t out[4]) {(void)v;(void)in;(void)h;(void)o;(void)out;return 0;}
int main(void) {
 integration_init(0);assert(!integration_tracking_ready());
 integration_poll(0);assert(!integration_tracking_ready());
 integration_poll(0);assert(integration_tracking_ready());
 FABRIC_REG(0x190)=1;assert(!integration_tracking_ready());FABRIC_REG(0x190)=0;
 FABRIC_REG(0x194)++;assert(!integration_tracking_ready());FABRIC_REG(0x198)=FABRIC_REG(0x194);assert(!integration_tracking_ready());
 assert(integration_poll(10)==1);assert(integration_tracking_ready());
 integration_set_mode(1);assert(!integration_tracking_ready());integration_set_mode(0);assert(integration_tracking_ready());
 FABRIC_REG(0x19c)=1;assert(!integration_tracking_ready());FABRIC_REG(0x19c)=0;
 assert(integration_command("display auto")==1);assert(!integration_tracking_ready());
 puts("GIMBAL_REAL_READINESS_PASS");return 0;
}
