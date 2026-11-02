#ifndef OOPFPGA1_FABRIC_REGS_H
#define OOPFPGA1_FABRIC_REGS_H
#include <stdint.h>
#ifdef OOPFPGA_HOST_TEST
extern uint32_t fabric_test_mmio[];
void fabric_test_fence(void);
#define FABRIC_REG(offset) fabric_test_mmio[(offset)/4u]
#else
#define FABRIC_REG(offset) (*(volatile uint32_t *)(AHB_REG_BASE + (offset)))
#endif
#define AHB_REG_BASE       UINT32_C(0x80000000)
#define REG_IDENT          FABRIC_REG(0x00u)
#define REG_SCRATCH0       FABRIC_REG(0x04u)
#define REG_SCRATCH1       FABRIC_REG(0x08u)
#define REG_BUTTONS        FABRIC_REG(0x0cu)
#define REG_HW_STATUS      FABRIC_REG(0x10u)
#define REG_AHB_CYCLES     FABRIC_REG(0x14u)
#define FABRIC_IDENT       UINT32_C(0xA5010006)
#define FINAL1_EXT_ABI     UINT32_C(0x00010001)
#define FINAL1_MOTION_CAP  UINT32_C(0x00000008)
/* Stats are published independently of AWB; HUD bit39=AUTO EXP, selection=10.
 * Bit39 was the unused high bit of the now-fixed GMR BCD field. */
#define FINAL1_EXPOSURE_CAP UINT32_C(0x00000010)
/* Same register layout; STYLE uses fixed GG224/576 rows, no LSC,
 * teammate CRT (without RGB Gaussian) and strict/enhanced RGB CL. */
#define FINAL1_STYLE_CAP UINT32_C(0x00000020)
#define FINAL1_STYLE_GG_Q8 224u
#define FINAL1_NEGATIVE_CAP UINT32_C(0x00000040)
/* Mode-specific HUD v2, same 0x140..0x158 registers and 96-bit mailbox.
 * IDs remain AE0 AG1 GMR2 BL3 BO4 MODE5 P1/2/3=6/7/8 TRACK9 AUTOEXP10.
 * GMR is hidden; TRACK is selectable only in RED; STYLE P3 is hidden/reserved zero.
 * HUD[28]=display AWB, [29]=motion mask, [31:30]=reserved zero,
 * [38:32]=MIN (2 BCD digits, 00..63), [39]=AUTO EXP.
 * In MOT only, [75:68]=DWELL (2 BCD digits),
 * leaving [67:64]=NEIG. Other fields retain their layout.
 * Bit7 is required: pre-v2 bit files interpret these status bits as GMR/NEIG. */
#define FINAL1_MODE_MENU_CAP UINT32_C(0x00000080)
/* Our HUD v2 is retained; bit13 rejects the incompatible teammate 0x1fff ABI. */
#define FINAL1_ASCII_CAP UINT32_C(0x00001000)
#define FINAL1_STYLE_V2_CAP UINT32_C(0x00002000)
#define FINAL1_PATROL_MENU_CAP UINT32_C(0x00004000) /* HUD bit95 means OFF/PATROL. */
#define FINAL1_CAPABILITIES UINT32_C(0x000070ff)
/* 0x188/0x19c: FX[1:0] stays in bits5:4; FX[2] uses previously reserved bit18.
 * 0..3 unchanged, 4=NEG and 5=ASCII in STYLE only; 6/7 rejected. Mailbox stays 96 bits. */
#define FINAL1_FX_HIGH_BIT UINT32_C(0x00040000)
#define FINAL1_FX_MASK (FINAL1_FX_HIGH_BIT | UINT32_C(0x00000030))
static inline unsigned final1_fx_decode(uint32_t cfg) {
    return ((cfg>>4)&3u)|((cfg>>16)&4u);
}
static inline uint32_t final1_fx_encode(unsigned fx) {
    return ((fx&3u)<<4)|((fx&4u)<<16);
}
#define REG_THRESH_SHADOW FABRIC_REG(0x20u)
#define REG_THRESH_COMMAND FABRIC_REG(0x24u)
#define REG_THRESH_STATUS FABRIC_REG(0x28u)
#define REG_THRESH_ACCEPTED FABRIC_REG(0x2cu)
#define REG_ACCEPTED_SEQ FABRIC_REG(0x30u)
#define REG_APPLIED_SEQ FABRIC_REG(0x34u)
#define REG_THRESH_COMPLETED FABRIC_REG(0x38u)
#define REG_THRESH_SELECTED FABRIC_REG(0x3cu)
#define REG_THRESH_ACTIVE FABRIC_REG(0x40u)
#define REG_MENU_CAMERA FABRIC_REG(0x44u)
#define REG_MENU_UI FABRIC_REG(0x48u)
/* Existing menu ABI: BL/BO drive the shared RAW BLC in all three modes.
 * BL=0 bypasses; BL=1 subtracts BO (0..255 RAW10 units) with zero saturation.
 * Both fields take effect together at the next RAW SOF. RED GMR is fixed at 0.70.
 * UI[14:11] remains ABI-compatible; firmware sends 6, and RED RTL ignores it.
 * This does not alter the independent display Gamma or BL/BO behavior. */
