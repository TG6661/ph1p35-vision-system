/* MCU owns debounce/repeat and mode-specific menu navigation. */
#include <stdint.h>
#include <stdio.h>
#include "al_core.h"
#include "fabric_regs.h"
#include "command_parser.h"
#include "al_hwcfg.h"
#include "al_usart_ll.h"
#include "console_uart.h"
#include "menu_control.h"
#include "menu_transport.h"
#include "target_service.h"
#include "camera_service.h"
#include "menu_display.h"
#include "integration_service.h"
#include "gimbal_track.h"
#include "exposure_service.h"
#include <string.h>
#include "al_systimer.h"

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



static Menu menu;
static MenuTransport transport;
static TargetService targets;
static CameraService camera;
static MenuDisplay display;
static unsigned camera_reported;
static uint32_t last_targets_print;
static uint64_t ticks_per_ms;
static uint32_t now_ms(void) {return (uint32_t)(AlSys_GetTimerTickCount()/ticks_per_ms);}
static void show_targets(uint32_t now) {
    // At most four reports/s and enough queue room for the entire snapshot.
    if((uint32_t)(now-last_targets_print)<250) return;
    last_targets_print=now;
    if(((console_tail-console_head-1u)&2047u)<1200) {console_dropped=1;return;}
    if(!targets.have_last) {console_printf("[TARGETS] no MCU result yet; hw=0x%x\r\n",(unsigned)REG_TARGET_STATUS);return;}
    const TargetSnapshot *r=&targets.last;
    console_printf("[TARGETS] seq=%u detection=%u total=%u selected=%u tracked=%u error=0x%x\r\n",
        (unsigned)r->sequence,(unsigned)r->frame_id,(unsigned)r->total,
        (unsigned)targets.last_input_count,(unsigned)r->count,(unsigned)r->error);
    console_printf("age_ms=%u stale=%u delivered=%u dropped=%u resyncs=%u rejects=%u (not HDMI frame)\r\n",
        (unsigned)(now-targets.last_ms),(unsigned)((uint32_t)(now-targets.last_ms)>=500),
        (unsigned)REG_TARGET_DELIVERED,(unsigned)r->dropped,(unsigned)targets.resyncs,(unsigned)targets.rejects);
    static const char *const names[]={"UNKNOWN","RECT","CIRCLE"};
    for(unsigned i=0;i<r->count;++i) {
        const Target *t=&r->items[i];
        console_printf("id=%u shape=%s area=%u center=%u,%u box=%u,%u..%u,%u\r\n",
            (unsigned)t->id,names[t->shape],(unsigned)t->area,
            ((unsigned)t->xmin+t->xmax)/2,((unsigned)t->ymin+t->ymax)/2,
            (unsigned)t->xmin,(unsigned)t->ymin,(unsigned)t->xmax,(unsigned)t->ymax);
    }
}
static void show_status(void) {
    fabric_fence();
    uint32_t mode=integration_get_mode(),p1=menu.rmin,p2=menu.rgap,p3=menu.bgap;
    integration_get_active_params(&p1,&p2,&p3);
    console_printf("[MENU] owner=MCU selected=%s AE=%u AG=%u BL=%u BO=%u\r\n",
        menu_names[menu.selected],(unsigned)menu.ae,(unsigned)menu.ag,
        (unsigned)menu.bl,(unsigned)menu.bo);
    if(mode==0) console_printf("RED: RMIN=%u RGAP=%u BGAP=%u TRACK=%u; WB=fixed GMR=0.70 SF=STRONG ERODE=3x3 DILATE=5x5\r\n",
        (unsigned)p1,(unsigned)p2,(unsigned)p3,(unsigned)gimbal_track_enabled());
    else if(mode==1) console_printf("MOTION: DIFF=%u NEIG=%u HOLD=%u; block=8x8 adaptive background, neighbor=3x3\r\n",
        (unsigned)p1,(unsigned)p2,(unsigned)p3);
    else console_printf("STYLE: FX=%u CL=%u; GG=224/256 H576 fixed Gamma=0.55\r\n",(unsigned)p1,(unsigned)p2);
    console_printf("control accepted=%u copied=%u busy=%u; RGB accepted=%u applied=%u busy=%u\r\n",
        (unsigned)REG_MENU_ACCEPTED_SEQ,(unsigned)REG_MENU_APPLIED_SEQ,(unsigned)(REG_MENU_STATUS&1),
        (unsigned)REG_ACCEPTED_SEQ,(unsigned)REG_APPLIED_SEQ,(unsigned)(REG_THRESH_STATUS&1));
    console_printf("[CAM] ID=%04x phase=%u fault=%u NACKs=%u timeouts=%u groups=%u status=0x%x state=0x%08x\r\n",
        (unsigned)camera.sensor_id,(unsigned)camera.phase,(unsigned)camera.fault,
        (unsigned)camera.errors,(unsigned)camera.timeouts,(unsigned)camera.groups,
        (unsigned)REG_CAM_STATUS,(unsigned)REG_CAM_COMPLETED_STATE);
    console_printf("HUD accepted=%u staged=%u busy=%u (not HDMI source-frame binding)\r\n",
        (unsigned)REG_HUD_ACCEPTED,(unsigned)REG_HUD_COMPLETED,(unsigned)(REG_HUD_STATUS&1u));
    console_printf("[CAM HEALTH] ready=%u retries=%u group_retry=%u/2 last_NACK=0x%06x phase=%u index=%u at_ms=%u\r\n",
        (unsigned)camera_service_ready(&camera),(unsigned)camera.retries,(unsigned)camera.group_retries,
        (unsigned)camera.last_error_word,(unsigned)camera.last_error_phase,(unsigned)camera.last_error_index,
        (unsigned)camera.last_error_ms);
    uint32_t active=REG_THRESH_ACTIVE;
    if(active&(1u<<24)) console_printf("RGB active=%u/%u/%u\r\n",
        (unsigned)((active>>16)&255),(unsigned)((active>>8)&255),(unsigned)(active&255));
    else console_printf("RGB active=unconfirmed until next SOF\r\n");
}
/* New motion UI strings stay in XIP flash; the existing DLM heap/stack stay intact. */
static const char motion_help[] __attribute__((section(".rodata.motion_ui"))) =
    "motion yoff -16..32 | dwell 5..60 | mask 0..1 | reset\r\n";
