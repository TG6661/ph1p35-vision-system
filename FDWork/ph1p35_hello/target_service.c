#include "target_service.h"
#include "target_io.h"
#include <string.h>
enum { FLUSH=0,WAIT_INPUT,READ_INPUT,CALCULATE,WAIT_OUTPUT,WRITE_OUTPUT,COMMIT_OUTPUT,CHECK_OUTPUT };
void target_service_init(TargetService *s,uint32_t now) {
    memset(s,0,sizeof(*s));target_tracker_init(&s->tracker);s->last_poll=now;s->start=now;
}
static void abandon(TargetService *s) {
    target_tracker_forget(&s->tracker);s->have_sequence=0;s->phase=FLUSH;++s->resyncs;
}
void target_service_poll(TargetService *s,uint32_t now) {
    // Never apply an old computation after a debugger pause. Video itself does
    // not depend on these polls; hardware expires stale annotations in 500 ms.
    if((uint32_t)(now-s->last_poll)>50 ||
       (s->phase>=READ_INPUT && (uint32_t)(now-s->start)>50)) {
        abandon(s);s->have_last=0;
    }
    s->last_poll=now;
    fabric_fence();
    switch(s->phase) {
    case FLUSH:
        TARGET_WRITE(REG_TARGET_COMMAND,1);fabric_fence();s->phase=WAIT_INPUT;break;
    case WAIT_INPUT: {
        if(!(TARGET_READ(REG_TARGET_STATUS)&1u)) break;
        memset(&s->input,0,sizeof(s->input));
        s->input.sequence=TARGET_READ(REG_TARGET_SEQUENCE);s->input.frame_id=TARGET_READ(REG_TARGET_FRAME);
        uint32_t meta=TARGET_READ(REG_TARGET_META);s->input.dropped=TARGET_READ(REG_TARGET_DROPPED);
        s->input.count=(uint8_t)(meta&15u);s->input.error=(uint8_t)((meta>>4)&15u);
        s->input.total=(uint16_t)(meta>>16);
        if(s->input.count>8 || s->input.total<s->input.count || (meta&0xff00u)) {
            s->input.error|=8;s->input.count=0;
        }
        if(s->have_sequence && s->input.sequence!=s->last_sequence+1u) {
            target_tracker_forget(&s->tracker);++s->resyncs;
        }
        s->word=0;s->start=now;s->phase=s->input.count?READ_INPUT:CALCULATE;break;
    }
    case READ_INPUT: {
        unsigned record=s->word/3u,field=s->word%3u;
        TARGET_WRITE(REG_TARGET_RX_INDEX,record*4u+field);fabric_fence();
        uint32_t word=TARGET_READ(REG_TARGET_RX_DATA);Target *t=&s->input.items[record];
        if(field==0) {t->area=word&0xfffffu;t->label=(uint8_t)(word>>20);if(word>>28)s->input.error|=8;}
        else if(field==1) {
            t->xmin=(uint16_t)(word&0x7ffu);t->xmax=(uint16_t)((word>>16)&0x7ffu);
            if(word&0xf800f800u)s->input.error|=8;
        } else {
            t->ymin=(uint16_t)(word&0x3ffu);t->ymax=(uint16_t)((word>>16)&0x3ffu);
            if(word&0xfc00fc00u)s->input.error|=8;
        }
        if(++s->word==s->input.count*3u) s->phase=CALCULATE;
        break;
    }
    case CALCULATE:
        target_process(&s->tracker,&s->input,&s->output);s->phase=WAIT_OUTPUT;break;
    case WAIT_OUTPUT:
        if(TARGET_READ(REG_TARGET_STATUS)&2u) break;
        TARGET_WRITE(REG_TARGET_TX_SEQUENCE,s->input.sequence);
        TARGET_WRITE(REG_TARGET_TX_META,s->output.count|((uint32_t)s->output.error<<4));
        fabric_fence();s->accepted_before=TARGET_READ(REG_TARGET_ACCEPT_COUNT);s->word=0;
        s->phase=s->output.count?WRITE_OUTPUT:COMMIT_OUTPUT;break;
    case WRITE_OUTPUT: {
        const Target *t=&s->output.items[s->word/2u];
        TARGET_WRITE(REG_TARGET_TX_INDEX,s->word);
        TARGET_WRITE(REG_TARGET_TX_DATA,(s->word&1u)?target_pack_high(t):target_pack_low(t));
        fabric_fence();
        if(++s->word==s->output.count*2u) s->phase=COMMIT_OUTPUT;
        break;
    }
    case COMMIT_OUTPUT:
        TARGET_WRITE(REG_TARGET_COMMAND,6);fabric_fence();s->phase=CHECK_OUTPUT;break;
    case CHECK_OUTPUT:
        if(TARGET_READ(REG_TARGET_ACCEPT_COUNT)==s->accepted_before+1u && TARGET_READ(REG_TARGET_ACCEPTED)==s->input.sequence) {
            s->last=s->output;s->have_last=1;s->last_ms=now;s->last_input_count=s->input.count;
            s->last_sequence=s->input.sequence;s->have_sequence=1;s->phase=WAIT_INPUT;
        } else if(TARGET_READ(REG_TARGET_STATUS)&4u) {++s->rejects;abandon(s);}
        break;
    default:abandon(s);break;
    }
}
