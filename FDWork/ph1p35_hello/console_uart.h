#ifndef CONSOLE_UART_H
#define CONSOLE_UART_H
#include <stdarg.h>
#include <stdint.h>
#include <stdio.h>
#include "al_hwcfg.h"
#include "al_usart_ll.h"
/* Poll TX and RX independently. A status report must not block RX for tens
 * of character times. Before console_start, use the SDK's normal printf. */
static char console_tx[2048];
static unsigned console_head,console_tail;
static int console_started,console_tx_wait,console_dropped;
static void console_printf(const char *fmt,...) {
    va_list ap;va_start(ap,fmt);
    if(!console_started) vprintf(fmt,ap);
    else {
        char text[256];
        int length=vsnprintf(text,sizeof(text),fmt,ap);
        unsigned free_bytes=(console_tail-console_head-1u)&2047u;
        if(length<0 || length>=(int)sizeof(text) || (unsigned)length>free_bytes)
            console_dropped=1;
        else for(int i=0;i<length;++i) {
            console_tx[console_head]=text[i];console_head=(console_head+1u)&2047u;
        }
    }
    va_end(ap);
}
static void console_poll_tx(void) {
    uint32_t status=AlUsart_ll_GetStatus(USART0_BASE_ADDR);
    if(console_tx_wait) {
        if(!(status & BIT(AL_USART_STATUS_TX_EOT))) return;
        AlUsart_ll_ClrStatus(USART0_BASE_ADDR,AL_USART_STATUS_TX_EOT);
        console_tx_wait=0;
    }
    if(console_head!=console_tail &&
       !(status & (BIT(AL_USART_STATUS_FULL)|BIT(AL_USART_STATUS_TX_BUSY)))) {
        AlUsart_ll_SetTxSize(USART0_BASE_ADDR,1);
        AlUsart_ll_SendData(USART0_BASE_ADDR,(unsigned char)console_tx[console_tail]);
        console_tail=(console_tail+1u)&2047u;console_tx_wait=1;
    } else if(console_head==console_tail && console_dropped) {
        console_dropped=0;
        console_printf("[WARN] output queue full; query status again\r\n");
    }
}
#endif