static const char motion_diag[] __attribute__((section(".rodata.motion_ui"))) =
    "motion adaptive: yoff=%d dwell=%u mask=%u ctrl=0x%08x\r\n";
static void execute_line(const char *line,uint32_t now) {
    int exposure=exposure_command(line);
    if(exposure) {
        if(exposure<0) {
            console_printf("[ERROR] use exposure auto|manual|status|target 16..160; matching bit required\r\n");return;
        }
        console_printf("[EXPOSURE] supported=%u auto=%u state=%u Y=%u target=%u samples=%u%% updates=%u\r\n",
            g_exposure.supported,g_exposure.enabled,g_exposure.state,g_exposure.mean,
            g_exposure.target,g_exposure.coverage,g_exposure.updates);
        console_printf("AE/AG wanted=%u/%u applied=%u/%u groups=%u; state 0=OFF 1=WAIT 2=SETTLE 3=ADJUST 4=MOT_LOCK 5=FAULT 6=STALE 7=TARGET/LIMIT\r\n",
            (unsigned)menu.ae,(unsigned)menu.ag,(unsigned)camera.applied_ae,(unsigned)camera.applied_ag,(unsigned)camera.groups);
        console_printf("camera ready=%u NACKs(history)=%u retries=%u group_retry=%u/2 fault=%u timeouts=%u\r\n",
            (unsigned)camera_service_ready(&camera),(unsigned)camera.errors,(unsigned)camera.retries,
            (unsigned)camera.group_retries,(unsigned)camera.fault,(unsigned)camera.timeouts);
        return;
    }
    int track=gimbal_track_command(line);
    if(track) {if(track<0) console_printf("[ERROR] invalid track/servo command; use help\r\n");return;}
    int ext=integration_command(line);
    if(ext) {
        if(ext==2) {console_printf("[FINAL1] mode=%u page=%u gen=%u accepted=%u status=0x%08x config=0x%08x\r\n",
            (unsigned)integration_mode(),integration_page(),(unsigned)FABRIC_REG(0x198),
            (unsigned)FABRIC_REG(0x194),(unsigned)FABRIC_REG(0x190),(unsigned)FABRIC_REG(0x19c));
            console_printf("source=%u raw_gen=%u post_source=%u post_gen=%u post_count=%u linear_captures=%u\r\n",
                (unsigned)FABRIC_REG(0x1c0),(unsigned)FABRIC_REG(0x1c4),(unsigned)FABRIC_REG(0x1c8),
                (unsigned)FABRIC_REG(0x1cc),(unsigned)FABRIC_REG(0x1d0),(unsigned)FABRIC_REG(0x1d4));
            uint32_t mc=FABRIC_REG(0x1ac);
            console_printf(motion_diag,
                (int)(int8_t)(mc>>8),(unsigned)((mc>>16)&255),(unsigned)((mc>>3)&1),(unsigned)mc);}
        else console_printf(ext>0?"[QUEUED] final1 setting saved\r\n":"[ERROR] invalid final1 command\r\n");
        return;
    }
    int result=menu_command(&menu,line,now);
    if(result==-2) {console_printf("[ERROR] GMR fixed at 0.70; only value GMR 70 is supported\r\n");return;}
    if(result>0) {console_printf("[QUEUED] MCU menu updated; status shows progress\r\n");return;}
    if(result<0) {console_printf("[ERROR] invalid menu item/value\r\n");return;}
    uint32_t rgb=0;
    switch(parse_command(line,&rgb)) {
    case CMD_SET:
        menu.rmin=(uint8_t)(rgb>>16);menu.rgap=(uint8_t)(rgb>>8);menu.bgap=(uint8_t)rgb;
        console_printf("[QUEUED] RGB %u/%u/%u; latest change will follow pending SOF\r\n",
            (unsigned)menu.rmin,(unsigned)menu.rgap,(unsigned)menu.bgap);break;
    case CMD_STATUS:show_status();gimbal_track_status();break;
    case CMD_TARGETS:if(integration_mode()==0) show_targets(now);else console_printf("[TARGETS] RED inactive\r\n");break;
    case CMD_HELP:
        console_printf("mode red|motion|style; page base|mode|motion|style; diag\r\n");
        console_printf("style fx 0..5 (4=NEG 5=ASCII) | cl 0..2 | gg 224 (fixed H576) | auto 0..1\r\n");
        console_printf("motion diff 1..255 | neighbor 1..7 | min 1..63 | hold 0..31\r\n");
        console_printf(motion_help);gimbal_track_help();
        console_printf("display fixed|auto. UP/DOWN moves cursor, +/- adjusts selected field.\r\n");
        console_printf("exposure auto|manual|status|target 16..160; AUTOEXP +/- ON/OFF; manual AE/AG exits auto\r\n");
        console_printf("Manual/auto limits in all modes: AE 2..1991, AG 16..239 (analog + digital gain)\r\n");
        console_printf("Keys: D5 up, A9 down, B9 plus, C7 minus. Read-only rows are skipped.\r\n");
        console_printf("status | targets | defaults | select AE | value AE 1991 | set 100 65 65\r\n");
        console_printf("Order: MODE AUTOEXP AE AG BL BO P1 P2 P3(RED/MOTION) TRACK(RED). GG fixed, LSC removed.\r\n");break;
    case CMD_FPGA:
        console_printf("[ERROR] FPGA menu retired; use defaults to reset the MCU menu\r\n");break;
    default:console_printf("[ERROR] unknown command; use help\r\n");break;
    }
}
static int uart_poll(void) {
    static int received=-1;
    uint32_t status=AlUsart_ll_GetStatus(USART0_BASE_ADDR);
    if(received<0 && !(status & (BIT(AL_USART_STATUS_EMPTY)|BIT(AL_USART_STATUS_RX_BUSY))))
        received=AlUsart_ll_RecvData(USART0_BASE_ADDR)&255;
    if(received>=0 && (AlUsart_ll_GetStatus(USART0_BASE_ADDR)&BIT(AL_USART_STATUS_RX_EOT))) {
        int ch=received;received=-1;
        AlUsart_ll_ClrStatus(USART0_BASE_ADDR,AL_USART_STATUS_RX_EOT);
        AlUsart_ll_SetRxSize(USART0_BASE_ADDR,1);
        return ch;
    }
    return -1;
}

