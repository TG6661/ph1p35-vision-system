// Production fabric_test extracted verbatim from main.c; SDK/MMIO replaced only.
#include <assert.h>
#include <stdio.h>
#include "fabric_regs.h"
uint32_t fabric_test_mmio[512];
void fabric_test_fence(void) {}
static void AlSys_MDelay(unsigned n) {REG_AHB_CYCLES+=n;}
#define console_printf(...) ((void)0)
static int fabric_test(void) {
    static const uint32_t patterns[] = {
        0x00000000u,0xffffffffu,0xaaaaaaaaU,0x55555555u,
        0x12345678u,0x87654321u,0x80000001u
    };
    uint32_t id=0;
    for (unsigned int retry=0; retry<100; ++retry) {
        fabric_fence(); id=REG_IDENT;
        if (id==FABRIC_IDENT) break;
        AlSys_MDelay(1);
    }
    console_printf("[AHB] ID=0x%08x expected=0x%08x\r\n",(unsigned)id,(unsigned)FABRIC_IDENT);
    if (id!=FABRIC_IDENT) return -1;
    if (REG_SERVO_ABI!=SERVO_ABI) return -5; // Matching TRACK menu/HUD/PWM extension required.
    if (!(FABRIC_REG(0x184)&FINAL1_EXPOSURE_CAP)) return -6;
    if (!(FABRIC_REG(0x184)&FINAL1_STYLE_CAP)) return -7; // New STYLE algorithms require a matching bit.
    if (!(FABRIC_REG(0x184)&FINAL1_NEGATIVE_CAP)) return -8; // FX4 encoding/NEG support required.
    if (!(FABRIC_REG(0x184)&FINAL1_MODE_MENU_CAP)) return -9; // Mode-specific HUD metadata required.
    if (!(FABRIC_REG(0x184)&FINAL1_ASCII_CAP)) return -14;
    if (!(FABRIC_REG(0x184)&FINAL1_STYLE_V2_CAP)) return -15; // Our HUD v2 + GG224/576 + no LSC.
    if (!(FABRIC_REG(0x184)&FINAL1_PATROL_MENU_CAP)) return -16; // OFF/PATROL label and transparent logo HUD.
    if (FABRIC_REG(0x180)!=FINAL1_EXT_ABI || !(FABRIC_REG(0x184)&FINAL1_MOTION_CAP)) return -4;
    for (unsigned int i=0; i<sizeof(patterns)/sizeof(patterns[0])+32; ++i) {
        uint32_t value=i<7 ? patterns[i] : (UINT32_C(1)<<(i-7));
        REG_SCRATCH0=value; REG_SCRATCH1=~value; fabric_fence();
        uint32_t a=REG_SCRATCH0, b=REG_SCRATCH1;
        if (a!=value || b!=~value) {
            console_printf("[FAIL] scratch test %u: 0x%08x 0x%08x\r\n",i,(unsigned)a,(unsigned)b);
            return -2;
        }
    }
    REG_SCRATCH0=0; REG_SCRATCH1=0; fabric_fence();
    uint32_t before=REG_AHB_CYCLES;
    AlSys_MDelay(1); fabric_fence();
    if (REG_AHB_CYCLES==before) return -3;
    console_printf("[PASS] AHB ID, two scratch registers, 39 patterns and live counter\r\n");
    return 0;
}



int main(void) {
 REG_IDENT=FABRIC_IDENT;REG_SERVO_ABI=SERVO_ABI;FABRIC_REG(0x180)=FINAL1_EXT_ABI;
 FABRIC_REG(0x184)=0x70ff;assert(fabric_test()==0);
 FABRIC_REG(0x184)=0x30ff;assert(fabric_test()==-16);
 FABRIC_REG(0x184)=0xff;assert(fabric_test()==-14);
 FABRIC_REG(0x184)=0x1fff;assert(fabric_test()==-15);
 FABRIC_REG(0x184)=0x7f;assert(fabric_test()==-9);
 FABRIC_REG(0x184)=0x3f;assert(fabric_test()==-8);
 FABRIC_REG(0x184)=0x1f;assert(fabric_test()==-7);
 FABRIC_REG(0x184)=0x2f;assert(fabric_test()==-6);
 FABRIC_REG(0x184)=0x70ff;FABRIC_REG(0x180)=0x00010014;assert(fabric_test()==-4);
 FABRIC_REG(0x180)=FINAL1_EXT_ABI;REG_SERVO_ABI=0;assert(fabric_test()==-5);
 REG_IDENT=0;assert(fabric_test()==-1);
 puts("STYLE_BOOT_CONTRACT_PASS: current capability accepted, old exposure-only bit/teammate ABI/missing servo rejected");return 0;
}