#define REG_MENU_COMMAND FABRIC_REG(0x4cu)
#define REG_MENU_STATUS FABRIC_REG(0x50u)
#define REG_MENU_ACCEPTED_SEQ FABRIC_REG(0x54u)
#define REG_MENU_APPLIED_SEQ FABRIC_REG(0x58u)
#define REG_MENU_COMPLETED_CAMERA FABRIC_REG(0x5cu)
#define REG_MENU_COMPLETED_UI FABRIC_REG(0x60u)
/* Servo ABI v1: atomic PAN/TILT update at 20ms PWM boundary, same AHB domain.
 * Width writes clamp to 500..2500us; zero means 1500us. Busy commit rejects.
 * Cancel discards pending pair and holds active widths. ABI also marks HUD
 * bit95 tracking enable and menu selection 9 as supported. */
#define REG_SERVO_PAN FABRIC_REG(0x64u)
#define REG_SERVO_TILT FABRIC_REG(0x68u)
#define REG_SERVO_CONTROL FABRIC_REG(0x6cu)
#define REG_SERVO_ABI FABRIC_REG(0x70u)
#define REG_SERVO_ACTIVE FABRIC_REG(0x74u)
#define SERVO_ABI UINT32_C(0x53560101)
#define SERVO_COMMIT 1u
#define SERVO_CANCEL 2u
#define SERVO_CLEAR_REJECT 4u
#define SERVO_BUSY 1u
#define SERVO_REJECTED 2u
/* v4 target window. Snapshot data is read-only and held until discard or
 * an accepted result commit. Reads have three hardware wait cycles. */
#define REG_TARGET_STATUS FABRIC_REG(0x80u)
#define REG_TARGET_SEQUENCE FABRIC_REG(0x84u)
#define REG_TARGET_FRAME FABRIC_REG(0x88u)
#define REG_TARGET_META FABRIC_REG(0x8cu)
#define REG_TARGET_RX_INDEX FABRIC_REG(0x90u)
#define REG_TARGET_RX_DATA FABRIC_REG(0x94u)
#define REG_TARGET_COMMAND FABRIC_REG(0x98u)
#define REG_TARGET_DROPPED FABRIC_REG(0x9cu)
#define REG_TARGET_TX_SEQUENCE FABRIC_REG(0xa0u)
#define REG_TARGET_TX_META FABRIC_REG(0xa4u)
#define REG_TARGET_TX_INDEX FABRIC_REG(0xa8u)
#define REG_TARGET_TX_DATA FABRIC_REG(0xacu)
#define REG_TARGET_ACCEPTED FABRIC_REG(0xb0u)
#define REG_TARGET_DELIVERED FABRIC_REG(0xb4u)
#define REG_TARGET_ACCEPT_COUNT FABRIC_REG(0xb8u)
#define REG_TARGET_INFO FABRIC_REG(0xbcu)
/* v5 camera transactions and atomic menu display. See README_MCU相机与BCD.md. */
#define REG_CAM_ADDR FABRIC_REG(0x100u)
#define REG_CAM_DATA FABRIC_REG(0x104u)
#define REG_CAM_COMMAND FABRIC_REG(0x108u)
#define REG_CAM_STATUS FABRIC_REG(0x10cu)
#define REG_CAM_ACCEPTED FABRIC_REG(0x110u)
#define REG_CAM_COMPLETED FABRIC_REG(0x114u)
#define REG_CAM_READ_DATA FABRIC_REG(0x118u)
#define REG_CAM_STATE FABRIC_REG(0x11cu)
#define REG_CAM_COMPLETED_STATE FABRIC_REG(0x120u)
#define REG_HUD_WORD0 FABRIC_REG(0x140u)
#define REG_HUD_WORD1 FABRIC_REG(0x144u)
#define REG_HUD_WORD2 FABRIC_REG(0x148u)
#define REG_HUD_COMMAND FABRIC_REG(0x14cu)
#define REG_HUD_STATUS FABRIC_REG(0x150u)
#define REG_HUD_ACCEPTED FABRIC_REG(0x154u)
#define REG_HUD_COMPLETED FABRIC_REG(0x158u)
// Order MMIO accesses at the CPU/compiler boundary; no pixel buffers are mapped.
static inline void fabric_fence(void) {
#ifndef OOPFPGA_HOST_TEST
    __asm__ volatile ("fence iorw, iorw" ::: "memory");
#else
    fabric_test_fence();
#endif
}
#endif