int main(void) {
    AlSys_MDelay(100);
    console_printf("\r\nfinal1 RED/MOTION/STYLE / interface v6 + servo v1 + exposure v1 / UART 115200 8N1\r\n");
    int result=fabric_test();
    if(result) {
        console_printf("[FAIL] code=%d; load matching final1 v6 + servo v1 + exposure v1 + STYLE v2 + NEG + ASCII + HUD v2 + PATROL menu bit/ELF\r\n",result);
        for(;;) AlSys_MDelay(1000);
    }
    ticks_per_ms=AlSys_GetTimerFreq()/1000u;
    if(!ticks_per_ms) {
        console_printf("[FAIL] invalid SDK timer frequency\r\n");
        for(;;) AlSys_MDelay(1000);
    }
    uint32_t now=now_ms();menu_init(&menu,now);menu_transport_init(&transport);
    target_service_init(&targets,now);last_targets_print=now-250u;
    camera_service_init(&camera,now);menu_display_init(&display);integration_init(now);gimbal_track_set_logger(console_printf);gimbal_track_init();
    exposure_init(now);
    console_printf("MCU menu: RED10/MOTION9/STYLE8 items, FX5 ASCII, TRACK OFF/PATROL. AUTO EXP defaults OFF. Send help for commands.\r\n");
    console_printf("Control copied != I2C success or displayed frame. CFG only means sequence complete.\r\n");
    AlUsart_ll_ClrStatus(USART0_BASE_ADDR,AL_USART_STATUS_RX_EOT);
    AlUsart_ll_SetRxSize(USART0_BASE_ADDR,1);
    console_started=1;
    char line[64];unsigned length=0;int overflow=0;
    uint32_t last_sample=now,last_reject=now-1000u;
    for(;;) {
        now=now_ms();
        if(now!=last_sample) {
            last_sample=now;
            menu_sample(&menu,integration_keys((uint8_t)REG_BUTTONS,now),now);
            unsigned events=menu_transport_service(&transport,&menu,now);
            if(events&TRANS_RESET) {
                target_service_init(&targets,now);
                camera_service_init(&camera,now);menu_display_init(&display);integration_init(now);gimbal_track_set_logger(console_printf);gimbal_track_init();
                exposure_init(now);
                camera_reported=0;
                console_printf("[RESET] Fabric reset; restoring camera, menu defaults and target state\r\n");
            }
            if(events&TRANS_RGB_APPLIED) console_printf("[APPLIED] RGB seq=%u\r\n",(unsigned)REG_APPLIED_SEQ);
            if(events&TRANS_RGB_WAIT) console_printf("[WAIT] RGB waiting for SOF; other menu controls remain available\r\n");
            if((events&TRANS_REJECT) && (uint32_t)(now-last_reject)>=1000) {
                last_reject=now;console_printf("[RETRY] control not accepted; retaining latest menu values\r\n");
            }
        }
        uint32_t uart_status=AlUsart_ll_GetStatus(USART0_BASE_ADDR);
        const uint32_t error_mask=BIT(AL_USART_STATUS_RX_ERROR_FLOW)|BIT(AL_USART_STATUS_RX_ERROR_PARITY)|
            BIT(AL_USART_STATUS_RX_FRAME_ERR_FLAG)|BIT(AL_USART_STATUS_STOP_BIT_ERR_FLAG);
        if(uart_status & error_mask) {
            overflow=1;
            for(unsigned bit=4;bit<=9;++bit)
                if((uart_status & error_mask)&(1u<<bit))
                    AlUsart_ll_ClrStatus(USART0_BASE_ADDR,(AL_USART_StatusEnum)bit);
        }
        int ch=uart_poll();
        if(ch=='\r' || ch=='\n') {
            if(overflow) console_printf("[ERROR] invalid or overlong line discarded\r\n");
            else if(length) {line[length]=0;execute_line(line,now);}
            length=0;overflow=0;
        } else if(ch==8 || ch==127) {if(length && !overflow) --length;}
        else if(ch>=0) {
            if((ch<32 && ch!='\t') || ch>126) overflow=1;
            else if(length<sizeof(line)-1 && !overflow) line[length++]=(char)ch;
            else overflow=1;
        }
        camera_service_poll(&camera,&menu,now);
        if(camera.fault && camera_reported!=2) {
            camera_reported=2;
            console_printf("[CAM FAULT] ID=%04x NACKs=%u timeouts=%u; stopped. Inspect status and reset after fixing cause.\r\n",
                (unsigned)camera.sensor_id,(unsigned)camera.errors,(unsigned)camera.timeouts);
        } else if(camera.groups && !camera_reported) {
            camera_reported=1;
            console_printf("[CAM] initialization sequence complete: ID=%04x NACKs=%u; CFG does not prove every write succeeded.\r\n",
                (unsigned)camera.sensor_id,(unsigned)camera.errors);
        }
        if(integration_poll(now)) {target_service_init(&targets,now);gimbal_track_invalidate();}
        exposure_poll(&menu,&camera,now);
        menu_display_poll(&display);
        target_service_poll(&targets,now);
        gimbal_track_poll(&targets,now);
        console_poll_tx();
    }
}
